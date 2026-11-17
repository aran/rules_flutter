"""Analysis tests: every registrant of an application registers one implementation of a federated plugin.

Over `//flutter/tests/federated_fixture`: `fed`, an app-facing package naming
`fed_android`, `fed_macos` and `fed_desktop` (Linux and Windows) its default
implementations, and `fed_alt`, which implements it on all four too, each with
native code there; and `inline`, a package with an
implementation of its own, and `inline_override`, another of it. The choice
itself, case by case, is `plugin_resolution_test.bzl`'s; these hold the rules
to handing it to the native registrants, the Dart registrant of the build and
of the dev loop, and a test's bootstrap, and to failing on a conflict, and the application to linking only the chosen
implementation's native code.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load(":action_content.bzl", "written_text")

_FIXTURE = "//flutter/tests/federated_fixture/app:"

_DBG = {"//command_line_option:compilation_mode": "dbg"}

def _on(plugins, platform):
    return sorted([p.name for p in plugins if platform in p.platforms])

def _registered_impl(ctx):
    """The application registers the implementations it should, on each platform."""
    env = analysistest.begin(ctx)
    plugins = analysistest.target_under_test(env)[FlutterApplicationInfo].plugins
    asserts.equals(env, ctx.attr.android, _on(plugins, "android"), "registered on Android")
    asserts.equals(env, ctx.attr.macos, _on(plugins, "macos"), "registered on macOS")
    return analysistest.end(env)

_registered_test = analysistest.make(
    _registered_impl,
    attrs = {
        "android": attr.string_list(),
        "macos": attr.string_list(),
    },
)

def _dart_registrants_impl(ctx):
    """The Dart registrant this build compiles, and the dev loop's for Android, register the chosen Dart classes."""
    env = analysistest.begin(ctx)

    # The build's own, for the host.
    build = written_text(env, "_plugin_registrant.dart")
    android = written_text(env, ".dev_plugin_registrant.android.dart")
    for content, expected, absent in [(build, "FedAlt", ctx.attr.host_default), (android, "FedAlt", "FedAndroid.")]:
        if content == None:
            continue
        asserts.true(env, "%s.registerWith();" % expected in content, "registers %s:\n%s" % (expected, content))
        asserts.true(env, absent not in content, "registers no %s:\n%s" % (absent, content))
    return analysistest.end(env)

# The Dart class of the host's default implementation, which an application
# that chooses `fed_alt` does not register.
_HOST_DEFAULT = {"host_default": attr.string(mandatory = True)}

def _host_default():
    return select({
        "@platforms//os:macos": "FedMacos",
        "//conditions:default": "FedDesktop",
    })

_dart_registrants_test = analysistest.make(_dart_registrants_impl, attrs = _HOST_DEFAULT, config_settings = _DBG)

def _native_registrant_impl(ctx):
    """A native registrant registers the chosen implementation's class, and not the other's."""
    env = analysistest.begin(ctx)
    content = written_text(env, ctx.attr.suffix)
    if content != None:
        asserts.true(env, ctx.attr.registers in content, "registers %s:\n%s" % (ctx.attr.registers, content))
        asserts.true(env, ctx.attr.not_registers not in content, "registers no %s:\n%s" % (ctx.attr.not_registers, content))
    return analysistest.end(env)

_native_registrant_test = analysistest.make(
    _native_registrant_impl,
    attrs = {
        "suffix": attr.string(mandatory = True),
        "registers": attr.string(mandatory = True),
        "not_registers": attr.string(mandatory = True),
    },
)

def _test_bootstrap_impl(ctx):
    """A test registers the implementation its own `deps` name, before its `main`."""
    env = analysistest.begin(ctx)
    content = written_text(env, "_bootstrap.dart")
    if content != None:
        asserts.true(env, "FedAlt.registerWith();" in content, "registers FedAlt:\n%s" % content)
        asserts.true(env, ctx.attr.host_default not in content, "registers no %s:\n%s" % (ctx.attr.host_default, content))
    return analysistest.end(env)

_test_bootstrap_test = analysistest.make(_test_bootstrap_impl, attrs = _HOST_DEFAULT)

def _platform(label):
    return {"//command_line_option:platforms": str(Label(label))}

def _native_inputs_impl(ctx):
    """An application carries the native code of the implementation it chooses on a platform, and not the other's."""
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterApplicationInfo]
    entries = getattr(info, ctx.attr.field).to_list()
    asserts.equals(env, ctx.attr.packages, sorted([e.package for e in entries]), ctx.attr.field)
    if ctx.attr.privacy_manifests:
        asserts.equals(
            env,
            ["flutter/tests/federated_fixture/%s/PrivacyInfo.xcprivacy" % p for p in ctx.attr.packages],
            sorted([f.short_path for f in info.apple_privacy_manifests.to_list()]),
            "apple_privacy_manifests",
        )
    return analysistest.end(env)

