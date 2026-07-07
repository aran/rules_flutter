"""Shared constants for rules_flutter."""

# Default minimum OS deployment targets. Matches Flutter's own template
# (IPHONEOS_DEPLOYMENT_TARGET) and the prebuilt engine: Flutter.framework is
# built for iOS 13.0, so a lower value only produces linker warnings.
IOS_MINIMUM_OS_VERSION = "13.0"
MACOS_MINIMUM_OS_VERSION = "10.14"

# Default Android SDK version targets.
ANDROID_MIN_SDK_VERSION = "21"
ANDROID_TARGET_SDK_VERSION = "35"
