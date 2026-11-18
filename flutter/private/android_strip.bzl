"""Stripping Android native libraries as a Gradle build does.

The Android Gradle Plugin's `strip<Variant>DebugSymbols` task runs the NDK's
`llvm-strip --strip-unneeded` over every native library it packages, in every
build type, into an APK or an AAR alike; `android_binary` packages a library as
it finds it. `run_strip_native_libs` strips the same way, with
`//flutter/private/tools:strip_native_libs.dart`.

The strip tool is the C++ toolchain's, resolved for the Android platform the
rule is configured for: the NDK toolchain an Android build registers. The
action runs in its own exec group, `STRIP`, which resolves that toolchain
together with the Flutter host tools whose `dart` runs the script. The group is
pinned to the machine running Bazel. rules_android_ndk's NDK, an installed one
(`ANDROID_NDK_HOME`), has toolchains with no execution constraints in every
release (through 0.1.5), so they match any execution platform: without the pin,
a registered remote Linux platform would take the strip and run it against a
macOS NDK it cannot see. hermetic_android_toolchains' NDK declares the host of
each of its toolchains, but the pin has to hold for both. Once a released
rules_android_ndk declares the OS and CPU of an installed NDK's toolchains, drop
the pin and let them place the action, which then still shares one execution
platform with the Flutter host tools.

With no C++ toolchain for the platform the target still analyses, and its
strip action fails, naming the NDK to register.
"""

load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter/private:exec_groups.bzl", "FLUTTER_EXEC_TOOLS")

visibility("//flutter/...")

# The exec group the strip runs in. Its name is part of the rules' interface:
# a user places it with `exec_group_compatible_with`.
STRIP = "strip"

STRIP_EXEC_GROUPS = {STRIP: exec_group(
    exec_compatible_with = HOST_CONSTRAINTS,
    toolchains = [FLUTTER_EXEC_TOOLS] + use_cc_toolchain(mandatory = False),
)}

# The attributes `run_strip_native_libs` reads.
STRIP_ATTRS = {
    "_strip_native_libs_tool": attr.label(
        default = "//flutter/private/tools:strip_native_libs.dart",
        allow_single_file = True,
    ),
    "_strip_zipper": attr.label(
        default = "@bazel_tools//tools/zip:zipper",
        executable = True,
        cfg = config.exec(STRIP),
    ),
}

def run_strip_native_libs(ctx, input, libs, mnemonic, progress_message, output = None):
    """Strips the native libraries of `input` into the zip `libs`.

    The rule needs `STRIP_ATTRS`, `STRIP_EXEC_GROUPS` and the `cpp` fragment,
    and must be configured for an Android platform, which picks the NDK's
    strip tool.

    Args:
        ctx: Rule context.
        input: A jar to split, given `output`; otherwise a zip of
            `lib/<abi>/<name>` native libraries alone, possibly empty.
        libs: The zip of the stripped libraries: compressed for a jar, stored
            for a zip of libraries.
        mnemonic: The action's mnemonic.
        progress_message: The action's progress message.
        output: The jar of `input`'s other entries, for a jar.
    """
    toolchains = ctx.exec_groups[STRIP].toolchains
    flutter_tools = toolchains[FLUTTER_EXEC_TOOLS].flutter_exec_tools_info
    args = ctx.actions.args()
    args.add(ctx.file._strip_native_libs_tool)
    args.add("--zipper", ctx.executable._strip_zipper)
    cc_info = toolchains[CC_TOOLCHAIN_TYPE]
    if not cc_info:
        # Analysing the target needs no NDK; building it does, and says so.
        args.add("--no-strip", (
            "%s: no C++ toolchain for the Android platform it is built for, to strip its " +
            "native libraries with. Register the NDK's (README, \"Android\")."
        ) % ctx.label)
        _run(ctx, args, flutter_tools, input, libs, output, depset(), mnemonic, progress_message)
        return
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

    # The toolchain names its tool by path. When that path is one of the
    # toolchain's own files it is handed over as the File, so path mapping
    # rewrites it with the rest; a path outside them (an absolute host path)
    # names no configuration.
    toolchain_files = cc_toolchain.all_files
    strip_file = [f for f in toolchain_files.to_list() if f.path == strip]
    args.add("--strip", strip_file[0] if strip_file else strip)
    _run(ctx, args, flutter_tools, input, libs, output, toolchain_files, mnemonic, progress_message)

def _run(ctx, args, flutter_tools, input, libs, output, toolchain_files, mnemonic, progress_message):
    args.add("--input", input)
    if output:
        args.add("--output", output)
    args.add("--libs", libs)
    ctx.actions.run(
        executable = flutter_tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._strip_native_libs_tool, input],
            transitive = [flutter_tools.sdk_files.run, toolchain_files],
        ),
        tools = [ctx.executable._strip_zipper],
        outputs = [libs] + ([output] if output else []),
        mnemonic = mnemonic,
        exec_group = STRIP,
        execution_requirements = PATH_MAPPING,
        progress_message = progress_message,
    )
