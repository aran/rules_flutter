"""Create a repository to hold the toolchains.

This follows guidance here:
https://docs.bazel.build/versions/main/skylark/deploying.html#registering-toolchains
"
Note that in order to resolve toolchains in the analysis phase
Bazel needs to analyze all toolchain targets that are registered.
Bazel will not need to analyze all targets referenced by toolchain.toolchain attribute.
If in order to register toolchains you need to perform complex computation in the repository,
consider splitting the repository with toolchain targets
from the repository with <LANG>_toolchain targets.
"
The "complex computation" in our case is downloading large engine artifacts.
This guidance tells us how to avoid that: we put the toolchain targets in the alias repository
with only the toolchain attribute pointing into the platform-specific repositories.
"""

visibility("//flutter/...")

# Host platforms on which Flutter builds can run.
# Keys are platform strings used in Flutter artifact URLs.
HOST_PLATFORMS = {
    "darwin-arm64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
        os = "macos",
        arch = "arm64",
    ),
    "darwin-x64": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
        os = "macos",
        arch = "x64",
    ),
    "linux-x64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
        os = "linux",
        arch = "x64",
    ),
    "linux-arm64": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
        os = "linux",
        arch = "arm64",
    ),
    "windows-x64": struct(
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
        os = "windows",
        arch = "x64",
    ),
}

# Cross-compilation target platforms.
# For each (host, target) pair, a toolchain is registered that runs on the
# host and produces output for the target.
TARGET_PLATFORMS = {
    "android-arm": struct(
        compatible_with = [
            "@platforms//os:android",
            "@platforms//cpu:armv7",
        ],
    ),
    "android-arm64": struct(
        compatible_with = [
            "@platforms//os:android",
            "@platforms//cpu:aarch64",
        ],
    ),
    "android-x64": struct(
        compatible_with = [
            "@platforms//os:android",
            "@platforms//cpu:x86_64",
        ],
    ),
    "ios-arm64": struct(
        compatible_with = [
            "@platforms//os:ios",
            "@platforms//cpu:aarch64",
        ],
    ),
}

# Desktop cross-platform pairs: host → list of desktop targets.
# Desktop targets ARE host platforms (they use HOST_PLATFORMS for constraints).
# These only support debug/JIT mode — gen_snapshot cannot cross-compile between
# desktop OSes for AOT.
DESKTOP_CROSS_PAIRS = {
    "darwin-arm64": ["linux-x64", "windows-x64"],
    "darwin-x64": ["linux-x64", "windows-x64"],
    "linux-x64": ["darwin-x64", "windows-x64"],
    "linux-arm64": ["darwin-x64", "windows-x64"],
    "windows-x64": ["darwin-x64", "linux-x64"],
}

# Which (host, target) cross-compilation pairs are supported.
#
# Flutter publishes Android gen_snapshot for x64 hosts only. On Apple Silicon
# the darwin-x64 binary runs under Rosetta, which every Mac that builds Apple
# targets has; a Linux arm64 host has no such guarantee, so it gets no Android
# toolchain, and an Android AOT compile picks another execution platform
# rather than fail on one that cannot run its compiler.
CROSS_COMPILATION_PAIRS = {
    "darwin-arm64": ["android-arm", "android-arm64", "android-x64", "ios-arm64"],
    "darwin-x64": ["android-arm", "android-arm64", "android-x64", "ios-arm64"],
    "linux-x64": ["android-arm", "android-arm64", "android-x64"],
    "windows-x64": ["android-arm", "android-arm64", "android-x64"],
}

# The platforms a desktop engine is published for, as targets: one engine
# repository per platform and mode, whichever host builds for it.
DESKTOP_ENGINE_PLATFORMS = ["darwin-x64", "linux-x64", "linux-arm64", "windows-x64"]

# The SDK a build uses when `--@rules_flutter//flutter:sdk` is not set: the
# stock release.
DEFAULT_SDK = "flutter"

def sdk_repo_name(sdk):
    """The repository holding the toolchain implementations of an SDK."""
    return sdk + "_sdk"

def sdk_setting(sdk):
    """The name of the `config_setting` in the registry that matches an SDK."""
    return "sdk_" + sdk

def toolchain_name(sdk, name):
    """A toolchain's name in the registry: the default SDK's are as they always were."""
    return name if sdk == DEFAULT_SDK else "{}__{}".format(sdk, name)

def _toolchain(sdk, name, toolchain_type, exec_compatible_with = None, target_compatible_with = None, impl = None):
    attrs = ""
    if exec_compatible_with:
        attrs += "    exec_compatible_with = %s,\n" % exec_compatible_with
    if target_compatible_with:
        attrs += "    target_compatible_with = %s,\n" % target_compatible_with
    return """
toolchain(
    name = "{name}",
{attrs}    target_settings = [":{setting}"],
    toolchain = "@{repo}//:{impl}",
    toolchain_type = "{toolchain_type}",
    visibility = ["//visibility:public"],
)
""".format(
        name = toolchain_name(sdk, name),
        attrs = attrs,
        setting = sdk_setting(sdk),
        repo = sdk_repo_name(sdk),
        impl = impl or name,
        toolchain_type = toolchain_type,
    )

