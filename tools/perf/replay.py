#!/usr/bin/env python3
"""Replay iOS-only build actions under /usr/bin/time for the iOS perf bench.

For each executed spawn in a Bazel JSON execution log whose mnemonic is in
the iOS set, re-runs its command line under ``/usr/bin/time -l`` with the
logged environment overlaid, in the build's execroot (so the same inputs are
visible), and records "instructions retired" per action. macOS ``time -l``
reports that counter; other platforms leave it null.

Default iOS mnemonic set (gen_snapshot for iOS, assembler/clang and linker
steps, framework/bundle tools):

- Verified in this repo's ``flutter/`` rules: ``FlutterAotMacho``
  (gen_snapshot Mach-O for iOS), ``FlutterIOSNativeAssetFramework``,
  ``FlutterIOSRetagDylib``, ``FlutterIOSCopyAssets``,
  ``FlutterIOSStubDylib``, ``FlutterIOSDebugAssets``,
  ``FlutterStripEngine``, ``FlutterPlistMerge``,
  ``FlutterMachOVerifyProbe``.
- Apple/Clang toolchain steps (best effort; extend with ``--mnemonic`` after
  a dispatch reveals the executed-by-mnemonic table): ``CppCompile``,
  ``CppLink``, ``ObjcCompile``, ``ObjcLink``, ``SwiftCompile``, ``Lipo``.

Platform-agnostic kernel actions (``FlutterKernelCompile``,
``FlutterToolKernel``, ``FlutterAssetBundle``) are deliberately excluded:
the Linux referee bench already measures them, and replaying them would
blow the job time budget. They stay opt-in via ``--mnemonic``.

Exec-configuration (host tool) spawns — outputs under a ``-exec-``
configuration directory such as ``bazel-out/darwin_arm64-opt-exec-*/``,
which build host tools (abseil, the Swift worker) rather than the iOS
app — are skipped by default and counted as "host tools (not replayed)";
pass ``--include-exec-config`` to replay them anyway.

Apple SDK actions need ``DEVELOPER_DIR`` and ``SDKROOT``, which Bazel's
darwin spawn runner adds at execution time (as ``XcodeLocalEnvProvider``
does) and the execution log therefore never records. When the logged
environment names an Apple SDK platform (``APPLE_SDK_PLATFORM``),
``DEVELOPER_DIR`` is resolved from ``xcode-select -p`` and ``SDKROOT``
from ``xcrun --sdk <platform> --show-sdk-path``, cached per platform.

Only successful (exit 0), non-cached spawns are replayed. Each replay runs
with stdin closed and a per-action timeout, under a whole-log time budget
(``--budget-seconds``); on exhaustion the report records ``truncated=true``
plus the skipped count. The report always includes the
executed-but-not-replayed table and per-mnemonic failure counts so a broken
replay can never look like a cost drop.

Every replay records ``user_s``/``sys_s`` CPU seconds from ``time -l``
alongside instructions retired: GitHub's macOS VMs may lack a PMU, in
which case the instruction counter stays empty everywhere and replay CPU
is the fallback cost signal. Failed replays (non-zero exit or timeout)
record the exit code plus the last ``STDERR_TAIL_LINES`` lines of stderr,
and each mnemonic aggregate keeps one such sample, so the summary shows
why a replay class failed.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from execlog import load_spawns  # noqa: E402

DEFAULT_IOS_MNEMONICS = frozenset([
    "FlutterAotMacho",
    "FlutterIOSNativeAssetFramework",
    "FlutterIOSRetagDylib",
    "FlutterIOSCopyAssets",
    "FlutterIOSStubDylib",
    "FlutterIOSDebugAssets",
    "FlutterStripEngine",
    "FlutterPlistMerge",
    "FlutterMachOVerifyProbe",
    "CppCompile",
    "CppLink",
    "ObjcCompile",
    "ObjcLink",
    "SwiftCompile",
    "Lipo",
])

# Exec-configuration output directory: bazel-out/<config>-exec-<hash>/...
# builds host tools, not the app. Matched against command arguments and
# declared outputs, never source inputs (which live outside bazel-out).
EXEC_CONFIG_RE = re.compile(r"(?:^|/)bazel-out/[^/\s\"']*-exec-[^/\s\"']*/")

# Skipped-bucket label for exec-configuration spawns in the report's
# skipped_by_mnemonic table and the summary ("host tools (not replayed)").
HOST_TOOLS_SKIPPED_KEY = "host tools (not replayed)"

TIME_BIN = "/usr/bin/time"

# Kept stderr lines per failed replay: enough to diagnose a broken replay
# class (missing Xcode env, sandbox-only paths) without bloating the report.
STDERR_TAIL_LINES = 20

INSTRUCTIONS_RE = re.compile(r"^\s*([\d,]+)\s+instructions retired\s*$",
                             re.MULTILINE)
REAL_RE = re.compile(r"^\s*([\d.]+)\s+real\b", re.MULTILINE)
# macOS `time -l` prints real/user/sys on one line, so user/sys match
# mid-line; GNU `time -v` prints "User time (seconds): N" lines instead.
USER_RE = re.compile(
    r"(?:([\d.]+)\s+user\b|[Uu]ser time[^\n:]*:\s*([\d.]+))")
SYS_RE = re.compile(
    r"(?:([\d.]+)\s+sys\b|[Ss]ystem time[^\n:]*:\s*([\d.]+))")


def first_number(match):
    if match is None:
        return None
    for group in match.groups():
        if group is not None:
            return float(group)
    return None


def parse_time_l_output(text):
    """Extracts instructions-retired, wall and CPU seconds from time output.

    macOS ``time -l`` prints real/user/sys on one line; GNU ``time -v``
    prints them labelled across lines. Either way the *_s values come back
    None when the platform reports no counter.
    """
    instructions = None
    match = INSTRUCTIONS_RE.search(text or "")
    if match:
        instructions = int(match.group(1).replace(",", ""))
    real_s = None
    match = REAL_RE.search(text or "")
    if match:
        real_s = float(match.group(1))
    user_s = first_number(USER_RE.search(text or ""))
    sys_s = first_number(SYS_RE.search(text or ""))
    return (instructions, real_s, user_s, sys_s)


def tail_lines(text, limit=STDERR_TAIL_LINES):
    """Last ``limit`` lines of text (a failed replay's stderr sample)."""
    lines = (text or "").splitlines()
    return "\n".join(lines[-limit:])


def select_spawns(spawns, mnemonics, include_exec_config=False):
    """Splits spawns into (replayable, skipped) by mnemonic and status.

    Exec-configuration (host tool) spawns are skipped by default into the
    single "host tools (not replayed)" bucket; pass include_exec_config
    to replay them like any other spawn.
    """
    replayable = []
    skipped = {}
    for spawn in spawns:
        mnemonic = spawn.get("mnemonic", "")
        if not include_exec_config and is_exec_config(spawn):
            skipped[HOST_TOOLS_SKIPPED_KEY] = \
                skipped.get(HOST_TOOLS_SKIPPED_KEY, 0) + 1
            continue
        if mnemonic not in mnemonics:
            skipped[mnemonic] = skipped.get(mnemonic, 0) + 1
            continue
        if spawn.get("exitCode", 0) != 0:
            skipped["%s (exit %s)" % (mnemonic, spawn.get("exitCode"))] = \
                skipped.get("%s (exit %s)" % (mnemonic, spawn.get("exitCode")), 0) + 1
            continue
        if spawn.get("cacheHit"):
            skipped["%s (cached)" % mnemonic] = \
                skipped.get("%s (cached)" % mnemonic, 0) + 1
            continue
        if not spawn.get("commandArgs"):
            skipped["%s (no command)" % mnemonic] = \
                skipped.get("%s (no command)" % mnemonic, 0) + 1
            continue
        replayable.append(spawn)
    return (replayable, skipped)


def replay_env(spawn):
    """Logged environment overlay for a spawn ({name: value})."""
    env = {}
    for entry in spawn.get("environmentVariables") or []:
        if isinstance(entry, dict) and "name" in entry:
            env[entry["name"]] = entry.get("value", "")
    return env


def spawn_search_strings(spawn):
    """Config-marker search space: every string except source inputs.

    Covers command arguments, declared outputs, the target label and the
    logged environment; the inputs map holds source paths (never
    configuration output directories) and can be enormous, so it is
    skipped.
    """
    found = []

    def walk(value):
        if isinstance(value, str):
            found.append(value)
        elif isinstance(value, list):
            for item in value:
                walk(item)
        elif isinstance(value, dict):
            for key, item in value.items():
                if key == "inputs":
                    continue
                walk(item)

    walk(spawn)
    return found


def is_exec_config(spawn):
    """Whether the spawn builds a host tool under an -exec- config dir."""
    return any(EXEC_CONFIG_RE.search(text or "")
               for text in spawn_search_strings(spawn))


def apple_env(spawn, cache=None, runner=None):
    """Synthesizes Bazel's Xcode execution env for an Apple spawn.

    Bazel's darwin spawn runner adds DEVELOPER_DIR and SDKROOT at execution
    time (as XcodeLocalEnvProvider does), so the execution log never
    records them. When the logged environment names an Apple SDK platform
    (APPLE_SDK_PLATFORM, alongside APPLE_SDK_VERSION_OVERRIDE /
    XCODE_VERSION_OVERRIDE), DEVELOPER_DIR comes from ``xcode-select -p``
    and SDKROOT from ``xcrun --sdk <platform lowercased>
    --show-sdk-path``, cached per platform. Fail-open: without the tools
    (e.g. Linux) or on any probe failure, returns {} and the replay runs
    with the logged environment alone.
    """
    logged = replay_env(spawn)
    platform = logged.get("APPLE_SDK_PLATFORM")
    if not platform:
        return {}
    cache = cache if cache is not None else {}
    if platform in cache:
        return dict(cache[platform])

    def default_runner(argv):
        return subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=60,
            check=False,
            text=True,
        )

    run = runner or default_runner
    try:
        developer_dir = run(["xcode-select", "-p"])
        sdk_path = run(["xcrun", "--sdk", platform.lower(),
                        "--show-sdk-path"])
    except (OSError, subprocess.SubprocessError):
        return {}
    if developer_dir.returncode != 0 or sdk_path.returncode != 0:
        return {}
    synthesized = {
        "DEVELOPER_DIR": (developer_dir.stdout or "").strip(),
        "SDKROOT": (sdk_path.stdout or "").strip(),
    }
    if not synthesized["DEVELOPER_DIR"] or not synthesized["SDKROOT"]:
        return {}
    cache[platform] = synthesized
    return dict(synthesized)


