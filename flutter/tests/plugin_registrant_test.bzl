"""Unit tests for plugin_registrant.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:plugin_registrant.bzl",
    "filter_excluded_native_plugins",
    "make_android_registrant_content",
    "make_ios_objc_header_content",
    "make_ios_objc_impl_content",
    "make_ios_registrant_content",
    "make_registrant_content",
)

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

def _native_agent_registrant_test_impl(ctx):
    """The native-only agent is imported and registered after the shared one."""
    env = unittest.begin(ctx)
    result = make_registrant_content(
        [],
        target_platform = "android",
        agent_import = "app.agent_extensions.dart",
        native_agent_import = "app.native_agent_extensions.dart",
    )
    asserts.true(env, "import 'app.native_agent_extensions.dart' as native_agent;" in result)
    asserts.true(env, "native_agent.registerRulesFlutterNativeAgentExtensions();" in result)
    asserts.true(
        env,
        result.index("agent.registerRulesFlutterAgentExtensions") < result.index("native_agent.registerRulesFlutterNativeAgentExtensions"),
    )

    # `dart:ffi` does not exist on web, so the native half never reaches it.
    web = make_registrant_content([], target_platform = "web", native_agent_import = "app.native_agent_extensions.dart")
    asserts.true(env, "native_agent" not in web)
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
_t14_test = unittest.make(_native_agent_registrant_test_impl)

def _android_registrant_names_the_declared_package_test_impl(ctx):
    """The registrant constructs `<package>.<pluginClass>`, as flutter_tools does."""
    env = unittest.begin(ctx)
    content = make_android_registrant_content([
        struct(name = "glass_plugin", plugin_class = "GlassPlugin", package = "com.example.glass_plugin"),
    ])
    asserts.true(
        env,
        "flutterEngine.getPlugins().add(new com.example.glass_plugin.GlassPlugin());" in content,
        content,
    )
    return unittest.end(env)

_t15_test = unittest.make(_android_registrant_names_the_declared_package_test_impl)

# -- iOS registrants (Swift and ObjC) ------------------------------------------
#
# These assert structure (imports, registration calls, exclusions). That the
# ObjC bytes equal the flutter tool's own
# `_objcPluginRegistryHeaderTemplate` /
# `_objcPluginRegistryImplementationTemplate` from
# `packages/flutter_tools/lib/src/flutter_plugins.dart` is guarded by the
# `objc_drift_test` suite, which renders those templates with the tool's
# mustache semantics and compares against the rule's output.

_IOS_GOLDEN_PLUGINS = [
    struct(name = "path_provider_foundation", plugin_class = "PathProviderPlugin"),
    struct(name = "url_launcher_ios", plugin_class = "URLLauncherPlugin"),
]

def _ios_swift_empty_test_impl(ctx):
    """An app with no iOS plugins still gets a registrant with no imports."""
    env = unittest.begin(ctx)
    result = make_ios_registrant_content([])
    asserts.true(env, "import Flutter" in result, result)
    asserts.true(env, "class GeneratedPluginRegistrant" in result, result)
    asserts.true(env, "register(with:" not in result, result)
    return unittest.end(env)

def _ios_swift_several_plugins_test_impl(ctx):
    """Every plugin gets an import and a registration call."""
    env = unittest.begin(ctx)
    result = make_ios_registrant_content(_IOS_GOLDEN_PLUGINS)
    for p in _IOS_GOLDEN_PLUGINS:
        asserts.true(env, "import %s" % p.name in result, result)
        asserts.true(
            env,
            '%s.register(with: registry.registrar(forPlugin: "%s")!)' % (p.plugin_class, p.plugin_class) in result,
            result,
        )
    return unittest.end(env)

def _ios_swift_exclusion_test_impl(ctx):
    """An excluded plugin gets no import and no registration call."""
    env = unittest.begin(ctx)
    remaining = filter_excluded_native_plugins(_IOS_GOLDEN_PLUGINS, ["url_launcher_ios"], "ios")
    asserts.equals(env, 1, len(remaining))
    result = make_ios_registrant_content(remaining)
    asserts.true(env, "url_launcher_ios" not in result, result)
    asserts.true(env, "URLLauncherPlugin" not in result, result)
    asserts.true(env, "import path_provider_foundation" in result, result)
    asserts.true(env, "PathProviderPlugin.register(with:" in result, result)
    return unittest.end(env)

def _ios_objc_header_test_impl(ctx):
    """The ObjC header declares the registry entry point (it names no plugin)."""
    env = unittest.begin(ctx)
    result = make_ios_objc_header_content()
    asserts.true(env, result.startswith("//\n//  Generated file. Do not edit."), result)
    asserts.true(env, "#import <Flutter/Flutter.h>" in result, result)
    asserts.true(
        env,
        "+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry;" in result,
        result,
    )
    return unittest.end(env)

def _ios_objc_empty_impl_test_impl(ctx):
    """An app with no iOS plugins gets an empty ObjC registrant."""
    env = unittest.begin(ctx)
    result = make_ios_objc_impl_content([])
    asserts.true(env, result.startswith("//\n//  Generated file. Do not edit."), result)
    asserts.true(env, '#import "GeneratedPluginRegistrant.h"' in result, result)
    asserts.true(env, "@implementation GeneratedPluginRegistrant" in result, result)
    asserts.true(env, "registerWithRegistrar" not in result, result)
    return unittest.end(env)

def _ios_objc_two_plugin_impl_test_impl(ctx):
    """Every plugin gets an import fallback and a registration call."""
    env = unittest.begin(ctx)
    result = make_ios_objc_impl_content(_IOS_GOLDEN_PLUGINS)
    for p in _IOS_GOLDEN_PLUGINS:
        asserts.true(
            env,
            "#if __has_include(<%s/%s.h>)" % (p.name, p.plugin_class) in result,
            result,
        )
        asserts.true(env, "@import %s;" % p.name in result, result)
        asserts.true(
            env,
            '[%s registerWithRegistrar:[registry registrarForPlugin:@"%s"]];' % (p.plugin_class, p.plugin_class) in result,
            result,
        )
    return unittest.end(env)

def _ios_objc_exclusion_test_impl(ctx):
    """An excluded plugin gets no import and no registration call in ObjC."""
    env = unittest.begin(ctx)
    remaining = filter_excluded_native_plugins(_IOS_GOLDEN_PLUGINS, ["url_launcher_ios"], "ios")
    result = make_ios_objc_impl_content(remaining)
    asserts.true(env, "url_launcher_ios" not in result, result)
    asserts.true(env, "URLLauncherPlugin" not in result, result)
    asserts.true(
        env,
        "#if __has_include(<path_provider_foundation/PathProviderPlugin.h>)" in result,
        result,
    )
    asserts.true(
        env,
        '[PathProviderPlugin registerWithRegistrar:[registry registrarForPlugin:@"PathProviderPlugin"]];' in result,
        result,
    )
    return unittest.end(env)

_t16_test = unittest.make(_ios_swift_empty_test_impl)
_t17_test = unittest.make(_ios_swift_several_plugins_test_impl)
_t18_test = unittest.make(_ios_swift_exclusion_test_impl)
_t19_test = unittest.make(_ios_objc_header_test_impl)
_t20_test = unittest.make(_ios_objc_empty_impl_test_impl)
_t21_test = unittest.make(_ios_objc_two_plugin_impl_test_impl)
_t22_test = unittest.make(_ios_objc_exclusion_test_impl)

def plugin_registrant_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test, _t9_test, _t10_test, _t11_test, _t12_test, _t13_test, _t14_test, _t15_test, _t16_test, _t17_test, _t18_test, _t19_test, _t20_test, _t21_test, _t22_test)
