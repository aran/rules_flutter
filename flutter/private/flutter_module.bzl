"""Per-library kernel compilation for Flutter: the SDK description and the aspect.

rules_dart compiles each library target once into a kernel module, and an
executable compiles only its entrypoint against those modules and links them
(see rules_dart's `dart_module.bzl`). A module is valid only for the platform it
was compiled against, so Flutter has its own aspect, made over the Flutter SDK
described here, and its own modules.
"""

load("@rules_dart//dart:providers.bzl", "DartKernelSdkInfo")
load("@rules_dart//dart:utils.bzl", "dart_module_aspect")

def _flutter_kernel_sdk_impl(ctx):
    sdk = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    if not sdk.kernel_worker or not sdk.libraries_spec:
        fail(
            "The resolved Flutter toolchain cannot compile kernel modules: it " +
            "carries no kernel_worker or libraries_spec. Only a host toolchain " +
            "does; build Flutter tests for the host platform.",
        )
    return [DartKernelSdkInfo(
        target = "flutter",
        runtime = sdk.dartaotruntime,
        kernel_worker = sdk.kernel_worker,
        frontend_server = sdk.frontend_server,
        platform = sdk.platform_kernel_dill,
        sdk_root = sdk.platform_kernel_dill.dirname,
        libraries_spec = sdk.libraries_spec,
        libraries_target = "flutter",
        # What flutter_tools folds into a debug compile. A module is compiled
        # with an explicit environment, so a declaration left out here would
        # not be left to the engine: it would take the default the compiler
        # was given.
        defines = ["dart.vm.product=false", "dart.vm.profile=false"],
        tool_files = sdk.tool_files,
    )]

flutter_kernel_sdk = rule(
    implementation = _flutter_kernel_sdk_impl,
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
    doc = "The `DartKernelSdkInfo` for the debug Flutter platform, from the resolved Flutter toolchain.",
)

flutter_module_aspect = dart_module_aspect(
    Label("//flutter/private:flutter_kernel_sdk"),
    extra_dart_defines = Label("//flutter:extra_dart_defines"),
)
