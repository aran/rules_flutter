"""The Flutter engine jar with its native libraries stripped and set apart.

Google publishes `flutter.jar` with `libflutter.so` (and, in the arm64 debug
engine, `libVkLayer_khronos_validation.so`) carrying full debug info: about
165 MB of release engine that strips to 12 MB. A Gradle build strips every
native library it packages, in every build type, with the NDK's
`llvm-strip --strip-unneeded` (the Android Gradle Plugin's
`strip<Variant>DebugSymbols` task); `android_binary` packages a jar's
`lib/**.so` as it finds it. This rule strips them the same way, so an APK
carries the engine a Gradle-built one does. Each engine repository declares
its stripped jars, so every `flutter_android_engine` (one per pub plugin, as
well as the app's) shares one stripping action.

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

The strip tool is the C++ toolchain's, resolved for the Android platform of
`android_abi` — the NDK toolchain an Android build registers. The action runs
in its own exec group, which resolves that toolchain together with the Flutter
host tools whose `dart` runs the stripping script. The group is pinned to the
machine running Bazel. rules_android_ndk's NDK, an installed one
(`ANDROID_NDK_HOME`), has toolchains with no execution constraints in every
release (through 0.1.5), so they match any execution platform: without the pin,
a registered remote Linux platform would take the strip and run it against a
macOS NDK it cannot see. hermetic_android_toolchains' NDK declares the host of
each of its toolchains, but the pin has to hold for both. Once a released
rules_android_ndk declares the OS and CPU of an installed NDK's toolchains, drop
the pin and let them place the action, which then still shares one execution
platform with the Flutter host tools. The unstripped jar stays in its repository for symbolizing a native
engine crash.
"""

load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")
load("@rules_android//providers:providers.bzl", "AndroidNativeLibsInfo")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:common.bzl", "ANDROID_ABIS", "android_platform_for_abi")
load("//flutter/private:exec_groups.bzl", "FLUTTER_EXEC_TOOLS")

visibility("//flutter/...")

_TOOL = Label("//flutter/private/tools:strip_native_libs.dart")

_STRIP = "strip"

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

def _flutter_android_engine_jar_impl(ctx):
    toolchains = ctx.exec_groups[_STRIP].toolchains
    flutter_tools = toolchains[FLUTTER_EXEC_TOOLS].flutter_exec_tools_info
    cc_info = toolchains[CC_TOOLCHAIN_TYPE]
    if not cc_info:
        fail("%s: no C++ toolchain for the Android platform of `%s`; register the NDK's." %
             (ctx.label, ctx.attr.android_abi))
    cc_toolchain = cc_info.cc
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    strip = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.strip,
    )

    output = ctx.actions.declare_file(ctx.label.name + ".jar")
    libs = ctx.actions.declare_file(ctx.label.name + "_native_libs.zip")
    args = ctx.actions.args()
    args.add(ctx.file._tool)
    args.add("--zipper", ctx.executable._zipper)

    # The toolchain names its tool by path. When that path is one of the
    # toolchain's own files it is handed over as the File, so path mapping
    # rewrites it with the rest; a path outside them (an absolute host path)
    # names no configuration.
    toolchain_files = cc_toolchain.all_files
    strip_file = [f for f in toolchain_files.to_list() if f.path == strip]
    args.add("--strip", strip_file[0] if strip_file else strip)
    args.add("--input", ctx.file.jar)
    args.add("--output", output)
    args.add("--libs", libs)

    ctx.actions.run(
        executable = flutter_tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._tool, ctx.file.jar],
            transitive = [flutter_tools.sdk_files.run, cc_toolchain.all_files],
        ),
        tools = [ctx.executable._zipper],
        outputs = [output, libs],
        mnemonic = "FlutterStripEngine",
        exec_group = _STRIP,
        execution_requirements = PATH_MAPPING,
        progress_message = "Stripping the Flutter engine's native libraries for %{label}",
    )
    return [
        DefaultInfo(files = depset([output])),
        AndroidNativeLibsInfo(native_libs = depset([libs])),
        # Nothing to link: an empty CcInfo is what lets an android_library
        # list this target in `exports`, which takes JavaInfo or CcInfo, and so
        # pass the libraries on.
        CcInfo(),
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
        "_tool": attr.label(
            default = _TOOL,
            allow_single_file = True,
        ),
        "_zipper": attr.label(
            default = "@bazel_tools//tools/zip:zipper",
            executable = True,
            cfg = config.exec(_STRIP),
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    exec_groups = {_STRIP: exec_group(
        exec_compatible_with = HOST_CONSTRAINTS,
        toolchains = [FLUTTER_EXEC_TOOLS] + use_cc_toolchain(),
    )},
    fragments = ["cpp"],
    doc = "Strips the native libraries of a Flutter engine jar as the Android Gradle Plugin does, and sets them apart from the classes.",
)
