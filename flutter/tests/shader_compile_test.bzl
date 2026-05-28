"""Unit tests for flutter_shader_compile.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_shader_compile.bzl", "SHADER_PLATFORM_FLAGS", "get_shader_platform_flags")

def _ios_flags_test_impl(ctx):
    """iOS shaders use Metal only."""
    env = unittest.begin(ctx)
    flags = get_shader_platform_flags("ios")
    asserts.equals(env, ["--runtime-stage-metal"], flags)
    return unittest.end(env)

def _macos_flags_test_impl(ctx):
    """macOS shaders use SKSL + Metal."""
    env = unittest.begin(ctx)
    flags = get_shader_platform_flags("macos")
    asserts.true(env, "--sksl" in flags, "macos should include --sksl")
    asserts.true(env, "--runtime-stage-metal" in flags, "macos should include --runtime-stage-metal")
    return unittest.end(env)

def _android_flags_test_impl(ctx):
    """Android shaders use SKSL + GLES + GLES3 + Vulkan."""
    env = unittest.begin(ctx)
    flags = get_shader_platform_flags("android")
    asserts.true(env, "--sksl" in flags)
    asserts.true(env, "--runtime-stage-gles" in flags)
    asserts.true(env, "--runtime-stage-gles3" in flags)
    asserts.true(env, "--runtime-stage-vulkan" in flags)
    return unittest.end(env)

def _linux_matches_android_test_impl(ctx):
    """Linux and Android should have the same shader flags."""
    env = unittest.begin(ctx)
    asserts.equals(env, get_shader_platform_flags("android"), get_shader_platform_flags("linux"))
    return unittest.end(env)

def _windows_matches_android_test_impl(ctx):
    """Windows and Android should have the same shader flags."""
    env = unittest.begin(ctx)
    asserts.equals(env, get_shader_platform_flags("android"), get_shader_platform_flags("windows"))
    return unittest.end(env)

def _web_flags_test_impl(ctx):
    """Web shaders use SKSL only."""
    env = unittest.begin(ctx)
    flags = get_shader_platform_flags("web")
    asserts.equals(env, ["--sksl"], flags)
    return unittest.end(env)

def _all_platforms_covered_test_impl(ctx):
    """All expected platforms are in the flags dict."""
    env = unittest.begin(ctx)
    expected = ["ios", "macos", "android", "linux", "windows", "web"]
    for p in expected:
        asserts.true(env, p in SHADER_PLATFORM_FLAGS, "Platform '%s' should be in SHADER_PLATFORM_FLAGS" % p)
    return unittest.end(env)

_t0_test = unittest.make(_ios_flags_test_impl)
_t1_test = unittest.make(_macos_flags_test_impl)
_t2_test = unittest.make(_android_flags_test_impl)
_t3_test = unittest.make(_linux_matches_android_test_impl)
_t4_test = unittest.make(_windows_matches_android_test_impl)
_t5_test = unittest.make(_web_flags_test_impl)
_t6_test = unittest.make(_all_platforms_covered_test_impl)

def shader_compile_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test)
