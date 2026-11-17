"""Unit tests for choosing a federated plugin's implementation (plugin_resolution.bzl).

Each case is one of flutter_tools' (`_resolvePluginImplementations` in
`flutter_plugins.dart`), over plugin structs as `FlutterInfo.plugins` carries
them. That the rules hand every registrant the choice is
`federated_plugin_test.bzl`'s.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_info.bzl", "plugins_on_platform")
load("//flutter/private:plugin_resolution.bzl", "choose_implementations", "chosen_native_code")

def _entry(plugin_class = "", dart = "", default = ""):
    return struct(plugin_class = plugin_class, dart_plugin_class = dart, default_package = default)

def _plugin(name, implements = "", dependencies = [], **platforms):
    return struct(name = name, platforms = platforms, dependencies = dependencies, implements = implements)

def _on(plugins, platform):
    return [p.name for p in plugins_on_platform(plugins, platform)]

# An app-facing package with a default implementation on Android and a second
# implementation of it: `url_launcher`, `url_launcher_android` and another.
_FED = _plugin("fed", android = _entry(default = "fed_android"))
_FED_ANDROID = _plugin("fed_android", implements = "fed", android = _entry("FedPlugin", "FedAndroid"))
_FED_ANDROID_ALT = _plugin("fed_android_alt", implements = "fed", android = _entry("AltPlugin", "FedAndroidAlt"))
_FEDERATED = [_FED, _FED_ANDROID, _FED_ANDROID_ALT]

def _choose(plugins, direct = []):
    return choose_implementations(plugins, depset(direct))

def _ordinary_plugin_test_impl(ctx):
    """A plugin with an implementation of its own and no `implements` is its own only candidate."""
    env = unittest.begin(ctx)
    chosen = _choose([_plugin("plain", android = _entry("PlainPlugin"), ios = _entry(dart = "PlainIOS"))])
    asserts.equals(env, None, chosen.error)
    asserts.equals(env, ["plain"], _on(chosen.native, "android"))
    asserts.equals(env, ["plain"], _on(chosen.native, "ios"))

    # Only a Dart implementation is a candidate of the Dart choice.
    asserts.equals(env, [], _on(chosen.dart, "android"))
    asserts.equals(env, ["plain"], _on(chosen.dart, "ios"))

    # Nothing passed over, so an application's native code passes through.
    asserts.equals(env, {}, chosen.unchosen)
    return unittest.end(env)

_ordinary_plugin_test = unittest.make(_ordinary_plugin_test_impl)

def _default_package_test_impl(ctx):
    """Of two implementations, neither depended on directly, the app-facing package's `default_package`."""
    env = unittest.begin(ctx)
    chosen = _choose(_FEDERATED)
    asserts.equals(env, None, chosen.error)
    asserts.equals(env, ["fed_android"], _on(chosen.native, "android"))
    asserts.equals(env, ["fed_android"], _on(chosen.dart, "android"))

    # The app-facing package, chosen on no platform, is registered on none.
    asserts.equals(env, ["fed_android"], [p.name for p in chosen.native])

    # The other implementation's native code stays out on Android. The
    # app-facing package has none of its own there.
    asserts.equals(env, {"android": {"fed_android_alt": True}}, chosen.unchosen)
    return unittest.end(env)

_default_package_test = unittest.make(_default_package_test_impl)

def _direct_dependency_test_impl(ctx):
    """The implementation the application depends on directly, over the default."""
    env = unittest.begin(ctx)
    chosen = _choose(_FEDERATED, direct = ["fed", "fed_android_alt"])
    asserts.equals(env, None, chosen.error)
    asserts.equals(env, ["fed_android_alt"], _on(chosen.native, "android"))
    asserts.equals(env, ["fed_android_alt"], _on(chosen.dart, "android"))
    asserts.equals(env, {"android": {"fed_android": True}}, chosen.unchosen)
    return unittest.end(env)

_direct_dependency_test = unittest.make(_direct_dependency_test_impl)

def _conflicting_direct_dependencies_test_impl(ctx):
    """Two implementations depended on directly are an error, flutter_tools' own."""
    env = unittest.begin(ctx)
    chosen = _choose(_FEDERATED, direct = ["fed_android", "fed_android_alt"])
    asserts.equals(
        env,
        "Plugin fed:android has conflicting direct dependency implementations:\n" +
        "  fed_android\n" +
        "  fed_android_alt\n" +
        "To fix this issue, remove all but one of these from the `deps` of the application " +
        "and of the `flutter_library` targets of this repository that it depends on.\n" +
        "Please resolve the plugin implementation selection errors",
        chosen.error,
    )
    return unittest.end(env)

