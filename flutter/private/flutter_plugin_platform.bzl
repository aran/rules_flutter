"""A plugin's registration and native library for one platform.

    flutter_plugin_platform(name = "ios", platform = "ios", plugin_class = "AudioSessionPlugin", lib = ":lib_apple")
    flutter_plugin_platform(name = "web", platform = "web", plugin_class = "AudioSessionWeb", file_name = "audio_session_web.dart")
    flutter_plugin(name = "audio_session", platforms = [":ios", ":web"], ...)

Each target is one entry of a pubspec's `flutter: plugin: platforms:`, its
attributes the entry's keys in snake case. Its `lib` is the platform's native
library, analysed only in a build for that platform: a plugin whose iOS and
macOS code is one library (`sharedDarwinSource`) names that library in both.
An Android plugin's Kotlin or Java is the plugin's `exports` instead, the one
attribute rules_android's dexing follows to it.
"""

load("@rules_apple//apple:providers.bzl", "AppleResourceInfo")

# See `flutter_plugin.bzl` for why the internal aspect, and what an upgrade checks.
# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal/aspects:resource_aspect.bzl", "apple_resource_aspect")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "swift_clang_module_aspect")
load("//flutter:providers.bzl", "FlutterPluginPlatformInfo")
load("//flutter/private:constants.bzl", "PLUGIN_PLATFORMS")
load("//flutter/private:flutter_apple_plugin_library.bzl", "module_headers_aspect")
load("//flutter/private:flutter_desktop_plugin_info.bzl", "FlutterLinuxPluginInfo", "FlutterWindowsPluginInfo")
load("//flutter/private:swiftpm_app_settings.bzl", "FlutterSwiftPMAppLibraryInfo")
load("//flutter/private:unbuilt_native_code.bzl", "FlutterUnbuiltNativeCodeInfo")

# The platforms whose native library is `lib`, and what it provides there.
_LIB_PROVIDERS = {
    "ios": ([CcInfo, FlutterSwiftPMAppLibraryInfo], "a `flutter_apple_plugin_library`"),
    "linux": ([FlutterLinuxPluginInfo], "a `flutter_linux_plugin_library`"),
    "macos": ([CcInfo, FlutterSwiftPMAppLibraryInfo], "a `flutter_apple_plugin_library`"),
    "windows": ([FlutterWindowsPluginInfo], "a `flutter_windows_plugin_library`"),
}

def _check(ctx):
    a = ctx.attr
    p = a.platform
    if not (a.plugin_class or a.dart_plugin_class or a.ffi_plugin or a.default_package):
        fail("%s: a plugin platform has a `plugin_class`, a `dart_plugin_class`, `ffi_plugin` or a `default_package`, as flutter_tools requires of one." % ctx.label)
    if a.dart_file_name and not a.dart_plugin_class:
        fail("%s: `dart_file_name` names the file of the `dart_plugin_class`, which is not set." % ctx.label)
    if p == "web" and (a.dart_file_name or a.ffi_plugin):
        fail("%s: a web plugin platform has a `plugin_class` and its `file_name`, not `dart_file_name` or `ffi_plugin`." % ctx.label)
    if a.file_name and p != "web":
        fail("%s: `file_name` is a web plugin's; on %s, `dart_file_name` names the file of the `dart_plugin_class`." % (ctx.label, p))
    if a.package and p != "android":
        fail("%s: `package` is the Java package of an Android `plugin_class`; this platform is %s." % (ctx.label, p))
    if a.group and p != "android":
        fail("%s: `group` is the Maven group of an Android plugin's AAR; this platform is %s." % (ctx.label, p))
    if p == "android" and a.plugin_class and a.plugin_class != "none" and not a.package:
        fail("%s: an Android `plugin_class` needs its Java `package`." % ctx.label)
    lib = a.apple_lib or a.lib
    if lib == None:
        return
    providers, what = _LIB_PROVIDERS[p]
    if FlutterUnbuiltNativeCodeInfo in lib or [x for x in providers if x in lib]:
        return
    fail("%s: `lib` %s is not a %s library: use %s." % (ctx.label, lib.label, p, what))

def _flutter_plugin_platform_impl(ctx):
    _check(ctx)
    a = ctx.attr
    return [FlutterPluginPlatformInfo(
        platform = a.platform,
        plugin_class = a.plugin_class,
        dart_plugin_class = a.dart_plugin_class,
        dart_file_name = a.dart_file_name,
        file_name = a.file_name,
        ffi_plugin = a.ffi_plugin,
        default_package = a.default_package,
        package = a.package,
        group = a.group,
        lib = a.apple_lib or a.lib,
    )]

