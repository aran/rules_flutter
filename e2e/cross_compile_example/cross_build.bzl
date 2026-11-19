"""Builds targets for Linux x86_64 in debug mode, whatever host and mode the command line has."""

_PLATFORMS = "//command_line_option:platforms"
_COMPILATION_MODE = "//command_line_option:compilation_mode"

# Debug only: gen_snapshot cannot compile AOT code for one desktop OS on
# another, so a release or profile bundle cannot be cross-compiled.
def _transition_impl(_settings, _attr):
    return {
        _PLATFORMS: [str(Label("@rules_flutter//flutter/platforms:linux_x64"))],
        _COMPILATION_MODE: "dbg",
    }

_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = [_PLATFORMS, _COMPILATION_MODE],
)

def _impl(ctx):
    return [DefaultInfo(files = depset(transitive = [t[DefaultInfo].files for t in ctx.attr.targets]))]

linux_x64_debug_build = rule(
    implementation = _impl,
    doc = """Builds `targets` for `@rules_flutter//flutter/platforms:linux_x64` with `-c dbg`, and forwards their files.

A `build_test` of it checks the cross build in a plain `bazel test`, with no
`--platforms` for the workspace: the build_test runs on the host, and only
what it depends on is built for Linux.""",
    attrs = {
        "targets": attr.label_list(
            cfg = _transition,
            mandatory = True,
            doc = "The targets to build for Linux.",
        ),
    },
)
