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

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_info", "derive_lib_root", "derive_package_name")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterDataAssetInfo", "FlutterNativeAssetInfo")
load("//flutter/private:common.bzl", "collect_native_libs")
load("//flutter/private:flutter_desktop_plugin_info.bzl", "FlutterLinuxPluginInfo", "FlutterWindowsPluginInfo")
load("//flutter/private:flutter_info.bzl", "flutter_info")
load("//flutter/private:flutter_library.bzl", "build_pub_contributions")

def build_plugin_struct(name, plugin_platforms):
    """Build a plugin metadata struct from per-platform metadata.

    Args:
        name: Plugin package name.
        plugin_platforms: Dict of platform -> {pluginClass, dartPluginClass, ...}.

    Returns:
        A struct with name and platforms dict.
    """
    return struct(name = name, platforms = plugin_platforms)

def _flutter_plugin_impl(ctx):
    package_name = derive_package_name(
        ctx.attr.package_name,
        ctx.label.package,
        ctx.label.name,
    )
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Build plugin metadata.
    # If plugin_platforms_json is set, decode it directly.
    # Otherwise construct from scalar attrs (for manual BUILD files).
    if ctx.attr.plugin_platforms_json:
        plugin_platforms = json.decode(ctx.attr.plugin_platforms_json)
    else:
        plugin_platforms = {}
        for p in ctx.attr.platforms:
            info = {}
            if ctx.attr.plugin_class:
                info["pluginClass"] = ctx.attr.plugin_class
            if ctx.attr.dart_plugin_class:
                info["dartPluginClass"] = ctx.attr.dart_plugin_class
            plugin_platforms[p] = info

    plugin = build_plugin_struct(
        name = package_name,
        plugin_platforms = plugin_platforms,
    )

    # Collect native libs from native_deps.
    native_libs = collect_native_libs(ctx.attr.native_deps)

    # Pull CcInfo + SwiftInfo from the per-platform Apple plugin libraries
    # so the runner aggregator can merge them into the runner's
    # swift_library compilation/link inputs. The `apple_libs` attribute
    # is a label_list typically populated via a `select()` on the target
    # platform — only the relevant platform's swift_library is in scope
    # for any one build, which avoids the swiftmodule output collision
    # that would happen if both platforms' libraries with the same module
    # name analyzed in the same configuration.
    extra_apple_plugin_libraries = []
    for lib in ctx.attr.apple_libs:
        platform_name = "macos" if "macos" in lib.label.name else ("ios" if "ios" in lib.label.name else "")
        if not platform_name:
            fail("flutter_plugin: apple_libs entry %s must have 'macos' or 'ios' in its label name" % lib.label)
        extra_apple_plugin_libraries.append(struct(
            platform = platform_name,
            label = lib.label,
            cc_info = lib[CcInfo] if CcInfo in lib else None,
            swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
            package = package_name,
        ))

    # Pull source bundles from linux + windows plugin libraries so the
    # corresponding runner can fold them into its compile.
    extra_linux_plugin_libraries = []
    for lib in ctx.attr.linux_libs:
        if FlutterLinuxPluginInfo not in lib:
            fail("flutter_plugin: linux_libs entry %s must provide FlutterLinuxPluginInfo (use flutter_linux_plugin_library)." % lib.label)
        info = lib[FlutterLinuxPluginInfo]
        extra_linux_plugin_libraries.append(struct(
            label = lib.label,
            srcs = info.srcs,
            hdrs = info.hdrs,
            include_dirs = info.include_dirs,
            package = package_name,
        ))

    extra_windows_plugin_libraries = []
    for lib in ctx.attr.windows_libs:
        if FlutterWindowsPluginInfo not in lib:
            fail("flutter_plugin: windows_libs entry %s must provide FlutterWindowsPluginInfo (use flutter_windows_plugin_library)." % lib.label)
        info = lib[FlutterWindowsPluginInfo]
        extra_windows_plugin_libraries.append(struct(
            label = lib.label,
            srcs = info.srcs,
            hdrs = info.hdrs,
            include_dirs = info.include_dirs,
            package = package_name,
        ))

    # Native Assets contributed by this plugin (or its parent ext/ overlay).
    extra_native_assets = []
    for dep in ctx.attr.native_assets:
        if FlutterNativeAssetInfo not in dep:
            fail(
                "flutter_plugin: native_assets entry %s must provide " % dep.label +
                "FlutterNativeAssetInfo (use flutter_native_asset).",
            )
        extra_native_assets.append(dep[FlutterNativeAssetInfo])

    extra_data_assets = []
    for dep in ctx.attr.data_assets:
        if FlutterDataAssetInfo not in dep:
            fail(
                "flutter_plugin: data_assets entry %s must provide " % dep.label +
                "FlutterDataAssetInfo (use flutter_data_asset).",
            )
        extra_data_assets.append(dep[FlutterDataAssetInfo])

    extra_apple_privacy_manifests = list(ctx.files.apple_privacy_files)

    # Pub-package asset contributions (fonts/assets/shaders from the parsed
    # flutter:-block, applicable to plugins that also ship icon fonts or
    # bundled assets — same shape as flutter_library). asset_pkg uses the
    # rule's `package_name` attr verbatim (empty = bare paths).
    asset_pkg = ctx.attr.package_name
    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = build_pub_contributions(
        asset_pkg,
        ctx.attr.fonts_json,
        ctx.attr.font_files,
        ctx.attr.pkg_assets,
        ctx.attr.pkg_shaders,
    )

    # `resources` names the non-Dart remainder of `lib/`; a Dart source there
    # is a mis-filed `srcs` entry, and identical paths with identical
    # extensions would otherwise collide silently. Mirrors `dart_library`.
    for f in ctx.files.resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the non-Dart remainder of `lib/`; Dart sources belong in " +
                 "`srcs`.") % (ctx.label, f.short_path),
            )

    # A plugin contributes on more channels than a library does, but the shape
    # is the same: name what this target adds, and let each constructor merge
    # the dependencies. `shaders` is absent here — a plugin has no such
    # attribute — which is a thing the caller simply does not say, rather than
    # something the merge has to probe for.
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
        ),
        flutter_info(
            deps = ctx.attr.deps,
            asset_dirs = ctx.files.assets,
            plugins = [plugin],
            native_libs = native_libs,
            apple_plugin_libraries = extra_apple_plugin_libraries,
            linux_plugin_libraries = extra_linux_plugin_libraries,
            windows_plugin_libraries = extra_windows_plugin_libraries,
            apple_privacy_manifests = extra_apple_privacy_manifests,
            native_assets = extra_native_assets,
            data_assets = extra_data_assets,
            pub_fonts = extra_pub_fonts,
            pub_assets = extra_pub_assets,
            pub_shaders = extra_pub_shaders,
        ),
    ]

