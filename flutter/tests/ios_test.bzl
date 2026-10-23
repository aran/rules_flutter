"""Unit and analysis tests for iOS application validation and bundling."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_apple//apple:providers.bzl", "AppleFrameworkImportInfo")
load("@rules_apple//apple:versioning.bzl", "apple_bundle_version")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load(
    "//flutter:ios.bzl",
    "flutter_apple_plugin_library",
    "flutter_ios_app",
    "flutter_ios_engine",
    "flutter_ios_framework_gen",
    "flutter_ios_registrant_gen",
    "flutter_ios_runner_lib_gen",
)
load("//flutter/private:flutter_ios_application.bzl", "flutter_ios_framework", "flutter_ios_native_frameworks")
load("//flutter/private:flutter_xtool_bundle.bzl", "flutter_darwin_xcframework_import", "flutter_xtool_ios_bundle")
load("//flutter/private:ios_entitlements.bzl", "resolve_ios_entitlements")
load(":apple_bundling.bzl", "fake_application", "fake_macho_binary", "fake_xcframework", "macho_verify_probe", "outputs_under_target_dir_test")

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

def _ios_framework_import_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)

    asserts.true(
        env,
        AppleFrameworkImportInfo in tut,
        "Expected AppleFrameworkImportInfo on %s" % tut.label,
    )
    asserts.true(
        env,
        CcInfo in tut,
        "Expected CcInfo on %s" % tut.label,
    )

    fw_imports = [
        f.short_path
        for f in tut[AppleFrameworkImportInfo].framework_imports.to_list()
    ]
    expected_prefix = ctx.attr.expected_framework_dir + "/App.framework/"
    asserts.true(
        env,
        any([p.endswith(expected_prefix + "App") for p in fw_imports]),
        "Expected %sApp in AppleFrameworkImportInfo.framework_imports, got: %s" % (expected_prefix, fw_imports),
    )
    asserts.true(
        env,
        any([p.endswith(expected_prefix + "Info.plist") for p in fw_imports]),
        "Expected %sInfo.plist in AppleFrameworkImportInfo.framework_imports, got: %s" % (expected_prefix, fw_imports),
    )

    linked_dylibs = [
        (lib.resolved_symlink_dynamic_library or lib.dynamic_library).short_path
        for li in tut[CcInfo].linking_context.linker_inputs.to_list()
        for lib in li.libraries
        if lib.dynamic_library != None
    ]
    if ctx.attr.expect_linked:
        asserts.true(
            env,
            any([p.endswith(expected_prefix + "App") for p in linked_dylibs]),
            "Expected release %sApp to be linked via CcInfo, got: %s" % (expected_prefix, linked_dylibs),
        )
    else:
        asserts.equals(
            env,
            [],
            linked_dylibs,
            "Expected debug App.framework to be bundle_only (not linked), got: %s" % linked_dylibs,
        )

    return analysistest.end(env)

def _fake_xcode_config_impl(_ctx):
    return [
        apple_common.XcodeVersionConfig(
            ios_sdk_version = "18.0",
            ios_minimum_os_version = "15.0",
            visionos_sdk_version = "2.0",
            visionos_minimum_os_version = "1.0",
            watchos_sdk_version = "11.0",
            watchos_minimum_os_version = "9.0",
            tvos_sdk_version = "18.0",
            tvos_minimum_os_version = "15.0",
            macos_sdk_version = "15.0",
            macos_minimum_os_version = "13.0",
            xcode_version = "16.0",
            availability = "UNKNOWN",
            xcode_version_flag = "16.0",
            include_xcode_execution_info = False,
        ),
    ]

_fake_xcode_config = rule(implementation = _fake_xcode_config_impl)

_ios_framework_import_release_test = analysistest.make(
    _ios_framework_import_test_impl,
    attrs = {
        "expect_linked": attr.bool(default = True),
        "expected_framework_dir": attr.string(mandatory = True),
    },
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
        "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
        str(Label("//flutter:profile")): False,
    },
)

_ios_framework_import_debug_test = analysistest.make(
    _ios_framework_import_test_impl,
    attrs = {
        "expect_linked": attr.bool(default = False),
        "expected_framework_dir": attr.string(mandatory = True),
    },
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
        "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
        str(Label("//flutter:profile")): False,
    },
)

def _ios_macro_surface_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, ctx.attr.expected_kinds, ctx.attr.actual_kinds)
    asserts.equals(env, [], ctx.attr.unexpected_xtool_targets)
    asserts.equals(env, ctx.attr.expected_app_deps, ctx.attr.actual_app_deps)
    return unittest.end(env)

_ios_macro_surface_test = unittest.make(
    _ios_macro_surface_test_impl,
    attrs = {
        "actual_app_deps": attr.string_list(mandatory = True),
        "actual_kinds": attr.string_dict(mandatory = True),
        "expected_app_deps": attr.string_list(mandatory = True),
        "expected_kinds": attr.string_dict(mandatory = True),
        "unexpected_xtool_targets": attr.string_list(mandatory = True),
    },
)

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
    fake_xcframework(
        name = name + "_fake_ios_plugin_kit_xcframework",
        framework_name = "PluginKit",
        platform = "ios",
        tags = ["manual"],
    )
    flutter_darwin_xcframework_import(
        name = name + "_fake_ios_plugin_kit_import",
        framework_name = "PluginKit",
        xcframework_imports = [":" + name + "_fake_ios_plugin_kit_xcframework"],
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
        deps = [":" + name + "_fake_ios_plugin_kit_import"],
        sdk_frameworks = ["AVFoundation"],
        sdk_dylibs = ["sqlite3"],
        backend = "xtool",
        tags = ["manual"],
    )
    fake_application(
        name = name + "_fake_e2e_ios_app",
        debug = False,
        macho_aot = True,
        native_libs = ["libfoo.dylib"],
        code_assets = ["libbar.dylib"],
        apple_plugin_libraries = [":" + name + "_sample_ios_plugin_lib"],
        tags = ["manual"],
    )
    flutter_ios_app(
        name = name + "_e2e_ios_app",
        application = ":" + name + "_fake_e2e_ios_app",
        bundle_id = "com.example.e2e.ios",
        minimum_os_version = "15.4",
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

    _fake_xcode_config(
        name = name + "_fake_xcode_config",
        tags = ["manual"],
    )

    # Default backend (`rules_apple`) macro surface fixtures: verify target
    # names, rule kinds, absence of xtool targets, and release App.framework
    # linking.
    before_default = native.existing_rules().keys()
    fg_name = name + "_default_framework_gen"
    eng_name = name + "_default_engine"
    reg_name = name + "_default_registrant"
    rl_name = name + "_default_runner_lib"
    pl_name = name + "_default_ios_plugin_lib"
    app_name = name + "_default_ios_app"

    flutter_ios_framework_gen(
        name = fg_name,
        application = ":" + name + "_fake_release_app",
        tags = ["manual"],
    )
    flutter_ios_engine(
        name = eng_name,
        tags = ["manual"],
    )
    flutter_ios_registrant_gen(
        name = reg_name,
        application = ":" + name + "_fake_release_app",
        tags = ["manual"],
    )
    flutter_ios_runner_lib_gen(
        name = rl_name,
        registrant = ":" + reg_name,
        engine = ":" + eng_name,
        application = ":" + name + "_fake_release_app",
        tags = ["manual"],
    )
    flutter_apple_plugin_library(
        name = pl_name,
        srcs = [":" + name + "_SampleIosPlugin.swift"],
        module_name = "default_ios_plugin",
        platform = "ios",
        tags = ["manual"],
    )
    flutter_ios_app(
        name = app_name,
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.default.ios",
        srcs = [
            "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        launch_storyboard = "@rules_flutter//flutter/private/runners/ios:Base.lproj/LaunchScreen.storyboard",
        app_icons = [],
        entitlements = False,
        tags = ["manual"],
    )
    after_default = native.existing_rules()
    created_default = {
        k: after_default[k]["kind"]
        for k in after_default
        if k not in before_default
    }
    unexpected_xtool = [
        k
        for k, kind in created_default.items()
        if "xtool" in k or "xtool" in kind or kind == "flutter_darwin_xcframework_import"
    ]
    expected_default_kinds = {
        "__%s_intermediates" % fg_name: "flutter_ios_application",
        "__%s_framework" % fg_name: "flutter_ios_framework",
        fg_name: "apple_dynamic_framework_import",
        eng_name: "apple_dynamic_xcframework_import",
        reg_name: "flutter_ios_registrant",
        "_%s__apple_plugins_aggregator" % rl_name: "flutter_apple_plugins_aggregator",
        rl_name: "swift_library",
        "_%s__flutter_framework" % pl_name: "apple_dynamic_xcframework_import",
        pl_name: "swift_library",
        "__%s_registrant" % app_name: "flutter_ios_registrant",
        "__%s_intermediates" % app_name: "flutter_ios_application",
        "__%s_app_framework" % app_name: "flutter_ios_framework",
        "__%s_app_bundle" % app_name: "apple_dynamic_framework_import",
        "__%s_engine" % app_name: "apple_dynamic_xcframework_import",
        "__%s_native_frameworks" % app_name: "flutter_ios_native_frameworks",
        "__%s_privacy_manifests" % app_name: "flutter_ios_privacy_manifests",
        "__%s_apple_plugins" % app_name: "flutter_apple_plugins_aggregator",
        "__%s_runner" % app_name: "swift_library",
        "__%s_version" % app_name: "apple_bundle_version",
        "__%s_info_plist_dev" % app_name: "flutter_plist_merge",
        app_name: "ios_application",
    }
    _ios_macro_surface_test(
        name = name + "_default_macro_surface",
        actual_kinds = created_default,
        expected_kinds = expected_default_kinds,
        unexpected_xtool_targets = unexpected_xtool,
        actual_app_deps = [str(d) for d in after_default[app_name]["deps"]],
        expected_app_deps = [
            ":__%s_runner" % app_name,
            ":__%s_app_bundle" % app_name,
            ":__%s_native_frameworks" % app_name,
        ],
    )

    _ios_framework_import_release_test(
        name = name + "_framework_gen_links_release",
        target_under_test = ":" + fg_name,
        expected_framework_dir = "__%s_framework" % fg_name,
    )
    _ios_framework_import_debug_test(
        name = name + "_framework_gen_bundle_only_debug",
        target_under_test = ":" + fg_name,
        expected_framework_dir = "__%s_framework" % fg_name,
    )
    _ios_framework_import_release_test(
        name = name + "_app_bundle_links_release",
        target_under_test = ":__%s_app_bundle" % app_name,
        expected_framework_dir = "__%s_app_framework" % app_name,
    )
    _ios_framework_import_debug_test(
        name = name + "_app_bundle_bundle_only_debug",
        target_under_test = ":__%s_app_bundle" % app_name,
        expected_framework_dir = "__%s_app_framework" % app_name,
    )

    macho_verify_probe(
        name = name + "_fake_app_framework_verify",
        target = ":" + name + "_fake_app_framework",
        expected_substrings = [
            "__TEXT",
            "__LINKEDIT",
            "LC_ID_DYLIB",
            "@rpath/App.framework/App",
            "LC_UUID",
            "LC_BUILD_VERSION",
            "LC_SYMTAB",
            "LC_DYSYMTAB",
            "NOUNDEFS",
            "DYLDLINK",
            "TWOLEVEL",
        ],
        tags = ["manual"],
    )

    macho_verify_probe(
        name = name + "_e2e_ios_app_framework_verify",
        target = ":__" + name + "_e2e_ios_app_app_framework",
        expected_substrings = [
            "@rpath/App.framework/App",
            "minos 15.4",
        ],
        tags = ["manual"],
    )

    macho_verify_probe(
        name = name + "_e2e_ios_app_native_framework_verify",
        target = ":__" + name + "_e2e_ios_app_native_frameworks",
        binary_relpath = "foo.framework/foo",
        expected_substrings = [
            "@rpath/foo.framework/foo",
            "minos 15.4",
        ],
        tags = ["manual"],
    )

    macho_verify_probe(
        name = name + "_e2e_ios_app_bundle_verify",
        target = ":" + name + "_e2e_ios_app",
        binary_relpath = "Payload/" + name + "_e2e_ios_app.app/" + name + "_e2e_ios_app",
        expected_entries = [
            "Payload/" + name + "_e2e_ios_app.app/" + name + "_e2e_ios_app",
            "Payload/" + name + "_e2e_ios_app.app/Frameworks/App.framework/App",
            "Payload/" + name + "_e2e_ios_app.app/Frameworks/Flutter.framework/Flutter",
            "Payload/" + name + "_e2e_ios_app.app/Frameworks/PluginKit.framework/PluginKit",
            "Payload/" + name + "_e2e_ios_app.app/Frameworks/foo.framework/foo",
            "Payload/" + name + "_e2e_ios_app.app/Frameworks/bar.framework/bar",
        ],
        expected_substrings = [
            "cmd LC_RPATH",
            "@executable_path/Frameworks",
            "/System/Library/Frameworks/AVFoundation.framework/AVFoundation",
            "/usr/lib/libsqlite3.dylib",
            "cmd LC_BUILD_VERSION",
            "minos 15.4",
        ],
        tags = ["manual"],
    )

    fake_application(
        name = name + "_fake_fat_ios_app",
        debug = False,
        macho_aot = True,
        fat_macho = True,
        native_libs = ["libfatplugin.dylib"],
        tags = ["manual"],
    )
    flutter_ios_framework(
        name = name + "_fake_fat_ios_app_framework",
        application = ":" + name + "_fake_fat_ios_app",
        minimum_os_version = "16.2",
        tags = ["manual"],
    )
    flutter_ios_native_frameworks(
        name = name + "_fake_fat_ios_app_native_frameworks",
        application = ":" + name + "_fake_fat_ios_app",
        minimum_os_version = "16.2",
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_fake_fat_ios_app_framework_verify",
        target = ":" + name + "_fake_fat_ios_app_framework",
        expected_substrings = [
            "@rpath/App.framework/App",
            "minos 16.2",
        ],
        tags = ["manual"],
    )
    macho_verify_probe(
        name = name + "_fake_fat_ios_app_native_framework_verify",
        target = ":" + name + "_fake_fat_ios_app_native_frameworks",
        binary_relpath = "fatplugin.framework/fatplugin",
        expected_substrings = [
            "@rpath/fatplugin.framework/fatplugin",
            "minos 16.2",
        ],
        tags = ["manual"],
    )

    fake_application(
        name = name + "_fake_non_macho_ios_app",
        debug = True,
        macho_aot = False,
        native_libs = ["libnonmacho.dylib"],
        tags = ["manual"],
    )
    flutter_ios_native_frameworks(
        name = name + "_fake_non_macho_ios_native_frameworks",
        application = ":" + name + "_fake_non_macho_ios_app",
        allow_non_macho = ["libnonmacho.dylib"],
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
            name + "_e2e_ios_app_framework_verify",
            name + "_e2e_ios_app_native_framework_verify",
            name + "_e2e_ios_app_bundle_verify",
            name + "_fake_fat_ios_app_framework_verify",
            name + "_fake_fat_ios_app_native_framework_verify",
            name + "_fake_non_macho_ios_native_frameworks",
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
            name + "_fake_app_framework_verify",
            name + "_fake_app_other_framework",
            name + "_release_device_targets",
        ],
    )

    _xtool_ios_app_actions_test(
        name = name + "_xtool_ios_app_actions",
        target_under_test = name + "_e2e_ios_app",
    )

    return [
        name + "_default_macro_surface",
        name + "_framework_gen_links_release",
        name + "_framework_gen_bundle_only_debug",
        name + "_app_bundle_links_release",
        name + "_app_bundle_bundle_only_debug",
        name + "_framework_outputs_under_target_dir",
        name + "_simulator_fastbuild_refused",
        name + "_xtool_ios_app_actions",
        name + "_two_apps_one_package",
    ] + _xtool_ios_validation_tests(name)

def _ios_expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_ios_expect_failure_test = analysistest.make(
    _ios_expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_substrings": attr.string_list(mandatory = True),
    },
)

def _xtool_ios_attrs_and_secrets_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    bundle_actions = [a for a in actions if a.mnemonic == "FlutterXtoolIosBundle"]
    asserts.equals(env, 1, len(bundle_actions))
    argv = bundle_actions[0].argv
    asserts.true(
        env,
        "--family" in argv and "ipad" in argv,
        "Expected --family ipad in argv: %s" % argv,
    )
    asserts.true(
        env,
        "--version-file" in argv,
        "Expected --version-file in argv when apple_bundle_version is passed to version: %s" % argv,
    )
    asserts.true(
        env,
        "--additional-content" in argv and any([arg.startswith("PlugIns=") for arg in argv]),
        "Expected --additional-content PlugIns=... in argv: %s" % argv,
    )
    asserts.true(
        env,
        "--certificate-password-file" in argv,
        "Expected --certificate-password-file in argv: %s" % argv,
    )
    asserts.true(
        env,
        "--certificate-password-env" in argv and "IOS_CERT_PW_ENV" in argv,
        "Expected --certificate-password-env IOS_CERT_PW_ENV in argv: %s" % argv,
    )
    asserts.true(
        env,
        "IOS_CERT_PW_ENV" in bundle_actions[0].env,
        "Expected IOS_CERT_PW_ENV to be explicitly bound in FlutterXtoolIosBundle action env, got: %s" % bundle_actions[0].env,
    )
    for a in actions:
        for arg in a.argv:
            asserts.false(
                env,
                "super-secret-p12-pass" in arg,
                "Signing secret leaked onto command line of %s: %s" % (a.mnemonic, a.argv),
            )
    return analysistest.end(env)

_xtool_ios_attrs_and_secrets_test = analysistest.make(_xtool_ios_attrs_and_secrets_test_impl)

def _xtool_ios_validation_tests(name):
    write_file(
        name = name + "_xtool_extra_plugin",
        out = name + "_extra_plugin.txt",
        content = ["plugin"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_xtool_cert_pw_file",
        out = name + "_cert_pw.txt",
        content = ["super-secret-p12-pass"],
        tags = ["manual"],
    )
    apple_bundle_version(
        name = name + "_xtool_custom_ios_version",
        build_version = "42",
        short_version_string = "2.5.0",
        tags = ["manual"],
    )

    before_xtool = native.existing_rules().keys()
    xtool_surface_app = name + "_xtool_attrs_ios_app"
    flutter_ios_app(
        name = xtool_surface_app,
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.xtool.attrs",
        families = ["ipad"],
        version = ":" + name + "_xtool_custom_ios_version",
        srcs = [
            "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        entitlements = False,
        additional_contents = {
            ":" + name + "_xtool_extra_plugin": "PlugIns",
        },
        certificate_password_file = ":" + name + "_xtool_cert_pw_file",
        certificate_password_env = "IOS_CERT_PW_ENV",
        backend = "xtool",
        tags = ["manual"],
    )
    flutter_ios_app(
        name = name + "_xtool_default_engine_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.xtool.defaultengine",
        srcs = [
            "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        entitlements = False,
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
            "ios_application",
            "apple_dynamic_framework_import",
            "apple_dynamic_xcframework_import",
            "apple_bundle_version",
        )
    ]
    _ios_macro_surface_test(
        name = name + "_xtool_no_rules_apple_surface",
        actual_kinds = created_xtool,
        expected_kinds = created_xtool,
        unexpected_xtool_targets = unexpected_rules_apple,
        actual_app_deps = [],
        expected_app_deps = [],
    )
    _xtool_ios_attrs_and_secrets_test(
        name = name + "_xtool_ios_attrs_and_secrets",
        target_under_test = ":" + xtool_surface_app,
    )

    # Invalid version target on xtool
    flutter_ios_app(
        name = name + "_xtool_bad_version_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.badversion",
        version = ":" + name + "_xtool_extra_plugin",
        srcs = ["@rules_flutter//flutter/private/runners/ios:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        entitlements = False,
        backend = "xtool",
        tags = ["manual"],
    )
    _ios_expect_failure_test(
        name = name + "_xtool_bad_version_fails",
        target_under_test = ":" + name + "_xtool_bad_version_ios_app",
        expected_substrings = ["'version'", "apple_bundle_version"],
    )

    # Invalid family
    flutter_ios_app(
        name = name + "_xtool_bad_family_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.badfamily",
        families = ["tv"],
        srcs = ["@rules_flutter//flutter/private/runners/ios:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        entitlements = False,
        backend = "xtool",
        tags = ["manual"],
    )
    _ios_expect_failure_test(
        name = name + "_xtool_bad_family_fails",
        target_under_test = ":" + name + "_xtool_bad_family_ios_app",
        expected_substrings = ["invalid device family \"tv\" in 'families'; expected 'iphone' or 'ipad'"],
    )

    # launch_storyboard on xtool
    flutter_ios_app(
        name = name + "_xtool_storyboard_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.storyboard",
        launch_storyboard = "@rules_flutter//flutter/private/runners/ios:Base.lproj/LaunchScreen.storyboard",
        srcs = ["@rules_flutter//flutter/private/runners/ios:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        entitlements = False,
        backend = "xtool",
        tags = ["manual"],
    )
    _ios_expect_failure_test(
        name = name + "_xtool_launch_storyboard_fails",
        target_under_test = ":" + name + "_xtool_storyboard_ios_app",
        expected_substrings = ["'launch_storyboard'", "ibtool"],
    )

    # Main.storyboard in resources on xtool
    flutter_ios_app(
        name = name + "_xtool_main_storyboard_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.mainstoryboard",
        resources = ["@rules_flutter//flutter/private/runners/ios:Base.lproj/Main.storyboard"],
        srcs = ["@rules_flutter//flutter/private/runners/ios:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        entitlements = False,
        backend = "xtool",
        tags = ["manual"],
    )
    _ios_expect_failure_test(
        name = name + "_xtool_main_storyboard_fails",
        target_under_test = ":" + name + "_xtool_main_storyboard_ios_app",
        expected_substrings = ["'resources'", "Main.storyboard", "ibtool"],
    )

    # app_icons on xtool
    flutter_ios_app(
        name = name + "_xtool_app_icons_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.appicons",
        app_icons = [":" + name + "_xtool_extra_plugin"],
        srcs = ["@rules_flutter//flutter/private/runners/ios:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        entitlements = False,
        backend = "xtool",
        tags = ["manual"],
    )
    _ios_expect_failure_test(
        name = name + "_xtool_app_icons_fails",
        target_under_test = ":" + name + "_xtool_app_icons_ios_app",
        expected_substrings = ["'app_icons'", "actool"],
    )

    # Plain-text certificate_password on xtool
    flutter_ios_app(
        name = name + "_xtool_plaintext_pw_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.plaintextpw",
        certificate_password = "leaked-password",
        srcs = ["@rules_flutter//flutter/private/runners/ios:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        entitlements = False,
        backend = "xtool",
        tags = ["manual"],
    )
    _ios_expect_failure_test(
        name = name + "_xtool_plaintext_pw_fails",
        target_under_test = ":" + name + "_xtool_plaintext_pw_ios_app",
        expected_substrings = ["plain-text 'certificate_password' is not supported"],
    )

    # require_sdk = True when SDK is unconfigured
    flutter_ios_app(
        name = name + "_xtool_require_sdk_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.requiresdk",
        require_sdk = True,
        srcs = ["@rules_flutter//flutter/private/runners/ios:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        entitlements = False,
        backend = "xtool",
        tags = ["manual"],
    )
    _ios_expect_failure_test(
        name = name + "_xtool_require_sdk_fails",
        target_under_test = ":" + name + "_xtool_require_sdk_ios_app",
        expected_substrings = ["The xtool Darwin SDK (@flutter_xtool_darwin_sdk) is not configured"],
    )

    # Unsupported kwargs on xtool
    flutter_ios_app(
        name = name + "_xtool_unsupported_kwarg_ios_app",
        application = ":" + name + "_fake_release_app",
        bundle_id = "com.example.badkwarg",
        ipa_post_processor = "foo",
        srcs = ["@rules_flutter//flutter/private/runners/ios:AppDelegate.swift"],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        engine = ":" + name + "_fake_ios_xcframework",
        entitlements = False,
        backend = "xtool",
        tags = ["manual"],
    )
    _ios_expect_failure_test(
        name = name + "_xtool_unsupported_kwarg_fails",
        target_under_test = ":" + name + "_xtool_unsupported_kwarg_ios_app",
        expected_substrings = ["unsupported attribute(s) 'ipa_post_processor' are not supported on the xtool backend"],
    )

    return [
        name + "_xtool_no_rules_apple_surface",
        name + "_xtool_ios_attrs_and_secrets",
        name + "_xtool_bad_version_fails",
        name + "_xtool_bad_family_fails",
        name + "_xtool_launch_storyboard_fails",
        name + "_xtool_main_storyboard_fails",
        name + "_xtool_app_icons_fails",
        name + "_xtool_plaintext_pw_fails",
        name + "_xtool_require_sdk_fails",
        name + "_xtool_unsupported_kwarg_fails",
    ]

def ios_test_suite(name):
    """Declares the iOS entitlement and bundling tests.

    Args:
        name: The test_suite name.
    """
    _resolve_test(name = name + "_resolve")
    native.test_suite(
        name = name,
        tests = [":" + t for t in [name + "_resolve"] + _bundling_tests(name) + _registrant_tests(name)],
    )

def _ios_registrant_swift_groups_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    swift_files = tut[OutputGroupInfo].swift.to_list()
    asserts.equals(env, 1, len(swift_files))
    asserts.true(
        env,
        swift_files[0].short_path.endswith("_native_plugin_registrant.swift"),
        "Expected the Swift registrant, got: %s" % [f.short_path for f in swift_files],
    )
    asserts.equals(env, 1, len(tut[DefaultInfo].files.to_list()))
    return analysistest.end(env)

_ios_registrant_swift_groups_test = analysistest.make(_ios_registrant_swift_groups_test_impl)

def _ios_registrant_objc_groups_test_impl(ctx):
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    groups = tut[OutputGroupInfo]
    hdrs = groups.hdrs.to_list()
    srcs = groups.srcs.to_list()
    asserts.equals(env, 1, len(hdrs))
    asserts.equals(env, 1, len(srcs))
    asserts.true(
        env,
        hdrs[0].short_path.endswith("GeneratedPluginRegistrant.h"),
        "Expected the ObjC header, got: %s" % [f.short_path for f in hdrs],
    )
    asserts.true(
        env,
        srcs[0].short_path.endswith("GeneratedPluginRegistrant.m"),
        "Expected the ObjC source, got: %s" % [f.short_path for f in srcs],
    )
    asserts.equals(env, 2, len(tut[DefaultInfo].files.to_list()))
    asserts.equals(
        env,
        None,
        getattr(groups, "swift", None),
        "The ObjC registrant must not expose a swift output group",
    )
    return analysistest.end(env)

_ios_registrant_objc_groups_test = analysistest.make(_ios_registrant_objc_groups_test_impl)

def _registrant_tests(name):
    """Declare the registrant fixtures and the tests over them.

    Args:
      name: Prefix for every target declared here.

    Returns:
      The test target names.
    """
    fake_application(
        name = name + "_reg_app",
        debug = True,
        plugin_name = "sample_plugin",
        plugin_class = "SamplePlugin",
        tags = ["manual"],
    )
    flutter_ios_registrant_gen(
        name = name + "_reg_swift",
        application = ":" + name + "_reg_app",
        tags = ["manual"],
    )
    flutter_ios_registrant_gen(
        name = name + "_reg_objc",
        application = ":" + name + "_reg_app",
        language = "objc",
        tags = ["manual"],
    )
    flutter_ios_registrant_gen(
        name = name + "_reg_excluded",
        application = ":" + name + "_reg_app",
        exclude_plugins = ["sample_plugin"],
        tags = ["manual"],
    )
    flutter_ios_registrant_gen(
        name = name + "_reg_typo",
        application = ":" + name + "_reg_app",
        exclude_plugins = ["typo_plugin"],
        tags = ["manual"],
    )
    _ios_registrant_swift_groups_test(
        name = name + "_reg_swift_groups",
        target_under_test = ":" + name + "_reg_swift",
    )
    _ios_registrant_objc_groups_test(
        name = name + "_reg_objc_groups",
        target_under_test = ":" + name + "_reg_objc",
    )
    _ios_registrant_swift_groups_test(
        name = name + "_reg_excluded_groups",
        target_under_test = ":" + name + "_reg_excluded",
    )
    _ios_expect_failure_test(
        name = name + "_reg_typo_fails",
        target_under_test = ":" + name + "_reg_typo",
        expected_substrings = ["exclude_plugins", "typo_plugin", "sample_plugin"],
    )

    # An app excluding the only plugin: the macro forwards exclude_plugins
    # to its internal registrant, which stays a Swift registrant. The
    # objc_drift_test suite reads that registrant's bytes and proves the
    # exclusion arrived.
    excl_app = name + "_excl_app"
    flutter_ios_app(
        name = excl_app,
        application = ":" + name + "_reg_app",
        bundle_id = "com.example.excl.ios",
        srcs = [
            "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
            "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
        ],
        info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
        exclude_plugins = ["sample_plugin"],
        entitlements = False,
        app_icons = [],
        tags = ["manual"],
    )
    _ios_registrant_swift_groups_test(
        name = name + "_excl_app_registrant_groups",
        target_under_test = ":__%s_registrant" % excl_app,
    )

    return [
        name + "_reg_swift_groups",
        name + "_reg_objc_groups",
        name + "_reg_excluded_groups",
        name + "_reg_typo_fails",
        name + "_excl_app_registrant_groups",
    ]
