"""A build for a target rules_flutter does not support fails saying why.

An x86_64 iOS simulator, which an Intel Mac runs, has no Flutter toolchain. The
registry registers a toolchain for it whose analysis fails with rules_flutter's
message, so a build stops on that rather than on Bazel's "No matching toolchains
found". (An analysis test cannot observe the failure through a dependent: a
failing dependency fails the test's own build. So the two halves are checked
apart.)
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:toolchains_repo.bzl", "toolchains_build_content")

def _registered_impl(ctx):
    env = unittest.begin(ctx)
    content = toolchains_build_content(["flutter"], "flutter")
    at = content.find('name = "ios_x86_64_unsupported_toolchain"')
    asserts.true(env, at >= 0, content)
    toolchain = content[at:content.find(")", at)]
    asserts.true(env, '"@platforms//os:ios", "@platforms//cpu:x86_64"' in toolchain, toolchain)
    asserts.true(env, 'toolchain = "@rules_flutter//flutter/private:ios_x86_64_unsupported"' in toolchain, toolchain)
    asserts.true(env, 'toolchain_type = "@rules_flutter//flutter/toolchains:toolchain_type"' in toolchain, toolchain)
    return unittest.end(env)

_registered_test = unittest.make(_registered_impl)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "rules_flutter supports Apple Silicon hosts only")
    return analysistest.end(env)

_fails_test = analysistest.make(_fails_impl, expect_failure = True)

def unsupported_target_test_suite(name):
    """The tests.

    Args:
        name: Suite name.
    """
    _registered_test(name = name + "_ios_x86_64_registered")
    _fails_test(
        name = name + "_ios_x86_64_fails",
        target_under_test = "//flutter/private:ios_x86_64_unsupported",
    )
    native.test_suite(name = name, tests = [
        name + "_ios_x86_64_registered",
        name + "_ios_x86_64_fails",
    ])
