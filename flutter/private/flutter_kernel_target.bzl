"""Internal rule for compiling Flutter sources to a kernel .dill file.

This is the base compilation step shared by all Flutter platform targets.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS")
load("//flutter/private:common.bzl", "AGENT_EXTENSIONS_ATTR", "flutter_compile_kernel")

def _flutter_kernel_target_impl(ctx):
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    flutter_sdk_info = flutter_toolchain.flutter_sdk_info

    # flutter_compile_kernel handles mode-aware platform dill selection.
    # If the user explicitly requests AOT, force it regardless of mode.
    # None lets flutter_compile_kernel decide based on COMPILATION_MODE;
    # True forces AOT even in debug mode.
    aot = True if ctx.attr.aot else None
    kernel_dill = flutter_compile_kernel(ctx, flutter_sdk_info, aot = aot).kernel_dill

    return [
        DefaultInfo(files = depset([kernel_dill])),
    ]

flutter_kernel_target = rule(
    implementation = _flutter_kernel_target_impl,
    attrs = {
        "main": attr.label(
            doc = "The main .dart entry point.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "package_name": attr.string(
            doc = "Dart package name (same value as `pubspec.yaml`'s `name:`). " +
                  "Required: keys the kernel's libraries under stable `package:` URIs " +
                  "(hot-reload parity with the dev tool), anchors codegen sibling " +
                  "co-location, and resolves `package:<self>/...` imports.",
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = "Additional Dart source files.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "dart_library or flutter_library dependencies.",
            providers = [DartInfo],
        ),
        "aot": attr.bool(
            doc = "If True, compile for AOT (--aot --tfa). Automatically True in opt/fastbuild mode.",
            default = False,
        ),
        "defines": attr.string_list(
            doc = "Dart environment defines (-D flags).",
        ),
    } | AGENT_EXTENSIONS_ATTR,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
    ] + COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Compiles Flutter sources to a kernel .dill file.",
)
