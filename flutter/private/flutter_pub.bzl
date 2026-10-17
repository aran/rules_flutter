"""`@rules_flutter//flutter:pub` — `dart pub`, run from the pinned toolchain.

`flutter.pub()` reads a checked-in `pubspec.lock` and turns every entry into a
repository. Nothing in the build writes that file, and the fetched toolchain
carries engine artifacts plus a Dart SDK — no `bin/flutter`, no `pub`
executable — so regenerating the lock has meant installing Flutter separately
and hoping its version matches the one Bazel pins. It usually does not, and the
mismatch is silent: pub's solver treats the running Dart SDK's version and the
Flutter SDK's version as constraints, so an older installation quietly pins
older packages and the resulting lock still looks perfectly valid.

This target closes that gap. It runs the *toolchain's* `dart pub` with
`FLUTTER_ROOT` pointing at `@flutter_dev_root`, a tree assembled from the same
Flutter tag the toolchain pins:

    bazel run @rules_flutter//flutter:pub -- get
    bazel run @rules_flutter//flutter:pub -- upgrade
    bazel run @rules_flutter//flutter:pub -- add qr

Arguments pass through to `dart pub` unchanged and the command runs in
`BUILD_WORKSPACE_DIRECTORY`, so `pubspec.lock` lands in the source tree where
`flutter.pub()` reads it. This is `dart pub`, not `flutter pub`: it writes
`pubspec.lock` and `.dart_tool/package_config.json` and does not produce
`.flutter-plugins-dependencies` — rules_flutter generates plugin registrants
from the build graph instead, so that file has no consumer here.
"""

load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("//flutter:providers.bzl", "resolve_exec_dart")

def _flutter_pub_impl(ctx):
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    exec_dart = resolve_exec_dart(ctx, flutter_sdk_info)

    tool = ctx.attr._tool
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    executable = ctx.actions.declare_file(ctx.label.name + (".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_PUB_DART": runfiles_path(exec_dart, workspace_name),
        "FLUTTER_PUB_VERSION_MANIFEST": runfiles_path(ctx.file.version_manifest, workspace_name),
    }

    runfiles = ctx.runfiles(
        files = [exec_dart, ctx.file.version_manifest],
        transitive_files = depset(
            ctx.files.dev_root,
            transitive = [flutter_sdk_info.dart_pub_files],
        ),
    )
    runfiles = runfiles.merge(tool[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = env),
    ]

flutter_pub = rule(
    implementation = _flutter_pub_impl,
    executable = True,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    attrs = {
        "dev_root": attr.label(
            doc = "The FLUTTER_ROOT-shaped tree pub resolves `sdk: flutter` " +
                  "dependencies against.",
            default = Label("@flutter_dev_root//:dev_root"),
        ),
        "version_manifest": attr.label(
            doc = "`bin/cache/flutter.version.json` within `dev_root`. Named " +
                  "separately because it is both an input pub requires and the " +
                  "anchor the runner derives FLUTTER_ROOT from.",
            default = Label("@flutter_dev_root//:version_manifest"),
            allow_single_file = True,
        ),
        "_tool": attr.label(
            default = Label("//flutter/private/tools:pub_runner"),
            executable = True,
            cfg = "exec",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    doc = "Runs `dart pub` from the pinned Flutter toolchain against the " +
          "current workspace. See `@rules_flutter//flutter:pub`.",
)
