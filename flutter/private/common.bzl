"""Shared utilities for Flutter rules.

Package config generation, transitive source collection, and the shared
compilation pipeline (kernel → AOT → assets → FFI collection) used by
flutter_application, flutter_android_bundle, and flutter_ios_application.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs", "generate_dev_package_config")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:app_entrypoint.bzl", "app_main_package_uri", "compile_package_config", "resolve_kernel_entrypoint", "synthesize_app_package")
load("//flutter/private:flutter_asset_bundle.bzl", "flutter_asset_bundle_action")
load("//flutter/private:flutter_compile.bzl", "flutter_kernel_compile_action")
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions", "dedup_plugins")
load("//flutter/private:flutter_shader_compile.bzl", "flutter_shader_compile_action")
load("//flutter/private:plugin_registrant.bzl", "generate_dart_plugin_registrant")
load("//flutter/private:validation.bzl", "validate_dart_defines")

def make_web_wrapper_main_content(original_import, registrant_import = None):
    """Generate a web wrapper main.dart that uses ui_web.bootstrapEngine().

    Flutter web requires ui_web.bootstrapEngine() to properly initialize the
    engine (create the implicit view, set up the platform dispatcher, etc.)
    before calling the user's main(). Without this, runApp() fails with
    "The app requested a view, but the platform did not provide one."

    This matches the wrapper that `flutter build web` generates.

    Args:
        original_import: Import URI for the original main.
        registrant_import: Optional relative import path for the generated
            registrant file. If None, plugin registration is a no-op.

    Returns:
        String of Dart source code.
    """
    lines = [
        "// GENERATED — do not edit.",
        "// Flutter web bootstrap script.",
        "// ignore_for_file: type=lint",
        "",
        "import 'dart:ui_web' as ui_web;",
        "import 'dart:async';",
        "",
        "import '%s' as entrypoint;" % original_import,
    ]
    if registrant_import:
        lines.append("import '%s' as pluginRegistrant;" % registrant_import)
    lines.extend([
        "",
        "typedef _UnaryFunction = dynamic Function(List<String> args);",
        "typedef _NullaryFunction = dynamic Function();",
        "",
        "Future<void> main() async {",
        "  await ui_web.bootstrapEngine(",
        "    runApp: () {",
        "      if (entrypoint.main is _UnaryFunction) {",
        "        return (entrypoint.main as _UnaryFunction)(<String>[]);",
        "      }",
        "      return (entrypoint.main as _NullaryFunction)();",
        "    },",
    ])
    if registrant_import:
        lines.append("    registerPlugins: () {")
        lines.append("      pluginRegistrant.registerPlugins();")
        lines.append("    },")
    lines.extend([
        "  );",
        "}",
        "",
    ])
    return "\n".join(lines)

def collect_native_libs(native_deps):
    """Collect shared libraries from native_deps for dart:ffi.

    Filters DefaultInfo files by extension (.so, .dylib, .dll).

    Args:
        native_deps: List of targets providing DefaultInfo with shared libs.

    Returns:
        List of shared library Files.
    """
    libs = []
    for dep in native_deps:
        for f in dep[DefaultInfo].files.to_list():
            if f.extension in ("so", "dylib", "dll"):
                libs.append(f)
    return libs

def collect_assets(deps, direct_assets):
    """Collect asset files from direct attrs and transitive FlutterInfo deps.

    Args:
        deps: List of targets, some of which may provide FlutterInfo.
        direct_assets: List of directly specified asset Files.

    Returns:
        List of all asset Files.
    """
    transitive_depsets = [
        dep[FlutterInfo].asset_dirs
        for dep in deps
        if FlutterInfo in dep
    ]
    if transitive_depsets:
        return list(direct_assets) + depset(transitive = transitive_depsets).to_list()
    return list(direct_assets)

def flutter_compile_kernel(ctx, flutter_sdk_info, aot = None, platform_dill = None, target_platform = None, frontend_server_target = "flutter", native_assets_manifest = None):
    """Run the shared kernel compilation step.

    Collects sources, generates package_config.json, and invokes
    flutter_kernel_compile_action. If deps contain plugins with
    dartPluginClass, generates a registrant and wrapper main.

    If aot and platform_dill are not specified, they are determined by the
    Bazel compilation mode: opt → product dill + AOT, dbg → debug dill + JIT.

    Args:
        ctx: Rule context (must have main, srcs, deps, defines attrs).
        flutter_sdk_info: FlutterSdkInfo from the toolchain.
        aot: If set, override AOT mode. Otherwise determined by compilation mode.
        platform_dill: If set, override platform dill. Otherwise determined by compilation mode.
        target_platform: Optional platform string (e.g. "web", "linux", "android").
            When set, only plugins with dartPluginClass on that platform are registered.
        frontend_server_target: Frontend server --target flag ("flutter" or "dartdevc" for web).
        native_assets_manifest: Optional File pointing at the
            `native_assets.json` manifest (the JSON shape the
            frontend_server reads via `--native-assets`). Always passed
            through when set; the manifest's contents may be empty.

    Returns:
        struct with kernel_dill (File) and package_config (File).
    """
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list()
    packages = collect_packages(ctx.attr.deps)

    # Register the app itself as a package so the frontend_server keys the
    # entrypoint as `package:<name>/main.dart` — the URI the dev tool's
    # incremental compiler uses (without this, hot-reload deltas keyed via
    # sandbox `file://` URIs can't be matched against the kernel's libraries).
    app_pkg_name = ctx.attr.package_name
    packages = synthesize_app_package(packages, app_pkg_name)

    # Include the app's own `main` so the synthesized package the wrapper
    # imports as `package:<name>/main.dart` (hot-reload URI parity) is
    # co-located with its lib/ siblings when any of them are generated.
    colocate_inputs = all_srcs + ([ctx.file.main] if ctx.file.main else [])

    # Dev hot-reload metadata (debug only): a *second* package_config that, for a
    # source-assembled app package, points its `rootUri` at the live source tree
    # + generated bazel-out roots via a filesystem scheme — instead of the frozen
    # assembled `.pkgsrcs` dir the build package_config uses. This is what lets
    # the dev tool's frontend_server pick up live edits AND find generated parts.
    # Computed from the PRE-colocation `packages`/`colocate_inputs` so `lib_root`
    # and `File.is_source` are still intact. See rules_dart
    # `generate_dev_package_config`.
    profile_mode = hasattr(ctx.attr, "profile") and ctx.attr.profile
    emit_dev_config = ctx.var["COMPILATION_MODE"] == "dbg" and not profile_mode
    dev_package_config = None
    dev_filesystem_roots = []
    dev_filesystem_scheme = ""
    dev_generated_source_paths = []
    dev_generated_source_uris = []
    dev_source_packages = []
    app_entrypoint_uri = app_main_package_uri(app_pkg_name, ctx.file.main.path) if ctx.file.main else None
    if emit_dev_config:
        dev_package_config = ctx.actions.declare_file(ctx.label.name + ".dev_package_config.json")
        dev_pc = generate_dev_package_config(packages, colocate_inputs, dev_package_config)
        ctx.actions.write(dev_package_config, dev_pc.content)
        dev_filesystem_roots = dev_pc.filesystem_roots
        dev_filesystem_scheme = dev_pc.scheme
        dev_generated_source_paths = dev_pc.generated_source_paths
        dev_generated_source_uris = dev_pc.generated_source_uris
        dev_source_packages = dev_pc.source_packages

    pc = compile_package_config(ctx, packages, colocate_inputs)
    config_file = pc.config_file
    all_srcs = pc.srcs
    packages = pc.packages

    # Collect plugins from deps and generate registrant if needed.
    all_dep_plugins = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
    plugins = dedup_plugins(all_dep_plugins)
    registrant = generate_dart_plugin_registrant(ctx, plugins, target_platform = target_platform)

    # Determine compilation mode from Bazel config.
    bazel_mode = ctx.var["COMPILATION_MODE"]
    if platform_dill == None:
        if bazel_mode == "dbg":
            platform_dill = flutter_sdk_info.platform_kernel_dill
        else:
            platform_dill = flutter_sdk_info.platform_kernel_dill_product
    if aot == None:
        aot = bazel_mode != "dbg"

    # AI-agent service-extension injection: in debug builds (non-AOT), if the
    # rule carries an `_agent_extensions_src` attr, stage the agent source next
    # to the wrapper and have the wrapper register the extensions before user
    # main(). Release/AOT/profile builds skip this entirely — profile mode is
    # for performance investigation where added instrumentation distorts
    # measurements, so it must look the same as release on the agent surface.
    agent_src_attr = getattr(ctx.attr, "_agent_extensions_src", None)
    profile_mode = hasattr(ctx.attr, "profile") and ctx.attr.profile
    inject_agent = (not aot) and bazel_mode == "dbg" and not profile_mode and agent_src_attr != None
    staged_agent = None
    if inject_agent:
        staged_agent = ctx.actions.declare_file(ctx.label.name + ".agent_extensions.dart")
        ctx.actions.symlink(output = staged_agent, target_file = ctx.file._agent_extensions_src)

    # Resolve the kernel entrypoint. app_entrypoint owns whether a wrapper
    # is needed and how the app's main is keyed for hot-reload URI parity;
    # this rule only supplies the inputs (package name + the optional
    # registrant/agent that must run before user main()).
    entrypoint_info = resolve_kernel_entrypoint(ctx, app_pkg_name, registrant, staged_agent)
    all_srcs = all_srcs + entrypoint_info.extra_srcs

    # Collect extra frontend_server flags from build flag attrs.
    extra_frontend_flags = []
    if hasattr(ctx.attr, "track_widget_creation") and ctx.attr.track_widget_creation:
        extra_frontend_flags.append("--track-widget-creation")

    # Merge defines with mode-specific Dart VM flags. user_defines (attr +
    # extra_dart_defines flag, no mode keys) is surfaced in the return struct
    # so dev-config writers can replay it on the dev tool's frontend_server.
    user_defines = merge_dart_defines(ctx)
    all_defines = list(user_defines)
    if hasattr(ctx.attr, "profile") and ctx.attr.profile:
        all_defines.append("dart.vm.profile=true")
    elif aot:
        all_defines.append("dart.vm.product=true")

    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        flutter_sdk_files = flutter_sdk_info.tool_files,
        frontend_server = flutter_sdk_info.frontend_server,
        platform_dill = platform_dill,
        main = entrypoint_info.file,
        entrypoint_uri = entrypoint_info.uri,
        srcs = all_srcs,
        package_config = config_file,
        output = kernel_dill,
        aot = aot,
        defines = all_defines,
        target = frontend_server_target,
        extra_flags = extra_frontend_flags,
        native_assets_manifest = native_assets_manifest,
    )
    return struct(
        kernel_dill = kernel_dill,
        package_config = config_file,
        # Merged user defines (attr + flag), without the mode-specific
        # dart.vm.* keys — the dev tool replays these on its own compiler.
        dart_defines = user_defines,
        # Hot-reload dev metadata (None/empty outside debug). Consumed by the
        # rule impl to emit `_dev_config.json` for the dev tool.
        app_entrypoint_uri = app_entrypoint_uri,
        dev_package_config = dev_package_config,
        dev_filesystem_roots = dev_filesystem_roots,
        dev_filesystem_scheme = dev_filesystem_scheme,
        dev_generated_source_paths = dev_generated_source_paths,
        dev_generated_source_uris = dev_generated_source_uris,
        dev_source_packages = dev_source_packages,
    )

def collect_sdk_shader_srcs(deps):
    """Collect shader source files from transitive FlutterInfo deps.

    These are raw .frag/.glsl files (e.g. Flutter SDK material shaders)
    that need to be compiled per-platform before inclusion in the asset bundle.

    Args:
        deps: List of targets, some of which may provide FlutterInfo.

    Returns:
        List of shader source Files.
    """
    transitive_depsets = [
        dep[FlutterInfo].shader_srcs
        for dep in deps
        if FlutterInfo in dep and hasattr(dep[FlutterInfo], "shader_srcs")
    ]
    if transitive_depsets:
        return depset(transitive = transitive_depsets).to_list()
    return []

def flutter_compile_shaders(ctx, flutter_sdk_info, target_platform):
    """Compile shader files for the target platform using impellerc.

    Compiles both user-provided shaders (from the shaders attr) and SDK
    shaders collected transitively from FlutterInfo.shader_srcs.

    User shaders keep their workspace-relative path (e.g. "shaders/my_effect.frag").
    SDK shaders are placed at "shaders/<basename>" (matching Flutter conventions).

    Args:
        ctx: Rule context (must have shaders attr and deps attr).
        flutter_sdk_info: FlutterSdkInfo from the toolchain.
        target_platform: Target platform string ("ios", "macos", "android", "linux", "windows", "web").

    Returns:
        Dict mapping bundle destination path → compiled File. Pass to
        extra_asset_copies in flutter_asset_bundle_action.
    """

    # Collect all shaders: user-provided + SDK shaders from deps.
    user_shaders = list(ctx.files.shaders) if hasattr(ctx.attr, "shaders") else []
    sdk_shaders = collect_sdk_shader_srcs(ctx.attr.deps) if hasattr(ctx.attr, "deps") else []

    # Walk pub-package shaders from FlutterInfo.pub_shaders. Each carries
    # (package_name, shader_path, file). Bundle dest path is
    # `packages/<pkg>/<shader_path>` (or bare `<shader_path>` for non-package
    # contributions where package_name is empty).
    pub_shader_entries = []
    if hasattr(ctx.attr, "deps"):
        for dep in ctx.attr.deps:
            if FlutterInfo in dep and hasattr(dep[FlutterInfo], "pub_shaders") and dep[FlutterInfo].pub_shaders != None:
                pub_shader_entries.extend(dep[FlutterInfo].pub_shaders.to_list())

    if (not user_shaders and not sdk_shaders and not pub_shader_entries) or not flutter_sdk_info.impellerc:
        return {}

    compiled = {}
    for shader in user_shaders + sdk_shaders:
        output = ctx.actions.declare_file(ctx.label.name + "_shaders/" + shader.basename + ".iplr")
        flutter_shader_compile_action(
            ctx = ctx,
            impellerc = flutter_sdk_info.impellerc,
            shader_lib = flutter_sdk_info.shader_lib,
            shader = shader,
            output = output,
            target_platform = target_platform,
            is_web = target_platform == "web",
        )

        # User shaders: use workspace-relative path ("shaders/my_effect.frag").
        # SDK shaders: place under "shaders/<basename>" (e.g. "shaders/ink_sparkle.frag").
        if shader in user_shaders:
            bundle_path = shader.short_path
        else:
            bundle_path = "shaders/" + shader.basename
        compiled[bundle_path] = output

    # Pub-package shaders. Output filename includes package_name to avoid
    # collisions when two packages ship a shader with the same basename.
    for entry in pub_shader_entries:
        prefix = "packages/{}/".format(entry.package_name) if entry.package_name else ""
        bundle_path = prefix + entry.shader_path
        out_dir = entry.package_name if entry.package_name else "_local"
        output = ctx.actions.declare_file(
            ctx.label.name + "_pub_shaders/" + out_dir + "/" + entry.file.basename + ".iplr",
        )
        flutter_shader_compile_action(
            ctx = ctx,
            impellerc = flutter_sdk_info.impellerc,
            shader_lib = flutter_sdk_info.shader_lib,
            shader = entry.file,
            output = output,
            target_platform = target_platform,
            is_web = target_platform == "web",
        )
        compiled[bundle_path] = output

    return compiled

def flutter_build_assets(ctx, flutter_sdk_info, compiled_shaders = {}, kernel_dill = None, is_debug = False, data_assets = None):
    """Run the shared asset bundling step.

    Walks `FlutterInfo.pub_fonts` / `pub_assets` from deps to bundle
    pub-package contributions (fonts/assets — shaders are pre-compiled by
    `flutter_compile_shaders` and arrive via `compiled_shaders`).

    Args:
        ctx: Rule context (must have assets, deps, license_files, tree_shake_icons attrs and _asset_bundle_tool).
        flutter_sdk_info: FlutterSdkInfo from the toolchain.
        compiled_shaders: Dict mapping bundle dest path → compiled shader File.
        kernel_dill: The compiled kernel .dill File (needed for icon tree shaking).
        is_debug: Whether this is a debug build (icon tree shaking is skipped in debug).
        data_assets: Optional depset[FlutterDataAssetInfo]. Each entry is
            placed at `flutter_assets/data/<package>/<name>` (matching
            `InstallDataAssets` in flutter_tools).

    Returns:
        The flutter_assets/ tree artifact File.
    """
    all_assets = collect_assets(ctx.attr.deps, ctx.files.assets)

    # Walk pub-package font/asset contributions from FlutterInfo.
    # MaterialIcons is no longer special-cased here — apps depend on
    # `@rules_flutter//flutter:material_icons` to get it via this same path.
    fonts, pub_extra_asset_copies = aggregate_pub_contributions(ctx.attr.deps)
    extra_asset_copies = dict(compiled_shaders)
    extra_asset_copies.update(pub_extra_asset_copies)

    # Drop each Native Assets DataAsset at flutter_assets/data/<pkg>/<name>.
    # The bundle action keys extra_asset_copies on a destination path
    # relative to the assets/ root; the data/<pkg>/<name> prefix matches
    # the convention `InstallDataAssets` uses in flutter_tools.
    if data_assets != None:
        for entry in data_assets.to_list():
            dst = "data/{pkg}/{name}".format(pkg = entry.package, name = entry.name)
            extra_asset_copies[dst] = entry.file

    license_files = ctx.files.license_files

    # Icon tree shaking: enabled only in non-debug mode with tree_shake_icons=True.
    tree_shake_icons = (
        ctx.attr.tree_shake_icons and
        not is_debug and
        kernel_dill != None and
        flutter_sdk_info.const_finder != None and
        flutter_sdk_info.font_subset != None
    )

    return flutter_asset_bundle_action(
        ctx = ctx,
        dart = flutter_sdk_info.dart,
        flutter_sdk_files = flutter_sdk_info.tool_files,
        assets = all_assets,
        fonts = fonts,
        license_files = license_files,
        output_dir_name = ctx.label.name + "_flutter_assets",
        const_finder = flutter_sdk_info.const_finder if tree_shake_icons else None,
        font_subset = flutter_sdk_info.font_subset if tree_shake_icons else None,
        kernel_dill = kernel_dill if tree_shake_icons else None,
        extra_asset_copies = extra_asset_copies,
    )

def compute_desktop_bundle_copies(is_debug, kernel_dill_path, aot_output_path, aot_dst, icu_data_path, engine_basenames, native_basenames, engine_dst_prefix = "lib/", native_dst_prefix = "lib/"):
    """Compute the file-copy list for a desktop Flutter bundle.

    Builds the list of {"src": ..., "dst": ...} dicts that the Dart bundler
    tool uses to assemble a Linux or Windows application directory.

    Args:
        is_debug: Whether this is a debug build.
        kernel_dill_path: Source path to kernel .dill file (used in debug mode), or None.
        aot_output_path: Source path to AOT output (used in release mode), or None.
        aot_dst: Destination path for AOT output (e.g. "lib/libapp.so" or "app.so").
        icu_data_path: Source path to icudtl.dat.
        engine_basenames: List of (src_path, basename) tuples for engine files.
        native_basenames: List of (src_path, basename) tuples for native FFI libs.
        engine_dst_prefix: Destination prefix for engine files (default "lib/").
        native_dst_prefix: Destination prefix for native FFI / Native
            Assets `dynamic_loading_bundle` libs. Linux uses `lib/`
            (next to libapp.so); Windows uses `""` so DLLs land next to
            the runner `.exe` where Windows' dynamic loader picks them
            up via the standard search order.

    Returns:
        List of {"src": ..., "dst": ...} dicts.
    """
    copies = [{"src": icu_data_path, "dst": "data/icudtl.dat"}]

    if is_debug and kernel_dill_path:
        # The Flutter engine's embedder looks for kernel_blob.bin inside the
        # assets directory (settings.assets_path / "kernel_blob.bin").
        copies.append({"src": kernel_dill_path, "dst": "data/flutter_assets/kernel_blob.bin"})
    elif aot_output_path:
        copies.append({"src": aot_output_path, "dst": aot_dst})

    for src_path, basename in engine_basenames:
        copies.append({"src": src_path, "dst": engine_dst_prefix + basename})

    for src_path, basename in native_basenames:
        copies.append({"src": src_path, "dst": native_dst_prefix + basename})

    return copies

def compute_android_jni_path(abi, basename):
    """Compute the JNI symlink path for an Android native library.

    Args:
        abi: Android ABI string (e.g. "arm64-v8a").
        basename: Filename within the ABI directory.

    Returns:
        Path string like "jni/arm64-v8a/libapp.so".
    """
    return "jni/{}/{}".format(abi, basename)

def host_target_arch(ctx, flutter_sdk_info):
    """Best-effort target architecture string for Native Assets.

    The toolchain's `target_arch` is set on cross-compilation toolchains
    but empty for native builds. For native builds we infer from
    `bin_dir` path. Returns one of `arm64`, `x64`, `arm`, or "" if
    unknown. The empty string causes the Native Assets manifest to omit
    the target section, which is still valid for the engine.

    Args:
      ctx: Rule context — used only for `ctx.bin_dir`.
      flutter_sdk_info: `FlutterSdkInfo` from the toolchain. Carries the
        `target_arch` field, which when set wins over the heuristic.

    Returns:
      A lowercase architecture string (`arm64`, `x64`, `arm`) or "" when
      neither the toolchain nor the bin_dir hint at a known arch.
    """
    if flutter_sdk_info.target_arch:
        return flutter_sdk_info.target_arch

    # Heuristic: parse the bazel-out output dir for cpu hints. The bin_dir
    # path looks like `bazel-out/<cpu>-<mode>/bin`. Match the same `cpu`
    # values rules_flutter assumes elsewhere. Windows cpu names put the
    # arch first (`x64_windows`, `arm64_windows`), so match those before
    # the suffix-style patterns.
    bin_dir = ctx.bin_dir.path
    if "arm64_windows" in bin_dir:
        return "arm64"
    if "x64_windows" in bin_dir:
        return "x64"
    if "darwin_arm64" in bin_dir or "_arm64" in bin_dir:
        return "arm64"
    if "darwin_x86_64" in bin_dir or "_x86_64" in bin_dir or "_amd64" in bin_dir or "k8" in bin_dir:
        return "x64"
    if "darwin_x64" in bin_dir or "_x64" in bin_dir:
        return "x64"
    if "armv7" in bin_dir or "arm-" in bin_dir:
        return "arm"
    return ""

def detect_target_platform(is_ios, is_macos, is_linux, is_windows, is_android):
    """Detect the Flutter target platform from constraint booleans.

    Args:
        is_ios: True if target platform is iOS.
        is_macos: True if target platform is macOS.
        is_linux: True if target platform is Linux.
        is_windows: True if target platform is Windows.
        is_android: True if target platform is Android.

    Returns:
        Platform string: "ios", "macos", "linux", "windows", or "android".
        Fails if no platform matches.
    """
    if is_ios:
        return "ios"
    elif is_macos:
        return "macos"
    elif is_linux:
        return "linux"
    elif is_windows:
        return "windows"
    elif is_android:
        return "android"
    else:
        fail(
            "No supported Flutter target platform detected. " +
            "Supported platforms: android, ios, macos, linux, windows. " +
            "Use --platforms= to set the target platform.",
        )

# Shared platform constraint attrs used by rules that need to check target platform.
PLATFORM_CONSTRAINT_ATTRS = {
    "_macos_constraint": attr.label(
        default = "@platforms//os:macos",
    ),
    "_ios_constraint": attr.label(
        default = "@platforms//os:ios",
    ),
    "_linux_constraint": attr.label(
        default = "@platforms//os:linux",
    ),
    "_windows_constraint": attr.label(
        default = "@platforms//os:windows",
    ),
    "_android_constraint": attr.label(
        default = "@platforms//os:android",
    ),
}

AGENT_EXTENSIONS_ATTR = {
    "_agent_extensions_src": attr.label(
        doc = "AI-agent service-extension source. Auto-injected into the wrapper main in debug builds; ignored in AOT/release.",
        default = Label("//flutter/private/agent_extensions:agent.dart"),
        allow_single_file = [".dart"],
    ),
}

EXTRA_DART_DEFINES_ATTR = {
    "_extra_dart_defines": attr.label(
        doc = "The //flutter:extra_dart_defines build setting, appended after the target's own `defines`.",
        default = Label("//flutter:extra_dart_defines"),
    ),
}

def merge_dart_defines(ctx):
    """Merge a target's `defines` attr with the extra_dart_defines flag.

    Flag values come after attr values, so on a duplicated key the command
    line wins (the compilers take the last -D). The flag validates its own
    value in its rule impl; only the attr is validated here.

    Args:
        ctx: Rule context with `defines` and `_extra_dart_defines` attrs.

    Returns:
        The merged list of KEY=VALUE define strings.
    """
    validate_dart_defines(ctx.attr.defines, "defines attribute of %s" % ctx.label)
    return list(ctx.attr.defines) + ctx.attr._extra_dart_defines[BuildSettingInfo].value

# Shared attrs for all flutter application rules.
FLUTTER_APPLICATION_ATTRS = {
    "main": attr.label(
        doc = "The main .dart entry point.",
        mandatory = True,
        allow_single_file = [".dart"],
    ),
    "package_name": attr.string(
        doc = "Dart package name (same value as `pubspec.yaml`'s `name:`). " +
              "Required: keys the kernel's libraries under stable `package:` URIs " +
              "(hot-reload parity with the dev tool), anchors codegen sibling " +
              "co-location, and resolves `package:<self>/...` imports. There is " +
              "no signal in the Bazel graph that can determine this reliably, " +
              "so it must be declared explicitly.",
        mandatory = True,
    ),
    "srcs": attr.label_list(
        doc = "Additional Dart source files.",
        allow_files = [".dart"],
    ),
    "deps": attr.label_list(
        doc = "`dart_library` or `flutter_library` dependencies. Apps that use " +
              "Material widgets must list `@rules_flutter//flutter:material_icons` " +
              "here to bundle `MaterialIcons-Regular.otf` into `flutter_assets/`.",
        providers = [DartInfo],
    ),
    "assets": attr.label_list(
        doc = "Asset files to include in the bundle.",
        allow_files = True,
    ),
    "native_deps": attr.label_list(
        doc = "cc_library targets providing shared libraries for dart:ffi.",
    ),
    "defines": attr.string_list(
        doc = "Dart environment defines (-D flags).",
    ),
    "profile": attr.bool(
        doc = "If True, compile in profile mode (AOT like release, but unstripped and with service extensions for profiling). Overrides the default compilation mode mapping.",
        default = False,
    ),
    "obfuscate": attr.bool(
        doc = "If True, obfuscate Dart symbols in the AOT output. Pair with split_debug_info to produce a symbol map for deobfuscation.",
        default = False,
    ),
    "split_debug_info": attr.bool(
        doc = "If True, extract debug info from the AOT output into a separate file. Produces a .symbols output alongside the AOT binary.",
        default = False,
    ),
    "extra_gen_snapshot_options": attr.string_list(
        doc = "Additional flags passed directly to gen_snapshot (AOT compiler).",
    ),
    "track_widget_creation": attr.bool(
        doc = "If True, track widget creation locations for the DevTools widget inspector. Adds overhead; typically used only in debug/profile builds.",
        default = False,
    ),
    "shaders": attr.label_list(
        doc = "Fragment shader files (.frag) to compile with impellerc. Compiled shaders are included in the asset bundle.",
        allow_files = [".frag", ".glsl"],
    ),
    "tree_shake_icons": attr.bool(
        doc = "If True, tree-shake icon fonts to only include used glyphs. " +
              "Requires all IconData instances to be const. Only applies to release builds.",
        default = True,
    ),
    "license_files": attr.label_list(
        doc = "License/NOTICE files to include in NOTICES.Z. Typically LICENSE files from dependencies.",
        allow_files = True,
    ),
    "min_os_version": attr.string(
        doc = "Minimum OS deployment target for Apple platforms (iOS/macOS). " +
              "Passed to gen_snapshot as --macho-min-os-version. " +
              "Platform-specific bundle rules set appropriate defaults.",
    ),
    "_asset_bundle_tool": attr.label(
        default = Label("//flutter/private/tools:generate_asset_manifest.dart"),
        allow_single_file = True,
    ),
} | AGENT_EXTENSIONS_ATTR | EXTRA_DART_DEFINES_ATTR
