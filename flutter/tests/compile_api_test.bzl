"""Analysis tests for the public compile API (`//flutter:utils.bzl`).

`flutter_kernel_compile_action` and `compile_package_config` live in
`//flutter/private`, but downstream rules compose over them through the public
`//flutter:utils.bzl` — this file's caller rule loads only that (plus the
public `@rules_dart` helpers), never `//flutter/private`, and still builds a
kernel with `vm_flags`/`import_dill`/`resource_set`. The tests pin what the
hidden consumer checks rely on:

- the default argv is unchanged (no `vm_flags` slot, no `--import-dill`);
- `vm_flags` sit right after `dartaotruntime`, before the snapshot, and only
  the allow-listed tuning flags are accepted (anything naming a file or a
  side effect fails the build, as does any `extra_flags` entry naming a
  file the compile does not declare, and any spelling of
  `--[no-]print-incremental-dependencies`, which the compile controls
  itself);
- `import_dill` is passed as `--import-dill=<path>` and is an action input,
  while an undeclared source beside it stays out of the inputs and the
  mounted roots (its refusal is pinned in `kernel_filter_test.dart`, including
  under `extra_flags = ["--incremental"]`, which keeps working without
  silencing the check);
- `extra_roots` entries appear in the emitted `package_config.json`, and an
  absolute, empty, or `..`-escaping root fails at analysis naming the
  package and the value;
- the default compile is reproducible: the entrypoint closes the argv as an
  `org-dartlang-app:///` URI (never the sandbox's `file://` exec path) and
  every emitted `rootUri` uses the same scheme, so the dill carries no
  absolute host path (`reproducible_default_test`);
- the module docstring's minimal example is itself a caller target: the
  exact call shape from `//flutter:utils.bzl`'s docstring compiles and keeps
  the default argv (`docstring_example_test`, executed by `build_test`);
- the default compile's full post-`--` argv is pinned element for element
  (`full_argv_test`): order, flags and values, with only host/toolchain
  file paths discovered from the action's own inputs;
- a caller that sets every new parameter still compiles (`build_test` —
  `resource_set` is not observable from analysis, so executing the action is
  the presence check), including a real `import_dill` chain: a whole-program
  dill of the dep entry seeding an incremental compile of a main importing
  the dep.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_dart//dart:defs.bzl", "dart_library")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs")
load("//flutter:utils.bzl", "FLUTTER_KERNEL_COMPILE_ATTRS", "FLUTTER_KERNEL_COMPILE_TOOLCHAINS", "compile_package_config", "flutter_kernel_compile_action", "flutter_kernel_compile_tools")
load(":action_content.bzl", "package_entry", "written_json")

# `HOST_COMPATIBLE` without the `//flutter/private` load this file must not
# have: these compiles run on a host OS only.
_HOST_COMPATIBLE = select({
    "@platforms//os:linux": [],
    "@platforms//os:macos": [],
    "@platforms//os:windows": [],
    "//conditions:default": ["@platforms//:incompatible"],
})

_TEST_RESOURCE_SET = {"memory": 8000, "cpu": 1}

def _compile_api_caller_impl(ctx):
    """A downstream-style compile over the public utils only."""
    tools = flutter_kernel_compile_tools(ctx)
    packages = collect_packages(ctx.attr.deps)
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list() + [ctx.file.main]
    pc = compile_package_config(ctx, packages, all_srcs, extra_roots = ctx.attr.extra_roots)
    output = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = tools.dartaotruntime,
        kernel_filter_tool = tools.kernel_filter_tool,
        frontend_server = tools.frontend_server,
        platform_dill = tools.platform_dill,
        main = ctx.file.main,
        srcs = pc.srcs,
        package_config = pc.config_file,
        output = output,
        vm_flags = ctx.attr.vm_flags,
        import_dill = ctx.file.import_dill if ctx.attr.import_dill else None,
        resource_set = _TEST_RESOURCE_SET if ctx.attr.use_resource_set else None,
        extra_flags = ctx.attr.extra_flags,
    )
    return [DefaultInfo(files = depset([output]))]

_compile_api_caller = rule(
    implementation = _compile_api_caller_impl,
    attrs = {
        "main": attr.label(
            doc = "The entrypoint .dart source.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Additional Dart sources.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "DartInfo dependencies.",
            providers = [DartInfo],
        ),
        "vm_flags": attr.string_list(
            doc = "Dart VM flags for dartaotruntime.",
        ),
        "extra_flags": attr.string_list(
            doc = "Additional frontend_server flags.",
        ),
        "import_dill": attr.label(
            doc = "Pre-compiled summary dill.",
            allow_single_file = True,
        ),
        "use_resource_set": attr.bool(
            doc = "Constrain the compile action's host resources.",
            default = False,
        ),
        "extra_roots": attr.string_dict(
            doc = "Package name to exec-root-relative root for sourceless packages.",
        ),
    } | FLUTTER_KERNEL_COMPILE_ATTRS,
    toolchains = FLUTTER_KERNEL_COMPILE_TOOLCHAINS,
)

def _kernel_action(env):
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterKernelCompile"
    ]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    return kernels[0] if kernels else None

# The documented minimal call shape from `//flutter:utils.bzl`'s module
# docstring, as a caller target: `compile_package_config` with no
# `extra_roots`, `flutter_kernel_compile_action` with no optional parameter.
# If the docstring drifts from the real signatures, this target stops
# analyzing; if the minimal shape's argv drifts, the test below fails.
def _docstring_example_impl(ctx):
    """The `//flutter:utils.bzl` docstring example, verbatim."""
    tools = flutter_kernel_compile_tools(ctx)
    packages = collect_packages(ctx.attr.deps)
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list() + [ctx.file.main]
    pc = compile_package_config(ctx, packages, all_srcs)
    output = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = tools.dartaotruntime,
        kernel_filter_tool = tools.kernel_filter_tool,
        frontend_server = tools.frontend_server,
        platform_dill = tools.platform_dill,
        main = ctx.file.main,
        srcs = pc.srcs,
        package_config = pc.config_file,
        output = output,
    )
    return [DefaultInfo(files = depset([output]))]

_docstring_example = rule(
    implementation = _docstring_example_impl,
    attrs = {
        "main": attr.label(
            doc = "The entrypoint .dart source.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Additional Dart sources.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "DartInfo dependencies.",
            providers = [DartInfo],
        ),
    } | FLUTTER_KERNEL_COMPILE_ATTRS,
    toolchains = FLUTTER_KERNEL_COMPILE_TOOLCHAINS,
)

def _compile_argv(env, action):
    """The frontend_server argv: everything after the kernel_filter `--`."""
    argv = action.argv if action else []
    asserts.true(env, "--" in argv, "expected the kernel_filter `--` separator, got %r" % (argv,))
    if "--" not in argv:
        return []
    return argv[argv.index("--") + 1:]

def _assert_default_argv(env, argv, main_suffix):
    """The default-shape argv: snapshot after dartaotruntime, entry last."""
    asserts.true(env, len(argv) > 2, "expected a full compile argv, got %r" % (argv,))
    if len(argv) > 2:
        asserts.true(
            env,
            argv[1].endswith(".snapshot"),
            "with no vm_flags the snapshot follows dartaotruntime directly, got %r" % (argv[:3],),
        )
    asserts.equals(
        env,
        [],
        [a for a in argv if a.startswith("--import-dill")],
        "the default compile passes no --import-dill, got %r" % (argv,),
    )
    asserts.true(
        env,
        argv[-1].endswith(main_suffix) if argv else False,
        "the entrypoint source closes the argv, got %r" % (argv[-1] if argv else None,),
    )

def _default_argv_test_impl(ctx):
    """Without the new parameters the action keeps its exact default shape."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    _assert_default_argv(env, _compile_argv(env, action), "flutter/tests/compile_api_main.dart")
    return analysistest.end(env)

