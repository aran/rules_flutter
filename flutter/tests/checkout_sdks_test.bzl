"""Tests for which SDKs the `flutter.checkout` tags declare."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:checkout_sdks.bzl", "checkout_repo_names", "checkout_sdks")

def _tag(name):
    return struct(name = name, path_env = "FLUTTER_CHECKOUT", engines_env = "FLUTTER_LOCAL_ENGINES", checkout = None, material_fonts_sha256 = "")

def _module(name, is_root, *checkouts):
    return struct(name = name, is_root = is_root, tags = struct(checkout = [_tag(c) for c in checkouts]))

def _root_declares_checkouts_test_impl(ctx):
    env = unittest.begin(ctx)
    result = checkout_sdks([_module("app", True, "local", "other"), _module("lib", False)], ["flutter"])
    asserts.equals(env, None, result.error)
    asserts.equals(env, ["local", "other"], sorted(result.tags.keys()))
    asserts.equals(env, "FLUTTER_CHECKOUT", result.tags["local"].path_env)
    return unittest.end(env)

def _dependency_may_not_declare_test_impl(ctx):
    env = unittest.begin(ctx)
    result = checkout_sdks([_module("app", True), _module("lib", False, "local")], ["flutter"])
    asserts.equals(env, {}, result.tags)
    asserts.true(env, "flutter.checkout(name = \"local\") in module lib" in result.error, result.error)
    asserts.true(env, "Only the root module may" in result.error, result.error)
    return unittest.end(env)

def _name_declared_twice_test_impl(ctx):
    env = unittest.begin(ctx)
    result = checkout_sdks([_module("app", True, "local", "local")], ["flutter"])
    asserts.equals(env, "flutter.checkout(name = \"local\") is declared twice.", result.error)
    return unittest.end(env)

def _name_of_a_toolchain_test_impl(ctx):
    env = unittest.begin(ctx)
    result = checkout_sdks([_module("app", True, "flutter")], ["flutter"])
    asserts.true(env, "both flutter.checkout(name = \"flutter\") and flutter.toolchain(name = \"flutter\")" in result.error, result.error)
    return unittest.end(env)

def _repositories_are_the_checkouts_own_test_impl(ctx):
    env = unittest.begin(ctx)
    repos = checkout_repo_names("local")
    asserts.equals(env, "local_checkout_framework", repos.framework)
    asserts.equals(env, "local_checkout_engine", repos.engine)
    return unittest.end(env)

_root_declares_checkouts_test = unittest.make(_root_declares_checkouts_test_impl)
_dependency_may_not_declare_test = unittest.make(_dependency_may_not_declare_test_impl)
_name_declared_twice_test = unittest.make(_name_declared_twice_test_impl)
_name_of_a_toolchain_test = unittest.make(_name_of_a_toolchain_test_impl)
_repositories_are_the_checkouts_own_test = unittest.make(_repositories_are_the_checkouts_own_test_impl)

def checkout_sdks_test_suite(name):
    unittest.suite(
        name,
        _root_declares_checkouts_test,
        _dependency_may_not_declare_test,
        _name_declared_twice_test,
        _name_of_a_toolchain_test,
        _repositories_are_the_checkouts_own_test,
    )
