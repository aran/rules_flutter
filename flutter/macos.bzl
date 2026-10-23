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
load("//flutter/private:flutter_apple_plugin_library.bzl", _flutter_apple_plugin_library_macro = "flutter_apple_plugin_library", _flutter_xtool_apple_plugin_library = "flutter_xtool_apple_plugin_library")
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load("//flutter/private:flutter_macos_application.bzl", _flutter_macos_framework_rule = "flutter_macos_framework", _flutter_macos_native_libs_rule = "flutter_macos_native_libs", _flutter_macos_privacy_manifests_rule = "flutter_macos_privacy_manifests")
load("//flutter/private:flutter_macos_registrant.bzl", _flutter_macos_registrant_rule = "flutter_macos_registrant")
load("//flutter/private:flutter_plist_merge.bzl", _flutter_entitlements_merge = "flutter_entitlements_merge", _flutter_plist_merge = "flutter_plist_merge")
load("//flutter/private:flutter_xtool_bundle.bzl", _flutter_darwin_xcframework_import = "flutter_darwin_xcframework_import", _flutter_xtool_bundle_version = "flutter_xtool_bundle_version", _flutter_xtool_macos_bundle = "flutter_xtool_macos_bundle", _resolve_xtool_version = "resolve_xtool_version")
load("//flutter/private:runner_module.bzl", "runner_module_name")
load("//flutter/private:validation.bzl", "validate_minimum_os_version")

# Re-export for user BUILD files.
MACOS_MINIMUM_OS_VERSION = _MACOS_MINIMUM_OS_VERSION

# Merges entitlement additions into a base entitlements file — the additive
# seam rules_apple's single-file `entitlements` attribute does not provide.
# Wired into flutter_macos_app as `additional_entitlements`; exposed for
# Tier 2 users assembling a macos_application themselves.
flutter_entitlements_merge = _flutter_entitlements_merge

# Host-agnostic xtool framework import, versioning, and macOS bundle rules.
flutter_darwin_xcframework_import = _flutter_darwin_xcframework_import
flutter_xtool_bundle_version = _flutter_xtool_bundle_version
flutter_xtool_macos_bundle = _flutter_xtool_macos_bundle

def _engine_framework_select():
    """Selects FlutterMacOS.framework for the build mode: debug, profile or release."""
    return select({
        Label("@rules_flutter//flutter/private:dbg"): [Label("@flutter_macos_engine//:engine_debug_library")],
        Label("@rules_flutter//flutter/private:profile"): [Label("@flutter_macos_engine//:engine_profile_library")],
        "//conditions:default": [Label("@flutter_macos_engine//:engine_library")],
    })

# -- Composable rules (Tier 2) ------------------------------------------------
#
# Like every other *_gen macro in this file, these default to
# `tags = ["manual"]`: the targets are only meaningful as deps of a
# `macos_application` and run Apple-only tooling, so a standalone `//...`
# build (host configuration) is wrong everywhere and fails outright on
# non-macOS hosts.

def flutter_macos_framework_gen(name, minimum_os_version = MACOS_MINIMUM_OS_VERSION, **kwargs):
    """Generates App.framework. See `flutter_macos_framework`.

    Args:
        name: Target name.
        minimum_os_version: Minimum macOS deployment target.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_framework_rule(
        name = name,
        minimum_os_version = minimum_os_version,
        tags = tags,
        **kwargs
    )

def flutter_macos_registrant_gen(name, **kwargs):
    """Generates the macOS GeneratedPluginRegistrant. See `flutter_macos_registrant`.

    Args:
        name: Target name.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_registrant_rule(name = name, tags = tags, **kwargs)

