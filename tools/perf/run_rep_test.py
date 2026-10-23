#!/usr/bin/env python3
"""Unit tests for run_rep.py (configs, ordering: builds first, replays last)."""

import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rep
from run_rep import CONFIGS, make_writable_tree, run_rep


class Proc:
    def __init__(self, returncode=0, stdout=""):
        self.returncode = returncode
        self.stdout = stdout


class FakeRun:
    """Records argv; emulates bazel build/info/shutdown and the tools."""

    def __init__(self, execroot="/fake/execroot", n_spawns=12):
        self.calls = []
        self.execroot = execroot
        self.n_spawns = n_spawns

    def __call__(self, argv, cwd=None, capture_output=False):
        self.calls.append(list(argv))
        if argv[0] == "bazel" and argv[2:4] == ["info", "execution_root"]:
            # One execroot per output base.
            base = argv[1].replace("--output_base=", "")
            return Proc(stdout=os.path.join(
                self.execroot, os.path.basename(base)) + "\n")
        if argv[0] == "bazel" and "build" in argv:
            # The real build writes the execution log; emulate it so the
            # clean-action guard has something to count.
            for arg in argv:
                if arg.startswith("--execution_log_json_file="):
                    log_path = arg.split("=", 1)[1]
                    os.makedirs(os.path.dirname(log_path), exist_ok=True)
                    with open(log_path, "w", encoding="utf-8",
                              newline="\n") as fh:
                        for _ in range(self.n_spawns):
                            fh.write(json.dumps(
                                {"mnemonic": "Genrule"}) + "\n")
            return Proc()
        if argv[0] == "bazel":
            return Proc()
        # Tool invocations: pretend to write their outputs.
        if "execlog.py" in argv[1]:
            out = argv[argv.index("--out") + 1]
            with open(out, "w", encoding="utf-8",
                      newline="\n") as fh:
                fh.write(json.dumps({"n_spawns": 1}) + "\n")
        if "replay.py" in argv[1]:
            out = argv[argv.index("--out") + 1]
            with open(out, "w", encoding="utf-8",
                      newline="\n") as fh:
                fh.write(json.dumps({"n_replayed": 1}) + "\n")
        return Proc()

    def kinds(self):
        kinds = []
        for argv in self.calls:
            if argv[0] == "bazel" and "build" in argv:
                kinds.append("build")
            elif "apply-" in (argv[2] if len(argv) > 2 else ""):
                kinds.append("edit")
            elif argv[0] == "bazel" and "shutdown" in argv:
                kinds.append("shutdown")
            elif len(argv) > 1 and "execlog.py" in argv[1]:
                kinds.append("summarize")
            elif len(argv) > 1 and "replay.py" in argv[1]:
                kinds.append("replay")
            elif "info" in argv:
                kinds.append("info")
            else:
                kinds.append("other:" + " ".join(argv))
        return kinds


class ConfigTableTest(unittest.TestCase):
    def test_two_configs_with_targets_and_flags(self):
        # device_release targets the inner framework rule: the public
        # import wrapper executes no actions of its own.
        self.assertEqual(
            CONFIGS["device_release"]["target"],
            "//app:__app_framework_framework")
        self.assertEqual(
            CONFIGS["sim_debug"]["target"], "//app:app_ios")
        device_flags = CONFIGS["device_release"]["build_flags"]
        sim_flags = CONFIGS["sim_debug"]["build_flags"]
        # Device framework builds AOT release; the simulator runs debug
        # builds only (flutter_ios_application.bzl refuses anything else).
        self.assertIn("opt", " ".join(device_flags))
        self.assertIn("--ios_multi_cpus=arm64", device_flags)
        self.assertIn("dbg", " ".join(sim_flags))
        self.assertIn("--ios_multi_cpus=sim_arm64", sim_flags)

    def test_unknown_config_rejected(self):
        with self.assertRaises(ValueError):
            run_rep("/tools", "/pristine", "/work", "/out", "/dest", 1,
                    configs=["nope"], run=FakeRun(),
                    chmod=lambda path: 0,
                    reset=lambda pristine, work: None)


class OrderingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run-rep-test-")
        self.pristine = os.path.join(self.tmp, "pristine")
        self.work = os.path.join(self.tmp, "work")
        self.dest = os.path.join(self.tmp, "results", "base")
        os.makedirs(self.pristine)
        with open(os.path.join(self.pristine, "marker.txt"), "w",
                  encoding="utf-8") as fh:
            fh.write("pristine\n")
        self.execroot = os.path.join(self.tmp, "execroot")
        for config in CONFIGS:
            os.makedirs(os.path.join(
                self.execroot, config, "bazel-out"))
        self.chmods = []
        self.resets = []

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fake_execroot(self, out_base):
        return os.path.join(
            self.execroot, os.path.basename(out_base))

    def drive(self, **kwargs):
        kwargs.setdefault("run", FakeRun(execroot=self.execroot))

        def chmod(path):
            self.chmods.append(path)
            return 0

        def reset(pristine, work):
            self.resets.append((pristine, work))
            shutil.rmtree(work, ignore_errors=True)
            shutil.copytree(pristine, work, symlinks=True)

        kwargs.setdefault("chmod", chmod)
        kwargs.setdefault("reset", reset)
        records = run_rep(
            "/tools", self.pristine, self.work, "/fake/out", self.dest, 2,
            **kwargs)
        return (kwargs["run"], records)

    def test_builds_before_replays_and_shutdown_last(self):
        fake, records = self.drive()
        kinds = fake.kinds()
        # Two configs x three scenarios.
        self.assertEqual(kinds.count("build"), 6)
        self.assertEqual(kinds.count("replay"), 6)
        self.assertEqual(sorted(records), ["device_release", "sim_debug"])
        for config, record in records.items():
            self.assertEqual(sorted(record["logs"]),
                             ["app_edit", "clean", "core_edit"])
        # Per config, no build follows the first replay.
        per_config = []
        current = []
        for argv, kind in zip(fake.calls, kinds):
            current.append(kind)
            if kind == "shutdown":
                per_config.append(current)
                current = []
        self.assertEqual(len(per_config), 2)
        for kinds_one in per_config:
            self.assertEqual(kinds_one[-1], "shutdown")
            first_replay = kinds_one.index("replay")
            self.assertNotIn("build", kinds_one[first_replay:])
            self.assertNotIn("shutdown", kinds_one[:first_replay])
            self.assertEqual(kinds_one[:2], ["build", "edit"])

    def test_work_reset_per_config(self):
        self.drive()
        self.assertEqual(
            self.resets,
            [(self.pristine, self.work)] * 2)
        self.assertTrue(os.path.isfile(
            os.path.join(self.work, "marker.txt")))

    def test_separate_output_base_per_config(self):
        fake, _ = self.drive()
        bases = [argv[1].replace("--output_base=", "")
                 for argv in fake.calls if argv[0] == "bazel"]
        self.assertTrue(bases)
        self.assertEqual(sorted(set(bases)),
                         ["/fake/out/device_release",
                          "/fake/out/sim_debug"])
        # No shared server between configs: every config's builds,
        # info and shutdown use its own base.
        self.assertEqual(
            self.chmods,
            [os.path.join(self.execroot, "device_release", "bazel-out"),
             os.path.join(self.execroot, "sim_debug", "bazel-out")])

    def test_build_flags_reach_bazel(self):
        fake, _ = self.drive()
        builds = [argv for argv in fake.calls
                  if argv[0] == "bazel" and "build" in argv]
        self.assertEqual(len(builds), 6)
        for argv in builds:
            if "//app:__app_framework_framework" in argv:
                self.assertIn("-c", argv)
                self.assertIn("opt", argv)
                self.assertIn("--ios_multi_cpus=arm64", argv)
            else:
                self.assertIn("//app:app_ios", argv)
                self.assertIn("dbg", argv)
                self.assertIn("--ios_multi_cpus=sim_arm64", argv)

    def test_results_layout_has_config(self):
        self.drive()
        for config in CONFIGS:
            for scenario in ["clean", "app_edit", "core_edit"]:
                for name in ["execlog.json", "replay.json"]:
                    path = os.path.join(self.dest, config, scenario,
                                        "rep2", name)
                    self.assertTrue(os.path.isfile(path), path)

    def test_config_subset(self):
        fake, records = self.drive(configs=["sim_debug"])
        self.assertEqual(sorted(records), ["sim_debug"])
        builds = [argv for argv in fake.calls
                  if argv[0] == "bazel" and "build" in argv]
        self.assertEqual(len(builds), 3)
        self.assertTrue(all("//app:app_ios" in argv for argv in builds))

    def test_replay_flags_forwarded(self):
        fake = FakeRun()
        run_rep("/tools", self.pristine, self.work, "/fake/out", self.dest,
                1, configs=["device_release"],
                replay_timeout=11.0, replay_budget=22.0,
                run=fake, chmod=lambda path: 0,
                reset=lambda pristine, work: None)
        replays = [c for c in fake.calls
                   if len(c) > 1 and "replay.py" in c[1]]
        self.assertEqual(len(replays), 3)
        for argv in replays:
            self.assertIn("11.0", argv[argv.index("--timeout") + 1])
            self.assertIn("22.0", argv[argv.index("--budget-seconds") + 1])

    def test_build_failure_aborts_before_replay(self):
        class FailBuild(FakeRun):
            def __call__(self, argv, cwd=None, capture_output=False):
                if argv[0] == "bazel" and "build" in argv:
                    self.calls.append(list(argv))
                    return Proc(returncode=1)
                return super().__call__(argv, cwd, capture_output)

        fake = FailBuild()
        with self.assertRaises(RuntimeError):
            run_rep("/tools", self.pristine, self.work, "/fake/out",
                    self.dest, 1, run=fake, chmod=lambda path: 0,
                    reset=lambda pristine, work: None)
        self.assertNotIn("replay", fake.kinds())

    def test_near_empty_clean_build_fails_loudly(self):
        fake = FakeRun(n_spawns=2)
        with self.assertRaisesRegex(RuntimeError, "only 2 action"):
            run_rep("/tools", self.pristine, self.work, "/fake/out",
                    self.dest, 1, run=fake, chmod=lambda path: 0,
                    reset=lambda pristine, work: None)
        self.assertNotIn("replay", fake.kinds())

    def test_min_clean_actions_override(self):
        fake = FakeRun(n_spawns=2)
        records = run_rep(
            "/tools", self.pristine, self.work, "/fake/out", self.dest, 1,
            configs=["sim_debug"], min_clean_actions=2,
            run=fake, chmod=lambda path: 0,
            reset=lambda pristine, work: None)
        self.assertEqual(sorted(records), ["sim_debug"])

    def test_missing_clean_log_fails_loudly(self):
        class NoLog(FakeRun):
            def __call__(self, argv, cwd=None, capture_output=False):
                if argv[0] == "bazel" and "build" in argv:
                    self.calls.append(list(argv))
                    return Proc()
                return super().__call__(argv, cwd, capture_output)

        fake = NoLog()
        with self.assertRaisesRegex(RuntimeError, "no execution log"):
            run_rep("/tools", self.pristine, self.work, "/fake/out",
                    self.dest, 1, run=fake, chmod=lambda path: 0,
                    reset=lambda pristine, work: None)


class ChmodTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run-rep-chmod-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_readonly_tree_becomes_writable(self):
        sub = os.path.join(self.tmp, "bazel-out", "d")
        os.makedirs(sub)
        target = os.path.join(sub, "out.o")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("x")
        os.chmod(target, stat.S_IRUSR)
        os.chmod(sub, stat.S_IRUSR | stat.S_IXUSR)
        changed = make_writable_tree(os.path.join(self.tmp, "bazel-out"))
        self.assertGreaterEqual(changed, 1)
        mode = os.stat(target).st_mode
        self.assertTrue(mode & stat.S_IWUSR)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("y")

    def test_missing_root_is_zero(self):
        self.assertEqual(
            make_writable_tree(os.path.join(self.tmp, "absent")), 0)


if __name__ == "__main__":
    unittest.main()
