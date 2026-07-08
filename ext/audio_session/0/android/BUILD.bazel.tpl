# audio_session 0.1.x Android sub-package overlay.
#
# Mirrors what `make_android_subpackage_build_content` would auto-generate
# for a plugin with Android sources, with no audio_session-specific
# additions — but the top-level overlay short-circuits the auto-gen path,
# so we ship the sub-package alongside it. {HUB_NAME} / {PKG} / {VERSION}
# substitution is performed by `_resolve_overlay_template`.

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
    outs = ["_build_config/com/ryanheise/audio_session/BuildConfig.java"],
    cmd = "cat > $@ <<'EOF'\npackage com.ryanheise.audio_session;\npublic final class BuildConfig {\n  public static final boolean DEBUG = false;\n  public static final String LIBRARY_PACKAGE_NAME = \"com.ryanheise.audio_session\";\n  public static final String BUILD_TYPE = \"release\";\n}\nEOF\n",
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
    ),
    custom_package = "com.ryanheise.audio_session",
    visibility = ["//visibility:public"],
    deps = [
        ":_engine",
        ":_build_config",
        "@rules_android_maven//:androidx_annotation_annotation",
        "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
        "@rules_android_maven//:androidx_media_media",
    ],
)
