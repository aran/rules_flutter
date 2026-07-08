# Bazel-native overlay for `package:jni` 1.x — the C + Java support library
# every jnigen-based plugin (path_provider_android >= 2.3, and a growing set
# of flutter/packages plugins) depends on.
#
# Gradle builds the package's `src/CMakeLists.txt` with the NDK
# (externalNativeBuild) into `libdartjni.so`, which the plugin's Java side
# loads via `System.loadLibrary("dartjni")` in a static initializer. This
# overlay reproduces that build with `cc_library` + `cc_shared_library` and
# ships the result through `flutter_plugin.native_deps` — the same transitive
# native-libs pathway FFI plugin libraries travel — so the Android bundle
# packages it at `lib/<abi>/libdartjni.so` next to libapp.so.
#
# The Android Java side additionally compiles `java/src/main/java` (shared
# JNI support classes — PortContinuation, PortProxyBuilder, PortCleaner,
# JniUtils — which dartjni.c looks up via JNI at runtime); Gradle folds that
# directory in via `sourceSets { main { java { srcDirs '../java/...' } } }`.
# The `android/` sub-package overlay consumes it via :jni_java_support_srcs.
#
# Substitutions ({HUB_NAME}, {PKG}, {VERSION}) are injected by
# `flutter_pub_package`'s `_resolve_overlay_template`.

load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@rules_cc//cc:cc_shared_library.bzl", "cc_shared_library")
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")

flutter_plugin(
    name = "{PKG}",
    srcs = glob(
        ["lib/**/*.dart"],
        allow_empty = True,
    ),
    language_version = "3.3",
    native_deps = select({
        "@platforms//os:android": [":dartjni"],
        "//conditions:default": [],
    }),
    package_name = "{PKG}",
    plugin_platforms_json = "{\"android\":{\"ffiPlugin\":true,\"package\":\"com.github.dart_lang.jni\",\"pluginClass\":\"JniPlugin\"},\"linux\":{\"ffiPlugin\":true},\"windows\":{\"ffiPlugin\":true}}",
    visibility = ["//visibility:public"],
    deps = [
        "@{HUB_NAME}__args//:args",
        "@{HUB_NAME}__collection//:collection",
        "@{HUB_NAME}__ffi//:ffi",
        "@{HUB_NAME}__meta//:meta",
        "@{HUB_NAME}__package_config//:package_config",
        "@{HUB_NAME}__path//:path",
        "@{HUB_NAME}__plugin_platform_interface//:plugin_platform_interface",
    ],
)

# Shared Java support classes, consumed by the android/ sub-package's
# kt_android_library (a Bazel glob cannot cross the package boundary).
filegroup(
    name = "jni_java_support_srcs",
    srcs = glob(["java/src/main/java/**/*.java"]),
    visibility = ["//android:__pkg__"],
)

# Mirrors `add_library(jni SHARED ...)` in src/CMakeLists.txt: the same three
# sources, DART_SHARED_LIB (makes dart_api_dl.h export the DL-stub symbols
# from the shared object), liblog from the NDK sysroot, and 16 KB max page
# size (required to load on Android 15+ devices with 16 KB pages).
cc_library(
    name = "_dartjni_cc",
    srcs = [
        "src/dartjni.c",
        "src/include/dart_api_dl.c",
        "src/third_party/global_jni_env.c",
    ],
    hdrs = glob(["src/**/*.h"]),
    defines = ["DART_SHARED_LIB"],
)

cc_shared_library(
    name = "dartjni",
    # `System.loadLibrary("dartjni")` resolves exactly `libdartjni.so`.
    shared_lib_name = "libdartjni.so",
    user_link_flags = [
        "-llog",
        "-Wl,-z,max-page-size=16384",
    ],
    deps = [":_dartjni_cc"],
)
