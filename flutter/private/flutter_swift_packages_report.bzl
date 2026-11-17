"""`bazel run @<hub>//swift:packages`: what the root declares for a hub's Swift packages.

Each pub hub has this target. It prints the lines the root module's
`Package.swift` and `MODULE.bazel` need for the remote Swift packages the
hub's Apple plugins depend on, and marks those the root's `Package.resolved`
is missing or pins at a version a plugin does not accept
(`flutter/private/tools/swift_packages.dart`). See `swift_packages.bzl`.
"""

load("@rules_dart//dart:utils.bzl", "dart_compile_action", "runfiles_path")
load("//flutter/private:host_platform_transition.bzl", "host_platform_transition")

def _flutter_swift_packages_report_impl(ctx):
    dart_sdk_info = ctx.toolchains["@rules_dart//dart:toolchain_type"].dart_sdk_info
    workspace_name = ctx.workspace_name
    config = ctx.actions.declare_file(ctx.label.name + ".config.json")
    ctx.actions.write(config, json.encode({
        "hub": ctx.attr.hub,
        "requirements": [runfiles_path(f, workspace_name) for f in ctx.files.requirements],
        "resolved": ctx.attr.resolved,
    }))
    executable = ctx.actions.declare_file(ctx.label.name)
    dart_compile_action(
        ctx = ctx,
        sdk = dart_sdk_info,
        kernel = ctx.file._main,
        sources = depset(ctx.files._srcs + [ctx.file._main]),
        output = executable,
        extra_flags = [
            "-Drules_flutter.swift_packages.config=" + runfiles_path(config, workspace_name),
        ],
    )
    return [DefaultInfo(
        executable = executable,
        runfiles = ctx.runfiles(files = [config] + ctx.files.requirements),
    )]

flutter_swift_packages_report = rule(
    implementation = _flutter_swift_packages_report_impl,
    executable = True,
    cfg = host_platform_transition,
    toolchains = ["@rules_dart//dart:toolchain_type"],
    attrs = {
        "hub": attr.string(doc = "The hub's name, for messages.", mandatory = True),
        "requirements": attr.label_list(
            doc = "The `swift_requirements.json` of the hub's packages' Apple repositories.",
            allow_files = [".json"],
        ),
        "resolved": attr.string(
            doc = "The root's `Package.resolved`, relative to the workspace (or a label " +
                  "of another repository's); empty when no tag names one.",
        ),
        "_main": attr.label(
            default = "//flutter/private/tools:swift_packages.dart",
            allow_single_file = [".dart"],
        ),
        "_srcs": attr.label_list(
            default = ["//flutter/private/tools:pub_runfiles.dart"],
            allow_files = [".dart"],
        ),
    },
    doc = "Prints what the root module declares for a pub hub's Swift packages. See the module docstring.",
)
