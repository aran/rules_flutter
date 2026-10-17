"""Unit and analysis tests for iOS application validation and bundling."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:ios.bzl", "flutter_apple_plugin_library", "flutter_ios_app")
load("//flutter/private:flutter_ios_application.bzl", "flutter_ios_framework", "flutter_ios_native_frameworks")
load("//flutter/private:flutter_xtool_bundle.bzl", "flutter_darwin_xcframework_import", "flutter_xtool_ios_bundle")
load("//flutter/private:ios_entitlements.bzl", "resolve_ios_entitlements")
load(":apple_bundling.bzl", "fake_application", "fake_macho_binary", "fake_xcframework", "outputs_under_target_dir_test")

def _ios_device_transition_impl(_settings, _attr):
    return {
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
        "//flutter/settings:apple_backend": "xtool",
    }

_ios_device_transition = transition(
    implementation = _ios_device_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//flutter/settings:apple_backend",
    ],
)

def _platform_target_impl(ctx):
    files = []
    for t in ctx.attr.targets:
        files.append(t[DefaultInfo].files)
    return [DefaultInfo(files = depset(transitive = files))]

_ios_device_targets = rule(
    implementation = _platform_target_impl,
    attrs = {
        "targets": attr.label_list(cfg = _ios_device_transition, mandatory = True),
    },
)

def _simulator_fastbuild_refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        "The iOS simulator runs debug builds only, and this is a fastbuild build.",
    )
    return analysistest.end(env)

_simulator_fastbuild_refused_test = analysistest.make(
    _simulator_fastbuild_refused_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:compilation_mode": "fastbuild",
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_x64")),
        str(Label("//flutter:profile")): False,
    },
)

_DISCOVERED = "ios/Runner/Runner.entitlements"

def _resolve_test_impl(ctx):
    env = unittest.begin(ctx)

    # Said nothing: the app ships what `flutter create` and Xcode left on disk.
    asserts.equals(
        env,
        _DISCOVERED,
        resolve_ios_entitlements(None, discovered = _DISCOVERED),
        "an unset attribute ships the discovered file",
    )

    # Said nothing, and there is nothing: a capability-less app, which is the
    # common iOS case and not an error.
    asserts.equals(
        env,
        None,
        resolve_ios_entitlements(None, discovered = None),
        "an app with no entitlements file ships none",
    )

    # Said "none": the device build whose profile cannot grant what the file
    # asks for. The file stays on disk for the targets that can use it.
    asserts.equals(
        env,
        None,
        resolve_ios_entitlements(False, discovered = _DISCOVERED),
        "False ships none although the file exists",
    )

    # Named one: an override beats both discovery and its absence.
    asserts.equals(
        env,
        "//other:entitlements",
        resolve_ios_entitlements("//other:entitlements", discovered = _DISCOVERED),
        "an explicit label wins over the discovered file",
    )
    asserts.equals(
        env,
        "//other:entitlements",
        resolve_ios_entitlements("//other:entitlements", discovered = None),
        "an explicit label is used when there is nothing to discover",
    )

    return unittest.end(env)

_resolve_test = unittest.make(_resolve_test_impl)


def _xtool_ios_app_actions_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)
    mnemonics = [a.mnemonic for a in actions]
    asserts.true(
        env,
        "FlutterXtoolRunner" in mnemonics,
        "Expected FlutterXtoolRunner action in flutter_ios_app, got: %s" % mnemonics,
    )
    asserts.true(
        env,
        "FlutterXtoolIosBundle" in mnemonics,
        "Expected FlutterXtoolIosBundle action in flutter_ios_app, got: %s" % mnemonics,
    )
    runner_actions = [a for a in actions if a.mnemonic == "FlutterXtoolRunner"]
    runner_inputs = [f.short_path for f in runner_actions[0].inputs.to_list()]
    asserts.true(
        env,
        any([p.endswith("AppDelegate.swift") for p in runner_inputs]),
        "Expected AppDelegate.swift in FlutterXtoolRunner inputs, got: %s" % runner_inputs,
    )
    asserts.true(
        env,
        any([p.endswith("_native_plugin_registrant.swift") for p in runner_inputs]),
        "Expected GeneratedPluginRegistrant.swift in FlutterXtoolRunner inputs, got: %s" % runner_inputs,
    )
    asserts.true(
        env,
        any([p.endswith(".modulemap") for p in runner_inputs]),
        "Expected plugin .modulemap in FlutterXtoolRunner inputs, got: %s" % runner_inputs,
    )
    files = tut[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(files))
    asserts.true(env, files[0].short_path.endswith(".ipa"))
    return analysistest.end(env)

_xtool_ios_app_actions_test = analysistest.make(_xtool_ios_app_actions_test_impl)

# -- Bundling ------------------------------------------------------------------

def _bundling_tests(name):
    """Declare the bundling fixtures and the tests over them.

    Args:
      name: Prefix for every target declared here.

    Returns:
      The test target names.
    """

    for app in ["_fake_app", "_fake_app_other"]:
        fake_application(
            name = name + app,
            debug = True,
            tags = ["manual"],
        )
        flutter_ios_framework(
            name = name + app + "_framework",
            application = name + app,
            tags = ["manual"],
        )

    # Release-mode fixture with a synthetic Mach-O AOT dylib and native dylib,
    # transitioned to //flutter/platforms:ios_arm64 so `FlutterIOSRetagDylib`
    # and `FlutterIOSNativeAssetFramework` run via `macho_edit.dart` on both
    # Linux and macOS hosts.
    fake_application(
        name = name + "_fake_release_app",
        debug = False,
        macho_aot = True,
        native_libs = ["libfoo.dylib"],
        code_assets = ["libbar.dylib"],
        tags = ["manual"],
    )
    flutter_ios_framework(
        name = name + "_fake_release_app_framework",
        application = name + "_fake_release_app",
        tags = ["manual"],
    )
    flutter_ios_native_frameworks(
        name = name + "_fake_release_app_native_frameworks",
        application = name + "_fake_release_app",
        tags = ["manual"],
    )
    fake_macho_binary(
        name = name + "_fake_ios_runner_bin",
        platform = "ios",
        tags = ["manual"],
    )
    flutter_darwin_xcframework_import(
        name = name + "_fake_xcframework_import",
        xcframework_imports = [name + "_fake_ios_runner_bin"],
        framework_name = "Flutter",
        tags = ["manual"],
    )
    flutter_xtool_ios_bundle(
        name = name + "_fake_xtool_ios_bundle",
        app_name = "Runner",
        bundle_id = "com.example.runner",
        executable = name + "_fake_ios_runner_bin",
        frameworks = [
            name + "_fake_release_app_framework",
            name + "_fake_release_app_native_frameworks",
        ],
        tags = ["manual"],
    )
    fake_xcframework(
        name = name + "_fake_ios_xcframework",
        framework_name = "Flutter",
        platform = "ios",
        tags = ["manual"],
    )
    write_file(
        name = name + "_sample_ios_plugin_swift",
        out = name + "_SampleIosPlugin.swift",
        content = ["import Flutter", "public class SampleIosPlugin {}"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_sample_ios_plugin_hdr",
        out = name + "_SampleIosPlugin.h",
        content = ["#pragma once"],
        tags = ["manual"],
    )
    flutter_apple_plugin_library(
        name = name + "_sample_ios_plugin_lib",
        srcs = [
            ":" + name + "_sample_ios_plugin_swift",
            ":" + name + "_sample_ios_plugin_hdr",
        ],
        module_name = "sample_ios_plugin",
        platform = "ios",
        engine = ":" + name + "_fake_ios_xcframework",
        tags = ["manual"],
    )
    flutter_ios_app(
        name = name + "_e2e_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.e2e.ios",
        srcs = [
            "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        runner_deps = [":" + name + "_sample_ios_plugin_lib"],
        backend = "xtool",
        tags = ["manual"],
    )
    _ios_device_targets(
        name = name + "_release_device_targets",
        targets = [
            name + "_fake_release_app_framework",
            name + "_fake_release_app_native_frameworks",
            name + "_fake_xcframework_import",
            name + "_fake_xtool_ios_bundle",
            name + "_sample_ios_plugin_lib",
            name + "_e2e_ios_app",
        ],
        tags = ["manual"],
    )

    outputs_under_target_dir_test(
        name = name + "_framework_outputs_under_target_dir",
        target_under_test = name + "_fake_app_framework",
    )

    _simulator_fastbuild_refused_test(
        name = name + "_simulator_fastbuild_refused",
        target_under_test = name + "_fake_release_app_framework",
    )

    # Two different apps in one package, built together: any output the two
    # declare under one name conflicts. A pair built from the same application
    # would not — Bazel shares identical actions.
    build_test(
        name = name + "_two_apps_one_package",
        targets = [
            name + "_fake_app_framework",
            name + "_fake_app_other_framework",
            name + "_release_device_targets",
        ],
    )

    _xtool_ios_app_actions_test(
        name = name + "_xtool_ios_app_actions",
        target_under_test = name + "_e2e_ios_app",
    )

    return [
        name + "_framework_outputs_under_target_dir",
        name + "_simulator_fastbuild_refused",
        name + "_xtool_ios_app_actions",
        name + "_two_apps_one_package",
    ]

def ios_test_suite(name):
    """Declares the iOS entitlement and bundling tests.

    Args:
        name: The test_suite name.
    """
    _resolve_test(name = name + "_resolve")
    native.test_suite(
        name = name,
        tests = [":" + t for t in [name + "_resolve"] + _bundling_tests(name)],
    )
