# audio_session 0.1.x Android sub-package overlay.
#
# Mirrors what `make_android_subpackage_build_content` would auto-generate
# for a plugin with Android sources, with no audio_session-specific
# additions — but the top-level overlay short-circuits the auto-gen path,
# so we ship the sub-package alongside it. Placeholder substitution is
# performed by `_resolve_overlay_template`; this comment names none of
# them, because it rewrites comment text too.

load("@rules_flutter//flutter/private:android_build_config.bzl", "android_build_config")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load("@rules_kotlin//kotlin:core.bzl", "kt_kotlinc_options")

# BuildConfig for the plugin's namespace, which Gradle generates and compiles
# with the module's sources, and rules_android does not. DEBUG and
# BUILD_TYPE follow the build mode.
android_build_config(
    name = "_build_config",
    package = "com.ryanheise.audio_session",
)

# The Java level audio_session 0.1.x's Gradle build compiles at (its targetCompatibility).
kt_kotlinc_options(
    name = "_kotlinc_options",
    jvm_target = "1.8",
)

kt_android_library(
    name = "lib",
    srcs = glob(
        [
            "src/main/**/*.kt",
            "src/main/**/*.java",
        ],
        allow_empty = True,
    ) + [":_build_config"],
    custom_package = "com.ryanheise.audio_session",
    kotlinc_opts = ":_kotlinc_options",
    visibility = ["//visibility:public"],
    deps = [
        "@rules_flutter//flutter/private/android:plugin_engine",
        "@rules_flutter_maven//:androidx_annotation_annotation",
        "@rules_flutter_maven//:androidx_lifecycle_lifecycle_common",
        "@rules_flutter_maven//:androidx_media_media",
    ],
)
