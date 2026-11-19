"""Tests for the aspect that finds what a `native_deps` library was linked from.

An Apple app's dSYM of a bundled library is read from what it was linked from,
or is the dSYM its link made (`native_link_aspect.bzl`). These check what the
aspect finds on real targets: a C++ link, the wrappers it is followed through,
a genrule it is not, and the `Rustc` action of a Rust library.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:native_link_aspect.bzl", "NativeLinkInfo", "native_link_aspect")

_FIXTURE = "//flutter/tests/native_sources_fixture:"

def _archives(info):
    return sorted([f.basename for f in info.link_inputs.to_list() if f.extension in ("o", "a")])

def _link_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[NativeLinkInfo]
    if ctx.attr.reason:
        asserts.equals(env, None, info.link_inputs, "an unknown link has no inputs")
        asserts.equals(env, None, info.dsym, "an unknown link has no dSYM")
        asserts.true(
            env,
            info.link_inputs_unset_reason != None and ctx.attr.reason in info.link_inputs_unset_reason,
            "the reason names %r: %r" % (ctx.attr.reason, info.link_inputs_unset_reason),
        )
    elif ctx.attr.dsym:
        asserts.equals(env, None, info.link_inputs, "a library with its link's dSYM is not read again")
        asserts.equals(env, ctx.attr.dsym, info.dsym.basename if info.dsym else None)
        asserts.equals(env, None, info.link_inputs_unset_reason)
    else:
        asserts.equals(env, None, info.link_inputs_unset_reason)
        asserts.equals(env, None, info.dsym)
        asserts.equals(env, ctx.attr.archives, _archives(info))
    return analysistest.end(env)

_link_test = analysistest.make(
    _link_impl,
    attrs = {
        "archives": attr.string_list(doc = "The object files and static archives among the inputs of the link found."),
        "dsym": attr.string(doc = "The basename of the dSYM the link made."),
        "reason": attr.string(doc = "A part of the reason the link is unknown."),
    },
    extra_target_under_test_aspects = [native_link_aspect],
)

def native_link_test_suite(name):
    """Declares the tests over `//flutter/tests/native_sources_fixture`.

    Args:
        name: The test_suite name.
    """

    # The `CppLink` of a `cc_shared_library` reads the archives of the
    # libraries below it.
    archives = ["libbridge_cc.a", "libhelper.a"]
    tests = {
        "cc_link": dict(target = "bridge", archives = archives),
        "through_a_copy": dict(target = "vendored_bridge", archives = archives),
        "through_a_filegroup_and_a_copy": dict(target = "bridge_files", archives = archives),
        "through_a_dart_code_asset": dict(target = "bridge_code_asset", archives = archives),
        "not_through_a_genrule": dict(target = "renamed_bridge", reason = "with a `Genrule` action"),
        # rustc deletes the objects it links in its action; its dSYM is the
        # library's.
        "rust_with_its_dsym": dict(target = "rust_bridge", dsym = "librust_bridge.dylib.dSYM"),
        # Nothing holds the line tables: the dSYM is the symbol table's.
        "rust_without_a_dsym": dict(target = "rust_bridge_without_dsym", archives = []),
        # As a code asset, whose objects rules_dart says are gone; macOS only,
        # as the fixture is.
        "rust_code_asset_without_a_dsym": dict(
            target = "rust_bridge_code_asset",
            archives = [],
            target_compatible_with = ["@platforms//os:macos"],
        ),
    }
    for test, kwargs in tests.items():
        _link_test(
            name = "%s_%s" % (name, test),
            target_under_test = _FIXTURE + kwargs.pop("target"),
            **kwargs
        )
    native.test_suite(name = name, tests = ["%s_%s" % (name, test) for test in tests])
