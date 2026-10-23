"""Unit and analysis tests for flutter_plugin.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterInfo")
load("//flutter/private:flutter_plugin.bzl", "build_plugin_struct", "flutter_plugin")

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

def _fake_apple_plugin_lib_impl(ctx):
    cc_info = CcInfo(compilation_context = cc_common.create_compilation_context())
    return [
        DefaultInfo(),
        cc_info,
        FlutterApplePluginInfo(
            module_name = ctx.label.name,
            platform = ctx.attr.platform,
            swift_srcs = depset(),
            objc_srcs = depset(),
            headers = depset(),
            modulemap = None,
            sdk_frameworks = [],
            sdk_dylibs = [],
        ),
    ]

_fake_apple_plugin_lib = rule(
    implementation = _fake_apple_plugin_lib_impl,
    attrs = {
        "platform": attr.string(mandatory = True),
    },
)

def _fake_bare_cc_lib_impl(_ctx):
    cc_info = CcInfo(compilation_context = cc_common.create_compilation_context())
    return [DefaultInfo(), cc_info]

_fake_bare_cc_lib = rule(
    implementation = _fake_bare_cc_lib_impl,
)

def _apple_plugin_routing_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]
    by_name = {
        entry.label.name: entry.platform
        for entry in info.apple_plugin_libraries.to_list()
    }
    asserts.equals(env, ctx.attr.expected_platforms, by_name)
    return analysistest.end(env)

_apple_plugin_routing_test = analysistest.make(
    _apple_plugin_routing_test_impl,
    attrs = {
        "expected_platforms": attr.string_dict(mandatory = True),
    },
)

def _apple_libs_missing_provider_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "must provide FlutterApplePluginInfo")
    return analysistest.end(env)

_apple_libs_missing_provider_fails_test = analysistest.make(
    _apple_libs_missing_provider_fails_test_impl,
    expect_failure = True,
)

_t0_test = unittest.make(_dart_only_plugin_test_impl)
_t1_test = unittest.make(_native_only_plugin_test_impl)
_t2_test = unittest.make(_multi_platform_plugin_test_impl)
_t3_test = unittest.make(_empty_platforms_test_impl)

def flutter_plugin_test_suite(name):
    """Defines unit and analysis tests for `flutter_plugin` and Apple plugin library routing.

    Args:
      name: The test_suite target name.
    """

    # Provider-driven platform routing: target names have no "macos"/"ios" or
    # even contain the opposite platform word, yet FlutterApplePluginInfo.platform
    # determines the platform.
    _fake_apple_plugin_lib(
        name = name + "_custom_neutral_lib",
        platform = "macos",
        tags = ["manual"],
    )
    _fake_apple_plugin_lib(
        name = name + "_ios_word_in_name_but_macos_provider",
        platform = "macos",
        tags = ["manual"],
    )
    _fake_apple_plugin_lib(
        name = name + "_macos_word_in_name_but_ios_provider",
        platform = "ios",
        tags = ["manual"],
    )
    flutter_plugin(
        name = name + "_provider_routed_plugin",
        package_name = "provider_routed_plugin",
        platforms = ["macos", "ios"],
        plugin_class = "SamplePlugin",
        apple_libs = [
            ":" + name + "_custom_neutral_lib",
            ":" + name + "_ios_word_in_name_but_macos_provider",
            ":" + name + "_macos_word_in_name_but_ios_provider",
        ],
        tags = ["manual"],
    )
    _apple_plugin_routing_test(
        name = name + "_provider_routing",
        target_under_test = ":" + name + "_provider_routed_plugin",
        expected_platforms = {
            name + "_custom_neutral_lib": "macos",
            name + "_ios_word_in_name_but_macos_provider": "macos",
            name + "_macos_word_in_name_but_ios_provider": "ios",
        },
    )

    # Explicit attribute routing via macos_libs / ios_libs without FlutterApplePluginInfo
    # or platform words in target names.
    _fake_bare_cc_lib(
        name = name + "_desktop_native_target",
        tags = ["manual"],
    )
    _fake_bare_cc_lib(
        name = name + "_handheld_native_target",
        tags = ["manual"],
    )
    flutter_plugin(
        name = name + "_attr_routed_plugin",
        package_name = "attr_routed_plugin",
        platforms = ["macos", "ios"],
        plugin_class = "SamplePlugin",
        macos_libs = [":" + name + "_desktop_native_target"],
        ios_libs = [":" + name + "_handheld_native_target"],
        tags = ["manual"],
    )
    _apple_plugin_routing_test(
        name = name + "_explicit_attr_routing",
        target_under_test = ":" + name + "_attr_routed_plugin",
        expected_platforms = {
            name + "_desktop_native_target": "macos",
            name + "_handheld_native_target": "ios",
        },
    )

    # A bare library in apple_libs fails even when its target name contains "macos".
    _fake_bare_cc_lib(
        name = name + "_bare_macos_named_lib",
        tags = ["manual"],
    )
    flutter_plugin(
        name = name + "_bare_apple_libs_plugin",
        package_name = "bare_apple_libs_plugin",
        platforms = ["macos"],
        plugin_class = "SamplePlugin",
        apple_libs = [":" + name + "_bare_macos_named_lib"],
        tags = ["manual"],
    )
    _apple_libs_missing_provider_fails_test(
        name = name + "_bare_apple_libs_fails",
        target_under_test = ":" + name + "_bare_apple_libs_plugin",
    )

    unittest.suite(
        name + "_unit",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_provider_routing",
            ":" + name + "_explicit_attr_routing",
            ":" + name + "_bare_apple_libs_fails",
        ],
    )
