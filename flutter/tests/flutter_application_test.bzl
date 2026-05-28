"""Unit tests for flutter_application platform detection logic."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:common.bzl", "detect_target_platform")

def _ios_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = True,
        is_macos = False,
        is_linux = False,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "ios", result)
    return unittest.end(env)

def _macos_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = True,
        is_linux = False,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "macos", result)
    return unittest.end(env)

def _linux_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = False,
        is_linux = True,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "linux", result)
    return unittest.end(env)

def _windows_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = False,
        is_linux = False,
        is_windows = True,
        is_android = False,
    )
    asserts.equals(env, "windows", result)
    return unittest.end(env)

def _android_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = False,
        is_linux = False,
        is_windows = False,
        is_android = True,
    )
    asserts.equals(env, "android", result)
    return unittest.end(env)

def _ios_priority_over_macos_test_impl(ctx):
    """iOS should take priority if both iOS and macOS match (edge case)."""
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = True,
        is_macos = True,
        is_linux = False,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "ios", result)
    return unittest.end(env)

_t0_test = unittest.make(_ios_detection_test_impl)
_t1_test = unittest.make(_macos_detection_test_impl)
_t2_test = unittest.make(_linux_detection_test_impl)
_t3_test = unittest.make(_windows_detection_test_impl)
_t4_test = unittest.make(_android_detection_test_impl)
_t5_test = unittest.make(_ios_priority_over_macos_test_impl)

def flutter_application_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test)
