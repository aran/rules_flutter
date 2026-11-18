"""The defines `flutter_tools` adds to every program it compiles.

`flutter build`, `flutter run` and `flutter test` describe the SDK and the app
to the program through its Dart environment: `FlutterVersion` and
`appBuildName` (`package:flutter/services.dart`) read them as
`String.fromEnvironment`. Left out, they read null.

The SDK's are the same for every program built with one SDK, and
`flutter_tools` takes them from the installed SDK (`FlutterVersion`); here they
come from the release the toolchain pins (`versions.bzl`). The app's are its
`build_name` and `build_number`, which `flutter_tools` takes from
`--build-name` and `--build-number` or the `version:` of `pubspec.yaml`.
"""

load("//flutter/private:app_version.bzl", "DEFAULT_BUILD_NAME", "DEFAULT_BUILD_NUMBER")
load("//flutter/private:versions.bzl", "FLUTTER_VERSIONS")

visibility("//flutter/...")

APP_BUILD_NAME_DEFINE = "FLUTTER_BUILD_NAME"
APP_BUILD_NUMBER_DEFINE = "FLUTTER_BUILD_NUMBER"

# The SDK's, in the order `flutter_tools` adds them.
SDK_DEFINE_KEYS = (
    "FLUTTER_VERSION",
    "FLUTTER_CHANNEL",
    "FLUTTER_GIT_URL",
    "FLUTTER_FRAMEWORK_REVISION",
    "FLUTTER_ENGINE_REVISION",
    "FLUTTER_DART_VERSION",
)

# Every key the ruleset sets itself from the SDK and the app's version.
VERSION_DEFINE_KEYS = (APP_BUILD_NAME_DEFINE, APP_BUILD_NUMBER_DEFINE) + SDK_DEFINE_KEYS

# What `flutter --version` reports for a release tag, and the repository it is
# cloned from.
_CHANNEL = "stable"
_GIT_URL = "https://github.com/flutter/flutter.git"

# `FlutterVersion.frameworkRevisionShort` and `engineRevisionShort`.
_SHORT_REVISION = 10

def sdk_dart_defines(flutter_version):
    """The defines that describe the Flutter SDK `flutter_version`, as `flutter_tools` adds them.

    Args:
        flutter_version: A key of `FLUTTER_VERSIONS`, such as `3.50.0`.

    Returns:
        The `KEY=VALUE` defines, in `SDK_DEFINE_KEYS` order.
    """
    meta = FLUTTER_VERSIONS.get(flutter_version)
    if meta == None:
        fail("Flutter %s is not a version versions.bzl lists: %s" % (flutter_version, ", ".join(FLUTTER_VERSIONS.keys())))
    return [
        "FLUTTER_VERSION=" + flutter_version,
        "FLUTTER_CHANNEL=" + _CHANNEL,
        "FLUTTER_GIT_URL=" + _GIT_URL,
        "FLUTTER_FRAMEWORK_REVISION=" + meta.framework_revision[:_SHORT_REVISION],
        "FLUTTER_ENGINE_REVISION=" + meta.engine_revision[:_SHORT_REVISION],
        "FLUTTER_DART_VERSION=" + meta.dart_version,
    ]

def custom_sdk_dart_defines(version, framework_revision, engine_revision, dart_version):
    """The defines that describe an SDK whose pieces are not all the release's.

    Args:
        version: The framework's `flutterVersion`.
        framework_revision: Its commit, or empty.
        engine_revision: The engine's commit, or empty.
        dart_version: The Dart the engine bundles, or empty.

    Returns:
        The `KEY=VALUE` defines, in `SDK_DEFINE_KEYS` order.
    """
    return [
        "FLUTTER_VERSION=" + version,
        "FLUTTER_CHANNEL=" + _CHANNEL,
        "FLUTTER_GIT_URL=" + _GIT_URL,
        "FLUTTER_FRAMEWORK_REVISION=" + framework_revision[:_SHORT_REVISION],
        "FLUTTER_ENGINE_REVISION=" + engine_revision[:_SHORT_REVISION],
        "FLUTTER_DART_VERSION=" + dart_version,
    ]

def sdk_engine_revision(engine, version):
    """The commit of an SDK's engine, wherever the SDK reports it.

    Args:
        engine: The engine's decoded `flutter_engine.json`, or `{}` for the
            release's engine.
        version: The release the SDK takes what its sources do not give
            from, or empty.

    Returns:
        What the engine's record says; nothing for an engine whose path is
        not set; else the release's.
    """
    if engine.get("unset"):
        return ""
    if "engine_revision" in engine:
        return engine["engine_revision"]
    meta = FLUTTER_VERSIONS.get(version) if version else None
    return meta.engine_revision if meta else ""

def app_version_dart_defines(build_name, build_number):
    """The defines `appBuildName` and `appBuildNumber` read.

    Args:
        build_name: The program's `build_name`; empty for `flutter create`'s `1.0.0`.
        build_number: The program's `build_number`; empty for `flutter create`'s `1`.

    Returns:
        The two `KEY=VALUE` defines, as given: unlike the bundle's own fields,
        `flutter_tools` does not pad or rewrite them.
    """
    return [
        "%s=%s" % (APP_BUILD_NAME_DEFINE, build_name or DEFAULT_BUILD_NAME),
        "%s=%s" % (APP_BUILD_NUMBER_DEFINE, build_number or DEFAULT_BUILD_NUMBER),
    ]

def program_version_dart_defines(sdk_defines, build_name, build_number):
    """All the version defines of a program: the app's, then the SDK's as the toolchain gives them.

    Args:
        sdk_defines: `FlutterSdkInfo.sdk_defines`.
        build_name: The program's `build_name`.
        build_number: The program's `build_number`.

    Returns:
        The `KEY=VALUE` defines.
    """
    return app_version_dart_defines(build_name, build_number) + list(sdk_defines)

def version_dart_defines(flutter_version, build_name, build_number):
    """All the version defines of a program, in the order `flutter_tools` adds them.

    Args:
        flutter_version: The toolchain's Flutter release.
        build_name: The program's `build_name`.
        build_number: The program's `build_number`.

    Returns:
        The `KEY=VALUE` defines.
    """
    return app_version_dart_defines(build_name, build_number) + sdk_dart_defines(flutter_version)
