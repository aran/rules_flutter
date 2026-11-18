"""Tests that a pub plugin whose native code rules_flutter does not build fails the build of that platform.

The fixtures are the build files of real pub.dev plugins, trimmed:
`super_native_extensions` 0.9.1 and `rhttp` 0.18.0 build a Rust crate with
cargokit on every platform; `webcrypto` 0.6.0 ships the library its Linux CMake
build makes; `record_android` 1.5.1 and the `flutter create` plugin template
build nothing but their sources.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_desktop_plugin_info.bzl", "plugin_link_flags")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "make_android_failing_build_content",
    "make_flutter_member_build_content",
)
load(
    "//flutter/private:unbuilt_native_code.bzl",
    "cmake_native_build",
    "ffi_plugin_native_build",
    "gradle_native_build",
    "podspec_dropped_fields",
    "podspec_dropped_fields_message",
    "podspec_native_build",
    "unbuilt_native_code_message",
)

_FIXTURE = "//flutter/tests/unbuilt_native_code_fixture:"

# super_native_extensions 0.9.1, android/build.gradle (Groovy).
_CARGOKIT_GRADLE = """\
apply plugin: 'com.android.library'

android {
    namespace 'com.superlist.super_native_extensions'
    compileSdkVersion 31
}

apply from: "../cargokit/gradle/plugin.gradle"

cargokit {
    manifestDir = "../rust"
    libname = "super_native_extensions"
}
"""

# rhttp 0.18.0, android/build.gradle.kts.
_CARGOKIT_GRADLE_KTS = """\
plugins {
    id("com.android.library")
}

android {
    namespace = "com.flutter_rust_bridge.rhttp"
}

apply(from = "../cargokit/gradle/plugin.gradle")

extensions.getByName("cargokit").withGroovyBuilder {
    setProperty("manifestDir", "../rust")
    setProperty("libname", "rhttp")
}
"""

_EXTERNAL_NATIVE_BUILD_GRADLE = """\
android {
    externalNativeBuild {
        cmake {
            path "../src/CMakeLists.txt"
        }
    }
}
"""

# record_android 1.5.1, android/build.gradle.
_PLAIN_GRADLE = """\
apply plugin: 'com.android.library'
apply plugin: 'kotlin-android'

android {
    namespace = 'com.llfbandit.record'
}
"""

# super_native_extensions 0.9.1, macos/super_native_extensions.podspec.
_CARGOKIT_PODSPEC = """\
Pod::Spec.new do |s|
  s.name             = 'super_native_extensions'
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  # This is identitcal the script in iOS podspec
  s.script_phase = {
    :name => 'Build SuperNativeExtensions Rust library',
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../rust super_native_extensions',
    :execution_position=> :before_compile,
    :output_files => ["${BUILT_PRODUCTS_DIR}/libsuper_native_extensions.a"],
  }
end
"""

_SCRIPT_PHASE_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'go_plugin'
  s.script_phases = [{ :name => 'Build Go', :script => 'make -C ../go' }]
end
"""

_PLAIN_PODSPEC = """\
Pod::Spec.new do |s|
  s.name             = 'url_launcher_macos'
  # s.script_phase = { :name => 'commented out' }
  s.source_files     = 'url_launcher_macos/Sources/**/*.swift'
  s.dependency 'FlutterMacOS'
end
"""

# firebase_core 5.1.0, ios/firebase_core.podspec, trimmed: a pod dependency
# and preprocessor defines.
_FIREBASE_CORE_PODSPEC = """\
Pod::Spec.new do |s|
  s.name             = pubspec['name']
  s.source_files     = 'firebase_core/Sources/**/*.{swift,h,m}'

  # Flutter dependencies
  s.dependency 'Flutter'

  # Firebase dependencies
  s.dependency 'Firebase/CoreOnly', firebase_sdk_version

  s.static_framework = true
  s.pod_target_xcconfig = {
    'GCC_PREPROCESSOR_DEFINITIONS' => "LIBRARY_VERSION=\\\"#{library_version}\\\" LIBRARY_NAME=\\\"flutter-fire-core\\\"",
    'DEFINES_MODULE' => 'YES'
  }
end
"""