def replay_argv(spawn):
    return [TIME_BIN, "-l"] + list(spawn["commandArgs"])


def run_replay(spawn, execroot, timeout, apple_cache=None, xcode_runner=None):
    """Replays one spawn; returns its record dict."""
    env = dict(os.environ)
    env.update(replay_env(spawn))
    env.update(apple_env(spawn, cache=apple_cache, runner=xcode_runner))
    try:
        proc = subprocess.run(
            replay_argv(spawn),
            cwd=execroot,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
            text=True,
        )
    except subprocess.TimeoutExpired as exc:
        return {
            "mnemonic": spawn.get("mnemonic", ""),
            "target": spawn.get("targetLabel", ""),
            "instructions": None,
            "real_s": None,
            "user_s": None,
            "sys_s": None,
            "exit_code": "timeout",
            "stderr_tail": tail_lines(
                exc.stderr.decode() if isinstance(exc.stderr, bytes)
                else exc.stderr),
            "command": spawn.get("commandArgs", []),
        }
    instructions, real_s, user_s, sys_s = parse_time_l_output(proc.stderr)
    failed = proc.returncode != 0
    return {
        "mnemonic": spawn.get("mnemonic", ""),
        "target": spawn.get("targetLabel", ""),
        "instructions": instructions,
        "real_s": real_s,
        "user_s": user_s,
        "sys_s": sys_s,
        "exit_code": proc.returncode,
        "stderr_tail": tail_lines(proc.stderr) if failed else None,
        "command": spawn.get("commandArgs", []),
    }


