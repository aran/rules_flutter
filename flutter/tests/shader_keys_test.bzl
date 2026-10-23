"""Analysis tests for package-relative own-shader keys (`shaders`).

An app, test, or bundle target's own `shaders` are keyed exactly like its
`assets`: relative to the listing target's package directory, which is where
`FragmentProgram.fromAsset` looks for them. A file in a nested Bazel package
below the listing directory keeps its path below that directory; a file
anywhere else fails analysis rather than guessing a key. The SDK
(`shaders/<basename>`) and package (`packages/<pkg>/<path>`) shader keys are
untouched and stay covered by `shader_compile_test`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:asset_keys.bzl", "is_within_package", "relative_key")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load(":action_content.bzl", "written_json")

_FIXTURE = "//flutter/tests/shader_keys_fixture"

def _root_key_is_short_path_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "shaders/app.frag", relative_key("", "", "shaders/app.frag"))
    asserts.true(env, is_within_package("", "", "shaders/app.frag"))
    asserts.false(env, is_within_package("", "", "../other_repo/shaders/app.frag"))
    return unittest.end(env)

def _subpackage_key_strips_package_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "shaders/app.frag",
        relative_key(
            "",
            "flutter/tests/shader_keys_fixture",
            "flutter/tests/shader_keys_fixture/shaders/app.frag",
        ),
    )
    asserts.false(
        env,
        is_within_package(
            "",
            "flutter/tests/shader_keys_fixture",
            "flutter/tests/shader_keys_sibling/shaders/elsewhere.frag",
        ),
    )
    return unittest.end(env)

_root_key_test = unittest.make(_root_key_is_short_path_test_impl)
_subpackage_key_test = unittest.make(_subpackage_key_strips_package_test_impl)

def _subpackage_bundle_key_test_impl(ctx):
    env = analysistest.begin(ctx)
    config = written_json(env, ".asset_bundle_config.json")
    if config != None:
        asserts.true(
            env,
            "shaders/app.frag" in config["copies"],
            "the subpackage app's own shader must bundle at its package-relative key: %s" % sorted(config["copies"].keys()),
        )
        asserts.false(
            env,
            "flutter/tests/shader_keys_fixture/shaders/app.frag" in config["copies"],
            "the workspace-relative path must not survive as a bundle key",
        )
    return analysistest.end(env)

def _outside_shaders_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        "shader flutter/tests/shader_keys_sibling/shaders/elsewhere.frag is outside the target's package",
    )
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

_subpackage_bundle_key_test = analysistest.make(_subpackage_bundle_key_test_impl, config_settings = _DBG)
_outside_shaders_fails_test = analysistest.make(
    _outside_shaders_fails_test_impl,
    expect_failure = True,
)

def shader_keys_test_suite(name):
    """Defines the own-shader-key unit and analysis tests.

    Args:
        name: Name of the resulting test_suite.
    """
    unittest.suite(
        name + "_keys_pure",
        _root_key_test,
        _subpackage_key_test,
    )
    _subpackage_bundle_key_test(
        name = name + "_subpackage_bundle_key",
        target_under_test = _FIXTURE + ":app",
    )
    _outside_shaders_fails_test(
        name = name + "_outside_shaders_fails",
        target_under_test = _FIXTURE + ":outside_shaders",
    )

    # A bundle with a shader compiles it for `flutter_tester` through the
    # retry wrapper's exec Dart VM: this build proves the rule declares that
    # toolchain instead of failing analysis.
    build_test(
        name = name + "_bundle_build_test",
        target_compatible_with = HOST_COMPATIBLE,
        targets = [_FIXTURE + ":bundle"],
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_keys_pure",
            ":" + name + "_subpackage_bundle_key",
            ":" + name + "_outside_shaders_fails",
            ":" + name + "_bundle_build_test",
        ],
    )
