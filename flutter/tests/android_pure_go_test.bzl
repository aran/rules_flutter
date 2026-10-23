"""Unit tests for the flutter_android_app pure-Go transition.

The transition behind `flutter_android_binary_proxy` sets
`@rules_go//go/config:pure` from the `//flutter:android_pure_go` flag. These
tests pin that mapping; the end-to-end effect (no LLVM C++ actions under the
Android app, cgo binaries elsewhere unaffected) is verified with cquery/aquery
on e2e/hello_world.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_android_binary_proxy.bzl", "testing")

def _enables_pure_by_default_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"@rules_go//go/config:pure": True},
        testing.pure_go_transition_impl({"//flutter:android_pure_go": True}, None),
    )
    return unittest.end(env)

_enables_pure_by_default_test = unittest.make(_enables_pure_by_default_test_impl)

def _opt_out_leaves_config_untouched_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {},
        testing.pure_go_transition_impl({"//flutter:android_pure_go": False}, None),
    )
    return unittest.end(env)

_opt_out_leaves_config_untouched_test = unittest.make(_opt_out_leaves_config_untouched_test_impl)

def android_pure_go_test_suite(name):
    unittest.suite(
        name,
        _enables_pure_by_default_test,
        _opt_out_leaves_config_untouched_test,
    )
