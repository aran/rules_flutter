"""Unit tests for plugin_registrant.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:plugin_registrant.bzl", "make_registrant_content")

def _no_plugins_returns_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    result = make_registrant_content([])
    asserts.equals(env, "", result)
    return unittest.end(env)

def _native_only_plugin_returns_empty_test_impl(ctx):
    """Plugins with only pluginClass (no dartPluginClass) produce no registrant."""
    env = unittest.begin(ctx)
    plugins = [struct(
        name = "my_plugin",
        platforms = {"linux": {"pluginClass": "MyPlugin"}},
    )]
    result = make_registrant_content(plugins)
    asserts.equals(env, "", result)
    return unittest.end(env)

def _single_dart_plugin_test_impl(ctx):
    """Non-web registrant is the engine-invocable _PluginRegistrant class.

    The engine looks up `_PluginRegistrant` by name in the library named by
    -Dflutter.dart_plugin_registrant and calls its static `register()` before
    main() on every root-isolate launch (including hot restart), so both the
    class and the method must carry @pragma('vm:entry-point') to survive
    AOT tree-shaking and be lookup-able.
    """
    env = unittest.begin(ctx)
    plugins = [struct(
        name = "url_launcher_web",
        platforms = {"web": {"dartPluginClass": "UrlLauncherPlugin"}},
    )]
    result = make_registrant_content(plugins)
    asserts.true(env, "import 'package:url_launcher_web/url_launcher_web.dart';" in result)
    asserts.true(env, "UrlLauncherPlugin.registerWith();" in result)
    asserts.true(env, "@pragma('vm:entry-point')" in result)
    asserts.true(env, "class _PluginRegistrant {" in result)
    asserts.true(env, "static void register() {" in result)
    return unittest.end(env)

def _multiple_dart_plugins_test_impl(ctx):
    env = unittest.begin(ctx)
    plugins = [
        struct(
            name = "url_launcher_web",
            platforms = {"web": {"dartPluginClass": "UrlLauncherPlugin"}},
        ),
        struct(
            name = "shared_preferences_web",
            platforms = {"web": {"dartPluginClass": "SharedPreferencesPlugin"}},
        ),
    ]
    result = make_registrant_content(plugins)
    asserts.true(env, "UrlLauncherPlugin.registerWith();" in result)
    asserts.true(env, "SharedPreferencesPlugin.registerWith();" in result)
    return unittest.end(env)

def _mixed_native_and_dart_plugins_test_impl(ctx):
    """Only plugins with dartPluginClass appear in registrant."""
    env = unittest.begin(ctx)
    plugins = [
        struct(
            name = "url_launcher_linux",
            platforms = {"linux": {"pluginClass": "UrlLauncherLinux"}},
        ),
        struct(
            name = "url_launcher_web",
            platforms = {"web": {"dartPluginClass": "UrlLauncherPlugin"}},
        ),
    ]
    result = make_registrant_content(plugins)
    asserts.true(env, "UrlLauncherPlugin.registerWith();" in result)
    asserts.true(env, "url_launcher_linux" not in result)
    return unittest.end(env)

def _multi_platform_plugin_registers_once_test_impl(ctx):
    """A plugin with dartPluginClass on multiple platforms registers only once."""
    env = unittest.begin(ctx)
    plugins = [struct(
        name = "my_plugin",
        platforms = {
            "web": {"dartPluginClass": "MyPlugin"},
            "linux": {"dartPluginClass": "MyPlugin"},
        },
    )]
    result = make_registrant_content(plugins)

    # Should have exactly one registerWith call.
    asserts.equals(env, 1, result.count("MyPlugin.registerWith();"))
    return unittest.end(env)

def _dart_file_name_override_test_impl(ctx):
    """dartFileName in platform info overrides the default import filename."""
    env = unittest.begin(ctx)
    plugins = [struct(
        name = "my_plugin",
        platforms = {"web": {"dartPluginClass": "MyPlugin", "dartFileName": "custom_file.dart"}},
    )]
    result = make_registrant_content(plugins)
    asserts.true(env, "import 'package:my_plugin/custom_file.dart';" in result)
    asserts.true(env, "MyPlugin.registerWith();" in result)
    return unittest.end(env)

def _platform_filters_web_only_test_impl(ctx):
    """With target_platform='web', only web dartPluginClass plugins are registered."""
    env = unittest.begin(ctx)
    plugins = [
        struct(
            name = "url_launcher",
            platforms = {
                "web": {"dartPluginClass": "UrlLauncherWeb"},
                "android": {"dartPluginClass": "UrlLauncherAndroid"},
            },
        ),
        struct(
            name = "camera",
            platforms = {
                "android": {"dartPluginClass": "CameraAndroid"},
            },
        ),
    ]
    result = make_registrant_content(plugins, target_platform = "web")
    asserts.true(env, "UrlLauncherWeb.registerWith();" in result)
    asserts.true(env, "UrlLauncherAndroid" not in result)
    asserts.true(env, "CameraAndroid" not in result)
    asserts.true(env, "camera" not in result)
    return unittest.end(env)

def _platform_filters_android_only_test_impl(ctx):
    """With target_platform='android', only android dartPluginClass plugins are registered."""
    env = unittest.begin(ctx)
    plugins = [
        struct(
            name = "url_launcher",
            platforms = {
                "web": {"dartPluginClass": "UrlLauncherWeb"},
                "android": {"dartPluginClass": "UrlLauncherAndroid"},
            },
        ),
        struct(
            name = "camera",
            platforms = {
                "android": {"dartPluginClass": "CameraAndroid"},
            },
        ),
    ]
    result = make_registrant_content(plugins, target_platform = "android")
    asserts.true(env, "UrlLauncherAndroid.registerWith();" in result)
    asserts.true(env, "CameraAndroid.registerWith();" in result)
    asserts.true(env, "UrlLauncherWeb" not in result)
    return unittest.end(env)

def _platform_no_match_returns_empty_test_impl(ctx):
    """When no plugins match the target platform, returns empty."""
    env = unittest.begin(ctx)
    plugins = [
        struct(
            name = "camera",
            platforms = {
                "android": {"dartPluginClass": "CameraAndroid"},
            },
        ),
    ]
    result = make_registrant_content(plugins, target_platform = "web")
    asserts.equals(env, "", result)
    return unittest.end(env)

def _agent_only_registrant_test_impl(ctx):
    """An agent import alone still generates a registrant.

    With zero Dart plugins but an agent import, a registrant is generated —
    it is what registers the agent extensions pre-main.
    """
    env = unittest.begin(ctx)
    result = make_registrant_content([], agent_import = "app.agent_extensions.dart")
    asserts.true(env, "import 'app.agent_extensions.dart' as agent;" in result)
    asserts.true(env, "agent.registerRulesFlutterAgentExtensions();" in result)
    asserts.true(env, "class _PluginRegistrant {" in result)
    asserts.true(env, "@pragma('vm:entry-point')" in result)
    return unittest.end(env)

def _plugins_and_agent_test_impl(ctx):
    """Agent registration precedes plugin registration inside register()."""
    env = unittest.begin(ctx)
    plugins = [struct(
        name = "my_plugin",
        platforms = {"macos": {"dartPluginClass": "MyPlugin"}},
    )]
    result = make_registrant_content(
        plugins,
        target_platform = "macos",
        agent_import = "app.agent_extensions.dart",
    )
    asserts.true(env, "agent.registerRulesFlutterAgentExtensions();" in result)
    asserts.true(env, "MyPlugin.registerWith();" in result)
    asserts.true(
        env,
        result.index("registerRulesFlutterAgentExtensions") < result.index("MyPlugin.registerWith"),
    )
    return unittest.end(env)

def _plugins_without_agent_test_impl(ctx):
    """Without an agent import (release/profile), no agent reference appears."""
    env = unittest.begin(ctx)
    plugins = [struct(
        name = "my_plugin",
        platforms = {"macos": {"dartPluginClass": "MyPlugin"}},
    )]
    result = make_registrant_content(plugins, target_platform = "macos")
    asserts.true(env, "agent" not in result)
    asserts.true(env, "MyPlugin.registerWith();" in result)
    return unittest.end(env)

def _web_registrant_keeps_function_shape_test_impl(ctx):
    """Web keeps the plain registerPlugins() function shape.

    It is called by the web bootstrap wrapper, not the engine hook, and
    never gets an agent.
    """
    env = unittest.begin(ctx)
    plugins = [struct(
        name = "url_launcher_web",
        platforms = {"web": {"pluginClass": "UrlLauncherPlugin"}},
    )]
    result = make_registrant_content(plugins, target_platform = "web", agent_import = "ignored.dart")
    asserts.true(env, "void registerPlugins() {" in result)
    asserts.true(env, "_PluginRegistrant" not in result)
    asserts.true(env, "ignored.dart" not in result)
    return unittest.end(env)

_t0_test = unittest.make(_no_plugins_returns_empty_test_impl)
_t1_test = unittest.make(_native_only_plugin_returns_empty_test_impl)
_t2_test = unittest.make(_single_dart_plugin_test_impl)
_t3_test = unittest.make(_multiple_dart_plugins_test_impl)
_t4_test = unittest.make(_mixed_native_and_dart_plugins_test_impl)
_t5_test = unittest.make(_multi_platform_plugin_registers_once_test_impl)
_t6_test = unittest.make(_dart_file_name_override_test_impl)
_t7_test = unittest.make(_agent_only_registrant_test_impl)
_t8_test = unittest.make(_platform_filters_web_only_test_impl)
_t9_test = unittest.make(_platform_filters_android_only_test_impl)
_t10_test = unittest.make(_platform_no_match_returns_empty_test_impl)
_t11_test = unittest.make(_plugins_and_agent_test_impl)
_t12_test = unittest.make(_plugins_without_agent_test_impl)
_t13_test = unittest.make(_web_registrant_keeps_function_shape_test_impl)

def plugin_registrant_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test, _t10_test, _t11_test, _t12_test, _t13_test)
