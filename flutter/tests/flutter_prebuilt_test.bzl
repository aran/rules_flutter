"""Analysis tests for `flutter_prebuilt_test` and the `flutter_test` output groups.

`flutter_prebuilt_test` runs an already built test kernel: its own actions
must contain no compile (no `FlutterKernelCompile`, no `DartKernel` module
compile or `DartKernelLink`), only what the runner needs. The kernel it runs
comes from a `flutter_test`'s `test_kernel` / `test_base_kernel` /
`test_assets` / `test_library_tags` output groups, and the custom-compile path
composes from the public `//flutter:utils.bzl` helpers (`flutter_test_bootstrap`
plus `flutter_kernel_compile_action`, with `FLUTTER_TEST_BOOTSTRAP_ATTRS` in
the caller's attrs) without loading `//flutter/private`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:defs.bzl", "flutter_prebuilt_test", "flutter_test")
load(
    "//flutter:utils.bzl",
    "FLUTTER_KERNEL_COMPILE_ATTRS",
    "FLUTTER_KERNEL_COMPILE_TOOLCHAINS",
    "FLUTTER_TEST_BOOTSTRAP_ATTRS",
    "compile_package_config",
    "flutter_kernel_compile_action",
    "flutter_kernel_compile_tools",
    "flutter_test_bootstrap",
)
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")

_PACKAGE = "inputs_fixture"
_MAIN = "lib/language_version_main.dart"
_BOOTSTRAP_URI = "package:prebuilt_probe/main.dart"

# Mnemonics that compile Dart: a prebuilt test's own actions must hold none
# of these. `frontend_server` runs inside `FlutterKernelCompile`, and modular
# compiles are `DartKernel` plus `DartKernelLink`, so the three cover every
# way this repo turns sources into a kernel.
_COMPILE_MNEMONICS = ["FlutterKernelCompile", "DartKernel", "DartKernelLink"]

def _prebuilt_no_compile_test_impl(ctx):
    """A `flutter_prebuilt_test`'s own actions compile nothing."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    compile_actions = [
        a
        for a in actions
        if a.mnemonic in _COMPILE_MNEMONICS
    ]
    asserts.equals(
        env,
        [],
        [a.mnemonic for a in compile_actions],
        "flutter_prebuilt_test must run no compile action, got %s" % (
            [a.mnemonic for a in actions]
        ),
    )

    # The runner contract is still fully wired: the kernel, its assets, the
    # engine and ICU data reach the test through runfiles, which is what the
    # runner resolves at start-up, so the run executes.
    runfile_paths = [
        f.path
        for f in analysistest.target_under_test(env)[DefaultInfo].default_runfiles.files.to_list()
    ]
    asserts.true(
        env,
        any([p.endswith("_prebuilt_inputs_test.dill") for p in runfile_paths]),
        "the fed kernel must be in runfiles",
    )
    asserts.true(
        env,
        any(["flutter_tester" in p for p in runfile_paths]),
        "flutter_tester must be in runfiles",
    )
    asserts.true(
        env,
        any([p.endswith(".library_tags.json") for p in runfile_paths]),
        "the fed library tags must be in runfiles",
    )
    return analysistest.end(env)

def _output_groups_test_impl(ctx):
    """`flutter_test` exposes its kernel, base kernel, assets and tags as output groups."""
    env = analysistest.begin(ctx)
    groups = analysistest.target_under_test(env)[OutputGroupInfo]

    kernels = groups.test_kernel.to_list()
    asserts.equals(env, 1, len(kernels), "expected one test_kernel file")
    if kernels:
        asserts.true(
            env,
            kernels[0].basename.endswith(".dill"),
            "test_kernel must be the test .dill, got %r" % kernels[0].basename,
        )

    # The fixture's closure carries no `package:flutter_test`, so no base
    # dill is linked at run time and the group is empty rather than absent.
    asserts.equals(
        env,
        [],
        groups.test_base_kernel.to_list(),
        "expected an empty test_base_kernel without a base dill",
    )

    assets = groups.test_assets.to_list()
    asserts.equals(env, 1, len(assets), "expected one test_assets tree")

    tags = groups.test_library_tags.to_list()
    asserts.equals(env, 1, len(tags), "expected one test_library_tags file")
    if tags:
        asserts.true(
            env,
            tags[0].basename.endswith(".library_tags.json"),
            "test_library_tags must be the entrypoint's @Tags JSON, got %r" % tags[0].basename,
        )
    return analysistest.end(env)

