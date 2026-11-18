"""Tests that each platform's bundle-parts aspect reads what an application provides.

The dev tool's `flutter_bazel run` applies `flutter/<platform>_bundle_parts.bzl`'s
aspect to the launch target and builds its two output groups: the
`flutter_assets` tree, and the native libraries the bundle carries. The aspects
read `FlutterApplicationInfo`, which no other test applies them to, so a change
to that provider that left one behind broke every run of a platform while
`bazel test //...` stayed green.

Each test applies the aspect to the rules that hold an application, over
`fake_application` (whose `native_libs` has the shape of `native_deps` records),
and reads both output groups: the native-libs group must hold the library, and
the bundle-parts group the assets tree.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:ios_bundle_parts.bzl", "flutter_ios_bundle_parts_aspect")
load("//flutter:linux_bundle_parts.bzl", "flutter_linux_bundle_parts_aspect")
load("//flutter:macos_bundle_parts.bzl", "flutter_macos_bundle_parts_aspect")
load("//flutter:windows_bundle_parts.bzl", "flutter_windows_bundle_parts_aspect")
load("//flutter/private:flutter_ios_application.bzl", "flutter_ios_app_framework", "flutter_ios_native_frameworks")
load("//flutter/private:flutter_linux_application.bzl", "flutter_linux_bundle_rule")
load("//flutter/private:flutter_macos_application.bzl", "flutter_macos_app_framework", "flutter_macos_native_libs")
load("//flutter/private:flutter_windows_application.bzl", "flutter_windows_bundle_rule")
load(":apple_bundling.bzl", "fake_application")

def _impl(ctx):
    env = analysistest.begin(ctx)
    groups = analysistest.target_under_test(env)[OutputGroupInfo]
    parts = "flutter_%s_bundle_parts" % ctx.attr.platform
    native = "flutter_%s_native_libs" % ctx.attr.platform
    asserts.true(env, parts in groups, "the aspect should provide the `%s` output group" % parts)
    asserts.true(env, native in groups, "the aspect should provide the `%s` output group" % native)
    if parts in groups and native in groups:
        asserts.equals(
            env,
            ["flutter_assets"],
            [f.basename for f in getattr(groups, parts).to_list()],
            "`%s` should hold the application's assets tree" % parts,
        )
        libraries = [f.basename for f in getattr(groups, native).to_list()]
        asserts.true(
            env,
            ctx.attr.library in libraries,
            "`%s` should hold the application's native library %s: %s" % (native, ctx.attr.library, libraries),
        )
    return analysistest.end(env)

def _make(aspect, target_platform = None):
    return analysistest.make(
        _impl,
        attrs = {
            "library": attr.string(mandatory = True),
            "platform": attr.string(mandatory = True),
        },
        extra_target_under_test_aspects = [aspect],
        config_settings = {
            "//command_line_option:platforms": str(Label(target_platform)),
        } if target_platform else {},
    )

_macos_test = _make(flutter_macos_bundle_parts_aspect)
_ios_test = _make(flutter_ios_bundle_parts_aspect)

# A desktop bundle needs the engine of its own OS, which the toolchain has
# only for that target platform, whatever the host.
_linux_test = _make(flutter_linux_bundle_parts_aspect, "//flutter/platforms:linux_x64")
_windows_test = _make(flutter_windows_bundle_parts_aspect, "//flutter/platforms:windows_x64")

def _launch_impl(_ctx):
    return [DefaultInfo()]

# What a launch target is to the aspect: a node with the rules that hold the
# application below it. The real one is rules_apple's `*_application`.
_launch = rule(
    implementation = _launch_impl,
    attrs = {"deps": attr.label_list()},
)

def bundle_parts_test_suite(name):
    """Declares the tests.

    Args:
        name: The test_suite name.
    """

    # A debug fake: a release framework retags its dylib with `vtool`.
    fake_application(
        name = name + "_apple_app",
        debug = True,
        native_libs = ["libadd.dylib"],
        tags = ["manual"],
    )
    flutter_macos_app_framework(
        name = name + "_macos_framework",
        application = name + "_apple_app",
        tags = ["manual"],
    )
    flutter_macos_native_libs(
        name = name + "_macos_native_libs",
        application = name + "_apple_app",
        tags = ["manual"],
    )
    _launch(
        name = name + "_macos_launch",
        deps = [name + "_macos_framework", name + "_macos_native_libs"],
        tags = ["manual"],
    )
    _macos_test(
        name = name + "_macos",
        target_under_test = name + "_macos_launch",
        platform = "macos",
        library = "libadd.dylib",
    )

    # No Linux-host-to-iOS Flutter toolchain exists, so iOS is analysed only
    # on macOS.
    flutter_ios_app_framework(
        name = name + "_ios_framework",
        application = name + "_apple_app",
        tags = ["manual"],
    )
    flutter_ios_native_frameworks(
        name = name + "_ios_native_frameworks",
        application = name + "_apple_app",
        tags = ["manual"],
    )
    _launch(
        name = name + "_ios_launch",
        deps = [name + "_ios_framework", name + "_ios_native_frameworks"],
        tags = ["manual"],
    )
    _ios_test(
        name = name + "_ios",
        target_under_test = name + "_ios_launch",
        platform = "ios",
        library = "libadd.dylib",
        target_compatible_with = ["@platforms//os:macos"],
    )

    # The desktop bundle rules take the runner as a built file; a stand-in
    # needs no C++ toolchain.
    write_file(
        name = name + "_runner",
        out = name + "_runner.bin",
        content = [""],
        tags = ["manual"],
    )
    fake_application(
        name = name + "_desktop_app",
        debug = True,
        native_libs = ["libadd.so"],
        tags = ["manual"],
    )
    flutter_linux_bundle_rule(
        name = name + "_linux_bundle",
        application = name + "_desktop_app",
        runner = name + "_runner",
        tags = ["manual"],
    )
    _linux_test(
        name = name + "_linux",
        target_under_test = name + "_linux_bundle",
        platform = "linux",
        library = "libadd.so",
    )
    flutter_windows_bundle_rule(
        name = name + "_windows_bundle",
        application = name + "_desktop_app",
        runner = name + "_runner",
        tags = ["manual"],
    )
    _windows_test(
        name = name + "_windows",
        target_under_test = name + "_windows_bundle",
        platform = "windows",
        library = "libadd.so",
    )

    native.test_suite(name = name, tests = [
        name + "_macos",
        name + "_ios",
        name + "_linux",
        name + "_windows",
    ])
