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

# The stock release: the SDK a build uses when neither `flutter.use_sdk` nor
# `--@rules_flutter//flutter:sdk` chooses another.
DEFAULT_SDK = "flutter"

_SDK_FLAG = "@rules_flutter//flutter:sdk"

def sdk_repo_name(sdk):
    """The repository holding the toolchain implementations of an SDK."""
    return sdk + "_sdk"

def sdk_setting(sdk):
    """The name of the setting in the registry that matches when the build uses an SDK."""
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

def _sdk_settings(sdk, default_sdk):
    """The setting `sdk_<sdk>`: the flag names the SDK or, for the root module's choice, is unset."""
    content = """
config_setting(
    name = "flag_is_{sdk}",
    flag_values = {{"{flag}": "{sdk}"}},
)
""".format(flag = _SDK_FLAG, sdk = sdk)
    if sdk != default_sdk:
        return content + """
alias(
    name = "{setting}",
    actual = ":flag_is_{sdk}",
    visibility = ["//visibility:public"],
)
""".format(setting = sdk_setting(sdk), sdk = sdk)
    return content + """
selects.config_setting_group(
    name = "{setting}",
    match_any = [
        ":flag_is_{sdk}",
        ":flag_unset",
    ],
    visibility = ["//visibility:public"],
)
""".format(setting = sdk_setting(sdk), sdk = sdk)

def _undeclared_sdk(sdks):
    """Toolchains for a flag naming no declared SDK, which fail listing those that are, not "no matching toolchains"."""
    content = """
alias(
    name = "uses_undeclared_sdk",
    actual = select({{
        ":flag_unset": "@rules_flutter//flutter/private:never",
{declared}        "//conditions:default": "@rules_flutter//flutter/private:always",
    }}),
)

flutter_missing_slice(
    name = "undeclared_sdk",
    message = {message},
    # Analysed only through toolchain resolution: built on its own, it fails.
    tags = ["manual"],
    visibility = ["//visibility:public"],
)
""".format(
        declared = "".join([
            '        ":flag_is_{}": "@rules_flutter//flutter/private:never",\n'.format(sdk)
            for sdk in sdks
        ]),
        message = json.encode(
            "--@rules_flutter//flutter:sdk names no Flutter SDK the root module declares. " +
            "The declared SDKs are: {}.".format(", ".join(sorted(sdks))),
        ),
    )
    for toolchain_type in ["toolchain_type", "exec_tools_toolchain_type"]:
        content += """
toolchain(
    name = "undeclared_sdk_{toolchain_type}",
    target_settings = [":uses_undeclared_sdk"],
    toolchain = ":undeclared_sdk",
    toolchain_type = "@rules_flutter//flutter:{toolchain_type}",
)
""".format(toolchain_type = toolchain_type)
    return content

def _unknown_machine_toolchains(sdk, message):
    """Toolchains of an SDK that serves the machine Bazel runs on, where its engine is not built: they fail, saying why, not "no matching toolchains"."""
    content = """
flutter_missing_slice(
    name = "{sdk}_unknown_machine",
    message = {message},
    # Analysed only through toolchain resolution: built on its own, it fails.
    tags = ["manual"],
    visibility = ["//visibility:public"],
)
""".format(sdk = sdk, message = json.encode(message))
    for toolchain_type in ["toolchain_type", "exec_tools_toolchain_type"]:
        content += """
toolchain(
    name = "{name}",
    exec_compatible_with = HOST_CONSTRAINTS,
    target_settings = [":{setting}"],
    toolchain = ":{sdk}_unknown_machine",
    toolchain_type = "@rules_flutter//flutter:{toolchain_type}",
)
""".format(
            name = toolchain_name(sdk, "unknown_machine_" + toolchain_type),
            setting = sdk_setting(sdk),
            sdk = sdk,
            toolchain_type = toolchain_type,
        )
    return content

