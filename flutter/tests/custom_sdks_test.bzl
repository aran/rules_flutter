"""Tests for which SDKs the root module's custom-SDK tags declare."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:custom_sdks.bzl", "CUSTOM_SDK_TAGS", "checkout_repo_names", "custom_sdks")

def _module(name, is_root, **tags):
    """A module whose tags are, for each kind given, the names it declares."""
    return struct(name = name, is_root = is_root, tags = struct(**{
        kind: [struct(name = n) for n in tags.get(kind, [])]
        for kind in CUSTOM_SDK_TAGS
    }))

def _sdks(*modules):
    return custom_sdks(list(modules), ["flutter"], "flutter")

def _root_declares_each_form_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _sdks(
        _module("app", True, checkout = ["local"], custom_sdk = ["fork"], custom_engine = ["patched"], custom_framework = ["ours"]),
        _module("lib", False),
    )
    asserts.equals(env, None, result.error)
    asserts.equals(env, ["fork", "local", "ours", "patched"], sorted(result.sdks.keys()))
    asserts.equals(env, "custom_engine", result.sdks["patched"].kind)
    asserts.equals(env, "local", result.sdks["local"].tag.name)
    return unittest.end(env)

def _dependency_may_not_declare_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _sdks(_module("app", True), _module("lib", False, custom_engine = ["patched"]))
    asserts.equals(env, {}, result.sdks)
    asserts.true(env, "flutter.custom_engine(name = \"patched\") in module lib" in result.error, result.error)
    asserts.true(env, "Only the root module may" in result.error, result.error)
    return unittest.end(env)

def _default_name_is_the_release_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _sdks(_module("app", True, custom_sdk = ["flutter"]))
    asserts.true(env, "flutter.custom_sdk(name = \"flutter\") takes the name of the release" in result.error, result.error)
    asserts.true(env, "--@rules_flutter//flutter:sdk=<name>" in result.error, result.error)
    return unittest.end(env)

def _name_declared_twice_test_impl(ctx):
    env = unittest.begin(ctx)
    result = _sdks(_module("app", True, checkout = ["local"], custom_sdk = ["local"]))
    asserts.equals(env, "\"local\" is declared twice: by flutter.custom_sdk() and by flutter.checkout().", result.error)
    return unittest.end(env)

def _name_of_a_release_test_impl(ctx):
    env = unittest.begin(ctx)
    result = custom_sdks([_module("app", True, checkout = ["beta"])], ["flutter", "beta"], "flutter")
    asserts.true(env, "both flutter.checkout(name = \"beta\") and flutter.toolchain(name = \"beta\")" in result.error, result.error)
    return unittest.end(env)

def _repositories_are_the_checkouts_own_test_impl(ctx):
    env = unittest.begin(ctx)
    repos = checkout_repo_names("local")
    asserts.equals(env, "local_checkout_framework", repos.framework)
    asserts.equals(env, "local_checkout_engine", repos.engine)
    return unittest.end(env)

_root_declares_each_form_test = unittest.make(_root_declares_each_form_test_impl)
_dependency_may_not_declare_test = unittest.make(_dependency_may_not_declare_test_impl)
_default_name_is_the_release_test = unittest.make(_default_name_is_the_release_test_impl)
_name_declared_twice_test = unittest.make(_name_declared_twice_test_impl)
_name_of_a_release_test = unittest.make(_name_of_a_release_test_impl)
_repositories_are_the_checkouts_own_test = unittest.make(_repositories_are_the_checkouts_own_test_impl)

def custom_sdks_test_suite(name):
    unittest.suite(
        name,
        _root_declares_each_form_test,
        _dependency_may_not_declare_test,
        _default_name_is_the_release_test,
        _name_declared_twice_test,
        _name_of_a_release_test,
        _repositories_are_the_checkouts_own_test,
    )
