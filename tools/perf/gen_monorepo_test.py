#!/usr/bin/env python3
"""Unit tests for gen_monorepo.py (run: python3 -m unittest discover -s tools/perf)."""

import hashlib
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_monorepo
from gen_monorepo import (
    Options,
    SplitMix64,
    apply_api_edit,
    apply_app_edit,
    apply_body_edit,
    bazelrc_text,
    build_dag,
    fan_in_counts,
    generate_flutter_monorepo,
    lib_skeleton_lines,
    method_count_range,
    module_bazel_text,
    pad_file,
    render_lib_file,
)


def small_opts(**kwargs):
    params = {
        "target_loc": 20000,
        "layers": 4,
        "fanout": 2,
        "files_per_package": 8,
        "seed": 7,
        "test_ratio": 0.0,
        "edit_layer": 0,
    }
    params.update(kwargs)
    return Options(**params)


def tree_hash(root):
    digest = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            digest.update(os.path.relpath(full, root).encode())
            digest.update(b"\0")
            with open(full, "rb") as fh:
                digest.update(fh.read())
            digest.update(b"\0")
    return digest.hexdigest()


def count_dart_lines(root):
    total = 0
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".dart"):
                with open(os.path.join(dirpath, name), encoding="utf-8") as fh:
                    total += fh.read().count("\n")
    return total


class SplitMix64Test(unittest.TestCase):
    def test_deterministic_stream(self):
        a = SplitMix64(12345)
        b = SplitMix64(12345)
        self.assertEqual([a.next() for _ in range(10)],
                         [b.next() for _ in range(10)])

    def test_different_seeds_differ(self):
        a = SplitMix64(1)
        b = SplitMix64(2)
        self.assertNotEqual([a.next() for _ in range(5)],
                            [b.next() for _ in range(5)])

    def test_64bit_wrapping(self):
        rng = SplitMix64((1 << 64) - 1)
        for _ in range(100):
            self.assertLess(rng.next(), 1 << 64)

    def test_below_range(self):
        rng = SplitMix64(99)
        for _ in range(200):
            self.assertLess(rng.below(7), 7)
        with self.assertRaises(ValueError):
            rng.below(0)


class DagTest(unittest.TestCase):
    def test_acyclic_layered_fanout(self):
        dag = build_dag(20, 4, 3, 11)
        self.assertEqual(len(dag["deps"]), 20)
        for layer_idx, members in enumerate(dag["layers"]):
            lower = {p for lower in dag["layers"][:layer_idx] for p in lower}
            for pkg in members:
                self.assertEqual(dag["layer_of"][pkg], layer_idx)
                for dep in dag["deps"][pkg]:
                    self.assertIn(dep, lower)
                # Fanout floor from the seeded pass; orphan repair (v2) may
                # add edges above it so every package stays reachable.
                self.assertGreaterEqual(
                    len(dag["deps"][pkg]), min(3, len(lower)))
                self.assertEqual(dag["deps"][pkg], sorted(dag["deps"][pkg]))
                self.assertEqual(len(set(dag["deps"][pkg])),
                                 len(dag["deps"][pkg]))

    def test_layer_zero_has_no_deps(self):
        dag = build_dag(9, 3, 4, 1)
        for pkg in dag["layers"][0]:
            self.assertEqual(dag["deps"][pkg], [])

    def test_single_package(self):
        dag = build_dag(1, 8, 4, 5)
        self.assertEqual(len(dag["layers"]), 1)
        self.assertEqual(dag["deps"], [[]])


