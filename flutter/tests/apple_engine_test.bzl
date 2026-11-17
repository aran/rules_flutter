"""The Apple engine targets follow the build mode.

`@flutter_macos_engine//:engine_library` and `@flutter_ios_engine//:Flutter_xcframework`
are the engine of the build mode, not the release engine. A plugin compiled
against the macOS one must agree with the application: the application bundles
that mode's FlutterMacOS.framework, and a plugin importing another mode's copy
puts two frameworks of one name into the bundle, which rules_apple cannot
assemble.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_apple//apple:providers.bzl", "AppleFrameworkImportInfo")
load("//flutter/private:flutter_apple_plugin_library.bzl", "flutter_apple_plugin_library")
load(":engine_mode.bzl", "MODE_FLAGS", "engine_modes")

def _target_modes_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.equals(env, [ctx.attr.mode], engine_modes(files, ctx.attr.marker))
    return analysistest.end(env)

def _plugin_import_modes_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[AppleFrameworkImportInfo].framework_imports.to_list()
    asserts.equals(env, [ctx.attr.mode], engine_modes(files, "/FlutterMacOS.framework/"))
    return analysistest.end(env)

_ATTRS = {"mode": attr.string(), "marker": attr.string()}

# Rules must be globals to be exported, so each mode's is named.
_target_debug_test = analysistest.make(_target_modes_impl, attrs = _ATTRS, config_settings = MODE_FLAGS["debug"])
_target_profile_test = analysistest.make(_target_modes_impl, attrs = _ATTRS, config_settings = MODE_FLAGS["profile"])
_target_release_test = analysistest.make(_target_modes_impl, attrs = _ATTRS, config_settings = MODE_FLAGS["release"])
_plugin_debug_test = analysistest.make(_plugin_import_modes_impl, attrs = _ATTRS, config_settings = MODE_FLAGS["debug"])
_plugin_profile_test = analysistest.make(_plugin_import_modes_impl, attrs = _ATTRS, config_settings = MODE_FLAGS["profile"])
_plugin_release_test = analysistest.make(_plugin_import_modes_impl, attrs = _ATTRS, config_settings = MODE_FLAGS["release"])

_TARGET_TESTS = {"debug": _target_debug_test, "profile": _target_profile_test, "release": _target_release_test}
_PLUGIN_TESTS = {"debug": _plugin_debug_test, "profile": _plugin_profile_test, "release": _plugin_release_test}

def apple_engine_test_suite(name):
    """The engine targets, and a macOS plugin's engine import, follow the build mode.

    Args:
        name: Suite name.
    """
    flutter_apple_plugin_library(
        name = name + "_plugin",
        srcs = ["apple_engine_probe.swift"],
        platform = "macos",
    )
    cases = [
        ("macos_engine", "@flutter_macos_engine//:engine_library", "/FlutterMacOS.framework/"),
        ("ios_engine", "@flutter_ios_engine//:Flutter_xcframework", "/Flutter.xcframework/"),
    ]
    tests = []
    for mode in MODE_FLAGS:
        for case, target, marker in cases:
            test = "%s_%s_%s" % (name, case, mode)
            _TARGET_TESTS[mode](
                name = test,
                target_under_test = target,
                mode = mode,
                marker = marker,
                target_compatible_with = ["@platforms//os:macos"],
            )
            tests.append(test)
        test = "%s_plugin_%s" % (name, mode)
        _PLUGIN_TESTS[mode](
            name = test,
            target_under_test = ":_%s_plugin__flutter_framework" % name,
            mode = mode,
            target_compatible_with = ["@platforms//os:macos"],
        )
        tests.append(test)
    native.test_suite(name = name, tests = tests)
