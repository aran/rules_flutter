"""Flutter plugin rule.

Declares a Flutter plugin with Dart code and platform metadata.

Platform-specific native dependencies use select() in BUILD files:

    flutter_plugin(
        name = "url_launcher",
        srcs = glob(["lib/**/*.dart"]),
        platforms = ["android", "ios", "macos", "linux", "windows", "web"],
        dart_plugin_class = "UrlLauncherPlugin",
        native_deps = select({
            "@platforms//os:linux": [":url_launcher_linux_cc"],
            "@platforms//os:windows": [":url_launcher_windows_cc"],
            "//conditions:default": [],
        }),
    )
"""

load("@rules_android//providers:providers.bzl", "AndroidLibraryResourceClassJarProvider", "StarlarkAndroidResourcesInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_info", "derive_lib_root", "derive_package_name")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterDataAssetInfo", "FlutterInfo", "FlutterNativeAssetInfo")
load("//flutter/private:asset_keys.bzl", "library_asset_entries")
load("//flutter/private:common.bzl", "collect_binding_contracts", "collect_native_libs")
load("//flutter/private:flutter_desktop_plugin_info.bzl", "FlutterLinuxPluginInfo", "FlutterWindowsPluginInfo")
load("//flutter/private:flutter_info.bzl", "LINK_HOOK_ATTR", "flutter_info")
load("//flutter/private:flutter_library.bzl", "SKY_ENGINE_ATTR", "build_pub_contributions", "flutter_analyzable_info")
load("//flutter/private:native_sources.bzl", "collect_native_source_pairs", "native_sources_aspect")

def build_plugin_struct(name, plugin_platforms):
    """Build a plugin metadata struct from per-platform metadata.

    Args:
        name: Plugin package name.
        plugin_platforms: Dict of platform -> {pluginClass, dartPluginClass, ...}.

    Returns:
        A struct with name and platforms dict.
    """
    return struct(name = name, platforms = plugin_platforms)

def _apple_plugin_platform(ctx):
    """Detect the Apple platform of a `swift_library` from its constraints."""
    macos_label = ctx.attr._macos_constraint.label
    ios_label = ctx.attr._ios_constraint.label
    for constraint in getattr(ctx.rule.attr, "target_compatible_with", []):
        if constraint.label == macos_label:
            return "macos"
        if constraint.label == ios_label:
            return "ios"
    return None

def _apple_link_sdk_lists(target):
    """Collect SDK frameworks and dylibs from a target's linker flags."""
    sdk_frameworks = []
    sdk_dylibs = []
    if CcInfo in target:
        for li in target[CcInfo].linking_context.linker_inputs.to_list():
            flags = li.user_link_flags
            for idx in range(len(flags)):
                if flags[idx] == "-framework" and idx + 1 < len(flags):
                    fw = flags[idx + 1]
                    if fw not in sdk_frameworks:
                        sdk_frameworks.append(fw)
                elif flags[idx].startswith("-l") and len(flags[idx]) > 2:
                    dylib = flags[idx][2:]
                    if dylib not in sdk_dylibs:
                        sdk_dylibs.append(dylib)
    return sdk_frameworks, sdk_dylibs

def _apple_plugin_aspect_impl(target, ctx):
    if FlutterApplePluginInfo in target:
        return []
    if ctx.rule.kind != "swift_library":
        return []
    platform = _apple_plugin_platform(ctx)
    if not platform:
        return []
    sdk_frameworks, sdk_dylibs = _apple_link_sdk_lists(target)
    return [
        FlutterApplePluginInfo(
            module_name = getattr(ctx.rule.attr, "module_name", ""),
            platform = platform,
            swift_srcs = depset(getattr(ctx.rule.files, "srcs", [])),
            objc_srcs = depset(),
            headers = depset(),
            modulemap = None,
            sdk_frameworks = tuple(sdk_frameworks),
            sdk_dylibs = tuple(sdk_dylibs),
        ),
    ]

_apple_plugin_aspect = aspect(
    implementation = _apple_plugin_aspect_impl,
    attrs = {
        "_ios_constraint": attr.label(default = "@platforms//os:ios"),
        "_macos_constraint": attr.label(default = "@platforms//os:macos"),
    },
)

