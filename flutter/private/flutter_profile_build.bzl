"""Builds targets in Flutter profile mode, whatever the command line asked for."""

visibility("//flutter/...")

def _profile_transition_impl(_settings, _attr):
    return {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:profile")): True,
    }

_profile_transition = transition(
    implementation = _profile_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        str(Label("//flutter:profile")),
    ],
)

def _flutter_profile_build_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.attr.targets
    ]))]

flutter_profile_build = rule(
    implementation = _flutter_profile_build_impl,
    doc = """Builds `targets` in Flutter profile mode and forwards their files.

Building it is the same as building `targets` with
`-c opt --@rules_flutter//flutter:profile`, whatever flags the command line
has. Use it to check a profile build from a test, such as the mode of a
bundle's AOT snapshot, in an invocation like a plain `bazel test //...` that
does not pass the flags.

Profile mode needs the profile engine and `gen_snapshot` for the target
platform, so the target is built where those exist. There is no profile mode
for the iOS simulator.""",
    attrs = {
        "targets": attr.label_list(
            cfg = _profile_transition,
            mandatory = True,
            doc = "The targets to build in profile mode, such as a `flutter_macos_app`.",
        ),
    },
)
