"""Unit tests for flutter_plugin.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_plugin.bzl", "build_plugin_struct")

def _dart_only_plugin_test_impl(ctx):
    env = unittest.begin(ctx)
    plugin = build_plugin_struct(
        name = "url_launcher_web",
        plugin_platforms = {"web": {"dartPluginClass": "UrlLauncherPlugin"}},
    )
    asserts.equals(env, "url_launcher_web", plugin.name)
    asserts.equals(env, 1, len(plugin.platforms))
    asserts.equals(env, "UrlLauncherPlugin", plugin.platforms["web"]["dartPluginClass"])
    return unittest.end(env)

def _native_only_plugin_test_impl(ctx):
    env = unittest.begin(ctx)
    plugin = build_plugin_struct(
        name = "url_launcher_linux",
        plugin_platforms = {"linux": {"pluginClass": "UrlLauncherLinux"}},
    )
    asserts.equals(env, "url_launcher_linux", plugin.name)
    asserts.equals(env, "UrlLauncherLinux", plugin.platforms["linux"]["pluginClass"])
    asserts.true(env, "dartPluginClass" not in plugin.platforms["linux"])
    return unittest.end(env)

def _multi_platform_plugin_test_impl(ctx):
    """Per-platform classes are preserved — different classes per platform."""
    env = unittest.begin(ctx)
    plugin = build_plugin_struct(
        name = "url_launcher",
        plugin_platforms = {
            "web": {"dartPluginClass": "UrlLauncherWeb"},
            "linux": {"pluginClass": "UrlLauncherLinux"},
            "android": {"pluginClass": "UrlLauncherAndroid", "dartPluginClass": "UrlLauncherAndroidDart"},
        },
    )
    asserts.equals(env, 3, len(plugin.platforms))
    asserts.equals(env, "UrlLauncherWeb", plugin.platforms["web"]["dartPluginClass"])
    asserts.true(env, "dartPluginClass" not in plugin.platforms["linux"])
    asserts.equals(env, "UrlLauncherLinux", plugin.platforms["linux"]["pluginClass"])
    asserts.equals(env, "UrlLauncherAndroidDart", plugin.platforms["android"]["dartPluginClass"])
    return unittest.end(env)

def _empty_platforms_test_impl(ctx):
    env = unittest.begin(ctx)
    plugin = build_plugin_struct(
        name = "stub",
        plugin_platforms = {},
    )
    asserts.equals(env, {}, plugin.platforms)
    return unittest.end(env)

_t0_test = unittest.make(_dart_only_plugin_test_impl)
_t1_test = unittest.make(_native_only_plugin_test_impl)
_t2_test = unittest.make(_multi_platform_plugin_test_impl)
_t3_test = unittest.make(_empty_platforms_test_impl)

def flutter_plugin_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test)
