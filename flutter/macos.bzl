"""Flutter rules for macOS desktop builds.

Two tiers of API:

    Tier 1 — flutter_macos_app (self-contained, recommended):

        load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_macos_app(
            name = "my_app_macos",
            application = ":my_app",
            bundle_id = "com.example.myapp",
            app_name = "My App",
        )

    Prerequisites: run `flutter create --platforms=macos .` in your package to
    generate the conventional `macos/Runner/` directory with AppDelegate.swift,
    MainFlutterWindow.swift, MainMenu.xib, and Info.plist.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:macos.bzl",
            "flutter_macos_engine",
            "flutter_macos_app_framework_gen",
            "flutter_macos_info_plist_gen",
            "flutter_macos_menu_xib_gen",
            "flutter_macos_native_libs_gen",
            "flutter_macos_registrant_gen",
            "flutter_macos_runner_lib_gen")

        flutter_macos_app_framework_gen(name = "my_framework", application = ":my_app")
        flutter_macos_registrant_gen(name = "my_registrant", application = ":my_app")
        flutter_macos_engine(name = "my_engine")
        flutter_macos_native_libs_gen(name = "my_native_libs", application = ":my_app")
        flutter_macos_info_plist_gen(name = "my_info_plist", app_name = "My App")
        flutter_macos_menu_xib_gen(name = "my_menu_xib", app_name = "My App")

        flutter_macos_runner_lib_gen(
            name = "my_runner",
            registrant = ":my_registrant",
            engine = ":my_engine",
        )

        macos_application(
            name = "my_macos_app",
            bundle_id = "com.example.myapp",
            additional_contents = {
                ":my_framework": "Frameworks",
                ":my_native_libs": "Frameworks",
            },
            infoplists = [":my_info_plist"],
            resources = [":my_menu_xib"],
            deps = [":my_runner"],
        )
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import")
load("@rules_apple//apple:macos.bzl", "macos_application")
load("@rules_swift//swift:swift.bzl", "swift_library")
load("//flutter/private:app_version.bzl", "version_arg", "version_target_conflict")
load("//flutter/private:apple_app.bzl", "flutter_apple_app")
load("//flutter/private:apple_engine.bzl", _MACOS_ENGINE_FRAMEWORK = "MACOS_ENGINE_FRAMEWORK")
load("//flutter/private:apple_version_check.bzl", _flutter_apple_version_check = "flutter_apple_version_check")
load("//flutter/private:apple_xcframeworks_codesign.bzl", _flutter_apple_xcframeworks_codesign = "flutter_apple_xcframeworks_codesign")
load("//flutter/private:apple_xcframeworks_layout.bzl", "flutter_apple_xcframeworks_layout")
load("//flutter/private:constants.bzl", _MACOS_MINIMUM_OS_VERSION = "MACOS_MINIMUM_OS_VERSION")
load("//flutter/private:flutter_apple_bundle_version.bzl", _flutter_apple_bundle_version = "flutter_apple_bundle_version")
load("//flutter/private:flutter_apple_plugin_library.bzl", _flutter_apple_plugin_library_macro = "flutter_apple_plugin_library")
load("//flutter/private:flutter_apple_plugin_xcframeworks.bzl", _flutter_macos_code_asset_xcframeworks = "flutter_macos_code_asset_xcframeworks", _flutter_macos_plugin_xcframeworks = "flutter_macos_plugin_xcframeworks")
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load("//flutter/private:flutter_apple_registrant.bzl", _flutter_apple_swift_package_registrant = "flutter_apple_swift_package_registrant")
load("//flutter/private:flutter_apple_xcframeworks.bzl", _flutter_macos_app_xcframework = "flutter_macos_app_xcframework", _flutter_macos_engine_xcframework = "flutter_macos_engine_xcframework")
load("//flutter/private:flutter_macos_application.bzl", _flutter_macos_app_framework_rule = "flutter_macos_app_framework", _flutter_macos_native_libs_rule = "flutter_macos_native_libs", _flutter_macos_privacy_manifests_rule = "flutter_macos_privacy_manifests")
load("//flutter/private:flutter_macos_registrant.bzl", _flutter_macos_registrant_rule = "flutter_macos_registrant")
load("//flutter/private:flutter_plist_merge.bzl", _flutter_entitlements_merge = "flutter_entitlements_merge", _flutter_plist_merge = "flutter_plist_merge")
load("//flutter/private:runner_module.bzl", "runner_module_name")
load("//flutter/private:swiftpm_app_settings.bzl", _flutter_apple_app_runner = "flutter_apple_app_runner")
load("//flutter/private:validation.bzl", "validate_minimum_os_version")

# Re-export for user BUILD files.
MACOS_MINIMUM_OS_VERSION = _MACOS_MINIMUM_OS_VERSION

# Add-to-app, for a host app built by Xcode (see README, "Add-to-app"): the
# application's App.xcframework, a copy of Flutter's own engine xcframework, an
# xcframework per plugin and per code asset, in the build mode of the
# configuration.
flutter_macos_app_xcframework = _flutter_macos_app_xcframework
flutter_macos_engine_xcframework = _flutter_macos_engine_xcframework
flutter_macos_plugin_xcframeworks = _flutter_macos_plugin_xcframeworks
flutter_apple_xcframeworks_codesign = _flutter_apple_xcframeworks_codesign
flutter_macos_code_asset_xcframeworks = _flutter_macos_code_asset_xcframeworks

# Merges entitlement additions into a base entitlements file — the additive
# seam rules_apple's single-file `entitlements` attribute does not provide.
# Wired into flutter_macos_app as `additional_entitlements`; exposed for
# Tier 2 users assembling a macos_application themselves.
flutter_entitlements_merge = _flutter_entitlements_merge

# A macOS bundle's version from Flutter's build name and build number: what
# flutter_macos_app's `build_name` and `build_number` declare. Exposed to
# give an app extension the version of its app.
flutter_apple_bundle_version = _flutter_apple_bundle_version

# -- Composable rules (Tier 2) ------------------------------------------------
#
# Like every other *_gen macro in this file, these default to
# `tags = ["manual"]`: the targets are only meaningful as deps of a
# `macos_application` and run Apple-only tooling, so a standalone `//...`
# build (the host platform's configuration) is wrong everywhere and fails outright on
# non-macOS hosts.

def flutter_macos_app_framework_gen(name, **kwargs):
    """Generates App.framework. See `flutter_macos_app_framework`.

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_app_framework_rule(name = name, tags = tags, **kwargs)

