"""Unit tests for flutter_application platform detection logic."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:common.bzl", "detect_target_platform", "launch_build_args")
load("//flutter/private:plugin_registrant.bzl", "DEV_REGISTRANT_PLATFORMS")

def _ios_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = True,
        is_macos = False,
        is_linux = False,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "ios", result)
    return unittest.end(env)

def _macos_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = True,
        is_linux = False,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "macos", result)
    return unittest.end(env)

def _linux_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = False,
        is_linux = True,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "linux", result)
    return unittest.end(env)

def _windows_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = False,
        is_linux = False,
        is_windows = True,
        is_android = False,
    )
    asserts.equals(env, "windows", result)
    return unittest.end(env)

def _android_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = False,
        is_macos = False,
        is_linux = False,
        is_windows = False,
        is_android = True,
    )
    asserts.equals(env, "android", result)
    return unittest.end(env)

def _ios_priority_over_macos_test_impl(ctx):
    """iOS should take priority if both iOS and macOS match (edge case)."""
    env = unittest.begin(ctx)
    result = detect_target_platform(
        is_ios = True,
        is_macos = True,
        is_linux = False,
        is_windows = False,
        is_android = False,
    )
    asserts.equals(env, "ios", result)
    return unittest.end(env)

# `launch_build_args` has to stay in step with `Device.buildArgs` in
# tools/dev_tool/lib/device.dart — the app reports these flags so an attaching
# dev tool can rebuild in the configuration the app was actually built in.
# Nothing links the two languages, so these assertions are the link: each
# expected value below is quoted from the corresponding `buildArgs` getter.

def _ios_simulator_build_args_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--ios_multi_cpus=sim_arm64"],
        launch_build_args("ios", is_simulator = True, is_arm64 = True, is_x86_64 = False),
    )
    return unittest.end(env)

def _ios_device_build_args_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--ios_multi_cpus=arm64"],
        launch_build_args("ios", is_simulator = False, is_arm64 = True, is_x86_64 = False),
    )
    return unittest.end(env)

def _android_arm64_build_args_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--platforms=@rules_flutter//flutter/platforms:android_arm64"],
        launch_build_args("android", is_simulator = False, is_arm64 = True, is_x86_64 = False),
    )
    return unittest.end(env)

def _android_x64_build_args_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ["--platforms=@rules_flutter//flutter/platforms:android_x64"],
        launch_build_args("android", is_simulator = False, is_arm64 = False, is_x86_64 = True),
    )
    return unittest.end(env)

def _desktop_build_args_test_impl(ctx):
    """Desktop needs no flag: the app is already in the top-level configuration.

    Emitting `--platforms=` here would move a dev-loop rebuild to a different
    output directory than the one the running app was built in — the exact
    mismatch `build_info` exists to prevent.
    """
    env = unittest.begin(ctx)
    for platform in ["macos", "linux", "windows"]:
        asserts.equals(
            env,
            [],
            launch_build_args(platform, is_simulator = False, is_arm64 = True, is_x86_64 = False),
            msg = "expected no launch flags for %s" % platform,
        )
    return unittest.end(env)

def _dev_registrant_covers_every_platform_test_impl(ctx):
    """Every platform a running app can report has a dev-loop registrant.

    The dev tool's incremental compiler picks its plugin registrant by the
    platform the running app reports, which is whatever
    `detect_target_platform` produced for the launch build. It looks that
    value up in `DEV_REGISTRANT_PLATFORMS`, and a miss is a hard failure
    rather than a fallback — deliberately, because falling back to another
    platform's filter is the silent wrong-plugin-set bug the map exists to
    prevent. So the two lists have to name the same platforms, and nothing in
    the rules couples them: they are separate literals in separate files, and
    a sixth platform added to one alone would surface only at dev-tool
    runtime, on a legitimate run.

    Both directions of the set comparison are asserted: a platform missing
    from the map breaks every dev run on it, and a stale key left in the map
    generates a filter for a platform nothing can produce. What this cannot
    reach is a sixth platform added to `detect_target_platform` behind a
    parameter with a default — the call below would still compile, still name
    five platforms, and still pass. That case is left to the runtime failure,
    which is loud: the dev tool names the platform it could not find and the
    keys it has.
    """
    env = unittest.begin(ctx)
    detected = [
        detect_target_platform(
            is_ios = p == "ios",
            is_macos = p == "macos",
            is_linux = p == "linux",
            is_windows = p == "windows",
            is_android = p == "android",
        )
        # Spelled out rather than read from DEV_REGISTRANT_PLATFORMS, so this
        # compares two lists instead of comparing one with itself.
        for p in ["android", "ios", "linux", "macos", "windows"]
    ]
    asserts.equals(
        env,
        sorted(detected),
        sorted(DEV_REGISTRANT_PLATFORMS),
        msg = "the dev registrant map and detect_target_platform disagree",
    )
    return unittest.end(env)

_t0_test = unittest.make(_ios_detection_test_impl)
_t1_test = unittest.make(_macos_detection_test_impl)
_t2_test = unittest.make(_linux_detection_test_impl)
_t3_test = unittest.make(_windows_detection_test_impl)
_t4_test = unittest.make(_android_detection_test_impl)
_t5_test = unittest.make(_ios_priority_over_macos_test_impl)
_t6_test = unittest.make(_ios_simulator_build_args_test_impl)
_t7_test = unittest.make(_ios_device_build_args_test_impl)
_t8_test = unittest.make(_android_arm64_build_args_test_impl)
_t9_test = unittest.make(_android_x64_build_args_test_impl)
_t10_test = unittest.make(_desktop_build_args_test_impl)
_t11_test = unittest.make(_dev_registrant_covers_every_platform_test_impl)

def flutter_application_test_suite(name):
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
    )
