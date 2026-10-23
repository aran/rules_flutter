"""Unit tests for the `sdks:` check that compares a lock against the toolchain."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    "//flutter/private:pub_lock_sdks.bzl",
    "constraint_lower_bound",
    "hosted_package_sha256",
    "parse_lock_sdk_constraints",
    "version_below_lower_bound",
)

_LOCK = """packages:
  meta:
    dependency: transitive
    description:
      name: meta
      sha256: "abc"
      url: "https://pub.dev"
    source: hosted
    version: "1.18.0"
sdks:
  dart: ">=3.10.0-0 <4.0.0"
  flutter: ">=3.18.0-18.0.pre.54"
"""

def _parses_the_sdks_block_test_impl(ctx):
    env = unittest.begin(ctx)
    sdks = parse_lock_sdk_constraints(_LOCK)
    asserts.equals(env, ">=3.10.0-0 <4.0.0", sdks.get("dart"))
    asserts.equals(env, ">=3.18.0-18.0.pre.54", sdks.get("flutter"))
    return unittest.end(env)

def _lock_without_sdks_block_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, {}, parse_lock_sdk_constraints("packages:\n  meta:\n    version: \"1.0.0\"\n"))
    return unittest.end(env)

def _reads_the_lower_bound_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [3, 18, 0], constraint_lower_bound(">=3.18.0-18.0.pre.54"))
    asserts.equals(env, [3, 10, 0], constraint_lower_bound(">=3.10.0-0 <4.0.0"))

    # Build metadata is not part of the floor: it is stripped from the
    # constraint just like the prerelease is.
    asserts.equals(env, [3, 47, 0], constraint_lower_bound(">=3.47.0+1"))
    asserts.equals(env, [3, 47, 7], constraint_lower_bound(">=3.47.7-1.0.pre+x"))

    # No `>=` term, or one that cannot be read: no opinion rather than a guess.
    asserts.equals(env, None, constraint_lower_bound("<4.0.0"))
    asserts.equals(env, None, constraint_lower_bound("any"))
    asserts.equals(env, None, constraint_lower_bound(">=main"))
    return unittest.end(env)

def _flags_only_a_toolchain_below_the_floor_test_impl(ctx):
    env = unittest.begin(ctx)

    # The failure this catches: lock resolved by a newer Flutter.
    asserts.true(env, version_below_lower_bound("3.41.2", ">=3.44.0"))
    asserts.true(env, version_below_lower_bound("3.44.0", ">=3.44.1"))

    # Satisfied, including the prerelease floor a real lock records: a release
    # version is >= any prerelease of the same triple.
    asserts.false(env, version_below_lower_bound("3.44.1", ">=3.18.0-18.0.pre.54"))
    asserts.false(env, version_below_lower_bound("3.18.0", ">=3.18.0-18.0.pre.54"))
    asserts.false(env, version_below_lower_bound("3.44.1", ">=3.44.1"))

    # Nothing readable to compare against: never fail the build on a guess.
    asserts.false(env, version_below_lower_bound("3.44.1", "any"))
    asserts.false(env, version_below_lower_bound("3.44.1", "<4.0.0"))
    asserts.false(env, version_below_lower_bound("stable", ">=3.44.0"))

    # Build metadata decides nothing on either side: the toolchain version
    # and the constraint floor both compare by release triple only.
    asserts.true(env, version_below_lower_bound("3.0.0+abc", ">=3.47.0"))
    asserts.false(env, version_below_lower_bound("3.47.7+hotfix.1", ">=3.47.0"))
    asserts.true(env, version_below_lower_bound("3.40.0", ">=3.47.0+1"))
    asserts.true(env, version_below_lower_bound("3.47.7-1.0.pre+x", ">=3.47.8"))
    return unittest.end(env)

def _hosted_package_sha256_returns_recorded_value_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "abc123",
        hosted_package_sha256(
            "meta",
            {"version": "1.18.0", "description": {"name": "meta", "sha256": "abc123"}},
            "//:pubspec.lock",
        ),
    )
    return unittest.end(env)

def _hosted_package_missing_sha256_probe_impl(ctx):
    sha = hosted_package_sha256(
        ctx.attr.pkg_name,
        {"version": ctx.attr.pkg_version, "description": {"name": ctx.attr.pkg_name}},
        ctx.attr.lock_label,
    )
    out = ctx.actions.declare_file(ctx.label.name + ".sha256")
    ctx.actions.write(out, sha)
    return [DefaultInfo(files = depset([out]))]

_hosted_package_missing_sha256_probe = rule(
    implementation = _hosted_package_missing_sha256_probe_impl,
    attrs = {
        "pkg_name": attr.string(mandatory = True),
        "pkg_version": attr.string(mandatory = True),
        "lock_label": attr.string(mandatory = True),
    },
)

def _hosted_package_missing_sha256_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        'pub package "meta" 1.18.0 in //:pubspec.lock has no sha256.',
    )
    return analysistest.end(env)

_hosted_package_missing_sha256_fails_test = analysistest.make(
    _hosted_package_missing_sha256_fails_test_impl,
    expect_failure = True,
)

_parses_the_sdks_block_test = unittest.make(_parses_the_sdks_block_test_impl)
_lock_without_sdks_block_test = unittest.make(_lock_without_sdks_block_test_impl)
_reads_the_lower_bound_test = unittest.make(_reads_the_lower_bound_test_impl)
_flags_only_a_toolchain_below_the_floor_test = unittest.make(_flags_only_a_toolchain_below_the_floor_test_impl)
_hosted_package_sha256_returns_recorded_value_test = unittest.make(_hosted_package_sha256_returns_recorded_value_test_impl)

def pub_lock_sdks_test_suite(name):
    _hosted_package_missing_sha256_probe(
        name = name + "_missing_sha256_probe",
        pkg_name = "meta",
        pkg_version = "1.18.0",
        lock_label = "//:pubspec.lock",
        tags = ["manual"],
    )
    _hosted_package_missing_sha256_fails_test(
        name = name + "_missing_sha256_fails",
        target_under_test = ":" + name + "_missing_sha256_probe",
    )

    unittest.suite(
        name + "_unit",
        _parses_the_sdks_block_test,
        _lock_without_sdks_block_test,
        _reads_the_lower_bound_test,
        _flags_only_a_toolchain_below_the_floor_test,
        _hosted_package_sha256_returns_recorded_value_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_missing_sha256_fails",
        ],
    )
