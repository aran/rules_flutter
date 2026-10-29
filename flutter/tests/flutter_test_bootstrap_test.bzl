"""Unit tests for the `flutter_test` bootstrap generator.

These exist for the *negative* case. A `flutter_test` whose deps carry only
`package:test_api` is a supported configuration, and its bootstrap must not
mention `package:flutter_test`. No target here can prove that by running —
both `test_api`-only fixtures are `manual` because their bootstraps cannot
compile — so asserting on the generated source is the only way to see it.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_test.bzl", "make_bootstrap_content")
load("//flutter/private:test_config.bzl", "find_test_config")

_TEST_IMPORT = "../../pkg/test/widget_test.dart"
_COMPARATOR_IMPORT = "my_test.golden_comparator.dart"

def _golden_block_present_with_flutter_test_test_impl(ctx):
    """With flutter_test, the comparator is imported and installed.

    Installed inside the `RemoteListener.start` callback and before the user's
    main is returned — the same point `flutter test` installs its own — so a
    test that replaces `goldenFileComparator` itself still wins.
    """
    env = unittest.begin(ctx)
    result = make_bootstrap_content(
        _TEST_IMPORT,
        golden_comparator_import = _COMPARATOR_IMPORT,
    )
    asserts.true(env, "import '%s' as goldens;" % _COMPARATOR_IMPORT in result)
    asserts.true(env, "goldens.installBazelGoldenFileComparator();" in result)

    # Order matters: installing after the user's main had been returned would
    # be too late for a test that reads `goldenFileComparator` at registration.
    install_at = result.find("goldens.installBazelGoldenFileComparator();")
    return_at = result.find("return _runTestMain;")
    asserts.true(env, install_at != -1 and return_at != -1)
    asserts.true(env, install_at < return_at)
    return unittest.end(env)

def _golden_block_absent_without_flutter_test_test_impl(ctx):
    """Without flutter_test, nothing golden-related is emitted at all.

    `goldenFileComparator` and `autoUpdateGoldenFiles` are `package:flutter_test`
    members, so a `test_api`-only suite would fail its kernel compile on an
    import it never asked for. Upstream draws the same line with
    `if (flutterTestDep)`.
    """
    env = unittest.begin(ctx)
    result = make_bootstrap_content(_TEST_IMPORT)
    asserts.true(env, "package:flutter_test" not in result)
    asserts.true(env, "installBazelGoldenFileComparator" not in result)
    asserts.true(env, "golden_comparator" not in result)
    asserts.true(env, "goldenFileComparator" not in result)
    asserts.true(env, "autoUpdateGoldenFiles" not in result)
    return unittest.end(env)

def _bootstrap_keeps_its_contract_either_way_test_impl(ctx):
    """The RemoteListener wiring is identical with and without the block.

    The golden block is an addition inside the existing callback, not a second
    shape of bootstrap; a `test_api`-only target must compile exactly what it
    compiled before goldens existed.
    """
    env = unittest.begin(ctx)
    for golden_import in [None, _COMPARATOR_IMPORT]:
        result = make_bootstrap_content(_TEST_IMPORT, golden_comparator_import = golden_import)
        asserts.true(env, "import 'package:test_api/backend.dart';" in result)
        asserts.true(env, "import '%s' as test;" % _TEST_IMPORT in result)
        asserts.true(env, "RemoteListener.start(() {" in result)
        asserts.true(env, "_catchIsolateErrors();" in result)
        asserts.true(env, "return _runTestMain;" in result)
        asserts.true(env, "FLUTTER_TEST_HARNESS_PORT" in result)
    return unittest.end(env)

def _test_config_wraps_main_after_goldens_test_impl(ctx):
    """A config's `testExecutable` is handed the suite's main, as upstream.

    After the comparator is installed, so a config that sets its own
    `goldenFileComparator` wins, as it does under `flutter test`.
    """
    env = unittest.begin(ctx)
    config = "../../pkg/test/flutter_test_config.dart"
    result = make_bootstrap_content(
        _TEST_IMPORT,
        golden_comparator_import = _COMPARATOR_IMPORT,
        test_config_import = config,
    )
    asserts.true(env, "import '%s' as test_config;" % config in result)
    returned = "return () => test_config.testExecutable(_runTestMain);"
    asserts.true(env, returned in result)
    asserts.true(env, "return _runTestMain;" not in result)
    asserts.true(env, result.find("goldens.installBazelGoldenFileComparator();") < result.find(returned))
    return unittest.end(env)

def _find_test_config_walks_like_flutter_test_test_impl(ctx):
    """The nearest config up from the test, ending after the pubspec's directory."""
    env = unittest.begin(ctx)

    def finds(files, main):
        return find_test_config(main, lambda path: path in files)

    # The nearest wins.
    asserts.equals(env, "test/a/flutter_test_config.dart", finds(
        ["test/a/flutter_test_config.dart", "test/flutter_test_config.dart"],
        "test/a/b_test.dart",
    ))

    # Up through directories without one, to the package root.
    asserts.equals(env, "flutter_test_config.dart", finds(
        ["flutter_test_config.dart"],
        "test/a/b/c_test.dart",
    ))

    # The pubspec's directory is still searched, but nothing above it.
    asserts.equals(env, "app/flutter_test_config.dart", finds(
        ["app/pubspec.yaml", "app/flutter_test_config.dart"],
        "app/test/x_test.dart",
    ))
    asserts.equals(env, None, finds(
        ["app/pubspec.yaml", "flutter_test_config.dart"],
        "app/test/x_test.dart",
    ))

    # A test at the package root, with and without one beside it.
    asserts.equals(env, "flutter_test_config.dart", finds(["flutter_test_config.dart"], "x_test.dart"))
    asserts.equals(env, None, finds([], "x_test.dart"))
    return unittest.end(env)

_t0_test = unittest.make(_golden_block_present_with_flutter_test_test_impl)
_t1_test = unittest.make(_golden_block_absent_without_flutter_test_test_impl)
_t2_test = unittest.make(_bootstrap_keeps_its_contract_either_way_test_impl)
_t3_test = unittest.make(_test_config_wraps_main_after_goldens_test_impl)
_t4_test = unittest.make(_find_test_config_walks_like_flutter_test_test_impl)

def flutter_test_bootstrap_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test)
