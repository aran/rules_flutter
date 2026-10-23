"""Unit and analysis tests for macOS application validation and bundling."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_apple//apple:providers.bzl", "AppleBundleInfo")
load("@rules_apple//apple:versioning.bzl", "apple_bundle_version")
load("@rules_dart//dart:defs.bzl", "dart_test")
load(
    "//flutter:macos.bzl",
    "flutter_apple_plugin_library",
    "flutter_macos_app",
    "flutter_macos_engine",
    "flutter_macos_framework_gen",
    "flutter_macos_registrant_gen",
    "flutter_macos_runner_lib_gen",
)
load("//flutter:providers.bzl", "FlutterDarwinFrameworkInfo")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load("//flutter/private:flutter_macos_application.bzl", "flutter_macos_framework", "flutter_macos_native_libs")
load("//flutter/private:flutter_xtool_bundle.bzl", "flutter_darwin_xcframework_import", "flutter_xtool_macos_bundle")
load("//flutter/private:validation.bzl", "is_valid_bundle_id", "minimum_os_version_is_below")
load(":apple_bundling.bzl", "fake_application", "fake_macho_binary", "fake_xcframework", "macho_verify_probe", "outputs_under_target_dir_test")

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
    direct = []
    files = []
    for t in ctx.attr.targets:
        files.append(t[DefaultInfo].files)
        if AppleBundleInfo in t and t[AppleBundleInfo].archive != None:
            direct.append(t[AppleBundleInfo].archive)
    return [DefaultInfo(files = depset(direct, transitive = files))]

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
# that holds it, relative to its owning package. App.framework travels as its
# deterministic App.framework.zip (merged from `AppleBundleInfo.archive`, so
# the version links survive), while the native-library staging is a directory
# at the package root, named after its target so that two apps in one package
# cannot both declare it, with the layout the bundle needs inside it.

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
    runner_argv = runner_actions[0].argv
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
    asserts.true(
        env,
        "--sdk-framework" in runner_argv and "AVFoundation" in runner_argv,
        "Expected --sdk-framework AVFoundation in FlutterXtoolRunner argv, got: %s" % runner_argv,
    )
    asserts.true(
        env,
        "--sdk-dylib" in runner_argv and "sqlite3" in runner_argv,
        "Expected --sdk-dylib sqlite3 in FlutterXtoolRunner argv, got: %s" % runner_argv,
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
    macho_verify_probe(
        name = name + "_verify_debug_stub_framework",
        target = ":" + name + "_fake_debug_app_framework",
        binary_relpath = "App.framework/Versions/A/App",
        expected_substrings = [
            "NOUNDEFS",
            "DYLDLINK",
            "TWOLEVEL",
            "NO_REEXPORTED_DYLIBS",
            "segname __TEXT",
            "segname __LINKEDIT",
            "cmd LC_ID_DYLIB",
            "@rpath/App.framework/Versions/A/App",
            "cmd LC_SYMTAB",
            "cmd LC_DYSYMTAB",
            "cmd LC_UUID",
            "cmd LC_BUILD_VERSION",
            "platform macos",
        ],
        tags = ["manual"],
    )
    fake_application(
        name = name + "_fake_release_macho_app",
        debug = False,
        macho_aot = True,
        native_libs = ["libplugin.dylib"],
        tags = ["manual"],
    )
    flutter_macos_framework(
        name = name + "_fake_release_macho_app_framework",
        application = name + "_fake_release_macho_app",
        tags = ["manual"],
    )
    fake_application(
        name = name + "_fake_fat_macos_app",
        debug = False,
        fat_macho = True,
        macho_aot = True,
        native_libs = ["libfat.dylib"],
        tags = ["manual"],
    )
    flutter_macos_framework(
        name = name + "_fake_fat_macos_app_framework",
        application = name + "_fake_fat_macos_app",
        minimum_os_version = "14.2",
        tags = ["manual"],
    )
    flutter_macos_native_libs(
        name = name + "_fake_fat_macos_native_libs",
        application = name + "_fake_fat_macos_app",
        minimum_os_version = "14.2",
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_verify_fat_macos_framework",
        target = ":" + name + "_fake_fat_macos_app_framework",
        binary_relpath = "App.framework/Versions/A/App",
        expected_substrings = [
            "platform macos",
            "minos 14.2",
            "sdk 14.2",
            "@rpath/App.framework/Versions/A/App",
        ],
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_verify_fat_macos_native_libs",
        target = ":" + name + "_fake_fat_macos_native_libs",
        binary_relpath = "libfat.dylib",
        expected_substrings = [
            "platform macos",
            "minos 14.2",
            "sdk 14.2",
        ],
        tags = ["manual"],
    )
    fake_macho_binary(
        name = name + "_fake_macos_runner_bin",
        platform = "macos",
        tags = ["manual"],
    )
    write_file(
        name = name + "_fake_xtool_cert",
        out = name + "_fake_xtool_cert.p12",
        content = ["fake-p12"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_fake_xtool_zsign",
        out = name + "_fake_xtool_zsign.sh",
        content = [
            "#!/bin/sh",
            'pw=""',
            'prev=""',
            'last=""',
            'for arg in "$@"; do',
            '  if [ "$prev" = "-p" ]; then pw="$arg"; fi',
            '  prev="$arg"',
            '  last="$arg"',
            "done",
            'mkdir -p "$last/Contents/_CodeSignature"',
            'printf "pw=%s\\ntmpdir=%s\\ntest_tmpdir=%s\\n" "$pw" "${TMPDIR:-}" "${TEST_TMPDIR:-}" > "$last/Contents/_CodeSignature/CodeResources"',
        ],
        is_executable = True,
        tags = ["manual"],
    )
    flutter_xtool_macos_bundle(
        name = name + "_fake_xtool_macos_bundle",
        app_name = "Runner",
        bundle_id = "com.example.runner",
        executable = name + "_fake_macos_runner_bin",
        frameworks = [name + "_fake_release_macho_app_framework"],
        native_libs = [name + "_native_libs"],
        certificate = ":" + name + "_fake_xtool_cert",
        certificate_password_env = "TMPDIR",
        zsign = ":" + name + "_fake_xtool_zsign",
        tags = ["manual"],
    )
    flutter_xtool_macos_bundle(
        name = name + "_fake_xtool_macos_bundle_alt",
        app_name = "Runner",
        bundle_id = "com.example.runner",
        executable = name + "_fake_macos_runner_bin",
        frameworks = [name + "_fake_release_macho_app_framework"],
        native_libs = [name + "_native_libs"],
        certificate = ":" + name + "_fake_xtool_cert",
        certificate_password_env = "TMPDIR",
        zsign = ":" + name + "_fake_xtool_zsign",
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
    fake_xcframework(
        name = name + "_fake_macos_plugin_kit_xcframework",
        framework_name = "PluginKit",
        platform = "macos",
        tags = ["manual"],
    )
    flutter_darwin_xcframework_import(
        name = name + "_fake_macos_plugin_kit_import",
        framework_name = "PluginKit",
        xcframework_imports = [":" + name + "_fake_macos_plugin_kit_xcframework"],
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
        deps = [":" + name + "_fake_macos_plugin_kit_import"],
        sdk_frameworks = ["AVFoundation"],
        sdk_dylibs = ["sqlite3"],
        backend = "xtool",
        tags = ["manual"],
    )
    fake_application(
        name = name + "_fake_e2e_macos_app",
        debug = False,
        macho_aot = True,
        native_libs = ["libplugin.dylib"],
        apple_plugin_libraries = [":" + name + "_sample_macos_plugin_lib"],
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
        application = ":" + name + "_fake_e2e_macos_app",
        bundle_id = "com.example.e2e.macos",
        minimum_os_version = "13.4",
        srcs = [
            "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        runner_deps = [":" + name + "_sample_macos_plugin_lib"],
        backend = "xtool",
        tags = ["manual"],
    )
    flutter_macos_app(
        name = name + "_minimal_xtool_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.minimal.macos",
        srcs = [
            "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        backend = "xtool",
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_verify_minimal_xtool_macos_app_bundle",
        target = ":" + name + "_minimal_xtool_macos_app",
        binary_relpath = name + "_minimal_xtool_macos_app.app/Contents/MacOS/" + name + "_minimal_xtool_macos_app",
        expected_entries = [
            name + "_minimal_xtool_macos_app.app/Contents/MacOS/" + name + "_minimal_xtool_macos_app",
            name + "_minimal_xtool_macos_app.app/Contents/Frameworks/App.framework/Versions/A/App",
            name + "_minimal_xtool_macos_app.app/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS",
        ],
        expected_substrings = [
            "cmd LC_RPATH",
            "@executable_path/../Frameworks",
            "cmd LC_BUILD_VERSION",
            "platform macos",
        ],
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_verify_e2e_macos_app_framework",
        target = ":__" + name + "_e2e_macos_app_app_framework",
        binary_relpath = "App.framework/Versions/A/App",
        expected_substrings = [
            "platform macos",
            "minos 13.4",
            "sdk 13.4",
            "@rpath/App.framework/Versions/A/App",
        ],
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_verify_e2e_macos_native_libs",
        target = ":__" + name + "_e2e_macos_app_native_libs",
        binary_relpath = "libplugin.dylib",
        expected_substrings = [
            "platform macos",
            "minos 13.4",
            "sdk 13.4",
        ],
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_verify_e2e_macos_app_bundle",
        target = ":" + name + "_e2e_macos_app",
        binary_relpath = name + "_e2e_macos_app.app/Contents/MacOS/" + name + "_e2e_macos_app",
        expected_entries = [
            name + "_e2e_macos_app.app/Contents/MacOS/" + name + "_e2e_macos_app",
            name + "_e2e_macos_app.app/Contents/Frameworks/App.framework/Versions/A/App",
            name + "_e2e_macos_app.app/Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS",
            name + "_e2e_macos_app.app/Contents/Frameworks/PluginKit.framework/PluginKit",
            name + "_e2e_macos_app.app/Contents/Frameworks/libplugin.dylib",
        ],
        forbidden_entries = [
            name + "_e2e_macos_app.app/Contents/Resources/libplugin.dylib",
        ],
        expected_substrings = [
            "cmd LC_RPATH",
            "@executable_path/Frameworks",
            "@executable_path/../Frameworks",
            "/System/Library/Frameworks/AVFoundation.framework/Versions/A/AVFoundation",
            "/usr/lib/libsqlite3.dylib",
            "cmd LC_BUILD_VERSION",
            "platform macos",
            "minos 13.4",
        ],
        tags = ["manual"],
    )
    fake_application(
        name = name + "_fake_non_macho_app",
        debug = True,
        macho_aot = False,
        native_libs = ["libnonmacho.dylib"],
        tags = ["manual"],
    )
    flutter_macos_native_libs(
        name = name + "_fake_non_macho_native_libs",
        application = name + "_fake_non_macho_app",
        allow_non_macho = ["libnonmacho.dylib"],
        tags = ["manual"],
    )
    surface_tests = _apple_surface_tests(name)

    macho_verify_probe(
        name = name + "_verify_release_macho_app_framework",
        target = ":" + name + "_fake_release_macho_app_framework",
        binary_relpath = "App.framework/Versions/A/App",
        expected_substrings = [
            "platform macos",
            "minos 12.0",
            "sdk 12.0",
            "@rpath/App.framework/Versions/A/App",
        ],
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_verify_default_macos_app_framework",
        target = ":__" + name + "_default_macos_app_app_framework",
        binary_relpath = "App.framework/Versions/A/App",
        expected_substrings = [
            "platform macos",
            "minos 12.0",
            "sdk 12.0",
            "@rpath/App.framework/Versions/A/App",
        ],
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_verify_default_fg_framework",
        target = ":" + name + "_default_fg",
        binary_relpath = "App.framework/Versions/A/App",
        expected_substrings = [
            "platform macos",
            "minos 12.0",
            "sdk 12.0",
            "@rpath/App.framework/Versions/A/App",
        ],
        tags = ["manual"],
    )
    _macos_arm64_targets(
        name = name + "_macos_arm64_release_targets",
        targets = [
            name + "_fake_debug_app_framework",
            name + "_verify_debug_stub_framework",
            name + "_fake_release_macho_app_framework",
            name + "_verify_release_macho_app_framework",
            name + "_fake_fat_macos_app_framework",
            name + "_verify_fat_macos_framework",
            name + "_verify_fat_macos_native_libs",
            name + "_fake_non_macho_native_libs",
            name + "_fake_xtool_macos_bundle",
            name + "_fake_xtool_macos_bundle_alt",
            name + "_sample_macos_plugin_lib",
            name + "_e2e_macos_app",
            "__" + name + "_e2e_macos_app_app_framework",
            name + "_minimal_xtool_macos_app",
            name + "_verify_minimal_xtool_macos_app_bundle",
            name + "_verify_e2e_macos_app_framework",
            name + "_verify_e2e_macos_native_libs",
            name + "_verify_e2e_macos_app_bundle",
            "__" + name + "_default_macos_app_app_framework",
            name + "_verify_default_macos_app_framework",
            name + "_default_fg",
            name + "_verify_default_fg_framework",
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

    dart_test(
        name = name + "_macos_framework_layout_test",
        main = "macos_framework_layout_test.dart",
        data = [":" + name + "_macos_arm64_release_targets"],
        deps = ["@dev_tool_deps//:test"],
        target_compatible_with = HOST_COMPATIBLE,
    )

    # Regression guards: the App.framework version links travel between
    # actions as App.framework.zip, never as a tree artifact (Bazel's input
    # staging materializes directory symlinks as real directories). Each
    # framework fixture gets a provider-shape test; the xtool bundle and the
    # Mach-O probes get consumer-input tests.
    archive_tests = []
    for framework_target in [
        name + "_fake_debug_app_framework",
        name + "_fake_release_macho_app_framework",
        name + "_fake_fat_macos_app_framework",
        "__" + name + "_e2e_macos_app_app_framework",
        "__" + name + "_default_macos_app_app_framework",
        name + "_default_fg",
    ]:
        test_name = name + "_framework_archive_" + framework_target.replace(":", "").replace("__", "")
        _framework_archive_test(
            name = test_name,
            target_under_test = ":" + framework_target,
        )
        archive_tests.append(test_name)
    _xtool_bundle_framework_archive_test(
        name = name + "_xtool_bundle_framework_archive",
        target_under_test = ":" + name + "_fake_xtool_macos_bundle",
    )
    archive_tests.append(name + "_xtool_bundle_framework_archive")
    for probe_target in [
        name + "_verify_fat_macos_framework",
        name + "_verify_release_macho_app_framework",
        name + "_verify_default_macos_app_framework",
        name + "_verify_e2e_macos_app_framework",
        name + "_verify_default_fg_framework",
    ]:
        test_name = name + "_probe_inputs_" + probe_target[len(name) + 1:]
        _framework_probe_inputs_test(
            name = test_name,
            target_under_test = ":" + probe_target,
        )
        archive_tests.append(test_name)

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
        name + "_macos_framework_layout_test",
    ] + archive_tests + surface_tests + _xtool_macos_validation_tests(name)

def _macos_framework_bundle_info_test_impl(ctx):
    """flutter_macos_framework must provide AppleBundleInfo so rules_apple merges it as a zip."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.true(
        env,
        AppleBundleInfo in tut,
        "Expected AppleBundleInfo on flutter_macos_framework so rules_apple preserves symlinks",
    )
    bundle_info = tut[AppleBundleInfo]
    asserts.equals(env, "App", bundle_info.bundle_name)
    asserts.equals(env, ".framework", bundle_info.bundle_extension)
    asserts.equals(env, "App", bundle_info.executable_name)
    asserts.equals(env, "io.flutter.flutter.app", bundle_info.bundle_id)
    asserts.equals(env, "macos", bundle_info.platform_type)
    asserts.equals(env, "com.apple.product-type.framework", bundle_info.product_type)
    asserts.true(
        env,
        bundle_info.archive != None and bundle_info.archive.short_path.endswith("/App.framework.zip"),
        "Expected AppleBundleInfo.archive ending with /App.framework.zip, got: %s" % bundle_info.archive,
    )
    asserts.true(
        env,
        FlutterDarwinFrameworkInfo in tut,
        "Expected FlutterDarwinFrameworkInfo on flutter_macos_framework for xtool bundling",
    )
    return analysistest.end(env)

