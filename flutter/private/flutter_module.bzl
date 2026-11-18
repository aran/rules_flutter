"""Flutter's kernel platform: the SDK description, and the aspect that compiles modules against it.

rules_dart compiles each library target once into a kernel module, and an
executable compiles only its entrypoint against those modules and links them
(see rules_dart's `dart_module.bzl`); a whole program is compiled from source
in one action (`dart_whole_program_kernel_action`). A kernel is valid only for
the platform it was compiled against, so Flutter describes its own here, from
the selected SDK, and has its own aspect and modules.
"""

load("@rules_dart//dart:providers.bzl", "DartKernelSdkInfo")
load("@rules_dart//dart:utils.bzl", "dart_kernel_runtime", "dart_module_aspect")
load("//flutter/private:exec_groups.bzl", "FLUTTER_EXEC_TOOLS")

visibility("//flutter/...")

# The libraries whose classes' `toString` an optimized build reduces to the
# default, as flutter_tools' `buildModeOptions` asks for profile and release.
_DELETE_TOSTRING = [
    "--delete-tostring-package-uri=dart:ui",
    "--delete-tostring-package-uri=package:flutter",
]

def flutter_kernel_sdk_info(sdk, libraries_spec = None, extra_defines = [], outline_tool = None):
    """The `DartKernelSdkInfo` of one Flutter SDK's platform.

    A runtime per build mode, as flutter_tools compiles for each
    (`buildModeOptions` in `compile.dart`): debug and profile against the
    non-product platform, which keeps the VM service and the profiling hooks,
    and release against the product one. Each fixes `dart.vm.profile` and
    `dart.vm.product`, constants the front end folds, so a kernel for one mode
    cannot run as another's. Profile and release also drop the `toString`
    bodies of `dart:ui` and `package:flutter` classes, as `flutter build` does,
    for a smaller snapshot.

    Args:
      sdk: A `FlutterSdkInfo` or `FlutterExecToolsInfo` of the selected SDK,
        for the host the compile runs on.
      libraries_spec: The `libraries.json` naming the `dart:` libraries a
        Flutter program can import, which modules compile against; None for
        a whole-program compile, which reads the platform dill instead.
      extra_defines: Declarations every compile against this SDK carries, for
        modules (a module's constants are folded when it is compiled, so what
        describes the SDK to the program cannot wait for the link). A
        whole-program compile adds the SDK's to its own environment instead.
      outline_tool: The executable (a `FilesToRunProvider`) that writes a
        module's outline, which its dependents compile against so an edit
        inside a function body does not compile them again; None to compile
        them against the full kernels.

    Returns:
      The `DartKernelSdkInfo`. It has a `release` runtime only where `sdk`
      has the product platform, which a debug build does not fetch.
    """
    runtimes = {
        "debug": dart_kernel_runtime(
            sdk.platform_kernel_dill,
            defines = ["dart.vm.profile=false", "dart.vm.product=false"] + extra_defines,
        ),
        "profile": dart_kernel_runtime(
            sdk.platform_kernel_dill,
            defines = ["dart.vm.profile=true", "dart.vm.product=false"] + extra_defines,
            flags = _DELETE_TOSTRING,
        ),
    }
    if sdk.platform_kernel_dill_product:
        runtimes["release"] = dart_kernel_runtime(
            sdk.platform_kernel_dill_product,
            defines = ["dart.vm.profile=false", "dart.vm.product=true"] + extra_defines,
            flags = _DELETE_TOSTRING,
        )
    return DartKernelSdkInfo(
        target = "flutter",
        aot_runtime = sdk.dartaotruntime,
        kernel_worker = sdk.kernel_worker,
        frontend_server = sdk.frontend_server,
        runtimes = runtimes,
        # Modules are what a test links, and `flutter test` compiles debug.
        module_runtime = "debug",
        libraries_spec = libraries_spec,
        libraries_target = "flutter",
        # The compilers read the files named above and nothing else of the SDK.
        tool_files = depset(),
        outline_tool = outline_tool,
    )

def _flutter_kernel_sdk_impl(ctx):
    sdk = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    if not sdk.kernel_worker or not sdk.dart_libraries_json:
        fail(
            "The resolved Flutter toolchain cannot compile kernel modules: it " +
            "carries no kernel_worker or Dart libraries spec. Only a host toolchain " +
            "does; build Flutter tests for the host platform.",
        )

    # The libraries Flutter provides, derived from the Dart SDK's own spec.
    libraries_spec = ctx.actions.declare_file(ctx.label.name + "/flutter_libraries.json")
    ctx.actions.run(
        executable = sdk.dart,
        arguments = [
            ctx.file._libraries_spec_tool.path,
            "--sdk-libraries=" + sdk.dart_libraries_json.path,
            "--output=" + libraries_spec.path,
        ],
        inputs = depset([ctx.file._libraries_spec_tool, sdk.dart_libraries_json], transitive = [sdk.sdk_files.run]),
        outputs = [libraries_spec],
        mnemonic = "FlutterLibrariesSpec",
        toolchain = "@rules_flutter//flutter:toolchain_type",
        progress_message = "Deriving Flutter's libraries.json for %s" % ctx.label,
    )
    outline_tool = ctx.attr.outline_tool[DefaultInfo].files_to_run if ctx.attr.outline_tool else None
    return [flutter_kernel_sdk_info(sdk, libraries_spec, list(sdk.sdk_defines), outline_tool)]

flutter_kernel_sdk = rule(
    implementation = _flutter_kernel_sdk_impl,
    attrs = {
        # Built for the platform this target is configured for: the host the
        # modules compile on, since the aspect builds it in that exec group.
        "outline_tool": attr.label(executable = True, cfg = "target"),
        "_libraries_spec_tool": attr.label(
            default = "//flutter/private/tools:libraries_spec.dart",
            allow_single_file = True,
        ),
    },
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
    doc = "The `DartKernelSdkInfo` Flutter's kernel modules compile against, from the resolved Flutter toolchain.",
)

# The modules compile on a `portable` host that has the Flutter tools as well
# as a Dart SDK: `flutter_kernel_sdk` is built for that host.
flutter_module_aspect = dart_module_aspect(
    Label("//flutter/private:flutter_kernel_sdk"),
    exec_toolchains = [FLUTTER_EXEC_TOOLS],
)
