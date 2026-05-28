"""Wrap a Flutter plugin's Android Kotlin/Java sources in a kt_android_library.

Public Tier-2 API: re-exported from `flutter/android.bzl`. For pub.dev
plugins, `flutter_pub_package` emits this automatically when
`android/src/main/{kotlin,java}/**/*.{kt,java}` sources are detected.

Wraps `kt_android_library` with the Flutter Android engine AAR as a dep
so the plugin's Kotlin/Java sees the FlutterPlugin SPI. A minimal
`AndroidManifest.xml` is generated when the plugin doesn't ship its
own manifest fragment.
"""

load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

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
        name: Target name. Pass to `android_binary.deps` either directly or
            via the `flutter_android_app` Tier-1 macro's auto-aggregation.
        srcs: Kotlin/Java source files (`.kt`, `.java`).
        java_package: Java package the plugin's classes live in
            (e.g. `io.flutter.plugins.urllauncher`). Used to generate a
            minimal manifest when none is provided. Defaults to
            `dev.flutter.plugins.<name>` to match the convention the
            registrant uses for fully-qualified class names.
        flutter_engine: A `flutter_android_engine` target (the Flutter
            Android engine AAR). Required for the plugin's Kotlin/Java
            to compile against the FlutterPlugin SPI.
        manifest: Optional AndroidManifest.xml fragment shipped with the
            plugin. Defaults to a minimal generated one.
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

    actual_manifest = manifest
    if not actual_manifest:
        manifest_target = "_%s__manifest" % name
        native.genrule(
            name = manifest_target,
            outs = ["_%s_AndroidManifest.xml" % name],
            cmd = "cat > $@ <<'EOF'\n" + _DEFAULT_MANIFEST_TEMPLATE.replace("PACKAGE_NAME", java_package) + "EOF",
            tags = tags,
        )
        actual_manifest = ":" + manifest_target

    plugin_deps = list(deps)
    if flutter_engine:
        plugin_deps.append(flutter_engine)

    kt_android_library(
        name = name,
        srcs = srcs,
        custom_package = java_package,
        manifest = actual_manifest,
        deps = plugin_deps,
        tags = tags,
        visibility = visibility,
        **kwargs
    )
