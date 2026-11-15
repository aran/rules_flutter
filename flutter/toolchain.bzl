"""The Flutter SDK toolchain rules.

`flutter_toolchain` is the SDK for one target platform, built on one host: its
`gen_snapshot` and engine are the target's. `flutter_exec_tools` is the part of
the SDK whose output does not depend on the target, for one host. Both are
assembled from the slices of an engine source (`//flutter:engine.bzl`).
"""

load("//flutter:engine.bzl", "FlutterEngineInfo", "FlutterGenSnapshotInfo", "FlutterHostToolsInfo", "FlutterPlatformKernelInfo")
load("//flutter:providers.bzl", "FlutterExecToolsInfo", "FlutterSdkInfo")

def _flutter_toolchain_impl(ctx):
    host = ctx.attr.host_tools[FlutterHostToolsInfo]
    kernel_debug = ctx.attr.platform_kernel_debug[FlutterPlatformKernelInfo]
    kernel_release = ctx.attr.platform_kernel_release[FlutterPlatformKernelInfo] if ctx.attr.platform_kernel_release else None
    gen_snapshot = ctx.attr.gen_snapshot[FlutterGenSnapshotInfo] if ctx.attr.gen_snapshot else None
    engine = ctx.attr.engine[FlutterEngineInfo] if ctx.attr.engine else None
    sdk_files = host.dart_sdk
    tool_files = depset(transitive = [sdk_files.all, kernel_debug.files])

    # Where each piece came from, for the record an app of a custom SDK keeps.
    slice_labels = {
        "host_tools": str(ctx.attr.host_tools.label),
        "platform_kernel": str((ctx.attr.platform_kernel_release or ctx.attr.platform_kernel_debug).label),
    }
    if ctx.attr.engine:
        slice_labels["engine"] = str(ctx.attr.engine.label)
    if ctx.attr.gen_snapshot:
        slice_labels["gen_snapshot"] = str(ctx.attr.gen_snapshot.label)

    flutter_sdk_info = FlutterSdkInfo(
        version = ctx.attr.version,
        engine_revision = ctx.attr.engine_revision,
        sdk = ctx.attr.sdk,
        sdk_defines = ctx.attr.sdk_defines,
        dart = host.dart,
        dartaotruntime = host.dartaotruntime,
        gen_snapshot = gen_snapshot.binary if gen_snapshot else None,
        flutter_tester = host.flutter_tester,
        frontend_server = host.frontend_server,
        kernel_worker = host.kernel_worker,
        dart_libraries_json = host.dart_libraries_json,
        platform_kernel_dill = kernel_debug.platform_dill,
        platform_kernel_dill_product = kernel_release.platform_dill if kernel_release else None,
        patched_sdk = ctx.attr.platform_kernel_debug,
        framework_json = ctx.file.framework_json,
        slice_labels = slice_labels,
        icu_data = host.icu_data,
        font_subset = host.font_subset,
        impellerc = host.impellerc,
        shader_lib = host.shader_lib,
        material_icons_font = ctx.file.material_icons_font,
        vm_isolate_snapshot = host.vm_isolate_snapshot,
        isolate_snapshot = host.isolate_snapshot,
        tool_files = tool_files,
        sdk_files = sdk_files,
        engine_library = ctx.attr.engine if ctx.attr.engine else None,
        host_tools = host,
        kernel_debug = kernel_debug,
        kernel_release = kernel_release,
        engine = engine,
        gen_snapshot_info = gen_snapshot,
        target_os = ctx.attr.target_os,
        target_arch = ctx.attr.target_arch,
        linux_sysroot = ctx.attr.linux_sysroot,
    )

    # `$(GEN_SNAPSHOT)` has no value where the toolchain compiles no snapshot.
    template_variables = platform_common.TemplateVariableInfo(
        {"GEN_SNAPSHOT": gen_snapshot.binary.path} if gen_snapshot else {},
    )
    default = DefaultInfo(
        files = tool_files,
        runfiles = ctx.runfiles(transitive_files = tool_files),
    )

    toolchain_info = platform_common.ToolchainInfo(
        flutter_sdk_info = flutter_sdk_info,
        template_variables = template_variables,
        default = default,
    )
    return [
        default,
        toolchain_info,
        template_variables,
    ]