def _plugin_platforms_metadata(ctx):
    """Decode the plugin's per-platform metadata from its attrs."""
    if ctx.attr.plugin_platforms_json:
        return json.decode(ctx.attr.plugin_platforms_json)
    plugin_platforms = {}
    for p in ctx.attr.platforms:
        info = {}
        if ctx.attr.plugin_class:
            info["pluginClass"] = ctx.attr.plugin_class
        if ctx.attr.dart_plugin_class:
            info["dartPluginClass"] = ctx.attr.dart_plugin_class
        if p == "android" and ctx.attr.android_package:
            info["package"] = ctx.attr.android_package
        plugin_platforms[p] = info
    return plugin_platforms

def _collect_native_lib_sources(ctx):
    """Pair native libraries with the sources their bindings were generated from."""
    return collect_native_source_pairs(ctx.attr.native_deps) + [
        pair
        for dep in ctx.attr.native_assets
        if FlutterInfo in dep
        for pair in dep[FlutterInfo].native_lib_sources.to_list()
    ]

def _collect_extra_apple_libraries(libs, platform, package_name, attr_name):
    """Collect one `apple_libs`/`macos_libs`/`ios_libs` attr into extra-library structs."""
    entries = []
    for lib in libs:
        info = lib[FlutterApplePluginInfo] if FlutterApplePluginInfo in lib else None
        if attr_name == "apple_libs":
            if info == None:
                fail(
                    "flutter_plugin: apple_libs entry %s must provide FlutterApplePluginInfo " % lib.label +
                    "(use flutter_apple_plugin_library, or pass platform libraries via macos_libs / ios_libs).",
                )
            platform_name = info.platform
            if platform_name not in ("macos", "ios"):
                fail(
                    "flutter_plugin: apple_libs entry %s has invalid FlutterApplePluginInfo.platform %r " % (
                        lib.label,
                        platform_name,
                    ) + "(expected 'macos' or 'ios').",
                )
        else:
            if info != None and info.platform not in ("", platform):
                fail(
                    "flutter_plugin: %s entry %s has FlutterApplePluginInfo.platform = %r, expected '%s'." % (
                        attr_name,
                        lib.label,
                        info.platform,
                        platform,
                    ),
                )
            platform_name = platform
        entries.append(struct(
            platform = platform_name,
            label = lib.label,
            cc_info = lib[CcInfo] if CcInfo in lib else None,
            swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
            files = lib[DefaultInfo].files,
            sdk_frameworks = tuple(info.sdk_frameworks) if info != None else (),
            sdk_dylibs = tuple(info.sdk_dylibs) if info != None else (),
            package = package_name,
        ))
    return entries

def _extra_apple_plugin_libraries(ctx, package_name):
    """Collect the `apple_libs`, `macos_libs` and `ios_libs` channels."""
    return (
        _collect_extra_apple_libraries(ctx.attr.apple_libs, "", package_name, "apple_libs") +
        _collect_extra_apple_libraries(ctx.attr.macos_libs, "macos", package_name, "macos_libs") +
        _collect_extra_apple_libraries(ctx.attr.ios_libs, "ios", package_name, "ios_libs")
    )

def _collect_desktop_plugin_libraries(libs, provider, provider_name, rule_name, attr_name, package_name):
    """Collect one `linux_libs`/`windows_libs` attr into source-bundle structs."""
    entries = []
    for lib in libs:
        if provider not in lib:
            fail("flutter_plugin: %s entry %s must provide %s (use %s)." % (attr_name, lib.label, provider_name, rule_name))
        info = lib[provider]
        entries.append(struct(
            label = lib.label,
            srcs = info.srcs,
            hdrs = info.hdrs,
            include_dirs = info.include_dirs,
            package = package_name,
        ))
    return entries

def _extra_linux_plugin_libraries(ctx, package_name):
    return _collect_desktop_plugin_libraries(
        ctx.attr.linux_libs,
        FlutterLinuxPluginInfo,
        "FlutterLinuxPluginInfo",
        "flutter_linux_plugin_library",
        "linux_libs",
        package_name,
    )

