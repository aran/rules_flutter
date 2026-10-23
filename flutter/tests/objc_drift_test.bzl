"""Drift guard: the ObjC registrant must match the flutter tool byte-for-byte.

`plugin_registrant_test.bzl` covers the registrant builders structurally
(empty set, several plugins, exclusions) with plain Starlark asserts. This
suite covers what those cannot: that the bytes equal what the pinned
flutter tool renders from its own
`packages/flutter_tools/lib/src/flutter_plugins.dart` templates. The Dart
test reads that file from `@flutter_dev_root`, renders both template
constants with the tool's mustache semantics, and compares against the
rule's outputs — so a template change in a toolchain bump fails here
instead of shipping a registrant the tool would not recognize.

The suite also proves the documented `objc_library` consumption (the
`hdrs`/`srcs` output groups plus `includes`) analyzes, and that
`flutter_ios_app` forwards `exclude_plugins` to its internal registrant.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_dart//dart:defs.bzl", "dart_test")
load("//flutter:ios.bzl", "flutter_ios_app", "flutter_ios_registrant_gen")
load(":apple_bundling.bzl", "fake_application")

# The fixture plugin set, sorted the way fake_application sorts it.
_DRIFT_PLUGINS = {
    "path_provider_foundation": "PathProviderPlugin",
    "url_launcher_ios": "URLLauncherPlugin",
}

def _objc_library_wiring_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.true(
        env,
        len(tut[DefaultInfo].files.to_list()) > 0,
        "Expected the documented objc_library wiring to produce a library",
    )
    return analysistest.end(env)

_objc_library_wiring_test = analysistest.make(_objc_library_wiring_test_impl)

def objc_drift_test_suite(name):
    """Declares the ObjC drift fixtures and the tests over them.

    Args:
        name: Prefix for every target declared here.
    """
    fake_application(
        name = name + "_app",
        debug = True,
        extra_plugins = _DRIFT_PLUGINS,
        tags = ["manual"],
    )

    # Two-plugin and empty ObjC registrants: the Dart test compares both
    # (plus the header) against the tool's own rendering.
    flutter_ios_registrant_gen(
        name = name + "_objc",
        application = ":" + name + "_app",
        language = "objc",
        tags = ["manual"],
    )
    flutter_ios_registrant_gen(
        name = name + "_empty",
        application = ":" + name + "_app",
        language = "objc",
        exclude_plugins = sorted(_DRIFT_PLUGINS.keys()),
        tags = ["manual"],
    )

    # The documented Tier-2 consumption: the output groups split the pair
    # back into headers and sources for an objc_library, and `includes`
    # names the registrant's output directory so other sources can use
    # `#import "GeneratedPluginRegistrant.h"`.
    native.filegroup(
        name = name + "_objc_hdrs",
        srcs = [":" + name + "_objc"],
        output_group = "hdrs",
        tags = ["manual"],
    )
    native.filegroup(
        name = name + "_objc_srcs",
        srcs = [":" + name + "_objc"],
        output_group = "srcs",
        tags = ["manual"],
    )
    native.filegroup(
        name = name + "_empty_srcs",
        srcs = [":" + name + "_empty"],
        output_group = "srcs",
        tags = ["manual"],
    )
    objc_library(
        name = name + "_lib",
        hdrs = [":" + name + "_objc_hdrs"],
        srcs = [":" + name + "_objc_srcs"],
        includes = [name + "_objc"],
        tags = ["manual"],
    )
    _objc_library_wiring_test(
        name = name + "_lib_wiring",
        target_under_test = ":" + name + "_lib",
    )

    # An app excluding one fixture plugin: the Dart test reads its internal
    # Swift registrant and proves the exclusion arrived there.
    excl_app = name + "_excl_app"
    flutter_ios_app(
        name = excl_app,
        application = ":" + name + "_app",
        bundle_id = "com.example.drift.ios",
        srcs = [
            "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        launch_storyboard = "@rules_flutter//flutter/private/runners/ios:Base.lproj/LaunchScreen.storyboard",
        exclude_plugins = ["url_launcher_ios"],
        entitlements = False,
        app_icons = [],
        tags = ["manual"],
    )
    dart_test(
        name = name + "_test",
        size = "small",
        args = [
            "$(rlocationpaths @flutter_dev_root//:flutter_plugins_dart)",
            "$(rlocationpaths :%s_objc_hdrs)" % name,
            "$(rlocationpaths :%s_objc_srcs)" % name,
            "$(rlocationpaths :%s_empty_srcs)" % name,
            "$(rlocationpaths :__%s_registrant)" % excl_app,
        ],
        data = [
            "@flutter_dev_root//:flutter_plugins_dart",
            ":" + name + "_objc_hdrs",
            ":" + name + "_objc_srcs",
            ":" + name + "_empty_srcs",
            ":__%s_registrant" % excl_app,
        ],
        main = "objc_registrant_drift_test.dart",
        deps = [
            "@dev_tool_deps//:test",
            "@rules_dart//dart/runfiles",
        ],
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_lib_wiring",
            ":" + name + "_test",
        ],
    )
