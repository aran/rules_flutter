"""The URI a native app's `main` is compiled under, in the build and the dev loop.

Hot reload applies an edit only when the dev tool's compiler names a library
exactly as the running kernel does. A `main` under its package's `lib/` has a
`package:` URI that is the same in the build's sandbox and the workspace. One
outside it — `flutter run -t test_driver/app.dart` — has no such URI, so both
sides name it under the app scheme instead, with the same root mounted. These
tests pin both halves: the build's kernel compile and the `_dev_config.json`
the dev tool compiles from.

The generated plugin registrant rides the same scheme, since a frontend_server
mounts one scheme at a time.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter:providers.bzl", "resolve_exec_dart_vm")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")
load(":action_content.bzl", "package_entry", "written_json")

_PACKAGE = "ae_fixture"
_OUTSIDE_LIB_URI = "org-dartlang-app:///flutter/tests/web_fixture_main.dart"

def _kernel_action(env):
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterKernelCompile"
    ]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    return kernels[0] if kernels else None

def _flag_values(argv, flag):
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == flag]

def _assert_multi_root_and_package_config(env, action):
    """FlutterKernelCompile mounts only its staging root under org-dartlang-app and emits stable rootUris.

    Every declared source (source and generated alike) is staged into the
    per-action staging root, which is the only `--filesystem-root` the
    compiler sees. The exec root (`.`) is never mounted: an undeclared file
    is then not there for the compiler to read whatever its spelling, and
    `kernel_filter` refuses disallowed directives and verifies the read set
    against the `--declared-inputs` manifest on top.
    """
    argv = action.argv if action else []
    roots = _flag_values(argv, "--filesystem-root")
    for r in roots:
        asserts.false(
            env,
            r.endswith("/bin"),
            "FlutterKernelCompile must never mount whole bin_dir, got %r" % roots,
        )
    asserts.false(
        env,
        "." in roots,
        "FlutterKernelCompile must never mount the exec root '.', got %r" % roots,
    )
    asserts.equals(env, 1, len(roots), "expected only the staging root mounted, got %r" % roots)
    if len(roots) >= 1:
        asserts.true(
            env,
            roots[0].startswith("bazel-out/") and roots[0].endswith(".stage"),
            "the --filesystem-root must be the per-action .stage dir, got %r" % roots[0],
        )
    asserts.equals(env, ["org-dartlang-app"], _flag_values(argv, "--filesystem-scheme"))

    manifests = _flag_values(argv, "--declared-inputs")
    asserts.equals(env, 1, len(manifests), "expected --declared-inputs <manifest>, got %r" % argv)
    if action and len(manifests) == 1:
        input_paths = [f.path for f in action.inputs.to_list()]
        asserts.true(
            env,
            manifests[0] in input_paths,
            "the --declared-inputs manifest %r must be an action input" % manifests[0],
        )

    pkg_config = written_json(env, ".package_config.json")
    entry = package_entry(pkg_config, _PACKAGE)
    asserts.true(env, entry != None, "expected `%s` entry in .package_config.json" % _PACKAGE)
    if entry != None:
        asserts.equals(
            env,
            "org-dartlang-app:///flutter/tests",
            entry.get("rootUri"),
            "expected stable org-dartlang-app:/// rootUri",
        )

    copy_actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartCopyTree"]
    asserts.equals(env, [], copy_actions, "FlutterKernelCompile must not emit DartCopyTree actions")

def _assert_registrant_on_app_scheme(env, action):
    """The registrant's `--source`, its define and its root agree."""
    argv = action.argv if action else []
    defines = [
        a[len("-Dflutter.dart_plugin_registrant="):]
        for a in argv
        if a.startswith("-Dflutter.dart_plugin_registrant=")
    ]
    asserts.equals(env, 1, len(defines), "a dbg app compiles a plugin registrant")
    if not defines:
        return
    registrant = defines[0]

    # The engine looks the define up as a library URI by exact string, so the
    # source it names has to be compiled under that same string.
    asserts.true(
        env,
        registrant in _flag_values(argv, "--source"),
        "the registrant define %r must be a --source" % registrant,
    )
    asserts.true(
        env,
        registrant.startswith("org-dartlang-app:///flutter/tests/"),
        "the registrant is named by its workspace path under the app scheme, got %r" % registrant,
    )
    _assert_multi_root_and_package_config(env, action)

