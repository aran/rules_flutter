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
            "flutter_ios_app_framework_gen",
            "flutter_ios_info_plist_gen",
            "flutter_ios_registrant_gen",
            "flutter_ios_runner_lib_gen")

        flutter_ios_app_framework_gen(name = "my_framework", application = ":my_app")
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

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@build_bazel_rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("//flutter/private:app_version.bzl", "version_arg", "version_target_conflict")
load("//flutter/private:apple_app.bzl", "flutter_apple_app")
load("//flutter/private:apple_engine.bzl", _IOS_ENGINE_XCFRAMEWORK = "IOS_ENGINE_XCFRAMEWORK")
load("//flutter/private:apple_version_check.bzl", _flutter_apple_version_check = "flutter_apple_version_check")
load("//flutter/private:apple_xcframeworks_codesign.bzl", _flutter_apple_xcframeworks_codesign = "flutter_apple_xcframeworks_codesign")
load("//flutter/private:apple_xcframeworks_layout.bzl", "flutter_apple_xcframeworks_layout")
load("//flutter/private:constants.bzl", _IOS_MINIMUM_OS_VERSION = "IOS_MINIMUM_OS_VERSION")
load("//flutter/private:debug_build.bzl", _debug_build = "debug_build")
load("//flutter/private:flutter_apple_bundle_version.bzl", _flutter_apple_bundle_version = "flutter_apple_bundle_version")
load("//flutter/private:flutter_apple_plugin_library.bzl", _flutter_apple_plugin_library_macro = "flutter_apple_plugin_library")
load("//flutter/private:flutter_apple_plugin_xcframeworks.bzl", _flutter_ios_code_asset_xcframeworks = "flutter_ios_code_asset_xcframeworks", _flutter_ios_plugin_xcframeworks = "flutter_ios_plugin_xcframeworks")
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load("//flutter/private:flutter_apple_registrant.bzl", _flutter_apple_swift_package_registrant = "flutter_apple_swift_package_registrant", _flutter_ios_registrant_xcframework = "flutter_ios_registrant_xcframework")
load("//flutter/private:flutter_apple_xcframeworks.bzl", _flutter_ios_app_xcframework = "flutter_ios_app_xcframework", _flutter_ios_engine_xcframework = "flutter_ios_engine_xcframework")
load("//flutter/private:flutter_ios_application.bzl", _flutter_ios_app_framework_rule = "flutter_ios_app_framework", _flutter_ios_application = "flutter_ios_application", _flutter_ios_dropped_frameworks_rule = "flutter_ios_dropped_frameworks", _flutter_ios_native_frameworks_rule = "flutter_ios_native_frameworks", _flutter_ios_privacy_manifests_rule = "flutter_ios_privacy_manifests")
load("//flutter/private:flutter_ios_registrant.bzl", _flutter_ios_registrant_rule = "flutter_ios_registrant")
load("//flutter/private:flutter_plist_merge.bzl", _flutter_entitlements_merge = "flutter_entitlements_merge", _flutter_plist_merge = "flutter_plist_merge")
load("//flutter/private:ios_entitlements.bzl", "resolve_ios_entitlements")
load("//flutter/private:ios_signing_check.bzl", "flutter_ios_signing_check")
load("//flutter/private:runner_module.bzl", "runner_module_name")
load("//flutter/private:swiftpm_app_settings.bzl", _flutter_apple_app_runner = "flutter_apple_app_runner")
load("//flutter/private:validation.bzl", "validate_minimum_os_version")

# Re-export constants for user BUILD files.
IOS_MINIMUM_OS_VERSION = _IOS_MINIMUM_OS_VERSION
IOS_DEFAULT_LAUNCH_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/LaunchScreen.storyboard"
IOS_DEFAULT_MAIN_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/Main.storyboard"

# Add-to-app, for a host app built by Xcode (see README, "Add-to-app"): the
# application's App.xcframework, a copy of Flutter's own engine xcframework, an
# xcframework per plugin and per code asset, and the plugin registrant, in the
# build mode of the configuration.
flutter_ios_app_xcframework = _flutter_ios_app_xcframework
flutter_ios_engine_xcframework = _flutter_ios_engine_xcframework
flutter_ios_plugin_xcframeworks = _flutter_ios_plugin_xcframeworks
flutter_apple_xcframeworks_codesign = _flutter_apple_xcframeworks_codesign
flutter_ios_code_asset_xcframeworks = _flutter_ios_code_asset_xcframeworks
flutter_ios_registrant_xcframework = _flutter_ios_registrant_xcframework

