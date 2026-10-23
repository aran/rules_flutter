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

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import")
load("@rules_apple//apple:ios.bzl", "ios_application")
load("@rules_apple//apple:versioning.bzl", "apple_bundle_version")
load("@rules_swift//swift:swift.bzl", "swift_library")
load("//flutter/private:constants.bzl", _IOS_MINIMUM_OS_VERSION = "IOS_MINIMUM_OS_VERSION")
load("//flutter/private:debug_build.bzl", _debug_build = "debug_build")
load("//flutter/private:flutter_apple_plugin_library.bzl", _flutter_apple_plugin_library_macro = "flutter_apple_plugin_library", _flutter_xtool_apple_plugin_library = "flutter_xtool_apple_plugin_library")
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load("//flutter/private:flutter_ios_application.bzl", _flutter_ios_application = "flutter_ios_application", _flutter_ios_framework_rule = "flutter_ios_framework", _flutter_ios_native_frameworks_rule = "flutter_ios_native_frameworks", _flutter_ios_privacy_manifests_rule = "flutter_ios_privacy_manifests")
load("//flutter/private:flutter_ios_registrant.bzl", _flutter_ios_registrant_rule = "flutter_ios_registrant")
load("//flutter/private:flutter_plist_merge.bzl", _flutter_entitlements_merge = "flutter_entitlements_merge", _flutter_plist_merge = "flutter_plist_merge")
load("//flutter/private:flutter_xtool_bundle.bzl", _flutter_darwin_xcframework_import = "flutter_darwin_xcframework_import", _flutter_xtool_bundle_version = "flutter_xtool_bundle_version", _flutter_xtool_ios_bundle = "flutter_xtool_ios_bundle", _resolve_xtool_version = "resolve_xtool_version")
load("//flutter/private:ios_entitlements.bzl", "resolve_ios_entitlements")
load("//flutter/private:runner_module.bzl", "runner_module_name")
load("//flutter/private:validation.bzl", "validate_minimum_os_version")

# Re-export constants for user BUILD files.
IOS_MINIMUM_OS_VERSION = _IOS_MINIMUM_OS_VERSION
IOS_DEFAULT_LAUNCH_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/LaunchScreen.storyboard"
IOS_DEFAULT_MAIN_STORYBOARD = "@rules_flutter//flutter/private/runners/ios:Base.lproj/Main.storyboard"

# Merges entitlement additions into a base entitlements file — the additive
# seam rules_apple's single-file `entitlements` attribute does not provide.
# Wired into flutter_ios_app as `additional_entitlements`; exposed for Tier 2
# users assembling an ios_application themselves.
flutter_entitlements_merge = _flutter_entitlements_merge

# Host-agnostic xtool xcframework import, versioning, and iOS bundle rules.
flutter_darwin_xcframework_import = _flutter_darwin_xcframework_import
flutter_xtool_bundle_version = _flutter_xtool_bundle_version
flutter_xtool_ios_bundle = _flutter_xtool_ios_bundle

# The Dart VM service's Info.plist keys, merged into non-release builds so
# the engine can advertise the service over mDNS. Matches flutter_tools'
# xcode_backend.dart, which only adds them for non-release configurations.
_DART_VM_SERVICE_PLIST = "@rules_flutter//flutter/private/runners/ios:DartVmServiceMdns.plist"

def _engine_xcframework_select():
    """Selects the Flutter.xcframework engine for the active compilation mode.

    Debug (-c dbg): JIT engine (simulator). Profile (-c opt with
    `//flutter:profile`): the profile AOT engine (device). Release (-c opt /
    default): AOT engine (device). The labels resolve through rules_flutter's
    own repo mapping, so a consumer needs none of these repos in `use_repo`.
    """
    return select({
        Label("@rules_flutter//flutter/private:dbg"): [Label("@flutter_ios_engine//:Flutter_xcframework_debug")],
        Label("@rules_flutter//flutter/private:profile"): [Label("@flutter_ios_engine_profile//:Flutter_xcframework")],
        "//conditions:default": [Label("@flutter_ios_engine//:Flutter_xcframework")],
    })