def flutter_macos_registrant_gen(name, **kwargs):
    """Generates the macOS GeneratedPluginRegistrant. See `flutter_macos_registrant`.

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_registrant_rule(name = name, tags = tags, **kwargs)

def flutter_macos_native_libs_gen(name, **kwargs):
    """Exposes native dylibs for bundling. See `flutter_macos_native_libs`.

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_native_libs_rule(name = name, tags = tags, **kwargs)

def flutter_macos_privacy_manifests_gen(name, **kwargs):
    """Exposes plugin privacy manifests. See `flutter_macos_privacy_manifests`.

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_privacy_manifests_rule(name = name, tags = tags, **kwargs)

# Public wrapper that compiles a Flutter plugin's macOS Apple sources into a
# swift_library. Use directly to wire a monorepo plugin's BUILD.bazel without
# going through the flutter/ext/ overlay system; for pub.dev plugins, flutter_pub_package
# emits this automatically.
flutter_apple_plugin_library = _flutter_apple_plugin_library_macro

# Aggregates per-plugin Apple swift_libraries from a flutter_application's
# transitive dep graph. Pass to runner_lib_gen `application` to thread plugin
# Swift modules + link inputs into the runner.
flutter_apple_plugins_aggregator = _flutter_apple_plugins_aggregator

def flutter_macos_engine(name, **kwargs):
    """Imports the FlutterMacOS.framework engine for the build mode.

    Debug mode (-c dbg): JIT engine for iterative development.
    Profile mode (-c opt with `//flutter:profile`): AOT engine with the VM
    service, for DevTools.
    Release mode (-c opt / default): AOT engine for production.

    Args:
        name: Target name. Add to swift_library deps for runner.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    apple_dynamic_framework_import(
        name = name,
        framework_imports = _MACOS_ENGINE_FRAMEWORK,
        tags = tags,
        **kwargs
    )

