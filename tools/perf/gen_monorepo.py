#!/usr/bin/env python3
"""Layered Flutter monorepo workspace generator for the iOS perf bench.

Generates a deterministic monorepo-shaped Flutter workspace sized by total
Dart lines of code (``target_loc``), mirroring the manager referee's
``flutter-monorepo`` generator knobs (``target_loc``, ``layers`` default 8,
``fanout`` default 4, ``files_per_package`` default 20, ``seed``):

- Packages spread over ``layers`` (layer 0 holds core/util packages with high
  fan-in, upper layers hold feature packages). Each package above layer 0
  depends on ``fanout`` packages from strictly lower layers (seeded PRNG), so
  the graph is acyclic by construction.
- Every library file is 100-150 lines of realistic Dart (documented enum,
  generic class with chained methods, extension, a widget, imports from the
  own package and from dependencies, ``part`` files in every eighth library).
  The same inputs give a byte-identical tree.
- One ``flutter_library`` per package plus an ``app/`` package with a
  ``flutter_application`` and the Tier-1 iOS app targets
  (``flutter_ios_app`` + an explicit ``flutter_ios_framework_gen``
  App.framework target + simulator build test). This bench measures iOS only,
  so unlike the referee generator there is no Android app and no
  ``flutter_test`` targets unless ``--test-ratio`` asks for them.
- Reachability (generator v2): each package entry calls its direct
  dependencies' entries and every own file's functions (including the
  value functions the bench edits) and constructs every own file's
  widget; ``main`` calls every top-layer entry. Cross-package calls are
  guarded by a probe main reads from a runtime source the compiler
  cannot fold that is zero at run time, so AOT tree-shaking keeps the
  whole program without running it.
- An edit manifest (``bench-edit-manifest.json``) records the file the
  ``body_edit``/``api_edit`` scenarios edit, and a stats file
  (``bench-workspace-stats.json``) records the workspace statistics.

Only the Python 3 standard library is used. Generation streams files to disk
(one file in memory at a time) so large workspaces stay fast.

Scaffolding (MODULE.bazel, pub files, .bazelrc, the ``ios/Runner/`` scaffold
the Tier-1 ``flutter_ios_app`` discovers) is derived from the
``e2e/hello_world`` fixture of the ``--rules-flutter`` checkout, so hermetic
pins can never drift from what ``rules_flutter`` main verifies.
"""

import argparse
import json
import os
import shutil
import sys

MASK64 = (1 << 64) - 1

STATS_REL_PATH = "bench-workspace-stats.json"
EDIT_MANIFEST_REL_PATH = "bench-edit-manifest.json"

DEFAULT_LAYERS = 8
DEFAULT_FANOUT = 4
DEFAULT_FILES_PER_PACKAGE = 20
DEFAULT_TEST_RATIO = 0.0
DEFAULT_EDIT_LAYER = 0
LOC_TOLERANCE = 0.05


# --------------------------------------------------------------------------
# Deterministic PRNG (splitmix64, same stream shape as the referee generator).


class SplitMix64:
    """Small deterministic PRNG. Same seed yields the same stream everywhere."""

    def __init__(self, state):
        self.state = state & MASK64

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def below(self, n):
        if n <= 0:
            raise ValueError("SplitMix64.below requires n >= 1")
        return self.next() % n


def file_rng(seed, package, file):
    """Per-file PRNG stream derived from the workspace seed (deterministic)."""
    return SplitMix64(seed + package * 1000003 + file * 1000033 + 0xA5A5A5A5)


# --------------------------------------------------------------------------
# Package DAG.


def repair_orphans(deps, layer_vecs, layer_count, seed):
    """Attaches every unreachable package to a higher-layer dependent.

    Generator v2 needs every package below the top layer reachable from
    main through the DAG (each entry calls its dependencies' entries, main
    calls the top layer). The seeded fanout above can leave a package with
    no dependents; such an orphan gains one edge from a package in a
    strictly higher layer, drawn from a fresh seeded stream so the main
    fanout stream is undisturbed. Top-layer packages need no repair: main
    calls them all directly. Edges stay sorted, unique, and downward, so
    the graph remains an acyclic layered DAG.
    """
    if layer_count < 2:
        return
    fan_in = [0] * len(deps)
    for edges in deps:
        for d in edges:
            fan_in[d] += 1
    rng = SplitMix64((seed ^ 0x0B971E) & MASK64)
    for layer in range(layer_count - 1):
        higher = [q for upper in layer_vecs[layer + 1:] for q in upper]
        for pkg in layer_vecs[layer]:
            if fan_in[pkg] > 0:
                continue
            dependent = higher[rng.below(len(higher))]
            deps[dependent].append(pkg)
            deps[dependent].sort()
            fan_in[pkg] += 1


def build_dag(n_packages, layers, fanout, seed):
    """Layered DAG: deps[p] holds the sorted direct deps of package p.

    Packages spread over min(layers, n_packages) layers (extras go to the top
    layers); each package above layer 0 depends on min(fanout, lower_count)
    distinct packages from strictly lower layers. A repair pass then gives
    every package below the top layer at least one dependent (generator v2
    reachability), adding the minimum edges to packages that fanout left
    orphaned.
    """
    if n_packages < 1:
        raise ValueError("build_dag requires n_packages >= 1")
    layer_count = max(1, min(layers, n_packages))
    base = n_packages // layer_count
    rem = n_packages % layer_count

    layer_vecs = []
    layer_of = [0] * n_packages
    next_pkg = 0
    for layer in range(layer_count):
        size = base + (1 if layer >= layer_count - rem else 0)
        members = []
        for _ in range(size):
            layer_of[next_pkg] = layer
            members.append(next_pkg)
            next_pkg += 1
        layer_vecs.append(members)

    rng = SplitMix64((seed ^ 0x51F15EED) & MASK64)
    deps = [[] for _ in range(n_packages)]
    for layer in range(1, layer_count):
        # Candidate pool: every package in a strictly lower layer. Built once
        # per layer; the per-package partial Fisher-Yates mutates it in place
        # through the shared seeded stream.
        candidates = [p for lower in layer_vecs[:layer] for p in lower]
        for pkg in layer_vecs[layer]:
            want = min(fanout, len(candidates))
            for j in range(want):
                k = j + rng.below(len(candidates) - j)
                candidates[j], candidates[k] = candidates[k], candidates[j]
            deps[pkg] = sorted(candidates[:want])

    repair_orphans(deps, layer_vecs, layer_count, seed)

    return {"deps": deps, "layer_of": layer_of, "layers": layer_vecs}


