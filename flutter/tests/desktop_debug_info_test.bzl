"""Tests that a Linux or Windows bundle holds its snapshot's `.symbols` in `debug_info`.

An obfuscated app's stack traces read back only through the `.symbols` of the
snapshot it ships. The bundle builds its application in its own
configuration, so the file must be that configuration's: the one the bundle
directory is in.

A release desktop snapshot is compiled only on its own OS (gen_snapshot makes
code for the host alone), so each test runs on the OS of its bundle, for the
host's platform. Over `//flutter/tests/desktop_debug_info_fixture`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_FIXTURE = "//flutter/tests/desktop_debug_info_fixture:"

def _impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    groups = target[OutputGroupInfo]
    symbols = groups.debug_info.to_list() if "debug_info" in groups else []
    asserts.equals(env, 1, len(symbols), "one `.symbols` in `debug_info`: %s" % symbols)
    if len(symbols) == 1:
        name = symbols[0].basename
        asserts.true(
            env,
            name.startswith("app.%s-" % ctx.attr.platform) and name.endswith(".symbols"),
            "named as `flutter build` names it, app.%s-<arch>.symbols: %s" % (ctx.attr.platform, name),
        )
        bundle = target[DefaultInfo].files.to_list()
        asserts.equals(
            env,
            [f.root.path for f in bundle],
            [symbols[0].root.path],
            "the `.symbols` should be the one of the snapshot the bundle ships, in the bundle's configuration",
        )
    return analysistest.end(env)

_desktop_debug_info_test = analysistest.make(
    _impl,
    attrs = {"platform": attr.string(mandatory = True)},
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        str(Label("//flutter:obfuscate")): True,
        str(Label("@rules_dart//dart:split_debug_info")): True,
    },
)

def desktop_debug_info_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """
    _desktop_debug_info_test(
        name = name + "_linux",
        target_under_test = _FIXTURE + "linux_bundle",
        platform = "linux",
        target_compatible_with = ["@platforms//os:linux"],
    )
    _desktop_debug_info_test(
        name = name + "_windows",
        target_under_test = _FIXTURE + "windows_bundle",
        platform = "windows",
        target_compatible_with = ["@platforms//os:windows"],
    )
    native.test_suite(name = name, tests = [name + "_linux", name + "_windows"])
