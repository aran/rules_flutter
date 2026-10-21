"""An app's Dart defines reach its kernel compile whole, commas included.

`flutter_test` cannot take a comma in a define's value (its dependencies are
compiled by kernel_worker, which splits every `-D` on commas), so hello_world's
end-to-end define test no longer uses one. Applications are still compiled by
frontend_server, which does not split, and this pins that.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_application.bzl", "flutter_application")

def _comma_test_impl(ctx):
    env = analysistest.begin(ctx)
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterKernelCompile"
    ]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    argv = kernels[0].argv if kernels else []
    asserts.true(env, "-DATTR_COMMA=a,b" in argv, "the attr define reaches the compile whole")
    asserts.true(env, "-DFLAG_COMMA=c,d" in argv, "the flag define reaches the compile whole")
    return analysistest.end(env)

_comma_test = analysistest.make(
    _comma_test_impl,
    config_settings = {
        str(Label("//flutter:extra_dart_defines")): ["FLAG_COMMA=c,d"],
    },
)

def app_defines_test_suite(name):
    """Fixture and test for comma-valued defines in an application.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_defines_comma_app",
        package_name = "defines_fixture",
        defines = ["ATTR_COMMA=a,b"],
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    _comma_test(
        name = name,
        target_under_test = ":_defines_comma_app",
    )
