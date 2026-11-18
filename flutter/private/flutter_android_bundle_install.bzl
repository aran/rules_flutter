"""The App Bundle `flutter_android_app` declares, with `bazel run` installing it.

rules_android's `android_application` builds the bundle; this rule forwards it
under the name the user chose and gives `bazel run` a program of rules_flutter's
own that installs it on a device. bundletool turns the bundle into the APKs of
the device, signed with the debug key the bundle's base module was signed with,
and installs them, as `bazel run` of an `android_application` means to.

Every tool the program runs comes from the build: the JDK Bazel runs its own
Java tools with (`--tool_java_runtime_version`), bundletool from the Android toolchain with the Kotlin runtime its
device commands need beside it, the Android toolchain's `aapt2`, and the SDK's
`adb`. None is looked up on PATH.
"""

load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")
load("@rules_android//providers:providers.bzl", "AndroidBundleInfo", "ApkInfo")
load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:android_debug_info.bzl", "AndroidDebugInfo", "android_debug_info_aspect")
load("//flutter/private:host_platform_transition.bzl", "host_platform_transition")

visibility("//flutter/...")

_ANDROID_TOOLCHAIN = "@rules_android//toolchains/android:toolchain_type"
_ANDROID_SDK_TOOLCHAIN = "@rules_android//toolchains/android_sdk:toolchain_type"

# The Android tools the program runs (bundletool's aapt2, adb) run where
# `bazel run` starts it: on this machine, never on a registered remote platform.
_HOST_TOOLS = "android_bundle_install_host_tools"

def _java(java_runtime, is_windows):
    suffix = "/bin/java" + (".exe" if is_windows else "")
    for file in java_runtime.files.to_list():
        if file.path.endswith(suffix):
            return file
    fail("The Java runtime %s has no %s, which installing an App Bundle runs." %
         (java_runtime.java_home, suffix[1:]))

def _flutter_android_app_bundle_impl(ctx):
    bundle = ctx.attr.bundle
    aab = bundle[AndroidBundleInfo].unsigned_aab
    apk_info = bundle[ApkInfo]

    # The key the bundle's base module was signed with: rules_android's debug
    # key, unless the app names keys of its own.
    debug_key = apk_info.signing_keys[-1]

    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    java_runtime = ctx.attr._java_runtime[java_common.JavaRuntimeInfo]
    java = _java(java_runtime, is_windows)

    host_tools = ctx.exec_groups[_HOST_TOOLS].toolchains
    android = host_tools[_ANDROID_TOOLCHAIN]
    bundletool = android.bundletool[DefaultInfo].files.to_list()[0]
    aapt2 = android.aapt2[DefaultInfo].files_to_run
    adb = host_tools[_ANDROID_SDK_TOOLCHAIN].android_sdk_info.adb

    kotlin = ctx.attr._kotlin_stdlib[JavaInfo].transitive_runtime_jars.to_list()

    # The bundle under this target's name, where `bazel build` of the
    # android_application would have put it.
    unsigned_aab = ctx.actions.declare_file(ctx.label.name + "_unsigned.aab")
    ctx.actions.symlink(output = unsigned_aab, target_file = aab)

    workspace = ctx.workspace_name
    config = ctx.actions.declare_file(ctx.label.name + ".android_bundle_install.json")
    ctx.actions.write(config, json.encode_indent({
        "aab": runfiles_path(aab, workspace),
        "aapt2": runfiles_path(aapt2.executable, workspace),
        "adb": runfiles_path(adb.executable, workspace),
        "bundletoolClasspath": [runfiles_path(jar, workspace) for jar in [bundletool] + kotlin],
        "java": runfiles_path(java, workspace),
        "key": runfiles_path(debug_key, workspace),
        "label": str(ctx.label),
    }))

    tool = ctx.attr._tool
    executable = ctx.actions.declare_file(ctx.label.name + (".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [config, aab, debug_key, bundletool, adb.executable] + kotlin,
        transitive_files = java_runtime.files,
    )
    runfiles = runfiles.merge_all([
        tool[DefaultInfo].default_runfiles,
        android.aapt2[DefaultInfo].default_runfiles,
        ctx.runfiles(files = [aapt2.executable]),
    ])

    return [
        DefaultInfo(
            files = depset([unsigned_aab]),
            executable = executable,
            runfiles = runfiles,
        ),
        RunEnvironmentInfo(environment = {
            "RULES_FLUTTER_ANDROID_BUNDLE_INSTALL_CONFIG": runfiles_path(config, workspace),
        }),
        # With `--@rules_dart//dart:split_debug_info`, the `.symbols` of the
        # snapshot of each ABI the bundle ships.
        OutputGroupInfo(debug_info = bundle[AndroidDebugInfo].debug_info),
        bundle[AndroidBundleInfo],
        apk_info,
    ]

flutter_android_app_bundle = rule(
    implementation = _flutter_android_app_bundle_impl,
    executable = True,
    # `bazel run` starts the program and the JDK on this machine. The bundle
    # takes its ABIs from `--@rules_android//flags:android_platforms`, which
    # this leaves alone.
    cfg = host_platform_transition,
    exec_groups = {_HOST_TOOLS: exec_group(
        exec_compatible_with = HOST_CONSTRAINTS,
        toolchains = [_ANDROID_TOOLCHAIN, _ANDROID_SDK_TOOLCHAIN],
    )},
    attrs = {
        "bundle": attr.label(
            doc = "The `android_application` to forward and install.",
            mandatory = True,
            aspects = [android_debug_info_aspect],
            providers = [AndroidBundleInfo, ApkInfo],
        ),
        "_java_runtime": attr.label(
            # The JDK of `--tool_java_runtime_version`, a remote one in the
            # setup the README gives, so nothing needs Java installed.
            default = "@bazel_tools//tools/jdk:current_java_runtime",
            cfg = config.exec(_HOST_TOOLS),
            providers = [java_common.JavaRuntimeInfo],
        ),
        "_kotlin_stdlib": attr.label(
            # bundletool's device commands (install-apks) reach Kotlin code
            # whose runtime its POM does not declare.
            default = Label("@rules_flutter_maven//:org_jetbrains_kotlin_kotlin_stdlib"),
            providers = [JavaInfo],
        ),
        "_tool": attr.label(
            default = Label("//flutter/private/tools:android_bundle_install"),
            executable = True,
            cfg = "target",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    doc = """An App Bundle that `bazel run` installs on a device.

Builds and forwards `bundle` (its `AndroidBundleInfo` and `ApkInfo`, and the
bundle as `<name>_unsigned.aab`). `bazel run` installs it on the device
`ANDROID_SERIAL` names, or the only one connected, through bundletool, signed
with the base module's debug key. With `--@rules_dart//dart:split_debug_info`,
its `debug_info` output group holds the `.symbols` of each ABI's `libapp.so`
in the bundle (`app.android-arm64.symbols`).
""",
)
