"""A runnable target that exposes the Flutter-bundled Dart binary via toolchain resolution.

Usage:
    bazel run @rules_flutter//dart -- --version
    bazel run @rules_flutter//dart -- analyze lib/
"""

_BASH_RUNFILES_INIT = """\
# --- begin runfiles.bash initialization v3 ---
set -uo pipefail; set +e; f=bazel_tools/tools/bash/runfiles/runfiles.bash
# shellcheck disable=SC1090
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v3 ---"""

_BAT_TEMPLATE = """\
@echo off
setlocal
set RUNFILES_DIR=%~dp0%~n0.exe.runfiles
if not exist "%RUNFILES_DIR%" set RUNFILES_DIR=%~dp0%~n0.runfiles
set DART=%RUNFILES_DIR%\\{dart}
if defined BUILD_WORKING_DIRECTORY cd /d "%BUILD_WORKING_DIRECTORY%"
"%DART%" %*
"""

def _runfiles_path(f, workspace_name):
    """Convert a File to its path in the runfiles tree."""
    if f.short_path.startswith("../"):
        return f.short_path[3:]
    return workspace_name + "/" + f.short_path

def _is_windows(ctx):
    return ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo])

def _flutter_sdk_binary_impl(ctx):
    toolchain = ctx.toolchains["//flutter:toolchain_type"]
    flutter_sdk_info = toolchain.flutter_sdk_info

    dart_path = _runfiles_path(flutter_sdk_info.dart, ctx.workspace_name)

    if _is_windows(ctx):
        script = ctx.actions.declare_file(ctx.label.name + ".bat")
        ctx.actions.write(
            output = script,
            content = _BAT_TEMPLATE.format(dart = dart_path.replace("/", "\\")),
            is_executable = True,
        )
    else:
        script = ctx.actions.declare_file(ctx.label.name)
        ctx.actions.write(
            output = script,
            content = """#!/usr/bin/env bash
{runfiles_init}
DART="$(rlocation "{dart}")"
if [[ -n "${{BUILD_WORKING_DIRECTORY:-}}" ]]; then
  cd "$BUILD_WORKING_DIRECTORY"
fi
exec "$DART" "$@"
""".format(
                runfiles_init = _BASH_RUNFILES_INIT,
                dart = dart_path,
            ),
            is_executable = True,
        )

    runfiles = ctx.runfiles(transitive_files = flutter_sdk_info.tool_files)
    runfiles = runfiles.merge(ctx.attr._runfiles_lib[DefaultInfo].default_runfiles)

    return [DefaultInfo(
        executable = script,
        runfiles = runfiles,
    )]

flutter_sdk_binary = rule(
    implementation = _flutter_sdk_binary_impl,
    attrs = {
        "_runfiles_lib": attr.label(
            default = "@bazel_tools//tools/bash/runfiles",
        ),
        "_windows_constraint": attr.label(
            default = "@platforms//os:windows",
        ),
    },
    executable = True,
    toolchains = ["//flutter:toolchain_type"],
    doc = "Exposes the Flutter-bundled Dart binary from the resolved toolchain as a runnable target.",
)
