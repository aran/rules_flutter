"""Unit tests for what a Flutter SDK package needs of the versions the build uses.

The build has one version of each package, the highest any lock records. A
Flutter SDK package's pubspec constrains some of them (`flutter_test` holds
`test_api` at exactly one version), and the package's fetch fails when the
version the build uses is one it does not allow, naming the SDK, the lock that
brings the version and the command that re-resolves it against that SDK.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:framework_source.bzl", "dependency_constraint_message")

_APP = "@@//app:pubspec.lock"
_TOOLS = "@@rules_flutter+//:pubspec.lock"

_FLUTTER_TEST = {
    "name": "flutter_test",
    "dependencies": {
        "flutter": {"sdk": "flutter"},
        "test_api": "0.7.14",
        "matcher": "0.12.20",
        "path": "^1.9.0",
    },
}

def _index(versions, version_locks = {}, sdk_packages = ["flutter", "flutter_test"]):
    return struct(
        versions = versions,
        version_locks = version_locks,
        sdk_packages = {n: True for n in sdk_packages},
        locks = [_APP, _TOOLS],
    )

def _a_fitting_lock_says_nothing_test_impl(ctx):
    env = unittest.begin(ctx)

    index = _index({"test_api": "0.7.14", "matcher": "0.12.20", "path": "1.9.1"})
    asserts.equals(env, None, dependency_constraint_message(index, "flutter", "flutter_test", _FLUTTER_TEST))

    # A dependency no lock lists, and one on another SDK package, are not this
    # check's concern.
    asserts.equals(env, None, dependency_constraint_message(_index({}), "flutter", "flutter_test", _FLUTTER_TEST))
    asserts.equals(env, None, dependency_constraint_message(_index({"flutter": "0.0.0"}), "flutter", "flutter_test", _FLUTTER_TEST))

    return unittest.end(env)

a_fitting_lock_says_nothing_test = unittest.make(_a_fitting_lock_says_nothing_test_impl)

def _a_version_past_an_exact_pin_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    # The app's lock holds the pin; rules_flutter's tool lock raises it.
    index = _index(
        {"test_api": "0.7.15", "matcher": "0.12.20", "path": "1.9.1"},
        version_locks = {"test_api": [_TOOLS], "matcher": [_APP], "path": [_APP]},
    )
    message = dependency_constraint_message(index, "beta", "flutter_test", _FLUTTER_TEST)
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
    message = dependency_constraint_message(index, "flutter", "flutter_test", _FLUTTER_TEST)
    asserts.true(env, message != None, "a version outside the SDK package's range passed")
    for fragment in [
        "needs path ^1.9.0, and the build uses path 2.0.0, which {} records".format(_APP),
        "-- get --directory=app",
    ]:
        asserts.true(env, fragment in message, "{} not in:\n{}".format(fragment, message))

    return unittest.end(env)

a_version_outside_a_range_is_refused_test = unittest.make(_a_version_outside_a_range_is_refused_test_impl)

def framework_source_test_suite(name):
    unittest.suite(
        name,
        a_fitting_lock_says_nothing_test,
        a_version_past_an_exact_pin_is_refused_test,
        a_version_outside_a_range_is_refused_test,
    )