def _outside_lib_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = action.argv if action else []

    # The compilation root. A `main` outside lib/ has no `package:` URI, so it
    # compiles under the app scheme — resolved through the staging root, which
    # stages the source by its workspace path. The exec root is never mounted.
    asserts.equals(env, _OUTSIDE_LIB_URI, argv[-1] if argv else None)
    _assert_registrant_on_app_scheme(env, action)

    # The dev loop names it the same way, from the same root — `""` is the
    # exec root in the dev config's exec-root-relative convention.
    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(env, _OUTSIDE_LIB_URI, config["appEntrypoint"])
        asserts.equals(env, [""], config["filesystemRoots"])
        asserts.equals(env, "org-dartlang-app", config["filesystemScheme"])

        # The `main`, and the sibling it imports: both reach the dev loop's
        # edit-to-URI map, the sibling because it is declared in `srcs` —
        # the build's compile sees nothing it does not declare, so this is
        # every file outside a package the app can read.
        asserts.equals(
            env,
            [
                {"path": "flutter/tests/web_fixture_main.dart", "uri": _OUTSIDE_LIB_URI},
                {"path": "flutter/tests/app_entrypoint_sibling.dart", "uri": "org-dartlang-app:///flutter/tests/app_entrypoint_sibling.dart"},
            ],
            config["appSources"],
        )
    return analysistest.end(env)

def _in_lib_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = action.argv if action else []
    asserts.equals(
        env,
        "package:%s/web_fixture_main.dart" % _PACKAGE,
        argv[-1] if argv else None,
    )
    asserts.false(
        env,
        "--no-embed-source-text" in argv,
        "JIT FlutterKernelCompile must keep embedded source text, got %r" % argv,
    )
    _assert_registrant_on_app_scheme(env, action)

    # Nothing for the dev loop to mount: the entrypoint resolves through the
    # package config, and the dev tool compiles its own registrant as a file.
    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(env, "package:%s/web_fixture_main.dart" % _PACKAGE, config["appEntrypoint"])
        asserts.equals(env, [], config["filesystemRoots"])
        asserts.equals(env, [], config["appSources"])
    return analysistest.end(env)

