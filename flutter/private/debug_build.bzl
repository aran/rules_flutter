"""Builds targets with `-c dbg`, whatever the command line asked for."""

_PROFILE_FLAG = str(Label("//flutter:profile"))

def _dbg_transition_impl(_settings, _attr):
    return {
        "//command_line_option:compilation_mode": "dbg",
        _PROFILE_FLAG: False,
    }

_dbg_transition = transition(
    implementation = _dbg_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        _PROFILE_FLAG,
    ],
)

def _debug_build_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.attr.targets
    ]))]

debug_build = rule(
    implementation = _debug_build_impl,
    doc = "Forwards the files of `targets`, built with `-c dbg`.",
    attrs = {
        "targets": attr.label_list(
            cfg = _dbg_transition,
            mandatory = True,
            doc = "The targets to build in debug mode.",
        ),
    },
)
