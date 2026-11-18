"""Unit tests for flutter_library.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart:utils.bzl", "derive_package_name", "derive_package_root")
load("//flutter/private:flutter_info.bzl", "dedup_plugins", "plugins_in_registration_order")
load("//flutter/private:flutter_library.bzl", "ships_in")

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

def _package_root_repo_root_and_package_test_impl(ctx):
    env = unittest.begin(ctx)

    # derive_package_root converts external/X -> ../X (short_path convention)
    result = derive_package_root("external/my_repo", "packages/my_lib")
    asserts.equals(env, "../my_repo/packages/my_lib", result)
    return unittest.end(env)

def _package_root_strips_trailing_lib_test_impl(ctx):
    env = unittest.begin(ctx)
    result = derive_package_root("", "packages/my_lib/lib")
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

def _plugin(name, dependencies = []):
    return struct(name = name, platforms = {}, dependencies = dependencies)

def _registration_order_test_impl(ctx):
    """flutter_tools' `sortByDependencies`: dependencies first, then by name."""
    env = unittest.begin(ctx)

    def order(plugins):
        return [p.name for p in plugins_in_registration_order(plugins)]

    # No dependencies: by name, whatever the graph order.
    asserts.equals(env, ["a", "b", "c"], order([_plugin("c"), _plugin("a"), _plugin("b")]))

    # `a` depends on `z`: `z` first, though it sorts last.
    asserts.equals(env, ["b", "z", "a"], order([_plugin("a", ["z"]), _plugin("b"), _plugin("z")]))

    # A chain, given dependents first, and a repeat.
    asserts.equals(env, ["c", "b", "a"], order([_plugin("a", ["b"]), _plugin("b", ["c"]), _plugin("c"), _plugin("a", ["b"])]))

    # A dependency that is not a plugin of the app, and one on itself, count for nothing.
    asserts.equals(env, ["a", "b"], order([_plugin("b", ["missing"]), _plugin("a", ["a"])]))

    # A cycle is broken at the fewest unplaced dependencies, then by name.
    asserts.equals(env, ["a", "b"], order([_plugin("b", ["a"]), _plugin("a", ["b"])]))
    asserts.equals(env, ["b", "c", "a"], order([_plugin("a", ["b", "c"]), _plugin("b", ["a"]), _plugin("c", ["b"])]))

    # A struct without `dependencies` depends on none.
    asserts.equals(env, ["a", "b"], order([struct(name = "b", platforms = {}), struct(name = "a", platforms = {})]))
    return unittest.end(env)

def _ships_in_truth_table_test_impl(ctx):
    """An entry without flavors is in every build; one with flavors only in a build of one of them."""
    env = unittest.begin(ctx)

    def entry(flavors = (), platforms = ()):
        return struct(flavors = flavors, platforms = platforms)

    asserts.true(env, ships_in(entry(), "android", ""))
    asserts.true(env, ships_in(entry(), "android", "paid"))
    asserts.true(env, ships_in(entry(("paid",)), "android", "paid"))
    asserts.true(env, ships_in(entry(("paid", "premium")), "web", "premium"))
    asserts.false(env, ships_in(entry(("paid",)), "android", "free"))
    asserts.false(env, ships_in(entry(("paid",)), "android", ""))
    asserts.false(env, ships_in(entry(("paid",)), "android", None))

    # `flutter test` bundles for `tester`, which matches the flavor all the same.
    asserts.true(env, ships_in(entry(("paid",)), "tester", "paid"))
    asserts.false(env, ships_in(entry(("paid",)), "tester", ""))

    # The platform filter is independent of the flavor filter.
    asserts.false(env, ships_in(entry(("paid",), ("web",)), "android", "paid"))
    asserts.true(env, ships_in(entry(("paid",), ("web",)), "web", "paid"))
    asserts.false(env, ships_in(entry(("paid",), ("web",)), "web", "free"))
    return unittest.end(env)

_t7_test = unittest.make(_ships_in_truth_table_test_impl)

_t0_test = unittest.make(_package_name_explicit_attr_wins_test_impl)
_t1_test = unittest.make(_package_name_falls_back_to_label_package_test_impl)
_t2_test = unittest.make(_package_name_falls_back_to_label_name_test_impl)
_t3_test = unittest.make(_package_root_repo_root_and_package_test_impl)
_t4_test = unittest.make(_package_root_strips_trailing_lib_test_impl)
_t5_test = unittest.make(_dedup_plugins_removes_duplicates_test_impl)
_t6_test = unittest.make(_dedup_plugins_preserves_order_test_impl)
_t8_test = unittest.make(_registration_order_test_impl)

def flutter_library_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test)