def toolchains_build_content(sdks, default_sdk, hosts = {}, unknown_machine = {}):
    """The BUILD file of the registry: every SDK's toolchains, and which SDK the build uses.

    An SDK's toolchains are registered only for the execution platforms it
    can serve. Bazel takes the first execution platform for which every
    toolchain a target needs is registered, and only then analyses the
    toolchains: one registered for a platform the SDK cannot serve would be
    taken, and fail the build, when a later platform would have built it.

    Args:
        sdks: The names of the declared SDKs.
        default_sdk: The SDK a build without `--@rules_flutter//flutter:sdk`
            uses: the one `flutter.use_sdk` chooses, or the release.
        hosts: For each SDK whose engine does not serve every host, the hosts
            it does (`darwin-arm64`): a checkout's out dirs serve the machine
            Bazel runs on alone, where they fail, saying why, when the
            checkout is not set or not built. The machine is the execution
            platform Bazel tries last.
        unknown_machine: For each SDK that serves the machine Bazel runs on
            where that is a machine no engine is built for, the message its
            toolchains there fail with.

    Returns:
        The BUILD.bazel text.
    """
    content = """# Generated by toolchains_repo.bzl
#
# rules_flutter's own MODULE.bazel registers these toolchains. Each applies
# when the build uses its SDK: the one `--@rules_flutter//flutter:sdk` names,
# or without the flag the one the root module chooses, "{default_sdk}".

load("@bazel_skylib//lib:selects.bzl", "selects")
{host_load}load("@rules_flutter//flutter:engine.bzl", "flutter_missing_slice")

config_setting(
    name = "flag_unset",
    flag_values = {{"{flag}": ""}},
)
""".format(
        default_sdk = default_sdk,
        flag = _SDK_FLAG,
        host_load = 'load("@platforms//host:constraints.bzl", "HOST_CONSTRAINTS")\n' if unknown_machine else "",
    )
    for sdk in sdks:
        content += _sdk_settings(sdk, default_sdk)
        if sdk in unknown_machine:
            content += _unknown_machine_toolchains(sdk, unknown_machine[sdk])

        def serves(host):
            return sdk not in hosts or host in hosts[sdk]

        # Native (host == target) toolchains.
        for platform, meta in HOST_PLATFORMS.items():
            if not serves(platform):
                continue
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
            if not serves(platform):
                continue
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
            for target_platform in targets if serves(host_platform) else []:
                content += _toolchain(
                    sdk,
                    "{}_to_{}_toolchain".format(host_platform, target_platform),
                    "@rules_flutter//flutter:toolchain_type",
                    HOST_PLATFORMS[host_platform].compatible_with,
                    TARGET_PLATFORMS[target_platform].compatible_with,
                )

        # Desktop cross-platform toolchains (debug bundles only: no desktop gen_snapshot cross-compiles AOT).
        for host_platform, targets in DESKTOP_CROSS_PAIRS.items():
            for target_platform in targets if serves(host_platform) else []:
                content += _toolchain(
                    sdk,
                    "{}_to_{}_desktop_toolchain".format(host_platform, target_platform),
                    "@rules_flutter//flutter:toolchain_type",
                    HOST_PLATFORMS[host_platform].compatible_with,
                    HOST_PLATFORMS[target_platform].compatible_with,
                )

    content += _undeclared_sdk(sdks)

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
    repository_ctx.file("BUILD.bazel", toolchains_build_content(
        repository_ctx.attr.sdks,
        repository_ctx.attr.default_sdk,
        repository_ctx.attr.hosts,
        repository_ctx.attr.unknown_machine,
    ))

flutter_toolchains_repo = repository_rule(
    _flutter_toolchains_repo_impl,
    doc = """Creates a repository with toolchain definitions for all known platforms
     which can be registered or selected, for each declared SDK.""",
    attrs = {
        "sdks": attr.string_list(doc = "The names of the declared SDKs.", mandatory = True),
        "default_sdk": attr.string(doc = "The SDK a build without `--@rules_flutter//flutter:sdk` uses.", mandatory = True),
        "hosts": attr.string_list_dict(doc = "For each SDK whose engine does not serve every host, the hosts it does."),
        "unknown_machine": attr.string_dict(doc = "For each SDK that serves the machine Bazel runs on, where no engine is built for it, why its toolchains fail there."),
    },
)
