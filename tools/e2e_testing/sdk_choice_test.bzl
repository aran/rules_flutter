"""Which Flutter SDK a build resolves: `flutter.use_sdk`'s choice, or the one `--@rules_flutter//flutter:sdk` names.

Each test analyses a probe that resolves the Flutter toolchains and checks the
SDK they belong to. The tests differ in the flag alone, since `use_sdk` is the
workspace's MODULE.bazel: a workspace states, with `sdk`, which SDK each
resolves there.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_SDK_FLAG = str(Label("@rules_flutter//flutter:sdk"))

_SdkInfo = provider(
    doc = "The SDKs the probe's Flutter toolchains belong to.",
    fields = {"target": "str", "exec_tools": "str"},
)

def _probe_impl(ctx):
    return [_SdkInfo(
        target = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info.sdk,
        exec_tools = ctx.toolchains["@rules_flutter//flutter:exec_tools_toolchain_type"].flutter_exec_tools_info.sdk,
    )]

flutter_sdk_probe = rule(
    implementation = _probe_impl,
    doc = "Resolves the Flutter toolchains, and returns which SDK they belong to.",
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        "@rules_flutter//flutter:exec_tools_toolchain_type",
    ],
)

def _resolves_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[_SdkInfo]
    asserts.equals(env, ctx.attr.sdk, info.target)
    asserts.equals(env, ctx.attr.sdk, info.exec_tools)
    return analysistest.end(env)

_ATTRS = {"sdk": attr.string(doc = "The SDK the toolchains must belong to.", mandatory = True)}

# The flag unset: the SDK `flutter.use_sdk` chooses, or the release.
flutter_sdk_default_test = analysistest.make(_resolves_impl, attrs = _ATTRS)

# The flag naming the release, whatever `flutter.use_sdk` chooses.
flutter_sdk_flag_release_test = analysistest.make(
    _resolves_impl,
    attrs = _ATTRS,
    config_settings = {_SDK_FLAG: "flutter"},
)

def _undeclared_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "--@rules_flutter//flutter:sdk names no Flutter SDK the root module declares")
    asserts.expect_failure(env, "The declared SDKs are: " + ctx.attr.declared + ".")
    return analysistest.end(env)

# What the flag naming no declared SDK fails with: the message of the toolchain
# it then resolves, `@flutter_toolchains//:undeclared_sdk`, which is the target
# under test. (A failing toolchain fails the analysis test's own build when it
# is reached through a dependent, so the test analyses it directly.)
flutter_sdk_flag_undeclared_test = analysistest.make(
    _undeclared_impl,
    attrs = {"declared": attr.string(doc = "The declared SDKs, as the failure lists them.", mandatory = True)},
    expect_failure = True,
)