def flutter_macos_info_plist_gen(name, app_name, **kwargs):
    """Generates a macOS Info.plist from the default Bazel template.

    As in `flutter create`'s, the version keys are `$(FLUTTER_BUILD_NAME)`
    and `$(FLUTTER_BUILD_NUMBER)`, which the app's `version` replaces: give
    the `macos_application` a `flutter_apple_bundle_version` with the same
    `application`, so the bundle carries the version the program reports.
    Without a `version`, rules_apple fails on the unknown variables.

    Args:
        name: Target name. Pass to macos_application infoplists.
        app_name: Display name (CFBundleDisplayName, CFBundleName).
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    expand_template(
        name = name,
        template = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        out = name + "/Info.plist",
        substitutions = {"APP_NAME": app_name},
        tags = tags,
        **kwargs
    )

def flutter_macos_menu_xib_gen(name, app_name, **kwargs):
    """Generates a MainMenu.xib from the default Bazel template.

    Args:
        name: Target name. Pass to macos_application resources.
        app_name: Display name shown in the menu bar.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    expand_template(
        name = name,
        template = "@rules_flutter//flutter/private/runners/macos:MainMenu.xib",
        out = name + "/MainMenu.xib",
        substitutions = {"APP_NAME": app_name},
        tags = tags,
        **kwargs
    )

