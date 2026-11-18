"""Stripping Android native libraries as a Gradle build does.

The Android Gradle Plugin's `strip<Variant>DebugSymbols` task runs the NDK's
`llvm-strip --strip-unneeded` over every native library it packages, in every
build type, into an APK or an AAR alike: the app's own, a plugin's, and those
of the Maven AARs it depends on. `android_binary` packages a library as it
finds it. `run_strip_native_libs` strips the libraries of jars and zips the
same way, with `//flutter/private/tools:strip_native_libs.dart`, and
`strip_native_library` strips one library.

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

# The attributes `run_strip_native_libs` and `strip_native_library` read.
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

def android_strip_tool(ctx):
    """The NDK's strip tool for the rule's Android platform, or None without a C++ toolchain.

    The rule needs `STRIP_EXEC_GROUPS` and the `cpp` fragment.

    Args:
        ctx: Rule context.

    Returns:
        None, or a struct of `strip` (the execution path the toolchain names
        for the tool), `files` (depset of the toolchain's files, the action's
        inputs), `execution_requirements` (for an action that runs it),
        `cc_toolchain` and `feature_configuration`.
    """
    cc_info = ctx.exec_groups[STRIP].toolchains[CC_TOOLCHAIN_TYPE]
    if not cc_info:
        return None
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
    return struct(
        strip = strip,
        files = cc_toolchain.all_files,
        # Path mapping rewrites the paths of Files, not strings: a tool the
        # build makes, whose path names a configuration, must keep its own.
        execution_requirements = {} if strip.startswith("bazel-out/") else PATH_MAPPING,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
    )

def _no_strip_reason(ctx):
    return (
        "%s: no C++ toolchain for the Android platform it is built for, to strip its " +
        "native libraries with. Register the NDK's (README, \"Android\")."
    ) % ctx.label

def run_strip_native_libs(ctx, inputs, libs, mnemonic, progress_message, output = None):
    """Strips the native libraries of each of `inputs` into the zip of `libs` in its place, in one action.

    The rule needs `STRIP_ATTRS`, `STRIP_EXEC_GROUPS` and the `cpp` fragment,
    and must be configured for an Android platform, which picks the NDK's
    strip tool.

    Args:
        ctx: Rule context.
        inputs: List of Files: one jar to split, given `output`; otherwise
            zips of `lib/<abi>/<name>` native libraries alone, any of them
            possibly empty.
        libs: List of Files, one for each of `inputs`: the zip of its
            stripped libraries, compressed for a jar and stored for a zip of
            libraries.
        mnemonic: The action's mnemonic.
        progress_message: The action's progress message.
        output: The jar of the other entries of the one jar of `inputs`.
    """
    outputs = libs
    if len(inputs) != len(outputs):
        fail("%s: %d zips to strip into %d" % (ctx.label, len(inputs), len(outputs)))
    if not inputs:
        return
    flutter_tools = ctx.exec_groups[STRIP].toolchains[FLUTTER_EXEC_TOOLS].flutter_exec_tools_info
    args = ctx.actions.args()
    args.add(ctx.file._strip_native_libs_tool)
    args.add("--zipper", ctx.executable._strip_zipper)
    tool = android_strip_tool(ctx)
    if tool:
        args.add("--strip", tool.strip)
    else:
        # Analysing the target needs no NDK; building it does, and says so.
        args.add("--no-strip", _no_strip_reason(ctx))
    for i, o in zip(inputs, outputs):
        args.add("--input", i)
        args.add("--libs", o)
    if output:
        args.add("--output", output)
    ctx.actions.run(
        executable = flutter_tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._strip_native_libs_tool] + inputs,
            transitive = [flutter_tools.sdk_files.run] + ([tool.files] if tool else []),
        ),
        tools = [ctx.executable._strip_zipper],
        outputs = outputs + ([output] if output else []),
        mnemonic = mnemonic,
        exec_group = STRIP,
        execution_requirements = tool.execution_requirements if tool else PATH_MAPPING,
        progress_message = progress_message,
    )

def strip_native_library(ctx, input, output, mnemonic, progress_message):
    """Strips the native library `input` into `output`, as the Android Gradle Plugin does.

    The NDK's strip tool runs with the arguments `stripArguments` of
    strip_native_libs.dart gives it. The rule needs what
    `run_strip_native_libs` does.

    Args:
        ctx: Rule context.
        input: The library.
        output: The stripped library.
        mnemonic: The action's mnemonic.
        progress_message: The action's progress message.
    """
    tool = android_strip_tool(ctx)
    args = ctx.actions.args()
    if not tool:
        flutter_tools = ctx.exec_groups[STRIP].toolchains[FLUTTER_EXEC_TOOLS].flutter_exec_tools_info
        args.add(ctx.file._strip_native_libs_tool)
        args.add("--no-strip", _no_strip_reason(ctx))
        ctx.actions.run(
            executable = flutter_tools.dart,
            arguments = [args],
            inputs = depset([ctx.file._strip_native_libs_tool], transitive = [flutter_tools.sdk_files.run]),
            outputs = [output],
            mnemonic = mnemonic,
            exec_group = STRIP,
            progress_message = progress_message,
        )
        return
    args.add_all(["--strip-unneeded", "-o", output, input])
    ctx.actions.run(
        executable = tool.strip,
        arguments = [args],
        inputs = depset([input], transitive = [tool.files]),
        outputs = [output],
        mnemonic = mnemonic,
        exec_group = STRIP,
        execution_requirements = tool.execution_requirements,
        progress_message = progress_message,
    )