_macos_framework_bundle_info_test = analysistest.make(_macos_framework_bundle_info_test_impl)

def _framework_archive_test_impl(ctx):
    """flutter_macos_framework must hand consumers the archive, never the tree.

    Bazel does not preserve directory symlinks inside tree artifacts when it
    stages them as action or test inputs (a link to a directory arrives as a
    real directory), so the versioned App.framework layout travels between
    actions only as its deterministic App.framework.zip. This test fails if a
    framework tree artifact with internal directory symlinks is ever handed
    straight to a consumer again through DefaultInfo or
    FlutterDarwinFrameworkInfo.
    """
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    files = tut[DefaultInfo].files.to_list()
    for f in files:
        asserts.false(
            env,
            f.is_directory,
            "DefaultInfo must not hand out the framework tree artifact %s: " % f.path +
            "consumers would see materialized directories instead of symlinks; " +
            "hand out App.framework.zip instead",
        )
    asserts.true(
        env,
        any([f.short_path.endswith("/App.framework.zip") for f in files]),
        "Expected App.framework.zip in DefaultInfo.files, got: %s" % [f.short_path for f in files],
    )

    asserts.true(
        env,
        FlutterDarwinFrameworkInfo in tut,
        "Expected FlutterDarwinFrameworkInfo on flutter_macos_framework",
    )
    fw_info = tut[FlutterDarwinFrameworkInfo]
    for f in fw_info.framework_files.to_list():
        asserts.false(
            env,
            f.is_directory,
            "FlutterDarwinFrameworkInfo.framework_files must not contain the framework tree %s; " % f.path +
            "the xtool backend would stage it with materialized symlinks",
        )
    asserts.true(
        env,
        fw_info.framework_dir != None and fw_info.framework_dir.endswith("App.framework.zip"),
        "Expected FlutterDarwinFrameworkInfo.framework_dir at App.framework.zip, got: %s" % fw_info.framework_dir,
    )
    return analysistest.end(env)

