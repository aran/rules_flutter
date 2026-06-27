"""Analysis-time validation tests for the Native Assets rules.

These tests specify the documented contract of `flutter_native_asset` /
`flutter_data_asset`: invalid configurations must fail at analysis time,
not silently produce something that breaks at runtime.

Each test uses `analysistest.make(expect_failure = True)` and pairs the
target under test with an `asserts.expect_failure(env, "<substring>")`
check against the produced error message — so we both assert the rule
fails *and* assert the failure message points the user at the right
fix.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:native_assets.bzl", "flutter_data_asset", "flutter_native_asset")
load("//flutter/private:flutter_native_assets.bzl", "native_asset_framework_name", "native_assets_target_string")

# -- Pure-function tests for the manifest helpers ----------------------

def _target_string_macos_arm64_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "macos_arm64", native_assets_target_string("macos", "arm64"))
    asserts.equals(env, "ios_arm64", native_assets_target_string("ios", "arm64"))
    asserts.equals(env, "linux_x64", native_assets_target_string("linux", "x64"))
    asserts.equals(env, "android_arm64", native_assets_target_string("android", "arm64"))
    return unittest.end(env)

def _target_string_unknown_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", native_assets_target_string("", ""))
    asserts.equals(env, "", native_assets_target_string("macos", ""))
    asserts.equals(env, "", native_assets_target_string("plan9", "arm64"))
    return unittest.end(env)

def _framework_name_impl(ctx):
    env = unittest.begin(ctx)

    # Strips the `.dylib` extension; sanitizes nothing it doesn't need to.
    asserts.equals(env, "objective_c", native_asset_framework_name("objective_c.dylib"))

    # Strips a leading `lib` only when it's a dylib (matches frameworkUri).
    asserts.equals(env, "sqlite3", native_asset_framework_name("libsqlite3.dylib"))

    # Sanitizes characters outside [A-Za-z0-9_-].
    asserts.equals(env, "my-lib_2", native_asset_framework_name("my-lib_2.dylib"))
    asserts.equals(env, "foobar", native_asset_framework_name("foo.bar.dylib"))

    # A `lib` prefix is kept when there is no `.dylib` extension to strip.
    asserts.equals(env, "libfoo", native_asset_framework_name("libfoo"))
    return unittest.end(env)

_target_string_t0_test = unittest.make(_target_string_macos_arm64_impl)
_target_string_t1_test = unittest.make(_target_string_unknown_impl)
_framework_name_test = unittest.make(_framework_name_impl)

# -- Analysis-time failure tests ---------------------------------------

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_substring)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_substring": attr.string(mandatory = True),
    },
)

def _setup_failure_targets():
    """Declare the rule instances whose analysis-time errors we test.

    Wrapped in a function called from the test suite macro so each
    invocation only emits the targets once. `tags = ["manual"]` keeps
    them out of `bazel test //...` glob expansion — they're only built
    by the analysistests that wrap them.
    """
    flutter_native_asset(
        name = "_static_link_mode",
        asset_id = "package:foo/foo.dylib",
        link_mode = "static",
        target_os = "macos",
        tags = ["manual"],
    )

    flutter_native_asset(
        name = "_bundle_missing_library",
        asset_id = "package:foo/foo.dylib",
        link_mode = "dynamic_loading_bundle",
        target_os = "macos",
        bundle_filename = "foo.dylib",
        tags = ["manual"],
    )

    flutter_native_asset(
        name = "_system_missing_uri",
        asset_id = "package:foo/foo.dylib",
        link_mode = "dynamic_loading_system",
        target_os = "linux",
        tags = ["manual"],
    )

    flutter_data_asset(
        name = "_data_bad_id",
        asset_id = "not-a-package-id",
        file = "BUILD.bazel",
        tags = ["manual"],
    )

def native_assets_test_suite(name):
    """Defines the analysis tests + pure-function tests for Native Assets.

    Args:
      name: The test_suite target name.
    """
    _setup_failure_targets()

    _expect_failure_test(
        name = name + "_static_fails",
        target_under_test = ":_static_link_mode",
        expected_substring = "link_mode = \"static\"",
    )

    _expect_failure_test(
        name = name + "_bundle_requires_library",
        target_under_test = ":_bundle_missing_library",
        expected_substring = "requires `library = ",
    )

    _expect_failure_test(
        name = name + "_system_requires_uri",
        target_under_test = ":_system_missing_uri",
        expected_substring = "requires `system_uri",
    )

    _expect_failure_test(
        name = name + "_data_asset_id_format",
        target_under_test = ":_data_bad_id",
        expected_substring = "must start with `package:`",
    )

    unittest.suite(
        name + "_pure",
        _target_string_t0_test,
        _target_string_t1_test,
        _framework_name_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_static_fails",
            ":" + name + "_bundle_requires_library",
            ":" + name + "_system_requires_uri",
            ":" + name + "_data_asset_id_format",
            ":" + name + "_pure",
        ],
    )
