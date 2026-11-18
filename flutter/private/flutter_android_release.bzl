"""`flutter_android_release`: sign an App Bundle and its APK with the upload key.

rules_android signs only with its debug key, and has no release signing by
design: a key handed to a build action reaches Bazel's action keys, caches and
remote executors. This rule builds the App Bundle in release mode and gives
`bazel run` a program that signs it on this machine, reading the keystore and
its passwords from the `key.properties` file Flutter's own deployment docs
describe. The rule takes no keystore, no password and no `key.properties`
label, so none of them can enter the build graph.

    bazel run //:app_release                 # sign
    bazel run //:app_release -- create-key   # make the upload keystore

The program, `flutter/private/tools/android_release.dart`, writes
`build/app/outputs/bundle/release/app-release.aab` and
`build/app/outputs/flutter-apk/app-release.apk` under the target's package, as
`flutter build appbundle` and `flutter build apk` do.
"""

load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")
load("@rules_android//providers:providers.bzl", "AndroidBundleInfo", "ApkInfo")
load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("//flutter/private:android_debug_info.bzl", "AndroidDebugInfo", "android_debug_info_aspect")
load("//flutter/private:host_platform_transition.bzl", "host_platform_transition")
load("//flutter/private:release_transition.bzl", "android_release_transition")

visibility("//flutter/...")

_ANDROID_TOOLCHAIN = "@rules_android//toolchains/android:toolchain_type"
_JAVA_RUNTIME_TOOLCHAIN = "@bazel_tools//tools/jdk:runtime_toolchain_type"

# The Android tool the program runs (bundletool) runs where `bazel run`
# starts it: on this machine, never on a registered remote platform.
_HOST_TOOLS = "android_release_host_tools"

_JDK_TOOLS = ["java", "jarsigner", "keytool"]

def _jdk_tool(java_runtime, tool, is_windows):
    suffix = "/bin/" + tool + (".exe" if is_windows else "")
    for file in java_runtime.files.to_list():
        if file.path.endswith(suffix):
            return file
    fail(("flutter_android_release needs a full JDK (java, jarsigner, keytool) as " +
          "the Java runtime, and %s has no %s. Set --java_runtime_version to a remote " +
          "JDK such as remotejdk_25.") % (java_runtime.java_home, suffix[1:]))

def _key_properties_error(path):
    if not path:
        return "is empty"
    if path.startswith("/") or (len(path) > 1 and path[1] == ":"):
        return "is absolute"
    if ".." in path.replace("\\", "/").split("/"):
        return "leaves the package with `..`"
    return None

