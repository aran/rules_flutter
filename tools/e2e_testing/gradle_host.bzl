"""What a Gradle build of an e2e workspace's add-to-app host app runs with.

`gradle_host_config` writes, as a JSON file, the runfiles paths of the Gradle
distribution, the JDK, the Android SDK and NDK, the host project and the Maven
repositories the build resolves from, and carries them all in its runfiles.
`package:rules_flutter_e2e_testing/gradle_host.dart` reads it.

The workspace pins the Gradle distribution as `@gradle` and downloads the
Android SDK and NDK as `@androidsdk` and `@androidndk`; the macro names them
in the workspace that calls it.
"""

load("@rules_dart//dart:utils.bzl", "runfiles_path")
load("@rules_java//java/common:java_common.bzl", "java_common")

visibility("public")

def _rlocation(ctx, file):
    return runfiles_path(file, ctx.workspace_name)

def _java_home(ctx, java_runtime):
    path = java_runtime.java_home_runfiles_path
    if path.startswith("../"):
        return path[len("../"):]
    return ctx.workspace_name + "/" + path

def _gradle_host_config_impl(ctx):
    java_runtime = ctx.attr._java_runtime[java_common.JavaRuntimeInfo]
    settings = ctx.file.settings
    module_repositories = []
    for target in ctx.attr.module_repositories:
        directories = [f for f in target[DefaultInfo].files.to_list() if f.is_directory]
        if len(directories) != 1:
            fail("expected one repository directory from %s" % target.label)
        module_repositories.append(directories[0])

    repositories = [{"runfile": _rlocation(ctx, d)} for d in module_repositories]
    if ctx.attr.maven_repository:
        repositories.append({"runfile": ctx.attr.maven_repository.label.repo_name})
    repositories.extend([{"url": url} for url in ctx.attr.remote_repositories])
    if bool(ctx.attr.maven_repository) == bool(ctx.attr.remote_repositories):
        fail("set one of maven_repository (an offline build) and remote_repositories (a recording)")

    project = _rlocation(ctx, settings).rpartition("/")[0]
    config = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(config, json.encode_indent({
        "android_ndk_root": _rlocation(ctx, ctx.file.android_ndk_root),
        "android_sdk_root": _rlocation(ctx, ctx.file.android_sdk_root),
        "gradle_agent": _rlocation(ctx, ctx.file.gradle_agent),
        "gradle_launcher": _rlocation(ctx, ctx.file.gradle_launcher),
        "java_home": _java_home(ctx, java_runtime),
        # Where the lock of the offline repository is, from the workspace root.
        "lock": settings.short_path.rpartition("/")[0] + "/gradle_repository.json",
        "project": project,
        "repositories": repositories,
        "variants": ctx.attr.variants,
    }))

    runfiles = ctx.runfiles(
        files = [config, settings, ctx.file.android_sdk_root, ctx.file.android_ndk_root] +
                module_repositories + ctx.files.project,
        transitive_files = depset(transitive = [
            java_runtime.files,
            depset(ctx.files.android_sdk),
            depset(ctx.files.android_ndk),
            depset(ctx.files.gradle),
            depset(ctx.files.maven_repository),
        ]),
    )
    return [DefaultInfo(files = depset([config]), runfiles = runfiles)]

_gradle_host_config = rule(
    implementation = _gradle_host_config_impl,
    attrs = {
        "android_ndk": attr.label(
            mandatory = True,
            doc = "The NDK files the build reads: the Android Gradle plugin strips the native libraries it packages with the NDK's `llvm-strip`.",
        ),
        "android_ndk_root": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "A file whose physical parent directory is the NDK, which the host's `ndkPath` names.",
        ),
        "android_sdk": attr.label(
            mandatory = True,
            doc = "The SDK files the build reads, so that a new SDK reruns the test.",
        ),
        "android_sdk_root": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "A file whose physical parent directory is the Android SDK, laid out as `sdk.dir` expects.",
        ),
        "gradle": attr.label(
            mandatory = True,
            doc = "Every file of the Gradle distribution.",
        ),
        "gradle_agent": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The Java agent the distribution's launcher script starts Gradle with.",
        ),
        "gradle_launcher": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The jar the distribution's launcher script runs.",
        ),
        "maven_repository": attr.label(
            doc = "A `gradle_offline_repository`'s `:files`: the repository an offline build resolves from.",
        ),
        "module_repositories": attr.label_list(
            mandatory = True,
            doc = "The `flutter_android_aar` repositories of the module, one per build mode.",
        ),
        "project": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "The host project's files.",
        ),
        "remote_repositories": attr.string_list(
            doc = "Repository URLs a recording resolves from, in order.",
        ),
        "settings": attr.label(
            allow_single_file = ["settings.gradle"],
            mandatory = True,
            doc = "The host project's settings.gradle, in its root directory. The lock of the offline repository is `gradle_repository.json` beside it.",
        ),
        "variants": attr.string_list(
            mandatory = True,
            doc = "The host's build variants the build assembles, one per Flutter build mode of `module_repositories`.",
        ),
        "_java_runtime": attr.label(
            default = "@bazel_tools//tools/jdk:current_java_runtime",
            providers = [java_common.JavaRuntimeInfo],
        ),
    },
    doc = "Writes the runfiles paths a Gradle build of the host app runs with.",
)

# The Gradle distribution an e2e workspace pins (its MODULE.bazel): the version
# and plugin `flutter create` writes.
_GRADLE_VERSION = "9.3.1"

def gradle_host_config(
        name,
        android_ndk = "@androidndk//:all_files",
        android_ndk_root = "@androidndk//:ndk_root",
        android_sdk = "@androidsdk//:files",
        android_sdk_root = "@androidsdk//:sdk_root",
        gradle = "@gradle//:distribution",
        gradle_agent = "@gradle//:lib/agents/gradle-instrumentation-agent-%s.jar" % _GRADLE_VERSION,
        gradle_launcher = "@gradle//:lib/gradle-gradle-cli-main-%s.jar" % _GRADLE_VERSION,
        **kwargs):
    """Writes the runfiles paths a Gradle build of a host app runs with.

    The labels are those of the workspace that calls it.

    Args:
        name: The target's name.
        android_ndk: The NDK's files.
        android_ndk_root: A file whose physical parent is the NDK.
        android_sdk: The Android SDK's files.
        android_sdk_root: A file whose physical parent is the Android SDK.
        gradle: The Gradle distribution's files.
        gradle_agent: The distribution's instrumentation agent jar.
        gradle_launcher: The distribution's launcher jar.
        **kwargs: The other attributes of the rule.
    """
    _gradle_host_config(
        name = name,
        android_ndk = android_ndk,
        android_ndk_root = android_ndk_root,
        android_sdk = android_sdk,
        android_sdk_root = android_sdk_root,
        gradle = gradle,
        gradle_agent = gradle_agent,
        gradle_launcher = gradle_launcher,
        **kwargs
    )
