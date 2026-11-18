"""Wrap a Flutter plugin's Android Kotlin/Java sources in a kt_android_library.

Public Tier-2 API: re-exported from `flutter/android.bzl`. For pub.dev
plugins, `flutter_pub_package` emits this automatically when
`android/src/main/{kotlin,java}/**/*.{kt,java}` sources are detected.

Wraps `kt_android_library` with the Flutter Android engine AAR as a dep
so the plugin's Kotlin/Java sees the FlutterPlugin SPI. A minimal
`AndroidManifest.xml` is generated when the plugin doesn't ship its
own manifest fragment, and a `BuildConfig` for its package, as Gradle
generates, with `DEBUG` and `BUILD_TYPE` of the build's mode.
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load(":android_build_config.bzl", "android_build_config")

visibility("//flutter/...")

_DEFAULT_MANIFEST_TEMPLATE = """\
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="PACKAGE_NAME">
</manifest>
"""

def flutter_android_plugin_library(
        name,
        srcs = [],
        java_package = None,
        flutter_engine = None,
        manifest = None,
        deps = [],
        visibility = None,
        tags = None,
        **kwargs):
    """Wrap a Flutter plugin's Android Kotlin/Java sources in a kt_android_library.

    Args:
        name: Target name. Add it to `flutter_android_app(deps = ...)`,
            which packages it and registers its plugin class, or list it in
            the `exports` of the plugin's `flutter_plugin` (under a
            `select()` on `@platforms//os:android`), so that every app that
            depends on the plugin links it, as it does a pub.dev plugin's.
        srcs: Kotlin/Java source files (`.kt`, `.java`).
        java_package: Java package the plugin's classes live in
            (e.g. `io.flutter.plugins.urllauncher`). The namespace of its
            generated `BuildConfig`, and of a minimal manifest when none is
            provided. Defaults to
            `dev.flutter.plugins.<name>` to match the convention the
            registrant uses for fully-qualified class names.
        flutter_engine: A `flutter_android_engine` target declared with
            `neverlink = True`. Required for the plugin's Kotlin/Java to
            compile against the FlutterPlugin SPI; the app packages its own
            engine, of its own ABI.
        manifest: Optional AndroidManifest.xml fragment shipped with the
            plugin. Its components and permissions (`<receiver>`,
            `<service>`, `<uses-permission>`, ...) are merged into the app's
            manifest, as AGP merges a library's. Defaults to a minimal
            generated one that contributes nothing.
        deps: Extra Maven AAR / android_library deps. The Flutter
            Android engine is added automatically.
        visibility: Target visibility.
        tags: Bazel tags. Defaults to ["manual"].
        **kwargs: Forwarded to kt_android_library.
    """
    if tags == None:
        tags = ["manual"]

    if java_package == None:
        java_package = "dev.flutter.plugins.%s" % name.replace("_", "")

    # rules_android's `android_library` keeps its manifest to itself unless
    # told to export it; AGP always merges a library's. The generated
    # stand-in has nothing to contribute.
    if manifest:
        kwargs.setdefault("exports_manifest", 1)

    actual_manifest = manifest
    if not actual_manifest:
        manifest_target = "_%s__manifest" % name
        write_file(
            name = manifest_target,
            out = "_%s_AndroidManifest.xml" % name,
            content = [_DEFAULT_MANIFEST_TEMPLATE.replace("PACKAGE_NAME", java_package)],
            tags = tags,
        )
        actual_manifest = ":" + manifest_target

    # Gradle generates a BuildConfig for every library's namespace and
    # plugins read BuildConfig.DEBUG from it.
    build_config = "_%s__build_config" % name
    android_build_config(
        name = build_config,
        package = java_package,
        tags = tags,
    )

    plugin_deps = list(deps)
    if flutter_engine:
        plugin_deps.append(flutter_engine)

    kt_android_library(
        name = name,
        srcs = srcs + [":" + build_config],
        custom_package = java_package,
        manifest = actual_manifest,
        deps = plugin_deps,
        tags = tags,
        visibility = visibility,
        **kwargs
    )