def toolchains_build_content(sdks):
    """The BUILD file of the registry: every SDK's toolchains, chosen by `--@rules_flutter//flutter:sdk`.

    Args:
        sdks: The names of the declared SDKs.

    Returns:
        The BUILD.bazel text.
    """
    content = """# Generated by toolchains_repo.bzl
#
# These can be registered via register_toolchains() or passed to --extra_toolchains flag.
# By default all these toolchains are registered by the flutter_register_toolchains macro
# so you don't normally need to interact with these targets.
#
# Each toolchain applies when `--@rules_flutter//flutter:sdk` names its SDK.
"""
    for sdk in sdks:
        content += """
config_setting(
    name = "{setting}",
    flag_values = {{"@rules_flutter//flutter:sdk": "{sdk}"}},
    visibility = ["//visibility:public"],
)
""".format(setting = sdk_setting(sdk), sdk = sdk)

        # Native (host == target) toolchains.
        for platform, meta in HOST_PLATFORMS.items():
            content += _toolchain(
                sdk,
                platform + "_toolchain",
                "@rules_flutter//flutter:toolchain_type",
                meta.compatible_with,
                meta.compatible_with,
            )

        # Host tools, constrained by execution platform alone: what an action needs
        # when its output is the same whatever the target.
        for platform, meta in HOST_PLATFORMS.items():
            content += _toolchain(
                sdk,
                platform + "_exec_tools_toolchain",
                "@rules_flutter//flutter:exec_tools_toolchain_type",
                meta.compatible_with,
            )

        # Where a `flutter_tester_binary` runs: a host of its target's OS and CPU.
        # Only those two constraints, not the whole target platform: an app's
        # platform may carry others (Apple's, say) that no execution platform has.
        for platform, meta in HOST_PLATFORMS.items():
            content += """
toolchain(
    name = "{name}",
    exec_compatible_with = {compatible_with},
    target_compatible_with = {compatible_with},
    target_settings = [":{setting}"],
    toolchain = "@bazel_tools//tools/test:empty_toolchain",
    toolchain_type = "@rules_flutter//flutter:run_host_toolchain_type",
    visibility = ["//visibility:public"],
)
""".format(
                name = toolchain_name(sdk, platform + "_run_host_toolchain"),
                compatible_with = meta.compatible_with,
                setting = sdk_setting(sdk),
            )

        # Cross-compilation toolchains.
        for host_platform, targets in CROSS_COMPILATION_PAIRS.items():
            for target_platform in targets:
                content += _toolchain(
                    sdk,
                    "{}_to_{}_toolchain".format(host_platform, target_platform),
                    "@rules_flutter//flutter:toolchain_type",
                    HOST_PLATFORMS[host_platform].compatible_with,
                    TARGET_PLATFORMS[target_platform].compatible_with,
                )

        # Desktop cross-platform toolchains (debug bundles only: no desktop gen_snapshot cross-compiles AOT).
        for host_platform, targets in DESKTOP_CROSS_PAIRS.items():
            for target_platform in targets:
                content += _toolchain(
                    sdk,
                    "{}_to_{}_desktop_toolchain".format(host_platform, target_platform),
                    "@rules_flutter//flutter:toolchain_type",
                    HOST_PLATFORMS[host_platform].compatible_with,
                    HOST_PLATFORMS[target_platform].compatible_with,
                )

    # An x86_64 iOS simulator, which an Intel Mac runs: no SDK builds for it,
    # and this toolchain fails the build saying so rather than leave it to
    # "no matching toolchains".
    content += """
toolchain(
    name = "ios_x86_64_unsupported_toolchain",
    target_compatible_with = {compatible_with},
    toolchain = "@rules_flutter//flutter/private:ios_x86_64_unsupported",
    toolchain_type = "@rules_flutter//flutter:toolchain_type",
    visibility = ["//visibility:public"],
)
""".format(compatible_with = ["@platforms//os:ios", "@platforms//cpu:x86_64"])
    return content

def _flutter_toolchains_repo_impl(repository_ctx):
    repository_ctx.file("BUILD.bazel", toolchains_build_content(repository_ctx.attr.sdks))

flutter_toolchains_repo = repository_rule(
    _flutter_toolchains_repo_impl,
    doc = """Creates a repository with toolchain definitions for all known platforms
     which can be registered or selected, for each declared SDK.""",
    attrs = {
        "sdks": attr.string_list(doc = "The names of the declared SDKs."),
    },
)