# -- Composable rules (Tier 2) ------------------------------------------------
#
# Like every other *_gen macro in this file, these default to
# `tags = ["manual"]`: the targets are only meaningful as deps of an
# `ios_application` (whose split transition puts them in an iOS
# configuration). Built standalone by a `//...` pattern they'd run in the
# host configuration — wrapping the wrong platform's dylibs and invoking
# Apple-only tools (`xcrun`), which fails outright on non-macOS hosts.

def flutter_ios_registrant_gen(name, language = "swift", exclude_plugins = [], **kwargs):
    """Generates the iOS GeneratedPluginRegistrant. See `flutter_ios_registrant`.

    Args:
        name: Target name.
        language: Registrant language: `"swift"` (default) emits
            GeneratedPluginRegistrant.swift; `"objc"` emits
            GeneratedPluginRegistrant.h and GeneratedPluginRegistrant.m
            matching the flutter tool's own template, exposed through the
            `hdrs` and `srcs` output groups for an objc_library to consume.
        exclude_plugins: Plugin module names to leave out of the
            registrant. A name that is not a native iOS plugin of the
            application is an error, listing the valid names. iOS-only:
            the Android, Linux, macOS and Windows registrants always
            register every collected native plugin.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `ios_application`.
    """
    if language not in ("swift", "objc"):
        fail("flutter_ios_registrant_gen: language must be 'swift' or 'objc', got %r" % language)
    tags = kwargs.pop("tags", ["manual"])
    _flutter_ios_registrant_rule(
        name = name,
        language = language,
        exclude_plugins = exclude_plugins,
        tags = tags,
        **kwargs
    )