class RepairTest(unittest.TestCase):
    def test_no_orphans_below_top_layer(self):
        shapes = [(1, 8, 4), (9, 3, 4), (20, 4, 3), (40, 8, 4),
                  (60, 8, 4)]
        for n, layers, fanout in shapes:
            for seed in [1, 2, 3, 11, 99]:
                dag = build_dag(n, layers, fanout, seed)
                fan_in = fan_in_counts(dag)
                top = set(dag["layers"][-1])
                for p in range(n):
                    if p not in top:
                        self.assertGreaterEqual(
                            fan_in[p], 1,
                            "pkg%d orphaned (n=%d seed=%d)" % (p, n, seed))

    def test_repair_keeps_dag_shaped(self):
        for seed in [1, 7, 42]:
            dag = build_dag(30, 6, 3, seed)
            for layer_idx, members in enumerate(dag["layers"]):
                lower = {p for lower in dag["layers"][:layer_idx]
                         for p in lower}
                for pkg in members:
                    for dep in dag["deps"][pkg]:
                        self.assertIn(dep, lower)
                    self.assertEqual(dag["deps"][pkg],
                                     sorted(dag["deps"][pkg]))
                    self.assertEqual(len(set(dag["deps"][pkg])),
                                     len(dag["deps"][pkg]))

    def test_repair_deterministic(self):
        self.assertEqual(build_dag(30, 6, 3, 9), build_dag(30, 6, 3, 9))
        self.assertNotEqual(build_dag(30, 6, 3, 9), build_dag(30, 6, 3, 10))


