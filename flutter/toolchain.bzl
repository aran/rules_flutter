"""The Flutter SDK toolchain rules.

`flutter_toolchain` is the SDK for one target platform, built on one host: its
`gen_snapshot` and engine are the target's. `flutter_exec_tools` is the part of
the SDK whose output does not depend on the target, for one host.
"""

load("//flutter:providers.bzl", "FlutterExecToolsInfo", "FlutterSdkInfo")

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
        kernel_worker = ctx.file.kernel_worker,
        libraries_spec = ctx.file.libraries_spec,
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
        "kernel_worker": attr.label(
            doc = "The `kernel_worker_aot.dart.snapshot`, which compiles one library target to a kernel module.",
            allow_single_file = True,
        ),
        "libraries_spec": attr.label(
            doc = "A `libraries.json` whose `flutter` target names the dart: libraries a " +
                  "Flutter program can import.",
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

def _shader_include_dir(ctx):
    """The execution path of `shader_include_dir`, checked to hold every `shader_lib` file.

    A source path: path mapping rewrites only output paths, so actions pass
    it as a string.
    """
    if not ctx.files.shader_lib:
        fail("%s: `shader_lib` has no files" % ctx.label)
    anchor = ctx.files.shader_lib[0]
    if not anchor.is_source:
        fail("%s: `shader_lib` must be source files, not %s" % (ctx.label, anchor.path))

    # The anchor's path less its package-relative name is its package's
    # directory, wherever the repository layout puts external repositories.
    in_package = anchor.owner.name
    package_dir = anchor.path[:-len(in_package)].rstrip("/")
    include_dir = "/".join([d for d in [package_dir, ctx.attr.shader_include_dir] if d])
    for f in ctx.files.shader_lib:
        if not f.path.startswith(include_dir + "/"):
            fail("%s: %s is not under `shader_include_dir` (%s)" % (ctx.label, f.path, include_dir))
    return include_dir

def _flutter_exec_tools_impl(ctx):
    tool_files = depset(transitive = [ctx.attr.dart_sdk.files, ctx.attr.patched_sdk.files])
    info = FlutterExecToolsInfo(
        version = ctx.attr.version,
        engine_revision = ctx.attr.engine_revision,
        host_os = ctx.attr.host_os,
        host_arch = ctx.attr.host_arch,
        dart = ctx.file.dart,
        dartaotruntime = ctx.file.dartaotruntime,
        frontend_server = ctx.file.frontend_server,
        kernel_worker = ctx.file.kernel_worker,
        libraries_spec = ctx.file.libraries_spec,
        platform_kernel_dill = ctx.file.platform_kernel_dill,
        platform_kernel_dill_product = ctx.file.platform_kernel_dill_product,
        patched_sdk = ctx.attr.patched_sdk,
        flutter_tester = ctx.file.flutter_tester,
        icu_data = ctx.file.icu_data,
        vm_isolate_snapshot = ctx.file.vm_isolate_snapshot,
        isolate_snapshot = ctx.file.isolate_snapshot,
        const_finder = ctx.file.const_finder,
        font_subset = ctx.file.font_subset,
        impellerc = ctx.file.impellerc,
        shader_lib = ctx.files.shader_lib,
        shader_include_dir = _shader_include_dir(ctx),
        tool_files = tool_files,
    )
    return [platform_common.ToolchainInfo(flutter_exec_tools_info = info)]

def _file(doc):
    return attr.label(doc = doc, mandatory = True, allow_single_file = True)

flutter_exec_tools = rule(
    implementation = _flutter_exec_tools_impl,
    attrs = {
        "version": attr.string(doc = "The Flutter SDK version string.", mandatory = True),
        "engine_revision": attr.string(doc = "The Flutter engine commit hash.", mandatory = True),
        "host_os": attr.string(doc = "The OS the tools run on.", mandatory = True, values = ["macos", "linux", "windows"]),
        "host_arch": attr.string(doc = "The CPU the tools run on.", mandatory = True, values = ["arm64", "x64"]),
        "dart": _file("The `dart` executable."),
        "dartaotruntime": _file("The `dartaotruntime` executable."),
        "dart_sdk": attr.label(doc = "A filegroup of the Flutter-bundled Dart SDK.", mandatory = True),
        "frontend_server": _file("`frontend_server_aot.dart.snapshot`."),
        "kernel_worker": _file("`kernel_worker_aot.dart.snapshot`."),
        "libraries_spec": _file("The Flutter `libraries.json`."),
        "platform_kernel_dill": _file("The debug `platform_strong.dill`."),
        "platform_kernel_dill_product": _file("The release `platform_strong.dill`."),
        "patched_sdk": attr.label(doc = "A filegroup of the Flutter patched SDK.", mandatory = True),
        "flutter_tester": _file("The `flutter_tester` binary."),
        "icu_data": _file("`icudtl.dat`."),
        "vm_isolate_snapshot": _file("`vm_isolate_snapshot.bin`."),
        "isolate_snapshot": _file("`isolate_snapshot.bin`."),
        "const_finder": _file("`const_finder.dart.snapshot`."),
        "font_subset": _file("The `font-subset` binary."),
        "impellerc": _file("The `impellerc` binary."),
        "shader_lib": attr.label(doc = "The impellerc include files.", mandatory = True),
        "shader_include_dir": attr.string(
            doc = "The directory impellerc searches for `shader_lib`'s files, relative to " +
                  "the package of the `shader_lib` files.",
            mandatory = True,
        ),
    },
    doc = "The host tools of one Flutter SDK download, for " +
          "`@rules_flutter//flutter:exec_tools_toolchain_type`. Generated by the " +
          "`flutter_engine_artifacts` repository rule.",
)
