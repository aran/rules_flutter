"""A test kernel compiled by hand over the public `flutter:utils.bzl` helpers.

The `flutter_test_bootstrap` docstring's example as a running target: instead
of `flutter_test` compiling the suite, this rule writes the bootstrap with
`flutter_test_bootstrap`, compiles it as the kernel entry point with
`flutter_kernel_compile_action`, extracts the suite's `@Tags` with the public
`//flutter/private/tools:extract_library_tags` tool, and exposes the products
as the `test_kernel` / `test_base_kernel` / `test_library_tags` output groups
`flutter_prebuilt_test` feeds on. A `flutter_test` on the same suite stays
beside each instance as the oracle: same sources, same assets, same result.

Loads are public only (`@rules_flutter//flutter:utils.bzl` plus public
`@rules_dart` helpers) with two cross-module labels: the golden comparator
default `FLUTTER_TEST_BOOTSTRAP_ATTRS` carries, and the tags extractor below.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs")
load(
    "@rules_flutter//flutter:utils.bzl",
    "FLUTTER_KERNEL_COMPILE_ATTRS",
    "FLUTTER_KERNEL_COMPILE_TOOLCHAINS",
    "FLUTTER_TEST_BOOTSTRAP_ATTRS",
    "compile_package_config",
    "flutter_kernel_compile_action",
    "flutter_kernel_compile_tools",
    "flutter_test_bootstrap",
)

def _custom_test_kernel_impl(ctx):
    tools = flutter_kernel_compile_tools(ctx)
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")

    # The suite sits outside any `lib/`, so no `package:` URI names it. Import
    # it by path from the bootstrap instead: climb out of the bootstrap's
    # directory, then descend to the suite's exec-root-relative path. The
    # kernel guard accepts the import because it resolves to a declared input
    # (see `resolveFlutterKeyRelativeTarget`), and the compiler finds it
    # materialized at its exec path under every execution strategy. The climb
    # keeps working now the default entrypoint is the `org-dartlang-app:///`
    # URI: URI resolution drops the excess `..` segments at the scheme root,
    # so the same spelling lands on the staged source.
    test_main_uri = "../" * len(bootstrap.path.split("/")[:-1]) + ctx.file.main.path
    comparator = flutter_test_bootstrap(ctx, test_main_uri, bootstrap)

    packages = collect_packages(ctx.attr.deps)
    all_srcs = depset(
        ctx.files.srcs +
        collect_transitive_srcs(ctx.attr.deps).to_list() +
        [ctx.file.main, bootstrap] +
        ([comparator] if comparator else []),
    ).to_list()
    pc = compile_package_config(ctx, packages, all_srcs)

    kernel = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = tools.dartaotruntime,
        kernel_filter_tool = tools.kernel_filter_tool,
        frontend_server = tools.frontend_server,
        platform_dill = tools.platform_dill,
        main = bootstrap,
        srcs = pc.srcs,
        package_config = pc.config_file,
        output = kernel,
    )

    # The suite's own `@Tags`, extracted the way `extract_library_tags_action`
    # extracts them for `flutter_test`: only the entrypoint file is read, and
    # the JSON reaches every test through the suite's root group.
    library_tags = ctx.actions.declare_file(ctx.label.name + ".library_tags.json")
    ctx.actions.run(
        executable = ctx.executable._library_tags_tool,
        arguments = [ctx.file.main.path, library_tags.path],
        inputs = [ctx.file.main],
        outputs = [library_tags],
        mnemonic = "FlutterExtractLibraryTags",
        progress_message = "Extracting library tags %s" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([kernel])),
        # The kernel is compiled whole-program, so `test_base_kernel` is empty
        # rather than absent, as on a `flutter_test` that linked no base dill.
        OutputGroupInfo(
            test_kernel = depset([kernel]),
            test_base_kernel = depset(),
            test_library_tags = depset([library_tags]),
        ),
    ]

custom_test_kernel = rule(
    implementation = _custom_test_kernel_impl,
    attrs = {
        "main": attr.label(
            doc = "The test entrypoint .dart source.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Dart sources of the test's own package (its `lib/`).",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "DartInfo dependencies, including the test's own package " +
                  "library so `package:<name>/...` imports resolve.",
            providers = [DartInfo],
        ),
        "_library_tags_tool": attr.label(
            doc = "The `@Tags` extractor run over the entrypoint.",
            default = Label("@rules_flutter//flutter/private/tools:extract_library_tags"),
            executable = True,
            cfg = "exec",
        ),
    } | FLUTTER_KERNEL_COMPILE_ATTRS | FLUTTER_TEST_BOOTSTRAP_ATTRS,
    toolchains = FLUTTER_KERNEL_COMPILE_TOOLCHAINS,
)