_framework_archive_test = analysistest.make(_framework_archive_test_impl)

def _xtool_bundle_framework_archive_test_impl(ctx):
    """The xtool bundle/runner actions must take the framework archive, not the tree.

    Both the FlutterXtoolMacosBundle embed step and the FlutterXtoolRunner
    link step receive `--framework` paths for every entry of `frameworks`.
    This test fails if App.framework ever reaches either action as a staged
    tree artifact directory again: only the `.framework.zip` archive (which
    the tool extracts locally with real symlinks) or a non-tree input may.
    """
    env = analysistest.begin(ctx)
    saw_archive = False
    for action in analysistest.target_actions(env):
        if action.mnemonic not in ("FlutterXtoolMacosBundle", "FlutterXtoolRunner"):
            continue
        argv = action.argv
        for idx, arg in enumerate(argv):
            if arg == "--framework" and argv[idx + 1].endswith(".framework.zip"):
                saw_archive = True
        for f in action.inputs.to_list():
            asserts.false(
                env,
                f.is_directory and "App.framework" in f.path,
                "%s takes the framework tree %s as an input: " % (action.mnemonic, f.path) +
                "staging would materialize its symlinks; take App.framework.zip instead",
            )
    asserts.true(
        env,
        saw_archive,
        "Expected a --framework App.framework.zip argument on the xtool bundle/runner actions",
    )
    return analysistest.end(env)

