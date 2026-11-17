"""The Flutter engine framework for the build mode, on macOS and iOS.

The application's bundle and every plugin compiled against the engine name
the same framework through these targets. Two imports of one framework name
from different modes reach rules_apple's bundling as one framework, and it
cannot assemble that. Each target follows the build mode itself (debug,
profile or release), so no caller selects. The labels resolve through
rules_flutter's own repo mapping, so a consumer needs none of these repos in
`use_repo`.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:engine.bzl", "FlutterEngineInfo")

# FlutterMacOS.framework of the build mode, as `framework_imports` of an
# apple_dynamic_framework_import.
MACOS_ENGINE_FRAMEWORK = [Label("@flutter_macos_engine//:engine_library")]

# The engine's dSYM, as `dsym_imports` of that apple_dynamic_framework_import,
# so it reaches the app's `dsyms` output group. Only with
# `--apple_generate_dsym`, when rules_apple makes the app's own dSYMs: the
# release dSYM is in Flutter's 165 MB `framework.zip`, which no other macOS
# app build downloads.
MACOS_ENGINE_DSYM = select({
    Label("//flutter/private:apple_generate_dsym"): [Label("//flutter/private:macos_engine_dsym")],
    "//conditions:default": [],
})

# Flutter.xcframework of the build mode, as `xcframework_imports` of an
# apple_dynamic_xcframework_import. Debug (-c dbg) is the JIT engine
# (simulator); profile and release are AOT engines (device).
IOS_ENGINE_XCFRAMEWORK = [Label("@flutter_ios_engine//:Flutter_xcframework")]

def _flutter_engine_module_maps_impl(ctx):
    module_maps = [f for f in ctx.files.framework if f.extension == "modulemap"]
    return [CcInfo(compilation_context = cc_common.create_compilation_context(
        headers = depset(module_maps),
    ))]

flutter_engine_module_maps = rule(
    implementation = _flutter_engine_module_maps_impl,
    attrs = {
        "framework": attr.label_list(allow_files = True, mandatory = True),
    },
    doc = """The engine framework's module maps, as headers of a C-family compile.

An Objective-C source that imports the engine as a module (`@import Flutter;`),
as a plugin's Swift package may, needs the framework's `module.modulemap`,
which rules_apple's framework import does not make an input of an
`objc_library`'s compile: without it the import fails in a sandbox. A
dependency on this target makes the module maps inputs of the compile.
""",
)

def _flutter_macos_engine_dsym_impl(ctx):
    if not ctx.attr.xcframework:
        return [DefaultInfo()]
    engine = ctx.attr.xcframework[FlutterEngineInfo]

    # The dSYM sits beside the framework, in the xcframework's slice:
    # `<slice>/dSYMs/FlutterMacOS.framework.dSYM`.
    binary = engine.binary.path
    marker = "/FlutterMacOS.framework/"
    if marker not in binary:
        fail("%s: the binary %s is not in a FlutterMacOS.framework" % (ctx.attr.xcframework.label, binary))
    prefix = binary[:binary.rfind(marker)] + "/dSYMs/FlutterMacOS.framework.dSYM/"
    return [DefaultInfo(files = depset([f for f in engine.files.to_list() if f.path.startswith(prefix)]))]

flutter_macos_engine_dsym = rule(
    implementation = _flutter_macos_engine_dsym_impl,
    attrs = {
        "xcframework": attr.label(
            doc = "The engine source's `//macos/<mode>:xcframework` slice, or none for no dSYM.",
            providers = [FlutterEngineInfo],
        ),
    },
    doc = """The FlutterMacOS.framework.dSYM of an engine's xcframework slice.

`flutter build macos --release` copies the dSYM from the release
FlutterMacOS.xcframework's slice when the slice has one, and in no other
mode. These are its files, or none when the slice has no dSYM, as upstream.
""",
)
