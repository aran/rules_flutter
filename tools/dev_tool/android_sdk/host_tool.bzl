"""`host_tool`: a tool built for the machine Bazel runs on, whatever the build's own platforms.

`flutter_bazel` runs `adb` and `aapt2` itself, on this machine. It builds them
in the same `bazel build` options as the app it runs, because a command whose
options differ from the one before throws the analysis cache away, and the
next build of the app then analyses its whole graph again. Those options can
name any `--platforms`, so the tool's edge moves to the host platform here
rather than through the command line.

The host, not an execution platform: an execution platform can be a remote
worker's, and these run where the dev tool does. It is `@platforms//host`
itself, as everywhere else in these rules: `--host_platform` names an alias of
it, and a configuration that spells the same platform differently builds every
shared dependency twice.
"""

# The transition itself, rather than the copy `//flutter:native_hot_patch.bzl`
# exports for users: this tool has nothing to do with hot patching.
load("//flutter/private:host_platform_transition.bzl", "host_platform_transition")

def _host_tool_impl(ctx):
    tool = ctx.attr.tool[0]
    executable = tool[DefaultInfo].files_to_run.executable
    if executable == None:
        fail("%s is not executable" % tool.label)

    # Under its own name and the tool's basename, so that a runner script that
    # looks for `$0.runfiles` finds the runfiles below, and `.exe` survives.
    link = ctx.actions.declare_file(ctx.label.name + "/" + executable.basename)
    ctx.actions.symlink(output = link, target_file = executable, is_executable = True)
    runfiles = ctx.runfiles(files = [executable]).merge(tool[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = link, files = depset([link]), runfiles = runfiles)]

host_tool = rule(
    implementation = _host_tool_impl,
    doc = "The executable `tool`, built for the host platform.",
    attrs = {
        "tool": attr.label(
            mandatory = True,
            executable = True,
            # An SDK's `adb` is often a file of its repository, not a rule.
            allow_files = True,
            cfg = host_platform_transition,
            doc = "The executable to build for the host.",
        ),
    },
    executable = True,
)