def _extra_windows_plugin_libraries(ctx, package_name):
    return _collect_desktop_plugin_libraries(
        ctx.attr.windows_libs,
        FlutterWindowsPluginInfo,
        "FlutterWindowsPluginInfo",
        "flutter_windows_plugin_library",
        "windows_libs",
        package_name,
    )

def _extra_android_plugin_libraries(ctx, package_name):
    entries = []
    for lib in ctx.attr.android_libs:
        entries.append(struct(
            label = lib.label,
            java_info = lib[JavaInfo],
            resources_info = lib[StarlarkAndroidResourcesInfo] if StarlarkAndroidResourcesInfo in lib else None,
            resource_class_jars = lib[AndroidLibraryResourceClassJarProvider].jars if AndroidLibraryResourceClassJarProvider in lib else None,
            package = package_name,
        ))
    return entries

def _collect_plugin_asset_infos(assets, provider, provider_name, rule_name, attr_name):
    """Collect one `native_assets`/`data_assets` attr into provider structs."""
    infos = []
    for dep in assets:
        if provider not in dep:
            fail(
                "flutter_plugin: %s entry %s must provide " % (attr_name, dep.label) +
                "%s (use %s)." % (provider_name, rule_name),
            )
        infos.append(dep[provider])
    return infos

def _extra_native_assets(ctx):
    return _collect_plugin_asset_infos(
        ctx.attr.native_assets,
        FlutterNativeAssetInfo,
        "FlutterNativeAssetInfo",
        "flutter_native_asset",
        "native_assets",
    )

def _extra_data_assets(ctx):
    return _collect_plugin_asset_infos(
        ctx.attr.data_assets,
        FlutterDataAssetInfo,
        "FlutterDataAssetInfo",
        "flutter_data_asset",
        "data_assets",
    )

def _plugin_pub_contributions(ctx):
    """Build this plugin's pub-package asset contributions (fonts/assets/shaders)."""
    return build_pub_contributions(
        ctx.attr.package_name,
        ctx.attr.fonts_json,
        ctx.attr.font_files,
        ctx.attr.pkg_assets,
        ctx.attr.pkg_shaders,
        ctx.files.shader_includes,
        ctx.attr.pkg_asset_platforms,
        ctx.attr.pkg_asset_flavors,
    )

def _check_plugin_resources(ctx):
    """Reject Dart sources mis-filed under `resources` instead of `srcs`."""
    for f in ctx.files.resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the non-Dart remainder of `lib/`; Dart sources belong in " +
                 "`srcs`.") % (ctx.label, f.short_path),
            )

def _plugin_dart_infos(ctx, package_name, lib_root):
    """The Dart-channel providers of a plugin: files, `dart_info`, analyzable info."""
    return [
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.resources)),
        dart_info(
            label = ctx.label,
            package_name = package_name,
            lib_root = lib_root,
            deps = ctx.attr.deps,
            srcs = ctx.files.srcs,
            resources = ctx.files.resources,
            code_assets = ctx.attr.code_assets,
            language_version = ctx.attr.language_version,
            version = ctx.attr.version,
            has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
            link_hook = ctx.file.link_hook,
        ),
        flutter_analyzable_info(ctx, package_name, lib_root),
    ]

def _plugin_flutter_info(ctx, package_name, plugin, extra):
    """The `FlutterInfo` provider aggregating every channel the plugin adds to."""
    return flutter_info(
        deps = ctx.attr.deps,
        asset_dirs = ctx.files.assets,
        assets = library_asset_entries(ctx.label, package_name, ctx.files.assets),
        plugins = [plugin],
        native_libs = extra.native_libs,
        binding_contracts = extra.binding_contracts,
        native_lib_sources = extra.native_lib_sources,
        apple_plugin_libraries = extra.apple,
        android_plugin_libraries = extra.android,
        linux_plugin_libraries = extra.linux,
        windows_plugin_libraries = extra.windows,
        apple_privacy_manifests = extra.privacy,
        native_assets = extra.native_assets,
        data_assets = extra.data_assets,
        pub_fonts = extra.pub_fonts,
        pub_assets = extra.pub_assets,
        pub_shaders = extra.pub_shaders,
    )

