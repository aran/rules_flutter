"""This module implements the Flutter SDK toolchain rule."""

load("//flutter:providers.bzl", "FlutterSdkInfo")

def _flutter_toolchain_impl(ctx):
    tool_files = depset(transitive = [ctx.attr.dart_sdk.files, ctx.attr.patched_sdk.files])

    flutter_sdk_info = FlutterSdkInfo(
        version = ctx.attr.version,
        engine_revision = ctx.attr.engine_revision,
        dart = ctx.file.dart,
        dartaotruntime = ctx.file.dartaotruntime,
        gen_snapshot = ctx.file.gen_snapshot,
        flutter_tester = ctx.file.flutter_tester,
        frontend_server = ctx.file.frontend_server,
        platform_kernel_dill = ctx.file.platform_kernel_dill,
        platform_kernel_dill_product = ctx.file.platform_kernel_dill_product,
        patched_sdk = ctx.attr.patched_sdk,
        icu_data = ctx.file.icu_data,
        const_finder = ctx.file.const_finder,
        font_subset = ctx.file.font_subset,
        impellerc = ctx.file.impellerc,
        shader_lib = ctx.files.shader_lib,
        material_icons_font = ctx.file.material_icons_font,
        vm_isolate_snapshot = ctx.file.vm_isolate_snapshot,
        isolate_snapshot = ctx.file.isolate_snapshot,
        tool_files = tool_files,
        engine_library = ctx.attr.engine_library,
        target_os = ctx.attr.target_os,
        target_arch = ctx.attr.target_arch,
        linux_sysroot = ctx.attr.linux_sysroot,
    )

    template_variables = platform_common.TemplateVariableInfo({
        "GEN_SNAPSHOT": ctx.file.gen_snapshot.path,
    })
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
            doc = "The Flutter SDK version string (e.g. `3.41.2`).",
            mandatory = True,
        ),
        "engine_revision": attr.string(
            doc = "The Flutter engine commit hash.",
            mandatory = True,
        ),
        "dart": attr.label(
            doc = "The `dart` executable from the Flutter-bundled Dart SDK.",
            mandatory = True,
            allow_single_file = True,
        ),
        "dartaotruntime": attr.label(
            doc = "The `dartaotruntime` executable for running AOT snapshots like frontend_server.",
            mandatory = True,
            allow_single_file = True,
        ),
        "gen_snapshot": attr.label(
            doc = "The `gen_snapshot` AOT compiler binary.",
            mandatory = True,
            allow_single_file = True,
        ),
        "flutter_tester": attr.label(
            doc = "The `flutter_tester` headless engine binary. Used by `flutter_test`.",
            allow_single_file = True,
        ),
        "frontend_server": attr.label(
            doc = "The `frontend_server_aot.dart.snapshot` file.",
            mandatory = True,
            allow_single_file = True,
        ),
        "platform_kernel_dill": attr.label(
            doc = "The `platform_strong.dill` debug platform kernel.",
            mandatory = True,
            allow_single_file = True,
        ),
        "platform_kernel_dill_product": attr.label(
            doc = "The `platform_strong_product.dill` release platform kernel.",
            mandatory = True,
            allow_single_file = True,
        ),
        "dart_sdk": attr.label(
            doc = "A filegroup containing the Flutter-bundled Dart SDK files.",
            mandatory = True,
        ),
        "patched_sdk": attr.label(
            doc = "A filegroup containing the Flutter patched Dart SDK files.",
            mandatory = True,
        ),
        "icu_data": attr.label(
            doc = "The `icudtl.dat` ICU data file.",
            mandatory = True,
            allow_single_file = True,
        ),
        "const_finder": attr.label(
            doc = "The `const_finder.dart.snapshot` for icon tree shaking.",
            allow_single_file = True,
        ),
        "font_subset": attr.label(
            doc = "The `font-subset` binary for font subsetting.",
            allow_single_file = True,
        ),
        "impellerc": attr.label(
            doc = "The `impellerc` shader compiler binary.",
            allow_single_file = True,
        ),
        "shader_lib": attr.label(
            doc = "The shader_lib/ directory contents (include files for impellerc).",
        ),
        "material_icons_font": attr.label(
            doc = "MaterialIcons-Regular.otf font file from the material_fonts artifact.",
            allow_single_file = True,
        ),
        "vm_isolate_snapshot": attr.label(
            doc = "The vm_isolate_snapshot.bin for debug VM bootstrap.",
            allow_single_file = True,
        ),
        "isolate_snapshot": attr.label(
            doc = "The isolate_snapshot.bin for debug isolate bootstrap (includes kernel service).",
            allow_single_file = True,
        ),
        "engine_library": attr.label(
            doc = "The platform-specific Flutter engine library (framework/so/dll). " +
                  "None for mobile/web targets or when engine is not available.",
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
    doc = "Defines a Flutter SDK toolchain. Typically generated by the `flutter_engine_artifacts` repository rule.",
)