def _docstring_example_test_impl(ctx):
    """The docstring's minimal example compiles with the default argv shape."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    _assert_default_argv(env, _compile_argv(env, action), "flutter/tests/compile_api_main.dart")
    return analysistest.end(env)

def _full_argv_test_impl(ctx):
    """The default compile's full post-`--` argv, element for element.

    Order, flags and values are pinned exactly; only host/toolchain file
    paths are discovered from the action's own inputs (matched by basename,
    each required to match exactly one input), and the staging root from the
    staged symlink inputs. A reordered, added or dropped flag fails here even
    when every fragment assertion above still passes.
    """
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = _compile_argv(env, action)
    if not argv:
        return analysistest.end(env)
    paths = [f.path for f in action.inputs.to_list()]
    runtimes = [p for p in paths if p.rsplit("/", 1)[-1] in ("dartaotruntime", "dartaotruntime.exe")]
    asserts.equals(env, 1, len(runtimes), "expected exactly one dartaotruntime input, got %r" % (paths,))
    snapshots = [p for p in paths if p.endswith("frontend_server_aot.dart.snapshot")]
    asserts.equals(env, 1, len(snapshots), "expected exactly one frontend_server snapshot input, got %r" % (paths,))
    platforms = [p for p in paths if p.rsplit("/", 1)[-1].startswith("platform_strong") and p.endswith(".dill")]
    asserts.equals(env, 1, len(platforms), "expected exactly one platform dill input, got %r" % (paths,))
    configs = [p for p in paths if p.endswith(".package_config.json")]
    asserts.equals(env, 1, len(configs), "expected exactly one package_config.json input, got %r" % (paths,))
    staged = [p for p in paths if ".stage/" in p]
    asserts.true(env, len(staged) > 0, "expected staged symlink inputs, got %r" % (paths,))
    roots = {p[:p.index(".stage") + len(".stage")]: True for p in staged}
    asserts.equals(env, 1, len(roots.keys()), "expected one staging root, got %r" % (staged,))
    stage_root = roots.keys()[0] if len(roots.keys()) == 1 else ""
    asserts.true(
        env,
        "_compile_api_default.dill." in stage_root and stage_root.endswith(".stage"),
        "the staging root is the action-scoped hashed directory, got %r" % (stage_root,),
    )
    outputs = action.outputs.to_list()
    asserts.equals(env, 1, len(outputs), "expected exactly one compile output")
    if len(runtimes) == 1 and len(snapshots) == 1 and len(platforms) == 1 and len(configs) == 1 and len(outputs) == 1 and len(roots.keys()) == 1:
        asserts.equals(
            env,
            [
                runtimes[0],
                snapshots[0],
                "--sdk-root",
                platforms[0].rsplit("/", 1)[0] + "/",
                "--target",
                "flutter",
                "--packages",
                configs[0],
                "--output-dill",
                outputs[0].path,
                "--verbosity=error",
                "--enable-asserts",
                "--filesystem-root",
                stage_root,
                "--filesystem-scheme",
                "org-dartlang-app",
                "org-dartlang-app:///flutter/tests/compile_api_main.dart",
            ],
            argv,
        )
    return analysistest.end(env)

def _extras_argv_test_impl(ctx):
    """`vm_flags` precede the snapshot; `import_dill` rides along as an input."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = _compile_argv(env, action)

    asserts.true(env, len(argv) > 3, "expected a full compile argv, got %r" % (argv,))
    if len(argv) > 3:
        asserts.equals(
            env,
            "--old-gen-heap-size=2147483648",
            argv[1],
            "vm_flags sit right after dartaotruntime, got %r" % (argv[:4],),
        )
        asserts.true(
            env,
            argv[2].endswith(".snapshot"),
            "the snapshot follows vm_flags, got %r" % (argv[:4],),
        )

    import_args = [a for a in argv if a.startswith("--import-dill=")]
    asserts.equals(env, 1, len(import_args), "expected one --import-dill=<path>, got %r" % (argv,))
    if action and len(import_args) == 1:
        input_paths = [f.path for f in action.inputs.to_list()]
        dill_path = import_args[0][len("--import-dill="):]
        asserts.true(
            env,
            dill_path in input_paths,
            "--import-dill path %r must be an action input" % dill_path,
        )
        asserts.true(
            env,
            dill_path.endswith("flutter/tests/compile_api_import.dill"),
            "unexpected --import-dill path %r" % dill_path,
        )

    # The `deps` closure still resolves: the extras main reaches its package.
    config = written_json(env, ".package_config.json")
    asserts.true(
        env,
        package_entry(config, "compile_api_dep") != None,
        "expected a `compile_api_dep` entry in .package_config.json",
    )
    return analysistest.end(env)