def fan_in_counts(dag):
    fan_in = [0] * len(dag["deps"])
    for deps in dag["deps"]:
        for d in deps:
            fan_in[d] += 1
    return fan_in


def fan_stats(values):
    if not values:
        return {"max": 0, "mean": 0.0, "min": 0}
    return {
        "max": max(values),
        "mean": sum(values) / len(values),
        "min": min(values),
    }


def pick_test_packages(n_packages, test_ratio, seed):
    """Seeded shuffle picking round(n * test_ratio) packages for flutter_test."""
    selected = [False] * n_packages
    k = min(int(round(n_packages * test_ratio)), n_packages)
    if k == 0:
        return selected
    rng = SplitMix64((seed ^ 0x7E57) & MASK64)
    order = list(range(n_packages))
    for j in range(k):
        swap = j + rng.below(n_packages - j)
        order[j], order[swap] = order[swap], order[j]
        selected[order[j]] = True
    return selected


# --------------------------------------------------------------------------
# File sizing.


def method_count_range(skeleton_lines):
    """Admissible method-count range keeping the file total in [100, 150]."""
    under = max(0, 100 - skeleton_lines)
    min_m = max(1, (under + 7) // 8)
    over = max(0, 150 - skeleton_lines)
    max_m = max(min_m, over // 8)
    return (min_m, max_m)


def method_count_for(rng, skeleton_lines):
    min_m, max_m = method_count_range(skeleton_lines)
    if max_m <= min_m:
        return min_m
    return min_m + rng.below(max_m - min_m + 1)


def pad_file(files_per_package, file):
    width = max(1, len(str(files_per_package - 1)))
    return str(file).zfill(width)


def lib_skeleton_lines(has_sibling, dep_count, has_part, odd_file):
    """Exact non-method line count of render_lib_file for the given shape.

    Must stay in lockstep with the template; unit tests cross-check it.
    """
    # Base: material import (1) + blank (1) + file doc (1) + enum
    # (header + 4 documented values + close = 10) + blank (1) + extension
    # (16) + blank (1) + class (19) + close (1) + blank (1) + stateless
    # widget (13) + blank (1) + value function (7) + helper (6).
    lines = 79
    if has_sibling:
        lines += 1  # sibling package: import
        lines += 1  # sibling call in fn
    if dep_count > 0:
        lines += dep_count  # dep imports
        lines += 2 * dep_count + 1  # per-dep doc + typedef + blank
    if has_part:
        lines += 1  # part directive
    if odd_file:
        lines += 21  # stateful widget block is 21 lines larger
    return lines


# --------------------------------------------------------------------------
# Dart rendering.


def render_lib_file(package, file, files_per_package, deps, method_count):
    """One library file: package: imports only, enum, extension, generic class.

    Layout (100-150 lines): a documented enum, a generic class with
    method_count chained methods, one widget (stateless on even files,
    stateful on odd files), a public value function and a local helper. The
    class carries the api_edit marker ("  /// The value.") and the value
    function the body_edit marker ("  var total = 1;").
    """
    has_sibling = file > 0
    has_part = file % 8 == 0
    odd_file = file % 2 == 1
    factor = file + 2
    pad = pad_file(files_per_package, file)

    imports = ["import 'package:flutter/material.dart';"]
    for d in deps:
        imports.append("import 'package:pkg%d/pkg%d.dart';" % (d, d))
    if has_sibling:
        imports.append(
            "import 'package:pkg%d/src/f%s.dart';"
            % (package, pad_file(files_per_package, file - 1))
        )
    imports.sort()

    out = []
    out.extend(imports)
    out.append("")
    if has_part:
        out.append("part 'f%s.part.dart';" % pad)
    if deps:
        dep_lines = sorted(
            "import 'package:pkg%d/pkg%d.dart';" % (d, d) for d in deps
        )
        for line in dep_lines:
            d = int(line.split("pkg")[1].split("/")[0])
            out.append("/// Dependency API of package pkg%d used here." % d)
            out.append("typedef D%dx%dA%d = C%dx0<int>;" % (package, file, d, d))
        out.append("")
    out.append("/// File %d of package %d." % (file, package))
    out.append("enum E%dx%d {" % (package, file))
    for value, kind in [
        ("alpha", "First"),
        ("beta", "Second"),
        ("gamma", "Third"),
        ("delta", "Fourth"),
    ]:
        out.append("  /// %s kind." % kind)
        out.append("  %s," % value)
    out.append("}")
    out.append("")
    out.append("/// Extension on [E%dx%d]." % (package, file))
    out.append("extension E%dx%dExt on E%dx%d {" % (package, file, package, file))
    out.append("  /// Describe this value.")
    out.append("  String describe() {")
    out.append("    switch (this) {")
    for value in ["alpha", "beta", "gamma", "delta"]:
        out.append("      case E%dx%d.%s:" % (package, file, value))
        out.append("        return 'p%df%d:%s';" % (package, file, value))
    out.append("    }")
    out.append("  }")
    out.append("}")
    out.append("")
    out.append("/// Boxed value %d of package %d." % (file, package))
    if has_part:
        out.append("class C%dx%d<T> with M%dx%d {" % (package, file, package, file))
    else:
        out.append("class C%dx%d<T> {" % (package, file))
    out.append("  /// Creates the value holder.")
    out.append("  C%dx%d(this.value, [this.tag, this.payload]);" % (package, file))
    out.append("")
    out.append("  /// The value.")
    out.append("  final int value;")
    out.append("")
    out.append("  /// The tag.")
    out.append("  final E%dx%d? tag;" % (package, file))
    out.append("")
    out.append("  /// The extra payload.")
    out.append("  final T? payload;")
    out.append("")
    out.append("  /// Describe this holder.")
    out.append("  String describe() => 'C%dx%d($value)';" % (package, file))
    out.append("")
    out.append("  /// Pick an item.")
    out.append("  T? pick(List<T> items) => items.isEmpty ? null : items.first;")
    for m in range(method_count):
        tail = " + m%d(x)" % (m + 1) if m + 1 < method_count else ""
        out.append("  /// Method %d of C%dx%d." % (m, package, file))
        out.append("  int m%d(int x) {" % m)
        out.append("    var total = x + value;")
        out.append("    for (var i = 0; i < x; i++) {")
        out.append("      total += i * %d;" % factor)
        out.append("    }")
        out.append("    return total%s;" % tail)
        out.append("  }")
    out.append("}")
    out.append("")
    if odd_file:
        out.extend(render_stateful_widget(package, file))
    else:
        out.append("/// Widget %d of package %d." % (file, package))
        out.append("class W%dx%d extends StatelessWidget {" % (package, file))
        out.append("  /// Creates the widget.")
        out.append("  const W%dx%d({super.key, this.value = 0});" % (package, file))
        out.append("")
        out.append("  /// The number shown.")
        out.append("  final int value;")
        out.append("")
        out.append("  @override")
        out.append("  Widget build(BuildContext context) {")
        out.append(
            "    return Text('pkg%d f%d: $value ${value%dx%d()}');"
            % (package, file, package, file)
        )
        out.append("  }")
        out.append("}")
    out.append("")
    out.append("/// Plain value of file %d of package %d." % (file, package))
    out.append("int value%dx%d() {" % (package, file))
    out.append("  var total = 1;")
    out.append("  total += fn%dx%d(%d);" % (package, file, file + 1))
    out.append("  return total % 1000003;")
    out.append("}")
    out.append("")
    out.append("/// Local helper of file %d of package %d." % (file, package))
    out.append("int fn%dx%d(int x) {" % (package, file))
    out.append("  var total = x + 1;")
    out.append(
        "  total += C%dx%d<int>(total).m0(total %% 7);" % (package, file)
    )
    if has_sibling:
        out.append("  total += fn%dx%d(x);" % (package, file - 1))
    out.append("  return total;")
    out.append("}")
    return "\n".join(out) + "\n"


def render_stateful_widget(package, file):
    """Stateful widget block of a library file (odd files only)."""
    p, f = package, file
    return [
        "/// Stateful widget %d of package %d." % (f, p),
        "class S%dx%d extends StatefulWidget {" % (p, f),
        "  /// Creates the widget.",
        "  const S%dx%d({super.key, this.value = 0});" % (p, f),
        "",
        "  /// The number shown.",
        "  final int value;",
        "",
        "  @override",
        "  State<S%dx%d> createState() => _S%dx%dState();" % (p, f, p, f),
        "}",
        "",
        "/// State of [S%dx%d]." % (p, f),
        "class _S%dx%dState extends State<S%dx%d> {" % (p, f, p, f),
        "  int _counter = 0;",
        "",
        "  /// Increments the counter.",
        "  void incrementCounter() {",
        "    setState(() {",
        "      _counter++;",
        "    });",
        "  }",
        "",
        "  @override",
        "  Widget build(BuildContext context) {",
        "    return Column(",
        "      mainAxisSize: MainAxisSize.min,",
        "      children: [",
        "        Text('pkg%d f%d: ${widget.value} ${value%dx%d()} $_counter'),"
        % (p, f, p, f),
        "        TextButton(onPressed: incrementCounter, child: const Text('+')),",
        "      ],",
        "    );",
        "  }",
        "}",
    ]


def render_part_file(package, file, files_per_package):
    pad = pad_file(files_per_package, file)
    return "\n".join(
        [
            "part of 'f%s.dart';" % pad,
            "",
            "/// Mixin for [C%dx%d]." % (package, file),
            "mixin M%dx%d {" % (package, file),
            "  /// Adjust a value.",
            "  int adjust(int x) => x + 1;",
            "}",
        ]
    ) + "\n"


def render_entrypoint(package, files_per_package, deps):
    """Package entry point: own files' functions plus dependencies' entries.

    Calls every own file's helper and value functions (including the value
    functions the bench edits) and constructs every own file's widget, all
    unconditionally, so any body_edit in the package changes the AOT
    program. Cross-package calls to the direct dependencies' entries are
    guarded by [probe]: main passes a value from a runtime source the
    compiler cannot fold that is zero at run time, so the whole transitive
    closure stays reachable for AOT tree-shaking without running.
    """
    imports = [
        "import 'package:pkg%d/src/f%s.dart';"
        % (package, pad_file(files_per_package, f))
        for f in range(files_per_package)
    ]
    imports.extend(
        "import 'package:pkg%d/pkg%d.dart';" % (d, d) for d in deps
    )
    imports.sort()
    out = ["/// Public API of package pkg%d." % package]
    out.extend(imports)
    for f in range(files_per_package):
        out.append("export 'src/f%s.dart';" % pad_file(files_per_package, f))
    out.append("")
    out.append("/// Entry point of package %d." % package)
    out.append("///")
    out.append("/// Calls every own file's functions and — guarded by [probe]")
    out.append("/// — the direct dependencies' entries.")
    out.append("int entry%d(int x, int probe) {" % package)
    out.append("  var total = x;")
    for f in range(files_per_package):
        out.append("  total += fn%dx%d(x);" % (package, f))
    for f in range(files_per_package):
        out.append("  total += value%dx%d();" % (package, f))
    for f in range(files_per_package):
        widget = "W" if f % 2 == 0 else "S"
        out.append(
            "  total += const %s%dx%d(value: 1).value;" % (widget, package, f)
        )
    if deps:
        out.append("  if (probe != 0) {")
        for d in deps:
            out.append("    total += entry%d(x, probe);" % d)
        out.append("  }")
    out.append("  return total;")
    out.append("}")
    return "\n".join(out) + "\n"


def render_test_file(package):
    return "\n".join(
        [
            "import 'package:flutter/material.dart';",
            "import 'package:flutter_test/flutter_test.dart';",
            "import 'package:pkg%d/pkg%d.dart';" % (package, package),
            "",
            "void main() {",
            "  testWidgets('W%dx0 renders in a MaterialApp', (tester) async {"
            % package,
            "    await tester.pumpWidget(",
            "      const MaterialApp(home: Scaffold(body: W%dx0(value: 1))),"
            % package,
            "    );",
            "    expect(find.byType(W%dx0), findsOneWidget);" % package,
            "    expect(value%dx0(), greaterThan(0));" % package,
            "  });",
            "}",
        ]
    ) + "\n"


def render_app_main(top_layer):
    """Application entrypoint wiring every top-layer feature package.

    Builds every top-layer package's widget and calls every top-layer
    package's entry point with a probe main reads from a runtime source
    (`int.tryParse` on a non-numeric literal is always null here, so the
    probe is zero at run time) the compiler cannot fold, keeping the
    guarded cross-package calls reachable for AOT tree-shaking. The summed
    entry results flow into a displayed string, so edited functions below
    the top layer have a reachable use.
    """
    out = ["import 'package:flutter/material.dart';"]
    dep_imports = sorted(
        "import 'package:pkg%d/pkg%d.dart';" % (a, a) for a in top_layer
    )
    out.extend(dep_imports)
    out.append("")
    out.append("/// Bench application wiring the top-layer feature packages.")
    out.append("void main() {")
    out.append("  final int probe = int.tryParse('probe') ?? 0;")
    out.append("  var reach = 0;")
    for a in top_layer:
        out.append("  reach += entry%d(3, probe);" % a)
    out.append("  runApp(")
    out.append("    MaterialApp(")
    out.append("      home: Scaffold(")
    out.append("        body: Center(")
    out.append("          child: Column(")
    out.append("            mainAxisSize: MainAxisSize.min,")
    out.append("            children: [")
    for a in top_layer:
        out.append("              W%dx0(value: value%dx0())," % (a, a))
    out.append("              Text('reach: $reach'),")
    out.append("            ],")
    out.append("          ),")
    out.append("        ),")
    out.append("      ),")
    out.append("    ),")
    out.append("  );")
    out.append("}")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# Plan, tuning, rendering to disk.


class Options:
    def __init__(
        self,
        target_loc,
        layers=DEFAULT_LAYERS,
        fanout=DEFAULT_FANOUT,
        files_per_package=DEFAULT_FILES_PER_PACKAGE,
        seed=1,
        test_ratio=DEFAULT_TEST_RATIO,
        edit_layer=DEFAULT_EDIT_LAYER,
    ):
        if target_loc < 1:
            raise ValueError("target_loc must be >= 1")
        if layers < 1:
            raise ValueError("layers must be >= 1")
        if files_per_package < 1:
            raise ValueError("files_per_package must be >= 1")
        if not 0.0 <= test_ratio <= 1.0:
            raise ValueError("test_ratio must be in [0.0, 1.0]")
        if edit_layer >= layers:
            raise ValueError("edit_layer must be < layers")
        self.target_loc = target_loc
        self.layers = layers
        self.fanout = fanout
        self.files_per_package = files_per_package
        self.seed = seed
        self.test_ratio = test_ratio
        self.edit_layer = edit_layer


class MonorepoPlan:
    def __init__(self, opts, n_packages):
        self.dag = build_dag(n_packages, opts.layers, opts.fanout, opts.seed)
        self.has_test = pick_test_packages(
            n_packages, opts.test_ratio, opts.seed
        )
        self.method_counts = []
        for p in range(n_packages):
            counts = []
            for f in range(opts.files_per_package):
                rng = file_rng(opts.seed, p, f)
                skeleton = lib_skeleton_lines(
                    f > 0, len(self.dag["deps"][p]), f % 8 == 0, f % 2 == 1
                )
                counts.append(method_count_for(rng, skeleton))
            self.method_counts.append(counts)

        edit_layer = min(opts.edit_layer, len(self.dag["layers"]) - 1)
        fan_in = fan_in_counts(self.dag)
        edit_pkg = self.dag["layers"][edit_layer][0]
        for pkg in self.dag["layers"][edit_layer]:
            if fan_in[pkg] > fan_in[edit_pkg]:
                edit_pkg = pkg
        self.edit_rel_path = "packages/pkg%d/lib/src/f%s.dart" % (
            edit_pkg,
            pad_file(opts.files_per_package, 0),
        )

    def top_layer(self):
        return self.dag["layers"][-1]


def count_lines(text):
    return text.count("\n")


def render_all_dart(opts, plan, render_one):
    """Renders every Dart file, passing (rel_path, content) to render_one."""
    lines = 0
    n = len(plan.dag["deps"])
    for p in range(n):
        for f in range(opts.files_per_package):
            content = render_lib_file(
                p, f, opts.files_per_package,
                plan.dag["deps"][p], plan.method_counts[p][f],
            )
            lines += count_lines(content)
            rel = "packages/pkg%d/lib/src/f%s.dart" % (
                p, pad_file(opts.files_per_package, f))
            render_one(rel, content)
            if f % 8 == 0:
                content = render_part_file(p, f, opts.files_per_package)
                lines += count_lines(content)
                rel = "packages/pkg%d/lib/src/f%s.part.dart" % (
                    p, pad_file(opts.files_per_package, f))
                render_one(rel, content)
        content = render_entrypoint(
            p, opts.files_per_package, plan.dag["deps"][p])
        lines += count_lines(content)
        render_one("packages/pkg%d/lib/pkg%d.dart" % (p, p), content)
        if plan.has_test[p]:
            content = render_test_file(p)
            lines += count_lines(content)
            render_one("packages/pkg%d/test/pkg%d_test.dart" % (p, p), content)
    content = render_app_main(plan.top_layer())
    lines += count_lines(content)
    render_one("app/lib/main.dart", content)
    return lines


def plan_total_lines(opts, plan):
    total = [0]

    def count_only(rel, content):
        total[0] += count_lines(content)

    render_all_dart(opts, plan, count_only)
    return total[0]


def tune_plan_to_target(opts, plan):
    """Adjusts method counts one method at a time toward target_loc."""
    total = plan_total_lines(opts, plan)
    lo = int(opts.target_loc * (1.0 - LOC_TOLERANCE))
    hi = int(opts.target_loc * (1.0 + LOC_TOLERANCE))
    n = len(plan.dag["deps"])
    for _ in range(16):
        if lo <= total <= hi:
            break
        moved = False
        for p in range(n):
            for f in range(opts.files_per_package):
                if lo <= total <= hi:
                    break
                skeleton = lib_skeleton_lines(
                    f > 0, len(plan.dag["deps"][p]), f % 8 == 0, f % 2 == 1
                )
                min_m, max_m = method_count_range(skeleton)
                current = plan.method_counts[p][f]
                if total < opts.target_loc and current < max_m:
                    plan.method_counts[p][f] = current + 1
                    total += 8
                    moved = True
                elif total > opts.target_loc and current > min_m:
                    plan.method_counts[p][f] = current - 1
                    total -= 8
                    moved = True
        if not moved:
            break
    return total


def select_package_count(opts):
    n = max(1, opts.target_loc // (opts.files_per_package * 125))
    seen = set()
    for _ in range(10):
        if n in seen:
            break
        seen.add(n)
        plan = MonorepoPlan(opts, n)
        total = tune_plan_to_target(opts, plan)
        lo = int(opts.target_loc * (1.0 - LOC_TOLERANCE))
        hi = int(opts.target_loc * (1.0 + LOC_TOLERANCE))
        if lo <= total <= hi:
            return (plan, total)
        per_pkg = max(total, 1) // max(n, 1)
        nxt = min(1000000, max(1, opts.target_loc // max(per_pkg, 1)))
        if nxt == n:
            n = n + 1 if total < opts.target_loc else max(1, n - 1)
        else:
            n = nxt
    raise ValueError(
        "flutter-monorepo could not reach target_loc %d within +/-%d%% "
        "(last tried %d packages)"
        % (opts.target_loc, int(LOC_TOLERANCE * 100), n)
    )


# --------------------------------------------------------------------------
# Scaffolding.


def write_plain(out_dir, rel, content):
    full = os.path.join(out_dir, rel)
    parent = os.path.dirname(full)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(full, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)


def read_bazel_version_or(rules_flutter_dir, fallback="9.3.0"):
    try:
        with open(os.path.join(rules_flutter_dir, ".bazelversion"),
                  encoding="utf-8") as fh:
            trimmed = fh.read().strip()
            if trimmed:
                return trimmed
    except OSError:
        pass
    return fallback


def extract_rules_dart_git_override(module_bazel_text):
    in_block = False
    block_lines = []
    for line in module_bazel_text.split("\n"):
        trimmed = line.strip()
        if not in_block and trimmed.startswith("git_override("):
            in_block = True
            block_lines = []
        if in_block:
            block_lines.append(line)
            if trimmed == ")":
                if any('"rules_dart"' in b for b in block_lines):
                    return "\n".join(block_lines) + "\n"
                in_block = False
    return None


def module_bazel_text(rules_flutter_dir, overrides):
    """MODULE.bazel derived from the hello_world fixture.

    Substitutes only the module name and the rules_flutter override path;
    everything else stays byte-identical to the fixture. Falls back to an
    embedded minimal module when the fixture is absent (unit tests).
    """
    extra_overrides = ""
    rules_dart_override = None
    for mod_name, mod_dir in overrides:
        if mod_name == "rules_flutter":
            continue
        block = (
            "local_path_override(\n"
            '    module_name = "%s",\n'
            '    path = "%s",\n)\n' % (mod_name, mod_dir)
        )
        if mod_name == "rules_dart":
            rules_dart_override = block
        else:
            extra_overrides += block

    fixture = os.path.join(
        rules_flutter_dir, "e2e", "hello_world", "MODULE.bazel")
    if os.path.isfile(fixture):
        with open(fixture, encoding="utf-8") as fh:
            text = fh.read()
        if "module(name = \"rules_flutter_hello_world\")" not in text:
            raise ValueError(
                "fixture '%s' is not the hello_world module" % fixture)
        if text.count("path = \"../..\",") != 1:
            raise ValueError(
                "fixture '%s' lacks the single rules_flutter path override"
                % fixture)
        out = text.replace(
            "module(name = \"rules_flutter_hello_world\")",
            "module(name = \"bench_monorepo\")",
        )
        out = out.replace(
            "path = \"../..\",",
            "path = \"%s\"," % rules_flutter_dir,
        )
        replaced = False
        if rules_dart_override is not None:
            try:
                with open(os.path.join(rules_flutter_dir, "MODULE.bazel"),
                          encoding="utf-8") as fh:
                    root = fh.read()
                git_override = extract_rules_dart_git_override(root)
                if git_override is not None and git_override in out:
                    out = out.replace(git_override, rules_dart_override, 1)
                    replaced = True
            except OSError:
                pass
            if not replaced:
                # No git_override to swap (minimal fixture): append instead so
                # the override is never silently dropped.
                extra_overrides += rules_dart_override
        out += extra_overrides
        return out

    return (
        "module(name = \"bench_monorepo\")\n"
        "\n"
        "bazel_dep(name = \"rules_flutter\", version = \"0.0.0\")\n"
        "bazel_dep(name = \"rules_dart\", version = \"0.7.3\")\n"
        "bazel_dep(name = \"bazel_skylib\", version = \"1.9.2\")\n"
        "bazel_dep(name = \"apple_support\", version = \"2.9.1\")\n"
        "bazel_dep(name = \"rules_apple\", version = \"5.2.0\")\n"
        "bazel_dep(name = \"rules_swift\", version = \"4.1.2\")\n"
        "bazel_dep(name = \"platforms\", version = \"1.1.0\")\n"
        "\n"
        "local_path_override(\n"
        "    module_name = \"rules_flutter\",\n"
        "    path = \"%s\",\n)\n" % rules_flutter_dir
        + (rules_dart_override or "")
        + extra_overrides
        + "flutter = use_extension(\"@rules_flutter//flutter:extensions.bzl\", \"flutter\")\n"
        "flutter.toolchain(flutter_version = \"3.47.7\")\n"
        "flutter.pub(\n"
        "    name = \"deps\",\n"
        "    lock = \"//:pubspec.lock\",\n)\n"
        "use_repo(flutter, \"deps\", \"flutter_ios_engine\", \"flutter_toolchains\", \"flutter_web_sdk\")\n"
        "\n"
        "register_toolchains(\"@flutter_toolchains//:all\")\n"
    )


def copy_pub_file(out_dir, rules_flutter_dir, file_name, fallback):
    src = os.path.join(
        rules_flutter_dir, "e2e", "hello_world", file_name)
    if os.path.isfile(src):
        with open(src, "rb") as fin:
            content = fin.read()
        with open(os.path.join(out_dir, file_name), "wb") as fout:
            fout.write(content)
    else:
        write_plain(out_dir, file_name, fallback)


def bazelrc_text(rules_flutter_dir):
    fallback = (
        "common --lockfile_mode=off\n"
        "test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze\n"
        "test --output_groups=+dart_analyze\n"
        "test --output_groups=+dart_format\n"
        "common --@rules_dart//dart:analysis_config=//:analysis_config\n"
        "try-import %workspace%/.bazelrc.user\n"
    )
    src = os.path.join(rules_flutter_dir, "e2e", "hello_world", ".bazelrc")
    try:
        with open(src, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return fallback
    kept = [
        line for line in raw.split("\n")
        if not line.startswith("@rules_flutter//flutter:extra_dart_defines")
        and not line.startswith(
            "common --@rules_flutter//flutter:extra_dart_defines")
    ]
    if "common --lockfile_mode=off" not in [l.strip() for l in kept]:
        at = next(
            (i for i, l in enumerate(kept)
             if not l.strip() or l.strip().startswith("try-import")),
            len(kept),
        )
        kept.insert(at, "common --lockfile_mode=off")
    return "\n".join(kept) + "\n"


def copy_dir_sorted(src, dest):
    entries = sorted(os.listdir(src))
    os.makedirs(dest, exist_ok=True)
    for name in entries:
        s = os.path.join(src, name)
        d = os.path.join(dest, name)
        if os.path.isdir(s) and not os.path.islink(s):
            copy_dir_sorted(s, d)
        else:
            shutil.copy2(s, d)


def copy_fixture_dir(out_dir, rules_flutter_dir, fixture_rel, dest_rel):
    src = os.path.join(rules_flutter_dir, *fixture_rel)
    if not os.path.isdir(src):
        if os.path.isfile(os.path.join(rules_flutter_dir, "MODULE.bazel")):
            raise ValueError(
                "rules_flutter fixture '%s' is missing "
                "(required for the iOS app)" % src)
        return
    copy_dir_sorted(src, os.path.join(out_dir, dest_rel))


def write_app_build(out_dir, top_layer):
    """app/BUILD.bazel: VM application, analyzer library, Tier-1 iOS app.

    flutter_ios_app tags every internal target "manual" itself, so iOS stays
    out of a Linux //... (the ios/Runner/ scaffold it discovers is copied
    from the hello_world fixture). Five top-level targets: the shared
    flutter_application, its analyzer library, the full Tier-1 simulator/
    device app, an explicit public App.framework target (Tier-2
    flutter_ios_framework_gen over the same application, so the bench's
    device_release config builds a stable public label instead of the
    macro's private __app_ios_app_framework), and the simulator build test.
    """
    app_deps = "".join("        \"//packages/pkg%d\",\n" % a for a in top_layer)
    build = (
        "load(\"@rules_flutter//flutter:defs.bzl\", \"flutter_application\", \"flutter_library\")\n"
        "load(\"@rules_flutter//flutter:ios.bzl\", \"flutter_ios_app\", \"flutter_ios_framework_gen\", \"flutter_ios_simulator_build_test\")\n"
        "\n"
        "flutter_application(\n"
        "    name = \"app\",\n"
        "    package_name = \"app\",\n"
        "    main = \"lib/main.dart\",\n"
        "    deps = [\n"
        "%s" % app_deps
        + "        \"@deps//:flutter\",\n"
        "    ],\n"
        ")\n"
        "\n"
        "# The app rule is a bundle and carries no DartInfo, so the sources are\n"
        "# declared once more as a library for the analyzer to stage.\n"
        "flutter_library(\n"
        "    name = \"app_lib\",\n"
        "    package_name = \"app\",\n"
        "    srcs = glob([\"lib/**/*.dart\"]),\n"
        "    deps = [\n"
        "%s" % app_deps
        + "        \"@deps//:flutter\",\n"
        "    ],\n"
        ")\n"
        "\n"
        "# iOS, Tier-1 style: the macro discovers ios/Runner/ from `flutter create`\n"
        "# and tags every internal target \"manual\" itself, so a Linux `//...`\n"
        "# skips the whole stack without any explicit constraint here.\n"
        "flutter_ios_app(\n"
        "    name = \"app_ios\",\n"
        "    app_name = \"Bench\",\n"
        "    application = \":app\",\n"
        "    bundle_id = \"com.example.bench\",\n"
        ")\n"
        "\n"
        "# Explicit public App.framework target for the device_release bench\n"
        "# config: AOT gen_snapshot for arm64 plus framework assembly, with no\n"
        "# ios_application, so no signing and no provisioning profile.\n"
        "flutter_ios_framework_gen(\n"
        "    name = \"app_framework\",\n"
        "    application = \":app\",\n"
        ")\n"
        "\n"
        "flutter_ios_simulator_build_test(\n"
        "    name = \"app_ios_sim\",\n"
        "    targets = [\":app_ios\"],\n"
        "    target_compatible_with = [\"@platforms//os:macos\"],\n"
        ")\n"
    )
    write_plain(out_dir, "app/BUILD.bazel", build)
    return 5


def write_scaffolding(out_dir, rules_flutter_dir, overrides, plan, tally):
    bazel_version = read_bazel_version_or(rules_flutter_dir)
    write_plain(
        out_dir, "MODULE.bazel", module_bazel_text(rules_flutter_dir, overrides))
    copy_pub_file(
        out_dir, rules_flutter_dir, "pubspec.lock",
        "# Generated by pub\npackages: {}\nsdks:\n  dart: \">=3.9.0 <4.0.0\"\n")
    copy_pub_file(
        out_dir, rules_flutter_dir, "pubspec.yaml",
        "name: bench_monorepo\nenvironment:\n  sdk: ^3.9.0\n")
    write_plain(out_dir, ".bazelversion", bazel_version + "\n")
    write_plain(out_dir, ".bazelrc", bazelrc_text(rules_flutter_dir))
    copy_pub_file(
        out_dir, rules_flutter_dir, "analysis_options.yaml",
        "analyzer:\n  language:\n    strict-casts: true\n")
    write_plain(
        out_dir, "BUILD.bazel",
        "load(\"@rules_dart//dart:defs.bzl\", \"dart_analysis_config\", \"dart_analysis_options\")\n"
        "\n"
        "exports_files([\"pubspec.lock\"])\n"
        "\n"
        "dart_analysis_options(\n"
        "    name = \"options\",\n"
        "    src = \"analysis_options.yaml\",\n"
        "    deps = [\"@deps//:very_good_analysis\"],\n"
        ")\n"
        "\n"
        "dart_analysis_config(\n"
        "    name = \"analysis_config\",\n"
        "    options = [\":options\"],\n"
        ")\n")
    copy_fixture_dir(
        out_dir, rules_flutter_dir, ["e2e", "hello_world", "ios"], "app/ios")

    n = len(plan.dag["deps"])
    for p in range(n):
        dep_lines = "".join(
            "        \"//packages/pkg%d\",\n" % d for d in plan.dag["deps"][p])
        pkg_build = (
            "load(\"@rules_flutter//flutter:defs.bzl\", \"flutter_library\", \"flutter_test\")\n"
            "\n"
            "_HOST_COMPATIBLE = select({\n"
            "    \"@platforms//os:linux\": [],\n"
            "    \"@platforms//os:macos\": [],\n"
            "    \"@platforms//os:windows\": [],\n"
            "    \"//conditions:default\": [\"@platforms//:incompatible\"],\n"
            "})\n"
            "\n"
            "flutter_library(\n"
            "    name = \"pkg%d\",\n" % p
            + "    package_name = \"pkg%d\",\n" % p
            + "    srcs = glob([\"lib/**/*.dart\"]),\n"
            "    visibility = [\"//visibility:public\"],\n"
            "    deps = [\n"
            "%s" % dep_lines
            + "        \"@deps//:flutter\",\n"
            "    ],\n"
            ")\n"
        )
        write_plain(out_dir, "packages/pkg%d/BUILD.bazel" % p, pkg_build)
        tally["targets"] += 1
        if plan.has_test[p]:
            test_build = (
                "\nflutter_test(\n"
                "    name = \"pkg%d_test\",\n" % p
                + "    package_name = \"pkg%d\",\n" % p
                + "    main = \"test/pkg%d_test.dart\",\n" % p
                + "    srcs = glob([\"lib/**/*.dart\"]),\n"
                "    target_compatible_with = _HOST_COMPATIBLE,\n"
                "    deps = [\n"
                "%s" % dep_lines
                + "        \"@deps//:flutter\",\n"
                "        \"@deps//:flutter_test\",\n"
                "    ],\n"
                ")\n"
            )
            path = os.path.join(out_dir, "packages/pkg%d/BUILD.bazel" % p)
            with open(path, encoding="utf-8") as fh:
                existing = fh.read()
            write_plain(
                out_dir, "packages/pkg%d/BUILD.bazel" % p, existing + test_build)
            tally["targets"] += 1

    tally["targets"] += write_app_build(out_dir, plan.top_layer())


def generate_flutter_monorepo(out_dir, rules_flutter_dir, overrides, opts):
    if not os.path.isdir(rules_flutter_dir):
        raise ValueError(
            "rules_flutter directory '%s' does not exist" % rules_flutter_dir)
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    plan, _ = select_package_count(opts)

    tally = {"files": 0, "lines": 0, "targets": 0}
    write_scaffolding(out_dir, rules_flutter_dir, overrides, plan, tally)

    def write_dart(rel, content):
        write_plain(out_dir, rel, content)
        tally["files"] += 1
        tally["lines"] += count_lines(content)

    render_all_dart(opts, plan, write_dart)

    n = len(plan.dag["deps"])
    fan_in = fan_in_counts(plan.dag)
    fan_out = [len(d) for d in plan.dag["deps"]]
    stats = {
        "edit_layer": opts.edit_layer,
        "fan_in": fan_stats(fan_in),
        "fan_out": fan_stats(fan_out),
        "files": tally["files"],
        "generator": "flutter-monorepo",
        # Shape version: 2 = reachable program (entries call dep entries
        # and own functions under an unfoldable guard, main calls top-layer
        # entries). v1 numbers are never comparable with v2 numbers.
        "generator_version": 2,
        "layers": opts.layers,
        "lines": tally["lines"],
        "packages": n,
        "seed": opts.seed,
        "target_loc": opts.target_loc,
        "targets": tally["targets"],
        "test_ratio": opts.test_ratio,
    }

    lo = int(opts.target_loc * (1.0 - LOC_TOLERANCE))
    hi = int(opts.target_loc * (1.0 + LOC_TOLERANCE))
    if tally["lines"] < lo or tally["lines"] > hi:
        raise ValueError(
            "flutter-monorepo generated %d lines for target_loc %d "
            "(outside +/-%d%%)"
            % (tally["lines"], opts.target_loc, int(LOC_TOLERANCE * 100)))

    manifest = {
        "api_edit": plan.edit_rel_path,
        "body_edit": plan.edit_rel_path,
        "app_main": "app/lib/main.dart",
    }
    write_plain(
        out_dir, EDIT_MANIFEST_REL_PATH,
        json.dumps(manifest, indent=2) + "\n")
    write_plain(
        out_dir, STATS_REL_PATH, json.dumps(stats, indent=2) + "\n")
    return stats


# --------------------------------------------------------------------------
# Edits.


def resolve_edit_path(workspace_dir, key):
    """Manifest edit target, validated (relative, contained, Dart, exists)."""
    manifest_path = os.path.join(workspace_dir, EDIT_MANIFEST_REL_PATH)
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    rel = manifest.get(key)
    if not rel:
        raise ValueError(
            "edit manifest '%s' is missing required key '%s'"
            % (manifest_path, key))
    if os.path.isabs(rel):
        raise ValueError("edit manifest has an absolute '%s' path" % key)
    if ".." in rel.split(os.sep):
        raise ValueError("edit manifest has an escaping '%s' path" % key)
    if not rel.endswith(".dart"):
        raise ValueError("edit manifest has a non-Dart '%s' path" % key)
    full = os.path.join(workspace_dir, rel)
    if not os.path.isfile(full):
        raise ValueError("edit manifest '%s' target '%s' does not exist"
                         % (key, full))
    return full


def apply_body_edit(workspace_dir, key="body_edit"):
    """Body-only edit keeping the public API (kernel outline) unchanged."""
    path = resolve_edit_path(workspace_dir, key)
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    if "i * 1]" in original:
        edited = original.replace("i * 1]", "i * 1 + 0]", 1)
    elif "var total = 1;" in original:
        edited = original.replace("var total = 1;", "var total = 2;", 1)
    elif "return " in original:
        pos = original.rfind("return ")
        edited = original[:pos] + "final _ = 0;\n  " + original[pos:]
    else:
        raise ValueError("unable to apply body-only edit to '%s'" % path)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(edited)
    return original


def apply_api_edit(workspace_dir, key="api_edit"):
    """Public API edit (adding a member), changing the kernel outline."""
    path = resolve_edit_path(workspace_dir, key)
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    if "  /// The value.\n" in original:
        edited = original.replace(
            "  /// The value.\n",
            "  /// Added API.\n  int get extra => 1;\n\n  /// The value.\n",
            1)
    else:
        edited = original + "\n/// Added API.\nint addedApi0x0() => 1;\n"
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(edited)
    return original


def apply_app_edit(workspace_dir):
    """Behaviour-changing top-layer edit of the bench application.

    Bumps the first wired widget's displayed value, changing what the app
    renders without touching any package API.
    """
    path = os.path.join(workspace_dir, "app", "lib", "main.dart")
    with open(path, encoding="utf-8") as fh:
        original = fh.read()
    marker = "W"
    idx = original.find("              W")
    if idx < 0:
        raise ValueError(
            "unable to apply app edit: no wired widget in '%s'" % path)
    end = original.find("),", idx)
    if end < 0:
        raise ValueError(
            "unable to apply app edit: malformed widget line in '%s'" % path)
    line = original[idx:end]
    if marker not in line or "value" not in line:
        raise ValueError(
            "unable to apply app edit: unexpected widget line in '%s'" % path)
    edited = original[:end] + " + 1" + original[end:]
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(edited)
    return original


# --------------------------------------------------------------------------
# CLI.


def build_parser():
    parser = argparse.ArgumentParser(
        description="Generate a layered Flutter monorepo for the iOS bench.")
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="generate a workspace")
    gen.add_argument("--target-loc", type=int, required=True)
    gen.add_argument("--layers", type=int, default=DEFAULT_LAYERS)
    gen.add_argument("--fanout", type=int, default=DEFAULT_FANOUT)
    gen.add_argument("--files-per-package", type=int,
                     default=DEFAULT_FILES_PER_PACKAGE)
    gen.add_argument("--seed", type=int, default=1)
    gen.add_argument("--test-ratio", type=float, default=DEFAULT_TEST_RATIO)
    gen.add_argument("--edit-layer", type=int, default=DEFAULT_EDIT_LAYER)
    gen.add_argument("--rules-flutter", required=True)
    gen.add_argument("--out", required=True)
    gen.add_argument("--override", action="append", default=[],
                     metavar="NAME=PATH",
                     help="extra local_path_override (repeatable)")

    for name in ["apply-body-edit", "apply-api-edit", "apply-app-edit"]:
        p = sub.add_parser(name, help="%s in a generated workspace" % name)
        p.add_argument("--workspace", required=True)
    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "generate":
        overrides = []
        for item in args.override:
            name, _, path = item.partition("=")
            if not name or not path:
                raise ValueError(
                    "--override must be NAME=PATH, got '%s'" % item)
            overrides.append((name, path))
        opts = Options(
            target_loc=args.target_loc,
            layers=args.layers,
            fanout=args.fanout,
            files_per_package=args.files_per_package,
            seed=args.seed,
            test_ratio=args.test_ratio,
            edit_layer=args.edit_layer,
        )
        stats = generate_flutter_monorepo(
            args.out, args.rules_flutter, overrides, opts)
        print(json.dumps(stats, indent=2))
    elif args.command == "apply-body-edit":
        apply_body_edit(args.workspace)
    elif args.command == "apply-api-edit":
        apply_api_edit(args.workspace)
    elif args.command == "apply-app-edit":
        apply_app_edit(args.workspace)
    else:  # pragma: no cover
        parser.error("unknown command '%s'" % args.command)
    return 0


if __name__ == "__main__":
    sys.exit(main())
