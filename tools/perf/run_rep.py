#!/usr/bin/env python3
"""One bench repeat for the iOS perf workflow: builds, then replays.

Ordering is the point. Per repeat, for each requested bench configuration,
this driver resets the workspace from a pristine copy, runs all three
scenario builds first (clean, then the top-layer app edit, then the layer-0
core edit, keeping each scenario's execution log), then makes the execroot's
bazel-out user-writable (replays re-run actions in place and must not fail
on read-only outputs), then summarizes and replays all three logs, then
shuts the server down. No Bazel build follows a replay in the same output
base, so a replay can never perturb the next incremental build's action
cache.

Configurations (fixed table ``CONFIGS``):

- ``device_release``: the Flutter iOS framework assembly itself
  (``//app:__app_framework_framework``, the ``_flutter_ios_framework``
  rule that ``flutter_ios_framework_gen(name = "app_framework")``
  creates: AOT gen_snapshot for arm64 plus App.framework assembly, no
  ``ios_application`` and therefore no signing or provisioning
  profile), built with ``-c opt --ios_multi_cpus=arm64``. The public
  ``//app:app_framework`` wrapper is an ``apple_dynamic_framework_import``
  whose outputs are only consumed when linked into an app, so building it
  executes nothing — the bench must target the inner rule.
- ``sim_debug``: the full simulator app (``//app:app_ios``, the developer
  inner loop), built with ``-c dbg --ios_multi_cpus=sim_arm64``. The
  simulator runs debug builds only, and simulator bundles need no
  provisioning profile.

Each configuration gets its own output base under the given root (no
shared server between configs). Results land in
<results-ref-dir>/<config>/<scenario>/rep<N>/{execlog.json, replay.json},
the layout summarize.py reads.
"""

import argparse
import os
import shutil
import stat
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from execlog import load_spawns  # noqa: E402

SCENARIOS = [
    ("clean", None),
    ("app_edit", "apply-app-edit"),
    ("core_edit", "apply-body-edit"),
]

CONFIGS = {
    "device_release": {
        "target": "//app:__app_framework_framework",
        "build_flags": ["-c", "opt", "--ios_multi_cpus=arm64"],
    },
    "sim_debug": {
        "target": "//app:app_ios",
        "build_flags": ["-c", "dbg", "--ios_multi_cpus=sim_arm64"],
    },
}
CONFIG_ORDER = ["device_release", "sim_debug"]

# A clean bench build always executes dozens of actions (kernel compiles
# per package, AOT, framework assembly or the full app link). Fewer than
# this many executed spawns means the target built nothing (as
# //app:app_framework did: its import wrapper has no actions of its own)
# and the repeat must fail loudly instead of recording a silent no-op.
DEFAULT_MIN_CLEAN_ACTIONS = 10


def real_run(argv, cwd=None, capture_output=False):
    return subprocess.run(
        argv,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.STDOUT if capture_output else None,
        text=True,
        check=False,
    )


def reset_work(pristine, work):
    """Replaces work with a fresh copy of the pristine workspace."""
    shutil.rmtree(work, ignore_errors=True)
    shutil.copytree(pristine, work, symlinks=True)


def bazel_build(run, work, out_base, target, build_flags, log_path):
    proc = run(
        ["bazel", "--output_base=" + out_base, "build"] + list(build_flags)
        + [target,
             "--execution_log_json_file=" + log_path,
             "--materialize_param_files"],
        cwd=work)
    if proc.returncode != 0:
        raise RuntimeError("bazel build %s failed (exit %s)"
                           % (target, proc.returncode))
    return proc


def apply_edit(run, tools_dir, work, edit_command):
    gen = os.path.join(tools_dir, "gen_monorepo.py")
    proc = run([sys.executable, gen, edit_command, "--workspace", work],
               cwd=work)
    if proc.returncode != 0:
        raise RuntimeError("%s failed (exit %s)"
                           % (edit_command, proc.returncode))
    return proc


