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
            deps = [
                ":my_framework",
                # Frameworks for native assets / `native_deps` dylibs. Leave
                # this out and the app still builds and renders — it just
                # cannot resolve any native asset at runtime.
                ":my_native_frameworks",
                ":my_runner",
            ],
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
load("//flutter/private:flutter_plist_merge.bzl", _flutter_entitlements_merge = "flutter_entitlements_merge", _flutter_plist_merge = "flutter_plist_merge")
load("//flutter/private:runner_module.bzl", "runner_module_name")

# Re-export constants for user BUILD files.
IOS_MINIMUM_OS_VERSION = _IOS_MINIMUM_OS_VERSION
IOS_DEFAULT_LAUNCH_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/LaunchScreen.storyboard"
IOS_DEFAULT_MAIN_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/Main.storyboard"

# Merges entitlement additions into a base entitlements file — the additive
# seam rules_apple's single-file `entitlements` attribute does not provide.
# Wired into flutter_ios_app as `additional_entitlements`; exposed for Tier 2
# users assembling an ios_application themselves.
flutter_entitlements_merge = _flutter_entitlements_merge

# The Dart VM service's Info.plist keys, merged into non-release builds so
# the engine can advertise the service over mDNS. Matches flutter_tools'
# xcode_backend.dart, which only adds them for non-release configurations.
_DART_VM_SERVICE_PLIST = "@rules_flutter//flutter/private/runners/ios:DartVmServiceMdns.plist"

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
        additional_entitlements = [],
        provisioning_profile = None,
        app_icons = None,
        resources = [],
        **kwargs):
    """Builds a Flutter iOS .app bundle from a flutter_application target.

    Discovers runner files from the conventional `ios/Runner/` directory
    (as generated by `flutter create --platforms=ios .`) and wires up all
    internal targets automatically.

    Prerequisites — the package must contain:
        - `ios/Runner/*.swift` (AppDelegate, SceneDelegate, etc.)
    Generate these with: `flutter create --platforms=ios .`

    Simulator builds need no code signing. Device builds require
    `provisioning_profile`; without it `ios_application` fails at analysis
    with "The provisioning_profile attribute must be set for device builds
    on this platform (ios)". See the README's "Running an iOS example on a
    physical device" for how to obtain one without an Xcode project.

    Non-release builds carry two extra `Info.plist` keys —
    `NSBonjourServices` and `NSLocalNetworkUsageDescription` — so the engine
    can advertise the Dart VM service over mDNS, matching flutter_tools'
    `xcode_backend.dart`. Release builds drop them, which is correct: they
    exist for the debugger, not for the app. An app that needs iOS 14+ Local
    Network Privacy for *itself* must declare `NSLocalNetworkUsageDescription`
    (and its own `NSBonjourServices`) in `ios/Runner/Info.plist`, where it
    survives into release; the macro merges the VM service keys into that
    plist rather than beside it, so the app's own values win and its Bonjour
    service list is preserved.

    Args:
        name: Target name (Bazel identifier). The runner's Swift module name
            is derived from it, so it must be a bare Swift identifier.
        application: A flutter_application target (required).
        bundle_id: CFBundleIdentifier (required — rules_apple constraint).
        families: Device families (default ["iphone"]).
        app_name: User-facing display name. Defaults to name.
        minimum_os_version: Minimum iOS version.
        info_plist: Override conventional ios/Runner/Info.plist. The macro
            substitutes `$(PRODUCT_MODULE_NAME)` in the conventional plist
            with the runner's module name; an overriding plist that spells
            `UISceneDelegateClassName` out as `Runner.SceneDelegate` will not
            find the scene delegate. Keep the `$(PRODUCT_MODULE_NAME)`
            variable, or write `<name>.SceneDelegate`.
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
        additional_entitlements: Entitlement plist files merged into the
            base entitlements in **every** compilation mode — the additive
            seam for an app that needs one more `com.apple.security.*` key
            without taking over `ios/Runner/Runner.entitlements`. A key the
            base already declares with the same value is deduped; a
            different value is a hard error naming the key and both files.
            Works when the app ships no entitlements file at all, in which
            case the additions become the entitlements.
        provisioning_profile: A `.mobileprovision` file (usually a
            `local_provisioning_profile` target) to sign a device build
            with. Required for device builds (`--ios_multi_cpus=arm64`) and
            unused by simulator builds.
        app_icons: The app icon, as the files of an `.appiconset` or of an
            Icon Composer `.icon` bundle. Defaults to the conventional
            `ios/Runner/Assets.xcassets/AppIcon.appiconset` that
            `flutter create` writes — so an app that has never thought about
            this ships the icon it already has on disk, which is what
            `flutter build ios` does with the same tree. Pass a list to name a
            different one; pass `[]` to ship no icon. rules_apple refuses an
            `.appiconset` and a `.icon` bundle together, so name exactly one.
            Discovery is per-platform and its absence is silent: a tree
            that only ever ran `flutter create --platforms=macos .` has no
            catalog here, and an app with neither a catalog nor an
            `app_icons` has said nothing either way, so it ships no icon and
            there is nothing to report.
        resources: Extra resources. Main.storyboard is wired separately,
            through the runner library, so that ibtool resolves its classes
            against the runner's module. Resources passed here are compiled
            against the app target's name instead, which is not a module any
            target produces — so a storyboard listed here cannot reference the
            runner's Swift classes (an `@objc` class name works regardless).
        **kwargs: Passed through to ios_application. The macro sets
            `bundle_id`, `bundle_name`, `entitlements`, `families`,
            `minimum_os_version`, `infoplists`, `version`,
            `launch_storyboard`, `resources`, `provisioning_profile`,
            `app_icons`, `deps` and `tags` itself, so passing any of those
            here is a duplicate-keyword error — use the named parameter
            instead.
    """
    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])

    module_name = runner_module_name("flutter_ios_app", name)

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

    # Fold the app's own entitlement additions in. `base` may legitimately be
    # None here: an iOS app without Xcode capabilities ships no entitlements
    # file, and then the additions are the entitlements.
    if additional_entitlements:
        _flutter_entitlements_merge(
            name = "__%s_entitlements" % name,
            base = entitlements,
            additions = additional_entitlements,
            tags = tags,
        )
        entitlements = "__%s_entitlements" % name

    # The app icon: the conventional catalog `flutter create` writes, unless
    # the caller named something else. Discovered for the same reason the
    # entitlements and the launch storyboard are — the scaffold is the app's
    # answer until it says otherwise — and leaving it undiscovered meant every
    # Bazel-built Flutter app shipped the generic icon while the sixteen PNGs
    # `flutter create` left behind were read by nothing.
    #
    # `None` means discover, `[]` means ship none: both states are sayable, and
    # an app with no catalog at all is the second without having to write it.
    if app_icons == None:
        app_icons = native.glob(
            ["ios/Runner/Assets.xcassets/AppIcon.appiconset/**"],
            allow_empty = True,
        )

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
        module_name = module_name,
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
                # UISceneDelegateClassName is <module>.SceneDelegate: the
                # flutter create SceneDelegate carries no @objc, so its
                # runtime name is module-qualified and must track module_name.
                "$(PRODUCT_MODULE_NAME)": module_name,
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

    # 10b. Dart VM service keys for debug/profile builds — required for the
    #      Flutter engine to register the VM service via mDNS. Matches
    #      flutter_tools' xcode_backend.dart, which only adds them for
    #      non-release configurations.
    #
    #      These are *merged into* the app's Info.plist rather than passed
    #      beside it. rules_apple's plisttool hard-fails when two plists
    #      declare the same key with different values, so an app declaring
    #      its own NSLocalNetworkUsageDescription — the documented way to
    #      request iOS 14+ Local Network Privacy, and the key a LAN app
    #      needs in release — could not build in `-c dbg` at all. The
    #      supplement merge keeps the app's own values and unions its
    #      NSBonjourServices with `_dartVmService._tcp`.
    _flutter_plist_merge(
        name = "__%s_info_plist_dev" % name,
        base = actual_info_plist,
        additions = [_DART_VM_SERVICE_PLIST],
        mode = "supplement",
        output_basename = "Info.plist",
        tags = tags,
    )

    # 11. Final ios_application.
    ios_application(
        name = name,
        bundle_id = bundle_id,
        bundle_name = display_name,
        entitlements = entitlements,
        families = families,
        minimum_os_version = minimum_os_version,
        infoplists = select({
            "@rules_flutter//flutter:release": [actual_info_plist],
            "//conditions:default": ["__%s_info_plist_dev" % name],
        }),
        version = version,
        launch_storyboard = actual_launch_storyboard,
        provisioning_profile = provisioning_profile,
        app_icons = app_icons,
        resources = resources + ["__%s_privacy_manifests" % name],
        deps = [
            "__%s_runner" % name,
            "__%s_app_bundle" % name,
            "__%s_native_frameworks" % name,
        ],
        tags = tags,
        **kwargs
    )
