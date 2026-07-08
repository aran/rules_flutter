# package:jni 1.x Android sub-package overlay.
#
# Mirrors what `_make_android_subpackage_build_content` would auto-generate,
# plus the two things Gradle wires up that autogen cannot see:
#
#   * `//:jni_java_support_srcs` — the shared JNI support classes from
#     `java/src/main/java` (PortContinuation, PortProxyBuilder, PortCleaner,
#     JniUtils), folded in by the plugin's `sourceSets` srcDirs declaration.
#     dartjni.c resolves them via JNI at runtime, so they must be in the dex.
#   * kotlinx-coroutines-core — PortContinuation implements
#     `kotlin.coroutines.Continuation` and returns `Dispatchers.getIO()`.
#
# {HUB_NAME} / {PKG} / {VERSION} substitution is performed by
# `_resolve_overlay_template`.

load("@rules_flutter//flutter:android.bzl", "flutter_android_engine")
load("@rules_java//java:java_library.bzl", "java_library")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

# Private engine target — gives the plugin's Java the FlutterPlugin SPI
# on the compile classpath. Always arm64 here; Java bytecode is
# ABI-independent. The consumer's flutter_android_app(android_abi=...)
# decides the runtime ABI.
flutter_android_engine(
    name = "_engine",
    visibility = ["//visibility:private"],
)

# BuildConfig.java stub. Gradle synthesizes this per Android module
# (matching `android.namespace`). rules_android doesn't, so we generate
# a minimal one — `DEBUG = false`, which is correct for release builds
# and harmless for debug (the engine ABI / mode is decided elsewhere).
genrule(
    name = "_build_config_src",
    outs = ["_build_config/com/github/dart_lang/jni/BuildConfig.java"],
    cmd = "cat > $@ <<'EOF'\npackage com.github.dart_lang.jni;\npublic final class BuildConfig {\n  public static final boolean DEBUG = false;\n  public static final String LIBRARY_PACKAGE_NAME = \"com.github.dart_lang.jni\";\n  public static final String BUILD_TYPE = \"release\";\n}\nEOF\n",
)

java_library(
    name = "_build_config",
    srcs = [":_build_config_src"],
    visibility = ["//visibility:private"],
)

kt_android_library(
    name = "lib",
    srcs = glob(
        [
            "src/main/**/*.kt",
            "src/main/**/*.java",
        ],
        allow_empty = True,
    ) + ["//:jni_java_support_srcs"],
    custom_package = "com.github.dart_lang.jni",
    exports_manifest = 1,
    manifest = "src/main/AndroidManifest.xml",
    proguard_specs = ["consumer-rules.pro"],
    visibility = ["//visibility:public"],
    deps = [
        ":_build_config",
        ":_engine",
        "@rules_android_maven//:androidx_annotation_annotation",
        "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
        "@rules_android_maven//:org_jetbrains_kotlin_kotlin_stdlib",
        "@rules_android_maven//:org_jetbrains_kotlinx_kotlinx_coroutines_core",
    ],
)
