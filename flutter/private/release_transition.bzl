"""The transition to an Android release build, for `flutter_android_release`."""

visibility("//flutter/...")

_PROFILE = str(Label("//flutter:profile"))
_ANDROID_PLATFORMS = str(Label("@rules_android//flags:android_platforms"))

# Release mode, not profile, as `flutter build appbundle` builds release
# unless told otherwise.
RELEASE_SETTINGS = {
    "//command_line_option:compilation_mode": "opt",
    _PROFILE: False,
}

def _android_release_transition_impl(_settings, attr):
    return RELEASE_SETTINGS | {
        _ANDROID_PLATFORMS: [str(platform) for platform in attr.android_platforms],
    }

# A release build for the ABIs of the rule's `android_platforms`, whatever the
# command line asked for.
android_release_transition = transition(
    implementation = _android_release_transition_impl,
    inputs = [],
    outputs = list(RELEASE_SETTINGS.keys()) + [_ANDROID_PLATFORMS],
)
