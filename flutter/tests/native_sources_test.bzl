"""Tests for the aspect that collects a native library's first-party sources.

What a hot reload stats to notice that an app's native code is behind its
sources — see `native_sources.bzl`. Two things decide whether that works: it has
to reach the sources through a library's own dependencies, and it has to leave
out everything that cannot be edited between reloads, or the reload pays for
stats that can never change.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:native_sources.bzl", "NativeSourcesInfo", "native_sources_aspect")

def _collects_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        ctx.attr.expected,
        sorted([f.basename for f in target[NativeSourcesInfo].sources.to_list()]),
    )
    return analysistest.end(env)

_collects_test = analysistest.make(
    _collects_impl,
    attrs = {"expected": attr.string_list()},
    extra_target_under_test_aspects = [native_sources_aspect],
)

def native_sources_test_suite(name):
    """Declares the tests over `//flutter/tests/native_sources_fixture`.

    Args:
        name: The test_suite name.
    """
    _collects_test(
        name = name + "_through_the_library_graph",
        target_under_test = "//flutter/tests/native_sources_fixture:bridge",
        # `helper.c` proves the walk reaches a dependency of the library, and
        # the absence of `generated.c` that a build output is left out.
        expected = ["bridge.c", "bridge.h", "helper.c"],
    )

    native.test_suite(name = name, tests = [name + "_through_the_library_graph"])