_NATIVE_INPUTS_ATTRS = {
    "field": attr.string(mandatory = True),
    "packages": attr.string_list(),
    "privacy_manifests": attr.bool(),
}

# Debug, since a release build of a desktop application is AOT, which only
# that desktop's host can make.
_android_inputs_test = analysistest.make(_native_inputs_impl, attrs = _NATIVE_INPUTS_ATTRS, config_settings = _DBG)
_macos_inputs_test = analysistest.make(_native_inputs_impl, attrs = _NATIVE_INPUTS_ATTRS, config_settings = _DBG | _platform("//flutter/platforms:macos_arm64"))
_linux_inputs_test = analysistest.make(_native_inputs_impl, attrs = _NATIVE_INPUTS_ATTRS, config_settings = _DBG | _platform("//flutter/platforms:linux_x64"))
_windows_inputs_test = analysistest.make(_native_inputs_impl, attrs = _NATIVE_INPUTS_ATTRS, config_settings = _DBG | _platform("//flutter/platforms:windows_x64"))

def _conflict_impl(ctx):
    """Two implementations depended on directly fail analysis, as `flutter build` fails."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Plugin fed:android has conflicting direct dependency implementations:\n  fed_alt\n  fed_android\n")
    asserts.expect_failure(env, "Please resolve the plugin implementation selection errors")
    return analysistest.end(env)

_conflict_test = analysistest.make(_conflict_impl, expect_failure = True)

def federated_plugin_test_suite(name):
    """Analysis tests of applications over a federated plugin.

    Args:
        name: Name of the resulting test_suite.
    """
    tests = []

    def add(test, **kwargs):
        test_name = "%s_%d" % (name, len(tests))
        test(name = test_name, **kwargs)
        tests.append(":" + test_name)

    # Neither implementation is a direct dependency: the defaults.
    add(_registered_test, target_under_test = _FIXTURE + "default_app", android = ["fed_android"], macos = ["fed_macos"])

    # The application depends on `fed_alt`, directly or through a library of
    # this repository.
    add(_registered_test, target_under_test = _FIXTURE + "direct_app", android = ["fed_alt"], macos = ["fed_alt"])
    add(_registered_test, target_under_test = _FIXTURE + "library_app", android = ["fed_alt"], macos = ["fed_alt"])

    # The other implementation of a package with one of its own.
    add(_registered_test, target_under_test = _FIXTURE + "inline_app", android = ["inline_override"], macos = [])

    add(_dart_registrants_test, target_under_test = _FIXTURE + "direct_app", host_default = _host_default())
    add(
        _native_registrant_test,
        target_under_test = _FIXTURE + "direct_app_android_registrant",
        suffix = "GeneratedPluginRegistrant.java",
        registers = "com.example.fedalt.FedAltPlugin",
        not_registers = "FedAndroidPlugin",
    )
    add(
        _native_registrant_test,
        target_under_test = _FIXTURE + "direct_app_macos_registrant",
        suffix = "_native_plugin_registrant.swift",
        registers = "FedAltPlugin.register",
        not_registers = "FedMacosPlugin",
    )
    add(
        _native_registrant_test,
        target_under_test = _FIXTURE + "inline_app_android_registrant",
        suffix = "GeneratedPluginRegistrant.java",
        registers = "com.example.inlineoverride.InlineOverridePlugin",
        not_registers = "com.example.inline.InlinePlugin",
    )
    add(_test_bootstrap_test, target_under_test = _FIXTURE + "direct_test.program", host_default = _host_default())
    add(_conflict_test, target_under_test = _FIXTURE + "conflict_app")

    # The native code an application links, on each platform: the chosen
    # implementation's, and not the other's. The macOS build is analysed only
    # on a macOS host, where rules_apple's tools have a platform to run on.
    for app, android, desktop, macos in [
        ("default_app", "fed_android", "fed_desktop", "fed_macos"),
        ("direct_app", "fed_alt", "fed_alt", "fed_alt"),
    ]:
        add(_android_inputs_test, target_under_test = _FIXTURE + app, field = "android_libs", packages = [android])
        add(_linux_inputs_test, target_under_test = _FIXTURE + app, field = "linux_plugin_libraries", packages = [desktop])
        add(_windows_inputs_test, target_under_test = _FIXTURE + app, field = "windows_plugin_libraries", packages = [desktop])
        add(
            _macos_inputs_test,
            target_under_test = _FIXTURE + app,
            field = "apple_plugin_libraries",
            packages = [macos],
            privacy_manifests = True,
            target_compatible_with = ["@platforms//os:macos"],
        )

    native.test_suite(name = name, tests = tests)