def flutter_ios_native_frameworks_gen(name, minimum_os_version = IOS_MINIMUM_OS_VERSION, **kwargs):
    """Wraps native dylibs in .frameworks for iOS bundling. See `flutter_ios_native_frameworks`.

    Args:
        name: Target name.
        minimum_os_version: Minimum iOS deployment target.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `ios_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_ios_native_frameworks_rule(
        name = name,
        minimum_os_version = minimum_os_version,
        tags = tags,
        **kwargs
    )

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
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    _flutter_ios_application(
        name = "__%s_intermediates" % name,
        application = application,
        tags = internal_tags,
    )

    _flutter_ios_framework_rule(
        name = "__%s_framework" % name,
        application = "__%s_intermediates" % name,
        minimum_os_version = minimum_os_version,
        tags = internal_tags,
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

def flutter_ios_engine(name, backend = "rules_apple", **kwargs):
    """Imports the Flutter.xcframework engine, auto-selecting debug or release.

    Debug mode (-c dbg): JIT engine for simulator.
    Release mode (-c opt / default): AOT engine for device.

    Args:
        name: Target name. Add to swift_library deps for runner.
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_ios_engine: backend must be 'rules_apple' or 'xtool', got %r" % backend)
    tags = kwargs.pop("tags", ["manual"])

    if backend == "rules_apple":
        apple_dynamic_xcframework_import(
            name = name,
            xcframework_imports = _engine_xcframework_select(),
            tags = tags,
            **kwargs
        )
    else:
        _flutter_darwin_xcframework_import(
            name = name,
            framework_name = "Flutter",
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

def flutter_ios_runner_lib_gen(name, registrant, engine, application = None, module_name = "Runner", backend = "rules_apple", **kwargs):
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
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        **kwargs: Additional arguments passed to swift_library.
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_ios_runner_lib_gen: backend must be 'rules_apple' or 'xtool', got %r" % backend)
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    deps = [engine]
    if application:
        aggregator_name = "_%s__apple_plugins_aggregator" % name
        _flutter_apple_plugins_aggregator(
            name = aggregator_name,
            application = application,
            platform = "ios",
            tags = internal_tags,
            visibility = ["//visibility:private"],
        )
        deps.append(":" + aggregator_name)

    runner_srcs = [
        registrant,
        "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
        "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
    ]
    if backend == "rules_apple":
        swift_library(
            name = name,
            srcs = runner_srcs,
            data = [
                "@rules_flutter//flutter/private/runners/ios:Base.lproj/Main.storyboard",
            ],
            module_name = module_name,
            tags = tags,
            deps = deps,
            **kwargs
        )
    else:
        _flutter_xtool_apple_plugin_library(
            name = name,
            srcs = runner_srcs,
            module_name = module_name,
            platform = "ios",
            deps = deps,
            tags = tags,
            **kwargs
        )

# -- Convenience macro (Tier 1) -----------------------------------------------

def _ios_resolve_entitlements(name, entitlements, additional_entitlements, internal_tags):
    """Discovers the Runner entitlements and folds the app's additions in.

    `base` may legitimately be None here: an iOS app without Xcode
    capabilities ships no entitlements file, and then the additions are the
    entitlements.
    """
    resolved = resolve_ios_entitlements(
        entitlements,
        discovered = "ios/Runner/Runner.entitlements" if native.glob(
            ["ios/Runner/Runner.entitlements"],
            allow_empty = True,
        ) else None,
    )
    if additional_entitlements:
        _flutter_entitlements_merge(
            name = "__%s_entitlements" % name,
            base = resolved,
            additions = additional_entitlements,
            tags = internal_tags,
        )
        resolved = "__%s_entitlements" % name
    return resolved

def _ios_discover_app_icons(app_icons, backend):
    """Discovers the conventional asset catalog `flutter create` writes.

    `None` means discover, `[]` means ship none: both states are sayable, and
    an app with no catalog at all is the second without having to write it.
    """
    if app_icons == None and backend == "rules_apple":
        return native.glob(
            ["ios/Runner/Assets.xcassets/AppIcon.appiconset/**"],
            allow_empty = True,
        )
    return app_icons

def _ios_build_frameworks(name, application, minimum_os_version, allow_non_macho, backend, engine, exclude_plugins, internal_tags):
    """Emits the registrant, intermediates, App.framework and engine targets.

    Returns:
      The engine target label to link the runner against.
    """

    # 1. Generate iOS Swift plugin registrant.
    _flutter_ios_registrant_rule(
        name = "__%s_registrant" % name,
        application = application,
        exclude_plugins = exclude_plugins,
        tags = internal_tags,
    )

    # 2. Extract intermediates (AOT dylib + flutter_assets + native_libs).
    _flutter_ios_application(
        name = "__%s_intermediates" % name,
        application = application,
        tags = internal_tags,
    )

    # 3. Assemble App.framework from the AOT dylib (or debug stub + kernel).
    _flutter_ios_framework_rule(
        name = "__%s_app_framework" % name,
        application = "__%s_intermediates" % name,
        minimum_os_version = minimum_os_version,
        allow_non_macho = allow_non_macho,
        tags = internal_tags,
    )

    # 4. Wrap App.framework for rules_apple.
    #    In debug mode, bundle_only=True embeds the framework without linking
    #    (the stub binary only exists for rules_apple compatibility and isn't
    #    loaded at runtime — Flutter uses the JIT kernel blob instead).
    if backend == "rules_apple":
        apple_dynamic_framework_import(
            name = "__%s_app_bundle" % name,
            framework_imports = ["__%s_app_framework" % name],
            bundle_only = select({
                Label("@rules_flutter//flutter/private:dbg"): True,
                "//conditions:default": False,
            }),
            tags = internal_tags,
        )

    # 5. Import Flutter.xcframework engine — auto-selects debug/release and backend.
    if engine:
        return engine
    flutter_ios_engine(
        name = "__%s_engine" % name,
        backend = backend,
        tags = internal_tags,
    )
    return "__%s_engine" % name

def _ios_build_native_frameworks(name, application, minimum_os_version, allow_non_macho, internal_tags):
    """Wraps native plugin/native-asset dylibs in .frameworks for bundling."""

    # 6. Wrap native plugin/native-asset dylibs in .frameworks for bundling.
    _flutter_ios_native_frameworks_rule(
        name = "__%s_native_frameworks" % name,
        application = application,
        minimum_os_version = minimum_os_version,
        allow_non_macho = allow_non_macho,
        tags = internal_tags,
    )

    # 6b. Expose plugin PrivacyInfo.xcprivacy files for bundling.
    _flutter_ios_privacy_manifests_rule(
        name = "__%s_privacy_manifests" % name,
        application = application,
        tags = internal_tags,
    )

def _ios_discover_runner_srcs(srcs):
    """Discovers the runner Swift sources, failing when there are none."""
    runner_srcs = srcs if srcs != None else native.glob(["ios/Runner/*.swift"])
    if not runner_srcs:
        fail("No Swift sources found in ios/Runner/. " +
             "Run 'flutter create --platforms=ios .' to generate runner files.")
    return runner_srcs

def _ios_resolve_info_plist(name, info_plist, module_name, internal_tags):
    """Preprocesses the Info.plist to resolve Xcode variables rules_apple misses."""
    if info_plist:
        return info_plist
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
        tags = internal_tags,
    )
    return "__%s_info_plist" % name