flutter_toolchain = rule(
    implementation = _flutter_toolchain_impl,
    attrs = {
        "version": attr.string(
            doc = "The Flutter SDK version string (e.g. `3.47.2`).",
            mandatory = True,
        ),
        "engine_revision": attr.string(
            doc = "The Flutter engine commit hash.",
            mandatory = True,
        ),
        "sdk": attr.string(
            doc = "The name of the SDK this toolchain belongs to.",
            mandatory = True,
        ),
        "sdk_defines": attr.string_list(
            doc = "The defines that describe the SDK's framework and engine.",
        ),
        "host_tools": attr.label(
            doc = "The host tools of the execution platform: a `flutter_host_tools` slice.",
            mandatory = True,
            providers = [FlutterHostToolsInfo],
        ),
        "platform_kernel_debug": attr.label(
            doc = "The debug (non-product) platform kernel: a `flutter_platform_kernel` slice.",
            mandatory = True,
            providers = [FlutterPlatformKernelInfo],
        ),
        "platform_kernel_release": attr.label(
            doc = "The release (product) platform kernel: a `flutter_platform_kernel` slice. " +
                  "Leave unset where no release kernel is compiled (debug mode), so a source " +
                  "without one still serves a debug build.",
            providers = [FlutterPlatformKernelInfo],
        ),
        "gen_snapshot": attr.label(
            doc = "The target's gen_snapshot of the build mode: a `flutter_gen_snapshot` slice. " +
                  "Unset in debug mode, and for a toolchain that cannot compile a snapshot.",
            providers = [FlutterGenSnapshotInfo],
        ),
        "engine": attr.label(
            doc = "The target's engine of the build mode, so a `select()` on the mode picks it: " +
                  "a `flutter_<os>_engine` slice. Unset for web targets.",
            providers = [FlutterEngineInfo],
        ),
        "material_icons_font": attr.label(
            doc = "MaterialIcons-Regular.otf font file from the material_fonts artifact.",
            allow_single_file = True,
        ),
        "framework_json": attr.label(
            doc = "The `flutter_framework.json` of the SDK's framework, when it is not the release's.",
            allow_single_file = True,
        ),
        "target_os": attr.string(
            doc = "Cross-compilation target OS. Leave empty for native compilation.",
        ),
        "target_arch": attr.string(
            doc = "Cross-compilation target architecture. Leave empty for native compilation.",
        ),
        "linux_sysroot": attr.label(
            doc = "Chromium sysroot filegroup for hermetic Linux GTK3 header resolution. None on non-Linux platforms.",
        ),
    },
    doc = "Defines a Flutter SDK toolchain, assembled from the slices of an engine source. Generated per SDK by the extension.",
)

def _flutter_exec_tools_impl(ctx):
    host = ctx.attr.host_tools[FlutterHostToolsInfo]
    kernel_debug = ctx.attr.platform_kernel_debug[FlutterPlatformKernelInfo]
    kernel_release = ctx.attr.platform_kernel_release[FlutterPlatformKernelInfo] if ctx.attr.platform_kernel_release else None
    info = FlutterExecToolsInfo(
        version = ctx.attr.version,
        engine_revision = ctx.attr.engine_revision,
        sdk = ctx.attr.sdk,
        sdk_defines = ctx.attr.sdk_defines,
        host_os = host.host_os,
        host_arch = host.host_arch,
        dart = host.dart,
        dartaotruntime = host.dartaotruntime,
        frontend_server = host.frontend_server,
        kernel_worker = host.kernel_worker,
        dart_libraries_json = host.dart_libraries_json,
        platform_kernel_dill = kernel_debug.platform_dill,
        platform_kernel_dill_product = kernel_release.platform_dill if kernel_release else None,
        patched_sdk = ctx.attr.platform_kernel_debug,
        host_tools = host,
        flutter_tester = host.flutter_tester,
        icu_data = host.icu_data,
        vm_isolate_snapshot = host.vm_isolate_snapshot,
        isolate_snapshot = host.isolate_snapshot,
        font_subset = host.font_subset,
        impellerc = host.impellerc,
        shader_lib = host.shader_lib,
        shader_include_dir = host.shader_include_dir,
        sdk_files = host.dart_sdk,
    )
    return [platform_common.ToolchainInfo(flutter_exec_tools_info = info)]

flutter_exec_tools = rule(
    implementation = _flutter_exec_tools_impl,
    attrs = {
        "version": attr.string(doc = "The Flutter SDK version string.", mandatory = True),
        "engine_revision": attr.string(doc = "The Flutter engine commit hash.", mandatory = True),
        "sdk": attr.string(doc = "The name of the SDK these tools belong to.", mandatory = True),
        "sdk_defines": attr.string_list(doc = "The defines that describe the SDK's framework and engine."),
        "host_tools": attr.label(
            doc = "The host tools: a `flutter_host_tools` slice.",
            mandatory = True,
            providers = [FlutterHostToolsInfo],
        ),
        "platform_kernel_debug": attr.label(
            doc = "The debug platform kernel: a `flutter_platform_kernel` slice.",
            mandatory = True,
            providers = [FlutterPlatformKernelInfo],
        ),
        "platform_kernel_release": attr.label(
            doc = "The release platform kernel: a `flutter_platform_kernel` slice. Unset in debug mode.",
            providers = [FlutterPlatformKernelInfo],
        ),
    },
    doc = "The host tools of one Flutter SDK, for " +
          "`@rules_flutter//flutter:exec_tools_toolchain_type`. Generated per SDK by the extension.",
)
