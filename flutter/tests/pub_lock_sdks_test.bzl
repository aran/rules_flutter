"""Unit tests for comparing a framework with the Flutter floor of a lock's `sdks:` block."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:pub_lock_sdks.bzl",
    "constraint_lower_bound",
    "version_below_lower_bound",
)

def _reads_the_lower_bound_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [3, 18, 0], constraint_lower_bound(">=3.18.0-18.0.pre.54"))
    asserts.equals(env, [3, 10, 0], constraint_lower_bound(">=3.10.0-0 <4.0.0"))

    # No `>=` term, or one that cannot be read: no opinion rather than a guess.
    asserts.equals(env, None, constraint_lower_bound("<4.0.0"))
    asserts.equals(env, None, constraint_lower_bound("any"))
    asserts.equals(env, None, constraint_lower_bound(">=main"))
    return unittest.end(env)

def _flags_only_a_toolchain_below_the_floor_test_impl(ctx):
    env = unittest.begin(ctx)

    # The failure this catches: lock resolved by a newer Flutter.
    asserts.true(env, version_below_lower_bound("3.47.2", ">=3.47.5"))
    asserts.true(env, version_below_lower_bound("3.47.5", ">=3.47.6"))

    # Satisfied, including the prerelease floor a real lock records: a release
    # version is >= any prerelease of the same triple.
    asserts.false(env, version_below_lower_bound("3.47.6", ">=3.18.0-18.0.pre.54"))
    asserts.false(env, version_below_lower_bound("3.18.0", ">=3.18.0-18.0.pre.54"))
    asserts.false(env, version_below_lower_bound("3.47.6", ">=3.47.6"))

    # Nothing readable to compare against: never fail the build on a guess.
    asserts.false(env, version_below_lower_bound("3.47.6", "any"))
    asserts.false(env, version_below_lower_bound("3.47.6", "<4.0.0"))
    asserts.false(env, version_below_lower_bound("stable", ">=3.47.5"))
    return unittest.end(env)

_reads_the_lower_bound_test = unittest.make(_reads_the_lower_bound_test_impl)
_flags_only_a_toolchain_below_the_floor_test = unittest.make(_flags_only_a_toolchain_below_the_floor_test_impl)

def pub_lock_sdks_test_suite(name):
    unittest.suite(
        name,
        _reads_the_lower_bound_test,
        _flags_only_a_toolchain_below_the_floor_test,
    )