def _flutter_android_release_impl(ctx):
    if ctx.label.repo_name:
        fail(("flutter_android_release %s is in an external repository. It finds " +
              "key.properties and writes its outputs in the source tree of the main " +
              "repository, so declare it there.") % ctx.label)
    error = _key_properties_error(ctx.attr.key_properties)
    if error:
        fail(("flutter_android_release %s: `key_properties` %r %s; give a path " +
              "relative to the package, like the default android/key.properties.") %
             (ctx.label, ctx.attr.key_properties, error))

    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    java_runtime = ctx.toolchains[_JAVA_RUNTIME_TOOLCHAIN].java_runtime
    jdk = {tool: _jdk_tool(java_runtime, tool, is_windows) for tool in _JDK_TOOLS}

    android = ctx.exec_groups[_HOST_TOOLS].toolchains[_ANDROID_TOOLCHAIN]
    bundletool = android.bundletool[DefaultInfo].files.to_list()[0]

    bundle = ctx.attr.app_bundle[0]
    aab = bundle[AndroidBundleInfo].unsigned_aab

    # The APK of the bundle's base module: the same release build, zipaligned
    # and signed with the debug key, which the program replaces.
    apk = bundle[ApkInfo].signed_apk

    apksigner = ctx.attr.apksigner[java_common.JavaRuntimeClasspathInfo].runtime_classpath

    workspace = ctx.workspace_name
    config = ctx.actions.declare_file(ctx.label.name + ".android_release.json")
    ctx.actions.write(config, json.encode_indent({
        "aab": runfiles_path(aab, workspace),
        "apk": runfiles_path(apk, workspace),
        "apksigner": [runfiles_path(jar, workspace) for jar in apksigner.to_list()],
        "bundletool": runfiles_path(bundletool, workspace),
        "keyProperties": ctx.attr.key_properties,
        "label": "//%s:%s" % (ctx.label.package, ctx.label.name),
        "package": ctx.label.package,
    } | {tool: runfiles_path(file, workspace) for tool, file in jdk.items()}))

    tool = ctx.attr._tool
    executable = ctx.actions.declare_file(ctx.label.name + (".exe" if is_windows else ""))
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [config, aab, apk, bundletool],
        transitive_files = depset(transitive = [apksigner, java_runtime.files]),
    )
    runfiles = runfiles.merge(tool[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(environment = {
            "RULES_FLUTTER_ANDROID_RELEASE_CONFIG": runfiles_path(config, workspace),
        }),
        OutputGroupInfo(
            android_release_config = depset([config]),
            # With `--@rules_dart//dart:split_debug_info`, the `.symbols` of
            # the release snapshot of each ABI the bundle and APK ship.
            debug_info = bundle[AndroidDebugInfo].debug_info,
        ),
    ]

_flutter_android_release = rule(
    implementation = _flutter_android_release_impl,
    executable = True,
    # `bazel run` starts the program and the JDK on this machine.
    cfg = host_platform_transition,
    toolchains = [_JAVA_RUNTIME_TOOLCHAIN],
    exec_groups = {_HOST_TOOLS: exec_group(
        exec_compatible_with = HOST_CONSTRAINTS,
        toolchains = [_ANDROID_TOOLCHAIN],
    )},
    attrs = {
        "apksigner": attr.label(
            doc = "The Android SDK's `apksigner`, which signs the APK: its " +
                  "`java_binary`, such as `@androidsdk//:apksigner`, run on " +
                  "its runtime classpath.",
            mandatory = True,
            providers = [java_common.JavaRuntimeClasspathInfo],
        ),
        "android_platforms": attr.label_list(
            doc = "The ABIs of the release build, whatever " +
                  "`--@rules_android//flags:android_platforms` says. Defaults to " +
                  "every ABI rules_flutter builds, as `flutter build appbundle` " +
                  "includes every ABI.",
            default = [
                Label("@rules_android//:armeabi-v7a"),
                Label("@rules_android//:arm64-v8a"),
                Label("@rules_android//:x86_64"),
            ],
            providers = [platform_common.PlatformInfo],
        ),
        "app_bundle": attr.label(
            doc = "The `android_application` (App Bundle) to sign: " +
                  "`flutter_android_app`'s `app_bundle`, or one assembled from the " +
                  "Tier 2 rules. Built in release mode (`-c opt`, not profile) for " +
                  "`android_platforms`, whatever the command line says.",
            mandatory = True,
            cfg = android_release_transition,
            providers = [AndroidBundleInfo, ApkInfo],
            aspects = [android_debug_info_aspect],
        ),
        "key_properties": attr.string(
            doc = "Where the signing configuration is, relative to this target's " +
                  "package in the source tree: Flutter's `key.properties` " +
                  "(`storePassword`, `keyPassword`, `keyAlias`, `storeFile`). A path, " +
                  "not a label, so the file never enters the build graph. " +
                  "`--key-properties` overrides it at run time.",
            default = "android/key.properties",
        ),
        "_tool": attr.label(
            default = Label("//flutter/private/tools:android_release"),
            executable = True,
            cfg = "target",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    doc = """Signs an App Bundle and its APK with the app's upload key, when run.

`bazel run` of this target builds `app_bundle` in release mode for every ABI
of `android_platforms`, signs it with the key `key.properties` names, signs
the APK of the same build (its bundle's base module) with the same key through
the SDK's `apksigner`, checks both, and writes them to
`build/app/outputs/bundle/release/app-release.aab` and
`build/app/outputs/flutter-apk/app-release.apk` under the package. Nothing is
signed in a build action: the keystore and its passwords are read when the
program runs and never reach Bazel.

With `--@rules_dart//dart:split_debug_info`, its `debug_info` output group
holds the `.symbols` of the release snapshot of each ABI the bundle and APK
ship (`app.android-arm64.symbols`), as `flutter build appbundle
--split-debug-info` writes them.

Commands (after `--`):

    sign (the default)  --key-properties=<path>  --output-dir=<dir>
    create-key          --key-properties=<path>  --dname=<X.500 name>
""",
)

def flutter_android_release(name, apksigner = Label("@androidsdk//:apksigner"), **kwargs):
    """Signs an App Bundle and its APK with the app's upload key, when run.

    See the rule, `_flutter_android_release`, for what it does and its
    attributes.

    Args:
        name: Target name; `bazel run` it to sign.
        apksigner: The Android SDK's `apksigner`, a `java_binary`. Defaults to
            that of `@androidsdk`, the SDK that builds the APKs, whether
            hermetic_android_toolchains downloads it or rules_android finds it
            at `ANDROID_HOME`.
        **kwargs: The rule's other attributes: `app_bundle`,
            `android_platforms`, `key_properties`, and the common ones.
    """
    _flutter_android_release(name = name, apksigner = apksigner, **kwargs)
