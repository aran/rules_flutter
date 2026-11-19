"""Unit and analysis tests for iOS application validation and bundling."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:flutter_ios_application.bzl", "flutter_ios_app_framework", "flutter_ios_native_frameworks")
load("//flutter/private:ios_entitlements.bzl", "resolve_ios_entitlements")
load(":apple_bundling.bzl", "fake_application", "native_library_symbols_test", "native_library_untouched_test", "outputs_under_target_dir_test", "strip_step_test")

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

# -- Bundling ------------------------------------------------------------------

def _bundling_tests(name):
    """Declare the bundling fixtures and the tests over them.

    Args:
      name: Prefix for every target declared here.

    Returns:
      The test target names.
    """

    # Debug fakes: a release framework retags its dylib with `vtool`, which
    # rejects a placeholder that is not a Mach-O, and the build_test below
    # really builds these.
    for app in ["_fake_app", "_fake_app_other"]:
        fake_application(
            name = name + app,
            debug = True,
            tags = ["manual"],
        )
        flutter_ios_app_framework(
            name = name + app + "_framework",
            application = name + app,
            tags = ["manual"],
        )

    # macOS-only, both of them, and not because of `xcrun`: there is no
    # Linux-host-to-iOS Flutter toolchain (`CROSS_COMPILATION_PAIRS` in
    # `toolchains_repo.bzl`), so the rule cannot even be analysed on the runner
    # that sweeps this workspace. `target_compatible_with` is what keeps that
    # from being an error there — an incompatible test is skipped without its
    # dependencies being analysed.
    outputs_under_target_dir_test(
        name = name + "_framework_outputs_under_target_dir",
        target_under_test = name + "_fake_app_framework",
        target_compatible_with = ["@platforms//os:macos"],
    )

    # Two different apps in one package, built together: any output the two
    # declare under one name conflicts. A pair built from the same application
    # would not — Bazel shares identical actions.
    build_test(
        name = name + "_two_apps_one_package",
        targets = [
            name + "_fake_app_framework",
            name + "_fake_app_other_framework",
        ],
        target_compatible_with = ["@platforms//os:macos"],
    )

    # A release framework runs Xcode's tools on its dylib, so these are only
    # analysed, never built: the fake's dylib is not a Mach-O. Whether the
    # binary is stripped follows the application, as `flutter build` follows
    # `--no-strip`.
    for strip in [True, False]:
        suffix = "_stripped" if strip else "_unstripped"
        fake_application(
            name = name + "_fake_release" + suffix,
            strip_aot = strip,
            tags = ["manual"],
        )
        flutter_ios_app_framework(
            name = name + "_release_framework" + suffix,
            application = name + "_fake_release" + suffix,
            tags = ["manual"],
        )
        strip_step_test(
            name = name + "_release_framework" + suffix + "_test",
            expect_strip = strip,
            target_under_test = name + "_release_framework" + suffix,
            target_compatible_with = ["@platforms//os:macos"],
        )

    # Each native library's framework, stripped and with a
    # `<name>.framework.dSYM`, as rules_apple treats the app's binary and
    # `flutter build ios` names the dSYM.
    fake_application(
        name = name + "_fake_native",
        native_libs = ["libadd.dylib"],
        code_assets = ["assets/libasset.dylib"],
        # A `rust_shared_library` without rustc's dSYM, as on iOS: its dSYM
        # is its symbol table's.
        gone_code_assets = ["assets/librust.dylib"],
        tags = ["manual"],
    )
    flutter_ios_native_frameworks(
        name = name + "_native_frameworks",
        application = name + "_fake_native",
        tags = ["manual"],
    )
    native_library_symbols_test(
        name = name + "_native_frameworks_symbols",
        target_under_test = name + "_native_frameworks",
        mnemonic = "FlutterIOSNativeAssetFramework",
        expected_dsyms = [
            "add.framework.dSYM/add",
            "asset.framework.dSYM/asset",
            "rust.framework.dSYM/rust",
        ],
        expected_always = ["add.framework.dSYM"],
        expected_candidates = ["asset.framework.dSYM", "rust.framework.dSYM"],
        symbol_table_only = ["librust.dylib"],
        target_compatible_with = ["@platforms//os:macos"],
    )
    native_library_untouched_test(
        name = name + "_native_frameworks_untouched",
        target_under_test = name + "_native_frameworks",
        target_compatible_with = ["@platforms//os:macos"],
    )

    return [
        name + "_framework_outputs_under_target_dir",
        name + "_native_frameworks_symbols",
        name + "_native_frameworks_untouched",
        name + "_two_apps_one_package",
        name + "_release_framework_stripped_test",
        name + "_release_framework_unstripped_test",
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