_conflicting_direct_dependencies_test = unittest.make(_conflicting_direct_dependencies_test_impl)

def _no_default_test_impl(ctx):
    """Two implementations, neither direct, and no default: an error."""
    env = unittest.begin(ctx)
    chosen = _choose([
        _plugin("nodefault"),
        _plugin("nodefault_a", implements = "nodefault", macos = _entry("A")),
        _plugin("nodefault_b", implements = "nodefault", macos = _entry("B")),
    ])
    asserts.equals(
        env,
        "Plugin nodefault:macos has multiple possible implementations:\n" +
        "  nodefault_a\n" +
        "  nodefault_b\n" +
        "To fix this issue, add one of these to the `deps` of the application.\n" +
        "Please resolve the plugin implementation selection errors",
        chosen.error,
    )
    return unittest.end(env)

_no_default_test = unittest.make(_no_default_test_impl)

def _inline_implementation_test_impl(ctx):
    """An app-facing package's own implementation is its default, and gives way to a direct one that implements it."""
    env = unittest.begin(ctx)
    plugins = [
        _plugin("inline", android = _entry("InlinePlugin")),
        _plugin("inline_override", implements = "inline", android = _entry("OverridePlugin")),
    ]
    asserts.equals(env, ["inline"], _on(_choose(plugins).native, "android"))
    asserts.equals(env, ["inline_override"], _on(_choose(plugins, direct = ["inline_override"]).native, "android"))

    # Both direct: the one that implements the other wins, not a conflict.
    asserts.equals(env, ["inline_override"], _on(_choose(plugins, direct = ["inline", "inline_override"]).native, "android"))
    return unittest.end(env)

_inline_implementation_test = unittest.make(_inline_implementation_test_impl)

def _dart_choice_test_impl(ctx):
    """The Dart registrant's choice is over Dart implementations only, and can differ from the native one."""
    env = unittest.begin(ctx)
    chosen = _choose([
        _plugin("mixed", android = _entry(default = "mixed_native")),
        _plugin("mixed_native", implements = "mixed", android = _entry("NativePlugin")),
        _plugin("mixed_dart", implements = "mixed", android = _entry(dart = "MixedDart")),
    ])
    asserts.equals(env, None, chosen.error)
    asserts.equals(env, ["mixed_native"], _on(chosen.native, "android"))
    asserts.equals(env, ["mixed_dart"], _on(chosen.dart, "android"))
    return unittest.end(env)

_dart_choice_test = unittest.make(_dart_choice_test_impl)

def _web_default_test_impl(ctx):
    """flutter_tools reads no `default_package` of the web: two web implementations need a direct dependency."""
    env = unittest.begin(ctx)
    plugins = [
        _plugin("webfed", web = _entry(default = "webfed_a")),
        _plugin("webfed_a", implements = "webfed", web = _entry("A")),
        _plugin("webfed_b", implements = "webfed", web = _entry("B")),
    ]
    asserts.true(env, "Plugin webfed:web has multiple possible implementations:\n" in (_choose(plugins).error or ""))
    asserts.equals(env, ["webfed_b"], _on(_choose(plugins, direct = ["webfed_b"]).native, "web"))
    return unittest.end(env)

_web_default_test = unittest.make(_web_default_test_impl)

def _pubspec_errors_test_impl(ctx):
    """A `default_package` beside an implementation of its own is refused, with flutter_tools' words."""
    env = unittest.begin(ctx)
    chosen = _choose([_plugin("both", implements = "other", ios = _entry(default = "both_ios"))])
    asserts.equals(
        env,
        "Plugin both:ios provides an implementation for other and also references a default implementation for both_ios, " +
        "which is currently not supported. Ask the maintainers of both to either remove the implementation via " +
        "`implements: other` or avoid referencing a default implementation via `platforms: ios: default_package: both_ios`.\n" +
        "Please resolve the plugin pubspec errors",
        chosen.error,
    )

    # A Dart class beside a `default_package` is an implementation only to the
    # Dart choice, which refuses it.
    chosen = _choose([
        _plugin("dartdefault", linux = _entry(dart = "DartDefault", default = "dartdefault_linux")),
        _plugin("dartdefault_linux", implements = "dartdefault", linux = _entry(dart = "DartDefaultLinux")),
    ])
    asserts.equals(
        env,
        "Plugin dartdefault:linux which provides an inline implementation cannot also reference a default implementation " +
        "for dartdefault_linux. Ask the maintainers of dartdefault to either remove the implementation via " +
        "`platforms: linux: dartPluginClass` or avoid referencing a default implementation via " +
        "`platforms: linux: default_package: dartdefault_linux`.\n" +
        "Please resolve the plugin pubspec errors",
        chosen.error,
    )
    return unittest.end(env)

