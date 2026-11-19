"""Unit tests for what a Flutter SDK package needs of the versions the build uses.

The build has one version of each package, the highest any lock records. A
Flutter SDK package's pubspec constrains some of them (`flutter_test` holds
`test_api` at exactly one version), and the package's target fails when the
version the build uses is one it does not allow, naming the SDK, the lock that
brings the version and the command that re-resolves it against that SDK. The
repository still fetches: every SDK's packages do, under `bazel fetch --all`,
and a lock may fit only the SDK the build uses.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:engine.bzl", "flutter_missing_slice")
load("//flutter/private:framework_source.bzl", "dependency_constraint_message", "lock_floor_message", "locked_versions", "write_failing_stub")

_APP = "@@//app:pubspec.lock"
_TOOLS = "@@rules_flutter+//:pubspec.lock"

def _index(versions, version_locks = {}, sdk_packages = ["flutter", "flutter_test"]):
    return struct(
        versions = versions,
        version_locks = version_locks,
        sdk_packages = {n: True for n in sdk_packages},
        locks = [_APP, _TOOLS],
    )

def _locked_versions_leave_out_the_sdk_packages_test_impl(ctx):
    env = unittest.begin(ctx)

    # An SDK package is locked at 0.0.0, which no constraint is compared with.
    index = _index({"test_api": "0.7.14", "flutter": "0.0.0", "path": "1.9.1"})
    asserts.equals(env, {"test_api": "0.7.14", "path": "1.9.1"}, locked_versions(index))

    return unittest.end(env)

locked_versions_leave_out_the_sdk_packages_test = unittest.make(_locked_versions_leave_out_the_sdk_packages_test_impl)

def _a_fitting_lock_says_nothing_test_impl(ctx):
    env = unittest.begin(ctx)

    index = _index({"test_api": "0.7.14", "matcher": "0.12.20", "path": "1.9.1"})
    asserts.equals(env, None, dependency_constraint_message(index, ["flutter"], "flutter_test", {}))

    return unittest.end(env)

a_fitting_lock_says_nothing_test = unittest.make(_a_fitting_lock_says_nothing_test_impl)

def _a_version_past_an_exact_pin_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    # The app's lock holds the pin; rules_flutter's tool lock raises it.
    index = _index(
        {"test_api": "0.7.15", "matcher": "0.12.20", "path": "1.9.1"},
        version_locks = {"test_api": [_TOOLS], "matcher": [_APP], "path": [_APP]},
    )
    message = dependency_constraint_message(index, ["beta"], "flutter_test", {"test_api": "0.7.14"})
    asserts.true(env, message != None, "a version the SDK package forbids passed")
    for fragment in [
        "\"beta\" Flutter SDK",
        "package:flutter_test needs test_api 0.7.14, and the build uses test_api 0.7.15, which {} records".format(_TOOLS),
        "`test_api: 0.7.14`",
    ]:
        asserts.true(env, fragment in message, "{} not in:\n{}".format(fragment, message))

    # Re-resolved against the SDK the check is of, and only the lock that
    # brings the version.
    asserts.true(env, message.endswith("\n    bazel run --@rules_flutter//flutter:sdk=beta @rules_flutter//flutter/pub -- get"), message)
    asserts.false(env, "matcher" in message, message)

    return unittest.end(env)

a_version_past_an_exact_pin_is_refused_test = unittest.make(_a_version_past_an_exact_pin_is_refused_test_impl)

def _a_version_outside_a_range_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    index = _index({"path": "2.0.0"}, version_locks = {"path": [_APP]})
    message = dependency_constraint_message(index, ["flutter"], "flutter_test", {"path": "^1.9.0"})
    asserts.true(env, message != None, "a version outside the SDK package's range passed")
    for fragment in [
        "needs path ^1.9.0, and the build uses path 2.0.0, which {} records".format(_APP),
        "-- get --directory=app",
    ]:
        asserts.true(env, fragment in message, "{} not in:\n{}".format(fragment, message))

    return unittest.end(env)

a_version_outside_a_range_is_refused_test = unittest.make(_a_version_outside_a_range_is_refused_test_impl)

def _a_lock_above_the_framework_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    index = struct(flutter_constraints = {_APP: ">=3.40.0", _TOOLS: ""})
    asserts.equals(env, None, lock_floor_message(index, ["beta"], "3.40.1"))
    message = lock_floor_message(index, ["beta"], "3.38.0")
    asserts.true(env, message != None, "a lock above the framework passed")
    for fragment in [
        "{} was resolved against a newer Flutter than the framework of the \"beta\" Flutter SDK".format(_APP),
        "requires flutter >=3.40.0, and the framework is 3.38.0",
        "bazel run --@rules_flutter//flutter:sdk=beta @rules_flutter//flutter/pub -- get --directory=app",
    ]:
        asserts.true(env, fragment in message, "{} not in:\n{}".format(fragment, message))

    return unittest.end(env)

a_lock_above_the_framework_is_refused_test = unittest.make(_a_lock_above_the_framework_is_refused_test_impl)

def _a_shared_framework_names_every_sdk_test_impl(ctx):
    """A framework several SDKs share is named by all of them, with a command for each."""
    env = unittest.begin(ctx)

    index = struct(flutter_constraints = {_APP: ">=3.40.0"})
    message = lock_floor_message(index, ["flutter", "engine_only"], "3.38.0")
    for fragment in [
        "than the framework of the Flutter SDKs \"flutter\" and \"engine_only\":",
        "with any of the SDKs that share it:",
        "bazel run --@rules_flutter//flutter:sdk=flutter @rules_flutter//flutter/pub -- get --directory=app",
        "bazel run --@rules_flutter//flutter:sdk=engine_only @rules_flutter//flutter/pub -- get --directory=app",
    ]:
        asserts.true(env, fragment in message, "{} not in:\n{}".format(fragment, message))

    index = _index({"test_api": "0.7.15"}, version_locks = {"test_api": [_APP]})
    message = dependency_constraint_message(index, ["a", "b", "c"], "flutter_test", {"test_api": "0.7.14"})
    asserts.true(env, "The locks do not fit the framework of the Flutter SDKs \"a\", \"b\" and \"c\":" in message, message)
    for sdk in ["a", "b", "c"]:
        asserts.true(env, "--@rules_flutter//flutter:sdk={} ".format(sdk) in message, message)

    return unittest.end(env)

a_shared_framework_names_every_sdk_test = unittest.make(_a_shared_framework_names_every_sdk_test_impl)

def _a_failing_stub_declares_each_target_test_impl(ctx):
    """The stub's targets carry the message as written."""
    env = unittest.begin(ctx)

    written = {}
    fake = struct(file = lambda path, content: written.update({path: content}))
    message = 'FLUTTER_CHECKOUT=/x "y" is not a flutter/flutter checkout'
    write_failing_stub(fake, ["flutter_test", "other"], message)
    build = written["BUILD.bazel"]
    for name in ["flutter_test", "other"]:
        asserts.true(env, "name = %s,\n    message = %s," % (repr(name), repr(message)) in build, build)

    return unittest.end(env)

