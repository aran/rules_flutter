"""Collects what a hot restart reads of a Windows app, without building the app.

A restart needs two things of the app it is restarting: the `flutter_assets`
tree, to see whether an asset moved, and the native code the bundle carries, to
see whether the process must be replaced rather than restarted. Building the
bundle to read them costs far more than they do: a debug bundle copies in the
app's kernel, so every Dart edit recompiles the whole program for it, while a
restart compiles the same edit itself, in the resident compiler.

An aspect reaches through the launch target (`flutter_windows_app`, which declares
a `flutter_windows_bundle`) and meets each dependency in the configuration the
bundle really used. Building only its output groups builds only what they hold:

    bazel build <launch target> \\
        --aspects=@rules_flutter//flutter:windows_bundle_parts.bzl%flutter_windows_bundle_parts_aspect \\
        --output_groups=flutter_windows_bundle_parts,flutter_windows_native_libs

`flutter_windows_bundle_parts` holds the application's `flutter_assets` tree, as
the bundle copies it in.

`flutter_windows_native_libs` holds what the bundle's native code is made from:
the libraries the bundle copies in beside the runner (the application's
`native_deps` and its bundled code assets), and the runner executable, which has
the plugins compiled into it. A change to any of them is a change to code the
running process has already loaded. An exec configuration is left out, since a
tool the build runs is not in the app.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:bundle_parts.bzl", "parts_of_dependencies", "parts_result", "runner_binary")
load("//flutter/private:flutter_native_assets.bzl", "candidate_code_asset_libraries")
load("//flutter/private:native_libraries.bzl", "native_library_files")

WINDOWS_BUNDLE_PARTS_OUTPUT_GROUP = "flutter_windows_bundle_parts"
WINDOWS_NATIVE_LIBS_OUTPUT_GROUP = "flutter_windows_native_libs"

def _flutter_windows_bundle_parts_aspect_impl(_target, ctx):
    if ctx.configuration.is_tool_configuration():
        return parts_result([], [], [], WINDOWS_BUNDLE_PARTS_OUTPUT_GROUP, WINDOWS_NATIVE_LIBS_OUTPUT_GROUP)
    assets = []
    native_libs = []

    # Only from the rule that assembles the bundle: the registrant and the
    # runner name the application too, and what they read of it is not what
    # the bundle carries.
    if ctx.rule.kind == "flutter_windows_bundle_rule":
        app = ctx.rule.attr.application
        if type(app) == "Target" and FlutterApplicationInfo in app:
            app_info = app[FlutterApplicationInfo]
            assets.append(depset([app_info.flutter_assets]))
            native_libs.append(depset(native_library_files(app_info)))
            native_libs.append(depset(candidate_code_asset_libraries(app_info.program_assets)))
        runner = runner_binary(ctx.rule.attr.runner)
        if runner:
            native_libs.append(depset([runner]))

    return parts_result(
        assets,
        native_libs,
        parts_of_dependencies(ctx.rule.attr),
        WINDOWS_BUNDLE_PARTS_OUTPUT_GROUP,
        WINDOWS_NATIVE_LIBS_OUTPUT_GROUP,
    )

flutter_windows_bundle_parts_aspect = aspect(
    implementation = _flutter_windows_bundle_parts_aspect_impl,
    attr_aspects = ["*"],
    doc = "Collects the flutter_assets tree and the native code inputs of a Windows app below a launch target, in the configuration each was built in.",
)