# Merges entitlement additions into a base entitlements file — the additive
# seam rules_apple's single-file `entitlements` attribute does not provide.
# Wired into flutter_ios_app as `additional_entitlements`; exposed for Tier 2
# users assembling an ios_application themselves.
flutter_entitlements_merge = _flutter_entitlements_merge

# An Apple bundle's version from Flutter's build name and build number:
# what flutter_ios_app's `build_name` and `build_number` declare. Exposed to
# give an app extension the version of its app.
flutter_apple_bundle_version = _flutter_apple_bundle_version

# The Dart VM service's Info.plist keys, merged into non-release builds so
# the engine can advertise the service over mDNS. Matches flutter_tools'
# xcode_backend.dart, which only adds them for non-release configurations.
_DART_VM_SERVICE_PLIST = "@rules_flutter//flutter/private/runners/ios:DartVmServiceMdns.plist"

# -- Composable rules (Tier 2) ------------------------------------------------
#
# Like every other *_gen macro in this file, these default to
# `tags = ["manual"]`: the targets are only meaningful as deps of an
# `ios_application` (whose split transition puts them in an iOS
# configuration). Built standalone by a `//...` pattern they'd run in the
# host platform's configuration — wrapping the wrong platform's dylibs and invoking
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

def flutter_ios_dropped_frameworks_gen(name, **kwargs):
    """Lists the frameworks a release app removes. See `flutter_ios_dropped_frameworks`.

    Give it to the `ios_application`'s `resources`, and
    `@rules_flutter//flutter:ios_code_asset_post_processor` as its
    `ipa_post_processor`, both outside `-c dbg`:

        ios_application(
            ...
            resources = select({
                "@rules_flutter//flutter/private:dbg": [],
                "//conditions:default": [":my_dropped_frameworks"],
            }),
            ipa_post_processor = select({
                "@rules_flutter//flutter/private:dbg": None,
                "//conditions:default": "@rules_flutter//flutter:ios_code_asset_post_processor",
            }),
        )

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `ios_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_ios_dropped_frameworks_rule(name = name, tags = tags, **kwargs)

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
# going through the flutter/ext/ overlay system; for pub.dev plugins, flutter_pub_package
# emits this automatically.
flutter_apple_plugin_library = _flutter_apple_plugin_library_macro

# Aggregates per-plugin Apple swift_libraries from a flutter_application's
# transitive dep graph. Pass to runner_lib_gen `application` to thread plugin
# Swift modules + link inputs into the runner.
flutter_apple_plugins_aggregator = _flutter_apple_plugins_aggregator

def flutter_ios_app_framework_gen(name, application, minimum_os_version = IOS_MINIMUM_OS_VERSION, **kwargs):
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

    _flutter_ios_app_framework_rule(
        name = "__%s_framework" % name,
        application = "__%s_intermediates" % name,
        minimum_os_version = minimum_os_version,
        tags = tags,
    )

    apple_dynamic_framework_import(
        name = name,
        framework_imports = ["__%s_framework" % name],
        bundle_only = select({
            Label("@rules_flutter//flutter/private:dbg"): True,
            "//conditions:default": False,
        }),
        tags = tags,
        **kwargs
    )

def flutter_ios_engine(name, **kwargs):
    """Imports the Flutter.xcframework engine for the build mode.

    Debug mode (-c dbg): JIT engine for simulator.
    Profile mode (-c opt with `//flutter:profile`): AOT engine with the VM
    service, for device.
    Release mode (-c opt / default): AOT engine for device.

    Args:
        name: Target name. Add to swift_library deps for runner.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    apple_dynamic_xcframework_import(
        name = name,
        xcframework_imports = _IOS_ENGINE_XCFRAMEWORK,
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

    As in `flutter create`'s, the version keys are `$(FLUTTER_BUILD_NAME)`
    and `$(FLUTTER_BUILD_NUMBER)`, which the app's `version` replaces: give
    the `ios_application` a `flutter_apple_bundle_version` with the same
    `application`, so the bundle carries the version the program reports.
    Without a `version`, rules_apple fails on the unknown variables.

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

def flutter_ios_runner_lib_gen(name, registrant, engine, application = None, module_name = "Runner", info_plist = None, swift_package_environment = {}, **kwargs):
    """Generates a swift_library for the default iOS runner.

    Uses template AppDelegate.swift and SceneDelegate.swift from rules_flutter.
    This replaces `flutter create --platforms=ios` output for users who
    don't need custom runner files.

    When `application` is set, an internal flutter_apple_plugins_aggregator
    target is created and added to the runner's `swift_library.deps` so the
    generated registrant's `import <PluginModule>` lines resolve and the
    linker pulls in each transitive plugin's static archive. `name` is then
    that library built in the app's configuration, with its plugins
    (`flutter_apple_app_runner`).

    Args:
        name: Target name. Add to ios_application deps.
        registrant: A flutter_ios_registrant_gen target (Swift source).
        engine: A flutter_ios_engine target (Flutter.xcframework).
        application: A flutter_application target. Required to wire pub
            plugins' iOS Swift modules + link inputs into the runner;
            optional only for legacy Tier-2 setups with no native plugins.
        module_name: Swift module name (default "Runner").
        info_plist: The app's Info.plist, which a plugin whose Package.swift
            decides its defines from the app reads (`flutter_ios_app`'s
            `swift_package_environment`). Unset, such a manifest sees an
            empty one.
        swift_package_environment: As `flutter_ios_app`'s.
        **kwargs: Additional arguments passed to swift_library.
    """
    tags = kwargs.pop("tags", ["manual"])

    deps = [engine]
    library = name
    if application:
        aggregator_name = "_%s__apple_plugins_aggregator" % name
        _flutter_apple_plugins_aggregator(
            name = aggregator_name,
            application = application,
            info_plist = info_plist,
            swift_package_environment = swift_package_environment,
            platform = "ios",
            tags = tags,
            visibility = ["//visibility:private"],
        )
        deps.append(":" + aggregator_name)

        # `name` is the library in the app's configuration, with its plugins
        # (`flutter_apple_app_runner`).
        library = "_%s__library" % name
        _flutter_apple_app_runner(
            name = name,
            deps = [":" + library],
            info_plist = info_plist,
            swift_package_environment = swift_package_environment,
            tags = tags,
            testonly = kwargs.get("testonly"),
            visibility = kwargs.get("visibility"),
        )

    swift_library(
        name = library,
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
        build_name = None,
        build_number = None,
        launch_storyboard = None,
        entitlements = None,
        additional_entitlements = [],
        provisioning_profile = None,
        app_icons = None,
        resources = [],
        runner_deps = [],
        swift_package_environment = {},
        **kwargs):
    """Builds a Flutter iOS .app bundle from a flutter_application target.

    Discovers runner files from the conventional `ios/Runner/` directory
    (as generated by `flutter create --platforms=ios .`) and wires up all
    internal targets automatically.

    Prerequisites — the package must contain:
        - `ios/Runner/*.swift` (AppDelegate, SceneDelegate, etc.)
    Generate these with: `flutter create --platforms=ios .`

    Simulator builds need no code signing. A device build needs
    `provisioning_profile`, and fails at analysis, saying so, without one. That
    holds for an app that is not signed in this build as well: rules_apple
    takes the bundle's `embedded.mobileprovision` and its entitlements from the
    profile, also when signing is left for later (see below). See the README's
    "Running on an iOS device" for how to obtain a profile without an Xcode
    project.

    To leave signing for later, as `flutter build ios --no-codesign` does for a
    CI that holds no signing identity, build with
    `--features=disable_legacy_signing`: the `.ipa` is unsigned, and
    rules_apple's `combined_dossier_zip` output group holds what
    `dossier_codesigningtool` signs it with elsewhere. Unlike
    `--no-codesign`, this still wants the profile.

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
        families: Device families (default ["iphone"]; `flutter create` targets iPhone and iPad. An iPhone-only app runs in a small window on iPadOS. Adding "ipad" makes actool reject the 76x76@1x icon in `flutter create`'s icon set, so drop that entry first).
        app_name: User-facing display name. Defaults to name.
        minimum_os_version: Minimum iOS version.
        info_plist: Override conventional ios/Runner/Info.plist. The macro
            substitutes `$(PRODUCT_MODULE_NAME)` in either with the runner's
            module name, and `$(DEVELOPMENT_LANGUAGE)` with `en`; a plist
            that spells `UISceneDelegateClassName` out as
            `Runner.SceneDelegate` will not find the scene delegate. Keep the
            `$(PRODUCT_MODULE_NAME)` variable, or write `<name>.SceneDelegate`.
            The plist leaves `CFBundleShortVersionString` and
            `CFBundleVersion` to the app's version: a literal value there
            that differs from it fails the build. No key, the version
            itself, `$(FLUTTER_BUILD_NAME)` and `$(FLUTTER_BUILD_NUMBER)` as
            `flutter create` writes them, and Xcode's `$(MARKETING_VERSION)`
            and `$(CURRENT_PROJECT_VERSION)` pass.
        version: An `apple_bundle_version` (or `flutter_apple_bundle_version`)
            target, rules_apple's own way to set the version, to give the
            app's extensions the same one. Its values must be the
            `application`'s, which the program reports as `appBuildName` and
            `appBuildNumber`: a bundle version that differs fails the build.
            A `flutter_apple_bundle_version` with the same `application`
            takes them, and follows `--@rules_flutter//flutter:build_name`
            and `build_number`; one that states its own values fails the
            build when a setting gives another. Setting it with `build_name`
            or `build_number` is an error.
        build_name: CFBundleShortVersionString, as `flutter build
            --build-name`: numbers separated by periods, padded to three
            as `flutter build` pads them (`2.1` is `2.1.0`). Defaults to
            `1.0.0`. May be a `select()`, whose `None` is the default.
            Unset, the `application`'s `build_name`. Set, the
            `application` must set the same.
            `--@rules_flutter//flutter:build_name` replaces both for one build.
        build_number: CFBundleVersion, as `flutter build --build-number`:
            numbers separated by periods. Defaults to `1`. May be a
            `select()`.
            Unset, the `application`'s `build_number`. Set, the
            `application` must set the same.
            `--@rules_flutter//flutter:build_number` replaces both for one build.
        launch_storyboard: Override launch storyboard. Defaults to
            ios/Runner/Base.lproj/LaunchScreen.storyboard.
        entitlements: Override entitlements wiring. By default the macro
            auto-discovers `ios/Runner/Runner.entitlements` and forwards
            it to `ios_application`. Unlike macOS (where flutter create
            always emits the entitlements files), iOS only ships
            Runner.entitlements when capabilities are enabled in Xcode;
            its absence is a valid, capability-less app and the macro
            ships nothing rather than synthesizing a default. Pass `False`
            to ship none although the file exists — a device build is
            signed against a profile, and an entitlement the profile does
            not grant fails it: `aps-environment`, which Xcode writes when
            Push is enabled, cannot be granted by a team wildcard profile
            at all. rules_apple reports that as "uses entitlements with
            the ... key, but the profile does not have this key", which
            names the profile and not the file — and the file is in the
            build because it is on disk, not because anyone named it.
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
        runner_deps: Extra `swift_library` labels to link into the runner, so
            the runner's sources can `import` them and the binary carries
            their code. Added to the generated `__<name>_runner` library's
            `deps`; `deps` itself is the macro's and cannot be passed through
            **kwargs. For App Intents, pass the library here *and* to
            rules_apple's `app_intents` (which passes through **kwargs):
            `app_intents` only extracts the metadata, it does not link.
        swift_package_environment: The environment in which the
            `Package.swift` of each plugin that decides its defines from the
            app is evaluated, as the shell's environment is under `flutter
            build`: `{"AUDIO_SESSION_MICROPHONE": "1"}` for what
            audio_session's README says to export. Such a manifest is
            evaluated for this app, also seeing the app's Info.plist (see
            the README's "Apple plugins built from their Package.swift").
            Nothing else reads it, and the shell's environment does not
            reach the manifests.
        **kwargs: Passed through to ios_application, except `target_compatible_with`
            and `visibility`, which are the named target's, and `testonly`, which
            every target the macro declares has, since one that depends on a
            `testonly` application would otherwise fail analysis. The app is
            compatible with macOS (which builds it for iOS) and iOS only,
            whatever `target_compatible_with` adds, so `bazel build //...`
            skips it on any other platform. `tags` defaults to
            `["manual"]`, so `bazel build //...` skips the app and every
            target the macro declares for it; pass `tags` to replace that
            on all of them. The macro sets
            `bundle_id`, `bundle_name`, `entitlements`, `families`,
            `minimum_os_version`, `infoplists`, `version`,
            `launch_storyboard`, `resources`, `provisioning_profile`,
            `app_icons` and `deps` itself, so passing any of those
            here is a duplicate-keyword error — use the named parameter
            instead.
    """
    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])
    conflict = version_target_conflict(
        "flutter_ios_app(name = %r)" % name,
        version,
        build_name,
        build_number,
    )
    if conflict:
        fail(conflict)
    validate_minimum_os_version(
        "flutter_ios_app",
        name,
        minimum_os_version,
        _IOS_MINIMUM_OS_VERSION,
        "iOS",
    )

    module_name = runner_module_name("flutter_ios_app", name)

    # `target_compatible_with` and what decides who can see the app belong to
    # the target the user names (see `flutter_apple_app`), not to the
    # `ios_application` behind it.
    target_compatible_with = kwargs.pop("target_compatible_with", [])
    visibility = kwargs.pop("visibility", None)
    testonly = kwargs.pop("testonly", False)

    # Auto-discover ios/Runner/Runner.entitlements if the user hasn't
    # passed one. Its absence is convention-matching (no-capabilities
    # apps don't have an entitlements file); rules_apple's signing
    # pipeline still injects `get-task-allow=true` for debug builds.
    # `False` ships none although the file exists — see
    # `resolve_ios_entitlements` for the device build that needs it.
    # `allow_empty` is the supported no-capabilities case.
    entitlements = resolve_ios_entitlements(
        entitlements,
        discovered = "ios/Runner/Runner.entitlements" if native.glob(
            ["ios/Runner/Runner.entitlements"],
            allow_empty = True,
        ) else None,
    )

    # Fold the app's own entitlement additions in. `base` may legitimately be
    # None here: an iOS app without Xcode capabilities ships no entitlements
    # file, and then the additions are the entitlements.
    if additional_entitlements:
        _flutter_entitlements_merge(
            name = "__%s_entitlements" % name,
            base = entitlements,
            additions = additional_entitlements,
            tags = tags,
            testonly = testonly,
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
        # `allow_empty`: an app with no catalog ships the generic icon.
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
        testonly = testonly,
    )

    # 2. Extract intermediates (AOT dylib + flutter_assets + native_libs).
    _flutter_ios_application(
        name = "__%s_intermediates" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )

    # 3. Assemble App.framework from the AOT dylib.
    _flutter_ios_app_framework_rule(
        name = "__%s_app_framework" % name,
        application = "__%s_intermediates" % name,
        minimum_os_version = minimum_os_version,
        tags = tags,
        testonly = testonly,
    )

    # 3b. The dSYM of the stripped release App binary, for rules_apple to carry
    # in the `dsyms` output group of the app (`--apple_generate_dsym`).
    native.filegroup(
        name = "__%s_app_dsym" % name,
        srcs = ["__%s_app_framework" % name],
        output_group = "dsym",
        tags = tags,
        testonly = testonly,
    )

    # 4. Wrap App.framework as dynamic framework import.
    # Debug: bundle_only=True embeds framework without linking (no binary).
    apple_dynamic_framework_import(
        name = "__%s_app_bundle" % name,
        dsym_imports = ["__%s_app_dsym" % name],
        framework_imports = ["__%s_app_framework" % name],
        bundle_only = select({
            Label("@rules_flutter//flutter/private:dbg"): True,
            "//conditions:default": False,
        }),
        tags = tags,
        testonly = testonly,
    )

    # 5. Import Flutter.xcframework engine — follows the build mode.
    apple_dynamic_xcframework_import(
        name = "__%s_engine" % name,
        xcframework_imports = _IOS_ENGINE_XCFRAMEWORK,
        tags = tags,
        testonly = testonly,
    )

    # 6. Wrap native plugin/native-asset dylibs in signed .frameworks for bundling.
    _flutter_ios_native_frameworks_rule(
        name = "__%s_native_frameworks" % name,
        application = application,
        minimum_os_version = minimum_os_version,
        tags = tags,
        testonly = testonly,
    )

    # 6b. Expose plugin PrivacyInfo.xcprivacy files for bundling.
    _flutter_ios_privacy_manifests_rule(
        name = "__%s_privacy_manifests" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )

    # 6c. Outside debug, a link hook may drop a code asset whose framework
    #     `__<name>_native_frameworks` wraps, as it wraps every candidate:
    #     rules_apple embeds only frameworks it knows when the app is
    #     analysed. The app carries the list of those to remove, and the
    #     post-processor removes them before rules_apple signs the app.
    #     rules_apple runs one post-processor: an app with its own has it in
    #     place of this one, and fails to build if anything is to be removed.
    user_post_processor = kwargs.pop("ipa_post_processor", None)
    _flutter_ios_dropped_frameworks_rule(
        name = "__%s_dropped_frameworks" % name,
        application = application,
        conflict = (
            str(native.package_relative_label(user_post_processor)) if type(user_post_processor) in ("string", "Label") else "the app's `ipa_post_processor`"
        ) if user_post_processor != None else "",
        tags = tags,
        testonly = testonly,
    )

    # 7. Discover runner Swift sources and build swift_library.
    runner_srcs = native.glob(["ios/Runner/*.swift"])
    if not runner_srcs:
        fail("No Swift sources found in ios/Runner/. " +
             "Run 'flutter create --platforms=ios .' to generate runner files.")

    # 7a. Aggregate Apple plugin libraries from the application's transitive
    # FlutterInfo so the runner's swift_library imports + links each pub
    # plugin's Swift module.
    # A plugin whose Package.swift decides its defines from the app reads the
    # Info.plist the app is built from.
    actual_info_plist = "__%s_info_plist" % name
    _flutter_apple_plugins_aggregator(
        name = "__%s_apple_plugins" % name,
        application = application,
        info_plist = actual_info_plist,
        platform = "ios",
        swift_package_environment = swift_package_environment,
        tags = tags,
        testonly = testonly,
    )

    swift_library(
        name = "__%s_runner" % name,
        srcs = runner_srcs + ["__%s_registrant" % name],
        data = native.glob(["ios/Runner/Base.lproj/Main.storyboard"]),
        module_name = module_name,
        tags = tags,
        testonly = testonly,
        deps = [
            "__%s_engine" % name,
            "__%s_apple_plugins" % name,
        ] + runner_deps,
    )

    # The runner in the app's configuration, with its plugins
    # (`flutter_apple_app_runner`).
    _flutter_apple_app_runner(
        name = "__%s_app_runner" % name,
        deps = ["__%s_runner" % name],
        info_plist = actual_info_plist,
        swift_package_environment = swift_package_environment,
        tags = tags,
        testonly = testonly,
    )

    # 8. Info.plist — preprocess to resolve Xcode variables that rules_apple
    #    doesn't handle, in the conventional plist or the one the app names.
    #    A merge rather than a text template: the app's plist may be saved in
    #    binary form, which a text substitution would corrupt.
    _flutter_plist_merge(
        name = "__%s_info_plist" % name,
        base = info_plist or "ios/Runner/Info.plist",
        mode = "supplement",
        output_basename = "Info.plist",
        substitutions = {
            "$(DEVELOPMENT_LANGUAGE)": "en",
            # UISceneDelegateClassName is <module>.SceneDelegate: the
            # flutter create SceneDelegate carries no @objc, so its
            # runtime name is module-qualified and must track module_name.
            "$(PRODUCT_MODULE_NAME)": module_name,
            # $(FLUTTER_BUILD_NAME) and $(FLUTTER_BUILD_NUMBER) stay:
            # rules_apple replaces both keys with `version`'s values.
        },
        tags = tags,
        # Not `testonly` even in a testonly app: the plugins whose
        # Package.swift reads the app read it (`swift_package_environment`),
        # and they are not. It depends on nothing that is.
    )

    # 9. Version, from `build_name` and `build_number` unless the app names
    #    its own.
    if not version:
        _flutter_apple_bundle_version(
            name = "__%s_version" % name,
            application = application,
            build_name = version_arg(build_name),
            build_number = version_arg(build_number),
            tags = tags,
            testonly = testonly,
        )
        version = ":%s" % ("__%s_version" % name)

    # 9b. The plist leaves the version keys to the version: rules_apple
    #     replaces both, so a literal that differs would be dropped silently.
    #     And the version is the application's, which the program reports.
    _flutter_apple_version_check(
        name = "__%s_version_check" % name,
        plist = actual_info_plist,
        plist_name = "ios/Runner/Info.plist" if not info_plist else "",
        app_label = str(native.package_relative_label(name)),
        application = application,
        version = version,
        rule_name = "flutter_ios_app",
        tags = tags,
        testonly = testonly,
    )

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
        testonly = testonly,
    )

    # 10c. Fails a device build that has no provisioning profile with the reason
    #      rules_apple wants one, which its own error leaves out. Which builds
    #      are for a device is known to the rule, under the transition.
    flutter_ios_signing_check(
        name = "__%s_signing_check" % name,
        app_label = str(native.package_relative_label(name)),
        provisioning_profile_set = provisioning_profile != None,
        tags = tags,
        testonly = testonly,
    )

    # 11. Final ios_application, behind the target the user names.
    ios_application(
        name = "__%s_app" % name,
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
        resources = resources + ["__%s_privacy_manifests" % name] + select({
            "@rules_flutter//flutter/private:dbg": [],
            "//conditions:default": ["__%s_dropped_frameworks" % name],
        }),
        ipa_post_processor = user_post_processor if user_post_processor != None else select({
            "@rules_flutter//flutter/private:dbg": None,
            "//conditions:default": "@rules_flutter//flutter:ios_code_asset_post_processor",
        }),
        deps = [
            "__%s_app_runner" % name,
            "__%s_app_bundle" % name,
            "__%s_native_frameworks" % name,
            "__%s_signing_check" % name,
        ],
        tags = tags,
        testonly = testonly,
        **kwargs
    )

    # 12. The target the user names: carries the compatibility constraints. An
    # iOS app is for a Mac, and built for iOS from there; `ios` is accepted too
    # for a build that already names an iOS platform.
    flutter_apple_app(
        name = name,
        app = "__%s_app" % name,
        validations = ["__%s_version_check" % name],
        tags = tags,
        target_compatible_with = target_compatible_with + select({
            "@platforms//os:ios": [],
            "@platforms//os:macos": [],
            "//conditions:default": ["@platforms//:incompatible"],
        }),
        testonly = testonly,
        visibility = visibility,
    )

