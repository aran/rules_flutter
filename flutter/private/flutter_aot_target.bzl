"""Internal rule for producing an AOT-compiled artifact from Flutter sources.

Chains: sources → kernel .dill → gen_snapshot → platform-specific output.

In debug mode, skips AOT and returns the kernel .dill directly (same as
flutter_application.bzl). Supports macOS/iOS (Mach-O .dylib) and other
platforms (ELF .so).
"""

load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")
load("//flutter/private:common.bzl", "FLUTTER_APPLICATION_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "flutter_compile_kernel")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action", "flutter_aot_macho_action")

def _flutter_aot_target_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    bazel_mode = ctx.var["COMPILATION_MODE"]
    is_debug = bazel_mode == "dbg"

    # Step 1: Kernel compilation.
    kernel_dill = flutter_compile_kernel(ctx, flutter_sdk_info, aot = not is_debug).kernel_dill

    # In debug mode, return the kernel .dill directly (JIT, no gen_snapshot).
    if is_debug:
        return [DefaultInfo(files = depset([kernel_dill]))]

    # Step 2: AOT compile — choose format based on target platform.
    is_ios = ctx.target_platform_has_constraint(
        ctx.attr._ios_constraint[platform_common.ConstraintValueInfo],
    )
    is_macos = ctx.target_platform_has_constraint(
        ctx.attr._macos_constraint[platform_common.ConstraintValueInfo],
    )

    strip = bazel_mode == "opt"

    if is_ios or is_macos:
        output = ctx.actions.declare_file(ctx.label.name + ".dylib")
        flutter_aot_macho_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            flutter_sdk_files = flutter_sdk_info.tool_files,
            kernel_dill = kernel_dill,
            output = output,
            strip = strip,
        )
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".so")
        flutter_aot_elf_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            flutter_sdk_files = flutter_sdk_info.tool_files,
            kernel_dill = kernel_dill,
            output = output,
            strip = strip,
        )

    return [
        DefaultInfo(files = depset([output])),
    ]

# flutter_aot_target needs core compilation attrs plus AOT-specific options.
_AOT_ATTRS = {k: v for k, v in FLUTTER_APPLICATION_ATTRS.items() if k in (
    "main",
    "package_name",
    "srcs",
    "deps",
    "defines",
    "profile",
    "obfuscate",
    "split_debug_info",
    "extra_gen_snapshot_options",
)}

flutter_aot_target = rule(
    implementation = _flutter_aot_target_impl,
    attrs = dict(_AOT_ATTRS, **PLATFORM_CONSTRAINT_ATTRS),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles Flutter sources to an AOT artifact (.so or .dylib depending on target platform).",
)
