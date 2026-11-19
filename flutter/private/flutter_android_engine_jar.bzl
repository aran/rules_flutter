"""The Flutter engine jar with its native libraries stripped and set apart.

Google publishes `flutter.jar` with `libflutter.so` (and, in the arm64 debug
engine, `libVkLayer_khronos_validation.so`) carrying full debug info: about
165 MB of release engine that strips to 12 MB. A Gradle build strips every
native library it packages, in every build type, with the NDK's
`llvm-strip --strip-unneeded` (the Android Gradle Plugin's
`strip<Variant>DebugSymbols` task); `android_binary` packages a jar's
`lib/**.so` as it finds it. This rule strips them the same way
(android_strip.bzl), so an APK carries the engine a Gradle-built one does.
Each engine repository declares its stripped jars, so every
`flutter_android_engine` (one per pub plugin, as well as the app's) shares one
stripping action.

The target has two products. Its default output is the jar of classes the
`java_import` of `flutter_android_engine` takes. The libraries are not in it:
they are a zip of their own, handed on as an `AndroidNativeLibsInfo`, as an
AAR's native libraries are. `android_binary` builds its dependencies once for
each ABI it is asked for and packages the native libraries of each build, but
takes the classes and resources of the first alone, so a library inside a jar
reaches the APK of the first ABI only. This is the engine of one ABI; an APK
for several has one of these per ABI, and `flutter_android_engine` selects
among them. The zip needs no list of the libraries in it, which differ by
engine mode and version.

The strip tool is the NDK's, resolved for the Android platform of
`android_abi`. The unstripped jar stays in its repository for symbolizing a
native engine crash.
"""

load("@rules_android//providers:providers.bzl", "AndroidNativeLibsInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:engine.bzl", "FlutterEngineInfo")
load("//flutter/private:android_strip.bzl", "STRIP_ATTRS", "STRIP_EXEC_GROUPS", "run_strip_native_libs")
load("//flutter/private:common.bzl", "ANDROID_ABIS", "android_platform_for_abi")

visibility("//flutter/...")

def _engine_jar_transition_impl(_settings, attr):
    return {
        "//command_line_option:platforms": [android_platform_for_abi(attr.android_abi)],
        # android_binary's split transition sets this for the app's deps and
        # the plugin libraries' configuration does not; pinning it here makes
        # both reach the same configured target, so the engine is stripped
        # once per mode rather than once per configuration that names it.
        "//command_line_option:dynamic_mode": "off",
    }

# Builds the stripped jar for the Android platform of `android_abi`, which is
# what resolves the NDK's strip tool.
_engine_jar_transition = transition(
    implementation = _engine_jar_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//command_line_option:dynamic_mode",
    ],
)

FlutterAndroidEmbeddingPomInfo = provider(
    doc = "The POM of an Android engine's embedding classes.",
    fields = {"pom": "File or None: the engine slice's `embedding_pom`."},
)

def _flutter_android_engine_jar_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".jar")
    libs = ctx.actions.declare_file(ctx.label.name + "_native_libs.zip")
    run_strip_native_libs(
        ctx,
        inputs = [ctx.file.jar],
        output = output,
        libs = [libs],
        mnemonic = "FlutterStripEngine",
        progress_message = "Stripping the Flutter engine's native libraries for %{label}",
    )
    return [
        DefaultInfo(files = depset([output])),
        AndroidNativeLibsInfo(native_libs = depset([libs])),
        # Nothing to link: an empty CcInfo is what lets an android_library
        # list this target in `exports`, which takes JavaInfo or CcInfo, and so
        # pass the libraries on.
        CcInfo(),
        FlutterAndroidEmbeddingPomInfo(
            pom = ctx.attr.jar[FlutterEngineInfo].embedding_pom if FlutterEngineInfo in ctx.attr.jar else None,
        ),
    ]

flutter_android_engine_jar = rule(
    implementation = _flutter_android_engine_jar_impl,
    cfg = _engine_jar_transition,
    attrs = {
        "jar": attr.label(
            doc = "The engine's flutter.jar.",
            allow_single_file = [".jar"],
            mandatory = True,
        ),
        "android_abi": attr.string(
            doc = "The ABI of the engine's native libraries; picks the strip tool's toolchain.",
            mandatory = True,
            values = ANDROID_ABIS.keys(),
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    } | STRIP_ATTRS,
    exec_groups = STRIP_EXEC_GROUPS,
    fragments = ["cpp"],
    doc = "Strips the native libraries of a Flutter engine jar as the Android Gradle Plugin does, and sets them apart from the classes.",
)