class ReachabilityTest(unittest.TestCase):
    def make_plan(self, **kwargs):
        opts = small_opts(**kwargs)
        return (opts, gen_monorepo.MonorepoPlan(opts, 12))

    def test_main_calls_every_top_layer_entry(self):
        opts, plan = self.make_plan()
        main = gen_monorepo.render_app_main(plan.top_layer())
        for a in plan.top_layer():
            self.assertIn("entry%d(3, probe)" % a, main)
        # Unfoldable-but-false-at-runtime guard source.
        self.assertIn("int.tryParse('probe') ?? 0", main)
        # Entry results flow to a reachable use.
        self.assertIn("$reach", main)

    def test_entry_calls_deps_and_own_functions(self):
        opts, plan = self.make_plan()
        n = len(plan.dag["deps"])
        for p in range(n):
            body = gen_monorepo.render_entrypoint(
                p, opts.files_per_package, plan.dag["deps"][p])
            self.assertIn("int entry%d(int x, int probe)" % p, body)
            for d in plan.dag["deps"][p]:
                self.assertIn("entry%d(x, probe)" % d, body)
            if plan.dag["deps"][p]:
                self.assertIn("if (probe != 0) {", body)
            for f in range(opts.files_per_package):
                self.assertIn("fn%dx%d(x)" % (p, f), body)
                self.assertIn("value%dx%d()" % (p, f), body)
                widget = "W" if f % 2 == 0 else "S"
                self.assertIn(
                    "%s%dx%d(value: 1)" % (widget, p, f), body)
        self.assertTrue(
            any(plan.dag["deps"]),
            "expected at least one package with dependencies")

    def test_entry_imports_dependency_entries(self):
        opts, plan = self.make_plan()
        for p, deps in enumerate(plan.dag["deps"]):
            body = gen_monorepo.render_entrypoint(
                p, opts.files_per_package, deps)
            for d in deps:
                self.assertIn(
                    "import 'package:pkg%d/pkg%d.dart';" % (d, d), body)

    def test_every_package_reachable_from_main_through_dag(self):
        for seed in [1, 7, 42]:
            opts = small_opts(seed=seed)
            plan = gen_monorepo.MonorepoPlan(opts, 15)
            seen = set(plan.top_layer())
            stack = list(plan.top_layer())
            while stack:
                pkg = stack.pop()
                for dep in plan.dag["deps"][pkg]:
                    if dep not in seen:
                        seen.add(dep)
                        stack.append(dep)
            self.assertEqual(seen, set(range(len(plan.dag["deps"]))),
                             "seed %d" % seed)

    def test_edit_target_reachable(self):
        tmp = tempfile.mkdtemp(prefix="gen-mono-reach-")
        try:
            rules_dir = os.path.join(tmp, "rules")
            os.makedirs(rules_dir)
            ws = os.path.join(tmp, "ws")
            generate_flutter_monorepo(ws, rules_dir, [], small_opts())
            with open(os.path.join(ws, "bench-edit-manifest.json"),
                      encoding="utf-8") as fh:
                rel = json.load(fh)["body_edit"]
            pkg = int(rel.split("/")[1].replace("pkg", ""))
            with open(os.path.join(ws, "packages/pkg%d/lib/pkg%d.dart"
                                    % (pkg, pkg)),
                      encoding="utf-8") as fh:
                entry = fh.read()
            # The edited file is f0: its value function is called from the
            # package entry, and the package is reachable from main.
            self.assertIn("value%dx0()" % pkg, entry)
            with open(os.path.join(ws, "bench-workspace-stats.json"),
                      encoding="utf-8") as fh:
                n_packages = json.load(fh)["packages"]
            opts = small_opts()
            plan = gen_monorepo.MonorepoPlan(opts, n_packages)
            seen = set(plan.top_layer())
            stack = list(plan.top_layer())
            while stack:
                member = stack.pop()
                for dep in plan.dag["deps"][member]:
                    if dep not in seen:
                        seen.add(dep)
                        stack.append(dep)
            self.assertIn(pkg, seen)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class SizingTest(unittest.TestCase):
    def test_pad_file_width(self):
        self.assertEqual(pad_file(8, 0), "0")
        self.assertEqual(pad_file(8, 7), "7")
        self.assertEqual(pad_file(12, 8), "08")
        self.assertEqual(pad_file(40, 39), "39")
        self.assertEqual(pad_file(200, 7), "007")

    def test_method_count_range_in_100_to_150(self):
        for dep_count in range(5):
            for flags in range(8):
                skeleton = lib_skeleton_lines(
                    bool(flags & 1), dep_count, bool(flags & 2),
                    bool(flags & 4))
                min_m, max_m = method_count_range(skeleton)
                self.assertGreaterEqual(min_m, 1)
                self.assertGreaterEqual(max_m, min_m)
                self.assertGreaterEqual(skeleton + 8 * min_m, 100)
                self.assertLessEqual(skeleton + 8 * max_m, 150)

    def test_skeleton_matches_template_for_every_shape(self):
        shapes = [
            (0, []), (0, [0]), (1, []), (1, [0, 1]), (1, [0, 1, 2]),
            (8, [0]), (9, [1, 3]),
        ]
        for file, deps in shapes:
            skeleton = lib_skeleton_lines(
                file > 0, len(deps), file % 8 == 0, file % 2 == 1)
            for methods in [1, 3, 7]:
                rendered = render_lib_file(5, file, 12, deps, methods)
                self.assertEqual(
                    rendered.count("\n"), skeleton + 8 * methods,
                    "shape f%d deps%s methods%d" % (file, deps, methods))

    def test_rendered_files_in_100_to_150(self):
        opts = small_opts()
        plan = gen_monorepo.MonorepoPlan(opts, 12)
        for p in range(12):
            for f in range(opts.files_per_package):
                content = render_lib_file(
                    p, f, opts.files_per_package, plan.dag["deps"][p],
                    plan.method_counts[p][f])
                lines = content.count("\n")
                self.assertGreaterEqual(lines, 100, "pkg%d f%d" % (p, f))
                self.assertLessEqual(lines, 150, "pkg%d f%d" % (p, f))


class GenerationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gen-mono-test-")
        self.rules_dir = os.path.join(self.tmp, "rules")
        os.makedirs(self.rules_dir)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def generate(self, name, **kwargs):
        out = os.path.join(self.tmp, name)
        stats = generate_flutter_monorepo(
            out, self.rules_dir, [], small_opts(**kwargs))
        return (out, stats)

    def test_byte_identical_for_same_inputs(self):
        out1, _ = self.generate("a")
        out2, _ = self.generate("b")
        self.assertEqual(tree_hash(out1), tree_hash(out2))

    def test_different_seed_differs(self):
        out1, _ = self.generate("a", seed=7)
        out2, _ = self.generate("b", seed=8)
        self.assertNotEqual(tree_hash(out1), tree_hash(out2))

    def test_loc_within_tolerance(self):
        for target in [20000, 60000]:
            out, stats = self.generate("t%d" % target, target_loc=target)
            lines = count_dart_lines(out)
            self.assertEqual(lines, stats["lines"])
            self.assertGreaterEqual(lines, int(target * 0.95))
            self.assertLessEqual(lines, int(target * 1.05))

    def test_stats_and_manifest(self):
        out, stats = self.generate("a")
        self.assertEqual(stats["generator"], "flutter-monorepo")
        self.assertEqual(stats["generator_version"], 2)
        self.assertGreater(stats["packages"], 0)
        self.assertGreater(stats["files"], 0)
        self.assertGreater(stats["targets"], 0)
        with open(os.path.join(out, "bench-workspace-stats.json"),
                  encoding="utf-8") as fh:
            on_disk = json.load(fh)
        self.assertEqual(on_disk, stats)
        with open(os.path.join(out, "bench-edit-manifest.json"),
                  encoding="utf-8") as fh:
            manifest = json.load(fh)
        for key in ["body_edit", "api_edit", "app_main"]:
            self.assertIn(key, manifest)
            full = os.path.join(out, manifest[key])
            self.assertTrue(os.path.isfile(full), key)
        # Edit target lives in layer 0 with maximal fan-in.
        dag = build_dag(stats["packages"], 4, 2, 7)
        fan_in = fan_in_counts(dag)
        layer0 = dag["layers"][0]
        best = max(fan_in[p] for p in layer0)
        edited_pkg = int(
            manifest["body_edit"].split("/")[1].replace("pkg", ""))
        self.assertIn(edited_pkg, layer0)
        self.assertEqual(fan_in[edited_pkg], best)

    def test_scaffolding_layout(self):
        out, _ = self.generate("a")
        for rel in ["MODULE.bazel", "BUILD.bazel", ".bazelrc",
                    ".bazelversion", "pubspec.yaml", "pubspec.lock",
                    "analysis_options.yaml", "app/BUILD.bazel",
                    "app/lib/main.dart"]:
            self.assertTrue(os.path.isfile(os.path.join(out, rel)), rel)
        with open(os.path.join(out, "app/BUILD.bazel"),
                  encoding="utf-8") as fh:
            app_build = fh.read()
        for target in ["flutter_application", "flutter_ios_app",
                       "flutter_ios_framework_gen",
                       "flutter_ios_simulator_build_test"]:
            self.assertIn(target, app_build)
        self.assertIn("name = \"app_framework\"", app_build)
        self.assertNotIn("android", app_build.lower())

    def test_options_validation(self):
        with self.assertRaises(ValueError):
            Options(target_loc=0)
        with self.assertRaises(ValueError):
            Options(target_loc=100, layers=0)
        with self.assertRaises(ValueError):
            Options(target_loc=100, files_per_package=0)
        with self.assertRaises(ValueError):
            Options(target_loc=100, test_ratio=1.5)
        with self.assertRaises(ValueError):
            Options(target_loc=100, layers=2, edit_layer=2)
        with self.assertRaises(ValueError):
            generate_flutter_monorepo(
                os.path.join(self.tmp, "x"), "/nonexistent", [],
                small_opts())


class ModuleTextTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gen-mono-mod-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_fake_fixture(self):
        hello = os.path.join(self.tmp, "rules", "e2e", "hello_world")
        os.makedirs(hello)
        with open(os.path.join(hello, "MODULE.bazel"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("module(name = \"rules_flutter_hello_world\")\n"
                     "local_path_override(\n"
                     "    module_name = \"rules_flutter\",\n"
                     "    path = \"../..\",\n"
                     ")\n")
        return os.path.join(self.tmp, "rules")

    def test_fixture_substitution(self):
        rules = self.write_fake_fixture()
        text = module_bazel_text(rules, [])
        self.assertIn("module(name = \"bench_monorepo\")", text)
        self.assertIn("path = \"%s\"," % rules, text)
        self.assertNotIn("../..", text)

    def test_extra_override_appended(self):
        rules = self.write_fake_fixture()
        text = module_bazel_text(
            rules, [("rules_dart", "/elsewhere/rules_dart")])
        self.assertIn("module_name = \"rules_dart\"", text)
        self.assertIn("/elsewhere/rules_dart", text)

    def test_fallback_module_without_fixture(self):
        rules = os.path.join(self.tmp, "empty-rules")
        os.makedirs(rules)
        text = module_bazel_text(rules, [])
        self.assertIn("module(name = \"bench_monorepo\")", text)
        self.assertIn("path = \"%s\"," % rules, text)

    def test_bazelrc_filtering(self):
        self.assertIn("common --lockfile_mode=off\n",
                      bazelrc_text("/nonexistent"))
        rules = self.write_fake_fixture()
        hello = os.path.join(rules, "e2e", "hello_world")
        with open(os.path.join(hello, ".bazelrc"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("common --lockfile_mode=off\n"
                     "common --@rules_flutter//flutter:extra_dart_defines=X\n"
                     "test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze\n")
        text = bazelrc_text(rules)
        self.assertNotIn("extra_dart_defines", text)
        self.assertIn("common --lockfile_mode=off\n", text)


class EditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gen-mono-edit-")
        self.rules_dir = os.path.join(self.tmp, "rules")
        os.makedirs(self.rules_dir)
        self.ws = os.path.join(self.tmp, "ws")
        generate_flutter_monorepo(self.ws, self.rules_dir, [],
                                 small_opts())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def read_manifest_target(self, key):
        with open(os.path.join(self.ws, "bench-edit-manifest.json"),
                  encoding="utf-8") as fh:
            rel = json.load(fh)[key]
        with open(os.path.join(self.ws, rel), encoding="utf-8") as fh:
            return (rel, fh.read())

    def test_body_edit_keeps_api(self):
        rel, original = self.read_manifest_target("body_edit")
        backup = apply_body_edit(self.ws)
        self.assertEqual(backup, original)
        with open(os.path.join(self.ws, rel), encoding="utf-8") as fh:
            edited = fh.read()
        self.assertNotEqual(edited, original)
        # No public member added: outline-affecting lines unchanged.
        for line in edited.split("\n"):
            if line.startswith("  int get extra") or \
                    line.startswith("int addedApi"):
                self.fail("body edit changed the API")

    def test_api_edit_adds_member(self):
        rel, original = self.read_manifest_target("api_edit")
        apply_api_edit(self.ws)
        with open(os.path.join(self.ws, rel), encoding="utf-8") as fh:
            edited = fh.read()
        self.assertNotEqual(edited, original)
        self.assertIn("extra", edited)

    def test_app_edit_changes_main(self):
        with open(os.path.join(self.ws, "app/lib/main.dart"),
                  encoding="utf-8") as fh:
            original = fh.read()
        apply_app_edit(self.ws)
        with open(os.path.join(self.ws, "app/lib/main.dart"),
                  encoding="utf-8") as fh:
            edited = fh.read()
        self.assertNotEqual(edited, original)
        self.assertIn("+ 1", edited)

    def test_edits_fail_closed(self):
        os.remove(os.path.join(self.ws, "bench-edit-manifest.json"))
        with self.assertRaises(Exception):
            apply_body_edit(self.ws)


if __name__ == "__main__":
    unittest.main()