a_failing_stub_declares_each_target_test = unittest.make(_a_failing_stub_declares_each_target_test_impl)

_STUB_MESSAGE = 'FLUTTER_ENGINE=/nowhere has no out: build the engine in it first. ("quoted")'

def _a_failing_target_fails_with_its_message_impl(ctx):
    """What a stub declares fails at analysis, when something uses it, saying why."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, _STUB_MESSAGE)
    return analysistest.end(env)

_a_failing_target_fails_with_its_message_test = analysistest.make(_a_failing_target_fails_with_its_message_impl, expect_failure = True)

def framework_source_test_suite(name):
    flutter_missing_slice(
        name = name + "_stubbed",
        message = _STUB_MESSAGE,
        tags = ["manual"],
    )
    _a_failing_target_fails_with_its_message_test(
        name = name + "_a_failing_target_fails_with_its_message",
        target_under_test = ":" + name + "_stubbed",
    )
    unittest.suite(
        name + "_units",
        a_fitting_lock_says_nothing_test,
        a_version_past_an_exact_pin_is_refused_test,
        a_version_outside_a_range_is_refused_test,
        locked_versions_leave_out_the_sdk_packages_test,
        a_lock_above_the_framework_is_refused_test,
        a_shared_framework_names_every_sdk_test,
        a_failing_stub_declares_each_target_test,
    )
    native.test_suite(
        name = name,
        tests = [name + "_units", name + "_a_failing_target_fails_with_its_message"],
    )
