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
            "flutter_macos_framework_gen",
            "flutter_macos_info_plist_gen",
            "flutter_macos_menu_xib_gen",
            "flutter_macos_native_libs_gen",
            "flutter_macos_registrant_gen",
            "flutter_macos_runner_lib_gen")

        flutter_macos_framework_gen(name = "my_framework", application = ":my_app")
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
load("@rules_apple//apple:versioning.bzl", "apple_bundle_version")
load("@rules_swift//swift:swift.bzl", "swift_library")
load("//flutter/private:constants.bzl", _MACOS_MINIMUM_OS_VERSION = "MACOS_MINIMUM_OS_VERSION")
load("//flutter/private:flutter_apple_plugin_library.bzl", _flutter_apple_plugin_library_macro = "flutter_apple_plugin_library")
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load("//flutter/private:flutter_macos_application.bzl", _flutter_macos_framework_rule = "flutter_macos_framework", _flutter_macos_native_libs_rule = "flutter_macos_native_libs", _flutter_macos_privacy_manifests_rule = "flutter_macos_privacy_manifests")
load("//flutter/private:flutter_macos_registrant.bzl", _flutter_macos_registrant_rule = "flutter_macos_registrant")

# Re-export for user BUILD files.
MACOS_MINIMUM_OS_VERSION = _MACOS_MINIMUM_OS_VERSION

# -- Composable rules (Tier 2) ------------------------------------------------

flutter_macos_framework_gen = _flutter_macos_framework_rule
flutter_macos_registrant_gen = _flutter_macos_registrant_rule
flutter_macos_native_libs_gen = _flutter_macos_native_libs_rule
flutter_macos_privacy_manifests_gen = _flutter_macos_privacy_manifests_rule

# Public wrapper that compiles a Flutter plugin's macOS Apple sources into a
# swift_library. Use directly to wire a monorepo plugin's BUILD.bazel without
# going through the ext/ overlay system; for pub.dev plugins, flutter_pub_package
# emits this automatically.
flutter_apple_plugin_library = _flutter_apple_plugin_library_macro

# Aggregates per-plugin Apple swift_libraries from a flutter_application's
# transitive dep graph. Pass to runner_lib_gen `application` to thread plugin
# Swift modules + link inputs into the runner.
flutter_apple_plugins_aggregator = _flutter_apple_plugins_aggregator

def flutter_macos_engine(name, **kwargs):
    """Imports the FlutterMacOS.framework engine, auto-selecting debug or release.

    Debug mode (-c dbg): JIT engine for iterative development.
    Release mode (-c opt / default): AOT engine for production.

    Args:
        name: Target name. Add to swift_library deps for runner.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    apple_dynamic_framework_import(
        name = name,
        framework_imports = select({
            "@rules_flutter//flutter/private:dbg": ["@flutter_macos_engine//:engine_debug_library"],
            "//conditions:default": ["@flutter_macos_engine//:engine_library"],
        }),
        tags = tags,
        **kwargs
    )

def flutter_macos_info_plist_gen(name, app_name, **kwargs):
    """Generates a macOS Info.plist from the default Bazel template.

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

