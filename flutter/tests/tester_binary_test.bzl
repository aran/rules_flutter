"""Analysis tests for `flutter_tester_binary`'s host resolution."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _resolves_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, "tester_binary", target[DefaultInfo].files_to_run.executable.basename)
    return analysistest.end(env)

# An app's Mac platform: macOS on arm64 plus a constraint no execution platform
# has. The binary still finds a host to run on, of the same OS and CPU.
_resolves_on_app_platform_test = analysistest.make(
    _resolves_impl,
    config_settings = {
        "//command_line_option:platforms": str(Label("//flutter/tests/tester_binary_fixture:app_mac")),
    },
)

def tester_binary_test_suite(name):
    _resolves_on_app_platform_test(
        name = name + "_resolves_on_app_platform",
        target_under_test = "//flutter/tests/tester_binary_fixture:tester_binary",
        # Analysed from a Mac, the host such a platform runs it on.
        target_compatible_with = ["@platforms//os:macos"],
    )
    native.test_suite(name = name, tests = [name + "_resolves_on_app_platform"])
