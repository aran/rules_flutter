"""Flutter rules for iOS builds.

Two tiers of API:

    Tier 1 — flutter_ios_app (self-contained, recommended):

        load("@rules_flutter//flutter:ios.bzl", "flutter_ios_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_ios_app(
            name = "my_app_ios",
            application = ":my_app",
            bundle_id = "com.example.myapp",
        )

    Prerequisites: run `flutter create --platforms=ios .` in your package to
    generate the conventional `ios/Runner/` directory with AppDelegate.swift
    and SceneDelegate.swift.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:ios.bzl",
            "IOS_DEFAULT_LAUNCH_STORYBOARD",
            "flutter_ios_engine",
            "flutter_ios_framework_gen",
            "flutter_ios_info_plist_gen",
            "flutter_ios_registrant_gen",
            "flutter_ios_runner_lib_gen")

        flutter_ios_framework_gen(name = "my_framework", application = ":my_app")
        flutter_ios_registrant_gen(name = "my_registrant", application = ":my_app")
        flutter_ios_engine(name = "my_engine")
        flutter_ios_info_plist_gen(name = "my_info_plist", app_name = "My App")

        flutter_ios_runner_lib_gen(
            name = "my_runner",
            registrant = ":my_registrant",
            engine = ":my_engine",
        )

        ios_application(
            name = "my_ios_app",
            bundle_id = "com.example.myapp",
            infoplists = [":my_info_plist"],
            launch_storyboard = IOS_DEFAULT_LAUNCH_STORYBOARD,
            deps = [":my_framework", ":my_runner"],
        )
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import")
load("@rules_apple//apple:ios.bzl", "ios_application")
load("@rules_apple//apple:versioning.bzl", "apple_bundle_version")
load("@rules_swift//swift:swift.bzl", "swift_library")
load("//flutter/private:constants.bzl", _IOS_MINIMUM_OS_VERSION = "IOS_MINIMUM_OS_VERSION")
load("//flutter/private:flutter_apple_plugin_library.bzl", _flutter_apple_plugin_library_macro = "flutter_apple_plugin_library")
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load("//flutter/private:flutter_ios_application.bzl", _flutter_ios_application = "flutter_ios_application", _flutter_ios_framework_rule = "flutter_ios_framework", _flutter_ios_native_frameworks_rule = "flutter_ios_native_frameworks", _flutter_ios_privacy_manifests_rule = "flutter_ios_privacy_manifests")
load("//flutter/private:flutter_ios_registrant.bzl", _flutter_ios_registrant_rule = "flutter_ios_registrant")

# Re-export constants for user BUILD files.
IOS_MINIMUM_OS_VERSION = _IOS_MINIMUM_OS_VERSION
IOS_DEFAULT_LAUNCH_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/LaunchScreen.storyboard"
IOS_DEFAULT_MAIN_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/Main.storyboard"

def _engine_xcframework_select():
    """Selects the Flutter.xcframework engine for the active compilation mode.

    Debug (-c dbg): JIT engine (simulator). Release (-c opt / default): AOT
    engine (device). Both live in the single `@flutter_ios_engine` repo, so a
    consumer only needs that one repo in `use_repo`.
    """
    return select({
        "@rules_flutter//flutter/private:dbg": ["@flutter_ios_engine//:Flutter_xcframework_debug"],
        "//conditions:default": ["@flutter_ios_engine//:Flutter_xcframework"],
    })

# -- Composable rules (Tier 2) ------------------------------------------------
#
# Like every other *_gen macro in this file, these default to
# `tags = ["manual"]`: the targets are only meaningful as deps of an
# `ios_application` (whose split transition puts them in an iOS
# configuration). Built standalone by a `//...` pattern they'd run in the
# host configuration — wrapping the wrong platform's dylibs and invoking
# Apple-only tools (`xcrun`), which fails outright on non-macOS hosts.

def flutter_ios_registrant_gen(name, **kwargs):
    """Generates the iOS GeneratedPluginRegistrant. See `flutter_ios_registrant`.

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `ios_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_ios_registrant_rule(name = name, tags = tags, **kwargs)

def flutter_ios_native_frameworks_gen(name, **kwargs):
    """Wraps native dylibs in signed .frameworks. See `flutter_ios_native_frameworks`.

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `ios_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_ios_native_frameworks_rule(name = name, tags = tags, **kwargs)