def _vm_flags_reject_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "vm_flags")
    return analysistest.end(env)

def _vm_flags_allowed_test_impl(ctx):
    """Allow-listed `vm_flags` precede the snapshot in the caller's order."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = _compile_argv(env, action)
    asserts.true(env, len(argv) > 4, "expected a full compile argv, got %r" % (argv,))
    if len(argv) > 4:
        asserts.equals(
            env,
            "--enable-asserts",
            argv[1],
            "the first vm_flag sits right after dartaotruntime, got %r" % (argv[:5],),
        )
        asserts.equals(
            env,
            "--old_gen_heap_size=1048576",
            argv[2],
            "the second vm_flag follows in order, got %r" % (argv[:5],),
        )
        asserts.true(
            env,
            argv[3].endswith(".snapshot"),
            "the snapshot follows vm_flags, got %r" % (argv[:5],),
        )
    return analysistest.end(env)

def _extra_flags_reject_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "extra_flags")
    return analysistest.end(env)

def _extra_flags_message_reject_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

def _extra_roots_reject_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

def _undeclared_staged_out_test_impl(ctx):
    """An undeclared source beside an `import_dill` stays out of the compile.

    The sibling exists on disk and the entrypoint imports it, but no target
    declares it: it must reach neither the action inputs nor any mounted
    `--filesystem-root`. `kernel_filter` then refuses the import before the
    compiler runs (see `kernel_filter_test.dart`); the staging here is what
    leaves the compiler nothing undeclared to read whatever its spelling.
    """
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    if action:
        input_paths = [f.path for f in action.inputs.to_list()]
        asserts.equals(
            env,
            [],
            [p for p in input_paths if p.endswith("compile_api_undeclared_sibling.dart")],
            "the undeclared sibling must not be an action input",
        )
        argv = _compile_argv(env, action)
        roots = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--filesystem-root"]
        asserts.false(
            env,
            "." in roots,
            "only the staging root is mounted, got %r" % (roots,),
        )
        asserts.equals(
            env,
            1,
            len([a for a in argv if a.startswith("--import-dill=")]),
            "the import_dill still rides along, got %r" % (argv,),
        )
    return analysistest.end(env)

def _extra_roots_test_impl(ctx):
    """`extra_roots` gives a sourceless package its config entry, under the stable scheme."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".package_config.json")
    entry = package_entry(config, "compile_api_ghost")
    asserts.true(env, entry != None, "expected a `compile_api_ghost` entry in .package_config.json")
    if entry != None:
        asserts.equals(
            env,
            "org-dartlang-app:///flutter/tests",
            entry.get("rootUri"),
            "the ghost rootUri must name the extra root under the stable scheme, got %r" % (entry,),
        )
        asserts.equals(env, "lib/", entry.get("packageUri"))
    return analysistest.end(env)

