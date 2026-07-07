"""Unit tests for validation.bzl dart-define helpers."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:validation.bzl", "is_valid_dart_define")

def _accepts_simple_define_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_valid_dart_define("FOO=bar"))
    return unittest.end(env)

def _accepts_comma_in_value_test_impl(ctx):
    """Values may contain commas (JSON blobs, lists) — the repeatable flag must not care."""
    env = unittest.begin(ctx)
    asserts.true(env, is_valid_dart_define("FOO=a,b"))
    return unittest.end(env)

def _accepts_equals_in_value_test_impl(ctx):
    """Only the first '=' separates key from value."""
    env = unittest.begin(ctx)
    asserts.true(env, is_valid_dart_define("FOO=a=b"))
    return unittest.end(env)

def _accepts_nonreserved_dart_vm_key_test_impl(ctx):
    """Only the two mode keys are reserved, not the whole dart.vm. namespace."""
    env = unittest.begin(ctx)
    asserts.true(env, is_valid_dart_define("dart.vm.other=x"))
    return unittest.end(env)

def _rejects_reserved_profile_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define("dart.vm.profile=true"))
    asserts.false(env, is_valid_dart_define("dart.vm.profile=false"))
    return unittest.end(env)

def _rejects_reserved_product_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define("dart.vm.product=true"))
    asserts.false(env, is_valid_dart_define("dart.vm.product=false"))
    return unittest.end(env)

def _rejects_bare_reserved_key_test_impl(ctx):
    """A define without '=' is still a key; reserved keys stay rejected."""
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define("dart.vm.product"))
    asserts.false(env, is_valid_dart_define("dart.vm.profile"))
    return unittest.end(env)

def _rejects_registrant_define_test_impl(ctx):
    """flutter.dart_plugin_registrant is a reserved key.

    The build sets -Dflutter.dart_plugin_registrant itself (engine
    plugin-registrant hook); a user value would break plugin registration.
    """
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define("flutter.dart_plugin_registrant=file:///x.dart"))
    asserts.false(env, is_valid_dart_define("flutter.dart_plugin_registrant"))
    return unittest.end(env)

def _rejects_empty_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_valid_dart_define(""))
    return unittest.end(env)

_t0_test = unittest.make(_accepts_simple_define_test_impl)
_t1_test = unittest.make(_accepts_comma_in_value_test_impl)
_t2_test = unittest.make(_accepts_equals_in_value_test_impl)
_t3_test = unittest.make(_accepts_nonreserved_dart_vm_key_test_impl)
_t4_test = unittest.make(_rejects_reserved_profile_test_impl)
_t5_test = unittest.make(_rejects_reserved_product_test_impl)
_t6_test = unittest.make(_rejects_bare_reserved_key_test_impl)
_t7_test = unittest.make(_rejects_empty_test_impl)
_t8_test = unittest.make(_rejects_registrant_define_test_impl)

def validation_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test, _t8_test)
