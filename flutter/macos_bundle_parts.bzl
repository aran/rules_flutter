"""Collects what a hot restart reads of a macOS app, without building the app bundle.

A restart needs two things of the app it is restarting: the `flutter_assets`
tree, to see whether an asset moved, and the native code the bundle carries, to
see whether the process must be replaced rather than restarted. Building the
bundle to read them costs far more than they do: a debug bundle's
`App.framework` holds the app's kernel, so every Dart edit recompiles the whole
program into it and re-signs the bundle, and a restart compiles the same edit
itself, in the resident compiler.

An aspect reaches through the launch target (`flutter_apple_app`, then
rules_apple's `macos_application`), transitions included, and meets each
dependency in the configuration the bundle really used. Building only its
output groups builds only what they hold:

    bazel build <launch target> \\
        --aspects=@rules_flutter//flutter:macos_bundle_parts.bzl%flutter_macos_bundle_parts_aspect \\
        --output_groups=flutter_macos_bundle_parts,flutter_macos_native_libs

`flutter_macos_bundle_parts` holds the application's `flutter_assets` tree, as
the `flutter_macos_app_framework` that puts it into `App.framework` reads it.

`flutter_macos_native_libs` holds what the bundle's native code is made from:
the libraries a `flutter_macos_native_libs` stages into `Contents/Frameworks`
(the application's `native_deps` and its bundled code assets), and the linker
inputs (archives, objects and shared libraries) of every `CcInfo` dependency,
which covers the runner executable, the plugins linked into it, and any
framework the bundle embeds. A change to any of them is a change to code the
running process has already loaded. An exec configuration is left out, since a
tool the build runs is not in the app.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:bundle_parts.bzl", "own_libraries", "parts_of_dependencies", "parts_result")
load("//flutter/private:flutter_native_assets.bzl", "candidate_code_asset_libraries")
load("//flutter/private:native_libraries.bzl", "native_library_files")

MACOS_BUNDLE_PARTS_OUTPUT_GROUP = "flutter_macos_bundle_parts"
MACOS_NATIVE_LIBS_OUTPUT_GROUP = "flutter_macos_native_libs"

def _application_info(ctx):
    app = getattr(ctx.rule.attr, "application", None)
    if type(app) == "Target" and FlutterApplicationInfo in app:
        return app[FlutterApplicationInfo]
    return None

def _flutter_macos_bundle_parts_aspect_impl(target, ctx):
    if ctx.configuration.is_tool_configuration():
        return parts_result([], [], [], MACOS_BUNDLE_PARTS_OUTPUT_GROUP, MACOS_NATIVE_LIBS_OUTPUT_GROUP)
    assets = []
    native_libs = []

    # Each from the rule that puts it into the bundle, not from every rule that
    # names the application: the registrant and the plugin aggregator name it
    # too, and what they read of it is not what the bundle carries.
    app_info = _application_info(ctx)
    if app_info:
        if ctx.rule.kind == "flutter_macos_app_framework":
            assets.append(depset([app_info.flutter_assets]))
        elif ctx.rule.kind == "flutter_macos_native_libs":
            native_libs.append(depset(native_library_files(app_info)))
            native_libs.append(depset(candidate_code_asset_libraries(app_info.program_assets)))

    if CcInfo in target:
        native_libs.append(depset(own_libraries(target[CcInfo], target.label)))

    return parts_result(
        assets,
        native_libs,
        parts_of_dependencies(ctx.rule.attr),
        MACOS_BUNDLE_PARTS_OUTPUT_GROUP,
        MACOS_NATIVE_LIBS_OUTPUT_GROUP,
    )

flutter_macos_bundle_parts_aspect = aspect(
    implementation = _flutter_macos_bundle_parts_aspect_impl,
    attr_aspects = ["*"],
    doc = "Collects the flutter_assets tree and the native code inputs of a macOS app below a launch target, in the configuration each was built in.",
)
