"""Unit tests for flutter_library.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart:utils.bzl", "derive_lib_root", "derive_package_name")
load("//flutter/private:flutter_library.bzl", "dedup_plugins")

def _package_name_explicit_attr_wins_test_impl(ctx):
    env = unittest.begin(ctx)
    result = derive_package_name("my_explicit_pkg", "some/path/lib_name", "target_name")
    asserts.equals(env, "my_explicit_pkg", result)
    return unittest.end(env)

def _package_name_falls_back_to_label_package_test_impl(ctx):
    env = unittest.begin(ctx)
    result = derive_package_name("", "some/path/my_lib", "target_name")
    asserts.equals(env, "my_lib", result)
    return unittest.end(env)

def _package_name_falls_back_to_label_name_test_impl(ctx):
    env = unittest.begin(ctx)
    result = derive_package_name("", "", "my_target")
    asserts.equals(env, "my_target", result)
    return unittest.end(env)

def _lib_root_workspace_root_and_package_test_impl(ctx):
    env = unittest.begin(ctx)

    # derive_lib_root converts external/X -> ../X (short_path convention)
    result = derive_lib_root("external/my_repo", "packages/my_lib")
    asserts.equals(env, "../my_repo/packages/my_lib", result)
    return unittest.end(env)

def _lib_root_strips_trailing_lib_test_impl(ctx):
    env = unittest.begin(ctx)
    result = derive_lib_root("", "packages/my_lib/lib")
    asserts.equals(env, "packages/my_lib", result)
    return unittest.end(env)

def _dedup_plugins_removes_duplicates_test_impl(ctx):
    """Diamond deps produce duplicate plugin structs; dedup keeps first occurrence."""
    env = unittest.begin(ctx)
    plugins = [
        struct(name = "url_launcher", platforms = {"web": {"dartPluginClass": "A"}}),
        struct(name = "shared_prefs", platforms = {"web": {"dartPluginClass": "B"}}),
        struct(name = "url_launcher", platforms = {"web": {"dartPluginClass": "A"}}),
        struct(name = "shared_prefs", platforms = {"web": {"dartPluginClass": "B"}}),
    ]
    result = dedup_plugins(plugins)
    asserts.equals(env, 2, len(result))
    asserts.equals(env, "url_launcher", result[0].name)
    asserts.equals(env, "shared_prefs", result[1].name)
    return unittest.end(env)

def _dedup_plugins_preserves_order_test_impl(ctx):
    """First occurrence of each plugin name wins."""
    env = unittest.begin(ctx)
    plugins = [
        struct(name = "b", platforms = {}),
        struct(name = "a", platforms = {}),
        struct(name = "b", platforms = {"linux": {}}),
    ]
    result = dedup_plugins(plugins)
    asserts.equals(env, 2, len(result))
    asserts.equals(env, "b", result[0].name)
    asserts.equals(env, "a", result[1].name)

    # First occurrence's platforms should be preserved.
    asserts.equals(env, {}, result[0].platforms)
    return unittest.end(env)

_t0_test = unittest.make(_package_name_explicit_attr_wins_test_impl)
_t1_test = unittest.make(_package_name_falls_back_to_label_package_test_impl)
_t2_test = unittest.make(_package_name_falls_back_to_label_name_test_impl)
_t3_test = unittest.make(_lib_root_workspace_root_and_package_test_impl)
_t4_test = unittest.make(_lib_root_strips_trailing_lib_test_impl)
_t5_test = unittest.make(_dedup_plugins_removes_duplicates_test_impl)
_t6_test = unittest.make(_dedup_plugins_preserves_order_test_impl)

def flutter_library_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test)