def _bootstrap_pipeline_test_impl(ctx):
    """A custom pipeline over the public utils writes and compiles the bootstrap."""
    env = analysistest.begin(ctx)

    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterKernelCompile"
    ]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    if kernels:
        input_paths = [f.path for f in kernels[0].inputs.to_list()]
        asserts.true(
            env,
            any([p.endswith("_bootstrap_pipeline_caller_bootstrap.dart") for p in input_paths]),
            "the bootstrap must be a compile input",
        )

    writes = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and
           a.outputs.to_list()[0].basename.endswith("_bootstrap.dart")
    ]
    asserts.equals(env, 1, len(writes), "expected one bootstrap write")
    if writes:
        content = writes[0].content
        asserts.true(
            env,
            _BOOTSTRAP_URI in content,
            "the bootstrap must import the test URI",
        )
        asserts.true(
            env,
            "RemoteListener.start" in content,
            "the bootstrap must drive RemoteListener",
        )
        asserts.true(
            env,
            "goldens" not in content,
            "a test_api-only closure gets no golden block",
        )
    return analysistest.end(env)

_prebuilt_no_compile_test = analysistest.make(_prebuilt_no_compile_test_impl)
_output_groups_test = analysistest.make(_output_groups_test_impl)
_bootstrap_pipeline_test = analysistest.make(_bootstrap_pipeline_test_impl)

def _bootstrap_pipeline_caller_impl(ctx):
    """A downstream-style prebuilt kernel compile over the public utils only.

    Writes the bootstrap with `flutter_test_bootstrap`, then compiles it as
    the kernel entry point — the custom pipeline the `flutter_prebuilt_test`
    docs describe. Merges `FLUTTER_TEST_BOOTSTRAP_ATTRS` (the golden
    comparator default must resolve for the rule to analyze); `deps` is empty,
    so no comparator is staged and no golden block is emitted.
    """
    tools = flutter_kernel_compile_tools(ctx)
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    comparator = flutter_test_bootstrap(ctx, _BOOTSTRAP_URI, bootstrap)
    all_srcs = [bootstrap, ctx.file.main] + ([comparator] if comparator else [])
    pc = compile_package_config(ctx, [], all_srcs)
    output = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = tools.dartaotruntime,
        kernel_filter_tool = tools.kernel_filter_tool,
        frontend_server = tools.frontend_server,
        platform_dill = tools.platform_dill,
        main = bootstrap,
        srcs = pc.srcs,
        package_config = pc.config_file,
        output = output,
    )
    return [DefaultInfo(files = depset([output]))]

_bootstrap_pipeline_caller = rule(
    implementation = _bootstrap_pipeline_caller_impl,
    attrs = {
        "main": attr.label(
            doc = "The test entrypoint .dart source.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
    } | FLUTTER_KERNEL_COMPILE_ATTRS | FLUTTER_TEST_BOOTSTRAP_ATTRS,
    toolchains = FLUTTER_KERNEL_COMPILE_TOOLCHAINS,
)

def flutter_prebuilt_test_suite(name):
    """Fixtures and tests for `flutter_prebuilt_test`.

    Args:
        name: The test suite name.
    """
    flutter_test(
        name = "_prebuilt_inputs_test",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    native.filegroup(
        name = "_prebuilt_inputs_kernel",
        srcs = [":_prebuilt_inputs_test"],
        output_group = "test_kernel",
        tags = ["manual"],
        testonly = True,
    )
    native.filegroup(
        name = "_prebuilt_inputs_base_kernel",
        srcs = [":_prebuilt_inputs_test"],
        output_group = "test_base_kernel",
        tags = ["manual"],
        testonly = True,
    )
    native.filegroup(
        name = "_prebuilt_inputs_assets",
        srcs = [":_prebuilt_inputs_test"],
        output_group = "test_assets",
        tags = ["manual"],
        testonly = True,
    )
    native.filegroup(
        name = "_prebuilt_inputs_tags",
        srcs = [":_prebuilt_inputs_test"],
        output_group = "test_library_tags",
        tags = ["manual"],
        testonly = True,
    )
    flutter_prebuilt_test(
        name = "_prebuilt_test",
        dill = ":_prebuilt_inputs_kernel",
        base_dill = [":_prebuilt_inputs_base_kernel"],
        assets = ":_prebuilt_inputs_assets",
        library_tags = ":_prebuilt_inputs_tags",
        tags = ["manual"],
    )
    _bootstrap_pipeline_caller(
        name = "_bootstrap_pipeline_caller",
        main = "compile_api_main.dart",
        tags = ["manual"],
    )

    _prebuilt_no_compile_test(
        name = name + "_no_compile",
        target_under_test = ":_prebuilt_test",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _output_groups_test(
        name = name + "_output_groups",
        target_under_test = ":_prebuilt_inputs_test",
        target_compatible_with = HOST_COMPATIBLE,
    )
    _bootstrap_pipeline_test(
        name = name + "_bootstrap_pipeline",
        target_under_test = ":_bootstrap_pipeline_caller",
        target_compatible_with = HOST_COMPATIBLE,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_no_compile",
            ":" + name + "_output_groups",
            ":" + name + "_bootstrap_pipeline",
        ],
    )
