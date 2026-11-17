"""`--@rules_flutter//flutter:agent_extensions` decides whether a debug app has them.

The agent extensions are compiled into a native debug build's program from its
plugin registrant. On by default, since `flutter_bazel` drives the app through
them; off, the program is the app's alone, as for a debug build no dev tool
runs. Release builds never have them, whatever the setting.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_application.bzl", "flutter_application")

_MAIN = "lib/language_version_main.dart"

def _registrant(env):
    writes = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and a.outputs.to_list()[0].basename.endswith("_plugin_registrant.dart")
    ]
    return writes[0].content if writes else ""

def _staged(env):
    return [
        f.basename
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartKernel"
        for f in a.inputs.to_list()
        if f.basename.endswith("agent_extensions.dart")
    ]

def _with_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.true(env, "registerRulesFlutterAgentExtensions();" in _registrant(env), "the registrant registers them")
    asserts.equals(env, 2, len(_staged(env)), "the kernel compiles both agent sources")
    return analysistest.end(env)

def _without_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.false(env, "AgentExtensions" in _registrant(env), "the registrant registers none")
    asserts.equals(env, [], _staged(env), "the kernel compiles no agent source")
    return analysistest.end(env)

_DEBUG = {"//command_line_option:compilation_mode": "dbg"}
_OFF = {str(Label("//flutter:agent_extensions")): False}

_debug_has_them_test = analysistest.make(_with_impl, config_settings = _DEBUG)
_debug_off_test = analysistest.make(_without_impl, config_settings = _DEBUG | _OFF)
# Pinned, so a run under `-c dbg` still tests a release build.
_release_never_test = analysistest.make(_without_impl, config_settings = {"//command_line_option:compilation_mode": "opt"})

def agent_extensions_test_suite(name):
    """A debug app with and without the setting, and a release one.

    Args:
        name: The test_suite name.
    """
    flutter_application(
        name = name + "_app",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )
    tests = []
    for suffix, test in [
        ("debug_has_them", _debug_has_them_test),
        ("debug_off", _debug_off_test),
        ("release_never", _release_never_test),
    ]:
        test(name = "%s_%s" % (name, suffix), target_under_test = ":%s_app" % name)
        tests.append(":%s_%s" % (name, suffix))
    native.test_suite(name = name, tests = tests)
