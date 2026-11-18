"""Builds targets for given Android platforms, whatever the command line asked for."""

load("@rules_android//rules:utils.bzl", android_utils = "utils")

visibility("//flutter/...")

# rules_android reads the platforms of an APK from this Starlark flag when it
# has a value, and from Bazel's native `--android_platforms` only when it is
# empty. Setting the Starlark flag alone is enough, and cannot disagree with a
# value of the native option the command line may carry: the Starlark one wins.
_STARLARK_PLATFORMS = Label("@rules_android//flags:android_platforms")

def _platforms_of(value):
    """The platforms rules_android builds for when its flag holds `value`.

    The flag holds strings, which rules_android resolves as labels in its own
    repository's context. Its own reader resolves them here, so a value means
    the same to this transition as to the APK rules.
    """
    return android_utils.get_android_platforms({android_utils.ANDROID_PLATFORMS_SETTING: value})

def _android_platforms_transition_impl(settings, attr):
    # The flag is a string list, so two spellings of one platform
    # (`@rules_android//:arm64-v8a` on a command line, `@@rules_android+//:arm64-v8a`
    # from `str(Label)`) are two configurations, and every target outside this
    # rule would be built in both. When the incoming value names these
    # platforms, it is kept as it is spelled.
    incoming = settings[str(_STARLARK_PLATFORMS)]
    if incoming and _platforms_of(incoming) == attr.android_platforms:
        return {str(_STARLARK_PLATFORMS): incoming}
    return {
        str(_STARLARK_PLATFORMS): [str(platform) for platform in attr.android_platforms],
    }

_android_platforms_transition = transition(
    implementation = _android_platforms_transition_impl,
    inputs = [str(_STARLARK_PLATFORMS)],
    outputs = [str(_STARLARK_PLATFORMS)],
)

def _flutter_android_build_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.attr.targets
    ]))]

flutter_android_build = rule(
    implementation = _flutter_android_build_impl,
    doc = """Builds `targets` for the Android `android_platforms` and forwards their files.

Building it is the same as building `targets` with
`--@rules_android//flags:android_platforms=<android_platforms>`, whatever flags the command line
has. Use it to check an APK for a given ABI, or for several, from a test in an
invocation like a plain `bazel test //...` that does not pass the flag.

The APK of `targets` holds the ABIs the platforms name: one platform builds an
APK for that ABI, several build one APK for all of them.""",
    attrs = {
        "android_platforms": attr.label_list(
            mandatory = True,
            allow_empty = False,
            providers = [platform_common.PlatformInfo],
            doc = """The platforms to build `targets` for, such as
`@rules_android//:armeabi-v7a`, `:arm64-v8a` and `:x86_64`. Each is
named for its ABI, which is the directory rules_android packages its native
libraries into.""",
        ),
        "targets": attr.label_list(
            cfg = _android_platforms_transition,
            mandatory = True,
            doc = "The targets to build, such as a `flutter_android_app`.",
        ),
    },
)