def _ios_resolve_version(name, backend, version, internal_tags, kwargs):
    """Creates the default apple_bundle_version (rules_apple) or resolves it (xtool).

    Returns:
      A `(version, invalid_version_error)` tuple.
    """
    if backend == "rules_apple":
        if not version:
            apple_bundle_version(
                name = "__%s_version" % name,
                build_version = "1.0",
                short_version_string = "1.0",
                tags = internal_tags,
            )
            return ":%s" % ("__%s_version" % name), ""
        return version, ""
    version, version_bv, version_sv, invalid_version_error = _resolve_xtool_version(
        name,
        "flutter_ios_app",
        version,
        internal_tags,
    )
    if version_bv and "build_version" not in kwargs:
        kwargs["build_version"] = version_bv
    if version_sv and "short_version" not in kwargs:
        kwargs["short_version"] = version_sv
    return version, invalid_version_error

def _ios_resolve_launch_storyboard(launch_storyboard, backend):
    """Resolves the launch storyboard, discovering the conventional one."""
    if launch_storyboard == False:
        return None
    if not launch_storyboard:
        launch_candidates = native.glob(["ios/Runner/Base.lproj/LaunchScreen.storyboard"], allow_empty = True)
        if launch_candidates:
            return launch_candidates[0]
        if backend == "rules_apple":
            return IOS_DEFAULT_LAUNCH_STORYBOARD
    return launch_storyboard

def _ios_dev_infoplists(name, actual_info_plist, internal_tags):
    """Merges the Dart VM service keys into a dev Info.plist and selects it.

    The keys are *merged into* the app's Info.plist rather than passed
    beside it. rules_apple's plisttool hard-fails when two plists
    declare the same key with different values, so an app declaring
    its own NSLocalNetworkUsageDescription — the documented way to
    request iOS 14+ Local Network Privacy, and the key a LAN app
    needs in release — could not build in `-c dbg` at all. The
    supplement merge keeps the app's own values and unions its
    NSBonjourServices with `_dartVmService._tcp`.
    """
    _flutter_plist_merge(
        name = "__%s_info_plist_dev" % name,
        base = actual_info_plist,
        additions = [_DART_VM_SERVICE_PLIST],
        mode = "supplement",
        output_basename = "Info.plist",
        tags = internal_tags,
    )
    return select({
        "@rules_flutter//flutter:release": [actual_info_plist],
        "//conditions:default": ["__%s_info_plist_dev" % name],
    })

def _ios_emit_rules_apple_bundle(name, display_name, bundle_id, families, minimum_os_version, version, selected_infoplists, actual_launch_storyboard, app_icons, resources, provisioning_profile, entitlements, tags, visibility, kwargs):
    """Emits the final rules_apple ios_application bundle target."""
    ios_application(
        name = name,
        bundle_id = bundle_id,
        bundle_name = display_name,
        entitlements = entitlements,
        families = families,
        minimum_os_version = minimum_os_version,
        infoplists = selected_infoplists,
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
        visibility = visibility,
        **kwargs
    )

