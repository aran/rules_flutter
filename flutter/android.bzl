"""Flutter rules for Android builds.

Two tiers of API:

    Tier 1 — flutter_android_app (self-contained, recommended):

        load("@rules_flutter//flutter:android.bzl", "flutter_android_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_android_app(
            name = "my_app_android",
            application = ":my_app",
            package_name = "com.example.myapp",
        )

    Prerequisites: run `flutter create --platforms=android .` in your package to
    generate the conventional `android/app/src/main/` directory with
    AndroidManifest.xml, resources, and Kotlin sources. The macro handles everything
    automatically — no edits to the flutter create output needed.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:android.bzl",
            "ANDROID_MIN_SDK_VERSION",
            "ANDROID_TARGET_SDK_VERSION",
            "flutter_android_bundle",
            "flutter_android_engine",
            "flutter_android_manifest_gen",
            "flutter_android_runner_lib_gen")

        flutter_android_bundle(name = "my_bundle", application = ":my_app")
        flutter_android_engine(name = "my_engine")
        flutter_android_manifest_gen(name = "my_manifest", package_name = "com.example.myapp")

        flutter_android_runner_lib_gen(
            name = "my_runner",
            package_name = "com.example.myapp",
            engine = ":my_engine",
        )

        android_binary(
            name = "my_apk",
            manifest = ":my_manifest",
            deps = [":my_bundle_native_libs", ":my_engine", ":my_runner"],
        )
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_android//android:rules.bzl", _android_binary = "android_binary")
load("@rules_java//java:java_import.bzl", _java_import = "java_import")
load("@rules_kotlin//kotlin:android.bzl", _kt_android_library = "kt_android_library")
load("//flutter/private:constants.bzl", _ANDROID_MIN_SDK_VERSION = "ANDROID_MIN_SDK_VERSION", _ANDROID_TARGET_SDK_VERSION = "ANDROID_TARGET_SDK_VERSION")
load("//flutter/private:flutter_android_application.bzl", _flutter_android_bundle = "flutter_android_bundle")
load("//flutter/private:flutter_android_plugin_library.bzl", _flutter_android_plugin_library = "flutter_android_plugin_library")
load("//flutter/private:flutter_android_registrant.bzl", _flutter_android_registrant = "flutter_android_registrant")

# Re-export constants for user BUILD files.
ANDROID_MIN_SDK_VERSION = _ANDROID_MIN_SDK_VERSION
ANDROID_TARGET_SDK_VERSION = _ANDROID_TARGET_SDK_VERSION

# AndroidX deps needed to compile Flutter runner Kotlin sources.
_ANDROIDX_COMPILE_DEPS = [
    "@rules_android_maven//:androidx_annotation_annotation",
    "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
]

# AndroidX deps that flutter.jar needs at runtime, mirroring the dependency
# list of Flutter's official io.flutter:flutter_embedding_* Maven POM (the
# deps every Gradle-built Flutter app ships): lifecycle for FlutterActivity's
# LifecycleRegistry, window/window-java for foldable display features, core
# for ContextCompat/ViewCompat/input, tracing for the engine's TraceSection,
# fragment for FlutterFragment(Activity), exifinterface for image decoding,
# and relinker for engine .so loading. The POM's lifecycle-common-java8 and
# lifecycle-process entries are omitted: at the lifecycle version pinned here
# their classes live in lifecycle-common, and the embedding never references
# lifecycle-process types.
_ANDROIDX_ENGINE_DEPS = [
    "@rules_android_maven//:androidx_annotation_annotation",
    "@rules_android_maven//:androidx_core_core",
    "@rules_android_maven//:androidx_exifinterface_exifinterface",
    "@rules_android_maven//:androidx_fragment_fragment",
    "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
    "@rules_android_maven//:androidx_lifecycle_lifecycle_runtime",
    "@rules_android_maven//:androidx_tracing_tracing",
    "@rules_android_maven//:androidx_window_window",
    "@rules_android_maven//:androidx_window_window_java",
    "@rules_android_maven//:com_getkeepsafe_relinker_relinker",
]

# -- Composable rules (Tier 2) ------------------------------------------------

flutter_android_bundle = _flutter_android_bundle

# Public wrapper that compiles a Flutter plugin's Android Kotlin/Java sources
# into a kt_android_library. For pub.dev plugins, flutter_pub_package emits
# this automatically; expose it here so users can wire a monorepo plugin's
# BUILD.bazel without going through the ext/ overlay system.
flutter_android_plugin_library = _flutter_android_plugin_library

# Registrant rule that emits GeneratedPluginRegistrant.java from a
# flutter_application's transitive FlutterInfo. Wired automatically by
# flutter_android_app; expose for Tier-2 control.
flutter_android_registrant = _flutter_android_registrant

def flutter_android_engine(name, android_abi = "arm64", **kwargs):
    """Imports the Flutter engine (flutter.jar) as a java_import target.

    Auto-selects debug or release engine based on Bazel compilation mode:
    - Debug (-c dbg): JIT engine for emulator/iterative development.
    - Release (-c opt / default): AOT engine for production.

    Args:
        name: Target name. Add to android_binary deps.
        android_abi: Engine ABI — "arm64" (default) or "x64".
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    # Map short ABI names to repo names.
    abi_to_repo = {
        "arm64": "flutter_android_engine_arm64",
        "x64": "flutter_android_engine_x64",
    }
    repo = abi_to_repo.get(android_abi)
    if not repo:
        fail("Unsupported android_abi '%s'. Use arm64 or x64." % android_abi)

    _java_import(
        name = name,
        jars = select({
            "@rules_flutter//flutter/private:dbg": ["@%s//:debug/flutter.jar" % repo],
            "//conditions:default": ["@%s//:flutter.jar" % repo],
        }),
        tags = tags,
        deps = _ANDROIDX_ENGINE_DEPS,
        **kwargs
    )

