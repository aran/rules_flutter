"""Tests for `flutter_native_library.hot_patch` and the aspect that collects it.

The dev tool reads the manifests out of a launch target it did not write and
that belongs to another rule set, so both halves are pinned here: the wrapper
refuses a `hot_patch` target it could not find one manifest in, and the aspect
finds the manifest however the launch target reaches the wrapper — a list, a
single label, or a label-keyed dict like `macos_application`'s frameworks.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_native_library")
load("//flutter:native_hot_patch.bzl", "HOT_PATCH_OUTPUT_GROUP", "flutter_native_hot_patch_aspect")

def _fake_launch_impl(_ctx):
    return [DefaultInfo()]

# Stands in for a platform launch target: every attribute shape a real one uses
# to reach its bundled libraries.
_fake_launch = rule(
    implementation = _fake_launch_impl,
    attrs = {
        "listed": attr.label_list(),
        "single": attr.label(),
        "keyed": attr.label_keyed_string_dict(),
    },
)

def _collects_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    files = getattr(target[OutputGroupInfo], HOT_PATCH_OUTPUT_GROUP).to_list()
    names = sorted([f.basename for f in files])
    asserts.equals(env, ctx.attr.expected, names)
    return analysistest.end(env)

_collects_test = analysistest.make(
    _collects_impl,
    attrs = {"expected": attr.string_list()},
    extra_target_under_test_aspects = [flutter_native_hot_patch_aspect],
)

def _refuses_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_refuses_test = analysistest.make(
    _refuses_impl,
    attrs = {"message": attr.string()},
    expect_failure = True,
)

def native_hot_patch_test_suite(name):
    """Declares the fixtures and tests.

    Args:
        name: The test_suite name.
    """
    write_file(name = name + "_lib", out = name + "/libfake.so", content = [""])
    write_file(name = name + "_contract", out = name + "/fake.h", content = [""])
    write_file(name = name + "_manifest", out = name + "/fake.hot_patch.json", content = ["{}"])
    write_file(name = name + "_second_manifest", out = name + "/other.hot_patch.json", content = ["{}"])
    write_file(name = name + "_tool", out = name + "/patch_tool", content = [""])

    native.filegroup(
        name = name + "_patcher",
        srcs = [name + "_manifest", name + "_tool"],
    )
    native.filegroup(
        name = name + "_no_manifest",
        srcs = [name + "_tool"],
    )
    native.filegroup(
        name = name + "_two_manifests",
        srcs = [name + "_manifest", name + "_second_manifest"],
    )

    flutter_native_library(
        name = name + "_patchable",
        library = name + "_lib",
        binding_contract = [name + "_contract"],
        hot_patch = name + "_patcher",
    )
    flutter_native_library(
        name = name + "_plain",
        library = name + "_lib",
        binding_contract = [name + "_contract"],
    )
    flutter_native_library(
        name = name + "_missing_manifest",
        library = name + "_lib",
        binding_contract = [name + "_contract"],
        hot_patch = name + "_no_manifest",
        tags = ["manual"],
    )
    flutter_native_library(
        name = name + "_ambiguous_manifest",
        library = name + "_lib",
        binding_contract = [name + "_contract"],
        hot_patch = name + "_two_manifests",
        tags = ["manual"],
    )

    # One hop removed from the launch target, the way a bundle generator sits
    # between an application rule and its native_deps.
    native.filegroup(name = name + "_between", srcs = [name + "_patchable"])

    _fake_launch(name = name + "_via_list", listed = [name + "_between"], tags = ["manual"])
    _fake_launch(name = name + "_via_label", single = name + "_patchable", tags = ["manual"])
    _fake_launch(name = name + "_via_dict", keyed = {name + "_between": "Frameworks"}, tags = ["manual"])
    _fake_launch(name = name + "_unpatched", listed = [name + "_plain"], tags = ["manual"])

    tests = []
    for via in ["via_list", "via_label", "via_dict"]:
        _collects_test(
            name = name + "_collects_" + via,
            target_under_test = name + "_" + via,
            expected = ["fake.hot_patch.json", "patch_tool"],
        )
        tests.append(name + "_collects_" + via)
    _collects_test(
        name = name + "_collects_nothing_without_hot_patch",
        target_under_test = name + "_unpatched",
        expected = [],
    )
    _refuses_test(
        name = name + "_refuses_missing_manifest",
        target_under_test = name + "_missing_manifest",
        message = "produces 0 `*.hot_patch.json` files",
    )
    _refuses_test(
        name = name + "_refuses_two_manifests",
        target_under_test = name + "_ambiguous_manifest",
        message = "produces 2 `*.hot_patch.json` files",
    )
    tests += [
        name + "_collects_nothing_without_hot_patch",
        name + "_refuses_missing_manifest",
        name + "_refuses_two_manifests",
    ]
    native.test_suite(name = name, tests = tests)
