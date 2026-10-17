"""Internal rule for producing an AOT-compiled artifact from Flutter sources.

Chains: sources → kernel .dill → gen_snapshot → platform-specific output.

In debug mode, skips AOT and returns the kernel .dill directly (same as
flutter_application.bzl). Supports macOS/iOS (Mach-O .dylib) and other
platforms (ELF .so).
"""

load("//flutter/private:common.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "FLUTTER_APPLICATION_ATTRS", "KERNEL_COMPILE_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "flutter_build_mode", "flutter_compile_kernel", "resolve_flutter_sdk_info")
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action", "flutter_aot_macho_action")

def _flutter_aot_target_impl(ctx):
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)

    is_debug = flutter_build_mode(ctx) == "debug"

    # Guard: AOT cross-compilation between desktop OSes is not supported.
    # target_os is non-empty only for cross-compilation toolchains.
    if not is_debug and flutter_sdk_info.target_os in ("linux", "macos", "windows"):
        fail(
            "AOT cross-compilation between desktop platforms is not supported. " +
            "Flutter's gen_snapshot can only produce native code for the host OS. " +
            "Build on the target platform, or use debug mode (-c dbg).",
        )
    if not is_debug and not flutter_sdk_info.gen_snapshot:
        fail(
            (
                "No target-compatible AOT gen_snapshot toolchain is registered for this " +
                "host and target platform (target_os=%s). Apple AOT snapshots require a " +
                "Darwin-target gen_snapshot on a macOS host; build on macOS or use debug mode (-c dbg)."
            ) % (
                flutter_sdk_info.target_os or "native",
            ),
        )

    # Step 1: Kernel compilation.
    kernel_dill = flutter_compile_kernel(
        ctx,
        flutter_sdk_info,
        aot = not is_debug,
    ).kernel_dill

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

    strip = ctx.var["COMPILATION_MODE"] == "opt"

    if is_ios or is_macos:
        output = ctx.actions.declare_file(ctx.label.name + ".dylib")
        flutter_aot_macho_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = output,
            strip = strip,
            min_os_version = ctx.attr.min_os_version if ctx.attr.min_os_version else None,
        )
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".so")
        flutter_aot_elf_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = output,
            strip = strip,
        )

    return [
        DefaultInfo(files = depset([output])),
    ]

# The compile inputs arrive as a bundle, the gen_snapshot options by name.
# Taking them from the shared bundle rather than copying attrs keeps this rule
# from missing one `flutter_compile_kernel` reads — an attr reaching `ctx.attr`
# on a rule that never declared it fails at analysis.
_AOT_ATTRS = KERNEL_COMPILE_ATTRS | {k: v for k, v in FLUTTER_APPLICATION_ATTRS.items() if k in (
    "obfuscate",
    "split_debug_info",
    "extra_gen_snapshot_options",
    "min_os_version",
)}

flutter_aot_target = rule(
    implementation = _flutter_aot_target_impl,
    attrs = dict(_AOT_ATTRS, **PLATFORM_CONSTRAINT_ATTRS),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_flutter//flutter/private:aot_toolchain_type", mandatory = False),
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles Flutter sources to an AOT artifact (.so or .dylib depending on target platform).",
)
