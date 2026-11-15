"""An application's AOT compile records the uses of `@RecordUse` only for a reader.

Two things read them: the packages' link hooks, and icon tree shaking, which
reads the `IconData` uses. A profile or release build that shakes icons
records them and the asset bundle reads them; one that neither shakes icons
nor runs a link hook asks the compiler for nothing it would throw away.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load(":action_content.bzl", "action_config")

_MAIN = "lib/language_version_main.dart"
_RELEASE = {"//command_line_option:compilation_mode": "opt"}
_FLAG = "--recorded-uses"

def _records(argv):
    return [a for a in argv if a.startswith(_FLAG)]

def _kernel_argv(env):
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernels), "expected one DartKernel")
    return kernels[0].argv if kernels else []

def _shaken_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.true(env, _records(_kernel_argv(env)), "the compile records no uses")
    bundle = action_config(env, "FlutterAssetBundle")
    asserts.true(
        env,
        bundle != None and len(bundle.get("icon_tree_shaking", {}).get("recorded_uses", [])) == 1,
        "the bundle does not shake icons over the compile's uses: %s" % bundle,
    )
    return analysistest.end(env)

def _unshaken_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.false(env, _records(_kernel_argv(env)), "the compile records uses nothing reads")
    bundle = action_config(env, "FlutterAssetBundle")
    asserts.true(env, bundle != None and "icon_tree_shaking" not in bundle, "the bundle shakes icons: %s" % bundle)
    return analysistest.end(env)

_shaken_release_test = analysistest.make(_shaken_impl, config_settings = _RELEASE)
_unshaken_release_test = analysistest.make(_unshaken_impl, config_settings = _RELEASE)

def recorded_uses_test_suite(name):
    """Fixtures and tests for when an application's compile records uses.

    Args:
        name: The test_suite name.
    """
    flutter_application(
        name = "_recorded_uses_shaken_app",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_application(
        name = "_recorded_uses_unshaken_app",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
        tree_shake_icons = False,
    )
    cases = {
        "release_shaking_icons_records": (_shaken_release_test, "_recorded_uses_shaken_app"),
        "release_not_shaking_icons_does_not": (_unshaken_release_test, "_recorded_uses_unshaken_app"),
    }
    tests = []
    for case, (rule, target) in cases.items():
        test = "%s_%s" % (name, case)
        rule(name = test, target_under_test = ":" + target)
        tests.append(":" + test)
    native.test_suite(name = name, tests = tests)