def flutter_macos_native_libs_gen(name, minimum_os_version = MACOS_MINIMUM_OS_VERSION, **kwargs):
    """Exposes native dylibs for bundling. See `flutter_macos_native_libs`.

    Args:
        name: Target name.
        minimum_os_version: Minimum macOS deployment target.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_native_libs_rule(
        name = name,
        minimum_os_version = minimum_os_version,
        tags = tags,
        **kwargs
    )

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
# going through the ext/ overlay system; for pub.dev plugins, flutter_pub_package
# emits this automatically.
flutter_apple_plugin_library = _flutter_apple_plugin_library_macro

# Aggregates per-plugin Apple swift_libraries from a flutter_application's
# transitive dep graph. Pass to runner_lib_gen `application` to thread plugin
# Swift modules + link inputs into the runner.
flutter_apple_plugins_aggregator = _flutter_apple_plugins_aggregator

def flutter_macos_engine(name, backend = "rules_apple", **kwargs):
    """Imports the FlutterMacOS.framework engine for the build mode.

    Debug mode (-c dbg): JIT engine for iterative development.
    Profile mode (-c opt with `//flutter:profile`): AOT engine with the VM
    service, for DevTools.
    Release mode (-c opt / default): AOT engine for production.

    Args:
        name: Target name. Add to swift_library deps for runner.
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_macos_engine: backend must be 'rules_apple' or 'xtool', got %r" % backend)
    tags = kwargs.pop("tags", ["manual"])

    if backend == "rules_apple":
        apple_dynamic_framework_import(
            name = name,
            framework_imports = _engine_framework_select(),
            tags = tags,
            **kwargs
        )
    else:
        _flutter_darwin_xcframework_import(
            name = name,
            framework_name = "FlutterMacOS",
            xcframework_imports = _engine_framework_select(),
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

def flutter_macos_runner_lib_gen(name, registrant, engine, application = None, module_name = "Runner", backend = "rules_apple", **kwargs):
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
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        **kwargs: Additional arguments passed to swift_library.
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_macos_runner_lib_gen: backend must be 'rules_apple' or 'xtool', got %r" % backend)
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    deps = [engine]
    if application:
        aggregator_name = "_%s__apple_plugins_aggregator" % name
        _flutter_apple_plugins_aggregator(
            name = aggregator_name,
            application = application,
            platform = "macos",
            tags = internal_tags,
            visibility = ["//visibility:private"],
        )
        deps.append(":" + aggregator_name)

    runner_srcs = [
        registrant,
        "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
        "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
    ]
    if backend == "rules_apple":
        swift_library(
            name = name,
            srcs = runner_srcs,
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
            platform = "macos",
            deps = deps,
            tags = tags,
            **kwargs
        )

# -- Convenience macro (Tier 1) -----------------------------------------------

def _macos_resolve_entitlements(name, entitlements, additional_entitlements, internal_tags):
    """Discovers the conventional entitlements pair and folds additions in.

    flutter create always emits both files; their absence is an error rather
    than a "ship without entitlements" fallback. Without entitlements the
    bundle is adhoc-signed unsandboxed and `getApplicationDocumentsDirectory()`
    resolves to ~/Documents instead of the app container, diverging from
    `flutter build macos`.
    """
    resolved = entitlements
    if resolved == None:
        debug_present = native.glob(
            ["macos/Runner/DebugProfile.entitlements"],
            allow_empty = True,
        )
        release_present = native.glob(
            ["macos/Runner/Release.entitlements"],
            allow_empty = True,
        )
        if debug_present and release_present:
            resolved = select({
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
            base = resolved,
            additions = additional_entitlements,
            tags = internal_tags,
        )
        resolved = "__%s_entitlements" % name
    return resolved

def _macos_build_frameworks(name, application, minimum_os_version, allow_non_macho, backend, engine, internal_tags):
    """Emits the registrant, App.framework, native libs and engine targets.

    Returns:
      The engine target label to link the runner against.
    """

    # 1. Generate macOS Swift plugin registrant.
    _flutter_macos_registrant_rule(
        name = "__%s_registrant" % name,
        application = application,
        tags = internal_tags,
    )

    # 2. Assemble App.framework (versioned layout with AOT dylib + flutter_assets).
    _flutter_macos_framework_rule(
        name = "__%s_app_framework" % name,
        application = application,
        minimum_os_version = minimum_os_version,
        allow_non_macho = allow_non_macho,
        tags = internal_tags,
    )

    # 3. Expose native plugin .dylib files for bundling.
    _flutter_macos_native_libs_rule(
        name = "__%s_native_libs" % name,
        application = application,
        minimum_os_version = minimum_os_version,
        allow_non_macho = allow_non_macho,
        tags = internal_tags,
    )

    # 3b. Expose plugin PrivacyInfo.xcprivacy files for bundling.
    _flutter_macos_privacy_manifests_rule(
        name = "__%s_privacy_manifests" % name,
        application = application,
        tags = internal_tags,
    )

    # 4. Import FlutterMacOS.framework engine — auto-select debug/release and backend.
    if engine:
        return engine
    flutter_macos_engine(
        name = "__%s_engine" % name,
        backend = backend,
        tags = internal_tags,
    )
    return "__%s_engine" % name

def _macos_discover_runner_srcs(srcs):
    """Discovers the runner Swift sources, failing when there are none."""
    runner_srcs = srcs if srcs != None else native.glob(["macos/Runner/*.swift"])
    if not runner_srcs:
        fail("No Swift sources found in macos/Runner/. " +
             "Run 'flutter create --platforms=macos .' to generate runner files.")
    return runner_srcs

def _macos_build_runner(name, backend, menu_xib, display_name, module_name, runner_srcs, runner_deps, engine_target, internal_tags):
    """Builds the rules_apple runner library with the preprocessed menu XIB."""
    if backend != "rules_apple":
        return
    menu_xib_template = menu_xib if menu_xib != None else "macos/Runner/Base.lproj/MainMenu.xib"
    expand_template(
        name = "__%s_menu_xib" % name,
        template = menu_xib_template,
        out = "__%s/Base.lproj/MainMenu.xib" % name,
        substitutions = {
            "APP_NAME": display_name,
            "customModule=\"Runner\"": "customModule=\"%s\"" % module_name,
        },
        tags = internal_tags,
    )
    swift_library(
        name = "__%s_runner" % name,
        srcs = runner_srcs + ["__%s_registrant" % name],
        data = ["__%s_menu_xib" % name],
        module_name = module_name,
        tags = internal_tags,
        deps = [
            engine_target,
            "__%s_apple_plugins" % name,
        ] + runner_deps,
    )

def _macos_discover_app_icons(app_icons, backend):
    """Discovers the conventional catalog, silently absent on iOS-only trees.

    Discovery is per-platform and its absence is silent: a tree that only
    ever ran `flutter create --platforms=ios .` has no catalog here, and an
    app with neither a catalog nor an `app_icons` has said nothing either
    way, so it ships no icon and there is nothing to report.
    """
    if app_icons == None and backend == "rules_apple":
        return native.glob(
            ["macos/Runner/Assets.xcassets/AppIcon.appiconset/**"],
            allow_empty = True,
        )
    return app_icons

def _macos_resolve_info_plist(name, info_plist, app_icons, internal_tags):
    """Preprocesses the Info.plist and drops the scaffold's empty icon key.

    `flutter create` writes `CFBundleIconFile` as `<string></string>` for
    Xcode to fill in. Nothing fills it in here, and `macos_application`
    generates its own `CFBundleIconFile` from the icon catalog — so with an
    app icon the two disagree and plisttool refuses the build outright.
    Only when there is an icon, and only when the value is empty: a plist
    that names a real icon file still conflicts, and still says so.
    """
    actual_info_plist = info_plist
    if not actual_info_plist:
        expand_template(
            name = "__%s_info_plist" % name,
            template = "macos/Runner/Info.plist",
            out = "__%s_Info.plist" % name,
            substitutions = {
                "$(DEVELOPMENT_LANGUAGE)": "en",
                "$(PRODUCT_COPYRIGHT)": "",
            },
            tags = internal_tags,
        )
        actual_info_plist = "__%s_info_plist" % name
    if app_icons:
        _flutter_plist_merge(
            name = "__%s_info_plist_icon" % name,
            base = actual_info_plist,
            additions = [],
            drop_empty_keys = ["CFBundleIconFile"],
            mode = "supplement",
            output_basename = "Info.plist",
            tags = internal_tags,
        )
        actual_info_plist = "__%s_info_plist_icon" % name
    return actual_info_plist

def _macos_resolve_version(name, backend, version, internal_tags, kwargs):
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
        "flutter_macos_app",
        version,
        internal_tags,
    )
    if version_bv and "build_version" not in kwargs:
        kwargs["build_version"] = version_bv
    if version_sv and "short_version" not in kwargs:
        kwargs["short_version"] = version_sv
    return version, invalid_version_error

def _macos_emit_rules_apple_bundle(name, display_name, bundle_id, minimum_os_version, actual_info_plist, version, app_icons, resources, flutter_contents, entitlements, tags, visibility, kwargs):
    """Emits the final rules_apple macos_application bundle target."""
    macos_application(
        name = name,
        bundle_id = bundle_id,
        bundle_name = display_name,
        minimum_os_version = minimum_os_version,
        infoplists = [actual_info_plist],
        version = version,
        app_icons = app_icons,
        resources = resources,
        additional_contents = flutter_contents,
        entitlements = entitlements,
        deps = ["__%s_runner" % name],
        tags = tags,
        visibility = visibility,
        **kwargs
    )

def _macos_emit_xtool_bundle(name, display_name, bundle_id, minimum_os_version, version, invalid_version_error, additional_contents, menu_xib, app_icons, actual_info_plist, runner_srcs, runner_deps, engine_target, resources, entitlements, tags, visibility, kwargs):
    """Emits the final xtool macOS bundle target, forwarding only its kwargs."""
    valid_xtool_kwargs = (
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
        "provisioning_profile",
        "require_sdk",
        "restricted_to",
        "short_version",
        "target_compatible_with",
        "testonly",
        "zsign",
    )
    forwarded_kwargs = {k: v for k, v in kwargs.items() if k in valid_xtool_kwargs}
    unsupported_kwargs = [k for k in kwargs if k not in valid_xtool_kwargs]
    discovered_menu_xib = native.glob(["macos/Runner/Base.lproj/MainMenu.xib"], allow_empty = True)
    xtool_menu_xib = menu_xib if menu_xib != None else (discovered_menu_xib[0] if discovered_menu_xib else None)
    _flutter_xtool_macos_bundle(
        name = name,
        app_name = display_name,
        bundle_id = bundle_id,
        minimum_os_version = minimum_os_version,
        version = version,
        invalid_version_error = invalid_version_error,
        additional_contents = additional_contents,
        menu_xib = xtool_menu_xib,
        app_icons = app_icons if app_icons != None else [],
        infoplists = [actual_info_plist],
        srcs = runner_srcs,
        registrant = ":__%s_registrant" % name,
        plugins = [":__%s_apple_plugins" % name],
        deps = runner_deps,
        frameworks = [
            ":__%s_app_framework" % name,
            engine_target,
        ],
        native_libs = [":__%s_native_libs" % name],
        resources = resources + [
            ":__%s_privacy_manifests" % name,
        ],
        entitlements = entitlements,
        tags = tags,
        visibility = visibility,
        unsupported_kwargs = unsupported_kwargs,
        **forwarded_kwargs
    )

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
        additional_entitlements = [],
        app_icons = None,
        resources = [],
        runner_deps = [],
        srcs = None,
        engine = None,
        menu_xib = None,
        allow_non_macho = [],
        backend = "rules_apple",
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
        version: An apple_bundle_version target. Defaults to "1.0".
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
        srcs: Override conventional `macos/Runner/*.swift` runner sources.
        engine: Override default macOS engine target.
        menu_xib: Override conventional `macos/Runner/Base.lproj/MainMenu.xib`.
            On the `xtool` backend, when `menu_xib` is omitted and no
            `macos/Runner/Base.lproj/MainMenu.xib` exists on disk, the default
            runner creates its menu programmatically without Interface Builder
            compilation. Any explicit `menu_xib` (including the default
            template label) or a discovered conventional
            `macos/Runner/Base.lproj/MainMenu.xib` fails at analysis with a
            named error because compiling `.xib` files requires Xcode `ibtool`
            (remove `macos/Runner/Base.lproj/MainMenu.xib` and omit `menu_xib`
            to use the programmatic menu, or use `backend = "rules_apple"`).
        allow_non_macho: Explicit allow-list of binary or framework names
            permitted to bypass Mach-O validation.
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in). Note: `"xtool"` requires a
            user-supplied `darwin.artifactbundle` configured via
            `flutter.darwin_sdk` in compliance with Apple's SDK licensing
            terms; no Apple SDK is downloaded by default.
        **kwargs: Passed through to `macos_application` (or `_flutter_xtool_macos_bundle`
            when `backend = "xtool"`). For `backend = "xtool"` signing with
            `certificate` (`.p12`), pass the password via
            `certificate_password_file` (a file label read at execution time)
            or `certificate_password_env` (an environment variable name read at
            execution time); plain-text `certificate_password` is rejected so
            signing secrets never appear on action command lines. The macro sets
            `app_icons` itself, so pass the named parameter instead.
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_macos_app: backend must be 'rules_apple' or 'xtool', got %r" % backend)

    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]
    visibility = kwargs.pop("visibility", None)
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
    entitlements = _macos_resolve_entitlements(name, entitlements, additional_entitlements, internal_tags)

    # -- Internal targets (all __{name}_ prefixed) --

    engine_target = _macos_build_frameworks(name, application, minimum_os_version, allow_non_macho, backend, engine, internal_tags)

    # 5. Discover runner Swift sources and build swift_library.
    runner_srcs = _macos_discover_runner_srcs(srcs)

    # 5b. Aggregate Apple plugin libraries from the application's transitive
    # FlutterInfo so the runner's swift_library imports + links each pub
    # plugin's Swift module.
    _flutter_apple_plugins_aggregator(
        name = "__%s_apple_plugins" % name,
        application = application,
        platform = "macos",
        tags = internal_tags,
    )

    _macos_build_runner(name, backend, menu_xib, display_name, module_name, runner_srcs, runner_deps, engine_target, internal_tags)

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
    app_icons = _macos_discover_app_icons(app_icons, backend)

    # 7. Info.plist — preprocess to resolve Xcode variables that rules_apple
    #    doesn't handle (PRODUCT_COPYRIGHT, DEVELOPMENT_LANGUAGE).
    actual_info_plist = _macos_resolve_info_plist(name, info_plist, app_icons, internal_tags)

    # 8. Version — create default apple_bundle_version if not provided (rules_apple),
    #    or resolve/convert apple_bundle_version on xtool without Apple toolchains.
    version, invalid_version_error = _macos_resolve_version(name, backend, version, internal_tags, kwargs)

    # 9. Assemble Flutter additional_contents.
    flutter_contents = {
        "__%s_app_framework" % name: "Frameworks",
        "__%s_native_libs" % name: "Frameworks",
        "__%s_privacy_manifests" % name: "Resources",
    }
    flutter_contents.update(additional_contents)

    # 10. Final bundle target — rules_apple (default) or explicit opt-in xtool.
    if backend == "rules_apple":
        _macos_emit_rules_apple_bundle(name, display_name, bundle_id, minimum_os_version, actual_info_plist, version, app_icons, resources, flutter_contents, entitlements, tags, visibility, kwargs)
    else:
        _macos_emit_xtool_bundle(name, display_name, bundle_id, minimum_os_version, version, invalid_version_error, additional_contents, menu_xib, app_icons, actual_info_plist, runner_srcs, runner_deps, engine_target, resources, entitlements, tags, visibility, kwargs)
