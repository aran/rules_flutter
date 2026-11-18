"""`@rules_flutter//flutter/pub` — `dart pub`, run from the pinned toolchain.

the `pub` extension's `from_lock` reads a checked-in `pubspec.lock` and turns every
entry into a repository. Nothing in the build writes that file, and the fetched
toolchain carries engine artifacts plus a Dart SDK — no `bin/flutter`, no `pub`
executable — so regenerating the lock has meant installing Flutter separately
and hoping its version matches the one Bazel pins. It usually does not, and the
mismatch is silent: pub's solver treats the running Dart SDK's version and the
Flutter SDK's version as constraints, so an older installation quietly pins
older packages and the resulting lock still looks perfectly valid.

This target closes that gap. It runs the *toolchain's* `dart pub` with
`FLUTTER_ROOT` pointing at `@flutter_dev_root`, a tree assembled from the same
Flutter tag the toolchain pins:

    bazel run @rules_flutter//flutter/pub -- get
    bazel run @rules_flutter//flutter/pub -- upgrade
    bazel run @rules_flutter//flutter/pub -- add qr

Arguments pass through to `dart pub` unchanged and the command runs in
`BUILD_WORKSPACE_DIRECTORY`, so `pubspec.lock` lands in the source tree where
the `pub` extension's `from_lock` reads it. This is `dart pub`, not `flutter pub`: it
writes `pubspec.lock` and `.dart_tool/package_config.json` and does not produce
`.flutter-plugins-dependencies` — rules_flutter generates plugin registrants
from the build graph instead, so that file has no consumer here.
"""

load("@rules_dart//dart:utils.bzl", "dart_compile_action", "runfiles_path")
load("//flutter/private:host_platform_transition.bzl", "host_platform_transition")

visibility("//flutter/...")

def _flutter_pub_impl(ctx):
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    dart_sdk_info = ctx.toolchains["@rules_dart//dart:toolchain_type"].dart_sdk_info
    workspace_name = ctx.workspace_name

    # One `dart compile exe` action on the SDK, from a script that imports only
    # the Dart libraries: no Dart tool of rules_dart's or ours, which would be
    # built from pub packages, and so no pub repository takes part. A lock
    # conflict there would stop the command that fixes the lock.
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._os_windows[platform_common.ConstraintValueInfo],
    )
    executable = ctx.actions.declare_file(ctx.label.name + (".exe" if is_windows else ""))
    dart_compile_action(
        ctx = ctx,
        sdk = dart_sdk_info,
        kernel = ctx.file.main,
        sources = depset(ctx.files.srcs + [ctx.file.main]),
        output = executable,
        extra_flags = [
            "-Drules_flutter.pub.dart=" + runfiles_path(flutter_sdk_info.dart, workspace_name),
            "-Drules_flutter.pub.version_manifest=" + runfiles_path(ctx.file.version_manifest, workspace_name),
        ],
    )

    runfiles = ctx.runfiles(
        files = [ctx.file.version_manifest],
        transitive_files = depset(
            ctx.files.dev_root,
            transitive = [flutter_sdk_info.tool_files],
        ),
    )

    # The SDK writes no telemetry identity into the home of whoever ran this.
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = {"DASH__SUPPRESS_ANALYTICS": "true"}),
    ]

flutter_pub = rule(
    implementation = _flutter_pub_impl,
    executable = True,
    # `bazel run` starts the runner and its `dart` on the machine running
    # Bazel, so the whole target is built for that machine, whatever
    # `--platforms` names; the Flutter toolchain for that platform runs there.
    cfg = host_platform_transition,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        "@rules_dart//dart:toolchain_type",
    ],
    attrs = {
        "main": attr.label(
            doc = "The runner's entry point, importing only `dart:` libraries and `srcs`.",
            allow_single_file = [".dart"],
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = "The Dart files `main` imports by relative path.",
            allow_files = [".dart"],
        ),
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
        "_os_windows": attr.label(default = "@platforms//os:windows"),
    },
    doc = "Runs `dart pub` from the pinned Flutter toolchain against the " +
          "current workspace. See `@rules_flutter//flutter/pub`.",
)