def flutter_ios_privacy_manifests_gen(name, **kwargs):
    """Exposes plugin privacy manifests. See `flutter_ios_privacy_manifests`.

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `ios_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_ios_privacy_manifests_rule(name = name, tags = tags, **kwargs)

# Public wrapper that compiles a Flutter plugin's iOS Apple sources into a
# swift_library. Use directly to wire a monorepo plugin's BUILD.bazel without
# going through the ext/ overlay system; for pub.dev plugins, flutter_pub_package
# emits this automatically.
flutter_apple_plugin_library = _flutter_apple_plugin_library_macro

# Aggregates per-plugin Apple swift_libraries from a flutter_application's
# transitive dep graph. Pass to runner_lib_gen `application` to thread plugin
# Swift modules + link inputs into the runner.
flutter_apple_plugins_aggregator = _flutter_apple_plugins_aggregator

def flutter_ios_framework_gen(name, application, minimum_os_version = IOS_MINIMUM_OS_VERSION, **kwargs):
    """Generates App.framework and wraps it as apple_dynamic_framework_import.

    Chains: flutter_application → intermediates → framework assembly → import.
    The resulting target can be added to ios_application deps directly.

    In debug mode (-c dbg), bundle_only=True embeds the framework without
    linking (stub binary for rules_apple compatibility, not loaded at runtime).

    Args:
        name: Target name. Add to ios_application deps.
        application: A flutter_application target.
        minimum_os_version: Minimum iOS deployment target.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    _flutter_ios_application(
        name = "__%s_intermediates" % name,
        application = application,
        tags = tags,
    )

    _flutter_ios_framework_rule(
        name = "__%s_framework" % name,
        application = "__%s_intermediates" % name,
        minimum_os_version = minimum_os_version,
        tags = tags,
    )

    apple_dynamic_framework_import(
        name = name,
        framework_imports = ["__%s_framework" % name],
        bundle_only = select({
            "@rules_flutter//flutter/private:dbg": True,
            "//conditions:default": False,
        }),
        tags = tags,
        **kwargs
    )

def flutter_ios_engine(name, **kwargs):
    """Imports the Flutter.xcframework engine, auto-selecting debug or release.

    Debug mode (-c dbg): JIT engine for simulator.
    Release mode (-c opt / default): AOT engine for device.

    Args:
        name: Target name. Add to swift_library deps for runner.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    apple_dynamic_xcframework_import(
        name = name,
        xcframework_imports = _engine_xcframework_select(),
        tags = tags,
        **kwargs
    )

def flutter_ios_info_plist_gen(name, app_name, module_name = "Runner", **kwargs):
    """Generates an iOS Info.plist from the default Bazel template.

    The template includes UIApplicationSceneManifest pointing to
    MODULE_NAME.SceneDelegate for scene-based lifecycle.

    The output is a filegroup that includes the generated plist plus
    NSBonjourServices for debug/profile builds (required for mDNS
    VM service registration). Pass this target to ios_application
    infoplists.

    Args:
        name: Target name. Pass to ios_application infoplists.
        app_name: Display name (CFBundleDisplayName, CFBundleName).
        module_name: Swift module name for SceneDelegate lookup.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])
    visibility = kwargs.pop("visibility", None)

    expand_template(
        name = "__%s_plist" % name,
        template = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        out = name + "/Info.plist",
        substitutions = {
            "APP_NAME": app_name,
            "MODULE_NAME": module_name,
        },
        tags = tags,
        **kwargs
    )

    native.filegroup(
        name = name,
        srcs = ["__%s_plist" % name] + select({
            "@rules_flutter//flutter:release": [],
            "//conditions:default": [
                "@rules_flutter//flutter/private/runners/ios:DartVmServiceMdns.plist",
            ],
        }),
        tags = tags,
        visibility = visibility,
    )

