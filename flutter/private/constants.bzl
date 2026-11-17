"""Shared constants for rules_flutter."""

# Minimum OS deployment targets: both the default and the floor.
#
# These are not a style choice. The prebuilt engine these rules vend is itself
# built for a minimum, and a bundle cannot honour one below it: the link warns
# ("building for iOS-simulator-14.0, but linking with dylib ... built for newer
# version 15.0"), and the engine is what the app loads at launch. So a lower
# value here would not widen the audience, it would only move the failure.
#
# Read the floor off the framework rather than off a changelog — it moves with
# the pinned engine, and the binary is the thing that has to load:
#
#   otool -l Flutter.framework/Flutter | grep -A 4 LC_BUILD_VERSION
#
# Measured on the pinned engine: iOS 15.0, macOS 12.0.
IOS_MINIMUM_OS_VERSION = "15.0"
MACOS_MINIMUM_OS_VERSION = "12.0"

# Default Android SDK version targets.
#
# The minimum is the Flutter Gradle plugin's `flutter.minSdkVersion`, and the
# floor of both the engine (`libflutter.so`'s `.note.android.ident` names API
# 24) and rules_android, which raises any lower `minSdkVersion` to 24. The
# target is its `flutter.targetSdkVersion`.
ANDROID_MIN_SDK_VERSION = "24"
ANDROID_TARGET_SDK_VERSION = "36"

# Android ABI directory name for each engine architecture this ruleset builds.
ANDROID_ABI_FOR_ARCH = {
    "arm": "armeabi-v7a",
    "arm64": "arm64-v8a",
    "x64": "x86_64",
}

# Where a pub package's repository links the `lib/` files of other packages that
# its assets and shaders name as `packages/<other>/<path>`: under
# `<this>/<other>/<path>`. A contribution from a path there is bundled at the
# key as listed, not under the contributing package's own `packages/<name>/`.
OTHER_PACKAGES_ASSETS = "_assets_of_other_packages"

# The platforms of a pubspec's `flutter: plugin: platforms:`, each a
# `flutter_plugin_platform`.
PLUGIN_PLATFORMS = ["android", "ios", "linux", "macos", "web", "windows"]
