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
            "flutter_android_apk_overlay",
            "flutter_android_bundle",
            "flutter_android_engine",
            "flutter_android_manifest_gen",
            "flutter_android_manifest_merge",
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
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//android:rules.bzl", _android_binary = "android_binary", _android_library = "android_library")
load("@rules_java//java:java_import.bzl", _java_import = "java_import")
load("@rules_kotlin//kotlin:android.bzl", _kt_android_library = "kt_android_library")
load("//flutter/private:constants.bzl", _ANDROID_ABI_FOR_ARCH = "ANDROID_ABI_FOR_ARCH", _ANDROID_MIN_SDK_VERSION = "ANDROID_MIN_SDK_VERSION", _ANDROID_TARGET_SDK_VERSION = "ANDROID_TARGET_SDK_VERSION")
load("//flutter/private:flutter_android_apk_overlay.bzl", _flutter_android_apk_overlay = "flutter_android_apk_overlay")
load("//flutter/private:flutter_android_application.bzl", _flutter_android_bundle = "flutter_android_bundle")
load("//flutter/private:flutter_android_binary_proxy.bzl", _flutter_android_binary_proxy = "flutter_android_binary_proxy")
load("//flutter/private:flutter_android_manifest_merge.bzl", _flutter_android_manifest_merge = "flutter_android_manifest_merge")
load("//flutter/private:flutter_android_plugin_library.bzl", _flutter_android_plugin_library = "flutter_android_plugin_library")
load("//flutter/private:flutter_android_registrant.bzl", _flutter_android_plugins_aggregator = "flutter_android_plugins_aggregator", _flutter_android_registrant = "flutter_android_registrant")

# Re-export constants for user BUILD files.
ANDROID_MIN_SDK_VERSION = _ANDROID_MIN_SDK_VERSION
ANDROID_TARGET_SDK_VERSION = _ANDROID_TARGET_SDK_VERSION

