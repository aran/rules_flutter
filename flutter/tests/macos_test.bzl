"""Unit and analysis tests for macOS application validation and bundling."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter:providers.bzl", "FlutterDarwinFrameworkInfo")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:macos.bzl", "flutter_apple_plugin_library", "flutter_macos_app")
load("//flutter/private:flutter_macos_application.bzl", "flutter_macos_framework", "flutter_macos_native_libs")
load("//flutter/private:flutter_xtool_bundle.bzl", "flutter_xtool_macos_bundle")
load("//flutter/private:validation.bzl", "is_valid_bundle_id", "minimum_os_version_is_below")
load(":apple_bundling.bzl", "fake_application", "fake_macho_binary", "fake_xcframework", "outputs_under_target_dir_test")

def _macos_arm64_transition_impl(_settings, _attr):
    return {
        "//command_line_option:platforms": str(Label("//flutter/platforms:macos_arm64")),
        "//flutter/settings:apple_backend": "xtool",
    }

_macos_arm64_transition = transition(
    implementation = _macos_arm64_transition_impl,
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

_macos_arm64_targets = rule(
    implementation = _platform_target_impl,
    attrs = {
        "targets": attr.label_list(cfg = _macos_arm64_transition, mandatory = True),
    },
)

def _valid_bundle_id_test_impl(ctx):
    env = unittest.begin(ctx)

    valid_ids = [
        "com.example.myapp",
        "com.example.my-app",
        "org.flutter.test123",
        "io.bazel.rules.flutter",
    ]
    for bid in valid_ids:
        asserts.true(env, is_valid_bundle_id(bid), "Expected '%s' to be valid" % bid)

    return unittest.end(env)

def _invalid_bundle_id_test_impl(ctx):
    env = unittest.begin(ctx)

    invalid_ids = [
        "com.example/myapp",
        "com.example my app",
        "com.example:myapp",
        "com.example@myapp",
    ]
    for bid in invalid_ids:
        asserts.false(env, is_valid_bundle_id(bid), "Expected '%s' to be invalid" % bid)

    return unittest.end(env)

def _bundle_id_segment_validation_test_impl(ctx):
    """Bundle IDs must have ≥2 dot-separated segments and no structural issues."""
    env = unittest.begin(ctx)

    # Empty string is invalid.
    asserts.false(env, is_valid_bundle_id(""), "Empty string should be invalid")

    # Single segment (no dots) is invalid.
    asserts.false(env, is_valid_bundle_id("myapp"), "Single segment 'myapp' should be invalid")

    # Leading dot is invalid.
    asserts.false(env, is_valid_bundle_id(".com.example"), "Leading dot should be invalid")

    # Trailing dot is invalid.
    asserts.false(env, is_valid_bundle_id("com.example."), "Trailing dot should be invalid")

    # Consecutive dots are invalid.
    asserts.false(env, is_valid_bundle_id("com..example"), "Consecutive dots should be invalid")

    # Two segments is the minimum valid.
    asserts.true(env, is_valid_bundle_id("com.example"), "Two segments should be valid")

    return unittest.end(env)

# The engine these rules vend is a prebuilt framework with a minimum of its
# own, and the constant is both the default and the floor. Compared segment by
# segment, because macOS spent years in the range where string order and
# version order disagree.
def _minimum_os_version_floor_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.true(env, minimum_os_version_is_below("14.0", "15.0"), "14.0 < 15.0")
    asserts.false(env, minimum_os_version_is_below("15.0", "15.0"), "equal is not below")
    asserts.false(env, minimum_os_version_is_below("16.2", "15.0"), "16.2 > 15.0")

    # "10.9" sorts above "10.14" as text and below it as a version — the whole
    # reason this is not a string comparison.
    asserts.true(env, minimum_os_version_is_below("10.9", "10.14"), "10.9 < 10.14")
    asserts.false(env, minimum_os_version_is_below("10.14", "10.9"), "10.14 > 10.9")

    # A version written short means the same version.
    asserts.false(env, minimum_os_version_is_below("15", "15.0"), "15 == 15.0")
    asserts.false(env, minimum_os_version_is_below("15.0.0", "15"), "15.0.0 == 15")

    return unittest.end(env)

_t0_test = unittest.make(_valid_bundle_id_test_impl)
_t1_test = unittest.make(_invalid_bundle_id_test_impl)
_t2_test = unittest.make(_bundle_id_segment_validation_test_impl)
_t3_test = unittest.make(_minimum_os_version_floor_test_impl)

# -- Bundling ------------------------------------------------------------------
#
# rules_apple places what `additional_contents` hands it under the directory
# that holds it, relative to its owning package. So the App.framework wrapper
# and the native-library staging are each a directory at the package root,
# named after its target so that two apps in one package cannot both declare
# it, with the layout the bundle needs inside it.

def _native_libs_staged_test_impl(ctx):
    """Every library is copied to its basename in one package-root directory."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    outputs = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(outputs), "expected one staged directory, got %s" % outputs)
    if len(outputs) != 1:
        return analysistest.end(env)
    staged = outputs[0]
    asserts.true(env, staged.is_directory, "%s is not a tree artifact" % staged.path)
    asserts.equals(
        env,
        "/".join([p for p in [target.label.package, target.label.name] if p]),
        staged.short_path,
        "the staged directory must sit at its package root, named after its target",
    )

    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterMacOSNativeLibs"
    ]
    asserts.equals(env, 1, len(actions), "expected one staging action")
    if len(actions) != 1:
        return analysistest.end(env)
    argv = actions[0].argv
    pairs = argv[argv.index(staged.path) + 1:]
    sources = pairs[0::2]
    fake_prefix = "/%s/" % ctx.attr.fake_application_name
    asserts.equals(
        env,
        ctx.attr.expected_sources,
        [path.split(fake_prefix, 1)[1] for path in sources],
        "each library once, deduplicated by path, in arrival order",
    )
    asserts.equals(env, ctx.attr.expected_basenames, pairs[1::2])
    asserts.equals(
        env,
        sorted(sources),
        sorted([f.path for f in actions[0].inputs.to_list() if f.path.endswith(".dylib")]),
        "the action's .dylib inputs must be exactly the libraries it copies",
    )
    return analysistest.end(env)

