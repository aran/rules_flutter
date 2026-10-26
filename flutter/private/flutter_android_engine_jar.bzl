"""The Flutter engine jar with its native libraries stripped.

Google publishes `flutter.jar` with `libflutter.so` (and, in the arm64 debug
engine, `libVkLayer_khronos_validation.so`) carrying full debug info: about
165 MB of release engine that strips to 12 MB. A Gradle build strips every
native library it packages, in every build type, with the NDK's
`llvm-strip --strip-unneeded` (the Android Gradle Plugin's
`strip<Variant>DebugSymbols` task); `android_binary` packages a jar's
`lib/**.so` as it finds it. This rule produces the jar
`flutter_android_engine` imports, with the same stripping applied, so an APK
carries the engine a Gradle-built one does. Each engine repository declares
its stripped jars, so every `flutter_android_engine` (one per pub plugin, as
well as the app's) shares one stripping action.

The strip tool is the C++ toolchain's, resolved for the Android platform of
`android_abi` — the NDK toolchain an Android build registers. The unstripped
jar stays in its repository for symbolizing a native engine crash.
"""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:common.bzl", "ANDROID_ABIS", "android_platform_for_abi")

_TOOL = Label("//flutter/private/tools:strip_native_libs.dart")

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
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    cc_toolchain = find_cc_toolchain(ctx)
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

    ctx.actions.run(
        executable = flutter_sdk_info.dart,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._tool, ctx.file.jar],
            transitive = [flutter_sdk_info.tool_files, cc_toolchain.all_files],
        ),
        tools = [ctx.executable._zipper],
        outputs = [output],
        mnemonic = "FlutterStripEngine",
        execution_requirements = PATH_MAPPING,
        progress_message = "Stripping the Flutter engine's native libraries for %{label}",
    )
    return [DefaultInfo(files = depset([output]))]

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
            cfg = "exec",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    toolchains = ["@rules_flutter//flutter:toolchain_type"] + use_cc_toolchain(),
    fragments = ["cpp"],
    doc = "Strips the native libraries of a Flutter engine jar as the Android Gradle Plugin does.",
)