_xtool_bundle_framework_archive_test = analysistest.make(_xtool_bundle_framework_archive_test_impl)

def _framework_probe_inputs_test_impl(ctx):
    """A Mach-O verify probe over a framework must not take a tree input.

    The probe reads the binary either from the staged input or from the
    `--framework-zip`; a tree input would additionally route the layout
    assertions in `verifyMacosFramework` at staged (possibly materialized)
    symlinks. Framework probes take App.framework.zip.
    """
    env = analysistest.begin(ctx)
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterMachOVerifyProbe"]
    asserts.equals(env, 1, len(actions), "expected one verify action, got %s" % [a.mnemonic for a in analysistest.target_actions(env)])
    if len(actions) != 1:
        return analysistest.end(env)
    for f in actions[0].inputs.to_list():
        asserts.false(
            env,
            f.is_directory,
            "verify probe must not take a directory input (%s): " % f.path +
            "a tree artifact's symlinks would arrive materialized at the " +
            "staged layout assertions; verify App.framework.zip instead",
        )
    return analysistest.end(env)

_framework_probe_inputs_test = analysistest.make(_framework_probe_inputs_test_impl)

def _xtool_macos_attrs_and_secrets_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    bundle_actions = [a for a in actions if a.mnemonic == "FlutterXtoolMacosBundle"]
    asserts.equals(env, 1, len(bundle_actions))
    argv = bundle_actions[0].argv
    asserts.true(
        env,
        "--version-file" in argv,
        "Expected --version-file in argv when apple_bundle_version is passed to version: %s" % argv,
    )
    asserts.true(
        env,
        "--additional-content" in argv and any([arg.startswith("Helpers=") for arg in argv]),
        "Expected --additional-content Helpers=... in argv: %s" % argv,
    )
    asserts.true(
        env,
        "--certificate-password-file" in argv,
        "Expected --certificate-password-file in argv: %s" % argv,
    )
    asserts.true(
        env,
        "--certificate-password-env" in argv and "MACOS_CERT_PW_ENV" in argv,
        "Expected --certificate-password-env MACOS_CERT_PW_ENV in argv: %s" % argv,
    )
    asserts.true(
        env,
        "MACOS_CERT_PW_ENV" in bundle_actions[0].env,
        "Expected MACOS_CERT_PW_ENV to be explicitly bound in FlutterXtoolMacosBundle action env, got: %s" % bundle_actions[0].env,
    )
    for a in actions:
        for arg in a.argv:
            asserts.false(
                env,
                "macos-secret-p12-pass" in arg,
                "Signing secret leaked onto command line of %s: %s" % (a.mnemonic, a.argv),
            )
    return analysistest.end(env)

