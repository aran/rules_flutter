"""Unit tests for plugin_registrant.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:app_entrypoint.bzl", "app_main_package_uri")
load("//flutter/private:plugin_registrant.bzl", "make_registrant_content", "make_wrapper_main_content")

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
    """Default import uses package:{name}/{name}.dart convention."""
    env = unittest.begin(ctx)
    plugins = [struct(
        name = "url_launcher_web",
        platforms = {"web": {"dartPluginClass": "UrlLauncherPlugin"}},
    )]
    result = make_registrant_content(plugins)
    asserts.true(env, "import 'package:url_launcher_web/url_launcher_web.dart';" in result)
    asserts.true(env, "UrlLauncherPlugin.registerWith();" in result)
    asserts.true(env, "void registerPlugins()" in result)
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

def _wrapper_main_content_test_impl(ctx):
    env = unittest.begin(ctx)
    result = make_wrapper_main_content("package:my_app/main.dart", "my_app_plugin_registrant.dart")
    asserts.true(env, "import 'package:my_app/main.dart' as entrypoint;" in result)
    asserts.true(env, "import 'my_app_plugin_registrant.dart' as reg;" in result)
    asserts.true(env, "reg.registerPlugins();" in result)
    asserts.true(env, "entrypoint.main();" in result)
    return unittest.end(env)

def _wrapper_imports_app_main_via_package_uri_test_impl(ctx):
    """Wrapper imports the user's main via the `package:` URI (Bug 3).

    It must not use a relative file path: the running kernel would key
    the library `file://` and `reloadSources` could not match it. Pins
    the helper→wrapper contract used at the native caller.
    """
    env = unittest.begin(ctx)
    original_import = app_main_package_uri("app_flutter", "lib/main.dart")
    asserts.equals(env, "package:app_flutter/main.dart", original_import)
    result = make_wrapper_main_content(
        original_import,
        "app_flutter_plugin_registrant.dart",
        "app_flutter.agent_extensions.dart",
    )
    asserts.true(
        env,
        "import 'package:app_flutter/main.dart' as entrypoint;" in result,
        "wrapper must import main via package: URI, got: %s" % result,
    )
    asserts.true(
        env,
        "import '../" not in result,
        "wrapper must not import main via a relative file path, got: %s" % result,
    )
    return unittest.end(env)

_t0_test = unittest.make(_no_plugins_returns_empty_test_impl)
_t1_test = unittest.make(_native_only_plugin_returns_empty_test_impl)
_t2_test = unittest.make(_single_dart_plugin_test_impl)
_t3_test = unittest.make(_multiple_dart_plugins_test_impl)
_t4_test = unittest.make(_mixed_native_and_dart_plugins_test_impl)
_t5_test = unittest.make(_multi_platform_plugin_registers_once_test_impl)
_t6_test = unittest.make(_dart_file_name_override_test_impl)
_t7_test = unittest.make(_wrapper_main_content_test_impl)
_t8_test = unittest.make(_platform_filters_web_only_test_impl)
_t9_test = unittest.make(_platform_filters_android_only_test_impl)
_t10_test = unittest.make(_platform_no_match_returns_empty_test_impl)
_t11_test = unittest.make(_wrapper_imports_app_main_via_package_uri_test_impl)

def plugin_registrant_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test, _t10_test, _t11_test)
