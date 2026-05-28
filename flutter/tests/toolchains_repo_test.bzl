"""Unit tests for toolchains_repo.bzl — DESKTOP_CROSS_PAIRS validation."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:toolchains_repo.bzl", "DESKTOP_CROSS_PAIRS", "HOST_PLATFORMS")

def _desktop_cross_pairs_keys_are_host_platforms_test_impl(ctx):
    """Every key in DESKTOP_CROSS_PAIRS must be a valid HOST_PLATFORMS key."""
    env = unittest.begin(ctx)
    for host in DESKTOP_CROSS_PAIRS.keys():
        asserts.true(
            env,
            host in HOST_PLATFORMS,
            "DESKTOP_CROSS_PAIRS key '{}' is not in HOST_PLATFORMS".format(host),
        )
    return unittest.end(env)

def _desktop_cross_pairs_targets_are_host_platforms_test_impl(ctx):
    """Every target in DESKTOP_CROSS_PAIRS must be a valid HOST_PLATFORMS key."""
    env = unittest.begin(ctx)
    for host, targets in DESKTOP_CROSS_PAIRS.items():
        for target in targets:
            asserts.true(
                env,
                target in HOST_PLATFORMS,
                "DESKTOP_CROSS_PAIRS[{}] target '{}' is not in HOST_PLATFORMS".format(host, target),
            )
    return unittest.end(env)

def _desktop_cross_pairs_no_self_pairs_test_impl(ctx):
    """No host should target itself in DESKTOP_CROSS_PAIRS."""
    env = unittest.begin(ctx)
    for host, targets in DESKTOP_CROSS_PAIRS.items():
        asserts.true(
            env,
            host not in targets,
            "DESKTOP_CROSS_PAIRS[{}] contains self-pair".format(host),
        )
    return unittest.end(env)

def _desktop_cross_pairs_no_same_os_test_impl(ctx):
    """No host should target a platform with the same OS (e.g. darwin-arm64 → darwin-x64)."""
    env = unittest.begin(ctx)
    for host, targets in DESKTOP_CROSS_PAIRS.items():
        host_os = HOST_PLATFORMS[host].os
        for target in targets:
            target_os = HOST_PLATFORMS[target].os
            asserts.true(
                env,
                host_os != target_os,
                "DESKTOP_CROSS_PAIRS[{}] targets same-OS platform '{}' (both {})".format(host, target, host_os),
            )
    return unittest.end(env)

def _desktop_cross_pairs_all_hosts_covered_test_impl(ctx):
    """Every HOST_PLATFORMS entry should have a DESKTOP_CROSS_PAIRS entry."""
    env = unittest.begin(ctx)
    for host in HOST_PLATFORMS.keys():
        asserts.true(
            env,
            host in DESKTOP_CROSS_PAIRS,
            "HOST_PLATFORMS key '{}' missing from DESKTOP_CROSS_PAIRS".format(host),
        )
    return unittest.end(env)

_t0_test = unittest.make(_desktop_cross_pairs_keys_are_host_platforms_test_impl)
_t1_test = unittest.make(_desktop_cross_pairs_targets_are_host_platforms_test_impl)
_t2_test = unittest.make(_desktop_cross_pairs_no_self_pairs_test_impl)
_t3_test = unittest.make(_desktop_cross_pairs_no_same_os_test_impl)
_t4_test = unittest.make(_desktop_cross_pairs_all_hosts_covered_test_impl)

def toolchains_repo_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test)