_xtool_macos_attrs_and_secrets_test = analysistest.make(_xtool_macos_attrs_and_secrets_test_impl)

def _xtool_macos_validation_tests(name):
    write_file(
        name = name + "_xtool_macos_helper",
        out = name + "_macos_helper.txt",
        content = ["helper"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_xtool_macos_cert_pw_file",
        out = name + "_macos_cert_pw.txt",
        content = ["macos-secret-p12-pass"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_custom_menu_xib",
        out = name + "_CustomMenu.xib",
        content = ["<document/>"],
        tags = ["manual"],
    )
    apple_bundle_version(
        name = name + "_xtool_custom_macos_version",
        build_version = "99",
        short_version_string = "3.1.0",
        tags = ["manual"],
    )

    before_xtool = native.existing_rules().keys()
    xtool_attrs_app = name + "_xtool_attrs_macos_app"
    flutter_macos_app(
        name = xtool_attrs_app,
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.xtool.macos.attrs",
        version = ":" + name + "_xtool_custom_macos_version",
        srcs = [
            "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        additional_contents = {
            ":" + name + "_xtool_macos_helper": "Helpers",
        },
        certificate_password_file = ":" + name + "_xtool_macos_cert_pw_file",
        certificate_password_env = "MACOS_CERT_PW_ENV",
        backend = "xtool",
        tags = ["manual"],
    )
    flutter_macos_app(
        name = name + "_xtool_default_engine_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.xtool.macos.defaultengine",
        srcs = [
            "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        backend = "xtool",
        tags = ["manual"],
    )
    after_xtool = native.existing_rules()
    created_xtool = {
        k: after_xtool[k]["kind"]
        for k in after_xtool
        if k not in before_xtool
    }
    unexpected_rules_apple = [
        k
        for k, kind in created_xtool.items()
        if kind in (
            "macos_application",
            "apple_dynamic_framework_import",
            "apple_dynamic_xcframework_import",
            "apple_bundle_version",
        )
    ]
    _macos_macro_surface_test(
        name = name + "_xtool_macos_no_rules_apple_surface",
        expected_rules = created_xtool,
        observed_rules = created_xtool,
        unexpected_xtool_targets = unexpected_rules_apple,
        expected_app_deps = [],
        observed_app_deps = [],
    )
    _xtool_macos_attrs_and_secrets_test(
        name = name + "_xtool_macos_attrs_and_secrets",
        target_under_test = ":" + xtool_attrs_app,
    )

    # Invalid version target on xtool
    flutter_macos_app(
        name = name + "_xtool_bad_version_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.macos.badversion",
        version = ":" + name + "_xtool_macos_helper",
        srcs = ["@rules_flutter//flutter/private/runners/macos:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        backend = "xtool",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_xtool_macos_bad_version_fails",
        target_under_test = ":" + name + "_xtool_bad_version_macos_app",
        expected_substrings = ["'version'", "apple_bundle_version"],
    )

    # User-supplied menu_xib on xtool
    flutter_macos_app(
        name = name + "_xtool_menu_xib_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.menuxib",
        menu_xib = ":" + name + "_custom_menu_xib",
        srcs = ["@rules_flutter//flutter/private/runners/macos:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        backend = "xtool",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_xtool_menu_xib_fails",
        target_under_test = ":" + name + "_xtool_menu_xib_macos_app",
        expected_substrings = ["'menu_xib'", "ibtool", "Remove", "rules_apple"],
    )

    # Explicit default template menu_xib on xtool
    flutter_macos_app(
        name = name + "_xtool_default_menu_xib_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.defaultmenuxib",
        menu_xib = "@rules_flutter//flutter/private/runners/macos:MainMenu.xib",
        srcs = ["@rules_flutter//flutter/private/runners/macos:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        backend = "xtool",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_xtool_default_menu_xib_fails",
        target_under_test = ":" + name + "_xtool_default_menu_xib_macos_app",
        expected_substrings = ["'menu_xib'", "MainMenu.xib", "ibtool", "Remove", "rules_apple"],
    )

    # Discovered conventional macos/Runner/Base.lproj/MainMenu.xib on xtool
    _expect_failure_test(
        name = name + "_xtool_discovered_menu_xib_fails",
        target_under_test = "//flutter/tests/macos_xib_fixture:discovered_menu_xib_app",
        expected_substrings = [
            "'menu_xib'",
            "macos/Runner/Base.lproj/MainMenu.xib",
            "ibtool",
            "Remove",
            "rules_apple",
        ],
    )

    # app_icons on xtool
    flutter_macos_app(
        name = name + "_xtool_app_icons_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.macos.appicons",
        app_icons = [":" + name + "_xtool_macos_helper"],
        srcs = ["@rules_flutter//flutter/private/runners/macos:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        backend = "xtool",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_xtool_macos_app_icons_fails",
        target_under_test = ":" + name + "_xtool_app_icons_macos_app",
        expected_substrings = ["'app_icons'", "actool"],
    )

    # Plain-text certificate_password on xtool
    flutter_macos_app(
        name = name + "_xtool_plaintext_pw_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.macos.plaintextpw",
        certificate_password = "leaked-macos-password",
        srcs = ["@rules_flutter//flutter/private/runners/macos:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        backend = "xtool",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_xtool_macos_plaintext_pw_fails",
        target_under_test = ":" + name + "_xtool_plaintext_pw_macos_app",
        expected_substrings = ["plain-text 'certificate_password' is not supported"],
    )

    # require_sdk = True when SDK is unconfigured
    flutter_macos_app(
        name = name + "_xtool_require_sdk_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.macos.requiresdk",
        require_sdk = True,
        srcs = ["@rules_flutter//flutter/private/runners/macos:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        backend = "xtool",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_xtool_macos_require_sdk_fails",
        target_under_test = ":" + name + "_xtool_require_sdk_macos_app",
        expected_substrings = ["The xtool Darwin SDK (@flutter_xtool_darwin_sdk) is not configured"],
    )

    # Unsupported kwargs on xtool
    flutter_macos_app(
        name = name + "_xtool_unsupported_kwarg_macos_app",
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.macos.badkwarg",
        ipa_post_processor = "foo",
        srcs = ["@rules_flutter//flutter/private/runners/macos:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        entitlements = ":" + name + "_sample_macos_entitlements",
        engine = ":" + name + "_fake_macos_xcframework",
        backend = "xtool",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_xtool_macos_unsupported_kwarg_fails",
        target_under_test = ":" + name + "_xtool_unsupported_kwarg_macos_app",
        expected_substrings = ["unsupported attribute(s) 'ipa_post_processor' are not supported on the xtool backend"],
    )

    return [
        name + "_xtool_macos_no_rules_apple_surface",
        name + "_xtool_macos_attrs_and_secrets",
        name + "_xtool_macos_bad_version_fails",
        name + "_xtool_menu_xib_fails",
        name + "_xtool_default_menu_xib_fails",
        name + "_xtool_discovered_menu_xib_fails",
        name + "_xtool_macos_app_icons_fails",
        name + "_xtool_macos_plaintext_pw_fails",
        name + "_xtool_macos_require_sdk_fails",
        name + "_xtool_macos_unsupported_kwarg_fails",
    ]

def _macos_macro_surface_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ctx.attr.expected_rules, ctx.attr.observed_rules)
    asserts.equals(env, [], ctx.attr.unexpected_xtool_targets)
    asserts.equals(env, ctx.attr.expected_app_deps, ctx.attr.observed_app_deps)
    return unittest.end(env)

_macos_macro_surface_test = unittest.make(
    _macos_macro_surface_test_impl,
    attrs = {
        "expected_app_deps": attr.string_list(mandatory = True),
        "expected_rules": attr.string_dict(mandatory = True),
        "observed_app_deps": attr.string_list(mandatory = True),
        "observed_rules": attr.string_dict(mandatory = True),
        "unexpected_xtool_targets": attr.string_list(mandatory = True),
    },
)

def _apple_surface_tests(name):
    """Verify default rules_apple target names and kinds for macOS macros."""
    before = native.existing_rules().keys()

    fg_name = name + "_default_fg"
    flutter_macos_framework_gen(
        name = fg_name,
        application = ":" + name + "_fake_release_macho_app",
        tags = ["manual"],
    )

    eng_name = name + "_default_engine"
    flutter_macos_engine(
        name = eng_name,
        tags = ["manual"],
    )

    reg_name = name + "_default_registrant"
    flutter_macos_registrant_gen(
        name = reg_name,
        application = ":" + name + "_fake_release_macho_app",
        tags = ["manual"],
    )

    runner_name = name + "_default_runner_lib"
    flutter_macos_runner_lib_gen(
        name = runner_name,
        registrant = ":" + reg_name,
        engine = ":" + eng_name,
        application = ":" + name + "_fake_release_macho_app",
        tags = ["manual"],
    )

    plugin_name = name + "_default_plugin_lib"
    flutter_apple_plugin_library(
        name = plugin_name,
        srcs = [
            ":" + name + "_SampleMacosPlugin.swift",
            ":" + name + "_SampleMacosPlugin.h",
        ],
        module_name = "default_macos_plugin",
        platform = "macos",
        tags = ["manual"],
    )

    app_name = name + "_default_macos_app"
    flutter_macos_app(
        name = app_name,
        application = ":" + name + "_fake_release_macho_app",
        bundle_id = "com.example.default.macos",
        srcs = [
            "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        menu_xib = "@rules_flutter//flutter/private/runners/macos:MainMenu.xib",
        entitlements = ":" + name + "_sample_macos_entitlements",
        tags = ["manual"],
    )

    all_rules = native.existing_rules()
    new_names = sorted([k for k in all_rules.keys() if k not in before])
    observed_rules = {k: all_rules[k]["kind"] for k in new_names}

    expected_rules = {
        fg_name: "flutter_macos_framework",
        eng_name: "apple_dynamic_framework_import",
        reg_name: "flutter_macos_registrant",
        "_" + runner_name + "__apple_plugins_aggregator": "flutter_apple_plugins_aggregator",
        runner_name: "swift_library",
        "_" + plugin_name + "__flutter_framework": "apple_dynamic_framework_import",
        plugin_name: "swift_library",
        "__" + app_name + "_registrant": "flutter_macos_registrant",
        "__" + app_name + "_app_framework": "flutter_macos_framework",
        "__" + app_name + "_native_libs": "flutter_macos_native_libs",
        "__" + app_name + "_privacy_manifests": "flutter_macos_privacy_manifests",
        "__" + app_name + "_engine": "apple_dynamic_framework_import",
        "__" + app_name + "_apple_plugins": "flutter_apple_plugins_aggregator",
        "__" + app_name + "_menu_xib": "expand_template",
        "__" + app_name + "_runner": "swift_library",
        "__" + app_name + "_version": "apple_bundle_version",
        app_name: "macos_application",
    }

    unexpected_xtool = [
        k
        for k in new_names
        if "xtool" in k or "xtool" in all_rules[k]["kind"] or "darwin_xcframework" in all_rules[k]["kind"]
    ]

    app_rule = all_rules[app_name]
    observed_app_deps = sorted([str(d) for d in app_rule.get("deps", [])])
    expected_app_deps = sorted([
        ":__" + app_name + "_runner",
    ])

    surface_test_name = name + "_macos_macro_surface_test"
    _macos_macro_surface_test(
        name = surface_test_name,
        expected_rules = expected_rules,
        observed_rules = observed_rules,
        unexpected_xtool_targets = unexpected_xtool,
        expected_app_deps = expected_app_deps,
        observed_app_deps = observed_app_deps,
    )

    fg_bundle_info_test_name = name + "_default_fg_bundle_info_test"
    _macos_framework_bundle_info_test(
        name = fg_bundle_info_test_name,
        target_under_test = ":" + fg_name,
    )

    app_fw_bundle_info_test_name = name + "_default_app_framework_bundle_info_test"
    _macos_framework_bundle_info_test(
        name = app_fw_bundle_info_test_name,
        target_under_test = ":__" + app_name + "_app_framework",
    )

    return [
        surface_test_name,
        fg_bundle_info_test_name,
        app_fw_bundle_info_test_name,
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