_native_libs_staged_test = analysistest.make(
    _native_libs_staged_test_impl,
    attrs = {
        "expected_basenames": attr.string_list(mandatory = True),
        "expected_sources": attr.string_list(mandatory = True),
        "fake_application_name": attr.string(mandatory = True),
    },
)

def _native_libs_empty_test_impl(ctx):
    """An app with no native libraries gets nothing to bundle, and no action."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, [], target[DefaultInfo].files.to_list())
    asserts.equals(env, [], analysistest.target_actions(env))
    return analysistest.end(env)

_native_libs_empty_test = analysistest.make(_native_libs_empty_test_impl)

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_substrings": attr.string_list(mandatory = True),
    },
)


def _xtool_macos_app_actions_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)
    mnemonics = [a.mnemonic for a in actions]
    asserts.true(
        env,
        "FlutterXtoolRunner" in mnemonics,
        "Expected FlutterXtoolRunner action in flutter_macos_app, got: %s" % mnemonics,
    )
    asserts.true(
        env,
        "FlutterXtoolMacosBundle" in mnemonics,
        "Expected FlutterXtoolMacosBundle action in flutter_macos_app, got: %s" % mnemonics,
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
    asserts.true(env, files[0].short_path.endswith(".app.zip"))
    return analysistest.end(env)

_xtool_macos_app_actions_test = analysistest.make(_xtool_macos_app_actions_test_impl)

def _bundling_tests(name):
    """Declare the bundling fixtures and the tests over them.

    Args:
      name: Prefix for every target declared here.

    Returns:
      The test target names.
    """
    staged_app = name + "_fake_app"
    fake_application(
        name = staged_app,
        # `libadd` arrives by both routes. `libsub` is the case the staging
        # exists for: a library that is not at the root of its package.
        native_libs = ["libadd.dylib", "vendor/lib/libsub.dylib"],
        code_assets = ["libadd.dylib", "assets/libasset.dylib"],
        tags = ["manual"],
    )
    flutter_macos_native_libs(
        name = name + "_native_libs",
        application = staged_app,
        tags = ["manual"],
    )
    _native_libs_staged_test(
        name = name + "_native_libs_staged",
        target_under_test = name + "_native_libs",
        fake_application_name = staged_app,
        expected_sources = ["libadd.dylib", "vendor/lib/libsub.dylib", "assets/libasset.dylib"],
        expected_basenames = ["libadd.dylib", "libsub.dylib", "libasset.dylib"],
    )

    fake_application(
        name = name + "_fake_app_empty",
        tags = ["manual"],
    )
    flutter_macos_native_libs(
        name = name + "_native_libs_empty",
        application = name + "_fake_app_empty",
        tags = ["manual"],
    )
    _native_libs_empty_test(
        name = name + "_native_libs_nothing_to_bundle",
        target_under_test = name + "_native_libs_empty",
    )

    # Two different libraries that would both be Contents/Frameworks/libdup.dylib.
    fake_application(
        name = name + "_fake_app_duplicate",
        native_libs = ["one/libdup.dylib"],
        code_assets = ["two/libdup.dylib"],
        tags = ["manual"],
    )
    flutter_macos_native_libs(
        name = name + "_native_libs_duplicate",
        application = name + "_fake_app_duplicate",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_native_libs_duplicate_basename_fails",
        target_under_test = name + "_native_libs_duplicate",
        expected_substrings = [
            "bundled as Contents/Frameworks/libdup.dylib",
            "_fake_app_duplicate/one/libdup.dylib",
            "_fake_app_duplicate/two/libdup.dylib",
        ],
    )

    # A second, different app in the same package. Built together with the
    # first, any output the two declare under one name conflicts in analysis —
    # which a pair built from the *same* application hides, because identical
    # actions are shared.
    fake_application(
        name = name + "_fake_app_other",
        native_libs = ["libadd.dylib"],
        tags = ["manual"],
    )
    for app in [staged_app, name + "_fake_app_other"]:
        flutter_macos_framework(
            name = app + "_framework",
            application = app,
            tags = ["manual"],
        )
    outputs_under_target_dir_test(
        name = name + "_framework_outputs_under_target_dir",
        target_under_test = staged_app + "_framework",
    )
    flutter_macos_native_libs(
        name = name + "_native_libs_other",
        application = name + "_fake_app_other",
        tags = ["manual"],
    )

    # Debug and release (real synthetic Mach-O AOT dylib) framework fixtures,
    # plus xtool macOS bundle assembly on any host (Linux or macOS).
    fake_application(
        name = name + "_fake_debug_app",
        debug = True,
        tags = ["manual"],
    )
    flutter_macos_framework(
        name = name + "_fake_debug_app_framework",
        application = name + "_fake_debug_app",
        tags = ["manual"],
    )
    fake_application(
        name = name + "_fake_release_macho_app",
        debug = False,
        macho_aot = True,
        tags = ["manual"],
    )
    flutter_macos_framework(
        name = name + "_fake_release_macho_app_framework",
        application = name + "_fake_release_macho_app",
        tags = ["manual"],
    )
    fake_macho_binary(
        name = name + "_fake_macos_runner_bin",
        platform = "macos",
        tags = ["manual"],
    )
    flutter_xtool_macos_bundle(
        name = name + "_fake_xtool_macos_bundle",
        app_name = "Runner",
        bundle_id = "com.example.runner",
        executable = name + "_fake_macos_runner_bin",
        frameworks = [name + "_fake_release_macho_app_framework"],
        native_libs = [name + "_native_libs"],
        tags = ["manual"],
    )
    fake_xcframework(
        name = name + "_fake_macos_xcframework",
        framework_name = "FlutterMacOS",
        platform = "macos",
        tags = ["manual"],
    )
    write_file(
        name = name + "_sample_macos_plugin_swift",
        out = name + "_SampleMacosPlugin.swift",
        content = ["import FlutterMacOS", "public class SampleMacosPlugin {}"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_sample_macos_plugin_hdr",
        out = name + "_SampleMacosPlugin.h",
        content = ["#pragma once"],
        tags = ["manual"],
    )
    flutter_apple_plugin_library(
        name = name + "_sample_macos_plugin_lib",
        srcs = [
            ":" + name + "_sample_macos_plugin_swift",
            ":" + name + "_sample_macos_plugin_hdr",
        ],
        module_name = "sample_macos_plugin",
        platform = "macos",
        engine = ":" + name + "_fake_macos_xcframework",
        tags = ["manual"],
    )
    write_file(
        name = name + "_sample_macos_entitlements",
        out = name + "_DebugProfile.entitlements",
        content = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>',
        ],
        tags = ["manual"],
    )
    flutter_macos_app(
        name = name + "_e2e_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.e2e.macos",
        srcs = [
            "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        menu_xib = "@rules_flutter//flutter/private/runners/macos:MainMenu.xib",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        runner_deps = [":" + name + "_sample_macos_plugin_lib"],
        backend = "xtool",
        tags = ["manual"],
    )
    _macos_arm64_targets(
        name = name + "_macos_arm64_release_targets",
        targets = [
            name + "_fake_debug_app_framework",
            name + "_fake_release_macho_app_framework",
            name + "_fake_xtool_macos_bundle",
            name + "_sample_macos_plugin_lib",
            name + "_e2e_macos_app",
        ],
        tags = ["manual"],
    )

    build_test(
        name = name + "_two_apps_one_package",
        targets = [
            staged_app + "_framework",
            name + "_fake_app_other_framework",
            name + "_native_libs",
            name + "_native_libs_other",
            name + "_macos_arm64_release_targets",
        ],
    )

    _xtool_macos_app_actions_test(
        name = name + "_xtool_macos_app_actions",
        target_under_test = name + "_e2e_macos_app",
    )

    return [
        name + "_framework_outputs_under_target_dir",
        name + "_native_libs_staged",
        name + "_native_libs_nothing_to_bundle",
        name + "_native_libs_duplicate_basename_fails",
        name + "_xtool_macos_app_actions",
        name + "_two_apps_one_package",
    ]

def macos_test_suite(name):
    unittest.suite(name + "_bundle_id", _t0_test, _t1_test, _t2_test)
    unittest.suite(name + "_minimum_os_version", _t3_test)
    native.test_suite(
        name = name,
        tests = [
            ":" + t
            for t in [name + "_bundle_id", name + "_minimum_os_version"] +
                     _bundling_tests(name)
        ],
    )
