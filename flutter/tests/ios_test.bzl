"""Unit and analysis tests for iOS application validation and bundling."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:flutter_ios_application.bzl", "flutter_ios_framework")
load("//flutter/private:ios_entitlements.bzl", "resolve_ios_entitlements")
load(":apple_bundling.bzl", "fake_application", "outputs_under_target_dir_test")

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
        flutter_ios_framework(
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

    return [
        name + "_framework_outputs_under_target_dir",
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