def is_failure(record):
    return record.get("exit_code") != 0


def aggregate_replays(records):
    by_mnemonic = {}
    for record in records:
        entry = by_mnemonic.setdefault(record["mnemonic"], {
            "count": 0,
            "failures": 0,
            "instructions_total": 0,
            "instructions_missing": 0,
            "real_s_total": 0.0,
            "user_s_total": 0.0,
            "sys_s_total": 0.0,
            "cpu_s_missing": 0,
            "sample_failure": None,
        })
        entry["count"] += 1
        if is_failure(record):
            entry["failures"] += 1
            if entry["sample_failure"] is None:
                entry["sample_failure"] = {
                    "target": record.get("target", ""),
                    "exit_code": record.get("exit_code"),
                    "stderr_tail": record.get("stderr_tail"),
                }
        if record["instructions"] is None:
            entry["instructions_missing"] += 1
        else:
            entry["instructions_total"] += record["instructions"]
        if record.get("real_s") is not None:
            entry["real_s_total"] += record["real_s"]
        if record.get("user_s") is None or record.get("sys_s") is None:
            entry["cpu_s_missing"] += 1
        else:
            entry["user_s_total"] += record["user_s"]
            entry["sys_s_total"] += record["sys_s"]
    return by_mnemonic


def replay_all(spawns, mnemonics, execroot, timeout, budget_seconds=None,
               runner=None, clock=None, include_exec_config=False,
               apple_cache=None, xcode_runner=None):
    """Selects and replays spawns under a whole-log time budget.

    Stops starting new replays once budget_seconds elapse; the report then
    carries truncated=true and the un-run actions land in
    skipped_by_mnemonic as "<mnemonic> (budget-exhausted)".
    """
    now = clock or time.monotonic
    replayable, skipped = select_spawns(
        spawns, mnemonics, include_exec_config=include_exec_config)
    skipped = dict(skipped)
    cache = apple_cache if apple_cache is not None else {}
    if runner is None:
        runner = (lambda spawn: run_replay(
            spawn, execroot, timeout, apple_cache=cache,
            xcode_runner=xcode_runner))
    records = []
    truncated = False
    start = now()
    for spawn in replayable:
        if budget_seconds is not None and now() - start >= budget_seconds:
            truncated = True
            break
        records.append(runner(spawn))
    if truncated:
        for spawn in replayable[len(records):]:
            key = "%s (budget-exhausted)" % spawn.get("mnemonic", "")
            skipped[key] = skipped.get(key, 0) + 1
    return {
        "n_replayed": len(records),
        "by_mnemonic": aggregate_replays(records),
        "skipped_by_mnemonic": skipped,
        "actions": records,
        "truncated": truncated,
        "budget_seconds": budget_seconds,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Replay iOS actions under /usr/bin/time -l.")
    parser.add_argument("--log", required=True, help="execution log path")
    parser.add_argument("--execroot", required=True,
                        help="build execroot to replay in")
    parser.add_argument("--out", required=True, help="replay JSON path")
    parser.add_argument("--mnemonic", action="append", default=[],
                        help="extra mnemonic to replay (repeatable)")
    parser.add_argument("--only-mnemonic", action="append", default=[],
                        help="replay only these mnemonics (repeatable)")
    parser.add_argument("--timeout", type=float, default=600.0,
                        help="per-action replay timeout in seconds")
    parser.add_argument("--budget-seconds", type=float, default=1800.0,
                        help="whole-log replay time budget in seconds")
    parser.add_argument("--include-exec-config", action="store_true",
                        help="also replay exec-configuration (host tool) "
                        "spawns, skipped by default")
    parser.add_argument("--dry-run", action="store_true",
                        help="print replay commands without running them")
    args = parser.parse_args(argv)
    mnemonics = set(args.only_mnemonic) if args.only_mnemonic \
        else set(DEFAULT_IOS_MNEMONICS) | set(args.mnemonic)
    spawns = load_spawns(args.log)
    if args.dry_run:
        replayable, skipped = select_spawns(
            spawns, mnemonics,
            include_exec_config=args.include_exec_config)
        for spawn in replayable:
            print("$ %s" % " ".join(replay_argv(spawn)))
        print("replayable=%d skipped=%s" % (len(replayable), skipped))
        return 0
    report = replay_all(spawns, mnemonics, args.execroot, args.timeout,
                        budget_seconds=args.budget_seconds,
                        include_exec_config=args.include_exec_config)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("replayed=%d skipped=%s" % (report["n_replayed"],
                                      report["skipped_by_mnemonic"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