def _ios_emit_xtool_bundle(name, display_name, bundle_id, families, minimum_os_version, version, invalid_version_error, selected_infoplists, actual_launch_storyboard, app_icons, resources, discovered_main_storyboard, runner_srcs, runner_deps, engine_target, entitlements, provisioning_profile, tags, visibility, kwargs):
    """Emits the final xtool iOS bundle target, forwarding only its kwargs."""
    valid_xtool_kwargs = (
        "additional_contents",
        "build_version",
        "certificate",
        "certificate_password",
        "certificate_password_env",
        "certificate_password_file",
        "compatible_with",
        "defines",
        "env",
        "exec_compatible_with",
        "executable",
        "features",
        "require_sdk",
        "restricted_to",
        "short_version",
        "target_compatible_with",
        "testonly",
        "zsign",
    )
    forwarded_kwargs = {k: v for k, v in kwargs.items() if k in valid_xtool_kwargs}
    unsupported_kwargs = [k for k in kwargs if k not in valid_xtool_kwargs]
    _flutter_xtool_ios_bundle(
        name = name,
        app_name = display_name,
        bundle_id = bundle_id,
        families = families,
        minimum_os_version = minimum_os_version,
        version = version,
        invalid_version_error = invalid_version_error,
        infoplists = selected_infoplists,
        launch_storyboard = actual_launch_storyboard,
        app_icons = app_icons if app_icons != None else [],
        srcs = runner_srcs,
        registrant = ":__%s_registrant" % name,
        plugins = [":__%s_apple_plugins" % name],
        deps = runner_deps,
        frameworks = [
            ":__%s_app_framework" % name,
            engine_target,
            ":__%s_native_frameworks" % name,
        ],
        resources = resources + discovered_main_storyboard + ["__%s_privacy_manifests" % name],
        provisioning_profile = provisioning_profile,
        entitlements = entitlements if entitlements != False else None,
        tags = tags,
        visibility = visibility,
        unsupported_kwargs = unsupported_kwargs,
        **forwarded_kwargs
    )

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
        runner_deps = [],
        srcs = None,
        engine = None,
        exclude_plugins = [],
        allow_non_macho = [],
        backend = "rules_apple",
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
        families: Device families (default ["iphone"]; `flutter create` targets iPhone and iPad. An iPhone-only app runs in a small window on iPadOS. Adding "ipad" makes actool reject the 76x76@1x icon in `flutter create`'s icon set, so drop that entry first).
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
        srcs: Override conventional `ios/Runner/*.swift` runner sources.
        engine: Override default `@flutter_ios_engine//:engine` target.
        exclude_plugins: Plugin module names to leave out of the
            registrant. A name that is not a native iOS plugin of the
            application is an error, listing the valid names. iOS-only:
            the Android, Linux, macOS and Windows registrants always
            register every collected native plugin.
        allow_non_macho: Explicit allow-list of binary or framework names
            permitted to bypass Mach-O validation.
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in). Note: `"xtool"` requires a
            user-supplied `darwin.artifactbundle` configured via
            `flutter.darwin_sdk` in compliance with Apple's SDK licensing
            terms; no Apple SDK is downloaded by default.
        **kwargs: Passed through to `ios_application` (or `_flutter_xtool_ios_bundle`
            when `backend = "xtool"`). For `backend = "xtool"` signing with
            `certificate` (`.p12`), pass the password via
            `certificate_password_file` (a file label read at execution time)
            or `certificate_password_env` (an environment variable name read at
            execution time); plain-text `certificate_password` is rejected so
            signing secrets never appear on action command lines. The macro sets
            `bundle_id`, `bundle_name`, `entitlements`, `families`,
            `minimum_os_version`, `infoplists`, `version`,
            `launch_storyboard`, `resources`, `provisioning_profile`,
            `app_icons`, `deps` and `tags` itself, so passing any of those
            here is a duplicate-keyword error — use the named parameter
            instead.
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_ios_app: backend must be 'rules_apple' or 'xtool', got %r" % backend)

    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]
    visibility = kwargs.pop("visibility", None)
    validate_minimum_os_version(
        "flutter_ios_app",
        name,
        minimum_os_version,
        _IOS_MINIMUM_OS_VERSION,
        "iOS",
    )

    module_name = runner_module_name("flutter_ios_app", name)

    # target_compatible_with doesn't work on ios_application (it transitions to
    # iOS platform, so macOS constraints would fail). Users should put
    # target_compatible_with on build_test instead.
    kwargs.pop("target_compatible_with", None)

    # Auto-discover ios/Runner/Runner.entitlements if the user hasn't
    # passed one. Its absence is convention-matching (no-capabilities
    # apps don't have an entitlements file); rules_apple's signing
    # pipeline still injects `get-task-allow=true` for debug builds.
    # `False` ships none although the file exists — see
    # `resolve_ios_entitlements` for the device build that needs it.
    entitlements = _ios_resolve_entitlements(name, entitlements, additional_entitlements, internal_tags)

    # The app icon: the conventional catalog `flutter create` writes, unless
    # the caller named something else. Discovered for the same reason the
    # entitlements and the launch storyboard are — the scaffold is the app's
    # answer until it says otherwise — and leaving it undiscovered meant every
    # Bazel-built Flutter app shipped the generic icon while the sixteen PNGs
    # `flutter create` left behind were read by nothing.
    #
    # `None` means discover, `[]` means ship none: both states are sayable, and
    # an app with no catalog at all is the second without having to write it.
    app_icons = _ios_discover_app_icons(app_icons, backend)

    # -- Internal targets (all __{name}_ prefixed) --

    engine_target = _ios_build_frameworks(name, application, minimum_os_version, allow_non_macho, backend, engine, exclude_plugins, internal_tags)

    _ios_build_native_frameworks(name, application, minimum_os_version, allow_non_macho, internal_tags)

    # 7. Discover runner Swift sources and build swift_library.
    runner_srcs = _ios_discover_runner_srcs(srcs)

    # 7a. Aggregate Apple plugin libraries from the application's transitive
    # FlutterInfo so the runner's swift_library imports + links each pub
    # plugin's Swift module.
    _flutter_apple_plugins_aggregator(
        name = "__%s_apple_plugins" % name,
        application = application,
        platform = "ios",
        tags = internal_tags,
    )

    discovered_main_storyboard = native.glob(["ios/Runner/Base.lproj/Main.storyboard"], allow_empty = True)
    if backend == "rules_apple":
        swift_library(
            name = "__%s_runner" % name,
            srcs = runner_srcs + ["__%s_registrant" % name],
            data = discovered_main_storyboard,
            module_name = module_name,
            tags = internal_tags,
            deps = [
                engine_target,
                "__%s_apple_plugins" % name,
            ] + runner_deps,
        )

    # 8. Info.plist — preprocess to resolve Xcode variables that rules_apple
    #    doesn't handle.
    actual_info_plist = _ios_resolve_info_plist(name, info_plist, module_name, internal_tags)

    # 9. Version — create default apple_bundle_version if not provided (rules_apple),
    #    or resolve/convert apple_bundle_version on xtool without Apple toolchains.
    version, invalid_version_error = _ios_resolve_version(name, backend, version, internal_tags, kwargs)

    # 10. Resolve launch storyboard. On xtool, storyboards discovered in the
    #     conventional `flutter create` layout are forwarded so the rule
    #     reports a named ibtool error rather than silently dropping them.
    actual_launch_storyboard = _ios_resolve_launch_storyboard(launch_storyboard, backend)

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
    # 10b. Dart VM service keys for debug/profile builds — required for the
    #      Flutter engine to register the VM service via mDNS. Matches
    #      flutter_tools' xcode_backend.dart, which only adds them for
    #      non-release configurations.
    selected_infoplists = _ios_dev_infoplists(name, actual_info_plist, internal_tags)

    # 11. Final bundle target — rules_apple (default) or explicit opt-in xtool.
    if backend == "rules_apple":
        _ios_emit_rules_apple_bundle(name, display_name, bundle_id, families, minimum_os_version, version, selected_infoplists, actual_launch_storyboard, app_icons, resources, provisioning_profile, entitlements, tags, visibility, kwargs)
    else:
        _ios_emit_xtool_bundle(name, display_name, bundle_id, families, minimum_os_version, version, invalid_version_error, selected_infoplists, actual_launch_storyboard, app_icons, resources, discovered_main_storyboard, runner_srcs, runner_deps, engine_target, entitlements, provisioning_profile, tags, visibility, kwargs)

def flutter_ios_simulator_build(name, targets, **kwargs):
    """Builds iOS apps for the simulator in debug mode, whatever `-c` says.

    The simulator engine runs only debug builds, so a simulator app built in
    `fastbuild` or `opt` is refused at analysis. This forwards the files of
    `targets` built with `-c dbg`, for anything that needs a simulator bundle
    under a default `bazel test //...`: a `build_test`, or a test that reads
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