def flutter_ios_simulator_build(name, targets, **kwargs):
    """Builds iOS apps for the simulator in debug mode, whatever `-c` says.

    The simulator engine runs only debug builds, so a simulator app built in
    `fastbuild` or `opt` is refused at analysis, and so is one built with
    `--@rules_flutter//flutter:profile` (upstream has no profile simulator
    build either). This forwards the files of `targets` built with `-c dbg`
    and the flag off, for anything that needs a simulator bundle under a
    default `bazel test //...`: a `build_test`, or a test that reads
    the bundle through `data`. The files keep their runfiles paths.

    Args:
        name: Target name.
        targets: `flutter_ios_app` or `ios_application` targets.
        **kwargs: Common attributes (e.g. `tags`, `testonly`, `visibility`).
    """
    _debug_build(
        name = name,
        targets = targets,
        **kwargs
    )

def flutter_ios_simulator_build_test(name, targets, **kwargs):
    """A build test of iOS simulator apps, built with `-c dbg`.

    A plain `build_test` of a simulator app fails under a default
    `bazel test //...`, because the app is refused outside debug mode. See
    `flutter_ios_simulator_build`.

    Args:
        name: Target name.
        targets: `flutter_ios_app` or `ios_application` targets to build.
        **kwargs: Passed through to `build_test` (e.g. `tags`,
            `target_compatible_with`).
    """
    flutter_ios_simulator_build(
        name = "__%s_dbg" % name,
        targets = targets,
        tags = ["manual"],
        testonly = True,
    )
    build_test(
        name = name,
        targets = ["__%s_dbg" % name],
        **kwargs
    )