flutter_plugin = rule(
    implementation = _flutter_plugin_impl,
    attrs = {
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
        "dart_plugin_class": attr.string(
            doc = "Dart-only plugin class name (for Dart-side registration).",
        ),
        "plugin_platforms_json": attr.string(
            doc = "JSON-encoded per-platform metadata dict. Overrides platforms/plugin_class/dart_plugin_class if set.",
        ),
        "native_deps": attr.label_list(
            doc = "Native dependencies. Use select() for platform-conditional deps.",
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
        "language_version": attr.string(
            doc = "Dart language version (`<major>.<minor>`) for this package's `package_config.json` entry. Mirrors `dart_library`'s attribute. Empty string means defer to the toolchain default.",
        ),
        "apple_libs": attr.label_list(
            doc = "Per-platform Apple swift_library targets (typically `flutter_apple_plugin_library`s) carrying the plugin's macOS / iOS native code. Each label's name must contain `macos` or `ios` so the runner aggregator can route it. Set this via `select()` on the target platform so only one platform's swift_library analyzes per build — both with the same module name in the same configuration would conflict on the produced `<module>.swiftmodule` output.",
            providers = [CcInfo],
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
            doc = "Native Assets `DataAsset` declarations (each a `flutter_data_asset` target). Propagated through `FlutterInfo.data_assets` and bundled at `flutter_assets/data/<pkg>/<name>` by `flutter_application`.",
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
        "pkg_shaders": attr.label_keyed_string_dict(
            doc = "Map of shader File label -> package-relative path (mirrors `flutter.shaders`). Same shape as `flutter_library.pkg_shaders`.",
            allow_files = True,
        ),
    },
    doc = "Declares a Flutter plugin with platform metadata and optional native dependencies.",
)
