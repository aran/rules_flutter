"""Analysis tests: a plugin and an asset reach an application through Dart targets Flutter's rules did not build.

Over `//flutter/tests/forwarding_fixture`: `relayed_plugin`, a plugin, and
`relayed_assets`, a package bundling `assets/relayed.txt`, reached by an
application only through two rules_dart `dart_library` targets, or through a
pure-Dart pub package's `pub_library`; a plugin that is a member of a
`pub_library`; and a `flutter_test` that takes the
first application's `deps` (`application`), or names the library in its own.
None of the targets between builds `FlutterInfo`; the forwarding aspect
(`flutter_info_forwarding.bzl`) carries it across them.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterApplicationInfo")

_APP = "//flutter/tests/forwarding_fixture/app:"
_ASSET = "flutter/tests/forwarding_fixture/assets/assets/relayed.txt"

def _bundled(env):
    return [
        f.short_path
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterAssetBundle"
        for f in a.inputs.to_list()
    ]

def _application_impl(ctx):
    """The application registers the plugin and bundles the asset."""
    env = analysistest.begin(ctx)
    plugins = [p.name for p in analysistest.target_under_test(env)[FlutterApplicationInfo].plugins]
    asserts.true(env, "relayed_plugin" in plugins, "registers relayed_plugin: %s" % plugins)
    bundled = _bundled(env)
    asserts.true(env, _ASSET in bundled, "bundles %s: %s" % (_ASSET, bundled))
    return analysistest.end(env)

_application_test = analysistest.make(_application_impl)

def _test_program_impl(ctx):
    """The test bundles the asset, as `flutter test` bundles every package's."""
    env = analysistest.begin(ctx)
    bundled = _bundled(env)
    asserts.true(env, _ASSET in bundled, "bundles %s: %s" % (_ASSET, bundled))
    return analysistest.end(env)

_test_program_test = analysistest.make(_test_program_impl)

def _member_plugin_impl(ctx):
    """A plugin among a `pub_library`'s members is registered."""
    env = analysistest.begin(ctx)
    plugins = [p.name for p in analysistest.target_under_test(env)[FlutterApplicationInfo].plugins]
    asserts.true(env, "member_plugin" in plugins, "registers member_plugin: %s" % plugins)
    return analysistest.end(env)

_member_plugin_test = analysistest.make(_member_plugin_impl)

def flutter_info_forwarding_test_suite(name):
    """Analysis tests of `FlutterInfo` across Dart targets of other rule sets.

    Args:
        name: Name of the resulting test_suite.
    """
    _application_test(name = name + "_dart_library", target_under_test = _APP + "through_dart_library")
    _application_test(name = name + "_pub_library", target_under_test = _APP + "through_pub_library")
    _test_program_test(name = name + "_test_application", target_under_test = _APP + "in_application_test.program")
    _test_program_test(name = name + "_test_deps", target_under_test = _APP + "own_deps_test.program")
    _member_plugin_test(name = name + "_member_plugin", target_under_test = _APP + "through_member_plugin")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + suffix
            for suffix in ["_dart_library", "_pub_library", "_test_application", "_test_deps", "_member_plugin"]
        ],
    )
