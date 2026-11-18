# package:jni 1.x Android sub-package overlay.
#
# Mirrors what `make_android_subpackage_build_content` would auto-generate,
# plus the two things Gradle wires up that autogen cannot see:
#
#   * `//:jni_java_support_srcs` — the shared JNI support classes from
#     `java/src/main/java` (PortContinuation, PortProxyBuilder, PortCleaner,
#     JniUtils), folded in by the plugin's `sourceSets` srcDirs declaration.
#     dartjni.c resolves them via JNI at runtime, so they must be in the dex.
#   * kotlinx-coroutines-core — PortContinuation implements
#     `kotlin.coroutines.Continuation` and returns `Dispatchers.getIO()`.
#
# Placeholder substitution is performed by `_resolve_overlay_template`;
# this comment names none of them, because it rewrites comment text too.

load("@rules_flutter//flutter/private:generated_repos.bzl", "android_build_config")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load("@rules_kotlin//kotlin:core.bzl", "kt_kotlinc_options")

# BuildConfig for the plugin's namespace, which Gradle generates and compiles
# with the module's sources, and rules_android does not. DEBUG and
# BUILD_TYPE follow the build mode.
android_build_config(
    name = "_build_config",
    package = "com.github.dart_lang.jni",
)

# The Java level jni 1.x's Gradle build compiles at (its targetCompatibility).
kt_kotlinc_options(
    name = "_kotlinc_options",
    jvm_target = "11",
)

kt_android_library(
    name = "lib",
    srcs = glob(
        [
            "src/main/**/*.kt",
            "src/main/**/*.java",
        ],
        allow_empty = True,
    ) + ["//:jni_java_support_srcs", ":_build_config"],
    custom_package = "com.github.dart_lang.jni",
    exports_manifest = 1,
    manifest = "src/main/AndroidManifest.xml",
    proguard_specs = ["consumer-rules.pro"],
    kotlinc_opts = ":_kotlinc_options",
    visibility = ["//visibility:public"],
    deps = [
        "@rules_flutter//flutter/private/android:plugin_engine",
        "@rules_flutter_maven//:androidx_annotation_annotation",
        "@rules_flutter_maven//:androidx_lifecycle_lifecycle_common",
        "@rules_flutter_maven//:org_jetbrains_kotlin_kotlin_stdlib",
        "@rules_flutter_maven//:org_jetbrains_kotlinx_kotlinx_coroutines_core",
    ],
)