flutter_plugin_platform_rule = rule(
    implementation = _flutter_plugin_platform_impl,
    attrs = {
        "platform": attr.string(
            doc = "The platform: the entry's key under `platforms:`.",
            mandatory = True,
            values = PLUGIN_PLATFORMS,
        ),
        "plugin_class": attr.string(
            doc = "`pluginClass`: the class registered with the platform's plugin registry. On web, the Dart class whose `registerWith(Registrar)` the web registrant calls.",
        ),
        "dart_plugin_class": attr.string(
            doc = "`dartPluginClass`: the Dart class whose `registerWith()` the Dart plugin registrant calls before `main()`.",
        ),
        "dart_file_name": attr.string(
            doc = "`dartFileName`: the library under `lib/` that declares `dart_plugin_class`. Defaults to `<package>.dart`.",
        ),
        "file_name": attr.string(
            doc = "`fileName`: the library under `lib/` that declares a web `plugin_class`. Defaults to `<package>.dart`.",
        ),
        "ffi_plugin": attr.bool(
            doc = "`ffiPlugin`: the platform's native code is a library that Dart opens through `dart:ffi`, not a registered class.",
        ),
        "default_package": attr.string(
            doc = "`default_package`: for a federated plugin, the package that implements it on this platform.",
        ),
        "package": attr.string(
            doc = "`package`: the Java package of an Android `plugin_class`.",
        ),
        "group": attr.string(
            doc = "Android only: the Maven group `flutter_android_aar` publishes the plugin's AAR under (Gradle's `group`, which a plugin's `android/build.gradle` sets). A workspace plugin built into an AAR must set it; there is no default, as a wrong group would publish under someone else's coordinates.",
        ),
        "lib": attr.label(
            doc = "The platform's native library on Linux and Windows. `flutter_plugin_platform` selects it on the platform.",
            providers = [[FlutterLinuxPluginInfo], [FlutterWindowsPluginInfo], [FlutterUnbuiltNativeCodeInfo]],
        ),
        "apple_lib": attr.label(
            doc = "The platform's native library on iOS and macOS, as `lib` is on the others. A separate attribute for its aspects, which need an Apple build.",
            providers = [[CcInfo], [FlutterSwiftPMAppLibraryInfo], [FlutterUnbuiltNativeCodeInfo]],
            # The libraries' resources, as an app's bundling collects them from
            # its own dependencies: the runner links the libraries through the
            # aggregator, which carries them on (`flutter_apple_plugins_aggregator`).
            # The public headers of a C-family module, for its add-to-app
            # framework. And an Objective-C library's Clang module as Swift
            # sees it, for the registrant's `import`.
            aspects = [apple_resource_aspect, module_headers_aspect, swift_clang_module_aspect],
        ),
    },
    doc = "The rule of `flutter_plugin_platform`, whose `lib` is analysed in every build it is reached in.",
)

def flutter_plugin_platform(name, platform, lib = None, **kwargs):
    """A plugin's registration and native library for one platform.

    Args:
        name: Target name.
        platform: `android`, `ios`, `linux`, `macos`, `web` or `windows`.
        lib: The platform's native library: a `flutter_apple_plugin_library`
            on iOS and macOS, a `flutter_linux_plugin_library` or
            `flutter_windows_plugin_library` on the desktops. Only a build for
            `platform` analyses it, so two platforms' libraries with one
            module name never meet, and one library may serve iOS and macOS
            both. An Android plugin's library is its `flutter_plugin`'s
            `exports`.
        **kwargs: `plugin_class`, `dart_plugin_class`, `dart_file_name`,
            `file_name`, `ffi_plugin`, `default_package`, `package`, `group`, and the
            common attributes. See the rule.
    """
    if lib != None:
        if platform not in _LIB_PROVIDERS:
            fail("flutter_plugin_platform %s: a %s plugin platform has no `lib`.%s" % (
                name,
                platform,
                " Its Kotlin or Java is the `flutter_plugin`'s `exports`, which rules_android's dexing follows." if platform == "android" else "",
            ))
        lib = select({
            Label("@platforms//os:" + platform): lib,
            "//conditions:default": None,
        })
    if platform in ("ios", "macos"):
        flutter_plugin_platform_rule(name = name, platform = platform, apple_lib = lib, **kwargs)
    else:
        flutter_plugin_platform_rule(name = name, platform = platform, lib = lib, **kwargs)

def plugin_platforms_of(label, targets):
    """The `FlutterPluginPlatformInfo` of each of a plugin's `platforms`, by platform.

    Args:
        label: The plugin's label, for the failure message.
        targets: Its `platforms`.

    Returns:
        A dict of platform to `FlutterPluginPlatformInfo`.
    """
    by_platform = {}
    for target in targets:
        info = target[FlutterPluginPlatformInfo]
        if info.platform in by_platform:
            fail("%s: `platforms` has two %s entries, %s and the one before it." % (label, info.platform, target.label))
        by_platform[info.platform] = info
    return by_platform

def apple_resource_info(lib):
    """The resources an Apple plugin library carries, or None."""
    return lib[AppleResourceInfo] if AppleResourceInfo in lib else None
