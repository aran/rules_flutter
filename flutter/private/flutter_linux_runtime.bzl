"""The Linux runtime integration tests run in: an X server, GTK, Mesa and what headless Chrome links, from pinned Debian packages.

`flutter_linux_runtime` is declared by the repository `flutter_linux_runtime_repo`
makes, one per architecture. It patches the X server so that it finds its
keymap compiler in the runtime rather than in `/usr/bin`, and checks, as a
validation of every build that uses it, that no file of the runtime asks more of
the host's C and C++ runtime than the oldest supported host has, and that every
library a file needs is in the runtime or that C and C++ runtime.
"""

load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("//flutter:providers.bzl", "FlutterLinuxRuntimeInfo")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")

visibility("//flutter/...")

# What the host's C and C++ runtime is, by the names a file needs it by:
# glibc's libraries, its dynamic loader for each architecture, and GCC's C++
# runtime. The runtime brings everything else.
HOST_LIBRARIES = [
    "ld-linux-aarch64.so.1",
    "ld-linux-x86-64.so.2",
    "libanl.so.1",
    "libc.so.6",
    "libdl.so.2",
    "libgcc_s.so.1",
    "libm.so.6",
    "libmvec.so.1",
    "libpthread.so.0",
    "libresolv.so.2",
    "librt.so.1",
    "libstdc++.so.6",
    "libutil.so.1",
]

def linux_runtime_check(ctx, tools, tool, name, checked, providers, floor):
    """Declares the check that `checked` asks no more of the host than `floor`.

    Args:
        ctx: The rule context, which declares `PORTABLE`.
        tools: The `FlutterExecToolsInfo` of the host the check runs on.
        tool: `linux_runtime.dart`.
        name: What the stamp is named for, unique in the package.
        checked: depset of the files checked (those that are not ELF are passed over).
        providers: depset of files that are not checked but whose libraries
            the checked ones may need.
        floor: dict of the newest symbol version of each host library a file
            may ask for (`GLIBC` to `2.39`, ...).

    Returns:
        The stamp the check writes.
    """
    stamp = ctx.actions.declare_file(name + ".linux_runtime_checked")
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("check")
    args.add("--stamp", stamp)
    for key, value in sorted(floor.items()):
        args.add("--floor", "%s=%s" % (key, value))
    args.add_all(HOST_LIBRARIES, before_each = "--host-library")
    args.add_all(providers, before_each = "--provider")
    args.add_all(checked)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [tool.path, args],
        inputs = depset([tool], transitive = [checked, providers, tools.sdk_files.run]),
        outputs = [stamp],
        mnemonic = "FlutterLinuxRuntimeCheck",
        exec_group = PORTABLE,
        progress_message = "Checking what %{label} asks of the host",
    )
    return stamp

def _flutter_linux_runtime_impl(ctx):
    tools = portable_tools(ctx)
    tool = ctx.file._tool

    xvfb = ctx.actions.declare_file(ctx.label.name + "/Xvfb")
    ctx.actions.run(
        executable = tools.dart,
        arguments = [tool.path, "patch-xvfb", ctx.file.xvfb.path, xvfb.path],
        inputs = depset([tool, ctx.file.xvfb], transitive = [tools.sdk_files.run]),
        outputs = [xvfb],
        mnemonic = "FlutterPatchXvfb",
        exec_group = PORTABLE,
        progress_message = "Pointing %{label}'s X server at its own xkbcomp",
    )

    files = depset(ctx.files.srcs + [ctx.file.fonts_conf])
    stamp = linux_runtime_check(
        ctx,
        tools,
        tool,
        ctx.label.name,
        checked = depset(ctx.files.srcs),
        providers = depset(),
        floor = ctx.attr.floor,
    )

    # The runtime's root, from a file whose place in it is known.
    xkbcomp = ctx.file.xkbcomp
    root = runfiles_path(xkbcomp, ctx.workspace_name)[:-len("/usr/bin/xkbcomp")]
    return [
        DefaultInfo(files = depset([xvfb], transitive = [files])),
        FlutterLinuxRuntimeInfo(
            files = depset([xvfb], transitive = [files]),
            libraries = files,
            config = struct(
                root = root,
                triple = ctx.attr.triple,
                xvfb = runfiles_path(xvfb, ctx.workspace_name),
                fontsConf = runfiles_path(ctx.file.fonts_conf, ctx.workspace_name),
            ),
            floor = ctx.attr.floor,
        ),
        OutputGroupInfo(_validation = depset([stamp])),
    ]

flutter_linux_runtime = rule(
    implementation = _flutter_linux_runtime_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "The runtime's files, under `<root>/usr`.",
            allow_files = True,
        ),
        "xvfb": attr.label(
            doc = "The X server, `<root>/usr/bin/Xvfb`, as the package has it.",
            allow_single_file = True,
            mandatory = True,
        ),
        "xkbcomp": attr.label(
            doc = "The keymap compiler the X server runs, `<root>/usr/bin/xkbcomp`, whose place says where the root is.",
            allow_single_file = True,
            mandatory = True,
        ),
        "fonts_conf": attr.label(
            doc = "The fontconfig configuration that names the runtime's fonts and no others.",
            allow_single_file = True,
            mandatory = True,
        ),
        "triple": attr.string(
            doc = "The multiarch directory of the libraries: `x86_64-linux-gnu` or `aarch64-linux-gnu`.",
            mandatory = True,
        ),
        "floor": attr.string_dict(
            doc = "The newest symbol version of each host library a file may ask for, by its version name (`GLIBC`: `2.39`).",
            mandatory = True,
        ),
        "_tool": attr.label(
            default = "//flutter/private/tools:linux_runtime.dart",
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "The X server, GTK, Mesa and libraries a Linux integration test runs with, from pinned Debian packages.",
)