def flutter_ios_xcframeworks(
        name,
        application,
        plugins = True,
        static_plugins = False,
        codesign_identity = None,
        minimum_os_version = IOS_MINIMUM_OS_VERSION,
        **kwargs):
    """The xcframeworks a host app built by Xcode embeds Flutter with, as `flutter build ios-framework` makes them.

    `bazel build` makes the build mode of the configuration (`-c dbg` Debug,
    `-c opt --@rules_flutter//flutter:profile` Profile, otherwise Release) as
    `<name>/<Mode>/`: App.xcframework, a copy of Flutter's own engine
    xcframework, an xcframework per plugin and per code asset,
    FlutterPluginRegistrant.xcframework (link it; or add the
    `GeneratedPluginRegistrant.h` and `.m` above the modes to the host),
    as upstream lays them out. `bazel run` writes that to
    `build/ios/framework/` in the package (`-- --output=<dir>` elsewhere),
    replacing that mode's directory, so a run per mode fills `Debug/`,
    `Profile/` and `Release/`. The frameworks are built unsigned; with
    `codesign_identity` they are signed in a step of their own, as upstream
    signs them (`flutter_apple_xcframeworks_codesign`).

    Args:
        name: The target: build it, or run it to export.
        application: The `flutter_application` the host shows.
        plugins: Whether to package the application's plugins; False when the
            host ships them itself (upstream's `--no-plugins`).
        static_plugins: Static plugin frameworks, linked and not embedded
            (upstream's `--static`).
        codesign_identity: The identity to sign the xcframeworks with
            (upstream's `--codesign-identity`), or `-` for ad hoc. Unset, they
            are unsigned, and Xcode signs them when it embeds them.
        minimum_os_version: The minimum iOS version of the frameworks.
        **kwargs: `visibility`, `tags` and the like, for `name`.
    """
    internal_tags = kwargs.get("tags", []) + ["manual"]
    _flutter_ios_app_xcframework(
        name = "_%s_app" % name,
        application = application,
        minimum_os_version = minimum_os_version,
        tags = internal_tags,
    )
    _flutter_ios_engine_xcframework(
        name = "_%s_engine" % name,
        tags = internal_tags,
    )
    _flutter_ios_code_asset_xcframeworks(
        name = "_%s_code_assets" % name,
        application = application,
        minimum_os_version = minimum_os_version,
        tags = internal_tags,
    )
    xcframeworks = [
        "_%s_app" % name,
        "_%s_engine" % name,
        "_%s_code_assets" % name,
    ]
    if plugins:
        _flutter_ios_plugin_xcframeworks(
            name = "_%s_plugins" % name,
            application = application,
            minimum_os_version = minimum_os_version,
            static = static_plugins,
            tags = internal_tags,
        )
        _flutter_ios_registrant_xcframework(
            name = "_%s_registrant" % name,
            application = application,
            plugins = "_%s_plugins" % name,
            minimum_os_version = minimum_os_version,
            tags = internal_tags,
        )
        xcframeworks += ["_%s_plugins" % name, "_%s_registrant" % name]
    layout = name
    if codesign_identity:
        layout = "_%s_unsigned" % name
        _flutter_apple_xcframeworks_codesign(
            name = name,
            xcframeworks = layout,
            identity = codesign_identity,
            **kwargs
        )
        kwargs = {"tags": internal_tags, "visibility": ["//visibility:private"]}
    _flutter_apple_swift_package_registrant(
        name = "_%s_swift_package_registrant" % name,
        application = application,
        platform = "ios",
        register_plugins = plugins,
        tags = internal_tags,
    )
    flutter_apple_xcframeworks_layout(
        name = layout,
        platform = "ios",
        swift_package_registrant = "_%s_swift_package_registrant" % name,
        minimum_os_version = minimum_os_version,
        xcframeworks = xcframeworks,
        renamed_files = {},
        debug_files = [
            Label("//flutter/private/add_to_app:flutter_lldbinit"),
            Label("//flutter/private/add_to_app:flutter_lldb_helper.py"),
        ],
        **kwargs
    )
