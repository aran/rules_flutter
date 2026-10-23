"""Profile mode compiles with the profile toolchain, and only with `-c opt`.

The engine checks the snapshot it is handed against its own mode: a release
snapshot on the profile engine dies at startup with "VM snapshot invalid", and
so does the reverse. So profile is three things that must agree — the
`dart.vm.profile` define, the non-product platform kernel, and the profile
gen_snapshot — and these tests pin each, in profile and in release, from the
actions the rule declares.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load("//flutter/private:debug_build.bzl", "debug_build")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", "flutter_application")

_PACKAGE = "profile_fixture"
_MAIN = "lib/language_version_main.dart"

_PROFILE = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): True,
}

_RELEASE = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): False,
}

def _action(env, mnemonics):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic in mnemonics]
    asserts.equals(env, 1, len(actions), "expected exactly one of %s" % (mnemonics,))
    return actions[0] if actions else None

def _assert_mode(env, profile):
    kernel = _action(env, ["FlutterKernelCompile"])
    aot = _action(env, ["FlutterAotMacho", "FlutterAotElf"])
    if kernel == None or aot == None:
        return
    argv = " ".join(kernel.argv)

    # Profile keeps the VM service and the profiling hooks, which the product
    # platform has compiled out.
    asserts.equals(env, profile, "/flutter_patched_sdk/" in argv, "non-product platform kernel")
    asserts.equals(env, not profile, "/flutter_patched_sdk_product/" in argv, "product platform kernel")
    asserts.equals(env, profile, "dart.vm.profile=true" in argv, "dart.vm.profile define")
    asserts.equals(env, not profile, "dart.vm.product=true" in argv, "dart.vm.product define")

    # The profile gen_snapshot lives in a repo of its own, fetched only for a
    # profile build.
    asserts.equals(
        env,
        profile,
        "_profile/" in aot.argv[0],
        "gen_snapshot %s should %sbe the profile one" % (aot.argv[0], "" if profile else "not "),
    )

def _profile_test_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_mode(env, profile = True)
    return analysistest.end(env)

def _release_test_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_mode(env, profile = False)
    return analysistest.end(env)

def _refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "needs -c opt")
    return analysistest.end(env)

def _debug_build_clears_profile_test_impl(ctx):
    """`debug_build` clears `//flutter:profile` when forcing `-c dbg`."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    basenames = [f.basename for f in target[DefaultInfo].files.to_list()]
    asserts.true(
        env,
        "_profile_application.dill" in basenames,
        "expected debug kernel .dill in debug_build outputs under profile, got %s" % basenames,
    )
    return analysistest.end(env)

_profile_test = analysistest.make(_profile_test_impl, config_settings = _PROFILE)
_release_test = analysistest.make(_release_test_impl, config_settings = _RELEASE)
_debug_build_clears_profile_test = analysistest.make(
    _debug_build_clears_profile_test_impl,
    config_settings = _PROFILE,
)
_refused_dbg_test = analysistest.make(
    _refused_test_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        str(Label("//flutter:profile")): True,
    },
)
_refused_fastbuild_test = analysistest.make(
    _refused_test_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:compilation_mode": "fastbuild",
        str(Label("//flutter:profile")): True,
    },
)

def profile_mode_test_suite(name):
    """Instantiate the fixtures and the analysis tests over them.

    The fixtures are `manual` and never built: with no `deps` there is no
    `package:flutter`, so they would not compile. The tests read the actions
    analysis declares.

    Args:
      name: The test_suite name.
    """
    flutter_application(
        name = "_profile_application",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_aot_target(
        name = "_profile_aot",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    debug_build(
        name = "_profile_debug_build",
        targets = [":_profile_application"],
        tags = ["manual"],
    )

    tests = []
    for fixture in ["_profile_application", "_profile_aot"]:
        for suffix, rule, compatible in [
            ("profile", _profile_test, HOST_COMPATIBLE),
            ("release", _release_test, HOST_COMPATIBLE),
            ("refused_dbg", _refused_dbg_test, []),
            ("refused_fastbuild", _refused_fastbuild_test, []),
        ]:
            test_name = "%s%s_%s_test" % (name, fixture, suffix)
            rule(
                name = test_name,
                target_under_test = ":" + fixture,
                target_compatible_with = compatible,
            )
            tests.append(":" + test_name)

    debug_build_test_name = "%s_debug_build_clears_profile_test" % name
    _debug_build_clears_profile_test(
        name = debug_build_test_name,
        target_under_test = ":_profile_debug_build",
    )
    tests.append(":" + debug_build_test_name)

    native.test_suite(name = name, tests = tests)
