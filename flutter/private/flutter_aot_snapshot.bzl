"""Internal rule for producing an AOT-compiled artifact from Flutter sources.

Chains: sources → kernel .dill → gen_snapshot → platform-specific output.

On an Apple platform the dylib is gen_snapshot's, symbols intact, and the
relocatable object it was linked from is in the `macho_object` output group.
`flutter_ios_app` and `flutter_macos_app` strip the dylib they bundle and keep
a dSYM; this rule is the unbundled compile.

In debug mode, skips AOT and returns the kernel .dill directly (same as
flutter_application.bzl). Supports macOS/iOS (Mach-O .dylib) and other
platforms (ELF .so).
"""

load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")
load("//flutter/private:common.bzl", "FLUTTER_APPLICATION_ATTRS", "KERNEL_COMPILE_ATTRS", "PLATFORM_CONSTRAINT_ATTRS", "detect_target_platform", "flutter_build_mode", "flutter_compile_kernel", "host_target_arch")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_aot_compile.bzl", "GEN_SNAPSHOT_SETTINGS_ATTRS", "flutter_aot_elf_action", "flutter_aot_macho_action", "gen_snapshot_options")

visibility("//flutter/...")

def _flutter_aot_snapshot_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    is_debug = flutter_build_mode(ctx) == "debug"

    def _has(constraint):
        return ctx.target_platform_has_constraint(getattr(ctx.attr, constraint)[platform_common.ConstraintValueInfo])

    is_ios = _has("_ios_constraint")
    is_macos = _has("_macos_constraint")

    # The artifact runs on one OS, as `flutter build`'s does: the AOT kernel
    # is compiled for it (`--target-os`), and only that OS's plugins register.
    target_platform = detect_target_platform(
        is_ios,
        is_macos,
        _has("_linux_constraint"),
        _has("_windows_constraint"),
        _has("_android_constraint"),
    )

    # Step 1: Kernel compilation.
    compilation = flutter_compile_kernel(
        ctx,
        portable_tools(ctx),
        aot = not is_debug,
        target_platform = target_platform,
    )
    kernel_dill = compilation.kernel_dill
    output_groups = dict(compilation.import_checks)

    # In debug mode, return the kernel .dill directly (JIT, no gen_snapshot).
    if is_debug:
        return [DefaultInfo(files = depset([kernel_dill])), OutputGroupInfo(**output_groups)]

    # Step 2: AOT compile — choose format based on target platform.
    options = gen_snapshot_options(ctx, target_platform, host_target_arch(ctx, flutter_sdk_info))
    if options.debug_info:
        output_groups["debug_info"] = depset([options.debug_info])
    if options.files:
        output_groups["gen_snapshot_files"] = depset(options.files)

    if is_ios or is_macos:
        output = ctx.actions.declare_file(ctx.label.name + ".dylib")
        object = ctx.actions.declare_file(ctx.label.name + ".o")
        output_groups["macho_object"] = depset([object])
        flutter_aot_macho_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = output,
            extra_flags = options.flags,
            file_flags = options.file_flags,
            debug_info = options.debug_info,
            object = object,
        )
    else:
        output = ctx.actions.declare_file(ctx.label.name + ".so")
        flutter_aot_elf_action(
            ctx = ctx,
            gen_snapshot = flutter_sdk_info.gen_snapshot,
            kernel_dill = kernel_dill,
            output = output,
            strip = options.strip,
            extra_flags = options.flags,
            file_flags = options.file_flags,
            debug_info = options.debug_info,
            target_arch = flutter_sdk_info.target_arch,
        )

    return [
        DefaultInfo(files = depset([output])),
        OutputGroupInfo(**output_groups),
    ]

# The compile inputs arrive as a bundle, the gen_snapshot options by name.
# Taking them from the shared bundle rather than copying attrs keeps this rule
# from missing one `flutter_compile_kernel` reads — an attr reaching `ctx.attr`
# on a rule that never declared it fails at analysis.
_AOT_ATTRS = KERNEL_COMPILE_ATTRS | GEN_SNAPSHOT_SETTINGS_ATTRS | {
    "extra_gen_snapshot_options": FLUTTER_APPLICATION_ATTRS["extra_gen_snapshot_options"],
}

flutter_aot_snapshot = rule(
    implementation = _flutter_aot_snapshot_impl,
    attrs = dict(_AOT_ATTRS, **PLATFORM_CONSTRAINT_ATTRS),
    # The target's toolchain is for gen_snapshot; the kernel is `portable`.
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Compiles Flutter sources to an AOT artifact (.so or .dylib depending on target platform).",
)