def flutter_ios_runner_lib_gen(name, registrant, engine, application = None, module_name = "Runner", **kwargs):
    """Generates a swift_library for the default iOS runner.

    Uses template AppDelegate.swift and SceneDelegate.swift from rules_flutter.
    This replaces `flutter create --platforms=ios` output for users who
    don't need custom runner files.

    When `application` is set, an internal flutter_apple_plugins_aggregator
    target is created and added to the runner's `swift_library.deps` so the
    generated registrant's `import <PluginModule>` lines resolve and the
    linker pulls in each transitive plugin's static archive.

    Args:
        name: Target name. Add to ios_application deps.
        registrant: A flutter_ios_registrant_gen target (Swift source).
        engine: A flutter_ios_engine target (Flutter.xcframework).
        application: A flutter_application target. Required to wire pub
            plugins' iOS Swift modules + link inputs into the runner;
            optional only for legacy Tier-2 setups with no native plugins.
        module_name: Swift module name (default "Runner").
        **kwargs: Additional arguments passed to swift_library.
    """
    tags = kwargs.pop("tags", ["manual"])

    deps = [engine]
    if application:
        aggregator_name = "_%s__apple_plugins_aggregator" % name
        _flutter_apple_plugins_aggregator(
            name = aggregator_name,
            application = application,
            platform = "ios",
            tags = tags,
            visibility = ["//visibility:private"],
        )
        deps.append(":" + aggregator_name)

    swift_library(
        name = name,
        srcs = [
            registrant,
            "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
        ],
        data = [
            "@rules_flutter//flutter/private/runners/ios:Base.lproj/Main.storyboard",
        ],
        module_name = module_name,
        tags = tags,
        deps = deps,
        **kwargs
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_ios_app(
        name,
        application,
        bundle_id,
        families = ["iphone"],
        app_name = None,
        minimum_os_version = IOS_MINIMUM_OS_VERSION,
        info_plist = None,
        version = None,
        launch_storyboard = None,
        entitlements = None,
        resources = [],
        **kwargs):
    """Builds a Flutter iOS .app bundle from a flutter_application target.

    Discovers runner files from the conventional `ios/Runner/` directory
    (as generated by `flutter create --platforms=ios .`) and wires up all
    internal targets automatically.

    Prerequisites — the package must contain:
        - `ios/Runner/*.swift` (AppDelegate, SceneDelegate, etc.)
    Generate these with: `flutter create --platforms=ios .`

    Args:
        name: Target name (Bazel identifier).
        application: A flutter_application target (required).
        bundle_id: CFBundleIdentifier (required — rules_apple constraint).
        families: Device families (default ["iphone"]).
        app_name: User-facing display name. Defaults to name.
        minimum_os_version: Minimum iOS version.
        info_plist: Override conventional ios/Runner/Info.plist.
        version: An apple_bundle_version target. Defaults to "1.0".
        launch_storyboard: Override launch storyboard. Defaults to
            ios/Runner/Base.lproj/LaunchScreen.storyboard.
        entitlements: Override entitlements wiring. By default the macro
            auto-discovers `ios/Runner/Runner.entitlements` and forwards
            it to `ios_application`. Unlike macOS (where flutter create
            always emits the entitlements files), iOS only ships
            Runner.entitlements when capabilities are enabled in Xcode;
            its absence is a valid, capability-less app and the macro
            ships nothing rather than synthesizing a default.
        resources: Extra resources.
        **kwargs: Passed through to ios_application.
    """
    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])

    # target_compatible_with doesn't work on ios_application (it transitions to
    # iOS platform, so macOS constraints would fail). Users should put
    # target_compatible_with on build_test instead.
    kwargs.pop("target_compatible_with", None)

    # Auto-discover ios/Runner/Runner.entitlements if the user hasn't
    # passed one. Its absence is convention-matching (no-capabilities
    # apps don't have an entitlements file); rules_apple's signing
    # pipeline still injects `get-task-allow=true` for debug builds.
    if entitlements == None:
        runner_entitlements = native.glob(
            ["ios/Runner/Runner.entitlements"],
            allow_empty = True,
        )
        if runner_entitlements:
            entitlements = "ios/Runner/Runner.entitlements"

    # -- Internal targets (all __{name}_ prefixed) --

    # 1. Generate iOS Swift plugin registrant.
    _flutter_ios_registrant_rule(
        name = "__%s_registrant" % name,
        application = application,
        tags = tags,
    )

    # 2. Extract intermediates (AOT dylib + flutter_assets + native_libs).
    _flutter_ios_application(
        name = "__%s_intermediates" % name,
        application = application,
        tags = tags,
    )

    # 3. Assemble App.framework from the AOT dylib.
    _flutter_ios_framework_rule(
        name = "__%s_app_framework" % name,
        application = "__%s_intermediates" % name,
        minimum_os_version = minimum_os_version,
        tags = tags,
    )

    # 4. Wrap App.framework as dynamic framework import.
    # Debug: bundle_only=True embeds framework without linking (no binary).
    apple_dynamic_framework_import(
        name = "__%s_app_bundle" % name,
        framework_imports = ["__%s_app_framework" % name],
        bundle_only = select({
            "@rules_flutter//flutter/private:dbg": True,
            "//conditions:default": False,
        }),
        tags = tags,
    )

    # 5. Import Flutter.xcframework engine — auto-selects debug/release.
    apple_dynamic_xcframework_import(
        name = "__%s_engine" % name,
        xcframework_imports = _engine_xcframework_select(),
        tags = tags,
    )

    # 6. Wrap native plugin/native-asset dylibs in signed .frameworks for bundling.
    _flutter_ios_native_frameworks_rule(
        name = "__%s_native_frameworks" % name,
        application = application,
        minimum_os_version = minimum_os_version,
        tags = tags,
    )

    # 6b. Expose plugin PrivacyInfo.xcprivacy files for bundling.
    _flutter_ios_privacy_manifests_rule(
        name = "__%s_privacy_manifests" % name,
        application = application,
        tags = tags,
    )

    # 7. Discover runner Swift sources and build swift_library.
    runner_srcs = native.glob(["ios/Runner/*.swift"])
    if not runner_srcs:
        fail("No Swift sources found in ios/Runner/. " +
             "Run 'flutter create --platforms=ios .' to generate runner files.")

    # 7a. Aggregate Apple plugin libraries from the application's transitive
    # FlutterInfo so the runner's swift_library imports + links each pub
    # plugin's Swift module.
    _flutter_apple_plugins_aggregator(
        name = "__%s_apple_plugins" % name,
        application = application,
        platform = "ios",
        tags = tags,
    )

    swift_library(
        name = "__%s_runner" % name,
        srcs = runner_srcs + ["__%s_registrant" % name],
        data = native.glob(["ios/Runner/Base.lproj/Main.storyboard"]),
        module_name = "Runner",
        tags = tags,
        deps = [
            "__%s_engine" % name,
            "__%s_apple_plugins" % name,
        ],
    )

    # 8. Info.plist — preprocess to resolve Xcode variables that rules_apple
    #    doesn't handle.
    if not info_plist:
        expand_template(
            name = "__%s_info_plist" % name,
            template = "ios/Runner/Info.plist",
            out = "__%s_Info.plist" % name,
            substitutions = {
                "$(DEVELOPMENT_LANGUAGE)": "en",
                "$(PRODUCT_MODULE_NAME)": "Runner",
                "$(FLUTTER_BUILD_NAME)": "1.0",
                "$(FLUTTER_BUILD_NUMBER)": "1",
            },
            tags = tags,
        )
        actual_info_plist = "__%s_info_plist" % name
    else:
        actual_info_plist = info_plist

    # 9. Version — create default apple_bundle_version if not provided.
    if not version:
        apple_bundle_version(
            name = "__%s_version" % name,
            build_version = "1.0",
            short_version_string = "1.0",
            tags = tags,
        )
        version = ":%s" % ("__%s_version" % name)

    # 10. Resolve launch storyboard.
    actual_launch_storyboard = launch_storyboard
    if not actual_launch_storyboard:
        launch_candidates = native.glob(["ios/Runner/Base.lproj/LaunchScreen.storyboard"])
        if launch_candidates:
            actual_launch_storyboard = launch_candidates[0]
        else:
            actual_launch_storyboard = IOS_DEFAULT_LAUNCH_STORYBOARD

    # 11. Final ios_application.
    # Include supplementary plist for NSBonjourServices in debug/profile builds —
    # required for the Flutter engine to register the Dart VM service via mDNS.
    # Matches flutter_tools xcode_backend.dart which only adds this for non-release.
    ios_application(
        name = name,
        bundle_id = bundle_id,
        bundle_name = display_name,
        entitlements = entitlements,
        families = families,
        minimum_os_version = minimum_os_version,
        infoplists = [actual_info_plist] + select({
            "@rules_flutter//flutter:release": [],
            "//conditions:default": [
                "@rules_flutter//flutter/private/runners/ios:DartVmServiceMdns.plist",
            ],
        }),
        version = version,
        launch_storyboard = actual_launch_storyboard,
        resources = resources + ["__%s_privacy_manifests" % name],
        deps = [
            "__%s_runner" % name,
            "__%s_app_bundle" % name,
            "__%s_native_frameworks" % name,
        ],
        tags = tags,
        **kwargs
    )