def flutter_macos_runner_lib_gen(name, registrant, engine, application = None, module_name = "Runner", info_plist = None, swift_package_environment = {}, **kwargs):
    """Generates a swift_library for the default macOS runner.

    Uses template AppDelegate.swift and MainFlutterWindow.swift from
    rules_flutter. This replaces `flutter create --platforms=macos` output
    for users who don't need custom runner files.

    When `application` is set, an internal flutter_apple_plugins_aggregator
    target is created and added to the runner's `swift_library.deps` so the
    generated registrant's `import <PluginModule>` lines resolve and the
    linker pulls in each transitive plugin's static archive. `name` is then
    that library built in the app's configuration, with its plugins
    (`flutter_apple_app_runner`).

    Args:
        name: Target name. Add to macos_application deps.
        registrant: A flutter_macos_registrant_gen target (Swift source).
        engine: A flutter_macos_engine target (FlutterMacOS.framework).
        application: A flutter_application target. Required to wire pub
            plugins' macOS Swift modules + link inputs into the runner;
            optional only for legacy Tier-2 setups with no native plugins.
        module_name: Swift module name (default "Runner").
        info_plist: The app's Info.plist, which a plugin whose Package.swift
            decides its defines from the app reads (`flutter_macos_app`'s
            `swift_package_environment`). Unset, such a manifest sees an
            empty one.
        swift_package_environment: As `flutter_macos_app`'s.
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
            platform = "macos",
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
            "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
        ],
        module_name = module_name,
        tags = tags,
        deps = deps,
        **kwargs
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_macos_app(
        name,
        application,
        bundle_id,
        app_name = None,
        minimum_os_version = MACOS_MINIMUM_OS_VERSION,
        info_plist = None,
        version = None,
        build_name = None,
        build_number = None,
        additional_contents = {},
        entitlements = None,
        additional_entitlements = [],
        app_icons = None,
        resources = [],
        runner_deps = [],
        swift_package_environment = {},
        **kwargs):
    """Builds a Flutter macOS .app bundle from a flutter_application target.

    Discovers runner files from the conventional `macos/Runner/` directory
    (as generated by `flutter create --platforms=macos .`) and wires up all
    internal targets automatically.

    Prerequisites — the package must contain:
        - `macos/Runner/*.swift` (AppDelegate, MainFlutterWindow, etc.)
        - `macos/Runner/Base.lproj/MainMenu.xib`
        - `macos/Runner/Info.plist`
        - `macos/Runner/DebugProfile.entitlements`, `Release.entitlements`
    Generate these with: `flutter create --platforms=macos .`

    Entitlements differ between debug and release, and that is a property of
    the `flutter create` scaffold rather than of these rules. `flutter
    create` writes `com.apple.security.network.server` and
    `com.apple.security.cs.allow-jit` into **DebugProfile.entitlements
    only**; `Release.entitlements` declares nothing but
    `com.apple.security.app-sandbox`. The macro selects between the two by
    compilation mode, so a sandboxed `-c opt` bundle has neither
    `network.server` nor `network.client` — the sandbox denies the socket
    with no build error and no runtime exception, and a networked app simply
    finds no peers. (`network.client` is absent from *both* files: most
    Flutter apps network through `NSURLSession`, which the sandbox exempts.
    A raw socket is not exempt.)

    Use `additional_entitlements` for any capability the app itself needs:
    additions are merged into whichever base the compilation mode selected,
    so one declaration covers both. Reach for `entitlements` only to replace
    the selection wholesale.

    Args:
        name: Target name (Bazel identifier). The runner's Swift module name
            is derived from it, so it must be a bare Swift identifier.
        application: A flutter_application target (required).
        bundle_id: CFBundleIdentifier (required — rules_apple constraint).
        app_name: User-facing display name (menu bar, window title). Defaults to name.
        minimum_os_version: Minimum macOS version.
        info_plist: Override conventional macos/Runner/Info.plist.
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
        additional_contents: Extra content for the bundle (merged with Flutter defaults).
        entitlements: Override entitlements wiring. By default the macro
            auto-discovers `macos/Runner/{DebugProfile,Release}.entitlements`
            (both files are required when this attribute is unset; their
            absence indicates a misconfigured runner). Pass a label to
            override, or a `select()` literal to control per-config
            selection yourself.
        additional_entitlements: Entitlement plist files merged into the
            base entitlements in **every** compilation mode — the additive
            seam for an app that needs one more `com.apple.security.*` key
            without taking over the `flutter create` files. A key the base
            already declares with the same value is deduped; a different
            value is a hard error naming the key and both files. Compose
            `flutter_entitlements_merge` directly for anything more.
        app_icons: The app icon, as the files of an `.appiconset` or of an
            Icon Composer `.icon` bundle. Defaults to the conventional
            `macos/Runner/Assets.xcassets/AppIcon.appiconset` that
            `flutter create` writes — so an app that has never thought about
            this ships the icon it already has on disk, which is what
            `flutter build macos` does with the same tree. Pass a list to
            name a different one; pass `[]` to ship no icon. rules_apple
            refuses an `.appiconset` and a `.icon` bundle together, so name
            exactly one.
            Discovery is per-platform and its absence is silent: a tree
            that only ever ran `flutter create --platforms=ios .` has no
            catalog here, and an app with neither a catalog nor an
            `app_icons` has said nothing either way, so it ships no icon and
            there is nothing to report.
        resources: Extra resources. MainMenu.xib is wired separately, through
            the runner library, so that ibtool resolves its Swift classes
            against the runner's module. Resources passed here are compiled
            against the app target's name instead, which is not a module any
            target produces — so a XIB listed here cannot reference the
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
        **kwargs: Passed through to macos_application, except `target_compatible_with`
            and `visibility`, which are the named target's, and `testonly`, which
            every target the macro declares has, since one that depends on a
            `testonly` application would otherwise fail analysis. The app is
            compatible with macOS only, whatever `target_compatible_with`
            adds, so `bazel build //...` skips it on any other platform.
            `tags` defaults to `["manual"]`, so `bazel build //...` skips
            the app and every target the macro declares for it; pass `tags`
            to replace that on all of them. The macro sets `app_icons`
            itself, so pass the named parameter instead.
    """
    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])
    conflict = version_target_conflict(
        "flutter_macos_app(name = %r)" % name,
        version,
        build_name,
        build_number,
    )
    if conflict:
        fail(conflict)

    # `target_compatible_with` and what decides who can see the app belong to
    # the target the user names (see `flutter_apple_app`), not to the
    # `macos_application` behind it.
    target_compatible_with = kwargs.pop("target_compatible_with", [])
    visibility = kwargs.pop("visibility", None)
    testonly = kwargs.pop("testonly", False)
    validate_minimum_os_version(
        "flutter_macos_app",
        name,
        minimum_os_version,
        _MACOS_MINIMUM_OS_VERSION,
        "macOS",
    )

    module_name = runner_module_name("flutter_macos_app", name)

    # Auto-discover the conventional entitlements pair. flutter create
    # always emits both files; treat their absence as an error rather
    # than a "ship without entitlements" fallback. Without entitlements
    # the bundle is adhoc-signed unsandboxed and
    # `getApplicationDocumentsDirectory()` resolves to ~/Documents
    # instead of ~/Library/Containers/<bundle-id>/Data/Documents,
    # diverging from `flutter build macos`.
    if entitlements == None:
        # `allow_empty`: an absent file is reported below, naming it.
        debug_present = native.glob(
            ["macos/Runner/DebugProfile.entitlements"],
            allow_empty = True,
        )
        release_present = native.glob(
            ["macos/Runner/Release.entitlements"],
            allow_empty = True,
        )
        if debug_present and release_present:
            entitlements = select({
                Label("@rules_flutter//flutter/private:dbg"): "macos/Runner/DebugProfile.entitlements",
                # The Xcode project `flutter create` writes signs Profile with
                # these too: the VM service needs `network.server`.
                Label("@rules_flutter//flutter/private:profile"): "macos/Runner/DebugProfile.entitlements",
                "//conditions:default": "macos/Runner/Release.entitlements",
            })
        elif debug_present or release_present:
            fail(
                "flutter_macos_app(name = %r): found one of " % name +
                "macos/Runner/DebugProfile.entitlements / " +
                "Release.entitlements but not both. " +
                "Provide both (run `flutter create --platforms=macos .`) " +
                "or pass `entitlements = ` explicitly.",
            )
        else:
            fail(
                "flutter_macos_app(name = %r): no entitlements file " % name +
                "found. Expected " +
                "macos/Runner/DebugProfile.entitlements and " +
                "Release.entitlements (generated by " +
                "`flutter create --platforms=macos .`), " +
                "or pass `entitlements = ` explicitly.",
            )

    # Fold the app's own entitlement additions into whichever base the
    # compilation mode selected. One declaration, both configurations —
    # the point being that a capability the app needs is not something the
    # release build should silently lose.
    if additional_entitlements:
        _flutter_entitlements_merge(
            name = "__%s_entitlements" % name,
            base = entitlements,
            additions = additional_entitlements,
            tags = tags,
            testonly = testonly,
        )
        entitlements = "__%s_entitlements" % name

    # -- Internal targets (all __{name}_ prefixed) --

    # 1. Generate macOS Swift plugin registrant.
    _flutter_macos_registrant_rule(
        name = "__%s_registrant" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )

    # 2. Assemble App.framework (flat layout with the AOT binary + flutter_assets).
    _flutter_macos_app_framework_rule(
        name = "__%s_app_framework" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )

    # 3. Expose native plugin .dylib files for bundling.
    _flutter_macos_native_libs_rule(
        name = "__%s_native_libs" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )

    # 3b. Expose plugin PrivacyInfo.xcprivacy files for bundling.
    _flutter_macos_privacy_manifests_rule(
        name = "__%s_privacy_manifests" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )

    # 4. Import FlutterMacOS.framework engine — follows the build mode.
    apple_dynamic_framework_import(
        name = "__%s_engine" % name,
        framework_imports = _MACOS_ENGINE_FRAMEWORK,
        tags = tags,
        testonly = testonly,
    )

    # 5. Discover runner Swift sources and build swift_library.
    runner_srcs = native.glob(["macos/Runner/*.swift"])
    if not runner_srcs:
        fail("No Swift sources found in macos/Runner/. " +
             "Run 'flutter create --platforms=macos .' to generate runner files.")

    # 5b. Aggregate Apple plugin libraries from the application's transitive
    # FlutterInfo so the runner's swift_library imports + links each pub
    # plugin's Swift module.
    # A plugin whose Package.swift decides its defines from the app reads the
    # Info.plist the app is built from: the app's own, before the icon step
    # below, which only drops an empty key.
    _flutter_apple_plugins_aggregator(
        name = "__%s_apple_plugins" % name,
        application = application,
        info_plist = info_plist or "__%s_info_plist" % name,
        platform = "macos",
        swift_package_environment = swift_package_environment,
        tags = tags,
        testonly = testonly,
    )

    # 6. XIB — substitute APP_NAME and keep the NIB's module in sync.
    #
    #    The runner's Swift classes (MainFlutterWindow, AppDelegate) carry no
    #    @objc annotation in `flutter create` output, so their Objective-C
    #    runtime names are Swift-mangled and module-qualified
    #    (_TtC<n><module>17MainFlutterWindow). The XIB names them via
    #    customClass/customModule. If the module baked into the NIB does not
    #    match the module the classes were compiled into, AppKit silently
    #    instantiates a plain NSWindow — blank window, no error.
    #
    #    Two mechanisms keep the two sides together:
    #
    #    a) customModuleProvider="target" (what `flutter create` emits) tells
    #       ibtool to use the module of the target being built. rules_apple
    #       derives that from the resource's owner: a XIB reached through a
    #       swift_library's `data` is bucketed with that library's own
    #       module_name (resource_aspect.bzl), so attaching the XIB to
    #       __<name>_runner below makes ibtool's --module follow the runner
    #       structurally, with no name to keep in sync by hand.
    #
    #    b) Rewriting the literal customModule covers XIBs that dropped the
    #       provider attribute and hardcode customModule="Runner". Harmless
    #       when the provider is present, since the provider wins.
    expand_template(
        name = "__%s_menu_xib" % name,
        template = "macos/Runner/Base.lproj/MainMenu.xib",
        out = "__%s/Base.lproj/MainMenu.xib" % name,
        substitutions = {
            "APP_NAME": display_name,
            "customModule=\"Runner\"": "customModule=\"%s\"" % module_name,
        },
        tags = tags,
        testonly = testonly,
    )

    swift_library(
        name = "__%s_runner" % name,
        srcs = runner_srcs + ["__%s_registrant" % name],
        data = ["__%s_menu_xib" % name],
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
        info_plist = info_plist or "__%s_info_plist" % name,
        swift_package_environment = swift_package_environment,
        tags = tags,
        testonly = testonly,
    )

    # 6b. App icon — the conventional catalog `flutter create` writes, unless
    #     the caller named something else. Discovered for the same reason the
    #     entitlements and the launch storyboard are: the scaffold is the app's
    #     answer until it says otherwise, and leaving this one undiscovered
    #     meant every Bazel-built Flutter app shipped the generic icon while
    #     sixteen PNGs sat in the tree that nothing read.
    #
    #     `None` means discover, `[]` means ship none: both states are sayable,
    #     and an app with no catalog at all is the second without having to
    #     write it.
    if app_icons == None:
        # `allow_empty`: an app with no catalog ships the generic icon.
        app_icons = native.glob(
            ["macos/Runner/Assets.xcassets/AppIcon.appiconset/**"],
            allow_empty = True,
        )

    # 7. Info.plist — preprocess to resolve Xcode variables that rules_apple
    #    doesn't handle (PRODUCT_COPYRIGHT, DEVELOPMENT_LANGUAGE).
    #    $(FLUTTER_BUILD_NAME) and $(FLUTTER_BUILD_NUMBER) stay: rules_apple
    #    replaces both keys with `version`'s values.
    if not info_plist:
        # A merge rather than a text template: the app's plist may be saved
        # in binary form, which a text substitution would corrupt.
        _flutter_plist_merge(
            name = "__%s_info_plist" % name,
            base = "macos/Runner/Info.plist",
            mode = "supplement",
            output_basename = "Info.plist",
            substitutions = {
                "$(DEVELOPMENT_LANGUAGE)": "en",
                "$(PRODUCT_COPYRIGHT)": "",
            },
            tags = tags,
            # Not `testonly` even in a testonly app: the plugins whose
            # Package.swift reads the app read it (`swift_package_environment`),
            # and they are not. It depends on nothing that is.
        )
        actual_info_plist = "__%s_info_plist" % name
    else:
        actual_info_plist = info_plist

    # 7a. Version, from `build_name` and `build_number` unless the app names
    #     its own.
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

    # 7b. The plist leaves the version keys to the version: rules_apple
    #     replaces both, so a literal that differs would be dropped silently.
    #     And the version is the application's, which the program reports.
    _flutter_apple_version_check(
        name = "__%s_version_check" % name,
        plist = actual_info_plist,
        plist_name = "macos/Runner/Info.plist" if not info_plist else "",
        app_label = str(native.package_relative_label(name)),
        application = application,
        version = version,
        rule_name = "flutter_macos_app",
        tags = tags,
        testonly = testonly,
    )

    # 7c. Drop the scaffold's empty `CFBundleIconFile`.
    #
    #     `flutter create` writes it as `<string></string>` for Xcode to fill
    #     in. Nothing fills it in here, and `macos_application` generates its
    #     own `CFBundleIconFile` from the icon catalog — so with an app icon
    #     the two disagree and plisttool refuses the build outright:
    #     `found key "CFBundleIconFile" in two plists with different values:
    #     "" != "AppIcon"`. Every `flutter create` app hits that, which is why
    #     it is handled here rather than left for each app to discover.
    #
    #     Only when there is an icon, and only when the value is empty: a plist
    #     that names a real icon file still conflicts, and still says so.
    if app_icons:
        _flutter_plist_merge(
            name = "__%s_info_plist_icon" % name,
            base = actual_info_plist,
            additions = [],
            drop_empty_keys = ["CFBundleIconFile"],
            mode = "supplement",
            output_basename = "Info.plist",
            tags = tags,
            testonly = testonly,
        )
        actual_info_plist = "__%s_info_plist_icon" % name

    # 8. Assemble Flutter additional_contents.
    flutter_contents = {
        "__%s_app_framework" % name: "Frameworks",
        "__%s_native_libs" % name: "Frameworks",
        "__%s_privacy_manifests" % name: "Resources",
    }
    flutter_contents.update(additional_contents)

    # 9. Final macos_application, behind the target the user names.
    macos_application(
        name = "__%s_app" % name,
        bundle_id = bundle_id,
        bundle_name = display_name,
        minimum_os_version = minimum_os_version,
        infoplists = [actual_info_plist],
        version = version,
        app_icons = app_icons,
        resources = resources,
        additional_contents = flutter_contents,
        entitlements = entitlements,
        deps = ["__%s_app_runner" % name],
        tags = tags,
        testonly = testonly,
        **kwargs
    )

    # 10. The target the user names: carries the compatibility constraints (see
    # `flutter_apple_app`). A macOS app is for a Mac.
    flutter_apple_app(
        name = name,
        app = "__%s_app" % name,
        validations = ["__%s_version_check" % name],
        tags = tags,
        target_compatible_with = target_compatible_with + select({
            "@platforms//os:macos": [],
            "//conditions:default": ["@platforms//:incompatible"],
        }),
        testonly = testonly,
        visibility = visibility,
    )

def flutter_macos_xcframeworks(
        name,
        application,
        plugins = True,
        static_plugins = False,
        codesign_identity = None,
        minimum_os_version = MACOS_MINIMUM_OS_VERSION,
        **kwargs):
    """The xcframeworks a host app built by Xcode embeds Flutter with, as `flutter build macos-framework` makes them.

    `bazel build` makes the build mode of the configuration (`-c dbg` Debug,
    `-c opt --@rules_flutter//flutter:profile` Profile, otherwise Release) as
    `<name>/<Mode>/`: App.xcframework, a copy of Flutter's own engine
    xcframework, an xcframework per plugin and per code asset,
    and `GeneratedPluginRegistrant.swift` above the modes, to copy into
    the host,
    as upstream lays them out. `bazel run` writes that to
    `build/macos/framework/` in the package (`-- --output=<dir>` elsewhere),
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
        minimum_os_version: The minimum macOS version of the frameworks.
        **kwargs: `visibility`, `tags` and the like, for `name`.
    """
    internal_tags = kwargs.get("tags", []) + ["manual"]
    _flutter_macos_app_xcframework(
        name = "_%s_app" % name,
        application = application,
        minimum_os_version = minimum_os_version,
        tags = internal_tags,
    )
    _flutter_macos_engine_xcframework(
        name = "_%s_engine" % name,
        tags = internal_tags,
    )
    _flutter_macos_code_asset_xcframeworks(
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
    renamed = {}
    if plugins:
        _flutter_macos_plugin_xcframeworks(
            name = "_%s_plugins" % name,
            application = application,
            minimum_os_version = minimum_os_version,
            static = static_plugins,
            tags = internal_tags,
        )
        _flutter_macos_registrant_rule(
            name = "_%s_registrant" % name,
            application = application,
            tags = internal_tags,
        )
        xcframeworks.append("_%s_plugins" % name)
        renamed[":_%s_registrant" % name] = "GeneratedPluginRegistrant.swift"
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
        platform = "macos",
        register_plugins = plugins,
        tags = internal_tags,
    )
    flutter_apple_xcframeworks_layout(
        name = layout,
        platform = "macos",
        swift_package_registrant = "_%s_swift_package_registrant" % name,
        minimum_os_version = minimum_os_version,
        xcframeworks = xcframeworks,
        renamed_files = renamed,
        debug_files = [],
        **kwargs
    )
