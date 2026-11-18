"""Builds targets with `-c dbg`, whatever the command line asked for."""

load("//flutter/private:dbg_transition.bzl", "dbg_transition")

visibility("//flutter/...")

def _debug_build_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.attr.targets
    ]))]

debug_build = rule(
    implementation = _debug_build_impl,
    doc = "Forwards the files of `targets`, built with `-c dbg` and without `--@rules_flutter//flutter:profile`.",
    attrs = {
        "targets": attr.label_list(
            cfg = dbg_transition,
            mandatory = True,
            doc = "The targets to build in debug mode.",
        ),
    },
)
