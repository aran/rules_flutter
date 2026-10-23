"""Tests for the kernel `unused_inputs_list` wiring (`flutter_kernel_module`).

Every Flutter kernel-module compile — the aspect's library modules (debug and
product) and the test, web, and app entry modules — writes the
`unused_inputs_list` rules_dart's `kernel_module` tool derives, so Bazel skips
the compile when only inputs it did not use changed. The fixture
(`flutter/tests/unused_inputs_fixture`) packs every dependency shape the list
must keep into one closure: `:a` adopts `:b`'s `part of` file, re-exports
`:c`, and folds a constant from `:d`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:flutter_kernel_module.bzl", "flutter_kernel_module_action")

def _kernel_actions(env):
    actions = analysistest.target_actions(env)
    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.true(
        env,
        len(kernel_actions) > 0,
        "expected DartKernel actions, got %s" % [a.mnemonic for a in actions],
    )
    return kernel_actions

def _entry_unused_inputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    for action in _kernel_actions(env):
        basenames = [f.basename for f in action.outputs.to_list()]
        lists = [b for b in basenames if b.endswith(".unused_inputs")]
        asserts.equals(
            env,
            1,
            len(lists),
            "each DartKernel action declares one unused-inputs list, got %s" % basenames,
        )
    entries = [
        a
        for a in _kernel_actions(env)
        if any(["flutter_entry.kmod" in f.basename for f in a.outputs.to_list()])
    ]
    asserts.equals(env, 1, len(entries), "the test compiles one flutter entry module")
    basenames = [f.basename for f in entries[0].outputs.to_list()]
    asserts.true(
        env,
        ctx.attr.target_under_test.label.name + ".flutter_entry.kmod.unused_inputs" in basenames,
        "the entry action declares the unused-inputs list, got %s" % basenames,
    )
    return analysistest.end(env)

_entry_unused_inputs_test = analysistest.make(_entry_unused_inputs_test_impl)

def _fake_file(path):
    short_path = path
    return struct(
        basename = short_path.split("/")[-1],
        is_directory = False,
        is_source = True,
        path = short_path,
        short_path = short_path,
    )

def _fake_args(added):
    # Records single-argument adds as strings and `--flag value` adds as
    # pairs, so tests can assert both forwarded flags and multi-root values.
    return struct(
        add = lambda *a, **_kw: added.append(a[0] if len(a) == 1 else a),
        add_all = lambda *a, **_kw: added.append(a[0]),
        set_param_file_format = lambda *a, **_kw: None,
        use_param_file = lambda *a, **_kw: None,
    )

def _compile(added, runs, **kw):
    """Runs `flutter_kernel_module_action` against a fake context, capturing the action."""
    fake_actions = struct(
        declare_file = lambda name: _fake_file("bazel-out/bin/fake/" + name),
        symlink = lambda **_kw: None,
        write = lambda **_kw: None,
        args = lambda: _fake_args(added),
        run = lambda **run_kw: runs.append(run_kw),
    )
    fake_ctx = struct(
        label = struct(name = "manual_target", package = "flutter/tests/foo"),
        attr = struct(tags = ["manual"], _kernel_module = None),
        executable = struct(_kernel_module = _fake_file("kernel_module.dill")),
        actions = fake_actions,
    )
    fake_tools = struct(
        dart = _fake_file("dart"),
        dartvm = _fake_file("dartvm"),
        runtime_files = None,
        dartaotruntime = _fake_file("dartaotruntime"),
        kernel_worker = _fake_file("kernel_worker.snapshot"),
        platform_dill = _fake_file("platform_strong.dill"),
        libraries_json = _fake_file("libraries.json"),
        version = "3.13.5",
    )
    kwargs = dict(
        ctx = fake_ctx,
        tools = fake_tools,
        sources = [struct(
            uri = "package:unused_a/adopt.dart",
            file = _fake_file("flutter/tests/unused_inputs_fixture/a/lib/adopt.dart"),
        )],
        packages = [],
        dep_kmods = depset(),
        output = _fake_file("manual_target.flutter.kmod"),
        defines = [],
        exclude_non_sources = True,
        droppable = True,
    )
    kwargs.update(kw)
    flutter_kernel_module_action(**kwargs)

def _library_unused_inputs_test_impl(ctx):
    env = unittest.begin(ctx)
    added = []
    runs = []
    _compile(
        added,
        runs,
        koutline = _fake_file("manual_target.flutter.koutline"),
        unused_inputs = True,
    )
    asserts.equals(env, 1, len(runs), "registers one DartKernel action")
    asserts.true(
        env,
        runs[0]["unused_inputs_list"] != None,
        "unused_inputs = True passes unused_inputs_list to the action",
    )
    asserts.equals(
        env,
        "manual_target.flutter.kmod.unused_inputs",
        runs[0]["unused_inputs_list"].basename,
        "the list file sits next to the module output",
    )
    flags = [a for a in added if type(a) == "string"] + [a[0] for a in added if type(a) == "tuple"]
    for flag in ["--unused-inputs-list", "--own-source-file", "--input-source"]:
        asserts.true(
            env,
            flag in flags,
            "unused_inputs = True forwards %s to kernel_module" % flag,
        )
    return unittest.end(env)

def _entry_extra_inputs_test_impl(ctx):
    env = unittest.begin(ctx)
    added = []
    runs = []
    _compile(
        added,
        runs,
        droppable = False,
        extra_inputs = depset([_fake_file("flutter/tests/unused_inputs_fixture/b/lib/other.dart")]),
        unused_inputs = True,
    )
    asserts.equals(env, 1, len(runs), "registers one DartKernel action")
    asserts.true(
        env,
        runs[0]["unused_inputs_list"] != None,
        "an entry compile takes unused_inputs_list",
    )
    return unittest.end(env)

def _default_no_list_test_impl(ctx):
    env = unittest.begin(ctx)
    added = []
    runs = []
    _compile(added, runs)
    asserts.equals(env, 1, len(runs), "registers one DartKernel action by default")
    asserts.true(
        env,
        runs[0]["unused_inputs_list"] == None,
        "the default registers the historical action with no list",
    )
    flags = [a for a in added if type(a) == "string"] + [a[0] for a in added if type(a) == "tuple"]
    asserts.true(
        env,
        "--unused-inputs-list" not in flags,
        "the default passes no --unused-inputs-list to kernel_module",
    )
    asserts.true(
        env,
        "--own-source-file" not in flags,
        "the default reports no own sources for the used-input check",
    )
    return unittest.end(env)

def _stage_all_test_impl(ctx):
    """Every modular kernel compile stages all sources and never mounts `.`.

    The exec root carries files the action did not declare; mounting it lets
    the compile read (and Bazel cache) undeclared bytes. The staging root
    holds only declared inputs.
    """
    env = unittest.begin(ctx)
    added = []
    runs = []
    _compile(added, runs, unused_inputs = True)
    pairs = [a for a in added if type(a) == "tuple"]
    asserts.true(
        env,
        ("--multi-root", ".") not in pairs,
        "no modular compile mounts the exec root '.', got %r" % (pairs,),
    )
    roots = [v for (k, v) in pairs if k == "--multi-root"]
    asserts.equals(env, 1, len(roots), "expected only the staging root mounted, got %r" % (roots,))
    if len(roots) == 1:
        asserts.true(
            env,
            roots[0].endswith(".stage"),
            "the --multi-root must be the per-action staging dir, got %r" % roots[0],
        )
    return unittest.end(env)

_library_unused_inputs_test = unittest.make(_library_unused_inputs_test_impl)
_entry_extra_inputs_test = unittest.make(_entry_extra_inputs_test_impl)
_default_no_list_test = unittest.make(_default_no_list_test_impl)
_stage_all_test = unittest.make(_stage_all_test_impl)

def unused_inputs_test_suite(name):
    """Defines tests for the kernel `unused_inputs_list` wiring.

    Args:
        name: The test suite name.
    """
    unittest.suite(
        name,
        _library_unused_inputs_test,
        _entry_extra_inputs_test,
        _default_no_list_test,
        _stage_all_test,
    )
    _entry_unused_inputs_test(
        name = name + "_entry",
        target_under_test = "//flutter/tests/unused_inputs_fixture:fixture_test",
    )
