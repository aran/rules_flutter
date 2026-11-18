"""Assembling a directory artifact from trees and files, on any host.

A tree artifact cannot be built up by Starlark alone: copying a directory's
contents, or adding files beside them, takes an action that runs something.
That something is `tools/assemble_directory.dart`, run by the exec-tools
toolchain's `dart`, so the action runs wherever that toolchain does and needs
no POSIX shell (`cp -R`) or Windows one.

A rule that calls `assemble_directory` merges `ASSEMBLE_DIRECTORY_ATTRS` into
its `attrs` and runs the action in the `PORTABLE` exec group.
"""

load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:exec_groups.bzl", "PORTABLE")

visibility("//flutter/...")

ASSEMBLE_DIRECTORY_ATTRS = {
    "_assemble_tool": attr.label(
        default = "//flutter/private/tools:assemble_directory.dart",
        allow_single_file = True,
    ),
}

def assemble_directory(ctx, tools, output, steps, mnemonic, progress_message):
    """Declares the action that fills the tree artifact `output`.

    Args:
        ctx: Rule context, of a rule with `ASSEMBLE_DIRECTORY_ATTRS` and the
            `PORTABLE` exec group.
        tools: The `FlutterExecToolsInfo` of the host the action runs on.
        output: The directory to fill, from `ctx.actions.declare_directory`.
        steps: The directory's contents, in the order they are placed, each a
            `(kind, name, source)` tuple. A `"tree"` copies the contents of
            the directory artifact `source` into `name` under `output` (`"."`
            for `output` itself); a `"file"` copies the file `source` to
            `name`. A later step replaces a file an earlier one placed.
        mnemonic: The action's mnemonic.
        progress_message: The action's progress message.
    """
    tool = ctx.file._assemble_tool
    args = ctx.actions.args()
    args.add(tool)

    # A tree artifact is named as a directory, not expanded to its files.
    args.add_all("--output", [output], expand_directories = False)
    sources = []
    for kind, name, source in steps:
        if kind == "tree":
            args.add("--add-tree", name)
        elif kind == "file":
            args.add("--add", name)
        else:
            fail("assemble_directory: step kind must be \"tree\" or \"file\", not %r" % kind)
        args.add_all([source], expand_directories = False)
        sources.append(source)

    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [tool] + sources,
            transitive = [tools.sdk_files.run],
        ),
        outputs = [output],
        mnemonic = mnemonic,
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = progress_message,
    )