def get_execroot(run, work, out_base):
    proc = run(["bazel", "--output_base=" + out_base, "info",
                "execution_root"], cwd=work, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError("bazel info execution_root failed (exit %s)"
                           % proc.returncode)
    return proc.stdout.strip()


def make_writable_tree(root):
    """Adds u+w (u+wx on dirs) under root; returns the changed count."""
    changed = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                mode = os.stat(path).st_mode
                extra = stat.S_IWUSR
                if os.path.isdir(path) and not mode & stat.S_IXUSR:
                    extra |= stat.S_IXUSR
                if mode & extra != extra:
                    os.chmod(path, mode | extra)
                    changed += 1
            except OSError:
                continue
    return changed


def summarize_log(run, tools_dir, log_path, out_path):
    proc = run([sys.executable, os.path.join(tools_dir, "execlog.py"),
                "--log", log_path, "--out", out_path])
    if proc.returncode != 0:
        raise RuntimeError("execlog.py failed (exit %s)" % proc.returncode)
    return proc


def replay_log(run, tools_dir, log_path, execroot, out_path, timeout,
               budget_seconds):
    proc = run([sys.executable, os.path.join(tools_dir, "replay.py"),
                "--log", log_path, "--execroot", execroot,
                "--out", out_path, "--timeout", str(timeout),
                "--budget-seconds", str(budget_seconds)])
    if proc.returncode != 0:
        raise RuntimeError("replay.py failed (exit %s)" % proc.returncode)
    return proc


def check_clean_actions(log_path, target, minimum):
    """Fails loudly when a clean build executed suspiciously few actions."""
    try:
        n_spawns = len(load_spawns(log_path))
    except OSError as exc:
        raise RuntimeError(
            "clean build of %s left no execution log %s (%s)"
            % (target, log_path, exc))
    if n_spawns < minimum:
        raise RuntimeError(
            "clean build of %s executed only %d action(s) "
            "(minimum %d): the target builds nothing" % (
                target, n_spawns, minimum))
    return n_spawns


def shutdown(run, work, out_base):
    proc = run(["bazel", "--output_base=" + out_base, "shutdown"], cwd=work)
    if proc.returncode != 0:
        raise RuntimeError("bazel shutdown failed (exit %s)"
                           % proc.returncode)
    return proc


def run_config(tools_dir, work, out_base, results_ref_dir, rep, config,
               replay_timeout=600.0, replay_budget=1800.0,
               min_clean_actions=DEFAULT_MIN_CLEAN_ACTIONS, run=None,
               chmod=None):
    """Runs one configuration: three builds, chmod, three replay passes."""
    spec = CONFIGS[config]
    run = run or real_run
    chmod = chmod or make_writable_tree
    logs = {}
    for scenario, edit_command in SCENARIOS:
        if edit_command is not None:
            apply_edit(run, tools_dir, work, edit_command)
        log_path = os.path.join(work, "execlog-%s.json" % scenario)
        bazel_build(run, work, out_base, spec["target"],
                    spec["build_flags"], log_path)
        logs[scenario] = log_path
        if scenario == "clean":
            check_clean_actions(log_path, spec["target"],
                                min_clean_actions)
    execroot = get_execroot(run, work, out_base)
    bazel_out = os.path.join(execroot, "bazel-out")
    made_writable = chmod(bazel_out) if os.path.isdir(bazel_out) else 0
    for scenario, _ in SCENARIOS:
        rep_dir = os.path.join(results_ref_dir, config, scenario,
                               "rep%d" % rep)
        os.makedirs(rep_dir, exist_ok=True)
        summarize_log(run, tools_dir, logs[scenario],
                      os.path.join(rep_dir, "execlog.json"))
        replay_log(run, tools_dir, logs[scenario], execroot,
                   os.path.join(rep_dir, "replay.json"),
                   replay_timeout, replay_budget)
    shutdown(run, work, out_base)
    return {"execroot": execroot, "logs": logs,
            "made_writable": made_writable}


def run_rep(tools_dir, pristine, work, out_base_root, results_ref_dir, rep,
            configs=None, replay_timeout=600.0, replay_budget=1800.0,
            min_clean_actions=DEFAULT_MIN_CLEAN_ACTIONS,
            run=None, chmod=None, reset=None):
    """Runs one full repeat over configs, each with a fresh work copy.

    The workspace is reset from pristine before every config so edits
    applied by an earlier config can never leak into a later config's
    clean build. Output bases are <root>/<config>: no shared server
    between configs.
    """
    configs = list(configs) if configs else list(CONFIG_ORDER)
    unknown = [c for c in configs if c not in CONFIGS]
    if unknown:
        raise ValueError("unknown config(s): %s" % ", ".join(unknown))
    reset = reset or reset_work
    records = {}
    for config in configs:
        reset(pristine, work)
        records[config] = run_config(
            tools_dir, work, os.path.join(out_base_root, config),
            results_ref_dir, rep, config,
            replay_timeout=replay_timeout, replay_budget=replay_budget,
            min_clean_actions=min_clean_actions,
            run=run, chmod=chmod)
    return records


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Run one iOS bench repeat (builds first, replays last).")
    parser.add_argument("--tools", required=True)
    parser.add_argument("--pristine", required=True,
                        help="pristine generated workspace to copy per config")
    parser.add_argument("--work", required=True,
                        help="scratch workspace dir (reset per config)")
    parser.add_argument("--out-base", required=True,
                        help="output base root; per-config base is <root>/<config>")
    parser.add_argument("--results-ref-dir", required=True)
    parser.add_argument("--rep", type=int, required=True)
    parser.add_argument("--config", action="append", default=[],
                        choices=sorted(CONFIGS),
                        help="repeatable; default is all configs in order")
    parser.add_argument("--replay-timeout", type=float, default=600.0)
    parser.add_argument("--replay-budget", type=float, default=1800.0)
    parser.add_argument("--min-clean-actions", type=int,
                        default=DEFAULT_MIN_CLEAN_ACTIONS,
                        help="clean builds executing fewer actions fail")
    args = parser.parse_args(argv)
    records = run_rep(args.tools, args.pristine, args.work, args.out_base,
                      args.results_ref_dir, args.rep, configs=args.config,
                      replay_timeout=args.replay_timeout,
                      replay_budget=args.replay_budget,
                      min_clean_actions=args.min_clean_actions)
    for config, record in records.items():
        print("config=%s rep=%d execroot=%s made_writable=%d"
              % (config, args.rep, record["execroot"],
                 record["made_writable"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
