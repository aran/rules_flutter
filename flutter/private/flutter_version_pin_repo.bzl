"""The Flutter release the toolchain pins, as a constant rules can load.

A rule that compiles a program learns the release from its toolchain. A rule
whose dependencies are compiled as modules (`flutter_test`) must know it before
that, as configuration, from its attributes alone: the modules compile in the
same environment as the program, and `FlutterVersion` is part of it. This
repository is where such a rule reads it.
"""

visibility("//flutter/...")

def _impl(repository_ctx):
    repository_ctx.file("BUILD.bazel", "")
    repository_ctx.file(
        "version.bzl",
        "FLUTTER_VERSION = %s\n" % json.encode(repository_ctx.attr.flutter_version),
    )

flutter_version_pin_repo = repository_rule(
    _impl,
    doc = "A `version.bzl` holding the `FLUTTER_VERSION` the toolchain pins.",
    attrs = {
        "flutter_version": attr.string(mandatory = True),
    },
)