_pubspec_errors_test = unittest.make(_pubspec_errors_test_impl)

def _missing_default_test_impl(ctx):
    """A default that is not in the application is passed over, as flutter_tools warns and does."""
    env = unittest.begin(ctx)
    chosen = _choose([
        _plugin("gone", windows = _entry(default = "gone_windows")),
        _plugin("gone_other", implements = "gone", windows = _entry("Other")),
    ])
    asserts.equals(env, None, chosen.error)
    asserts.equals(env, ["gone_other"], _on(chosen.native, "windows"))
    return unittest.end(env)

_missing_default_test = unittest.make(_missing_default_test_impl)

def _per_platform_choice_test_impl(ctx):
    """A plugin chosen on one platform and not another keeps only the platform it is chosen on."""
    env = unittest.begin(ctx)
    chosen = _choose([
        _plugin("split", ios = _entry(default = "split_both")),
        _plugin("split_both", implements = "split", android = _entry("BothA"), ios = _entry("BothI")),
        _plugin("split_ios", implements = "split", ios = _entry("OnlyI")),
    ], direct = ["split_ios"])
    asserts.equals(env, None, chosen.error)
    asserts.equals(env, ["split_both"], _on(chosen.native, "android"))
    asserts.equals(env, ["split_ios"], _on(chosen.native, "ios"))
    both = [p for p in chosen.native if p.name == "split_both"][0]
    asserts.equals(env, ["android"], sorted(both.platforms))
    return unittest.end(env)

_per_platform_choice_test = unittest.make(_per_platform_choice_test_impl)

def _platform_order_test_impl(ctx):
    """A platform's plugins are ordered among themselves, as flutter_tools orders them."""
    env = unittest.begin(ctx)

    # `a` depends on `z`, which has no Android implementation: on Android `a`
    # depends on nothing there, and comes before `b` by name.
    chosen = _choose([
        _plugin("a", dependencies = ["z"], android = _entry("A"), ios = _entry("A")),
        _plugin("b", android = _entry("B"), ios = _entry("B")),
        _plugin("z", ios = _entry("Z")),
    ])
    asserts.equals(env, ["a", "b"], _on(chosen.native, "android"))
    asserts.equals(env, ["b", "z", "a"], _on(chosen.native, "ios"))
    return unittest.end(env)

_platform_order_test = unittest.make(_platform_order_test_impl)

def _native(package, platform = None, privacy = ()):
    return struct(package = package, platform = platform, privacy_manifests = privacy)

def _chosen_native_code_test_impl(ctx):
    """An application's native code keeps the chosen implementation's entries, matched by package and platform."""
    env = unittest.begin(ctx)
    resolution = struct(unchosen = {"android": {"b": True}, "macos": {"b": True}, "linux": {"b": True}})
    code = chosen_native_code(
        resolution,
        android_libs = depset([_native("a"), _native("b"), _native("not_a_plugin")]),
        # `b` is passed over on macOS only: its iOS library stays.
        apple_plugin_libraries = depset([
            _native("a", "macos", ("a.xcprivacy",)),
            _native("b", "macos", ("b.xcprivacy",)),
            _native("b", "ios", ("b_ios.xcprivacy",)),
        ]),
        apple_privacy_manifests = depset(["a.xcprivacy", "b.xcprivacy", "b_ios.xcprivacy"]),
        linux_plugin_libraries = depset([_native("a"), _native("b")]),
        windows_plugin_libraries = depset([_native("a"), _native("b")]),
    )
    asserts.equals(env, ["a", "not_a_plugin"], [e.package for e in code.android_libs.to_list()])
    asserts.equals(env, [("a", "macos"), ("b", "ios")], [(e.package, e.platform) for e in code.apple_plugin_libraries.to_list()])
    asserts.equals(env, ["a.xcprivacy", "b_ios.xcprivacy"], code.apple_privacy_manifests.to_list())
    asserts.equals(env, ["a"], [e.package for e in code.linux_plugin_libraries.to_list()])
    asserts.equals(env, ["a", "b"], [e.package for e in code.windows_plugin_libraries.to_list()])
    return unittest.end(env)

_chosen_native_code_test = unittest.make(_chosen_native_code_test_impl)

def plugin_resolution_test_suite(name):
    unittest.suite(
        name,
        _ordinary_plugin_test,
        _default_package_test,
        _direct_dependency_test,
        _conflicting_direct_dependencies_test,
        _no_default_test,
        _inline_implementation_test,
        _dart_choice_test,
        _web_default_test,
        _pubspec_errors_test,
        _missing_default_test,
        _per_platform_choice_test,
        _platform_order_test,
        _chosen_native_code_test,
    )
