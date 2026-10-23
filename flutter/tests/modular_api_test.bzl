"""Analysis tests for the public modular kernel API (`//flutter:utils.bzl`).

`flutter_kernel_module_aspect`, `FlutterKernelModuleInfo`,
`FLUTTER_MODULAR_KERNEL_ATTRS` / `FLUTTER_MODULAR_KERNEL_TOOLCHAINS` and the
`flutter_modular_test_kernel` / `flutter_modular_app_kernel` functions live in
`//flutter/private`, but downstream rules compose custom pipelines over them
through the public `//flutter:utils.bzl` — this file's caller rules load only
that, never `//flutter/private`. The tests pin what the hidden consumer
checks rely on:

- the test path compiles the bootstrap as one `DartKernel` entry module
  against the dependency `.flutter.koutline` summaries and links with
  `DartKernelLink` against the `.flutter.kmod` modules, emitting no
  whole-program `FlutterKernelCompile`;
- the default link is complete: every reachable module lands in the kernel,
  no base dill or keys are staged, and the base output group is empty even
  though the closure carries a base (the `fake_flutter_test_sdk` fixture,
  standing in for `package:flutter_test`);
- with `use_base_dill` the same deps delta-link: the base keys are staged at
  link time, the base's own modules are excluded from the link, and the base
  output group holds the base dill;
- the bootstrap write imports the `test_uri` and drives `RemoteListener`;
- the app path does the same for the app's own sources, with the debug
  platform dill prepended at link time — complete by default, delta-linked
  with `use_base_dill` (base search, base staging and base group included);
- a comma-bearing global `extra_dart_defines` does NOT fall back: the `deps`
  transition strips it for the custom closure, so the actions stay modular;
- a caller-set `defines` fails the build (a custom kernel has no
  whole-program fallback);
- the app path executes end to end in both modes (`build_test` over real
  kernels; the test path's execution is the `e2e/hello_world` prebuilt run,
  also in both modes).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load(
    "//flutter:utils.bzl",
    "FLUTTER_MODULAR_KERNEL_ATTRS",
    "FLUTTER_MODULAR_KERNEL_TOOLCHAINS",
    "FLUTTER_TEST_BOOTSTRAP_ATTRS",
    "flutter_modular_app_kernel",
    "flutter_modular_test_kernel",
)
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")

_TEST_URI = "package:modular_api_b/b.dart"

def _modular_api_test_caller_impl(ctx):
    """A downstream-style modular test kernel over the public utils only."""
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    base_dill = flutter_modular_test_kernel(
        ctx,
        test_uri = _TEST_URI,
        deps = ctx.attr.deps,
        output = kernel_dill,
        use_base_dill = ctx.attr.use_base_dill,
    )
    return [
        DefaultInfo(files = depset([kernel_dill])),
        OutputGroupInfo(
            test_kernel = depset([kernel_dill]),
            test_base_kernel = depset([base_dill]) if base_dill else depset(),
        ),
    ]

_modular_api_test_caller = rule(
    implementation = _modular_api_test_caller_impl,
    attrs = {
        "use_base_dill": attr.bool(default = False),
    } | FLUTTER_MODULAR_KERNEL_ATTRS | FLUTTER_TEST_BOOTSTRAP_ATTRS,
    toolchains = FLUTTER_MODULAR_KERNEL_TOOLCHAINS,
)

def _modular_api_app_caller_impl(ctx):
    """A downstream-style modular app kernel over the public utils only."""
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    base_dill = flutter_modular_app_kernel(
        ctx,
        main = ctx.file.main,
        package_name = "modular_api_app",
        srcs = ctx.files.srcs,
        deps = ctx.attr.deps,
        output = kernel_dill,
        use_base_dill = ctx.attr.use_base_dill,
    )
    return [
        DefaultInfo(files = depset([kernel_dill])),
        OutputGroupInfo(
            kernel = depset([kernel_dill]),
            base_kernel = depset([base_dill]) if base_dill else depset(),
        ),
    ]

_modular_api_app_caller = rule(
    implementation = _modular_api_app_caller_impl,
    attrs = {
        "main": attr.label(mandatory = True, allow_single_file = [".dart"]),
        "srcs": attr.label_list(allow_files = [".dart"]),
        "use_base_dill": attr.bool(default = False),
    } | FLUTTER_MODULAR_KERNEL_ATTRS,
    toolchains = FLUTTER_MODULAR_KERNEL_TOOLCHAINS,
)

def _find_action(env, mnemonics):
    found = [a for a in analysistest.target_actions(env) if a.mnemonic in mnemonics]
    asserts.equals(
        env,
        1,
        len(found),
        "expected exactly one action in %s, got %s" % (mnemonics, [a.mnemonic for a in found]),
    )
    return found[0] if found else None

def _entry_and_link(env):
    """The entry `DartKernel` plus the `DartKernelLink`, with no whole-program compile."""
    entry = _find_action(env, ["DartKernel"])
    link = _find_action(env, ["DartKernelLink"])
    whole_program = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterKernelCompile"
    ]
    asserts.equals(env, [], whole_program, "a custom modular kernel must not run FlutterKernelCompile")
    return entry, link

def _test_shapes_test_impl(ctx):
    """The test path compiles one entry module and links it, never whole-program.

    The caller under test links the default complete kernel: even though the
    closure carries a base (the `fake_flutter_test_sdk` fixture), every
    reachable module lands in the kernel, no base dill is staged, and the
    base output group stays empty.
    """
    env = analysistest.begin(ctx)
    entry, link = _entry_and_link(env)

    if entry:
        entry_inputs = [f.path for f in entry.inputs.to_list()]
        for want in ["dep_a.flutter.koutline", "dep_b.flutter.koutline", "fake_flutter_test_sdk.flutter.koutline"]:
            asserts.true(
                env,
                any([want in p for p in entry_inputs]),
                "the entry compile must see the %s outline, got %d inputs" % (want, len(entry_inputs)),
            )
        asserts.equals(
            env,
            [],
            [p for p in entry_inputs if p.endswith(".dart") and "bootstrap" not in p and "comparator" not in p],
            "the entry compile must not stage dependency sources",
        )
    if link:
        link_inputs = [f.path for f in link.inputs.to_list()]
        for want in ["dep_a.flutter.kmod", "dep_b.flutter.kmod", "fake_flutter_test_sdk.flutter.kmod"]:
            asserts.true(
                env,
                any([want in p for p in link_inputs]),
                "the complete link must stage the %s module, got %d inputs" % (want, len(link_inputs)),
            )
        asserts.equals(
            env,
            [],
            [p for p in link_inputs if ".flutter_base." in p],
            "the complete link must stage no base dill or keys",
        )

    groups = analysistest.target_under_test(env)[OutputGroupInfo]
    asserts.equals(
        env,
        [],
        groups.test_base_kernel.to_list(),
        "the default complete kernel links no base, so the base group is empty",
    )

    writes = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and
           a.outputs.to_list()[0].basename.endswith("_modular_bootstrap.dart")
    ]
    asserts.equals(env, 1, len(writes), "expected one modular bootstrap write")
    if writes:
        content = writes[0].content
        asserts.true(
            env,
            _TEST_URI in content,
            "the bootstrap must import the test URI",
        )
        asserts.true(
            env,
            "RemoteListener.start" in content,
            "the bootstrap must drive RemoteListener",
        )
    return analysistest.end(env)

def _based_test_shapes_test_impl(ctx):
    """With `use_base_dill` the test kernel delta-links against the base.

    Same deps as the complete kernel, but the link stages the base keys,
    excludes the base's own modules, and the base output group holds the
    base dill — the `flutter_prebuilt_test` `base_dill` contract.
    """
    env = analysistest.begin(ctx)
    _entry, link = _entry_and_link(env)

    if link:
        link_inputs = [f.path for f in link.inputs.to_list()]
        for want in ["dep_a.flutter.kmod", "dep_b.flutter.kmod"]:
            asserts.true(
                env,
                any([want in p for p in link_inputs]),
                "the delta link must still stage the %s module, got %d inputs" % (want, len(link_inputs)),
            )
        asserts.equals(
            env,
            [],
            [p for p in link_inputs if "fake_flutter_test_sdk.flutter.kmod" in p],
            "the delta link must exclude the base's own modules",
        )
        bases = [p for p in link_inputs if p.endswith(".flutter_base.keys")]
        asserts.equals(
            env,
            1,
            len(bases),
            "the delta link must stage the base keys, got %d inputs" % len(link_inputs),
        )

    groups = analysistest.target_under_test(env)[OutputGroupInfo]
    base_files = groups.test_base_kernel.to_list()
    asserts.equals(env, 1, len(base_files), "expected one base dill in the base group")
    if base_files:
        asserts.true(
            env,
            base_files[0].basename.endswith(".flutter_base.dill"),
            "the base group must hold the base dill, got %r" % base_files[0].basename,
        )

    writes = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and
           a.outputs.to_list()[0].basename.endswith("_modular_bootstrap.dart")
    ]
    asserts.equals(env, 1, len(writes), "expected one modular bootstrap write")
    if writes:
        content = writes[0].content
        asserts.true(
            env,
            _TEST_URI in content,
            "the bootstrap must import the test URI",
        )
        asserts.true(
            env,
            "RemoteListener.start" in content,
            "the bootstrap must drive RemoteListener",
        )
    return analysistest.end(env)

def _app_shapes_test_impl(ctx):
    """The app path compiles the app sources as the entry and links with the platform dill."""
    env = analysistest.begin(ctx)
    entry, link = _entry_and_link(env)

    if entry:
        entry_inputs = [f.path for f in entry.inputs.to_list()]
        asserts.true(
            env,
            any(["dep_a.flutter.koutline" in p for p in entry_inputs]),
            "the app entry compile must see the dep outline",
        )
        asserts.true(
            env,
            any([p.endswith("modular_api_app_main.dart") for p in entry_inputs]),
            "the app entry compile must stage the app main",
        )
    if link:
        link_inputs = [f.path for f in link.inputs.to_list()]
        asserts.true(
            env,
            any(["dep_a.flutter.kmod" in p for p in link_inputs]),
            "the app link must stage the dep module",
        )
        asserts.true(
            env,
            any([p.endswith("platform_strong.dill") for p in link_inputs]),
            "the app link must prepend the debug platform dill, got %d inputs" % len(link_inputs),
        )
        asserts.equals(
            env,
            [],
            [p for p in link_inputs if ".flutter_base." in p],
            "the default app link is complete: it stages no base dill or keys",
        )
    groups = analysistest.target_under_test(env)[OutputGroupInfo]
    asserts.equals(
        env,
        [],
        groups.base_kernel.to_list(),
        "the default complete app kernel links no base, so the base group is empty",
    )
    return analysistest.end(env)

def _based_app_shapes_test_impl(ctx):
    """With `use_base_dill` the app kernel delta-links against the base.

    The base search runs in the app path too: the link stages the base keys
    and the base output group holds the base dill, while the platform dill is
    still prepended and no whole-program compile runs.
    """
    env = analysistest.begin(ctx)
    _entry, link = _entry_and_link(env)

    if link:
        link_inputs = [f.path for f in link.inputs.to_list()]
        asserts.true(
            env,
            any(["dep_a.flutter.kmod" in p for p in link_inputs]),
            "the app link must stage the dep module",
        )
        asserts.true(
            env,
            any([p.endswith("platform_strong.dill") for p in link_inputs]),
            "the app link must prepend the debug platform dill, got %d inputs" % len(link_inputs),
        )
        bases = [p for p in link_inputs if p.endswith(".flutter_base.keys")]
        asserts.equals(
            env,
            1,
            len(bases),
            "the delta app link must stage the base keys, got %d inputs" % len(link_inputs),
        )
    groups = analysistest.target_under_test(env)[OutputGroupInfo]
    base_files = groups.base_kernel.to_list()
    asserts.equals(env, 1, len(base_files), "expected one base dill in the app base group")
    if base_files:
        asserts.true(
            env,
            base_files[0].basename.endswith(".flutter_base.dill"),
            "the app base group must hold the base dill, got %r" % base_files[0].basename,
        )
    return analysistest.end(env)

def _comma_stays_modular_test_impl(ctx):
    """A comma-bearing global define does not fork the custom closure off modular.

    The built-in rules fall back to `FlutterKernelCompile` here; the custom
    `deps` transition strips the flag for the custom closure instead, so the
    entry compile (which never reads the flag) stays consistent with the
    dependency modules and the actions stay `DartKernel` + `DartKernelLink`.
    """
    env = analysistest.begin(ctx)
    _entry_and_link(env)
    return analysistest.end(env)

def _defines_reject_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "defines")
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}
_COMMA = _DBG | {
    str(Label("//flutter:extra_dart_defines")): ["FOO=a,b"],
}

_test_shapes_test = analysistest.make(_test_shapes_test_impl, config_settings = _DBG)
_based_test_shapes_test = analysistest.make(_based_test_shapes_test_impl, config_settings = _DBG)
_app_shapes_test = analysistest.make(_app_shapes_test_impl, config_settings = _DBG)
_based_app_shapes_test = analysistest.make(_based_app_shapes_test_impl, config_settings = _DBG)
_comma_stays_modular_test = analysistest.make(_comma_stays_modular_test_impl, config_settings = _COMMA)
_defines_reject_test = analysistest.make(_defines_reject_test_impl, config_settings = _DBG, expect_failure = True)

def modular_api_test_suite(name):
    """Fixtures and tests for the public modular kernel API.

    Args:
        name: The test suite name.
    """
    _modular_api_test_caller(
        name = "_modular_api_test",
        tags = ["manual"],
        deps = [
            "//flutter/tests/modular_api_fixture:dep_b",
            "//flutter/tests/modular_api_sdk_fixture:fake_flutter_test_sdk",
        ],
    )

    # Delta twin of the above: same closure, `use_base_dill` links against
    # the fixture SDK base instead of linking complete.
    _modular_api_test_caller(
        name = "_modular_api_test_based",
        tags = ["manual"],
        use_base_dill = True,
        deps = [
            "//flutter/tests/modular_api_fixture:dep_b",
            "//flutter/tests/modular_api_sdk_fixture:fake_flutter_test_sdk",
        ],
    )
    _modular_api_app_caller(
        name = "_modular_api_app",
        main = "modular_api_app_main.dart",
        srcs = ["modular_api_app_main.dart"],
        tags = ["manual"],
        deps = ["//flutter/tests/modular_api_fixture:dep_a"],
    )

    # Analysis negative: a caller-set `defines` has no whole-program fallback
    # to route to, so the build fails with the reason.
    _modular_api_test_caller(
        name = "_modular_api_test_defines",
        tags = ["manual"],
        deps = ["//flutter/tests/modular_api_fixture:dep_b"],
        defines = ["FOO=1"],
    )

    # Executed kernels: the app path links a real kernel in both modes. (The
    # test path's execution is the `e2e/hello_world` prebuilt run over the
    # same helpers, in both modes.)
    _modular_api_app_caller(
        name = "_modular_api_app_build",
        main = "modular_api_app_main.dart",
        srcs = ["modular_api_app_main.dart"],
        tags = ["manual"],
        target_compatible_with = HOST_COMPATIBLE,
        deps = ["//flutter/tests/modular_api_fixture:dep_a"],
    )
    _modular_api_app_caller(
        name = "_modular_api_app_based_build",
        main = "modular_api_app_main.dart",
        srcs = ["modular_api_app_main.dart"],
        tags = ["manual"],
        target_compatible_with = HOST_COMPATIBLE,
        use_base_dill = True,
        deps = [
            "//flutter/tests/modular_api_fixture:dep_a",
            "//flutter/tests/modular_api_sdk_fixture:fake_flutter_test_sdk",
        ],
    )

    _test_shapes_test(
        name = name + "_test_shapes",
        target_under_test = ":_modular_api_test",
    )
    _based_test_shapes_test(
        name = name + "_based_test_shapes",
        target_under_test = ":_modular_api_test_based",
    )
    _app_shapes_test(
        name = name + "_app_shapes",
        target_under_test = ":_modular_api_app",
    )
    _based_app_shapes_test(
        name = name + "_based_app_shapes",
        target_under_test = ":_modular_api_app_based_build",
    )
    _comma_stays_modular_test(
        name = name + "_comma_stays_modular",
        target_under_test = ":_modular_api_test",
    )
    _defines_reject_test(
        name = name + "_defines_reject",
        target_under_test = ":_modular_api_test_defines",
    )
    build_test(
        name = name + "_build",
        target_compatible_with = HOST_COMPATIBLE,
        targets = [
            ":_modular_api_app_build",
            ":_modular_api_app_based_build",
        ],
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_test_shapes",
            ":" + name + "_based_test_shapes",
            ":" + name + "_app_shapes",
            ":" + name + "_based_app_shapes",
            ":" + name + "_comma_stays_modular",
            ":" + name + "_defines_reject",
            ":" + name + "_build",
        ],
    )