def _no_extra_roots_test_impl(ctx):
    """Without `extra_roots` the sourceless package stays out of the config."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".package_config.json")
    asserts.equals(
        env,
        None,
        package_entry(config, "compile_api_ghost"),
        "no entry without extra_roots",
    )
    return analysistest.end(env)

def _reproducible_default_test_impl(ctx):
    """The default public compile uses `org-dartlang-app:///` throughout.

    The entrypoint closes the argv as the stable app-scheme URI rather than
    the sandbox's `file://` exec path, and every package config entry names
    the same scheme, so the dill embeds no absolute host path and is
    byte-identical across output bases and runs.
    """
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = _compile_argv(env, action)
    if argv:
        asserts.equals(
            env,
            "org-dartlang-app:///flutter/tests/compile_api_extras_main.dart",
            argv[-1],
            "the entrypoint must be the stable app-scheme URI, got %r" % (argv[-1],),
        )
    config = written_json(env, ".package_config.json")
    if config != None:
        asserts.true(
            env,
            len(config["packages"]) > 0,
            "expected package entries in .package_config.json",
        )
        for entry in config["packages"]:
            asserts.true(
                env,
                entry.get("rootUri", "").startswith("org-dartlang-app:///"),
                "every rootUri must use the stable scheme, got %r" % (entry,),
            )
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

_default_argv_test = analysistest.make(_default_argv_test_impl, config_settings = _DBG)
_docstring_example_test = analysistest.make(_docstring_example_test_impl, config_settings = _DBG)
_full_argv_test = analysistest.make(_full_argv_test_impl, config_settings = _DBG)
_extras_argv_test = analysistest.make(_extras_argv_test_impl, config_settings = _DBG)
_vm_flags_reject_test = analysistest.make(_vm_flags_reject_test_impl, config_settings = _DBG, expect_failure = True)
_vm_flags_allowed_test = analysistest.make(_vm_flags_allowed_test_impl, config_settings = _DBG)
_extra_flags_reject_test = analysistest.make(_extra_flags_reject_test_impl, config_settings = _DBG, expect_failure = True)
_extra_flags_message_reject_test = analysistest.make(
    _extra_flags_message_reject_test_impl,
    config_settings = _DBG,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
)
_extra_roots_reject_test = analysistest.make(
    _extra_roots_reject_test_impl,
    config_settings = _DBG,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
)
_undeclared_staged_out_test = analysistest.make(_undeclared_staged_out_test_impl, config_settings = _DBG)
_extra_roots_test = analysistest.make(_extra_roots_test_impl, config_settings = _DBG)
_no_extra_roots_test = analysistest.make(_no_extra_roots_test_impl, config_settings = _DBG)
_reproducible_default_test = analysistest.make(_reproducible_default_test_impl, config_settings = _DBG)

def compile_api_test_suite(name):
    """Fixtures and tests for the public compile API.

    Args:
        name: The test suite name.
    """
    dart_library(
        name = "_compile_api_dep",
        package_name = "compile_api_dep",
        srcs = ["lib/compile_api_dep.dart"],
        tags = ["manual"],
    )
    dart_library(
        name = "_compile_api_ghost",
        package_name = "compile_api_ghost",
        srcs = [],
        tags = ["manual"],
    )

    # A real summary dill of the dep package: a whole-program kernel compile
    # of an entrypoint reaching the dep. The `_compile_api_import` target
    # below consumes it as `import_dill`.
    _compile_api_caller(
        name = "_compile_api_dill_source",
        main = "compile_api_extras_main.dart",
        deps = [":_compile_api_dep"],
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )

    # A real `import_dill` compile: the dep entry's dill seeds an incremental
    # compile of a main importing the dep. The dep's sources stay declared
    # inputs — `frontend_server` re-reads an imported dill's whole source
    # closure (verified directly: even a main importing nothing from the dill
    # makes it re-read the dill's entry and closure), so a sound `import_dill`
    # compile must declare that closure. `kernel_filter` then accepts those
    # declared reads plus the dill input, and still refuses undeclared ones
    # (pinned in `kernel_filter_test.dart`). `--incremental` keeps the
    # compiler from additionally re-reading the dill's own entry main, which
    # this compile does not declare.
    _compile_api_caller(
        name = "_compile_api_import",
        main = "compile_api_import_main.dart",
        deps = [":_compile_api_dep"],
        extra_roots = {"compile_api_dep": "flutter/tests"},
        extra_flags = ["--incremental"],
        import_dill = ":_compile_api_dill_source",
        vm_flags = ["--old-gen-heap-size=2147483648"],
        use_resource_set = True,
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )

    _compile_api_caller(
        name = "_compile_api_default",
        main = "compile_api_main.dart",
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_extras",
        main = "compile_api_extras_main.dart",
        deps = [":_compile_api_dep"],
        vm_flags = ["--old-gen-heap-size=2147483648"],
        import_dill = "compile_api_import.dill",
        use_resource_set = True,
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_flags",
        main = "compile_api_main.dart",
        vm_flags = ["--old-gen-heap-size=2147483648", "frontend_server_aot.dart.snapshot"],
        tags = ["manual"],
    )

    # Analysis-only: allow-listed `vm_flags` spellings (a bare diagnostic
    # plus an underscore-spelled sizing) keep their order before the snapshot.
    _compile_api_caller(
        name = "_compile_api_vm_allowed",
        main = "compile_api_main.dart",
        vm_flags = ["--enable-asserts", "--old_gen_heap_size=1048576"],
        tags = ["manual"],
    )

    # Analysis negatives (each must fail with its `fail` message): a
    # file-naming `vm_flags` entry, a host-writing one, an unlisted one, a
    # file-naming `extra_flags` entry, and a mount-smuggling one.
    _compile_api_caller(
        name = "_compile_api_bad_vm_files",
        main = "compile_api_main.dart",
        vm_flags = ["--packages=lib/secret.dart"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_vm_sideeffect",
        main = "compile_api_main.dart",
        vm_flags = ["--timeline-recorder=file:/tmp/timeline"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_vm_unknown",
        main = "compile_api_main.dart",
        vm_flags = ["--ignore_unrecognized_flags"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_extra_files",
        main = "compile_api_main.dart",
        extra_flags = ["--import-dill=compile_api_import.dill"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_extra_mount",
        main = "compile_api_main.dart",
        extra_flags = ["--filesystem-root", "."],
        tags = ["manual"],
    )

    # Analysis negatives for the dependency-report silencers: every spelling
    # `_check_extra_flags` normalizes (case, `_` vs `-`, one or two dashes,
    # with and without the `no-` prefix, including a `=value` form) fails at
    # analysis naming the flag — the compile controls the report itself.
    _compile_api_caller(
        name = "_compile_api_bad_extra_silencer",
        main = "compile_api_main.dart",
        extra_flags = ["--no-print-incremental-dependencies"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_extra_silencer_bare",
        main = "compile_api_main.dart",
        extra_flags = ["--print-incremental-dependencies"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_extra_silencer_single",
        main = "compile_api_main.dart",
        extra_flags = ["-no-print-incremental-dependencies"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_extra_silencer_underscore",
        main = "compile_api_main.dart",
        extra_flags = ["--no_print_incremental_dependencies"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_extra_silencer_case",
        main = "compile_api_main.dart",
        extra_flags = ["--PRINT-INCREMENTAL-DEPENDENCIES"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_extra_silencer_value",
        main = "compile_api_main.dart",
        extra_flags = ["--no-print-incremental-dependencies=false"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_undeclared",
        main = "compile_api_undeclared_main.dart",
        import_dill = "compile_api_import.dill",
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_roots",
        main = "compile_api_main.dart",
        deps = [":_compile_api_ghost"],
        extra_roots = {"compile_api_ghost": "flutter/tests"},
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_no_roots",
        main = "compile_api_main.dart",
        deps = [":_compile_api_ghost"],
        tags = ["manual"],
    )

    # Analysis negatives for `extra_roots`: an absolute root (POSIX or
    # Windows), a `..` escape, and an empty root each fail at analysis
    # naming the package and the value — never after the read.
    _compile_api_caller(
        name = "_compile_api_bad_roots_abs",
        main = "compile_api_main.dart",
        deps = [":_compile_api_ghost"],
        extra_roots = {"compile_api_ghost": "/abs/root"},
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_roots_win",
        main = "compile_api_main.dart",
        deps = [":_compile_api_ghost"],
        extra_roots = {"compile_api_ghost": "C:/win/root"},
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_roots_escape",
        main = "compile_api_main.dart",
        deps = [":_compile_api_ghost"],
        extra_roots = {"compile_api_ghost": "../escape"},
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_roots_empty",
        main = "compile_api_main.dart",
        deps = [":_compile_api_ghost"],
        extra_roots = {"compile_api_ghost": ""},
        tags = ["manual"],
    )

    # Executed compiles: the default shape, the docstring example shape, the
    # every-new-parameter shape, and the real `import_dill` chain all build.
    # `resource_set` is invisible to analysis, so running the action is its
    # presence check. The analysis-only `_compile_api_extras`/
    # `_compile_api_undeclared` targets use the checked-in stub dill, which no
    # executed compile reads as a dill.
    _compile_api_caller(
        name = "_compile_api_build_default",
        main = "compile_api_main.dart",
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )
    _docstring_example(
        name = "_compile_api_build_docstring",
        main = "compile_api_main.dart",
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )
    _compile_api_caller(
        name = "_compile_api_build_extras",
        main = "compile_api_extras_main.dart",
        deps = [":_compile_api_dep"],
        vm_flags = ["--old-gen-heap-size=2147483648", "--enable-asserts"],
        use_resource_set = True,
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )

    # Real negative (manual, deliberately NOT in `build_test`): the sibling
    # import is never declared, so executing this compile must fail. Run it
    # explicitly to see the refusal.
    _compile_api_caller(
        name = "_compile_api_build_negative",
        main = "compile_api_undeclared_main.dart",
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )

    # Real negative under `--incremental` (manual, deliberately NOT in
    # `build_test`): `--incremental` keeps working but does not silence the
    # read-set check, so the same undeclared sibling is still refused. Run it
    # explicitly to see the refusal.
    _compile_api_caller(
        name = "_compile_api_build_negative_incremental",
        main = "compile_api_undeclared_main.dart",
        extra_flags = ["--incremental"],
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )

    # Real negative for an undeclared `package:` import under `--incremental`
    # (manual, deliberately NOT in `build_test`): the directive guard accepts
    # the non-escaping `package:` URI, so the post-compile read-set check is
    # what refuses the build. Run it explicitly to see the refusal.
    _compile_api_caller(
        name = "_compile_api_build_negative_pkg",
        main = "compile_api_undeclared_pkg_main.dart",
        deps = [":_compile_api_dep"],
        extra_flags = ["--incremental"],
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )

    # Analysis target for the docstring example: the exact minimal call shape
    # from the `//flutter:utils.bzl` module docstring.
    _docstring_example(
        name = "_compile_api_docstring",
        main = "compile_api_main.dart",
        tags = ["manual"],
    )

    _default_argv_test(
        name = name + "_default_argv",
        target_under_test = ":_compile_api_default",
    )
    _docstring_example_test(
        name = name + "_docstring_example",
        target_under_test = ":_compile_api_docstring",
    )
    _full_argv_test(
        name = name + "_full_argv",
        target_under_test = ":_compile_api_default",
    )
    _extras_argv_test(
        name = name + "_extras_argv",
        target_under_test = ":_compile_api_extras",
    )
    _vm_flags_reject_test(
        name = name + "_vm_flags_reject",
        target_under_test = ":_compile_api_bad_flags",
    )
    _vm_flags_allowed_test(
        name = name + "_vm_flags_allowed",
        target_under_test = ":_compile_api_vm_allowed",
    )
    _vm_flags_reject_test(
        name = name + "_vm_flags_files",
        target_under_test = ":_compile_api_bad_vm_files",
    )
    _vm_flags_reject_test(
        name = name + "_vm_flags_sideeffect",
        target_under_test = ":_compile_api_bad_vm_sideeffect",
    )
    _vm_flags_reject_test(
        name = name + "_vm_flags_unknown",
        target_under_test = ":_compile_api_bad_vm_unknown",
    )
    _extra_flags_reject_test(
        name = name + "_extra_flags_files",
        target_under_test = ":_compile_api_bad_extra_files",
    )
    _extra_flags_reject_test(
        name = name + "_extra_flags_mount",
        target_under_test = ":_compile_api_bad_extra_mount",
    )
    _extra_flags_message_reject_test(
        name = name + "_extra_flags_silencer",
        target_under_test = ":_compile_api_bad_extra_silencer",
        expected_substrings = ["extra_flags", "--no-print-incremental-dependencies", "controls"],
    )
    _extra_flags_message_reject_test(
        name = name + "_extra_flags_silencer_bare",
        target_under_test = ":_compile_api_bad_extra_silencer_bare",
        expected_substrings = ["extra_flags", "--print-incremental-dependencies", "controls"],
    )
    _extra_flags_message_reject_test(
        name = name + "_extra_flags_silencer_single",
        target_under_test = ":_compile_api_bad_extra_silencer_single",
        expected_substrings = ["extra_flags", "-no-print-incremental-dependencies", "controls"],
    )
    _extra_flags_message_reject_test(
        name = name + "_extra_flags_silencer_underscore",
        target_under_test = ":_compile_api_bad_extra_silencer_underscore",
        expected_substrings = ["extra_flags", "--no_print_incremental_dependencies", "controls"],
    )
    _extra_flags_message_reject_test(
        name = name + "_extra_flags_silencer_case",
        target_under_test = ":_compile_api_bad_extra_silencer_case",
        expected_substrings = ["extra_flags", "--PRINT-INCREMENTAL-DEPENDENCIES", "controls"],
    )
    _extra_flags_message_reject_test(
        name = name + "_extra_flags_silencer_value",
        target_under_test = ":_compile_api_bad_extra_silencer_value",
        expected_substrings = ["extra_flags", "--no-print-incremental-dependencies=false", "controls"],
    )
    _undeclared_staged_out_test(
        name = name + "_undeclared_staged_out",
        target_under_test = ":_compile_api_undeclared",
    )
    _extra_roots_test(
        name = name + "_extra_roots",
        target_under_test = ":_compile_api_roots",
    )
    _no_extra_roots_test(
        name = name + "_no_extra_roots",
        target_under_test = ":_compile_api_no_roots",
    )
    _reproducible_default_test(
        name = name + "_reproducible_default",
        target_under_test = ":_compile_api_extras",
    )
    _extra_roots_reject_test(
        name = name + "_extra_roots_abs",
        target_under_test = ":_compile_api_bad_roots_abs",
        expected_substrings = ["extra_roots", "compile_api_ghost", "/abs/root"],
    )
    _extra_roots_reject_test(
        name = name + "_extra_roots_win",
        target_under_test = ":_compile_api_bad_roots_win",
        expected_substrings = ["extra_roots", "compile_api_ghost", "C:/win/root"],
    )
    _extra_roots_reject_test(
        name = name + "_extra_roots_escape",
        target_under_test = ":_compile_api_bad_roots_escape",
        expected_substrings = ["extra_roots", "compile_api_ghost", "../escape"],
    )
    _extra_roots_reject_test(
        name = name + "_extra_roots_empty",
        target_under_test = ":_compile_api_bad_roots_empty",
        expected_substrings = ["extra_roots", "compile_api_ghost"],
    )
    build_test(
        name = name + "_build",
        target_compatible_with = _HOST_COMPATIBLE,
        targets = [
            ":_compile_api_build_default",
            ":_compile_api_build_docstring",
            ":_compile_api_build_extras",
            ":_compile_api_dill_source",
            ":_compile_api_import",
        ],
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_default_argv",
            ":" + name + "_docstring_example",
            ":" + name + "_full_argv",
            ":" + name + "_extras_argv",
            ":" + name + "_vm_flags_reject",
            ":" + name + "_vm_flags_allowed",
            ":" + name + "_vm_flags_files",
            ":" + name + "_vm_flags_sideeffect",
            ":" + name + "_vm_flags_unknown",
            ":" + name + "_extra_flags_files",
            ":" + name + "_extra_flags_mount",
            ":" + name + "_extra_flags_silencer",
            ":" + name + "_extra_flags_silencer_bare",
            ":" + name + "_extra_flags_silencer_single",
            ":" + name + "_extra_flags_silencer_underscore",
            ":" + name + "_extra_flags_silencer_case",
            ":" + name + "_extra_flags_silencer_value",
            ":" + name + "_undeclared_staged_out",
            ":" + name + "_extra_roots",
            ":" + name + "_no_extra_roots",
            ":" + name + "_reproducible_default",
            ":" + name + "_extra_roots_abs",
            ":" + name + "_extra_roots_win",
            ":" + name + "_extra_roots_escape",
            ":" + name + "_extra_roots_empty",
            ":" + name + "_build",
        ],
    )
