"""Consumer-module caller over the public compile API only.

This module (`rules_flutter_smoke_test`) is a *different* Bazel module from
`rules_flutter`: it reaches the helpers exclusively through
`@rules_flutter//flutter:utils.bzl` (plus public `@rules_dart` helpers). If
every target `FLUTTER_KERNEL_COMPILE_ATTRS` names is not visible outside
`rules_flutter`, analysis of the rules below fails — so this file is the
cross-module visibility proof for `flutter:utils.bzl`.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs")
load("@rules_flutter//flutter:utils.bzl", "FLUTTER_KERNEL_COMPILE_ATTRS", "FLUTTER_KERNEL_COMPILE_TOOLCHAINS", "compile_package_config", "flutter_kernel_compile_action", "flutter_kernel_compile_tools")

_CONSUMER_RESOURCE_SET = {"memory": 8000, "cpu": 1}

def _consumer_caller_impl(ctx):
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
        resource_set = _CONSUMER_RESOURCE_SET if ctx.attr.use_resource_set else None,
        extra_flags = ctx.attr.extra_flags,
    )
    return [DefaultInfo(files = depset([output]))]

consumer_caller = rule(
    implementation = _consumer_caller_impl,
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