def flutter_macos_runner_lib_gen(name, registrant, engine, application = None, module_name = "Runner", **kwargs):
    """Generates a swift_library for the default macOS runner.

    Uses template AppDelegate.swift and MainFlutterWindow.swift from
    rules_flutter. This replaces `flutter create --platforms=macos` output
    for users who don't need custom runner files.

    When `application` is set, an internal flutter_apple_plugins_aggregator
    target is created and added to the runner's `swift_library.deps` so the
    generated registrant's `import <PluginModule>` lines resolve and the
    linker pulls in each transitive plugin's static archive.

    Args:
        name: Target name. Add to macos_application deps.
        registrant: A flutter_macos_registrant_gen target (Swift source).
        engine: A flutter_macos_engine target (FlutterMacOS.framework).
        application: A flutter_application target. Required to wire pub
            plugins' macOS Swift modules + link inputs into the runner;
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
            platform = "macos",
            tags = tags,
            visibility = ["//visibility:private"],
        )
        deps.append(":" + aggregator_name)

    swift_library(
        name = name,
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
        additional_contents = {},
        entitlements = None,
        resources = [],
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

    Args:
        name: Target name (Bazel identifier).
        application: A flutter_application target (required).
        bundle_id: CFBundleIdentifier (required — rules_apple constraint).
        app_name: User-facing display name (menu bar, window title). Defaults to name.
        minimum_os_version: Minimum macOS version.
        info_plist: Override conventional macos/Runner/Info.plist.
        version: An apple_bundle_version target. Defaults to "1.0".
        additional_contents: Extra content for the bundle (merged with Flutter defaults).
        entitlements: Override entitlements wiring. By default the macro
            auto-discovers `macos/Runner/{DebugProfile,Release}.entitlements`
            (both files are required when this attribute is unset; their
            absence indicates a misconfigured runner). Pass a label to
            override, or a `select()` literal to control per-config
            selection yourself.
        resources: Extra resources (merged with MainMenu.xib).
        **kwargs: Passed through to macos_application.
    """
    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])

    # Auto-discover the conventional entitlements pair. flutter create
    # always emits both files; treat their absence as an error rather
    # than a "ship without entitlements" fallback. Without entitlements
    # the bundle is adhoc-signed unsandboxed and
    # `getApplicationDocumentsDirectory()` resolves to ~/Documents
    # instead of ~/Library/Containers/<bundle-id>/Data/Documents,
    # diverging from `flutter build macos`.
    if entitlements == None:
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
                "@rules_flutter//flutter/private:dbg": "macos/Runner/DebugProfile.entitlements",
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

    # -- Internal targets (all __{name}_ prefixed) --

    # 1. Generate macOS Swift plugin registrant.
    _flutter_macos_registrant_rule(
        name = "__%s_registrant" % name,
        application = application,
        tags = tags,
    )

    # 2. Assemble App.framework (versioned layout with AOT dylib + flutter_assets).
    _flutter_macos_framework_rule(
        name = "__%s_app_framework" % name,
        application = application,
        tags = tags,
    )

    # 3. Expose native plugin .dylib files for bundling.
    _flutter_macos_native_libs_rule(
        name = "__%s_native_libs" % name,
        application = application,
        tags = tags,
    )

    # 3b. Expose plugin PrivacyInfo.xcprivacy files for bundling.
    _flutter_macos_privacy_manifests_rule(
        name = "__%s_privacy_manifests" % name,
        application = application,
        tags = tags,
    )

    # 4. Import FlutterMacOS.framework engine — auto-select debug/release.
    apple_dynamic_framework_import(
        name = "__%s_engine" % name,
        framework_imports = select({
            "@rules_flutter//flutter/private:dbg": ["@flutter_macos_engine//:engine_debug_library"],
            "//conditions:default": ["@flutter_macos_engine//:engine_library"],
        }),
        tags = tags,
    )

    # 5. Discover runner Swift sources and build swift_library.
    runner_srcs = native.glob(["macos/Runner/*.swift"])
    if not runner_srcs:
        fail("No Swift sources found in macos/Runner/. " +
             "Run 'flutter create --platforms=macos .' to generate runner files.")

    # 5b. Aggregate Apple plugin libraries from the application's transitive
    # FlutterInfo so the runner's swift_library imports + links each pub
    # plugin's Swift module.
    _flutter_apple_plugins_aggregator(
        name = "__%s_apple_plugins" % name,
        application = application,
        platform = "macos",
        tags = tags,
    )

    swift_library(
        name = "__%s_runner" % name,
        srcs = runner_srcs + ["__%s_registrant" % name],
        module_name = "Runner",
        tags = tags,
        deps = [
            "__%s_engine" % name,
            "__%s_apple_plugins" % name,
        ],
    )

    # 6. XIB — substitute APP_NAME and fix Swift module resolution.
    #
    #    Flutter's XIB templates (from `flutter create`) set
    #    customModuleProvider="target" on custom classes like MainFlutterWindow
    #    and AppDelegate. This tells ibtool to embed the build target's module
    #    name in the compiled NIB's Swift class mangling (e.g.
    #    _TtC17hello_world_macos17MainFlutterWindow).
    #
    #    rules_apple passes `--module <target_name>` to ibtool, where the
    #    module name is always derived from the macos_application rule's label
    #    name (via resources_support.bzl: `swift_module = swift_module or
    #    rule_label.name`). There is no public attribute to override this.
    #
    #    Since the runner swift_library uses module_name = "Runner" (matching
    #    Xcode convention), the ibtool module ("hello_world_macos") won't
    #    match, and the NIB's class lookup silently falls back to NSWindow —
    #    no FlutterViewController is created, and the UI is blank.
    #
    #    Fix: strip customModuleProvider="target" so ibtool uses the explicit
    #    customModule="Runner" already present in the XIB.
    expand_template(
        name = "__%s_menu_xib" % name,
        template = "macos/Runner/Base.lproj/MainMenu.xib",
        out = "__%s/Base.lproj/MainMenu.xib" % name,
        substitutions = {
            "APP_NAME": display_name,
            " customModuleProvider=\"target\"": "",
        },
        tags = tags,
    )

    # 7. Info.plist — preprocess to resolve Xcode variables that rules_apple
    #    doesn't handle (PRODUCT_COPYRIGHT, DEVELOPMENT_LANGUAGE).
    if not info_plist:
        expand_template(
            name = "__%s_info_plist" % name,
            template = "macos/Runner/Info.plist",
            out = "__%s_Info.plist" % name,
            substitutions = {
                "$(DEVELOPMENT_LANGUAGE)": "en",
                "$(PRODUCT_COPYRIGHT)": "",
            },
            tags = tags,
        )
        actual_info_plist = "__%s_info_plist" % name
    else:
        actual_info_plist = info_plist

    # 8. Version — create default apple_bundle_version if not provided.
    if not version:
        apple_bundle_version(
            name = "__%s_version" % name,
            build_version = "1.0",
            short_version_string = "1.0",
            tags = tags,
        )
        version = ":%s" % ("__%s_version" % name)

    # 9. Assemble Flutter additional_contents.
    flutter_contents = {
        "__%s_app_framework" % name: "Frameworks",
        "__%s_native_libs" % name: "Frameworks",
        "__%s_privacy_manifests" % name: "Resources",
    }
    flutter_contents.update(additional_contents)

    # 10. Final macos_application.
    macos_application(
        name = name,
        bundle_id = bundle_id,
        bundle_name = display_name,
        minimum_os_version = minimum_os_version,
        infoplists = [actual_info_plist],
        version = version,
        resources = ["__%s_menu_xib" % name] + resources,
        additional_contents = flutter_contents,
        entitlements = entitlements,
        deps = ["__%s_runner" % name],
        tags = tags,
        **kwargs
    )
