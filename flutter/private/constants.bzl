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
ANDROID_MIN_SDK_VERSION = "21"
ANDROID_TARGET_SDK_VERSION = "35"