# AndroidX deps of flutter.jar, mirroring the dependency list of Flutter's
# official io.flutter:flutter_embedding_* Maven POM (the deps every
# Gradle-built Flutter app ships): lifecycle for FlutterActivity's
# LifecycleRegistry, window/window-java for foldable display features, core
# for ContextCompat/ViewCompat/input, tracing for the engine's TraceSection,
# fragment for FlutterFragment(Activity), exifinterface for image decoding,
# and relinker for engine .so loading. The POM's lifecycle-common-java8 and
# lifecycle-process entries are omitted: at the lifecycle version pinned here
# their classes live in lifecycle-common, and the embedding never references
# lifecycle-process types.
#
# `flutter_android_engine` *exports* these: the POM declares them at compile
# scope, so in Gradle builds everything that compiles against the embedding
# AAR — runner sources, the plugin registrant, and every Flutter plugin —
# sees them on its compile classpath transitively. Exporting reproduces
# that contract. It adds nothing to the APK that the engine target wasn't
# already carrying at runtime.
_ANDROIDX_EMBEDDING_DEPS = [
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

# Finishes a payload-free android_binary into a signed APK by injecting the
# Flutter payload (native libraries and flutter_assets) after resource
# linking. Wired automatically by flutter_android_app; expose for Tier-2
# control when assembling an `android_binary` by hand.
flutter_android_apk_overlay = _flutter_android_apk_overlay

# The aapt2 default no-compress extension list that both the overlay tool and
# android_binary's own packaging apply (see
# flutter/private/tools/apk_overlay.dart `_aaptNoCompressExtensions`, itself
# mirroring singlejar). Reference apps in e2e tests pass this to
# android_binary's nocompress_extensions so entry-by-entry parity checks
# compare the same compression policy on both APKs.
FLUTTER_APK_AAPT_NO_COMPRESS_EXTENSIONS = [
    "jpg",
    "jpeg",
    "png",
    "gif",
    "wav",
    "mp2",
    "mp3",
    "ogg",
    "aac",
    "mpg",
    "mpeg",
    "mid",
    "midi",
    "smf",
    "jet",
    "rtttl",
    "imy",
    "xmf",
    "mp4",
    "m4a",
    "m4v",
    "3gp",
    "3gpp",
    "3g2",
    "3gpp2",
    "amr",
    "awb",
    "wma",
    "wmv",
    "webm",
    "mkv",
    "webp",
]

# Merges a variant AndroidManifest.xml overlay (e.g. flutter create's
# android/app/src/debug/AndroidManifest.xml) into a base manifest — the
# Bazel counterpart of Gradle's per-variant manifest merge. Wired
# automatically by flutter_android_app; expose for Tier-2 control.
flutter_android_manifest_merge = _flutter_android_manifest_merge

def flutter_android_permissions_manifest(name, permissions, **kwargs):
    """Writes an overlay manifest declaring `permissions`, and nothing else.

    The overlay half of the additive permission seam: pair it with
    `flutter_android_manifest_merge` to add `<uses-permission>` elements to
    any base manifest — including one produced by
    `flutter_android_manifest_gen`, which has no permission attribute of its
    own. `flutter_android_app(permissions = [...])` composes exactly these
    two rules; do it by hand when assembling an `android_binary` yourself.

    Args:
        name: Target name. Pass as `overlay` to
            `flutter_android_manifest_merge`.
        permissions: Fully-qualified permission names, e.g.
            `["android.permission.INTERNET"]`.
        **kwargs: Additional arguments (e.g. visibility, tags). `tags`
            defaults to `["manual"]`.
    """
    if not permissions:
        fail("flutter_android_permissions_manifest(name = %r): `permissions` " % name +
             "is empty. Drop the target rather than merging nothing.")
    tags = kwargs.pop("tags", ["manual"])
    write_file(
        name = name,
        out = "%s/AndroidManifest.xml" % name,
        content = [
            "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">",
        ] + [
            "    <uses-permission android:name=\"%s\"/>" % permission
            for permission in permissions
        ] + [
            "</manifest>",
            "",
        ],
        tags = tags,
        **kwargs
    )

def flutter_android_plugin_library(name, flutter_engine = None, tags = None, **kwargs):
    """Wrap a Flutter plugin's Android Kotlin/Java sources in a kt_android_library.

    For pub.dev plugins, `flutter_pub_package` emits this automatically; expose
    it here so users can wire a workspace plugin's BUILD.bazel without going
    through the ext/ overlay system. When `flutter_engine` is omitted, a
    private `neverlink = True` engine target is created automatically.

    Args:
        name: Target name. Pass to `flutter_plugin(android_libs = [...])` or
            `flutter_android_app(deps = [...])`.
        flutter_engine: Optional `flutter_android_engine` target declared with
            `neverlink = True`. If omitted, a private compile-only engine is
            synthesized automatically.
        tags: Bazel tags. Defaults to `["manual"]`.
        **kwargs: Forwarded to `_flutter_android_plugin_library`.
    """
    if flutter_engine == None:
        engine_tags = tags if tags != None else ["manual"]
        flutter_android_engine(
            name = "_%s__engine" % name,
            neverlink = True,
            tags = engine_tags,
            visibility = ["//visibility:private"],
        )
        flutter_engine = ":_%s__engine" % name
    _flutter_android_plugin_library(
        name = name,
        flutter_engine = flutter_engine,
        tags = tags,
        **kwargs
    )

# Registrant rule that emits GeneratedPluginRegistrant.java from a
# flutter_application's transitive FlutterInfo. Wired automatically by
# flutter_android_app; expose for Tier-2 control.
flutter_android_registrant = _flutter_android_registrant

def flutter_android_engine(name, android_abi = "arm64", neverlink = False, **kwargs):
    """Imports the Flutter engine (flutter.jar) as a java_import target.

    Auto-selects debug or release engine based on Bazel compilation mode:
    - Debug (-c dbg): JIT engine for emulator/iterative development.
    - Release (-c opt / default): AOT engine for production.

    The engine's native libraries are stripped with the NDK's `llvm-strip
    --strip-unneeded`, as a Gradle build strips them, so the Android NDK
    C++ toolchain must be registered (see the README's Android section).

    A plugin library compiles against the engine but must not package it:
    the app's own engine, of the app's ABI, is the one that ships. Give a
    plugin a `neverlink = True` engine, as Gradle gives a plugin the
    embedding with `compileOnly`. A linked one puts a second engine in the
    APK, which for an x64 app is an arm64 `libflutter.so` that makes Android
    install the app as arm64 and crash at launch.

    Args:
        name: Target name. Add to android_binary deps.
        android_abi: Engine ABI — "arm64" (default) or "x64".
        neverlink: Compile against the engine without packaging it. For
            `flutter_android_plugin_library(flutter_engine = ...)`; the
            engine in the app's `android_binary` deps leaves it False.
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

    # `deps` (not just the wrapper's exports) matters here: flutter.jar's
    # own desugar action takes its classpath from the java_import's
    # direct deps, and desugaring io.flutter.* against an incomplete
    # classpath fails the deploy jar's desugar-dependency check.
    _java_import(
        name = "_%s_jar" % name,
        # The engine with its native libraries stripped, as Gradle packages
        # it (flutter_android_engine_jar.bzl).
        jars = select({
            "@rules_flutter//flutter/private:dbg": [Label("@%s//:debug_stripped" % repo)],
            # Named through rules_flutter's own repo mapping, so a consumer
            # needs no use_repo entry for a repo only profile builds fetch.
            "@rules_flutter//flutter/private:profile": [Label("@%s_profile//:stripped" % repo)],
            "//conditions:default": [Label("@%s//:stripped" % repo)],
        }),
        tags = tags,
        neverlink = neverlink,
        deps = _ANDROIDX_EMBEDDING_DEPS,
    )

    # The android_library wrapper carries the embedding's R8 keep rules
    # (the @androidx.annotation.Keep contract FlutterJNI relies on) to the
    # consuming android_binary — the role the Maven embedding AAR's
    # consumer proguard config plays in Gradle builds. java_import cannot
    # declare proguard_specs, hence the wrapper. The androidx artifacts
    # are additionally exported so consumers compile against the same
    # classpath the embedding POM gives Gradle builds (see
    # _ANDROIDX_EMBEDDING_DEPS).
    _android_library(
        name = name,
        exports = ["_%s_jar" % name] + _ANDROIDX_EMBEDDING_DEPS,
        proguard_specs = ["@rules_flutter//flutter/private/runners/android:flutter_engine_proguard.pro"],
        neverlink = neverlink,
        tags = tags,
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

    Debug builds (`-c dbg`) declare `android.permission.INTERNET`, matching
    the permission Gradle merges from flutter create's debug variant
    manifest: Android enforces INTERNET at the kernel level (AID_INET group
    membership), so without it the Dart VM service cannot bind even its
    loopback socket and debugging/hot reload are impossible. Release builds
    declare no permissions.

    That grant is the *debugger's*, not the app's, and this template has a
    fixed key set with no permission attribute. An app that networks in
    release declares it for itself — through
    `flutter_android_app(permissions = [...])`, or, when assembling an
    `android_binary` by hand, by composing this manifest with
    `flutter_android_permissions_manifest` +
    `flutter_android_manifest_merge`:

        flutter_android_manifest_gen(name = "base", package_name = "...")
        flutter_android_permissions_manifest(
            name = "extra",
            permissions = ["android.permission.INTERNET"],
        )
        flutter_android_manifest_merge(
            name = "manifest",
            base = ":base",
            overlay = ":extra",
        )

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

    substitutions = {
        "PACKAGE_NAME": package_name,
        "APP_NAME": display_name,
        "MIN_SDK_VERSION": min_sdk_version,
        "TARGET_SDK_VERSION": target_sdk_version,
    }

    expand_template(
        name = "__%s_dbg" % name,
        template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
        out = "__%s_dbg/AndroidManifest.xml" % name,
        substitutions = substitutions | {
            "INTERNET_PERMISSION": "<uses-permission android:name=\"android.permission.INTERNET\"/>",
        },
        tags = tags,
    )

    expand_template(
        name = "__%s_opt" % name,
        template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
        out = "__%s_opt/AndroidManifest.xml" % name,
        substitutions = substitutions | {
            "INTERNET_PERMISSION": "",
        },
        tags = tags,
    )

    native.alias(
        name = name,
        actual = select({
            "@rules_flutter//flutter/private:dbg": "__%s_dbg" % name,
            # Profile serves the VM service too, so it needs the socket.
            "@rules_flutter//flutter/private:profile": "__%s_dbg" % name,
            "//conditions:default": "__%s_opt" % name,
        }),
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
                # Never a permission here: this is a LIBRARY manifest, and
                # rules_android's merger strips library permissions unless
                # --merge_android_manifest_permissions is set — the permission
                # would silently come and go with a flag. The binary manifest
                # (flutter_android_manifest_gen) owns INTERNET.
                "INTERNET_PERMISSION": "",
            },
            tags = tags,
        )
        actual_manifest = "__%s_lib_manifest" % name

    _kt_android_library(
        name = name,
        srcs = ["__%s_main_activity" % name],
        manifest = actual_manifest,
        tags = tags,
        deps = [engine],
        **kwargs
    )

def _variant_overlay(name, variant, manifest, base_manifest):
    """Resolves a `flutter create` variant manifest (`debug` or `profile`).

    Args:
        name: The flutter_android_app name, for error messages.
        variant: The build variant directory under android/app/src/.
        manifest: The macro argument: False, None (discover) or a label.
        base_manifest: The main manifest the variant merges into, or None.

    Returns:
        The overlay manifest, or None.
    """
    if manifest == False:
        return None
    if manifest == None:
        discovered = native.glob(
            ["android/app/src/%s/AndroidManifest.xml" % variant],
            allow_empty = True,
        )
        overlay = discovered[0] if discovered else None
    else:
        overlay = manifest
    if overlay != None and base_manifest == None:
        fail(
            ("flutter_android_app(name = %r): %s variant manifest %r has no main " +
             "manifest to merge into. Add android/app/src/main/AndroidManifest.xml " +
             "(flutter create output), pass `manifest`, or pass " +
             "`%s_manifest = False` to ignore the variant manifest.") %
            (name, variant, overlay, variant),
        )
    return overlay

# -- Convenience macro (Tier 1) -----------------------------------------------

def _android_internal_tags(tags):
    """Keeps internal targets out of wildcard builds behind the pure-Go proxy.

    Behind the proxy's pure-Go transition internal targets would otherwise
    build the whole Android subtree a second time in the plain
    configuration. The default tags already carry "manual"; re-add it when
    the caller overrides tags. The user-facing proxy keeps the caller's tags
    verbatim.
    """
    internal_tags = list(tags) if tags else []
    if "manual" not in internal_tags:
        internal_tags.append("manual")
    return internal_tags

def _android_bundle_and_engine(name, application, android_abi, internal_tags):
    """Emits the bundle, native-libs wiring, engine and overlay-assets targets."""

    # 1. Bundle Flutter outputs (native_libs.jar + flutter_assets).
    _flutter_android_bundle(
        name = "__%s_bundle" % name,
        application = application,
        android_abi = _short_abi_to_full(android_abi),
        tags = internal_tags,
    )

    # 2. Extract native_libs.jar from the bundle.
    native.filegroup(
        name = "__%s_native_libs_jar" % name,
        srcs = ["__%s_bundle" % name],
        output_group = "native_libs_jar",
        tags = internal_tags,
    )

    # 3. Wrap native_libs.jar as java_import.
    _java_import(
        name = "__%s_native_libs" % name,
        jars = ["__%s_native_libs_jar" % name],
        tags = internal_tags,
    )

    # 4. Import Flutter engine.
    flutter_android_engine(
        name = "__%s_engine" % name,
        android_abi = android_abi,
        tags = internal_tags,
    )

    # 5. Extract flutter_assets for injection into the APK after resource
    # linking (see flutter_android_apk_overlay).
    native.filegroup(
        name = "__%s_overlay_assets" % name,
        srcs = ["__%s_bundle" % name],
        output_group = "flutter_assets",
        tags = internal_tags,
    )

def _android_registrant(name, application, android_abi, pub_hub_name, deps, internal_tags):
    """Auto-wires the plugin registrant and returns its compile deps.

    Generates `GeneratedPluginRegistrant.java` from the flutter_application's
    transitive FlutterInfo plugin metadata, then wraps it in a
    kt_android_library so the registrant class is on the runtime
    classpath (called from the runner's MainActivity / FlutterActivity).

    The registrant references each plugin's `PluginClass` by fully
    qualified name, so its compile classpath must include every
    plugin's `kt_android_library`, the hub aggregator, the workspace
    `deps` (a workspace plugin reaches the app through them and the
    registrant names its class), and the engine.
    """
    _flutter_android_registrant(
        name = "__%s_registrant_src" % name,
        application = application,
        android_abi = _short_abi_to_full(android_abi),
        tags = internal_tags,
    )

    _flutter_android_plugins_aggregator(
        name = "__%s_android_plugins" % name,
        application = application,
        android_abi = _short_abi_to_full(android_abi),
        tags = internal_tags,
    )

    registrant_deps = [
        "__%s_engine" % name,
        "__%s_android_plugins" % name,
    ]
    if pub_hub_name:
        registrant_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)
    return registrant_deps + deps

def _android_discover_runner(name, package_name, resources, binary_deps, base_manifest, internal_tags):
    """Discovers flutter create output: manifest, resources, Kotlin sources.

    Returns:
      The `(base_manifest, resources)` tuple; `binary_deps` gains the runner
      library when Kotlin sources are discovered.
    """
    if base_manifest:
        return base_manifest, resources

    # Try to discover flutter create output.
    discovered_manifests = native.glob(
        ["android/app/src/main/AndroidManifest.xml"],
        allow_empty = True,
    )
    if not discovered_manifests:
        return base_manifest, resources

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
        tags = internal_tags,
    )

    # Discover resources from flutter create output.
    discovered_resources = native.glob(
        ["android/app/src/main/res/**"],
        allow_empty = True,
    )
    resources = list(resources) + discovered_resources

    # Discover and compile Kotlin sources from flutter create output.
    discovered_kotlin = native.glob(
        ["android/app/src/main/kotlin/**/*.kt"],
        allow_empty = True,
    )
    if discovered_kotlin:
        _kt_android_library(
            name = "__%s_runner" % name,
            srcs = discovered_kotlin,
            custom_package = package_name,
            tags = internal_tags,
            deps = ["__%s_engine" % name],
        )
        binary_deps.append("__%s_runner" % name)
    return "__%s_manifest" % name, resources

def _android_resolve_manifest(name, base_manifest, debug_manifest, profile_manifest, package_name, display_name, min_sdk_version, target_sdk_version, permissions, binary_deps, deps, internal_tags):
    """Resolves the effective manifest: variants, template, permissions.

    Folds each variant's permissions into its own mode's APKs, the merge
    Gradle performs per build type. Release APKs keep the main manifest,
    byte-identical to a build without the variants. The app's own
    permissions go last and in every compilation mode, so a permission the
    app needs cannot go missing from the release APK the way `flutter
    create`'s debug-variant INTERNET does. Library permissions are lifted
    as Gradle does, whatever the merger flags.
    """
    debug_overlay = _variant_overlay(name, "debug", debug_manifest, base_manifest)
    profile_overlay = _variant_overlay(name, "profile", profile_manifest, base_manifest)

    if base_manifest == None:
        # No flutter create output — generate manifest from template. The
        # generated manifest handles the debug and profile INTERNET
        # permission itself (see flutter_android_manifest_gen).
        flutter_android_manifest_gen(
            name = "__%s_manifest" % name,
            package_name = package_name,
            app_name = display_name,
            min_sdk_version = min_sdk_version,
            target_sdk_version = target_sdk_version,
            tags = internal_tags,
        )
        actual_manifest = "__%s_manifest" % name
    elif debug_overlay != None or profile_overlay != None:
        variants = {}
        for mode, overlay in [("dbg", debug_overlay), ("profile", profile_overlay)]:
            if overlay == None:
                continue
            flutter_android_manifest_merge(
                name = "__%s_manifest_merged_%s" % (name, mode),
                base = base_manifest,
                overlay = overlay,
                tags = internal_tags,
            )
            variants["@rules_flutter//flutter/private:" + mode] = "__%s_manifest_merged_%s" % (name, mode)
        actual_manifest = select(variants | {"//conditions:default": base_manifest})
    else:
        actual_manifest = base_manifest

    if permissions:
        flutter_android_permissions_manifest(
            name = "__%s_permissions" % name,
            permissions = permissions,
            tags = internal_tags,
        )
        flutter_android_manifest_merge(
            name = "__%s_manifest_with_permissions" % name,
            base = actual_manifest,
            overlay = "__%s_permissions" % name,
            tags = internal_tags,
        )
        actual_manifest = "__%s_manifest_with_permissions" % name

    flutter_android_manifest_merge(
        name = "__%s_manifest_with_library_permissions" % name,
        base = actual_manifest,
        libraries = ["__%s_native_libs" % name] + binary_deps + deps,
        placeholders = ["applicationId", "minSdkVersion", "targetSdkVersion"],
        tags = internal_tags,
    )
    return "__%s_manifest_with_library_permissions" % name

def _android_binary_and_overlay(name, package_name, min_sdk_version, target_sdk_version, actual_manifest, resources, binary_deps, deps, nocompress_extensions, tags, internal_tags, kwargs, keystore = None, keystore_password_file = None, key_alias = None, key_password_file = None):
    """Emits the payload-free android_binary, the payload overlay and the proxy.

    The android_binary builds a payload-free base APK: neither the
    native_libs java_import (whose jar carries libapp.so through the dex
    chain) nor flutter_assets (which aapt2 would link into the resources
    APK) are its inputs, so Dart edits re-run neither resource linking nor
    dexing. The overlay injects both after resource linking, then aligns
    and signs — the same steps android_binary would have run.
    """

    # 9. Final android_binary, behind a proxy that scopes rules_go pure mode
    # to this app (see flutter_android_binary_proxy.bzl).
    # `android_binary` resolves `_cc_toolchain` in the outer target
    # configuration before transitioning to Android, so it can be analyzed on
    # host or Android platforms (both of which register a CC toolchain) but not
    # when the top-level `--platforms` is iOS.
    kwargs.setdefault(
        "target_compatible_with",
        select({
            Label("@platforms//os:ios"): [Label("@platforms//:incompatible")],
            "//conditions:default": [],
        }),
    )

    # Attributes describing the app target itself, mirrored onto both the proxy
    # (what users build) and the binary behind it so the two agree on where the
    # app can build and how it is released. Everything else configures the
    # binary alone.
    passthrough = {}
    for key in ("compatible_with", "deprecation", "restricted_to", "target_compatible_with", "testonly", "visibility"):
        if key in kwargs:
            passthrough[key] = kwargs.pop(key)
    binary_kwargs = dict(kwargs)
    binary_kwargs.update(passthrough)
    if nocompress_extensions != None:
        binary_kwargs["nocompress_extensions"] = nocompress_extensions

    # Like every other internal target, the binary stays out of wildcard
    # builds (see internal_tags above): the proxy is the only entry point.
    _android_binary(
        name = "__%s_binary" % name,
        manifest = actual_manifest,
        manifest_values = {
            "applicationId": package_name,
            "minSdkVersion": min_sdk_version,
            "targetSdkVersion": target_sdk_version,
        },
        resource_files = resources if resources else None,
        deps = binary_deps + deps,
        tags = internal_tags,
        **binary_kwargs
    )

    # 10. Inject the Flutter payload after resource linking, then align and
    # sign — the same steps android_binary would have run. `signing` follows
    # @rules_android//flags:apk_signing_method so the overlay signs exactly
    # like the binary would have. Signing/alignment overrides passed for the
    # binary apply to the overlay too.
    overlay_kwargs = {}
    for key in ("debug_key", "debug_signing_keys", "debug_signing_lineage_file", "key_rotation_min_sdk", "zipalign_alignment"):
        if key in kwargs:
            overlay_kwargs[key] = kwargs[key]
    if nocompress_extensions != None:
        overlay_kwargs["nocompress_extensions"] = nocompress_extensions
    for key, value in (
        ("keystore", keystore),
        ("keystore_password_file", keystore_password_file),
        ("key_alias", key_alias),
        ("key_password_file", key_password_file),
    ):
        if value != None:
            overlay_kwargs[key] = value

    # L-1: the overlay is the target users actually build, so it must carry
    # the same testonly/compatible_with/restricted_to as the user-facing
    # proxy — otherwise a testonly app's APK would be buildable from
    # non-testonly targets, or a constrained app from anywhere.
    for key in ("compatible_with", "restricted_to", "testonly"):
        if key in passthrough:
            overlay_kwargs[key] = passthrough[key]
    _flutter_android_apk_overlay(
        name = "__%s_overlay" % name,
        binary = "__%s_binary" % name,
        native_libs_jar = "__%s_native_libs_jar" % name,
        flutter_assets = "__%s_overlay_assets" % name,
        signing = select({
            "@rules_flutter//flutter:apk_signing_v1": "v1",
            "@rules_flutter//flutter:apk_signing_v2": "v2",
            "@rules_flutter//flutter:apk_signing_v4": "v4",
            "//conditions:default": "v1_v2",
        }),
        tags = internal_tags,
        **overlay_kwargs
    )

    # The user-facing target: same providers and the same `<name>.apk` output
    # as the android_binary used to be, with pure Go scoped to its subtree.
    _flutter_android_binary_proxy(
        name = name,
        binary = ":__%s_overlay" % name,
        tags = tags,
        **passthrough
    )

def flutter_android_app(
        name,
        application,
        package_name,
        app_name = None,
        android_abi = "arm64",
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        manifest = None,
        debug_manifest = None,
        profile_manifest = None,
        permissions = [],
        resources = [],
        deps = [],
        pub_hub_name = "deps",
        nocompress_extensions = None,
        keystore = None,
        keystore_password_file = None,
        key_alias = None,
        key_password_file = None,
        **kwargs):
    """Builds a Flutter Android APK from a flutter_application target.

    Discovers runner files from the conventional `android/app/src/main/`
    directory (as generated by `flutter create --platforms=android .`) and
    wires up all internal targets automatically.

    Three modes, and which one an app is in decides what it can express:
      1. `manifest` provided → uses it directly, with **no** `${...}`
         placeholder preprocessing and no resource/Kotlin auto-discovery.
         Handing this attribute the same `android/app/src/main/`
         AndroidManifest.xml mode 2 would have discovered therefore fails —
         `flutter create` writes `android:name="${applicationName}"` and
         nothing substitutes it. Use mode 2 for `flutter create` output;
         mode 1 is for a manifest you wrote yourself.
      2. android/app/src/main/AndroidManifest.xml found → uses flutter create
         manifest (preprocessed for Gradle variables), discovers resources
         and Kotlin sources from android/app/src/main/. The main manifest is
         used in **every** compilation mode.
      3. No manifest found → generates manifest from template.

    `permissions` adds `<uses-permission>` elements to the effective manifest
    in every mode and every compilation mode, so it is the answer in all
    three — see the attribute's documentation below.

    Debug variant manifests (the Gradle merge Bazel lacks): flutter create
    declares `android.permission.INTERNET` only in
    `android/app/src/debug/AndroidManifest.xml`. Without it a debug APK
    cannot host the Dart VM service (Android enforces INTERNET at the
    kernel level via AID_INET), so hot reload and debugging are impossible.
    This macro folds the debug variant into `-c dbg` APKs, controlled by
    `debug_manifest`:
      - None (default) → discover android/app/src/debug/AndroidManifest.xml;
        when present, its permissions are merged into the main manifest for
        `-c dbg` builds only. Requires a main manifest (mode 1 or 2).
      - a label → merge that variant manifest instead of discovering one.
      - False → no debug variant handling, even if the file exists.
    Release (`-c opt`, the default) APKs always use the main manifest
    unchanged — so a `flutter create` app that networks perfectly in `-c dbg`
    has **no** `INTERNET` permission in release, and Android enforces that at
    the kernel level (AID_INET group membership): every socket fails with
    `EACCES`, with no build error and no diagnostic. The dbg-only grant is a
    *debugging* requirement, not the app's network grant. An app that
    networks must declare it for itself, via `permissions`.
    `profile_manifest` does the same for profile builds (`-c opt` with
    `--@rules_flutter//flutter:profile`), from
    android/app/src/profile/AndroidManifest.xml, which `flutter create`
    writes with the `INTERNET` permission the VM service needs.

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
        spoke's Kotlin/Java sources (and resources) via the hub's
        aggregator. Spokes without Android sources contribute empty
        libraries (no-op).
      - Permissions that plugins and AARs declare in their own manifests
        (e.g. record_android's RECORD_AUDIO) are lifted into the app's
        manifest, as AGP merges them. Bazel's own merger drops library
        permissions unless `--merge_android_manifest_permissions` is set;
        the app no longer depends on that flag.

    The app target builds rules_android's Go host tools in rules_go pure
    mode (no C++ toolchain, so the hermetic LLVM runtimes are never
    compiled from source), scoped to this app:
    `--@rules_flutter//flutter:android_pure_go=false` opts out, for example
    when the app's own subtree needs cgo. See the README's Android section
    for the trade-off.

    Release signing: by default the APK signs with the debug keystore, as an
    `android_binary` does. To ship to Google Play, pass `keystore` (a `.jks`
    or PKCS#12 `.p12` file label) together with `keystore_password_file` (a
    file label) and `key_alias` (a string); set `key_password_file` (a file
    label) as well when the key has its own password. The
    overlay then signs with `--ks`, `--ks-key-alias`, `--ks-pass
    file:<path>` and, when `key_password_file` is set, `--key-pass
    file:<path>`: both passwords are read from files at execution time and
    never appear on the command line. When `key_password_file` is unset,
    `--key-pass` is omitted and apksigner unlocks the key with the keystore
    password. A `keystore` without `keystore_password_file` or `key_alias` fails
    analysis naming the missing attribute. When `keystore` is unset, the
    `//flutter:android_release_keystore`,
    `//flutter:android_release_keystore_password_file` and
    `//flutter:android_release_key_alias` flags supply the same three
    values, so CI can inject a secret without editing BUILD files; an
    explicit attribute always wins over its flag. Every secret setting must
    name a target with exactly one file — an empty or multi-file target
    fails analysis instead of silently debug-signing — and the release
    signing action runs locally only (`no-remote`), so the secrets never
    reach remote execution or caches. See the README's Android
    section.

    Args:
        name: Target name (Bazel identifier). Produces the app APK (an android_binary behind a pure-Go proxy).
        application: A flutter_application target (required).
        package_name: Android package name, e.g. "com.example.myapp" (required).
        app_name: User-facing display name. Defaults to name.
        android_abi: Target ABI — "arm64" (default) or "x64". Selects the
            engine and the Android platform the application is built for.
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version.
        manifest: Override AndroidManifest.xml. If not set, auto-discovered
            from android/app/src/main/ or generated from template.
        debug_manifest: Debug variant manifest merged into `-c dbg` APKs.
            None (default) discovers android/app/src/debug/AndroidManifest.xml;
            a label overrides discovery; False disables variant handling.
        profile_manifest: Profile variant manifest merged into profile APKs.
            None (default) discovers android/app/src/profile/AndroidManifest.xml;
            a label overrides discovery; False disables variant handling.
        permissions: Permission names — e.g.
            `["android.permission.INTERNET"]` — added to the effective
            manifest in **every** compilation mode and in all three manifest
            modes. This is what a networked app needs: `flutter create`
            grants `INTERNET` in the debug variant only, so without this the
            release APK cannot open a socket. A permission the manifest
            already declares is not duplicated. For a permission wanted in
            `-c dbg` alone, use `debug_manifest` instead; this attribute is
            consumed by the macro and cannot be a `select()`.
        resources: Extra resource_files for android_binary.
        deps: Extra deps for android_binary (e.g. custom android_library).
            A plugin written in the workspace goes here as its
            `flutter_android_plugin_library`: the registrant compiles
            against these too, so the plugin is both packaged and
            registered. Pub plugins arrive through the hub instead.
        pub_hub_name: Name of the `flutter.pub(name = ...)` hub providing
            plugin spokes. The macro depends on
            `@<pub_hub_name>//android:all_android_plugin_libs` to compile
            all plugin Kotlin/Java automatically. Defaults to `"deps"`,
            matching the convention in repo MODULE.bazel files. Set to
            `None` to opt out (e.g. for a workspace with no pub plugins).
        nocompress_extensions: Extra asset extensions stored uncompressed in
            the final APK, on top of the aapt2 defaults (see
            FLUTTER_APK_AAPT_NO_COMPRESS_EXTENSIONS). Forwarded to both the
            payload-free android_binary and the overlay that injects the
            Flutter payload, so both agree on the compression policy.
            Matched case-sensitively by suffix.
        keystore: Release keystore (a `.jks` or PKCS#12 `.p12` file label)
            signing the APK instead of the debug keystore. Needs
            `keystore_password_file` and `key_alias`; without them analysis
            fails naming the missing attribute. Unset (with the
            `//flutter:android_release_keystore` flag unset) keeps debug
            signing. An explicit keystore always wins over the flag.
        keystore_password_file: File holding the release keystore's
            password, read by apksigner at execution time through `--ks-pass
            file:<path>`. The password text never appears on the command
            line. Only the first line is read, so end the file with a
            newline. Falls back to the
            `//flutter:android_release_keystore_password_file` flag.
        key_alias: Alias of the signing key inside `keystore`. Falls back to
            the `//flutter:android_release_key_alias` flag.
        key_password_file: File holding the signing key's own password, read
            through `--key-pass file:<path>`. When unset, `--key-pass` is
            omitted and apksigner unlocks the key with the keystore password;
            the same first-line-and-newline rule applies when it is set.
        **kwargs: Passed through to android_binary.
    """
    display_name = app_name or name
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = _android_internal_tags(tags)

    # -- Internal targets (all __{name}_ prefixed) --

    _android_bundle_and_engine(name, application, android_abi, internal_tags)

    # 6. Auto-wire the plugin registrant.
    #
    # `deps` and `flutter_plugin(android_libs = ...)` too: a plugin written in
    # the workspace reaches the app through them, and the registrant names its
    # class.
    registrant_deps = _android_registrant(name, application, android_abi, pub_hub_name, deps, internal_tags)

    _kt_android_library(
        name = "__%s_registrant" % name,
        srcs = ["__%s_registrant_src" % name],
        custom_package = "io.flutter.plugins",
        tags = internal_tags,
        deps = registrant_deps,
    )

    # 7. Resolve manifests (main + debug variant), resources, and Kotlin
    # sources.
    base_manifest = manifest

    # The android_binary below builds a payload-free base APK: neither the
    # native_libs java_import (whose jar carries libapp.so through the dex
    # chain) nor flutter_assets (which aapt2 would link into the resources
    # APK) are its inputs, so Dart edits re-run neither resource linking nor
    # dexing. The overlay (step 10) injects both after resource linking.
    base_binary_deps = [
        "__%s_engine" % name,
        "__%s_registrant" % name,
        "__%s_android_plugins" % name,
    ]
    binary_deps = list(base_binary_deps)

    # 8. Plugin auto-wiring: compile every transitively-needed plugin's
    # Kotlin/Java via the hub's aggregator. Each spoke unconditionally
    # exposes `android:lib`; the hub's `all_android_plugin_libs` deps on
    # all of them. Spokes without Android sources contribute empty
    # libraries — no-op at link time, mechanical at the macro layer.
    if pub_hub_name:
        binary_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)

    base_manifest, resources = _android_discover_runner(name, package_name, resources, binary_deps, base_manifest, internal_tags)

    # Resolve the variant overlays — every state explicit:
    #   False → no variant handling, even if the file exists.
    #   None  → discover flutter create's variant manifest.
    #   label → use it, overriding discovery.
    # 8b. Add the app's own permissions to whatever manifest the mode
    # produced. 8c. Lift the permissions the app's Android libraries declare
    # (plugins, AARs) into its own manifest, as Gradle does. Bazel's merger
    # drops them unless --merge_android_manifest_permissions is set; done
    # here, they reach the APK whatever the flags. The merger sees the full
    # library list including the native libs java_import, exactly as before
    # the payload-free split: native_libs first, then every binary dep.
    actual_manifest = _android_resolve_manifest(name, base_manifest, debug_manifest, profile_manifest, package_name, display_name, min_sdk_version, target_sdk_version, permissions, binary_deps, deps, internal_tags)

    # 9. Final android_binary, behind a proxy that scopes rules_go pure mode
    # to this app, and 10. the payload overlay. The overlay is the target
    # users actually build; the proxy is the only entry point.
    _android_binary_and_overlay(name, package_name, min_sdk_version, target_sdk_version, actual_manifest, resources, binary_deps, deps, nocompress_extensions, tags, internal_tags, kwargs, keystore = keystore, keystore_password_file = keystore_password_file, key_alias = key_alias, key_password_file = key_password_file)

def _short_abi_to_full(abi):
    """Convert short ABI name to full ABI string for flutter_android_bundle."""
    if abi not in _ANDROID_ABI_FOR_ARCH:
        fail("Unsupported android_abi '%s'. Use arm64 or x64." % abi)
    return _ANDROID_ABI_FOR_ARCH[abi]
