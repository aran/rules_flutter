"""Internal rule for compiling Flutter sources to a kernel .dill file.

This is the base compilation step shared by all Flutter platform targets.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "MODULAR_KERNEL_ATTRS", "MODULAR_KERNEL_TOOLCHAINS")
load("//flutter/private:common.bzl", "AGENT_EXTENSIONS_ATTR", "COPY_TO_DIRECTORY_TOOLCHAINS", "FLUTTER_DEPS_DOC", "KERNEL_COMPILE_ATTRS", "flutter_compile_kernel", "resolve_flutter_sdk_info")
load("//flutter/private:flutter_kernel_module.bzl", "flutter_kernel_module_aspect")

def _flutter_kernel_target_impl(ctx):
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)
    kernel_dill = flutter_compile_kernel(ctx, flutter_sdk_info, aot = True if ctx.attr.aot else None).kernel_dill

    return [
        DefaultInfo(files = depset([kernel_dill])),
    ]

flutter_kernel_target = rule(
    implementation = _flutter_kernel_target_impl,
    # The compile inputs come from the shared bundle rather than a copy of it,
    # so this rule cannot drift from what `flutter_compile_kernel` reads.
    attrs = KERNEL_COMPILE_ATTRS | {
        "deps": attr.label_list(
            doc = FLUTTER_DEPS_DOC,
            providers = [DartInfo],
            aspects = [flutter_kernel_module_aspect],
        ),
        "aot": attr.bool(
            doc = "If True, compile for AOT (--aot --tfa). Automatically True in opt/fastbuild mode.",
            default = False,
        ),
    } | AGENT_EXTENSIONS_ATTR | MODULAR_KERNEL_ATTRS,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles Flutter sources to a kernel .dill file.",
)