# A plugin over another plugin's pod, which its pubspec also depends on, and a
# vendored framework for macOS only.
_VENDORED_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'maps_darwin'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.dependency 'firebase_core'
  s.osx.vendored_frameworks = 'Frameworks/Maps.xcframework'
  s.pod_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited)' }
  # s.dependency 'Commented'
end
"""

# super_native_extensions 0.9.1, linux/CMakeLists.txt.
_CARGOKIT_CMAKE = """\
set(PLUGIN_NAME "super_native_extensions_plugin")
add_library(${PLUGIN_NAME} SHARED
  "super_native_extensions_plugin.cc"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)

include("../cargokit/cmake/cargokit.cmake")
apply_cargokit(${PLUGIN_NAME} ../rust super_native_extensions "")

set(super_native_extensions_bundled_libraries
  "${${PLUGIN_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
"""

# webcrypto 0.6.0, linux/CMakeLists.txt (an ffiPlugin building BoringSSL).
_BUNDLING_CMAKE = """\
add_library(webcrypto SHARED ${WEBCRYPTO_SOURCES})
set(webcrypto_bundled_libraries
  "$<TARGET_FILE:webcrypto>"
  PARENT_SCOPE
)
"""

# The `flutter create --template=plugin` CMakeLists.txt.
_PLAIN_CMAKE = """\
# set(my_plugin_bundled_libraries "lib.so" PARENT_SCOPE)
add_library(${PLUGIN_NAME} SHARED "my_plugin.cc")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
set(my_plugin_bundled_libraries
  ""
  PARENT_SCOPE
)
"""

def _gradle_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        'cargokit (`apply from: "../cargokit/gradle/plugin.gradle"` in android/build.gradle), which builds a Rust crate with cargo',
        gradle_native_build(_CARGOKIT_GRADLE, "android/build.gradle"),
    )
    asserts.equals(
        env,
        'cargokit (`apply(from = "../cargokit/gradle/plugin.gradle")` in android/build.gradle.kts), which builds a Rust crate with cargo',
        gradle_native_build(_CARGOKIT_GRADLE_KTS, "android/build.gradle.kts"),
    )
    asserts.equals(
        env,
        "Gradle's `externalNativeBuild` (CMake or ndk-build, in android/build.gradle)",
        gradle_native_build(_EXTERNAL_NATIVE_BUILD_GRADLE, "android/build.gradle"),
    )
    asserts.equals(env, "", gradle_native_build(_PLAIN_GRADLE, "android/build.gradle"))
    asserts.equals(env, "", gradle_native_build("// apply from: \"../cargokit/gradle/plugin.gradle\"\n", "android/build.gradle"))
    return unittest.end(env)

_gradle_test = unittest.make(_gradle_test_impl)

def _podspec_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "cargokit (`build_pod.sh`, run by a CocoaPods script phase in macos/super_native_extensions.podspec), which builds a Rust crate with cargo",
        podspec_native_build(_CARGOKIT_PODSPEC, "macos/super_native_extensions.podspec"),
    )
    asserts.equals(
        env,
        "a CocoaPods script phase (`s.script_phases = [{ :name => 'Build Go', :script => 'make -C ../go' }]` in ios/go_plugin.podspec)",
        podspec_native_build(_SCRIPT_PHASE_PODSPEC, "ios/go_plugin.podspec"),
    )
    asserts.equals(env, "", podspec_native_build(_PLAIN_PODSPEC, "macos/url_launcher_macos.podspec"))
    return unittest.end(env)

_podspec_test = unittest.make(_podspec_test_impl)

def _podspec_dropped_fields_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        [
            "`s.dependency 'Firebase/CoreOnly', firebase_sdk_version` (line 9)",
            "`%s` (line 13)" % _FIREBASE_CORE_PODSPEC.split("\n")[12].strip(),
        ],
        podspec_dropped_fields(_FIREBASE_CORE_PODSPEC, "ios"),
    )

    # The Flutter pods, a plugin of the pubspec, defines that only inherit,
    # comments, and another platform's lines are not dropped.
    asserts.equals(env, [], podspec_dropped_fields(_VENDORED_PODSPEC, "ios", ["firebase_core"]))
    asserts.equals(
        env,
        ["`s.osx.vendored_frameworks = 'Frameworks/Maps.xcframework'` (line 6)"],
        podspec_dropped_fields(_VENDORED_PODSPEC, "macos", ["firebase_core"]),
    )

    # A plugin's pod the pubspec does not depend on is no plugin of the graph.
    asserts.equals(
        env,
        ["`s.dependency 'firebase_core'` (line 5)", "`s.osx.vendored_frameworks = 'Frameworks/Maps.xcframework'` (line 6)"],
        podspec_dropped_fields(_VENDORED_PODSPEC, "macos"),
    )
    asserts.equals(env, [], podspec_dropped_fields(_PLAIN_PODSPEC, "macos"))

    message = podspec_dropped_fields_message(
        "firebase_core",
        "5.1.0",
        "ios",
        "ios/firebase_core.podspec",
        podspec_dropped_fields(_FIREBASE_CORE_PODSPEC, "ios"),
    )
    asserts.true(env, message.startswith(
        "package:firebase_core 5.1.0 has no Package.swift for iOS, and its podspec (ios/firebase_core.podspec) " +
        "adds to the plugin's build what rules_flutter drops, since it does not run CocoaPods:\n" +
        "    `s.dependency 'Firebase/CoreOnly', firebase_sdk_version` (line 9)\n",
    ), message)
    for part in ["so the iOS build stops here", "`flutter_pub.plugin_overlays`", "`flutter_apple_plugin_library`", "`flutter_pub.from_lock(resolve = ...)`"]:
        asserts.true(env, part in message, "%r not in %r" % (part, message))
    return unittest.end(env)

_podspec_dropped_fields_test = unittest.make(_podspec_dropped_fields_test_impl)

def _cmake_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "cargokit (`apply_cargokit()` in linux/CMakeLists.txt, line 8), which builds a Rust crate with cargo",
        cmake_native_build(_CARGOKIT_CMAKE, "linux/CMakeLists.txt"),
    )
    asserts.equals(
        env,
        "`webcrypto_bundled_libraries` in linux/CMakeLists.txt, line 2, which bundles $<TARGET_FILE:webcrypto> with the app",
        cmake_native_build(_BUNDLING_CMAKE, "linux/CMakeLists.txt"),
    )
    asserts.equals(env, "", cmake_native_build(_PLAIN_CMAKE, "linux/CMakeLists.txt"))
    return unittest.end(env)

_cmake_test = unittest.make(_cmake_test_impl)

def _message_test_impl(ctx):
    env = unittest.begin(ctx)
    message = unbuilt_native_code_message(
        "rhttp",
        "0.18.0",
        "macos",
        ffi_plugin_native_build("its podspec, macos/rhttp.podspec"),
    )
    asserts.true(env, message.startswith(
        "package:rhttp 0.18.0 builds native code for macOS with `ffiPlugin: true` in its pubspec, " +
        "for which Flutter builds the plugin's native sources with its podspec, macos/rhttp.podspec. ",
    ), message)
    for part in ["so the macOS build stops here", "`native_deps`", "`flutter_pub.plugin_overlays`", "`flutter_pub.from_lock(resolve = ...)`"]:
        asserts.true(env, part in message, "%r not in %r" % (part, message))
    return unittest.end(env)

_message_test = unittest.make(_message_test_impl)

def _android_content_test_impl(ctx):
    """The Android package fails with the message as written, quotes and all."""
    env = unittest.begin(ctx)
    message = 'package:x 1.0 builds native code for Android with cargokit (`apply from: "../cargokit/gradle/plugin.gradle"`)'
    asserts.equals(env, "fail(%s)\n" % repr(message), make_android_failing_build_content(message))
    return unittest.end(env)

_android_content_test = unittest.make(_android_content_test_impl)

def _member_content_test_impl(ctx):
    """Each platform with unbuilt native code gets a stand-in library in its slot."""
    env = unittest.begin(ctx)
    content = make_flutter_member_build_content(
        name = "rusty",
        language_version = "3.4",
        code_assets = [],
        unreplaced_hook = "",
        plugin_platforms = {
            "ios": {"pluginClass": "RustyPlugin"},
            "linux": {"ffiPlugin": True},
            "macos": {"ffiPlugin": True},
            "windows": {"ffiPlugin": True},
        },
        apple_libs = {"ios": "@flutter_pub_apple__rusty//:rusty_apple_ios"},
        unbuilt_native_code = {
            "linux": "linux message",
            "macos": "macos message",
            "windows": "windows message",
        },
    )
    for part in [
        'load("@rules_flutter//flutter/private:generated_repos.bzl", "flutter_unbuilt_plugin_library")',
        'flutter_unbuilt_plugin_library(\n    name = "rusty_apple_macos",\n    message = "macos message",',
        'flutter_unbuilt_plugin_library(\n    name = "rusty_linux",\n    message = "linux message",',
        'flutter_unbuilt_plugin_library(\n    name = "rusty_windows",\n    message = "windows message",',
        'flutter_plugin_platform(\n    name = "plugin_macos",\n    ffi_plugin = True,\n    lib = ":rusty_apple_macos",\n    platform = "macos",\n)',
        'flutter_plugin_platform(\n    name = "plugin_ios",\n    lib = "@flutter_pub_apple__rusty//:rusty_apple_ios",\n    platform = "ios",\n    plugin_class = "RustyPlugin",\n)',
        'flutter_plugin_platform(\n    name = "plugin_linux",\n    ffi_plugin = True,\n    lib = ":rusty_linux",\n    platform = "linux",\n)',
        'flutter_plugin_platform(\n    name = "plugin_windows",\n    ffi_plugin = True,\n    lib = ":rusty_windows",\n    platform = "windows",\n)',
    ]:
        asserts.true(env, part in content, "%r not in:\n%s" % (part, content))

    # The Apple libraries are the Apple repository's, not the spoke's.
    asserts.false(env, "flutter_apple_plugin_library(" in content, content)
    return unittest.end(env)

_member_content_test = unittest.make(_member_content_test_impl)

def _link_flags_test_impl(ctx):
    """A Linux or Windows runner fails with the message of each plugin it would ship without its library."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "package:alpha 1.0 builds native code for Linux\n\npackage:zeta 1.0 builds native code for Linux")
    return analysistest.end(env)

_link_flags_test = analysistest.make(_link_flags_test_impl, expect_failure = True)

def _link_flags_subject_impl(_ctx):
    plugin_link_flags([
        struct(package = "fine", linkopts = ["-lm"], link_errors = [], unbuilt_native_code = ""),
        struct(package = "zeta", linkopts = [], link_errors = [], unbuilt_native_code = "package:zeta 1.0 builds native code for Linux"),
        struct(package = "alpha", linkopts = [], link_errors = [], unbuilt_native_code = "package:alpha 1.0 builds native code for Linux"),
    ], "Linux")
    return []

_link_flags_subject = rule(implementation = _link_flags_subject_impl)

def _apple_fails_test_impl(ctx):
    """The macOS build of an app with the plugin fails with the plugin's message."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "package:rusty 1.0 builds native code for macOS with cargokit")
    return analysistest.end(env)

_apple_fails_test = analysistest.make(_apple_fails_test_impl, expect_failure = True)

def _other_apple_platform_builds_test_impl(ctx):
    """The iOS build of the same app is unaffected: the stand-in is the macOS library only."""
    env = analysistest.begin(ctx)
    return analysistest.end(env)

_other_apple_platform_builds_test = analysistest.make(_other_apple_platform_builds_test_impl)

def _podspec_pod_fails_test_impl(ctx):
    """A plugin built from a podspec that depends on a pod fails the macOS build, naming it."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "package:podspec_plugin 1.0.0 has no Package.swift for macOS, and its podspec (macos/podspec_plugin.podspec)")
    asserts.expect_failure(env, "`s.dependency 'Sparkle', '~> 2.6'` (line 7)")
    return analysistest.end(env)

_podspec_pod_fails_test = analysistest.make(_podspec_pod_fails_test_impl, expect_failure = True)

def _podspec_pod_fails_ios_test_impl(ctx):
    """And the iOS build, for an iOS platform, where the plugin's iOS library is analysed."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "package:podspec_plugin 1.0.0 has no Package.swift for iOS, and its podspec (ios/podspec_plugin.podspec)")
    asserts.expect_failure(env, "`s.dependency 'GoogleMaps', '~> 8.4'` (line 7)")
    return analysistest.end(env)

_podspec_pod_fails_ios_test = analysistest.make(
    _podspec_pod_fails_ios_test_impl,
    expect_failure = True,
    config_settings = {"//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64"))},
)

def _platform(label):
    return {"//command_line_option:platforms": str(Label(label))}

def _carries_linux_message_test_impl(ctx):
    """In a Linux build the plugin hands the runner its Linux stand-in, with its message."""
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]
    asserts.equals(
        env,
        ["package:rusty 1.0 builds native code for Linux with cargokit"],
        [e.unbuilt_native_code for e in info.linux_plugin_libraries.to_list()],
    )
    asserts.equals(env, [], info.apple_plugin_libraries.to_list())
    return analysistest.end(env)

_carries_linux_message_test = analysistest.make(
    _carries_linux_message_test_impl,
    config_settings = _platform("//flutter/platforms:linux_x64"),
)

def _carries_macos_message_test_impl(ctx):
    """In a macOS build the plugin hands the aggregator its macOS stand-in, and no Linux one."""
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]
    asserts.equals(
        env,
        ["package:rusty 1.0 builds native code for macOS with cargokit"],
        [e.unbuilt_native_code for e in info.apple_plugin_libraries.to_list()],
    )
    asserts.equals(env, [], info.linux_plugin_libraries.to_list())
    return analysistest.end(env)

_carries_macos_message_test = analysistest.make(
    _carries_macos_message_test_impl,
    config_settings = _platform("//flutter/platforms:macos_arm64"),
)

def unbuilt_native_code_test_suite(name):
    """The tests of `unbuilt_native_code.bzl` and of the builds that fail on it.

    Args:
      name: The name of the unit test suite, and the prefix of the analysis tests.
    """
    unittest.suite(
        name,
        _gradle_test,
        _podspec_test,
        _podspec_dropped_fields_test,
        _cmake_test,
        _message_test,
        _android_content_test,
        _member_content_test,
    )
    _link_flags_subject(name = name + "_link_flags_subject", tags = ["manual"])
    _link_flags_test(name = name + "_link_flags_test", target_under_test = ":" + name + "_link_flags_subject")

    # The Apple builds are analysed only on a macOS host: there the host is the
    # macOS target the aggregators build for, and rules_apple's tools have a
    # platform to run on.
    macos = ["@platforms//os:macos"]
    _apple_fails_test(name = name + "_apple_fails_test", target_under_test = _FIXTURE + "macos_plugins", target_compatible_with = macos)
    _other_apple_platform_builds_test(name = name + "_other_apple_platform_builds_test", target_under_test = _FIXTURE + "ios_plugins", target_compatible_with = macos)
    _podspec_pod_fails_test(name = name + "_podspec_pod_fails_test", target_under_test = "//flutter/tests/podspec_fixture:macos_plugins", target_compatible_with = macos)
    _podspec_pod_fails_ios_test(name = name + "_podspec_pod_fails_ios_test", target_under_test = "//flutter/tests/podspec_fixture:ios_plugins", target_compatible_with = macos)
    _carries_linux_message_test(name = name + "_carries_linux_message_test", target_under_test = _FIXTURE[:-1] + "/rusty")
    _carries_macos_message_test(name = name + "_carries_macos_message_test", target_under_test = _FIXTURE[:-1] + "/rusty", target_compatible_with = macos)
