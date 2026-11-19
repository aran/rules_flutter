"""Flutter rules for Android builds.

Two tiers of API:

    Tier 1 — flutter_android_app (self-contained, recommended):

        load("@rules_flutter//flutter:android.bzl", "flutter_android_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_android_app(
            name = "my_app_android",
            application = ":my_app",
            application_id = "com.example.myapp",
            app_bundle = "my_app_bundle",
        )

        # `bazel run :my_app_release` signs the App Bundle and an APK with
        # the upload key in android/key.properties, as `flutter build
        # appbundle` and `flutter build apk` do.
        flutter_android_release(name = "my_app_release", app_bundle = ":my_app_bundle")

        # Add-to-app: the module as a local Maven repository for a Gradle-built
        # host, as `flutter build aar` makes one. `bazel run` writes it to
        # build/host/outputs/repo/ and prints the host's steps.
        flutter_android_aar(
            name = "my_module_aar",
            application = ":my_app",
            package_name = "com.example.my_module",
        )

    Prerequisites: run `flutter create --platforms=android .` in your package to
    generate the conventional `android/app/src/main/` directory with
    AndroidManifest.xml, resources, and Kotlin sources. The macro handles everything
    automatically — no edits to the flutter create output needed.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:android.bzl",
            "ANDROID_MIN_SDK_VERSION",
            "ANDROID_TARGET_SDK_VERSION",
            "flutter_android_build",
            "flutter_android_bundle",
            "flutter_android_engine",
            "flutter_android_manifest_gen",
            "flutter_android_manifest_merge",
            "flutter_android_maven_repo",
            "flutter_android_module_aar",
            "flutter_android_plugin_aars",
            "flutter_android_release",
            "flutter_android_runner_lib_gen")

        # Its native libraries reach android_binary as an aar_import's do.
        flutter_android_bundle(name = "my_bundle", application = ":my_app")
        flutter_android_engine(name = "my_engine")

        # The flutter_assets tree at assets/flutter_assets/, as the APK holds it.
        filegroup(
            name = "my_flutter_assets",
            srcs = [":my_bundle"],
            output_group = "flutter_assets",
        )

        flutter_android_manifest_gen(name = "my_manifest", application_id = "com.example.myapp")

        flutter_android_runner_lib_gen(
            name = "my_runner",
            namespace = "com.example.myapp",
            engine = ":my_engine",
        )

        android_binary(
            name = "my_apk",
            manifest = ":my_manifest",
            assets = [":my_flutter_assets"],
            assets_dir = "assets",
            # Stored uncompressed, as the manifest's
            # android:extractNativeLibs="false" requires.
            nocompress_extensions = [".so"],
            deps = [":my_bundle", ":my_engine", ":my_runner"],
        )

    The App Bundle is rules_android's `android_application` from the same
    arguments, with rules_flutter's bundle configuration:

        android_application(
            name = "my_aab",
            bundle_config_file = "@rules_flutter//flutter:android_bundle_config.pb.json",
            manifest = ":my_manifest",
            manifest_values = {"applicationId": "com.example.myapp"},
            assets = [":my_flutter_assets"],
            assets_dir = "assets",
            nocompress_extensions = [".so"],
            deps = [":my_bundle", ":my_engine", ":my_runner"],
        )

        flutter_android_release(name = "my_release", app_bundle = ":my_aab")

    The add-to-app repository, `flutter_android_aar`, is these three over the
    bundle and a registrant compiled against a `neverlink` engine:

        flutter_android_module_aar(
            name = "my_module",
            bundle = ":my_bundle",
            library = ":my_registrant",  # a kt_android_library of flutter_android_registrant
            package_name = "com.example.my_module",
            min_sdk_version = ANDROID_MIN_SDK_VERSION,
        )
        flutter_android_plugin_aars(name = "my_plugins", application = ":my_app")
        flutter_android_maven_repo(name = "my_repo", module = ":my_module", plugins = ":my_plugins")

    rules_android runs R8 only for an `android_binary` with `proguard_specs`.
    `flutter_android_app` gives a release build
    `@rules_flutter//flutter:android_proguard_rules.pro`, as `flutter build
    --release` shrinks; give your own binary the same to match it.
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//android:rules.bzl", _android_application = "android_application", _android_binary = "android_binary", _android_library = "android_library")
load("@rules_dart//dart:defs.bzl", "dart_binary")
load("@rules_java//java:java_import.bzl", _java_import = "java_import")
load("@rules_jvm_external//:defs.bzl", "artifact")
load("@rules_kotlin//kotlin:android.bzl", _kt_android_library = "kt_android_library")
load("@rules_kotlin//kotlin:core.bzl", _kt_kotlinc_options = "kt_kotlinc_options")
load("//flutter/private:android_debug_info.bzl", _flutter_android_debug_info = "flutter_android_debug_info")
load("//flutter/private:app_version.bzl", "manifest_values_conflict", "version_arg")
load("//flutter/private:common.bzl", _ANDROID_EMBEDDING_MAVEN_DEPS = "ANDROID_EMBEDDING_MAVEN_DEPS")
load("//flutter/private:constants.bzl", _ANDROID_MIN_SDK_VERSION = "ANDROID_MIN_SDK_VERSION", _ANDROID_REGISTRANT_JVM_TARGET = "ANDROID_REGISTRANT_JVM_TARGET", _ANDROID_TARGET_SDK_VERSION = "ANDROID_TARGET_SDK_VERSION")
load("//flutter/private:flutter_android_aar.bzl", _DEFAULT_AAR_ABIS = "DEFAULT_AAR_ABIS", _flutter_android_maven_repo = "flutter_android_maven_repo", _flutter_android_module_aar = "flutter_android_module_aar", _flutter_android_plugin_aars = "flutter_android_plugin_aars")
load("//flutter/private:flutter_android_application.bzl", _flutter_android_bundle = "flutter_android_bundle")
load("//flutter/private:flutter_android_build.bzl", _flutter_android_build = "flutter_android_build")
load("//flutter/private:flutter_android_bundle_install.bzl", _flutter_android_app_bundle = "flutter_android_app_bundle")
load("//flutter/private:flutter_android_classes.bzl", _LISTENABLEFUTURE_RUNTIME = "LISTENABLEFUTURE_RUNTIME", _flutter_android_class_check = "flutter_android_class_check", _flutter_android_listenablefuture = "flutter_android_listenablefuture")
load("//flutter/private:flutter_android_manifest_merge.bzl", _flutter_android_manifest_merge = "flutter_android_manifest_merge")
load("//flutter/private:flutter_android_plugin_library.bzl", _flutter_android_plugin_library = "flutter_android_plugin_library")
load("//flutter/private:flutter_android_plugin_libs.bzl", _flutter_android_maven_report = "flutter_android_maven_report", _flutter_android_plugin_libs = "flutter_android_plugin_libs")
load("//flutter/private:flutter_android_registrant.bzl", _flutter_android_registrant = "flutter_android_registrant")
load("//flutter/private:flutter_android_release.bzl", _flutter_android_release = "flutter_android_release")

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
    Label(artifact(coordinate, repository_name = "rules_flutter_maven"))
    for coordinate in _ANDROID_EMBEDDING_MAVEN_DEPS
]

# -- Composable rules (Tier 2) ------------------------------------------------

def _android_only():
    """`target_compatible_with` for a target built only for Android arm, arm64 or x86_64.

    A target that takes its ABI from the platform it is built for has nothing to
    build on any other, so a wildcard on a non-Android platform skips it rather
    than failing on it. Its dependents are skipped with it.
    """
    return select({
        "@rules_flutter//flutter/private:android_arm": [],
        "@rules_flutter//flutter/private:android_arm64": [],
        "@rules_flutter//flutter/private:android_x64": [],
        "//conditions:default": [Label("@platforms//:incompatible")],
    })

def flutter_android_bundle(name, **kwargs):
    """Bundles Flutter compilation outputs for Android packaging.

    See `flutter/private/flutter_android_application.bzl` for the rule. The
    bundle is built for the Android platform `android_binary` builds it for, so
    it is incompatible with any other platform: `bazel build //...` on a host
    platform skips it, with no `manual` tag.

    Args:
        name: Target name.
        **kwargs: Arguments of the rule: `application`, and the common ones
            (`tags`, `visibility`, ...).
    """
    kwargs["target_compatible_with"] = kwargs.pop("target_compatible_with", []) + _android_only()
    _flutter_android_bundle(name = name, **kwargs)

# Builds targets for given Android platforms, whatever the command line asked
# for: a test of an APK for one ABI, or several, in a plain `bazel test //...`.
flutter_android_build = _flutter_android_build

# Signs an App Bundle (an `android_application`, such as
# `flutter_android_app`'s `app_bundle`) and the APK of the same build with
# the app's upload key, when `bazel run`. Builds the bundle in release mode for
# every ABI. The key is read at run time from Flutter's `key.properties` and
# never reaches the build graph. See flutter/private/flutter_android_release.bzl.
flutter_android_release = _flutter_android_release

# Applied from the command line, gives an APK (`android_binary`) the
# `.symbols` of the snapshots it ships in its `debug_info` output group. See
# flutter/private/android_debug_info.bzl.
flutter_android_debug_info = _flutter_android_debug_info

# The AAR of a Flutter module (`flutter_<mode>`), the AARs of its plugins, and
# the Maven repository of both, for a Gradle-built host app: the pieces of
# `flutter_android_aar`. See flutter/private/flutter_android_aar.bzl.
flutter_android_module_aar = _flutter_android_module_aar
flutter_android_plugin_aars = _flutter_android_plugin_aars
flutter_android_maven_repo = _flutter_android_maven_repo

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

# Public wrapper that compiles a Flutter plugin's Android Kotlin/Java sources
# into a kt_android_library. For pub.dev plugins, flutter_pub_package emits
# this automatically; expose it here so users can wire a monorepo plugin's
# BUILD.bazel without going through the flutter/ext/ overlay system.
flutter_android_plugin_library = _flutter_android_plugin_library

# Links the Android libraries of the plugins a flutter_application depends on,
# and checks the Maven artifacts their Gradle builds declare. Wired
# automatically by flutter_android_app; expose for Tier-2 control.
flutter_android_plugin_libs = _flutter_android_plugin_libs

def flutter_android_maven_artifacts(name, application, maven, **kwargs):
    """A program that prints the Maven artifacts an application's plugins need.

    `bazel run` of it prints the lines to paste into
    `maven.install(name = "rules_flutter_maven", artifacts = [...])` for the
    plugins `application` depends on and no others, marking those the install
    lacks or has too low. It also prints the artifacts the install resolves
    that Gradle would raise: those whose versions the Gradle module metadata
    of another artifact aligns (androidx `activity` 1.9.0 asks for
    `activity-ktx` 1.9.0), which rules_jvm_external does not read. That
    metadata it fetches from the install's repositories when it runs, or,
    with `-- --metadata=<file>`, reads from a snapshot that
    `-- --record=<file>` wrote.
    `flutter_android_app` declares one as `<name>_maven_artifacts`; declare
    this one for Tier-2 wiring.

    Args:
        name: The target name.
        application: The `flutter_application` whose plugins to report on.
        maven: The build's Maven requirements: `@<hub>//android:maven_requirements`
            of any `flutter_pub.from_lock` hub.
        **kwargs: Passed to both targets the macro declares (`tags`,
            `testonly`, `visibility`).
    """
    _flutter_android_maven_report(
        name = "__%s_report" % name,
        app_label = str(native.package_relative_label(application)).removeprefix("@@"),
        application = application,
        maven = maven,
        **dict(kwargs, visibility = ["//visibility:private"])
    )
    dart_binary(
        name = name,
        args = ["$(rlocationpath :__%s_report)" % name],
        compile_mode = "exe",
        data = [":__%s_report" % name],
        deps = [Label("@rules_dart//dart/runfiles")],
        main = Label("//flutter/private/tools:maven_artifacts.dart"),
        **kwargs
    )

# Registrant rule that emits GeneratedPluginRegistrant.java from a
# flutter_application's transitive FlutterInfo. Wired automatically by
# flutter_android_app; expose for Tier-2 control.
flutter_android_registrant = _flutter_android_registrant

# The engine of each ABI an APK can be built for, by the CPU of the platform
# `android_binary` builds that copy of its dependencies for. The labels are
# rules_flutter's own, resolved from its `use_repo` of the extension's engine
# repositories, so a workspace names none of them. A caller's label would have
# to be visible to the workspace for every branch of the `select()`, because
# `bazel query` and the tooling built on it load them all; a build resolves
# only the one it takes.
_ENGINE_FOR_CPU = {
    "@rules_flutter//flutter/private:android_arm": [Label("@flutter_android_engine_arm//:stripped")],
    "@rules_flutter//flutter/private:android_arm64": [Label("@flutter_android_engine_arm64//:stripped")],
    "@rules_flutter//flutter/private:android_x64": [Label("@flutter_android_engine_x64//:stripped")],
}

_NO_ENGINE_FOR_PLATFORM = (
    "flutter_android_engine is built for a platform that is not Android arm, arm64 " +
    "or x86_64. An Android app is built for the platforms of --@rules_android//flags:android_platforms: " +
    "pass --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a " +
    "(and :armeabi-v7a or :x86_64 for a second ABI), or build it through flutter_android_build."
)

def flutter_android_engine(name, neverlink = False, **kwargs):
    """Imports the Flutter engine (flutter.jar) as an android_library target.

    The engine is the one of the platform the target is built for. An
    `android_binary` builds its dependencies once for each platform of
    `--@rules_android//flags:android_platforms`, so an APK for several ABIs carries the engine of
    each, and a target built for none of Android arm, arm64 and x86_64 fails. The
    engine repositories are rules_flutter's: nothing goes in your `use_repo`.

    Auto-selects the engine of the build mode:
    - Debug (-c dbg): JIT engine for emulator/iterative development.
    - Profile (-c opt with --@rules_flutter//flutter:profile): AOT engine
      with the Dart VM service.
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
        neverlink: Compile against the engine without packaging it. For
            `flutter_android_plugin_library(flutter_engine = ...)`; the
            engine in the app's `android_binary` deps leaves it False.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    _flutter_android_engine(name, neverlink, listenablefuture = not neverlink, **kwargs)

def _flutter_android_engine(name, neverlink, listenablefuture, **kwargs):
    """`flutter_android_engine`, linking listenablefuture 1.0 if `listenablefuture`.

    androidx needs `com.google.guava:listenablefuture` at runtime, and
    `@rules_flutter_maven` has it on the compile classpath only (see
    `flutter_android_listenablefuture`). A linked engine of your own
    `android_binary` links it; `flutter_android_app`'s does not, and the app
    links it when Gradle would.
    """
    tags = kwargs.pop("tags", ["manual"])

    # The engine of an ABI exists for platforms of that ABI only.
    compatible_with = kwargs.pop("target_compatible_with", [])
    if not neverlink:
        compatible_with = compatible_with + _android_only()

    # A neverlink engine is compiled against, and its classes are the same for
    # every ABI, so it is the arm64 engine whatever platform the plugin is
    # built for. That keeps a plugin library buildable on its own, with no
    # Android platform.
    if neverlink:
        engine = [Label("@flutter_android_engine_arm64//:stripped")]
    else:
        engine = select(_ENGINE_FOR_CPU, no_match_error = _NO_ENGINE_FOR_PLATFORM)

    # `deps` (not just the wrapper's exports) matters here: flutter.jar's
    # own desugar action takes its classpath from the java_import's
    # direct deps, and desugaring io.flutter.* against an incomplete
    # classpath fails the deploy jar's desugar-dependency check.
    #
    # The jar holds the classes. The engine's libraries are not in it, and
    # reach the APK as the engine target's AndroidNativeLibsInfo (below).
    _java_import(
        name = "_%s_jar" % name,
        # The engine repo's `stripped` follows the build mode, and fetches
        # the profile engine's repo only in a profile build.
        jars = engine,
        tags = tags,
        neverlink = neverlink,
        target_compatible_with = compatible_with,
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
    #
    # The engine's libraries are the exports an APK packages and a plugin's
    # compile does not need.
    _android_library(
        name = name,
        exports = ["_%s_jar" % name] + _ANDROIDX_EMBEDDING_DEPS + ([] if neverlink else engine) +
                  ([_LISTENABLEFUTURE_RUNTIME] if listenablefuture else []),
        proguard_specs = ["@rules_flutter//flutter/private/runners/android:flutter_engine_proguard.pro"],
        neverlink = neverlink,
        tags = tags,
        target_compatible_with = compatible_with,
        **kwargs
    )

def flutter_android_manifest_gen(
        name,
        application_id,
        app_name = None,
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        **kwargs):
    """Generates an AndroidManifest.xml from the default Bazel template.

    The template uses FlutterActivity as the main activity with embedding v2.

    It declares `android:extractNativeLibs="false"`, as AGP does, so the
    `android_binary` it goes to must store its libraries uncompressed with
    `nocompress_extensions = [".so"]`: Android refuses to install an APK whose
    manifest says so and whose libraries are compressed.

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

        flutter_android_manifest_gen(name = "base", application_id = "...")
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
        application_id: The application id, e.g. "com.example.myapp": the
            manifest's `package`.
        app_name: Display name for the app. Defaults to `application_id`.
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])
    display_name = app_name or application_id

    substitutions = {
        "PACKAGE_NAME": application_id,
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
        namespace,
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
        namespace: The Kotlin package of the generated Activity, as Gradle's
            `namespace` (e.g. "com.example.myapp"). Also the library manifest's
            package and label.
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
            "PACKAGE_NAME": namespace,
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
                "PACKAGE_NAME": namespace,
                "APP_NAME": namespace,
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
        # `allow_empty`: a variant overlay is optional; most apps have none.
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

def _registrant_library(name, deps, tags, testonly):
    """Compiles the `flutter_android_registrant` `<name>_src` as `name`.

    At the Java level `flutter create`'s templates compile it at, not the Kotlin
    toolchain's default, whose Java 8 javac reports as obsolete under
    `-Xlint:all`.

    Args:
        name: The library's name.
        deps: The engine and the plugins' libraries the registrant names.
        tags: The tags of both targets.
        testonly: The `testonly` of both targets.
    """
    _kt_kotlinc_options(
        name = name + "_kotlinc_opts",
        jvm_target = _ANDROID_REGISTRANT_JVM_TARGET,
        tags = tags,
        testonly = testonly,
    )
    _kt_android_library(
        name = name,
        srcs = [name + "_src"],
        custom_package = "io.flutter.plugins",
        kotlinc_opts = name + "_kotlinc_opts",
        tags = tags,
        testonly = testonly,
        deps = deps,
    )

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_android_app(
        name,
        application,
        application_id,
        app_name = None,
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        manifest = None,
        debug_manifest = None,
        profile_manifest = None,
        permissions = [],
        resources = [],
        deps = [],
        namespace = None,
        build_name = None,
        build_number = None,
        manifest_values = None,
        proguard_specs = None,
        app_bundle = None,
        bundle_config = Label("//flutter:android_bundle_config.pb.json"),
        **kwargs):
    """Builds a Flutter Android APK from a flutter_application target.

    Discovers runner files from the conventional `android/app/src/main/`
    directory (as generated by `flutter create --platforms=android .`) and
    wires up all internal targets automatically.

    The ABIs of the APK are those of `--@rules_android//flags:android_platforms`, as for any
    `android_binary`: one platform builds an APK for that ABI, several build one
    APK for all of them (`flutter build apk`'s fat APK). The Flutter engine, the
    app's `libapp.so`, the AARs' native libraries and any C++ deps are each
    packaged for every ABI. Name the platforms rules_android ships,
    `@rules_android//:armeabi-v7a`, `@rules_android//:arm64-v8a` and
    `@rules_android//:x86_64`:

        bazel build //:my_app_android --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a

    With no `--@rules_android//flags:android_platforms`, rules_android builds
    for `--platforms`, the host's, with which the engine and the bundle are
    incompatible: building the app fails as incompatible, naming the platform,
    and `bazel build //...` skips it. To fix the ABI of a target
    regardless of the command line, as a test does, wrap it in
    `flutter_android_build`.

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

    The runner's sources, where Gradle looks for them (Kotlin under
    android/app/src/main/kotlin/ or java/, Java under java/, as
    `flutter create --android-language java` writes it), are compiled via
    kt_android_library with the Flutter engine and AndroidX deps.

    Plugin auto-wiring:
      - Generates a `flutter_android_registrant` target whose application is
        `application`, then compiles the resulting Java into a private
        `kt_android_library` that goes into `binary_deps`. Every plugin
        whose `flutter.plugin.platforms.android.pluginClass` is set ends up
        registered with the FlutterEngine on startup — no manual wiring.
      - Links the Kotlin/Java sources (and resources) of the plugins
        `application` depends on, and of those only
        (`flutter_android_plugin_libs`): the `exports` each plugin
        selects on Android. A plugin the lock lists and the application does
        not use contributes no code, no manifest entries and no Maven
        requirements to the APK.
      - Checks the Maven artifacts the Gradle builds of those plugins
        declare against `@rules_flutter_maven`, failing with every one the
        app lacks, by name.
      - Permissions that plugins and AARs declare in their own manifests
        (e.g. record_android's RECORD_AUDIO) are lifted into the app's
        manifest, as AGP merges them. Bazel's own merger drops library
        permissions unless `--merge_android_manifest_permissions` is set;
        the app no longer depends on that flag.

    Args:
        name: Target name (Bazel identifier). Produces an android_binary.
        application: A flutter_application target (required).
        application_id: The application id, e.g. "com.example.myapp", as
            Gradle's `applicationId` (required).
        namespace: The package the runner's code lives in, as Gradle's
            `namespace` (and AGP's R class package) in build.gradle.
            Defaults to `application_id`, which `flutter create` sets equal
            to it. Set it when the runner declares another package, e.g.
            one runner shipped under several application ids. The
            manifest's relative class names (`.MainActivity`,
            `.sub.Receiver`, a bare `MainActivity`) are written out in
            full against it, as AGP does; qualified names are untouched.
        app_name: User-facing display name. Defaults to name.
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version, Gradle's
            `targetSdk`. Defaults to 36, the Flutter Gradle plugin's
            `flutter.targetSdkVersion`.
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
        build_name: versionName, as `flutter build --build-name`. Defaults to
            `1.0.0`. May be a `select()`, whose `None` is the default.
            Unset, the `application`'s `build_name`. Set, the
            `application` must set the same.
            `--@rules_flutter//flutter:build_name` replaces both for one build.
        build_number: versionCode, as `flutter build --build-number`: a
            whole number from 1 to 2100000000, Google Play's limit. Defaults
            to `1`. May be a `select()`.
            Unset, the `application`'s `build_number`. Set, the
            `application` must set the same.
            `--@rules_flutter//flutter:build_number` replaces both for one build. A manifest that declares
            `android:versionCode` or `android:versionName` itself must
            declare the app's version, the program's, or the build fails.
        manifest_values: `android_binary`'s `manifest_values`: values for
            the manifest's `${...}` placeholders. The macro sets
            `applicationId`, `minSdkVersion` and `targetSdkVersion` from
            `application_id`, `min_sdk_version` and `target_sdk_version`, so
            naming them here is an error. `versionCode` and `versionName`
            are allowed while `build_number` and `build_name` are unset,
            and are then held to the `application`'s as those are. They
            are written as given, so `--@rules_flutter//flutter:build_name`
            and `build_number` do not change them: built with the setting of
            one set to another value, the app fails to build.
            Other keys pass through. A dict, not a `select()`.
        proguard_specs: The R8 configuration of the APK. By default a
            release build (`-c opt` without
            `--@rules_flutter//flutter:profile`) is shrunk with R8 as
            `flutter build apk --release` shrinks it:
            `@rules_flutter//flutter:android_proguard_rules.pro` (the Android
            Gradle plugin's proguard-android-optimize.txt and Flutter's
            rules), then `android/app/proguard-rules.pro` when `flutter
            create`'s directory has one; debug and profile builds are not
            shrunk. A list (or `select()`) replaces that whole default, in
            every compilation mode; `[]` turns R8 off. Resources are shrunk
            whenever R8 runs, unless `shrink_resources = False` is passed.
        app_bundle: When set, also declare an App Bundle of this app named
            `app_bundle`, built by rules_android's `android_application` from
            the same arguments as the APK. Its output is the unsigned
            `<app_bundle>_unsigned.aab`, for the ABIs and compilation mode of
            the build like the APK's. `bazel run` of it installs it on the
            device `ANDROID_SERIAL` names with bundletool, signed with the
            debug key. Hand it to `flutter_android_release` to sign a release.
            With `--@rules_dart//dart:split_debug_info`, its `debug_info`
            output group holds the `.symbols` of each ABI's `libapp.so`
            (`app.android-arm64.symbols`), which are the APK's too.
        bundle_config: The bundletool `BundleConfig` (`.pb.json`) of
            `app_bundle`. The default,
            `@rules_flutter//flutter:android_bundle_config.pb.json`, is the
            Android Gradle plugin's: split by ABI, screen density and
            language, with native libraries and dex stored uncompressed and
            the libraries 16 KB-aligned. Setting it replaces the default.
        **kwargs: Passed through to android_binary, except `testonly`, which
            every target the macro declares has, since one that depends on a
            `testonly` application would otherwise fail analysis.
    """
    display_name = app_name or name
    namespace = namespace or application_id
    tags = kwargs.pop("tags", ["manual"])
    testonly = kwargs.pop("testonly", False)
    manifest_values = {} if manifest_values == None else manifest_values
    conflict = manifest_values_conflict(
        "flutter_android_app(name = %r)" % name,
        manifest_values,
        build_name,
        build_number,
    )
    if conflict:
        fail(conflict)
    if "custom_package" in kwargs:
        fail("flutter_android_app(name = %r): set `namespace`, which is the APK's `custom_package`" % name)

    # `android_binary` writes a `versionCode` or `versionName` of
    # `manifest_values` over the manifest's, so it states the app's version
    # as the argument would: it must be the application's.
    version_stated_as = {}
    for key, arg in [("versionCode", "build_number"), ("versionName", "build_name")]:
        if key in manifest_values:
            version_stated_as[arg] = "`%s` in `manifest_values`" % key
    if "build_number" in version_stated_as:
        build_number = manifest_values["versionCode"]
    if "build_name" in version_stated_as:
        build_name = manifest_values["versionName"]
    manifest_values = {
        "applicationId": application_id,
        "minSdkVersion": min_sdk_version,
        "targetSdkVersion": target_sdk_version,
    } | manifest_values

    # -- Internal targets (all __{name}_ prefixed) --
    #
    # The engine and the bundle are built for the Android platforms of the APK
    # that depends on them, once for each. On any other platform they are
    # incompatible, and so are the targets that depend on them, so a wildcard
    # skips them.

    # 1. Bundle Flutter outputs (libapp.so and the other native libraries +
    # flutter_assets). Built for each platform of --@rules_android//flags:android_platforms, as the
    # rest of android_binary's deps are.
    flutter_android_bundle(
        name = "__%s_bundle" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )

    # 2. The bundle is a dependency of android_binary itself, which packages
    # the native libraries of each ABI it builds it for (`libapp.so`, the
    # `native_deps` libraries and the code assets that ship) from its
    # `AndroidNativeLibsInfo`, as it does an `aar_import`'s.

    # 4. Import Flutter engine. listenablefuture is the app's own choice:
    # see step 9b.
    _flutter_android_engine(
        name = "__%s_engine" % name,
        neverlink = False,
        listenablefuture = False,
        tags = tags,
        testonly = testonly,
    )

    # 5. The flutter_assets tree for the APK, laid out at
    # assets/flutter_assets/ for `assets_dir = "assets"`.
    native.filegroup(
        name = "__%s_flutter_assets" % name,
        srcs = ["__%s_bundle" % name],
        output_group = "flutter_assets",
        tags = tags,
        testonly = testonly,
    )

    # 6. Auto-wire the plugin registrant. Generates
    # `GeneratedPluginRegistrant.java` from the flutter_application's
    # transitive FlutterInfo plugin metadata, then wraps it in a
    # kt_android_library so the registrant class is on the runtime
    # classpath (called from the runner's MainActivity / FlutterActivity).
    #
    # The registrant references each plugin's `PluginClass` by fully
    # qualified name, so its compile classpath must include every
    # plugin's `kt_android_library`. The libraries of the plugins the
    # application depends on are linked once, for the registrant and the
    # APK alike.
    # The Maven data of every pub package of the build, whichever hub lists it.
    maven = Label("@flutter_pub_android_maven//:requirements")
    _flutter_android_plugin_libs(
        name = "__%s_plugin_libs" % name,
        deps = [application],
        maven = maven,
        report = "//%s:%s_maven_artifacts" % (native.package_name(), name),
        tags = tags,
        testonly = testonly,
    )
    flutter_android_maven_artifacts(
        name = "%s_maven_artifacts" % name,
        application = application,
        maven = maven,
        tags = tags,
        testonly = testonly,
    )
    _flutter_android_registrant(
        name = "__%s_registrant_src" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )

    # `deps` too: a plugin written in the workspace reaches the app only
    # through them, and the registrant names its class.
    registrant_deps = ["__%s_engine" % name, "__%s_plugin_libs" % name] + deps

    _registrant_library(
        name = "__%s_registrant" % name,
        tags = tags,
        testonly = testonly,
        deps = registrant_deps,
    )

    # 7. Resolve manifests (main + debug variant), resources, and Kotlin
    # sources.
    base_manifest = manifest
    app_proguard_rules = []
    binary_deps = [
        "__%s_engine" % name,
        "__%s_registrant" % name,
    ]

    # 8. Plugin auto-wiring: the Kotlin/Java of the plugins the application
    # depends on, linked by `flutter_android_plugin_libs`.
    binary_deps.append("__%s_plugin_libs" % name)

    if not base_manifest:
        # Try to discover flutter create output. `allow_empty`: an app
        # assembled without `flutter create`'s `android/` directory is a
        # supported case; the macro then needs the `base_manifest` argument.
        discovered_manifests = native.glob(
            ["android/app/src/main/AndroidManifest.xml"],
            allow_empty = True,
        )
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
                testonly = testonly,
            )
            base_manifest = "__%s_manifest" % name

            # Discover resources from flutter create output. `allow_empty`:
            # an app may ship none.
            discovered_resources = native.glob(
                ["android/app/src/main/res/**"],
                allow_empty = True,
            )
            resources = list(resources) + discovered_resources

            # The app's own R8 rules, where `flutter create` leaves room for
            # them and the Flutter Gradle plugin looks. `allow_empty`: most
            # apps have none.
            app_proguard_rules = native.glob(
                ["android/app/proguard-rules.pro"],
                allow_empty = True,
            )

            # Discover and compile the runner from flutter create output:
            # Gradle's main source directories for Kotlin and Java. Not the
            # plugin registrant `flutter run` writes there: the
            # `__{name}_registrant` above is this app's. `allow_empty`: an app
            # may keep all of its code in Dart.
            runner_sources = native.glob(
                [
                    "android/app/src/main/kotlin/**/*.kt",
                    "android/app/src/main/java/**/*.java",
                    "android/app/src/main/java/**/*.kt",
                ],
                exclude = [
                    "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java",
                ],
                allow_empty = True,
            )
            if runner_sources:
                _kt_android_library(
                    name = "__%s_runner" % name,
                    srcs = runner_sources,
                    custom_package = namespace,
                    tags = tags,
                    testonly = testonly,
                    deps = ["__%s_engine" % name],
                )
                binary_deps.append("__%s_runner" % name)

    # Resolve the variant overlays — every state explicit:
    #   False → no variant handling, even if the file exists.
    #   None  → discover flutter create's variant manifest.
    #   label → use it, overriding discovery.
    debug_overlay = _variant_overlay(name, "debug", debug_manifest, base_manifest)
    profile_overlay = _variant_overlay(name, "profile", profile_manifest, base_manifest)

    if base_manifest == None:
        # No flutter create output — generate manifest from template. The
        # generated manifest handles the debug and profile INTERNET
        # permission itself (see flutter_android_manifest_gen).
        flutter_android_manifest_gen(
            name = "__%s_manifest" % name,
            application_id = application_id,
            app_name = display_name,
            min_sdk_version = min_sdk_version,
            target_sdk_version = target_sdk_version,
            tags = tags,
            testonly = testonly,
        )
        actual_manifest = "__%s_manifest" % name
    elif debug_overlay != None or profile_overlay != None:
        # Fold each variant's permissions into its own mode's APKs, the merge
        # Gradle performs per build type. Release APKs keep the main
        # manifest, byte-identical to a build without the variants.
        variants = {}
        for mode, overlay in [("dbg", debug_overlay), ("profile", profile_overlay)]:
            if overlay == None:
                continue
            flutter_android_manifest_merge(
                name = "__%s_manifest_merged_%s" % (name, mode),
                base = base_manifest,
                overlay = overlay,
                tags = tags,
                testonly = testonly,
            )
            variants["@rules_flutter//flutter/private:" + mode] = "__%s_manifest_merged_%s" % (name, mode)
        actual_manifest = select(variants | {"//conditions:default": base_manifest})
    else:
        actual_manifest = base_manifest

    # 8b. Add the app's own permissions to whatever manifest the mode
    # produced. Applied last and in every compilation mode, so a permission
    # the app needs cannot go missing from the release APK the way
    # `flutter create`'s debug-variant INTERNET does.
    if permissions:
        flutter_android_permissions_manifest(
            name = "__%s_permissions" % name,
            permissions = permissions,
            tags = tags,
            testonly = testonly,
        )
        flutter_android_manifest_merge(
            name = "__%s_manifest_with_permissions" % name,
            base = actual_manifest,
            overlay = "__%s_permissions" % name,
            tags = tags,
            testonly = testonly,
        )
        actual_manifest = "__%s_manifest_with_permissions" % name

    # 8c. Lift the permissions the app's Android libraries declare (plugins,
    # AARs) into its own manifest, as Gradle does. Bazel's merger drops them
    # unless --merge_android_manifest_permissions is set; done here, they
    # reach the APK whatever the flags.
    #
    # The same action writes the manifest's relative class names
    # (`.MainActivity`) in full against the namespace, as AGP does. Left
    # relative, Android resolves them against `application_id`, which need
    # not be the code's package: a second app shipping the same runner under
    # its own id would name a class that does not exist.
    #
    # And it sets the app's version on the manifest, from `build_name` and
    # `build_number`, and `android:extractNativeLibs="false"`: see step 10.
    flutter_android_manifest_merge(
        name = "__%s_manifest_with_library_permissions" % name,
        base = actual_manifest,
        libraries = binary_deps + deps,
        placeholders = sorted(manifest_values.keys()),
        namespace = namespace,
        set_version = True,
        uncompressed_native_libs = True,
        application = application,
        build_name = version_arg(build_name),
        build_number = version_arg(build_number),
        version_stated_as = version_stated_as,
        tags = tags,
        testonly = testonly,
    )
    actual_manifest = "__%s_manifest_with_library_permissions" % name

    # 9. R8 in release, as the Flutter Gradle plugin turns on `minifyEnabled`
    # and `shrinkResources` for the release build type only. rules_android runs
    # R8 exactly when `proguard_specs` is non-empty, and shrinks resources only
    # then.
    if proguard_specs == None:
        proguard_specs = select({
            Label("//flutter:release"): [Label("//flutter:android_proguard_rules.pro")] + app_proguard_rules,
            "//conditions:default": [],
        })
    kwargs.setdefault("shrink_resources", True)

    # Native libraries stored uncompressed and 16 KB-aligned, as AGP packages
    # them for a minimum SDK of 23 or more (`jniLibs.useLegacyPackaging`,
    # false by default): Android maps them straight from the APK instead of
    # extracting a second copy at install. rules_android's zipalign
    # page-aligns stored `.so` files; the manifest step above tells the
    # installer not to extract them. `.so` stays whatever else is given,
    # since the manifest promises it.
    kwargs["nocompress_extensions"] = kwargs.pop("nocompress_extensions", []) + [".so"]

    # 9b. listenablefuture 1.0 at runtime, unless the app links a Guava that
    # brings the interface, as Gradle resolves it: see
    # flutter_android_classes.bzl.
    _flutter_android_listenablefuture(
        name = "__%s_listenablefuture" % name,
        libraries = binary_deps + deps,
        tags = tags,
        testonly = testonly,
    )
    binary_deps.append("__%s_listenablefuture" % name)

    # 9c. Fail the build when two jars the app links define a class
    # differently, which Gradle's resolution would not let happen: see
    # flutter_android_classes.bzl. A dependency of the binary, so building the
    # app runs it.
    _flutter_android_class_check(
        name = "__%s_class_check" % name,
        app = "//%s:%s" % (native.package_name(), name),
        libraries = binary_deps + deps,
        report = "//%s:%s_maven_artifacts" % (native.package_name(), name),
        tags = tags,
        testonly = testonly,
    )

    # 10. Final android_binary, and the App Bundle beside it. rules_android's
    # `android_application` declares an `android_binary` of its own,
    # `<app_bundle>_base`, from the same arguments: it cannot take this one.
    binary_args = dict(
        # The R class package, as AGP takes it from `namespace`: unset, it
        # is the manifest's package, the application id. `bazel
        # mobile-install` needs it set, or a java/ directory in the BUILD
        # package's path to infer it from.
        custom_package = namespace,
        manifest = actual_manifest,
        manifest_values = manifest_values,
        resource_files = resources if resources else None,
        assets = ["__%s_flutter_assets" % name],
        assets_dir = "assets",
        # The bundle is built for the ABIs android_binary builds; the class
        # check, which reads the Java libraries of `binary_deps`, is not.
        deps = binary_deps + ["__%s_bundle" % name] + deps + ["__%s_class_check" % name],
        proguard_specs = proguard_specs,
        tags = tags,
        testonly = testonly,
        **kwargs
    )
    _android_binary(name = name, **binary_args)
    if app_bundle:
        # The bundle is rules_android's; `app_bundle` forwards it and gives
        # `bazel run` rules_flutter's install program, which takes every tool
        # from the build.
        bundle = "__%s_aab" % app_bundle
        _android_application(
            name = bundle,
            bundle_config_file = bundle_config,
            **binary_args
        )
        _flutter_android_app_bundle(
            name = app_bundle,
            bundle = bundle,
            tags = tags,
            testonly = testonly,
            visibility = kwargs.get("visibility"),
        )

def flutter_android_aar(
        name,
        application,
        package_name,
        build_number = "1.0",
        abis = _DEFAULT_AAR_ABIS,
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        **kwargs):
    """A Flutter module as a local Maven repository, as `flutter build aar` makes one.

    For a native Android app built with Gradle (add-to-app). The repository
    holds the module's AAR, `<package_name>:flutter_<mode>:<build_number>`,
    and one AAR per plugin with Android code, `<group>:<plugin>_<mode>:<build_number>`;
    the module's POM depends on Flutter's engine artifacts
    (`io.flutter:flutter_embedding_<mode>` and `io.flutter:<abi>_<mode>`) and
    on the plugins'. With an engine that is not the release's, the repository
    holds that engine's artifacts too. See `flutter_android_maven_repo` for
    the layout.

    The mode is the command line's: `-c dbg` is debug, `-c opt
    --@rules_flutter//flutter:profile` profile, and otherwise release.
    `bazel build` makes that mode's repository in `bazel-bin`; `bazel run`
    adds it to `build/host/outputs/repo/` under the package (or
    `-- --output=<dir>`), beside what runs in other modes wrote, and prints
    the host app's steps:

        flutter_android_aar(
            name = "module_aar",
            application = ":my_app",
            package_name = "com.example.my_module",
        )

        bazel run -c dbg //:module_aar
        bazel run -c opt //:module_aar

    With `--@rules_dart//dart:split_debug_info`, the target's `debug_info`
    output group holds the `.symbols` of each ABI's `libapp.so`
    (`app.android-arm64.symbols`), as `flutter build aar --split-debug-info`
    writes them.

    Args:
        name: Target name: the `flutter_android_maven_repo`.
        application: The module's `flutter_application`.
        package_name: The module's Android package, `module.androidPackage`
            of a `flutter create --template module` pubspec: the Maven group
            of `flutter_<mode>`.
        build_number: The version of every artifact, as `flutter build aar
            --build-number`.
        abis: The ABIs whose native libraries the module's AAR holds, as
            `flutter build aar --target-platform`. Defaults to upstream's:
            armeabi-v7a, arm64-v8a and x86_64.
        min_sdk_version: The `minSdkVersion` of the module's manifest.
        **kwargs: Common attributes of the repository target (`visibility`,
            `testonly`, and `tags`, which every target the macro declares has
            and defaults to `["manual"]`).
    """
    testonly = kwargs.get("testonly", False)
    tags = kwargs.pop("tags", ["manual"])

    flutter_android_bundle(
        name = "__%s_bundle" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )

    # The registrant, compiled against the plugins' libraries and an engine it
    # does not package: the host's engine comes from the module's POM.
    maven = Label("@flutter_pub_android_maven//:requirements")
    _flutter_android_plugin_libs(
        name = "__%s_plugin_libs" % name,
        deps = [application],
        maven = maven,
        report = "//%s:%s_maven_artifacts" % (native.package_name(), name),
        tags = tags,
        testonly = testonly,
    )
    flutter_android_maven_artifacts(
        name = "%s_maven_artifacts" % name,
        application = application,
        maven = maven,
        tags = tags,
        testonly = testonly,
    )
    _flutter_android_engine(
        name = "__%s_engine" % name,
        neverlink = True,
        listenablefuture = False,
        tags = tags,
        testonly = testonly,
    )
    _flutter_android_registrant(
        name = "__%s_registrant_src" % name,
        application = application,
        tags = tags,
        testonly = testonly,
    )
    _registrant_library(
        name = "__%s_registrant" % name,
        tags = tags,
        testonly = testonly,
        deps = ["__%s_engine" % name, "__%s_plugin_libs" % name],
    )

    _flutter_android_module_aar(
        name = "__%s_module" % name,
        abis = abis,
        bundle = "__%s_bundle" % name,
        library = "__%s_registrant" % name,
        min_sdk_version = min_sdk_version,
        package_name = package_name,
        tags = tags,
        testonly = testonly,
    )
    _flutter_android_plugin_aars(
        name = "__%s_plugins" % name,
        abis = abis,
        application = application,
        maven = maven,
        tags = tags,
        testonly = testonly,
    )
    _flutter_android_maven_repo(
        name = name,
        tags = tags,
        build_number = build_number,
        module = "__%s_module" % name,
        plugins = "__%s_plugins" % name,
        **kwargs
    )