def _flutter_plugin_impl(ctx):
    package_name = derive_package_name(ctx.attr.package_name, ctx.label.package, ctx.label.name)
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Build plugin metadata.
    # If plugin_platforms_json is set, decode it directly.
    # Otherwise construct from scalar attrs (for manual BUILD files).
    plugin = build_plugin_struct(
        name = package_name,
        plugin_platforms = _plugin_platforms_metadata(ctx),
    )

    # Collect native libs from native_deps.
    native_libs = collect_native_libs(ctx.attr.native_deps)

    # And what their bindings were generated from, for the ones whose build said
    # so. Carried to the app rather than used here: a plugin bundles nothing, and
    # the app is where the dev config that a reload reads is written.
    binding_contracts = collect_binding_contracts(ctx.attr.native_deps)

    # `native_deps` and the Native Assets alike: an asset's own rule pairs the
    # library it declares with its sources, on its `FlutterInfo`.
    native_lib_sources = _collect_native_lib_sources(ctx)

    # Pull CcInfo + SwiftInfo from the per-platform Apple plugin libraries
    # so the runner aggregator can merge them into the runner's
    # swift_library compilation/link inputs. Targets in `apple_libs`
    # declare their target platform via `FlutterApplePluginInfo.platform`
    # (produced by `flutter_apple_plugin_library`), while `macos_libs` and
    # `ios_libs` accept platform-specific `CcInfo`/`SwiftInfo` targets
    # directly. Set `apple_libs` via `select()` on the target platform so
    # only one platform's swift_library analyzes per build.
    extra_apple_plugin_libraries = _extra_apple_plugin_libraries(ctx, package_name)

    # Pull source bundles from linux + windows plugin libraries so the
    # corresponding runner can fold them into its compile.
    extra_linux_plugin_libraries = _extra_linux_plugin_libraries(ctx, package_name)
    extra_windows_plugin_libraries = _extra_windows_plugin_libraries(ctx, package_name)
    extra_android_plugin_libraries = _extra_android_plugin_libraries(ctx, package_name)

    # Native Assets contributed by this plugin (or its parent ext/ overlay).
    extra_native_assets = _extra_native_assets(ctx)
    extra_data_assets = _extra_data_assets(ctx)

    extra_apple_privacy_manifests = list(ctx.files.apple_privacy_files)

    # Pub-package asset contributions (fonts/assets/shaders from the parsed
    # flutter:-block, applicable to plugins that also ship icon fonts or
    # bundled assets — same shape as flutter_library). asset_pkg uses the
    # rule's `package_name` attr verbatim (empty = bare paths).
    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = _plugin_pub_contributions(ctx)

    # `resources` names the non-Dart remainder of `lib/`; a Dart source there
    # is a mis-filed `srcs` entry, and identical paths with identical
    # extensions would otherwise collide silently. Mirrors `dart_library`.
    _check_plugin_resources(ctx)

    # A plugin contributes on more channels than a library does, but the shape
    # is the same: name what this target adds, and let each constructor merge
    # the dependencies. `shaders` is absent here — a plugin has no such
    # attribute — which is a thing the caller simply does not say, rather than
    # something the merge has to probe for.
    extra = struct(
        native_libs = native_libs,
        binding_contracts = binding_contracts,
        native_lib_sources = native_lib_sources,
        apple = extra_apple_plugin_libraries,
        android = extra_android_plugin_libraries,
        linux = extra_linux_plugin_libraries,
        windows = extra_windows_plugin_libraries,
        privacy = extra_apple_privacy_manifests,
        native_assets = extra_native_assets,
        data_assets = extra_data_assets,
        pub_fonts = extra_pub_fonts,
        pub_assets = extra_pub_assets,
        pub_shaders = extra_pub_shaders,
    )
    return _plugin_dart_infos(ctx, package_name, lib_root) + [_plugin_flutter_info(ctx, package_name, plugin, extra)]