def flutter_android_manifest_gen(
        name,
        package_name,
        app_name = None,
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        **kwargs):
    """Generates an AndroidManifest.xml from the default Bazel template.

    The template uses FlutterActivity as the main activity with embedding v2.

    Args:
        name: Target name. Pass to android_binary manifest.
        package_name: Android package name (e.g. "com.example.myapp").
        app_name: Display name for the app. Defaults to package_name.
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])
    display_name = app_name or package_name

    expand_template(
        name = name,
        template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
        out = name + "/AndroidManifest.xml",
        substitutions = {
            "PACKAGE_NAME": package_name,
            "APP_NAME": display_name,
            "MIN_SDK_VERSION": min_sdk_version,
            "TARGET_SDK_VERSION": target_sdk_version,
        },
        tags = tags,
        **kwargs
    )

def flutter_android_runner_lib_gen(
        name,
        package_name,
        engine,
        manifest = None,
        **kwargs):
    """Generates a kt_android_library with a default Flutter runner Activity.

    Uses template MainActivity.kt from rules_flutter. This provides a
    custom Activity subclass for users who don't have `flutter create`
    output but want a named Activity class (e.g. for deep links or
    intent filters).

    For most apps, FlutterActivity can be used directly in the manifest
    without a custom runner — see flutter_android_manifest_gen.

    Args:
        name: Target name. Add to android_binary deps.
        package_name: Android package name (e.g. "com.example.myapp").
            Used for template substitution in MainActivity.kt.
        engine: A flutter_android_engine target (flutter.jar).
        manifest: AndroidManifest.xml for the library. If not provided,
            a minimal one is generated.
        **kwargs: Additional arguments passed to kt_android_library.
    """
    tags = kwargs.pop("tags", ["manual"])

    # Generate the MainActivity.kt with the correct package name.
    expand_template(
        name = "__%s_main_activity" % name,
        template = "@rules_flutter//flutter/private/runners/android:MainActivity.kt",
        out = "__%s_runner/MainActivity.kt" % name,
        substitutions = {
            "PACKAGE_NAME": package_name,
        },
        tags = tags,
    )

    # Generate a minimal manifest for android_library if not provided.
    actual_manifest = manifest
    if not actual_manifest:
        expand_template(
            name = "__%s_lib_manifest" % name,
            template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
            out = "__%s_lib_manifest/AndroidManifest.xml" % name,
            substitutions = {
                "PACKAGE_NAME": package_name,
                "APP_NAME": package_name,
                "MIN_SDK_VERSION": ANDROID_MIN_SDK_VERSION,
                "TARGET_SDK_VERSION": ANDROID_TARGET_SDK_VERSION,
            },
            tags = tags,
        )
        actual_manifest = "__%s_lib_manifest" % name

    _kt_android_library(
        name = name,
        srcs = ["__%s_main_activity" % name],
        manifest = actual_manifest,
        tags = tags,
        deps = [engine] + _ANDROIDX_COMPILE_DEPS,
        **kwargs
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_android_app(
        name,
        application,
        package_name,
        app_name = None,
        android_abi = "arm64",
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        manifest = None,
        resources = [],
        deps = [],
        pub_hub_name = "deps",
        **kwargs):
    """Builds a Flutter Android APK from a flutter_application target.

    Discovers runner files from the conventional `android/app/src/main/`
    directory (as generated by `flutter create --platforms=android .`) and
    wires up all internal targets automatically.

    Three modes:
      1. manifest provided → uses it directly, no auto-discovery.
      2. android/app/src/main/AndroidManifest.xml found → uses flutter create
         manifest (preprocessed for Gradle variables), discovers resources
         and Kotlin sources from android/app/src/main/.
      3. No manifest found → generates manifest from template.

    When Kotlin sources are found in android/app/src/main/kotlin/, they are
    compiled via kt_android_library with the Flutter engine and AndroidX deps.

    Plugin auto-wiring:
      - Generates a `flutter_android_registrant` target whose application is
        `application`, then compiles the resulting Java into a private
        `kt_android_library` that goes into `binary_deps`. Every plugin
        whose `flutter.plugin.platforms.android.pluginClass` is set ends up
        registered with the FlutterEngine on startup — no manual wiring.
      - Adds `@<pub_hub_name>//android:all_android_plugin_libs` to
        `binary_deps`, pulling in every transitively-resolved plugin
        spoke's Kotlin/Java sources via the hub's aggregator. Spokes
        without Android sources contribute empty libraries (no-op).

    Args:
        name: Target name (Bazel identifier). Produces an android_binary.
        application: A flutter_application target (required).
        package_name: Android package name, e.g. "com.example.myapp" (required).
        app_name: User-facing display name. Defaults to name.
        android_abi: Target ABI — "arm64" (default) or "x64". Selects the
            engine and the Android platform the application is built for.
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version.
        manifest: Override AndroidManifest.xml. If not set, auto-discovered
            from android/app/src/main/ or generated from template.
        resources: Extra resource_files for android_binary.
        deps: Extra deps for android_binary (e.g. custom android_library).
        pub_hub_name: Name of the `flutter.pub(name = ...)` hub providing
            plugin spokes. The macro depends on
            `@<pub_hub_name>//android:all_android_plugin_libs` to compile
            all plugin Kotlin/Java automatically. Defaults to `"deps"`,
            matching the convention in repo MODULE.bazel files. Set to
            `None` to opt out (e.g. for a workspace with no pub plugins).
        **kwargs: Passed through to android_binary.
    """
    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])

    # -- Internal targets (all __{name}_ prefixed) --

    # 1. Bundle Flutter outputs (native_libs.jar + flutter_assets).
    _flutter_android_bundle(
        name = "__%s_bundle" % name,
        application = application,
        android_abi = _short_abi_to_full(android_abi),
        tags = tags,
    )

    # 2. Extract native_libs.jar from the bundle.
    native.filegroup(
        name = "__%s_native_libs_jar" % name,
        srcs = ["__%s_bundle" % name],
        output_group = "native_libs_jar",
        tags = tags,
    )

    # 3. Wrap native_libs.jar as java_import.
    _java_import(
        name = "__%s_native_libs" % name,
        jars = ["__%s_native_libs_jar" % name],
        tags = tags,
    )

    # 4. Import Flutter engine.
    flutter_android_engine(
        name = "__%s_engine" % name,
        android_abi = android_abi,
        tags = tags,
    )

    # 5. Extract flutter_assets for inclusion in the APK.
    # The mobile_install output group has assets at assets/flutter_assets/.
    native.filegroup(
        name = "__%s_flutter_assets" % name,
        srcs = ["__%s_bundle" % name],
        output_group = "mobile_install",
        tags = tags,
    )

    # 6. Auto-wire the plugin registrant. Generates
    # `GeneratedPluginRegistrant.java` from the flutter_application's
    # transitive FlutterInfo plugin metadata, then wraps it in a
    # kt_android_library so the registrant class is on the runtime
    # classpath (called from the runner's MainActivity / FlutterActivity).
    #
    # The registrant references each plugin's `PluginClass` by fully
    # qualified name, so its compile classpath must include every
    # plugin's `kt_android_library`. We add the hub aggregator so the
    # plugin classes resolve at javac time too.
    _flutter_android_registrant(
        name = "__%s_registrant_src" % name,
        application = application,
        tags = tags,
    )

    registrant_deps = ["__%s_engine" % name] + _ANDROIDX_COMPILE_DEPS
    if pub_hub_name:
        registrant_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)

    _kt_android_library(
        name = "__%s_registrant" % name,
        srcs = ["__%s_registrant_src" % name],
        custom_package = "io.flutter.plugins",
        tags = tags,
        deps = registrant_deps,
    )

    # 7. Resolve manifest, resources, and Kotlin sources.
    actual_manifest = manifest
    binary_deps = [
        "__%s_native_libs" % name,
        "__%s_engine" % name,
        "__%s_registrant" % name,
    ]

    # 8. Plugin auto-wiring: compile every transitively-needed plugin's
    # Kotlin/Java via the hub's aggregator. Each spoke unconditionally
    # exposes `android:lib`; the hub's `all_android_plugin_libs` deps on
    # all of them. Spokes without Android sources contribute empty
    # libraries — no-op at link time, mechanical at the macro layer.
    if pub_hub_name:
        binary_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)

    if not actual_manifest:
        # Try to discover flutter create output.
        discovered_manifests = native.glob(["android/app/src/main/AndroidManifest.xml"])
        if discovered_manifests:
            # Flutter create case — preprocess manifest for Gradle variables.
            # Same pattern as flutter_ios_app preprocessing Info.plist for Xcode
            # variables (ios.bzl).
            expand_template(
                name = "__%s_manifest" % name,
                template = discovered_manifests[0],
                out = "__%s_AndroidManifest.xml" % name,
                substitutions = {
                    "${applicationName}": "android.app.Application",
                },
                tags = tags,
            )
            actual_manifest = "__%s_manifest" % name

            # Discover resources from flutter create output.
            discovered_resources = native.glob(["android/app/src/main/res/**"])
            resources = list(resources) + discovered_resources

            # Discover and compile Kotlin sources from flutter create output.
            discovered_kotlin = native.glob(["android/app/src/main/kotlin/**/*.kt"])
            if discovered_kotlin:
                _kt_android_library(
                    name = "__%s_runner" % name,
                    srcs = discovered_kotlin,
                    custom_package = package_name,
                    tags = tags,
                    deps = ["__%s_engine" % name] + _ANDROIDX_COMPILE_DEPS,
                )
                binary_deps.append("__%s_runner" % name)
        else:
            # No flutter create output — generate manifest from template.
            flutter_android_manifest_gen(
                name = "__%s_manifest" % name,
                package_name = package_name,
                app_name = display_name,
                min_sdk_version = min_sdk_version,
                target_sdk_version = target_sdk_version,
                tags = tags,
            )
            actual_manifest = "__%s_manifest" % name

    # 9. Final android_binary.
    _android_binary(
        name = name,
        manifest = actual_manifest,
        manifest_values = {
            "applicationId": package_name,
            "minSdkVersion": min_sdk_version,
            "targetSdkVersion": target_sdk_version,
        },
        resource_files = resources if resources else None,
        assets = ["__%s_flutter_assets" % name],
        assets_dir = "assets",
        deps = binary_deps + deps,
        tags = tags,
        **kwargs
    )

def _short_abi_to_full(abi):
    """Convert short ABI name to full ABI string for flutter_android_bundle."""
    mapping = {
        "arm64": "arm64-v8a",
        "x64": "x86_64",
    }
    if abi not in mapping:
        fail("Unsupported android_abi '%s'. Use arm64 or x64." % abi)
    return mapping[abi]
