# Bazel-native overlay for `package:audio_session` 0.1.x.
#
# audio_session's iOS / macOS sources `#import <AVFoundation/AVFoundation.h>`
# and reference symbols like `_AVAudioSessionCategorySoloAmbient` that live
# in Apple's AVFoundation framework. The plugin doesn't declare the
# framework in its podspec or Package.swift — it relies on Clang's
# `enable_modules` auto-link to emit the linker hint, which Bazel's
# apple_support deliberately suppresses with `-fno-autolink`. The
# Bazel-canonical answer for `objc_library` + Apple SDK framework is
# explicit `sdk_frameworks`, which rules_apple's own examples use
# uniformly. This overlay supplies it.
#
# Substitutions ({HUB_NAME}, {PKG}, {VERSION}) are injected by
# `flutter_pub_package`'s `_resolve_overlay_template`. The overlay sits
# under `0/`, so any 0.x audio_session version routes here.

load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")
load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")

flutter_plugin(
    name = "{PKG}",
    srcs = glob(
        ["lib/**/*.dart"],
        allow_empty = True,
    ),
    apple_libs = select({
        "@platforms//os:macos": [":{PKG}_apple_macos"],
        "@platforms//os:ios": [":{PKG}_apple_ios"],
        "//conditions:default": [],
    }),
    language_version = "3.4",
    package_name = "{PKG}",
    plugin_platforms_json = "{\"android\":{\"package\":\"com.ryanheise.audio_session\",\"pluginClass\":\"AudioSessionPlugin\"},\"ios\":{\"pluginClass\":\"AudioSessionPlugin\"},\"macos\":{\"pluginClass\":\"AudioSessionPlugin\"},\"web\":{\"fileName\":\"audio_session_web.dart\",\"pluginClass\":\"AudioSessionWeb\"}}",
    visibility = ["//visibility:public"],
    deps = [
        "@{HUB_NAME}__flutter//:flutter",
        "@{HUB_NAME}__flutter_web_plugins//:flutter_web_plugins",
        "@{HUB_NAME}__meta//:meta",
        "@{HUB_NAME}__rxdart//:rxdart",
    ],
)

flutter_apple_plugin_library(
    name = "{PKG}_apple_macos",
    srcs = glob(
        [
            "macos/{PKG}/Sources/{PKG}/**/*.swift",
            "macos/{PKG}/Sources/{PKG}/**/*.m",
            "macos/{PKG}/Sources/{PKG}/**/*.mm",
            "macos/{PKG}/Sources/{PKG}/**/*.h",
        ],
        allow_empty = True,
        exclude = [
            "macos/{PKG}/Sources/{PKG}/test/**",
            "macos/{PKG}/Sources/{PKG}/example/**",
        ],
    ),
    includes = [
        "macos/{PKG}/Sources/{PKG}/include",
        "macos/{PKG}/Sources/{PKG}/include/{PKG}",
    ],
    module_name = "{PKG}",
    platform = "macos",
    sdk_frameworks = ["AVFoundation"],
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "{PKG}_apple_ios",
    srcs = glob(
        [
            "ios/{PKG}/Sources/{PKG}/**/*.swift",
            "ios/{PKG}/Sources/{PKG}/**/*.m",
            "ios/{PKG}/Sources/{PKG}/**/*.mm",
            "ios/{PKG}/Sources/{PKG}/**/*.h",
        ],
        allow_empty = True,
        exclude = [
            "ios/{PKG}/Sources/{PKG}/test/**",
            "ios/{PKG}/Sources/{PKG}/example/**",
        ],
    ),
    includes = [
        "ios/{PKG}/Sources/{PKG}/include",
        "ios/{PKG}/Sources/{PKG}/include/{PKG}",
    ],
    module_name = "{PKG}",
    platform = "ios",
    sdk_frameworks = ["AVFoundation"],
    visibility = ["//visibility:public"],
)