flutter_plugin = rule(
    implementation = _flutter_plugin_impl,
    attrs = {
        "_sky_engine": SKY_ENGINE_ATTR,
        "srcs": attr.label_list(
            doc = "Dart source files for the plugin's public API.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "Dart/Flutter library dependencies.",
            providers = [DartInfo],
        ),
        "resources": attr.label_list(
            doc = "Non-Dart files this package ships inside `lib/` — part of its published surface, but never compiled (a web plugin's bundled JS/wasm, templates, YAML). Anything under `lib/` is addressable as `package:<name>/<path>` whatever its extension, so these are members of the package: they ride `DartInfo.transitive_resources` and are staged wherever the whole package is staged, mirroring `dart_library`. Orthogonal to `pkg_assets`/`pkg_shaders`/`font_files`, which name flutter_assets bundle contributions. `.dart` files belong in `srcs`.",
            allow_files = True,
        ),
        "assets": attr.label_list(
            doc = "Asset files to include.",
            allow_files = True,
        ),
        "package_name": attr.string(
            doc = "The Dart package name. If omitted, derived from label.",
        ),
        "platforms": attr.string_list(
            doc = "Platforms this plugin supports (android, ios, macos, linux, windows, web).",
        ),
        "plugin_class": attr.string(
            doc = "Native plugin class name (for platform channel registration).",
        ),
        "android_package": attr.string(
            doc = "Java package of the Android `plugin_class`, as " +
                  "`flutter.plugin.platforms.android.package` in a pubspec. " +
                  "Required when `platforms` lists android with a " +
                  "`plugin_class`. Its Kotlin/Java goes to the app via " +
                  "`android_libs` on `flutter_plugin` or as a " +
                  "`flutter_android_plugin_library` in " +
                  "`flutter_android_app(deps = ...)`.",
        ),
        "dart_plugin_class": attr.string(
            doc = "Dart-only plugin class name (for Dart-side registration).",
        ),
        "plugin_platforms_json": attr.string(
            doc = "JSON-encoded per-platform metadata dict. Overrides platforms/plugin_class/dart_plugin_class if set.",
        ),
        "native_deps": attr.label_list(
            doc = "Native dependencies. Use select() for platform-conditional deps.",
            aspects = [native_sources_aspect],
        ),
        "code_assets": attr.label_list(
            doc = "`dart_code_asset` targets standing in for this package's " +
                  "`hook/build.dart` output. Declared on the owning package " +
                  "rather than on the consuming application so they propagate " +
                  "the way pub's own do — depending on the package is enough.",
            providers = [DartCodeAssetInfo],
        ),
        "has_unreplaced_hook": attr.string(
            doc = "Path of a build hook this package ships that nothing " +
                  "replaces, or empty. Recorded at repo generation; the " +
                  "application that depends on the package fails on it.",
        ),
        "version": attr.string(
            doc = "The package's own version, as resolved by pub (e.g. `2.2.0`). " +
                  "Set automatically by the generated pub spokes; leave it empty on " +
                  "hand-written targets, which have no resolved version to state. " +
                  "Mirrors `dart_library`'s attribute, and has its one use: when a " +
                  "single package name arrives from two hubs, two records stating " +
                  "different versions fail the build instead of the first one " +
                  "silently standing in for the second. An empty version never " +
                  "conflicts.",
        ),
        "link_hook": LINK_HOOK_ATTR,
        "language_version": attr.string(
            doc = "Dart language version (`<major>.<minor>`) for this package's `package_config.json` entry. Mirrors `dart_library`'s attribute. Empty string means defer to the toolchain default.",
        ),
        "apple_libs": attr.label_list(
            doc = "Per-platform Apple plugin libraries (`flutter_apple_plugin_library`) carrying the plugin's macOS / iOS native code and `FlutterApplePluginInfo` provider. Set this via `select()` on the target platform so only one platform's library analyzes per build — both with the same module name in the same configuration would conflict on the produced `<module>.swiftmodule` output.",
            aspects = [_apple_plugin_aspect],
            providers = [CcInfo],
        ),
        "macos_libs": attr.label_list(
            doc = "macOS Apple plugin libraries providing `CcInfo` (and optionally `SwiftInfo`). Routed to the macOS runner aggregator.",
            providers = [CcInfo],
        ),
        "ios_libs": attr.label_list(
            doc = "iOS Apple plugin libraries providing `CcInfo` (and optionally `SwiftInfo`). Routed to the iOS runner aggregator.",
            providers = [CcInfo],
        ),
        "android_libs": attr.label_list(
            doc = "Android plugin libraries (`flutter_android_plugin_library`, `kt_android_library`, `android_library`, or `java_library`) providing `JavaInfo`. Propagated through `FlutterInfo.android_plugin_libraries` so `flutter_android_app` and `flutter_integration_test(platform = \"android\")` compile and package them automatically.",
            providers = [JavaInfo],
        ),
        "linux_libs": attr.label_list(
            doc = "Linux plugin source bundles (`flutter_linux_plugin_library`). Propagated through `FlutterInfo.linux_plugin_libraries` so the Linux runner folds them into its `cc_common.compile()` pass.",
            providers = [FlutterLinuxPluginInfo],
        ),
        "windows_libs": attr.label_list(
            doc = "Windows plugin source bundles (`flutter_windows_plugin_library`). Propagated through `FlutterInfo.windows_plugin_libraries` so the Windows runner folds them into its `cc_common.compile()` pass.",
            providers = [FlutterWindowsPluginInfo],
        ),
        "native_assets": attr.label_list(
            doc = "Native Assets `CodeAsset` declarations (each a `flutter_native_asset` target). Propagated through `FlutterInfo.native_assets` and aggregated by `flutter_application` into the `--native-assets` manifest. Declare per-platform asset sets with `select()`: this is what routes each asset to the applications built for its platform, and listing two targets with the same `asset_id` in one configuration fails analysis.",
            providers = [FlutterNativeAssetInfo],
        ),
        "data_assets": attr.label_list(
            doc = "Native Assets `DataAsset` declarations (each a `flutter_data_asset` target). Propagated through `FlutterInfo.data_assets` and bundled at `flutter_assets/packages/<pkg>/<name>` by `flutter_application`.",
            providers = [FlutterDataAssetInfo],
        ),
        "apple_privacy_files": attr.label_list(
            doc = "`PrivacyInfo.xcprivacy` files this plugin contributes to the iOS / macOS app bundle. Apple requires every framework to ship a privacy manifest since iOS 17.4 / macOS 14.4; the App Store submission validator walks the bundle and aggregates them. Propagated through `FlutterInfo.apple_privacy_manifests` and threaded into the platform application bundle's `Resources/<pkg>/PrivacyInfo.xcprivacy` slot. Auto-detected by `flutter_pub_package` from both layouts pub plugins use (`Sources/<pkg>/PrivacyInfo.xcprivacy` and `Sources/<pkg>/Resources/PrivacyInfo.xcprivacy`).",
            allow_files = [".xcprivacy"],
        ),
        "fonts_json": attr.string(
            doc = "JSON-encoded list of font-family declarations (mirrors `flutter.fonts` in pubspec.yaml). Same shape as `flutter_library.fonts_json`.",
            default = "",
        ),
        "font_files": attr.label_keyed_string_dict(
            doc = "Map of font File label -> package-relative asset path. Same shape as `flutter_library.font_files`.",
            allow_files = True,
        ),
        "pkg_assets": attr.label_keyed_string_dict(
            doc = "Map of asset File label -> package-relative path (mirrors `flutter.assets`). Same shape as `flutter_library.pkg_assets`.",
            allow_files = True,
        ),
        "pkg_asset_platforms": attr.string_list_dict(
            doc = "Per-asset `platforms` conditions. Same shape as `flutter_library.pkg_asset_platforms`.",
        ),
        "pkg_asset_flavors": attr.string_list_dict(
            doc = "Per-asset `flavors` conditions. Same shape as `flutter_library.pkg_asset_flavors`.",
        ),
        "shader_includes": attr.label_list(
            doc = "Files this package's `pkg_shaders` may `#include` (e.g. " +
                  "`glob([\"shaders/**/*.glsl\"])`). A shader compiles in a " +
                  "sandbox holding only its declared inputs, so an include " +
                  "not listed here is not found.",
            allow_files = True,
        ),
        "pkg_shaders": attr.label_keyed_string_dict(
            doc = "Map of shader File label -> package-relative path (mirrors `flutter.shaders`). Same shape as `flutter_library.pkg_shaders`.",
            allow_files = True,
        ),
    },
    doc = "Declares a Flutter plugin with platform metadata and optional native dependencies.",
)
