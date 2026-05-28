"""Unit tests for macOS application validation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:validation.bzl", "is_valid_bundle_id")

def _valid_bundle_id_test_impl(ctx):
    env = unittest.begin(ctx)

    valid_ids = [
        "com.example.myapp",
        "com.example.my-app",
        "org.flutter.test123",
        "io.bazel.rules.flutter",
    ]
    for bid in valid_ids:
        asserts.true(env, is_valid_bundle_id(bid), "Expected '%s' to be valid" % bid)

    return unittest.end(env)

def _invalid_bundle_id_test_impl(ctx):
    env = unittest.begin(ctx)

    invalid_ids = [
        "com.example/myapp",
        "com.example my app",
        "com.example:myapp",
        "com.example@myapp",
    ]
    for bid in invalid_ids:
        asserts.false(env, is_valid_bundle_id(bid), "Expected '%s' to be invalid" % bid)

    return unittest.end(env)

def _bundle_id_segment_validation_test_impl(ctx):
    """Bundle IDs must have ≥2 dot-separated segments and no structural issues."""
    env = unittest.begin(ctx)

    # Empty string is invalid.
    asserts.false(env, is_valid_bundle_id(""), "Empty string should be invalid")

    # Single segment (no dots) is invalid.
    asserts.false(env, is_valid_bundle_id("myapp"), "Single segment 'myapp' should be invalid")

    # Leading dot is invalid.
    asserts.false(env, is_valid_bundle_id(".com.example"), "Leading dot should be invalid")

    # Trailing dot is invalid.
    asserts.false(env, is_valid_bundle_id("com.example."), "Trailing dot should be invalid")

    # Consecutive dots are invalid.
    asserts.false(env, is_valid_bundle_id("com..example"), "Consecutive dots should be invalid")

    # Two segments is the minimum valid.
    asserts.true(env, is_valid_bundle_id("com.example"), "Two segments should be valid")

    return unittest.end(env)

_t0_test = unittest.make(_valid_bundle_id_test_impl)
_t1_test = unittest.make(_invalid_bundle_id_test_impl)
_t2_test = unittest.make(_bundle_id_segment_validation_test_impl)

def macos_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test)
