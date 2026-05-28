"""Unit tests for engine helpers and provider definitions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter:providers.bzl", "FlutterSdkInfo")
load("//flutter/private:engine_helpers.bzl", "dart_binary_name", "dartaotruntime_binary_name", "engine_arch_for_os", "platform_to_arch", "platform_to_os")

def _provider_exists_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, FlutterSdkInfo != None, "FlutterSdkInfo should be defined")
    asserts.true(
        env,
        type(FlutterSdkInfo) == "Provider",
        "FlutterSdkInfo should be a Provider, got {}".format(type(FlutterSdkInfo)),
    )
    return unittest.end(env)

def _dart_binary_name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "dart", dart_binary_name("darwin-arm64"))
    asserts.equals(env, "dart", dart_binary_name("linux-x64"))
    asserts.equals(env, "dart.exe", dart_binary_name("windows-x64"))
    asserts.equals(env, "dartaotruntime", dartaotruntime_binary_name("darwin-arm64"))
    asserts.equals(env, "dartaotruntime.exe", dartaotruntime_binary_name("windows-x64"))
    return unittest.end(env)

def _platform_mapping_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "macos", platform_to_os("darwin-arm64"))
    asserts.equals(env, "linux", platform_to_os("linux-x64"))
    asserts.equals(env, "windows", platform_to_os("windows-x64"))
    asserts.equals(env, "arm64", platform_to_arch("darwin-arm64"))
    asserts.equals(env, "x64", platform_to_arch("linux-x64"))
    asserts.equals(env, "", platform_to_arch("nohyphen"))
    return unittest.end(env)

def _engine_arch_for_os_test_impl(ctx):
    env = unittest.begin(ctx)

    # macOS always overrides to x64.
    asserts.equals(env, "x64", engine_arch_for_os("macos", "arm64"))
    asserts.equals(env, "x64", engine_arch_for_os("macos", "x64"))

    # Other OSes pass through.
    asserts.equals(env, "x64", engine_arch_for_os("linux", "x64"))
    asserts.equals(env, "arm64", engine_arch_for_os("linux", "arm64"))
    asserts.equals(env, "x64", engine_arch_for_os("windows", "x64"))
    return unittest.end(env)

_t0_test = unittest.make(_provider_exists_test_impl)
_t1_test = unittest.make(_dart_binary_name_test_impl)
_t2_test = unittest.make(_platform_mapping_test_impl)
_t3_test = unittest.make(_engine_arch_for_os_test_impl)

def toolchain_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test)
