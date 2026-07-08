"""Unit tests for flutter_pub_package.bzl's generated Android sub-package.

The fixture shapes mirror real pub.dev plugins:

* `record_android` 1.5.1 — Kotlin sources, `android/src/main/res/`
  resources referenced as `R.drawable.ic_mic`, a library manifest
  declaring RECORD_AUDIO, a `build.gradle` with a `namespace` and **no**
  dependencies block (androidx arrives via the Flutter embedding's
  compile classpath, exactly as in Gradle builds).
* `url_launcher_android` — Kotlin sources, no resources, gradle deps.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "make_android_subpackage_build_content",
    "parse_android_manifest_package",
    "parse_gradle_android_namespace",
)

# Verbatim shape of record_android 1.5.1's android/build.gradle (trimmed):
# Groovy DSL, namespace assignment, no dependencies block at all.
_RECORD_ANDROID_GRADLE = """\
group 'com.llfbandit.record'
version '1.0'

apply plugin: 'com.android.library'
apply plugin: 'kotlin-android'

android {
    namespace = 'com.llfbandit.record'

    compileSdk = flutter.compileSdkVersion

    sourceSets {
        main.java.srcDirs += 'src/main/kotlin'
    }

    defaultConfig {
        minSdk = 23
    }
}
"""

_GRADLE_KTS_NAMESPACE = """\
android {
    namespace = "dev.example.kts_plugin"
}
"""

# Legacy (pre-AGP-8) Groovy namespace method-call syntax, no `=`.
_GRADLE_GROOVY_NAMESPACE_NO_ASSIGN = """\
android {
    namespace 'dev.example.legacy'
}
"""

_RECORD_ANDROID_MANIFEST = """\
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
  package="com.llfbandit.record">

    <uses-permission android:name="android.permission.RECORD_AUDIO" />
</manifest>
"""

_MANIFEST_NO_PACKAGE = """\
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
</manifest>
"""

def _parse_gradle_android_namespace_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "com.llfbandit.record",
        parse_gradle_android_namespace(_RECORD_ANDROID_GRADLE),
    )
    asserts.equals(
        env,
        "dev.example.kts_plugin",
        parse_gradle_android_namespace(_GRADLE_KTS_NAMESPACE),
    )
    asserts.equals(
        env,
        "dev.example.legacy",
        parse_gradle_android_namespace(_GRADLE_GROOVY_NAMESPACE_NO_ASSIGN),
    )
    asserts.equals(env, "", parse_gradle_android_namespace("android {}\n"))

    return unittest.end(env)

parse_gradle_android_namespace_test = unittest.make(_parse_gradle_android_namespace_test_impl)

def _parse_android_manifest_package_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "com.llfbandit.record",
        parse_android_manifest_package(_RECORD_ANDROID_MANIFEST),
    )
    asserts.equals(env, "", parse_android_manifest_package(_MANIFEST_NO_PACKAGE))
    asserts.equals(env, "", parse_android_manifest_package("not xml"))

    return unittest.end(env)

parse_android_manifest_package_test = unittest.make(_parse_android_manifest_package_test_impl)

def _record_android_subpackage_test_impl(ctx):
    """record_android shape: Kotlin + res/ + manifest + dep-less gradle."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "com.llfbandit.record",
        extra_maven_labels = [],
        android_manifest = "android/src/main/AndroidManifest.xml",
        has_resources = True,
    )

    # Resources must be compiled into the library so R.drawable.* resolves
    # and the drawables merge into the consuming APK.
    asserts.true(
        env,
        'resource_files = glob(["src/main/res/**"], allow_empty = False)' in content,
        "expected resource_files glob in:\n" + content,
    )

    # The R class (and BuildConfig) must be generated against the plugin's
    # own namespace.
    asserts.true(
        env,
        'custom_package = "com.llfbandit.record"' in content,
        "expected custom_package in:\n" + content,
    )
    asserts.true(
        env,
        "_build_config/com/llfbandit/record/BuildConfig.java" in content,
        "expected BuildConfig against the plugin namespace in:\n" + content,
    )

    # The plugin's own manifest is used (RECORD_AUDIO merges into the APK).
    asserts.true(
        env,
        'manifest = "src/main/AndroidManifest.xml"' in content,
        "expected plugin manifest in:\n" + content,
    )
    asserts.true(env, "exports_manifest = 1" in content, content)

    # The androidx compile baseline comes from the engine target's exports
    # (mirroring the Flutter embedding POM), not from a per-plugin list —
    # a dep-less build.gradle still compiles against NotificationCompat etc.
    asserts.true(env, '":_engine",' in content, content)
    asserts.false(
        env,
        "@rules_android_maven//:androidx" in content,
        "androidx deps must flow via the engine's exports, not be " +
        "restated per plugin:\n" + content,
    )

    return unittest.end(env)

record_android_subpackage_test = unittest.make(_record_android_subpackage_test_impl)

def _resources_without_manifest_test_impl(ctx):
    """Resources force a manifest: synthesize one when the plugin ships none."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "dev.example.res_only_manifestless",
        extra_maven_labels = [],
        android_manifest = "",
        has_resources = True,
    )

    asserts.true(
        env,
        'resource_files = glob(["src/main/res/**"], allow_empty = False)' in content,
        content,
    )

    # rules_android requires a manifest whenever resource_files is set;
    # AGP treats a missing library manifest as an empty one, so we
    # synthesize the equivalent.
    asserts.true(env, 'manifest = ":_manifest"' in content, content)
    asserts.true(
        env,
        'package=\\"dev.example.res_only_manifestless\\"' in content,
        content,
    )
    asserts.false(env, "exports_manifest" in content, content)

    return unittest.end(env)

resources_without_manifest_test = unittest.make(_resources_without_manifest_test_impl)

def _no_resources_subpackage_test_impl(ctx):
    """url_launcher_android shape: sources + manifest, no res/."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "io.flutter.plugins.urllauncher",
        extra_maven_labels = ["@rules_android_maven//:androidx_browser_browser"],
        android_manifest = "android/src/main/AndroidManifest.xml",
        has_resources = False,
    )

    asserts.false(env, "resource_files" in content, content)
    asserts.true(
        env,
        '"@rules_android_maven//:androidx_browser_browser",' in content,
        "gradle-declared deps must still be wired:\n" + content,
    )

    return unittest.end(env)

no_resources_subpackage_test = unittest.make(_no_resources_subpackage_test_impl)

def _empty_subpackage_test_impl(ctx):
    """No Android sources and no resources → the empty aggregator stub."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "",
        java_package = "",
        extra_maven_labels = [],
    )

    asserts.true(env, "srcs = []" in content, content)
    asserts.false(env, "resource_files" in content, content)
    asserts.false(env, "flutter_android_engine" in content, content)

    return unittest.end(env)

empty_subpackage_test = unittest.make(_empty_subpackage_test_impl)

def flutter_pub_package_test_suite(name):
    unittest.suite(
        name,
        parse_gradle_android_namespace_test,
        parse_android_manifest_package_test,
        record_android_subpackage_test,
        resources_without_manifest_test,
        no_resources_subpackage_test,
        empty_subpackage_test,
    )
