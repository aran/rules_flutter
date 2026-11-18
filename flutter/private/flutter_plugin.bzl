"""Flutter plugin rule.

Declares a Flutter plugin: its Dart code, and a `flutter_plugin_platform` for
each platform it registers on, holding that platform's registration and native
library:

    flutter_plugin_platform(
        name = "linux",
        platform = "linux",
        plugin_class = "UrlLauncherPlugin",
        lib = ":url_launcher_linux",
    )

    flutter_plugin(
        name = "url_launcher",
        srcs = glob(["lib/**/*.dart"]),
        platforms = [":linux"],
    )
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo", "DartUsedWithoutImportInfo")
load("@rules_dart//dart:utils.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "LIBRARY_IMPORT_CHECKER_ATTRS", "PORTABLE_EXEC_GROUPS", "RUNTIME_INDEPENDENT_ATTR", "SUMMARY_ATTRS", "dart_info", "library_import_check", "library_package", "package_identity_attrs", "runtime_reset_when_independent")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterPluginPlatformInfo")
load("//flutter/private:flutter_apple_plugin_library.bzl", "FlutterAppleModuleHeadersInfo")
load("//flutter/private:flutter_desktop_plugin_info.bzl", "FlutterLinuxPluginInfo", "FlutterWindowsPluginInfo")
load("//flutter/private:flutter_font.bzl", "FONTS_ATTR")
load("//flutter/private:flutter_info.bzl", "flutter_info")
load("//flutter/private:flutter_info_forwarding.bzl", "flutter_info_forwarding_aspect")
load("//flutter/private:flutter_library.bzl", "ADDITIONAL_LICENSES_ATTR", "ASSET_FLAVORS_ATTR", "ASSET_PLATFORMS_ATTR", "LIBRARY_DATA_ATTR", "SHADER_FLAVORS_ATTR", "SHADER_PLATFORMS_ATTR", "SKY_ENGINE_ATTR", "build_pub_contributions", "flutter_analyzable_info", "own_additional_licenses")
load("//flutter/private:flutter_plugin_platform.bzl", "apple_resource_info", "plugin_platforms_of")
load("//flutter/private:native_libraries.bzl", "native_library_records")
load("//flutter/private:native_library_aspect.bzl", "native_library_aspect")
load("//flutter/private:native_link_aspect.bzl", "native_link_aspect")
load("//flutter/private:swiftpm_app_settings.bzl", "FlutterSwiftPMAppLibraryInfo")
load("//flutter/private:unbuilt_native_code.bzl", "FlutterUnbuiltNativeCodeInfo")

visibility("//flutter/...")

def build_plugin_struct(name, plugin_platforms, implements = ""):
    """Build a plugin metadata struct from per-platform metadata.

    Args:
        name: Plugin package name.
        plugin_platforms: Dict of platform -> FlutterPluginPlatformInfo.
        implements: The plugin this one implements, or "".

    Returns:
        A struct with name, platforms dict and implements.
    """
    return struct(name = name, platforms = plugin_platforms, implements = implements)

def _unbuilt_native_code(lib):
    """The message of a library standing in for unbuilt native code, or ""."""
    return lib[FlutterUnbuiltNativeCodeInfo].message if FlutterUnbuiltNativeCodeInfo in lib else ""

def _unbuilt_desktop_entry(lib, package_name):
    """A Linux or Windows plugin library entry with nothing to compile, whose runner fails on its message."""
    return struct(
        label = lib.label,
        srcs = depset(),
        hdrs = depset(),
        include_dirs = depset(),
        linkopts = (),
        link_errors = (),
        unbuilt_native_code = _unbuilt_native_code(lib),
        package = package_name,
    )

def plugin_contributions(ctx, package_name, package_root, declares_plugin):
    """What a plugin-shaped target adds to `FlutterInfo`, beyond its dependencies'.

    Shared by `flutter_plugin` and by the member of a generated pub package
    (`flutter_pub_member`), so a package contributes the same whether its target
    stands alone or is built with the others of its dependency cycle.

    Args:
      ctx: The rule context: the attributes of `flutter_plugin` other than `deps`.
      package_name: The Dart package name.
      package_root: Its package root, from `derive_package_root`.
      declares_plugin: Whether the target is a plugin to register. A pub
        package without a `flutter.plugin` block is not one, though it
        contributes assets and fonts.

    Returns:
      A dict of the keyword arguments of `flutter_info()` for what the target
      itself contributes.
    """

    platforms = plugin_platforms_of(ctx.label, ctx.attr.platforms)
    plugins = [build_plugin_struct(
        name = package_name,
        plugin_platforms = platforms,
        implements = ctx.attr.implements,
    )] if declares_plugin else []

    # The record of each `native_deps` library: what it is built from, and
    # what its bindings were generated from, when its build said so. Carried to
    # the app rather than used here: a plugin bundles nothing, and the app is
    # where the dev config that a reload reads is written. A code asset's are
    # found by the application, off the asset's own target; see
    # `code_asset_libraries.bzl`.
    native_libraries = native_library_records(ctx.attr.native_deps, package_name)

    # Each platform's native library, which `flutter_plugin_platform` gives
    # only to a build for that platform: the iOS and macOS libraries of one
    # plugin share a module name, and analysed in one configuration they
    # would collide on `<module>.swiftmodule`. The runner aggregator merges
    # the Apple ones' CcInfo + SwiftInfo into the runner's compile and link;
    # the Linux and Windows runners fold the desktop ones into theirs.
    extra_apple_plugin_libraries = []
    extra_linux_plugin_libraries = []
    extra_windows_plugin_libraries = []
    for platform_name in sorted(platforms):
        lib = platforms[platform_name].lib
        if lib == None:
            continue
        if platform_name in ("ios", "macos"):
            extra_apple_plugin_libraries.append(struct(
                platform = platform_name,
                label = lib.label,
                cc_info = lib[CcInfo] if CcInfo in lib else None,
                swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
                # The module's public C-family headers, for its add-to-app
                # framework.
                module_headers = lib[FlutterAppleModuleHeadersInfo].headers if FlutterAppleModuleHeadersInfo in lib else None,
                # The library's resources (a Swift package target's resource
                # bundle), for the app's bundle.
                resource_info = apple_resource_info(lib),
                unbuilt_native_code = _unbuilt_native_code(lib),
                package = package_name,
                # The plugin's privacy manifest, which an add-to-app framework
                # of the plugin carries.
                privacy_manifests = tuple(ctx.files.apple_privacy_files),
                # A library its Package.swift gives defines from the app, which
                # the app's aggregator, or add-to-app's plugin xcframeworks,
                # build for the app (`swiftpm_app_settings.bzl`).
                app_library = lib[FlutterSwiftPMAppLibraryInfo].library if FlutterSwiftPMAppLibraryInfo in lib else None,
            ))
            continue
        desktop = extra_linux_plugin_libraries if platform_name == "linux" else extra_windows_plugin_libraries
        if FlutterUnbuiltNativeCodeInfo in lib:
            desktop.append(_unbuilt_desktop_entry(lib, package_name))
            continue
        info = lib[FlutterLinuxPluginInfo] if platform_name == "linux" else lib[FlutterWindowsPluginInfo]
        desktop.append(struct(
            label = lib.label,
            srcs = info.srcs,
            hdrs = info.hdrs,
            include_dirs = info.include_dirs,
            linkopts = info.linkopts,
            link_errors = info.link_errors,
            unbuilt_native_code = "",
            package = package_name,
        ))

    extra_apple_privacy_manifests = list(ctx.files.apple_privacy_files)

    # The plugin's Android library, when this build selected one. Only an
    # Android build does, so nothing else loads the library's package. Its
    # `native_deps` libraries, the records of its package, go with it: an AAR
    # of the plugin carries them, as Gradle's of the plugin carries what its
    # own build links.
    android_group = platforms["android"].group if "android" in platforms else ""
    extra_android_libs = [
        struct(
            package = package_name,
            group = android_group,
            lib = lib,
        )
        for lib in ctx.attr.exports
    ]

    # Pub-package asset contributions (fonts/assets/shaders from the parsed
    # flutter:-block, applicable to plugins that also ship icon fonts or
    # bundled assets — same shape as flutter_library), of the Dart package.
    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = build_pub_contributions(ctx, package_name, package_root)

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

    return dict(
        plugins = plugins,
        native_libraries = native_libraries,
        apple_plugin_libraries = extra_apple_plugin_libraries,
        linux_plugin_libraries = extra_linux_plugin_libraries,
        windows_plugin_libraries = extra_windows_plugin_libraries,
        apple_privacy_manifests = extra_apple_privacy_manifests,
        pub_fonts = extra_pub_fonts,
        pub_assets = extra_pub_assets,
        pub_shaders = extra_pub_shaders,
        additional_licenses = own_additional_licenses(ctx, package_name),
        android_libs = extra_android_libs,
    )

def _flutter_plugin_impl(ctx):
    declared = library_package(ctx, ctx.files.srcs, ctx.files.resources)
    package_name = declared.package_name
    package_root = declared.package_root
    package = declared.record

    # A plugin contributes on more channels than a library does, but the shape
    # is the same: name what this target adds, and let each constructor merge
    # the dependencies. `shader_srcs`, the framework's own shaders, is absent
    # here — only `package:flutter` has them — which is a thing the caller
    # simply does not say, rather than something the merge has to probe for.
    info = dart_info(
        ctx = ctx,
        packages = [package],
        deps = ctx.attr.deps,
        srcs = ctx.files.srcs,
        resources = ctx.files.resources,
        analysis_deps = [ctx.attr._sky_engine],
        data = ctx.attr.data,
    )
    return [
        DefaultInfo(
            files = depset(ctx.files.srcs + ctx.files.resources),
            runfiles = info.runfiles,
        ),
        info,
        flutter_analyzable_info(ctx, package),
        flutter_info(
            deps = ctx.attr.deps,
            **plugin_contributions(ctx, package_name, package_root, True)
        ),
        # The app registers it from native code, so a library that brings it
        # into the app need not import it.
        DartUsedWithoutImportInfo(),
    ] + library_import_check(ctx, list(info.packages))

# The attributes of a plugin that describe the package itself, which the member
# of a generated pub package (`flutter_pub_member`) takes too. The rest of
# `flutter_plugin`'s are `deps` and `_sky_engine`: what a dependency cycle's
# library states once for all of its members.
PLUGIN_PACKAGE_ATTRS = package_identity_attrs() | {
    "srcs": attr.label_list(
        doc = "Dart source files for the plugin's public API.",
        allow_files = [".dart"],
    ),
    "resources": attr.label_list(
        doc = "Non-Dart files this package ships inside `lib/` — part of its published surface, but never compiled (a web plugin's bundled JS/wasm, templates, YAML). Anything under `lib/` is addressable as `package:<name>/<path>` whatever its extension, so these are members of the package: they ride `DartInfo.transitive_resources` and are staged wherever the whole package is staged, mirroring `dart_library`. Orthogonal to `assets`/`shaders`/`fonts`, which name flutter_assets bundle contributions. `.dart` files belong in `srcs`.",
        allow_files = True,
    ),
    "assets": attr.label_list(
        doc = "Asset files to include: any file of this target's Dart package, keyed as `flutter_library.assets` is.",
        allow_files = True,
    ),
    "additional_licenses": ADDITIONAL_LICENSES_ATTR,
    "platforms": attr.label_list(
        doc = "The platforms the plugin registers on: a `flutter_plugin_platform` for each, holding that platform's registration and native library, as the entries of a pubspec's `flutter: plugin: platforms:`.",
        providers = [FlutterPluginPlatformInfo],
    ),
    "implements": attr.string(
        doc = "The app-facing plugin this one implements, as a pubspec's `flutter: plugin: implements:` names it: on each platform it has an implementation for (an entry of `platforms` without a `default_package`), it is a candidate implementation of that plugin rather than of itself. An application registers one implementation of a plugin per platform: the only one it reaches, else the one it depends on directly, else the app-facing plugin's `default_package` for the platform.",
    ),
    "native_deps": attr.label_list(
        doc = "Native dependencies. Use select() for platform-conditional deps.",
        aspects = [native_library_aspect, native_link_aspect],
    ),
    "exports": attr.label_list(
        doc = "The plugin's Android libraries: a `flutter_android_plugin_library` or a `kt_android_library`, anything with `JavaInfo`. Its registration is the `android` entry of `platforms`. An Android app links the libraries of the plugins it depends on, and no others. Set this with `select()` on `@platforms//os:android`, with an empty list as the default, so that only an Android build loads and analyses it: `select({\"@platforms//os:android\": [\"//android:lib\"], \"//conditions:default\": []})`. Named `exports`, as a Java library's re-exported dependencies are, because rules_android dexes an APK's libraries one at a time by an aspect that follows `deps`, `exports` and `runtime_deps` and nothing else, so only an `exports` edge makes the library visible to it.",
        providers = [JavaInfo],
    ),
    "apple_privacy_files": attr.label_list(
        doc = "`PrivacyInfo.xcprivacy` files this plugin contributes to the iOS / macOS app bundle. Apple requires every framework to ship a privacy manifest since iOS 17.4 / macOS 14.4; the App Store submission validator walks the bundle and aggregates them. Propagated through `FlutterInfo.apple_privacy_manifests` and threaded into the platform application bundle's `Resources/<pkg>/PrivacyInfo.xcprivacy` slot. Auto-detected by `flutter_pub_package` from both layouts pub plugins use (`Sources/<pkg>/PrivacyInfo.xcprivacy` and `Sources/<pkg>/Resources/PrivacyInfo.xcprivacy`).",
        allow_files = [".xcprivacy"],
    ),
    "fonts": FONTS_ATTR,
    "asset_platforms": ASSET_PLATFORMS_ATTR,
    "shader_platforms": SHADER_PLATFORMS_ATTR,
    "asset_flavors": ASSET_FLAVORS_ATTR,
    "shader_flavors": SHADER_FLAVORS_ATTR,
    "shader_includes": attr.label_list(
        doc = "Files this package's `shaders` may `#include` (e.g. " +
              "`glob([\"shaders/**/*.glsl\"])`). A shader compiles in a " +
              "sandbox holding only its declared inputs, so an include " +
              "not listed here is not found.",
        allow_files = True,
    ),
    "shaders": attr.label_list(
        doc = "The package's fragment shaders, mirroring `flutter: shaders:`: any file of this target's Dart package, keyed as `flutter_library.shaders` is.",
        allow_files = True,
    ),
}

flutter_plugin = rule(
    implementation = _flutter_plugin_impl,
    # As `flutter_library`: configured once per web compiler that reaches it,
    # unless `runtime_independent`.
    cfg = runtime_reset_when_independent,
    attrs = PLUGIN_PACKAGE_ATTRS | {
        "_sky_engine": SKY_ENGINE_ATTR,
        "data": LIBRARY_DATA_ATTR,
        "deps": attr.label_list(
            doc = "Dart/Flutter library dependencies.",
            providers = [DartInfo],
            aspects = [flutter_info_forwarding_aspect],
        ),
    } | RUNTIME_INDEPENDENT_ATTR | SUMMARY_ATTRS | LIBRARY_IMPORT_CHECKER_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    toolchains = COPY_TO_DIRECTORY_TOOLCHAINS,
    doc = "Declares a Flutter plugin with platform metadata and optional native dependencies.",
)
