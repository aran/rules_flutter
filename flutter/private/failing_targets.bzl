"""Targets that fail at analysis, for a repository that cannot hold what a build would ask of it.

A repository whose content depends on the machine (an environment variable, a
local path, the host's tools) or on what a build chooses (an SDK, a platform)
still fetches where that content cannot be made: `bazel fetch --all`, an
untargeted `bazel vendor` and `bazel query` fetch every repository, whether or
not a build uses it. The repository writes these targets instead, and a build
that uses one fails at analysis with the reason; one that does not is
unaffected. A fetch fails only for what no build could avoid: bytes that do not
match their checksum, a declaration the user must fix, a network failure.
"""

visibility("//flutter/...")

FAILING_TARGETS_LOAD = 'load("@rules_flutter//flutter:engine.bzl", "flutter_missing_slice")\n'

def failing_targets(names, message):
    """BUILD text declaring targets that fail at analysis with `message`.

    The file must load `flutter_missing_slice` (`FAILING_TARGETS_LOAD`).

    Args:
        names: The names of the targets a build could ask for.
        message: Why they cannot be built, and what to do about it.

    Returns:
        The declarations.
    """
    return "".join([
        "\nflutter_missing_slice(\n    name = {name},\n    message = {message},\n    visibility = [\"//visibility:public\"],\n)\n".format(
            # A Starlark literal, whatever the text: a message may quote
            # what a package or a machine holds.
            name = repr(name),
            message = repr(message),
        )
        for name in names
    ])

def write_failing_build(ctx, names, message, path = "BUILD.bazel", prelude = ""):
    """Writes a BUILD file whose targets fail at analysis with `message`.

    Args:
        ctx: The `repository_ctx`.
        names: The names of the targets a build could ask for.
        message: Why they cannot be built, and what to do about it.
        path: The BUILD file, relative to the repository root.
        prelude: Text the file begins with.
    """
    ctx.file(path, prelude + FAILING_TARGETS_LOAD + failing_targets(names, message))
