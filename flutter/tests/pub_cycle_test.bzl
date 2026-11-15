"""Analysis tests: each plugin of a pub dependency cycle depends on its own package's dependencies.

Over `//flutter/tests/pub_cycle_fixture`: `cycle_a` and `cycle_b`, plugins of
one cycle built as one `flutter_pub_library`, and `outside`, a plugin only
`cycle_b` depends on. flutter_tools orders each plugin after those of its own
pubspec's dependencies, so `cycle_a` depends on `cycle_b` and not on
`outside`, which the cycle as a whole depends on.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterInfo")

def _dependencies_impl(ctx):
    env = analysistest.begin(ctx)
    plugins = {p.name: p.dependencies for p in analysistest.target_under_test(env)[FlutterInfo].plugins}
    asserts.equals(env, ["cycle_b"], plugins["cycle_a"], "cycle_a's dependencies")
    asserts.equals(env, ["cycle_a", "outside"], plugins["cycle_b"], "cycle_b's dependencies")
    asserts.equals(env, [], plugins["outside"], "outside's dependencies")
    return analysistest.end(env)

_dependencies_test = analysistest.make(_dependencies_impl)

def pub_cycle_test_suite(name):
    """Analysis tests of the plugins of a pub dependency cycle.

    Args:
        name: Name of the resulting test_suite.
    """
    _dependencies_test(
        name = name + "_dependencies",
        target_under_test = "//flutter/tests/pub_cycle_fixture:cycle",
    )
    native.test_suite(name = name, tests = [":" + name + "_dependencies"])