def _opt_in_lib_test_impl(ctx):
    """Release builds stage every source and mount only the staging root."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = action.argv if action else []
    asserts.equals(
        env,
        "package:%s/web_fixture_main.dart" % _PACKAGE,
        argv[-1] if argv else None,
    )
    asserts.true(
        env,
        "--no-embed-source-text" in argv,
        "AOT FlutterKernelCompile must pass --no-embed-source-text, got %r" % argv,
    )
    _assert_multi_root_and_package_config(env, action)
    return analysistest.end(env)

def _stale_bin_dir_seed_impl(ctx):
    """Materializes an invalid Dart file at `bazel-out/<cfg>/bin/flutter/tests/lib/web_fixture_main.dart` alongside a declared generated source."""
    stale_tmpl = ctx.actions.declare_file(ctx.label.name + "_stale.tmpl")
    ctx.actions.write(
        stale_tmpl,
        "THIS IS STALE GENERATED GARBAGE IN BAZEL-OUT THAT MUST NOT BE PICKED UP;\n",
    )
    seed_tmpl = ctx.actions.declare_file(ctx.label.name + "_seed.tmpl")
    ctx.actions.write(
        seed_tmpl,
        "const int staleProbeSeed = 1;\n",
    )

    # `stale_out` lands at `bazel-out/<cfg>/bin/flutter/tests/lib/web_fixture_main.dart`,
    # the exact bin_dir path corresponding to the source `lib/web_fixture_main.dart`.
    # Producing both outputs from one action guarantees `stale_out` exists on disk
    # in `bazel-out/<cfg>/bin` whenever a consumer builds `seed_out`, while only
    # `seed_out` is exposed in `DefaultInfo.files`.
    stale_out = ctx.actions.declare_file("lib/web_fixture_main.dart")
    seed_out = ctx.actions.declare_file("lib/stale_probe_seed.dart")
    cfg = ctx.actions.declare_file(ctx.label.name + "_config.json")
    ctx.actions.write(
        cfg,
        json.encode({
            "web_defines": {},
            "keep_placeholders": [],
            "files": [
                {
                    "template": stale_tmpl.path,
                    "output": stale_out.path,
                    "label": "stale",
                    "base_href": "",
                    "static_assets_url": None,
                    "dev_loop_guard": False,
                    "manages_service_worker": False,
                    "check_constructs": False,
                    "builtins": {},
                },
                {
                    "template": seed_tmpl.path,
                    "output": seed_out.path,
                    "label": "seed",
                    "base_href": "",
                    "static_assets_url": None,
                    "dev_loop_guard": False,
                    "manages_service_worker": False,
                    "check_constructs": False,
                    "builtins": {},
                },
            ],
        }),
    )
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    ctx.actions.run(
        executable = dart_exe,
        arguments = [ctx.executable._web_template_tool.path, "--config", cfg.path],
        inputs = depset(
            direct = [stale_tmpl, seed_tmpl, cfg, ctx.executable._web_template_tool],
            transitive = [dart_vm_files],
        ),
        outputs = [stale_out, seed_out],
        mnemonic = "StaleBinDirSeed",
    )
    return [
        DefaultInfo(files = depset([seed_out])),
        OutputGroupInfo(stale = depset([stale_out])),
    ]

_stale_bin_dir_seed = rule(
    implementation = _stale_bin_dir_seed_impl,
    attrs = {
        "_web_template_tool": attr.label(
            default = Label("//flutter/private/tools:web_template"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
)

def _other_cfg_transition_impl(settings, _attr):
    mode = settings["//command_line_option:compilation_mode"]
    return {
        "//command_line_option:compilation_mode": "dbg" if mode != "dbg" else "fastbuild",
    }

_other_cfg_transition = transition(
    implementation = _other_cfg_transition_impl,
    inputs = ["//command_line_option:compilation_mode"],
    outputs = ["//command_line_option:compilation_mode"],
)

def _transitioned_dart_src_impl(ctx):
    part_out = ctx.actions.declare_file("lib/transitioned_part.dart")
    ctx.actions.write(part_out, "const int transitionedValue = 7;\n")
    main_out = ctx.actions.declare_file("lib/transitioned_main.dart")
    ctx.actions.write(
        main_out,
        "import 'package:%s/transitioned_part.dart';\nvoid main() { if (transitionedValue != 7) throw StateError('bad'); }\n" % _PACKAGE,
    )
    return [DefaultInfo(files = depset([part_out, main_out]))]

_transitioned_dart_src = rule(
    implementation = _transitioned_dart_src_impl,
    cfg = _other_cfg_transition,
)

def _transitioned_main_only_impl(ctx):
    for f in ctx.files.src:
        if f.basename == "transitioned_main.dart":
            return [DefaultInfo(files = depset([f]))]
    fail("expected transitioned_main.dart")

_transitioned_main_only = rule(
    implementation = _transitioned_main_only_impl,
    attrs = {"src": attr.label(mandatory = True)},
)

def _declared_shadow_src_impl(ctx):
    # Generates `app_entrypoint_sibling.dart` at the same package-relative path
    # as the checked-in source `app_entrypoint_sibling.dart`, adding
    # `generatedShadowSymbol` which is absent from the source file.
    shadow_sibling = ctx.actions.declare_file("app_entrypoint_sibling.dart")
    ctx.actions.write(
        shadow_sibling,
        "const sibling = 'generated';\nconst int generatedShadowSymbol = 99;\n",
    )
    return [DefaultInfo(files = depset([shadow_sibling]))]

_declared_shadow_src = rule(
    implementation = _declared_shadow_src_impl,
)

def _shadow_consumer_main_impl(ctx):
    main_out = ctx.actions.declare_file("shadow_consumer_main.dart")
    ctx.actions.write(
        main_out,
        "import 'app_entrypoint_sibling.dart';\nvoid main() { if (generatedShadowSymbol != 99) throw StateError(sibling); }\n",
    )
    return [DefaultInfo(files = depset([main_out]))]

_shadow_consumer_main = rule(
    implementation = _shadow_consumer_main_impl,
)

def _stale_probe_analysis_test_impl(ctx):
    """Declared inputs are staged in `.stage`, while undeclared files in `bazel-out` are not."""
    env = analysistest.begin(ctx)
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    if kernels:
        action = kernels[0]
        _assert_multi_root_and_package_config(env, action)
        input_paths = [f.path for f in action.inputs.to_list()]
        staged_seed = [p for p in input_paths if p.endswith(".stage/flutter/tests/lib/stale_probe_seed.dart")]
        asserts.equals(
            env,
            1,
            len(staged_seed),
            "expected declared generated file staged in .stage, got %r" % input_paths,
        )
        staged_main = [p for p in input_paths if p.endswith(".stage/flutter/tests/lib/web_fixture_main.dart")]
        asserts.equals(
            env,
            1,
            len(staged_main),
            "expected declared main staged in .stage, got %r" % input_paths,
        )

        # The stale sibling in bazel-out is in no output group the compile
        # declares, so it reaches neither the inputs nor the staging root.
        # The staged link above resolves the `package:` entrypoint, and the
        # accompanying build test only passes when that link points at the
        # declared source — the stale file holds no valid Dart. An unstaged
        # `bin/...` path would be readable only behind a mounted root, and
        # only the staging root is mounted.
        unstaged = [p for p in input_paths if p.endswith("bin/flutter/tests/lib/web_fixture_main.dart") and ".stage/" not in p]
        asserts.equals(
            env,
            [],
            unstaged,
            "undeclared stale file in bazel-out must not be an action input: %r" % unstaged,
        )
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}
_OPT = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): False,
}

_outside_lib_test = analysistest.make(_outside_lib_test_impl, config_settings = _DBG)
_in_lib_test = analysistest.make(_in_lib_test_impl, config_settings = _DBG)
_opt_in_lib_test = analysistest.make(_opt_in_lib_test_impl, config_settings = _OPT)
_stale_probe_analysis_test = analysistest.make(_stale_probe_analysis_test_impl, config_settings = _OPT)

def app_entrypoint_test_suite(name):
    """Fixtures and tests for where a native app's `main` is compiled from.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_ae_outside_lib",
        srcs = [
            "app_entrypoint_sibling.dart",
            # Under `lib/`, so keyed by its `package:` URI and not listed.
            "lib/web_fixture_main.dart",
        ],
        package_name = _PACKAGE,
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_application(
        name = "_ae_in_lib",
        package_name = _PACKAGE,
        main = "lib/web_fixture_main.dart",
        tags = ["manual"],
    )
    _stale_bin_dir_seed(
        name = "_ae_stale_bin_dir_seed",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_stale_probe_aot",
        srcs = [":_ae_stale_bin_dir_seed"],
        aot = True,
        package_name = _PACKAGE,
        main = "lib/web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_stale_probe_modular",
        srcs = [":_ae_stale_bin_dir_seed"],
        aot = False,
        package_name = _PACKAGE,
        main = "lib/web_fixture_main.dart",
        tags = ["manual"],
    )
    _transitioned_dart_src(
        name = "_ae_transitioned_srcs",
        tags = ["manual"],
    )
    _transitioned_main_only(
        name = "_ae_transitioned_main",
        src = ":_ae_transitioned_srcs",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_transitioned_probe_aot",
        srcs = [":_ae_transitioned_srcs"],
        aot = True,
        package_name = _PACKAGE,
        main = ":_ae_transitioned_main",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_transitioned_probe_modular",
        srcs = [":_ae_transitioned_srcs"],
        aot = False,
        package_name = _PACKAGE,
        main = ":_ae_transitioned_main",
        tags = ["manual"],
    )
    _declared_shadow_src(
        name = "_ae_declared_shadow_src",
        tags = ["manual"],
    )
    _shadow_consumer_main(
        name = "_ae_shadow_consumer_main",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_shadow_probe_aot",
        srcs = [
            "app_entrypoint_sibling.dart",
            ":_ae_declared_shadow_src",
        ],
        aot = True,
        package_name = _PACKAGE,
        main = ":_ae_shadow_consumer_main",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_ae_shadow_probe_modular",
        srcs = [
            "app_entrypoint_sibling.dart",
            ":_ae_declared_shadow_src",
        ],
        aot = False,
        package_name = _PACKAGE,
        main = ":_ae_shadow_consumer_main",
        tags = ["manual"],
    )
    _outside_lib_test(
        name = name + "_outside_lib",
        target_under_test = ":_ae_outside_lib",
    )
    _in_lib_test(
        name = name + "_in_lib",
        target_under_test = ":_ae_in_lib",
    )
    _opt_in_lib_test(
        name = name + "_opt_in_lib",
        target_under_test = ":_ae_in_lib",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _stale_probe_analysis_test(
        name = name + "_stale_probe_analysis",
        target_under_test = ":_ae_stale_probe_aot",
        target_compatible_with = HOST_COMPATIBLE,
    )
    build_test(
        name = name + "_stale_generated_build_test",
        targets = [
            ":_ae_stale_probe_aot",
            ":_ae_stale_probe_modular",
            ":_ae_transitioned_probe_aot",
            ":_ae_transitioned_probe_modular",
            ":_ae_shadow_probe_aot",
            ":_ae_shadow_probe_modular",
        ],
        target_compatible_with = HOST_COMPATIBLE,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_outside_lib",
            ":" + name + "_in_lib",
            ":" + name + "_opt_in_lib",
            ":" + name + "_stale_probe_analysis",
            ":" + name + "_stale_generated_build_test",
        ],
    )
