"""Tests for an app's version: `build_name` and `build_number` on every platform.

Unit tests of `app_version.bzl`'s checks, and analysis tests of the rules that
use them: the Apple bundle version, the Android manifest step, and a web
bundle's version.json, with and without `--@rules_flutter//flutter:build_name`
and `build_number`.

Instantiated from `flutter/tests/app_version/BUILD.bazel`, beside its fixtures.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_apple//apple:providers.bzl", "AppleBundleVersionInfo")
load("//flutter:android.bzl", "flutter_android_manifest_merge")
load("//flutter:defs.bzl", "dart_package_metadata", "flutter_application")
load("//flutter:ios.bzl", "flutter_apple_bundle_version")
load("//flutter:web.bzl", "flutter_web_bundle")
load(
    "//flutter/private:app_version.bzl",
    "android_version",
    "apple_version",
    "manifest_values_conflict",
    "version_arg",
    "version_target_conflict",
    "web_version",
)
load(":action_content.bzl", "written_json")

# -- Checks -------------------------------------------------------------------

def _defaults_test_impl(ctx):
    env = unittest.begin(ctx)
    apple = apple_version("", "")
    asserts.equals(env, None, apple.error)
    asserts.equals(env, "1.0.0", apple.short_version_string)
    asserts.equals(env, "1", apple.build_version)
    android = android_version("", "")
    asserts.equals(env, None, android.error)
    asserts.equals(env, "1.0.0", android.version_name)
    asserts.equals(env, "1", android.version_code)
    web = web_version("", "")
    asserts.equals(env, "1.0.0", web.version)
    asserts.equals(env, "1", web.build_number)
    return unittest.end(env)

def _apple_test_impl(ctx):
    env = unittest.begin(ctx)

    # flutter_tools pads the build name to three numbers; the number as given.
    asserts.equals(env, "2.1.0", apple_version("2.1", "").short_version_string)
    asserts.equals(env, "3.0.0", apple_version("3", "").short_version_string)
    asserts.equals(env, "1.2.3.4", apple_version("1.2.3.4", "").short_version_string)
    asserts.equals(env, "42", apple_version("", "42").build_version)
    asserts.equals(env, "1.2", apple_version("", "1.2").build_version)

    # What flutter_tools would rewrite is an error.
    for name, number, want in [
        ("1.0-beta", "", "build_name = \"1.0-beta\" is not a valid CFBundleShortVersionString"),
        ("1..2", "", "build_name = \"1..2\""),
        (".1", "", "build_name = \".1\""),
        ("", "abc", "build_number = \"abc\" is not a valid CFBundleVersion"),
        ("", "1.", "build_number = \"1.\""),
        ("1.2.3.4.5", "", "at most 4 numbers"),
        ("", "1234567890123456789", "at most 4 numbers and 18 characters"),
        ("1234567890123456", "", "padded to three numbers, \"1234567890123456.0.0\" is over 18"),
    ]:
        error = apple_version(name, number).error
        asserts.true(env, error != None and want in error, "%r %r: %s" % (name, number, error))
    return unittest.end(env)

def _android_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "2100000000", android_version("", "2100000000").version_code)

    # Any build name, as Gradle takes it.
    asserts.equals(env, "2.1-beta+x", android_version("2.1-beta+x", "").version_name)
    for number in ["0", "007", "-1", "1.2", "abc", "2100000001", "99999999999999999999"]:
        error = android_version("", number).error
        asserts.true(
            env,
            error != None and ("build_number = %r is not a valid Android versionCode" % number) in error,
            "%r: %s" % (number, error),
        )
    return unittest.end(env)

def _version_arg_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "42", version_arg(42))
    asserts.equals(env, "2.1.0", version_arg("2.1.0"))
    asserts.equals(env, None, version_arg(None))
    return unittest.end(env)

def _version_target_conflict_test_impl(ctx):
    env = unittest.begin(ctx)
    owner = "flutter_ios_app(name = \"app\")"
    asserts.equals(env, None, version_target_conflict(owner, None, "2.0.0", "3"))
    asserts.equals(env, None, version_target_conflict(owner, ":v", None, None))
    error = version_target_conflict(owner, ":v", "2.0.0", None)
    asserts.true(env, error != None and "sets both `version` and `build_name`" in error, str(error))
    error = version_target_conflict(owner, ":v", "2.0.0", "3")
    asserts.true(env, error != None and "`build_name` and `build_number`" in error, str(error))
    return unittest.end(env)

def _manifest_values_conflict_test_impl(ctx):
    env = unittest.begin(ctx)
    owner = "flutter_android_app(name = \"app\")"

    # Other keys pass through, and so do version keys the arguments leave unset.
    asserts.equals(env, None, manifest_values_conflict(owner, {}, None, None))
    asserts.equals(env, None, manifest_values_conflict(owner, {"appAuthRedirectScheme": "x"}, "2.0.0", "3"))
    asserts.equals(env, None, manifest_values_conflict(owner, {"versionCode": "9", "versionName": "9.0"}, None, None))
    for values, name, number, want in [
        ({"applicationId": "a.b"}, None, None, "sets `applicationId` twice: in `manifest_values` and through `application_id`"),
        ({"minSdkVersion": "21"}, None, None, "through `min_sdk_version`"),
        ({"targetSdkVersion": "35"}, None, None, "through `target_sdk_version`"),
        ({"versionCode": "9"}, None, "3", "sets `versionCode` twice: in `manifest_values` and through `build_number`"),
        ({"versionName": "9.0"}, "2.0.0", None, "through `build_name`"),
    ]:
        error = manifest_values_conflict(owner, values, name, number)
        asserts.true(env, error != None and want in error, "%s: %s" % (values, error))
    error = manifest_values_conflict(owner, select({"//conditions:default": {}}), None, None)
    asserts.true(env, error != None and "must be a dict, not a select" in error, str(error))
    return unittest.end(env)

_defaults_test = unittest.make(_defaults_test_impl)
_apple_test = unittest.make(_apple_test_impl)
_android_test = unittest.make(_android_test_impl)
_version_arg_test = unittest.make(_version_arg_test_impl)
_version_target_conflict_test = unittest.make(_version_target_conflict_test_impl)
_manifest_values_conflict_test = unittest.make(_manifest_values_conflict_test_impl)

# -- Rules --------------------------------------------------------------------

# A build with `--@rules_flutter//flutter:build_name=3.0` and
# `--@rules_flutter//flutter:build_number=123`.
_SETTINGS = {
    str(Label("//flutter:build_name")): "3.0",
    str(Label("//flutter:build_number")): "123",
}

def _apple_bundle_version_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, AppleBundleVersionInfo in target, "fits a rules_apple `version` attribute")
    asserts.equals(
        env,
        {"build_version": ctx.attr.build_version, "short_version_string": ctx.attr.short_version_string},
        written_json(env, ".bundle_version"),
    )
    return analysistest.end(env)

_apple_bundle_version_test = analysistest.make(
    _apple_bundle_version_test_impl,
    attrs = {
        "build_version": attr.string(),
        "short_version_string": attr.string(),
    },
)
_apple_bundle_version_settings_test = analysistest.make(
    _apple_bundle_version_test_impl,
    attrs = {
        "build_version": attr.string(),
        "short_version_string": attr.string(),
    },
    config_settings = _SETTINGS,
)

def _android_version_args_test_impl(ctx):
    env = analysistest.begin(ctx)
    merges = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterManifestMerge"]
    asserts.equals(env, 1, len(merges))
    argv = merges[0].argv
    for flag, value in ctx.attr.expected.items():
        asserts.true(env, flag in argv, "%s missing from %s" % (flag, argv))
        if flag in argv:
            asserts.equals(env, value, argv[argv.index(flag) + 1])
    for flag in ctx.attr.absent:
        asserts.false(env, flag in argv, "%s in %s" % (flag, argv))
    return analysistest.end(env)

_android_version_args_test = analysistest.make(
    _android_version_args_test_impl,
    attrs = {
        "expected": attr.string_dict(),
        "absent": attr.string_list(),
    },
)
_android_version_args_settings_test = analysistest.make(
    _android_version_args_test_impl,
    attrs = {
        "expected": attr.string_dict(),
        "absent": attr.string_list(),
    },
    config_settings = _SETTINGS,
)

def _version_json_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(
        env,
        {
            "app_name": "app_version",
            "version": ctx.attr.version,
            "build_number": ctx.attr.build_number,
            "package_name": "app_version",
        },
        written_json(env, "_version.json"),
    )
    return analysistest.end(env)

_version_json_test = analysistest.make(
    _version_json_test_impl,
    attrs = {
        "version": attr.string(),
        "build_number": attr.string(),
    },
)
_version_json_settings_test = analysistest.make(
    _version_json_test_impl,
    attrs = {
        "version": attr.string(),
        "build_number": attr.string(),
    },
    config_settings = _SETTINGS,
)

def _version_json_check_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterCheckWebVersion"]
    if not ctx.attr.checked:
        asserts.equals(env, 0, len(checks), "a version.json the bundle writes needs no check")
        return analysistest.end(env)
    asserts.equals(env, 1, len(checks), "expected one check of the app's own version.json")
    if len(checks) != 1:
        return analysistest.end(env)
    argv = checks[0].argv
    for flag, value in ctx.attr.expected.items():
        asserts.true(env, flag in argv, "%s missing from %s" % (flag, argv))
        if flag in argv:
            asserts.equals(env, value, argv[argv.index(flag) + 1])
    asserts.true(env, argv[argv.index("--version-json") + 1].endswith("app_version/version.json"), argv)
    asserts.true(env, argv[argv.index("--application") + 1].endswith(ctx.attr.application), argv)

    # The build requires the check: its stamp is a validation output.
    stamp = checks[0].outputs.to_list()[0]
    asserts.true(
        env,
        stamp in target[OutputGroupInfo]._validation.to_list(),
        "the check is a requirement of the bundle",
    )
    return analysistest.end(env)

_version_json_check_test = analysistest.make(
    _version_json_check_test_impl,
    attrs = {
        "checked": attr.bool(default = True),
        "application": attr.string(),
        "expected": attr.string_dict(),
    },
)

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for message in ctx.attr.messages:
        asserts.expect_failure(env, message)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"messages": attr.string_list()},
)
_expect_failure_settings_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"messages": attr.string_list()},
    config_settings = _SETTINGS,
)

# Values no Android or Apple bundle can carry.
_expect_failure_invalid_number_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"messages": attr.string_list()},
    config_settings = {str(Label("//flutter:build_number")): "0"},
)
_expect_failure_invalid_name_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"messages": attr.string_list()},
    config_settings = {str(Label("//flutter:build_name")): "1.0-beta"},
)

def app_version_test_suite(name):
    """Defines the tests, with their fixtures.

    Args:
        name: The test_suite target name, and the prefix of the tests.
    """
    tests = []

    def add(test, suffix, **kwargs):
        test(name = "%s_%s" % (name, suffix), **kwargs)
        tests.append(":%s_%s" % (name, suffix))

    add(_defaults_test, "defaults")
    add(_apple_test, "apple")
    add(_android_test, "android")
    add(_version_arg_test, "version_arg")
    add(_version_target_conflict_test, "version_target_conflict")
    add(_manifest_values_conflict_test, "manifest_values_conflict")

    # Apple.
    flutter_apple_bundle_version(name = "_apple_default", tags = ["manual"])
    add(
        _apple_bundle_version_test,
        "apple_default",
        target_under_test = ":_apple_default",
        build_version = "1",
        short_version_string = "1.0.0",
    )
    flutter_apple_bundle_version(
        name = "_apple_given",
        build_name = "2.1",
        build_number = "42",
        tags = ["manual"],
    )
    add(
        _apple_bundle_version_test,
        "apple_given",
        target_under_test = ":_apple_given",
        build_version = "42",
        short_version_string = "2.1.0",
    )
    flutter_apple_bundle_version(
        name = "_apple_selected",
        build_name = select({"//conditions:default": None}),
        build_number = select({"//conditions:default": "7"}),
        tags = ["manual"],
    )
    add(
        _apple_bundle_version_test,
        "apple_selected",
        target_under_test = ":_apple_selected",
        build_version = "7",
        short_version_string = "1.0.0",
    )
    flutter_apple_bundle_version(
        name = "_apple_invalid",
        build_name = "1.0-beta",
        tags = ["manual"],
    )
    add(
        _expect_failure_test,
        "apple_invalid",
        target_under_test = ":_apple_invalid",
        messages = ["_apple_invalid: build_name = \"1.0-beta\" is not a valid CFBundleShortVersionString"],
    )

    # An app takes the version of the application it is built over; setting
    # the same one is fine, a different one is an error.
    dart_package_metadata(
        name = "pubspec-metadata",
        package_name = "app_version",
        tags = ["manual"],
    )
    flutter_application(
        name = "_versioned_application",
        package = ":pubspec-metadata",
        main = "main.dart",
        build_name = "2.1",
        build_number = "42",
        tags = ["manual"],
    )
    flutter_apple_bundle_version(
        name = "_apple_from_application",
        application = ":_versioned_application",
        tags = ["manual"],
    )
    add(
        _apple_bundle_version_test,
        "apple_from_application",
        target_under_test = ":_apple_from_application",
        build_version = "42",
        short_version_string = "2.1.0",
    )
    flutter_apple_bundle_version(
        name = "_apple_same_as_application",
        application = ":_versioned_application",
        build_name = "2.1",
        tags = ["manual"],
    )
    add(
        _apple_bundle_version_test,
        "apple_same_as_application",
        target_under_test = ":_apple_same_as_application",
        build_version = "42",
        short_version_string = "2.1.0",
    )
    flutter_apple_bundle_version(
        name = "_apple_differs_from_application",
        application = ":_versioned_application",
        build_number = "43",
        tags = ["manual"],
    )
    add(
        _expect_failure_test,
        "apple_differs_from_application",
        target_under_test = ":_apple_differs_from_application",
        messages = ["build_number = \"43\", and the application ", "_versioned_application it is built over has build_number = \"42\""],
    )
    flutter_android_manifest_merge(
        name = "_android_from_application",
        application = ":_versioned_application",
        base = "AndroidManifest.xml",
        set_version = True,
        tags = ["manual"],
    )
    add(
        _android_version_args_test,
        "android_from_application",
        target_under_test = ":_android_from_application",
        expected = {"--version-code": "42", "--version-name": "2.1"},
    )

    # A `versionCode` of `manifest_values` states the version as
    # `build_number` does, so it is the application's or an error.
    flutter_android_manifest_merge(
        name = "_android_manifest_values_from_application",
        application = ":_versioned_application",
        base = "AndroidManifest.xml",
        set_version = True,
        build_number = "42",
        version_stated_as = {"build_number": "`versionCode` in `manifest_values`"},
        tags = ["manual"],
    )
    add(
        _android_version_args_test,
        "android_manifest_values_from_application",
        target_under_test = ":_android_manifest_values_from_application",
        expected = {"--version-code": "42", "--version-name": "2.1"},
    )
    flutter_android_manifest_merge(
        name = "_android_manifest_values_differ",
        application = ":_versioned_application",
        base = "AndroidManifest.xml",
        set_version = True,
        build_number = "5",
        version_stated_as = {"build_number": "`versionCode` in `manifest_values`"},
        tags = ["manual"],
    )
    add(
        _expect_failure_test,
        "android_manifest_values_differ",
        target_under_test = ":_android_manifest_values_differ",
        messages = [
            "`versionCode` in `manifest_values` = \"5\", and the application ",
            "_versioned_application it is built over has build_number = \"42\"",
        ],
    )

    # An application that sets no version reports the defaults: an app that
    # states them agrees with it, and one that states another does not.
    flutter_application(
        name = "_unversioned_application",
        package = ":pubspec-metadata",
        main = "main.dart",
        tags = ["manual"],
    )
    flutter_apple_bundle_version(
        name = "_apple_defaults_of_application",
        application = ":_unversioned_application",
        build_name = "1.0.0",
        build_number = "1",
        tags = ["manual"],
    )
    add(
        _apple_bundle_version_test,
        "apple_defaults_of_application",
        target_under_test = ":_apple_defaults_of_application",
        build_version = "1",
        short_version_string = "1.0.0",
    )
    flutter_android_manifest_merge(
        name = "_android_manifest_values_beside_defaults",
        application = ":_unversioned_application",
        base = "AndroidManifest.xml",
        set_version = True,
        build_number = "5",
        version_stated_as = {"build_number": "`versionCode` in `manifest_values`"},
        tags = ["manual"],
    )
    add(
        _expect_failure_test,
        "android_manifest_values_beside_defaults",
        target_under_test = ":_android_manifest_values_beside_defaults",
        messages = [
            "`versionCode` in `manifest_values` = \"5\", and the application ",
            "has build_number = \"1\", the default.",
        ],
    )

    # Android.
    flutter_android_manifest_merge(
        name = "_android_default",
        base = "AndroidManifest.xml",
        set_version = True,
        tags = ["manual"],
    )
    add(
        _android_version_args_test,
        "android_default",
        target_under_test = ":_android_default",
        expected = {"--version-code": "1", "--version-name": "1.0.0"},
    )
    flutter_android_manifest_merge(
        name = "_android_given",
        base = "AndroidManifest.xml",
        set_version = True,
        build_name = "2.1.0",
        build_number = select({"//conditions:default": "42"}),
        tags = ["manual"],
    )
    add(
        _android_version_args_test,
        "android_given",
        target_under_test = ":_android_given",
        expected = {"--version-code": "42", "--version-name": "2.1.0"},
    )
    flutter_android_manifest_merge(
        name = "_android_unversioned",
        base = "AndroidManifest.xml",
        tags = ["manual"],
    )
    add(
        _android_version_args_test,
        "android_unversioned",
        target_under_test = ":_android_unversioned",
        absent = ["--version-code", "--version-name"],
    )
    flutter_android_manifest_merge(
        name = "_android_invalid",
        base = "AndroidManifest.xml",
        set_version = True,
        build_number = "0",
        tags = ["manual"],
    )
    add(
        _expect_failure_test,
        "android_invalid",
        target_under_test = ":_android_invalid",
        messages = ["_android_invalid: build_number = \"0\" is not a valid Android versionCode"],
    )

    # Web.
    flutter_application(
        name = "_web_default_app",
        main = "main.dart",
        package = ":pubspec-metadata",
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = "_web_default",
        application = ":_web_default_app",
        tags = ["manual"],
    )
    add(
        _version_json_test,
        "web_default",
        target_under_test = ":_web_default",
        version = "1.0.0",
        build_number = "1",
    )
    flutter_application(
        name = "_web_given_app",
        build_name = "2.1.0-beta \"x\"",
        build_number = "42",
        main = "main.dart",
        package = ":pubspec-metadata",
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = "_web_given",
        application = ":_web_given_app",
        tags = ["manual"],
    )
    add(
        _version_json_test,
        "web_given",
        target_under_test = ":_web_given",
        version = "2.1.0-beta \"x\"",
        build_number = "42",
    )
    add(
        _version_json_check_test,
        "web_generated_unchecked",
        target_under_test = ":_web_given",
        checked = False,
    )

    # An own version.json is checked when it is built, against what the
    # program reports: the defaults for an application that sets no version,
    # or the application's own.
    flutter_web_bundle(
        name = "_web_own_file",
        application = ":_web_default_app",
        tags = ["manual"],
        version_json = "version.json",
    )
    add(
        _version_json_check_test,
        "web_own_file_defaults",
        target_under_test = ":_web_own_file",
        application = ":_web_default_app",
        expected = {
            "--version": "1.0.0",
            "--version-default": "true",
            "--build-number": "1",
            "--build-number-default": "true",
            "--name": "flutter/tests/app_version/version.json",
        },
    )
    flutter_application(
        name = "_web_own_file_versioned_app",
        build_number = "42",
        main = "main.dart",
        package = ":pubspec-metadata",
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = "_web_own_file_versioned",
        application = ":_web_own_file_versioned_app",
        tags = ["manual"],
        version_json = "version.json",
    )
    add(
        _version_json_check_test,
        "web_own_file_versioned",
        target_under_test = ":_web_own_file_versioned",
        application = ":_web_own_file_versioned_app",
        expected = {
            "--version": "1.0.0",
            "--version-default": "true",
            "--build-number": "42",
            "--build-number-default": "false",
        },
    )

    # `--@rules_flutter//flutter:build_name` and `build_number` replace the
    # application's version for the build. Whatever takes the version from the
    # application follows them, an app's argument that repeats the
    # application's included.
    add(
        _apple_bundle_version_settings_test,
        "apple_from_application_settings",
        target_under_test = ":_apple_from_application",
        build_version = "123",
        short_version_string = "3.0.0",
    )
    add(
        _apple_bundle_version_settings_test,
        "apple_same_as_application_settings",
        target_under_test = ":_apple_same_as_application",
        build_version = "123",
        short_version_string = "3.0.0",
    )

    # One with no application states its own version, which no setting
    # changes: the app's check fails it at build time, against the program's.
    add(
        _apple_bundle_version_settings_test,
        "apple_without_application_settings",
        target_under_test = ":_apple_given",
        build_version = "42",
        short_version_string = "2.1.0",
    )

    # An argument that differs from the application's is still an error.
    add(
        _expect_failure_settings_test,
        "apple_differs_from_application_settings",
        target_under_test = ":_apple_differs_from_application",
        messages = ["build_number = \"43\", and the application ", "_versioned_application it is built over has build_number = \"42\""],
    )
    add(
        _android_version_args_settings_test,
        "android_from_application_settings",
        target_under_test = ":_android_from_application",
        expected = {
            "--version-code": "123",
            "--version-name": "3.0",
            "--version-code-setting": "--@rules_flutter//flutter:build_number",
            "--version-name-setting": "--@rules_flutter//flutter:build_name",
        },
    )
    flutter_android_manifest_merge(
        name = "_android_repeats_application",
        application = ":_versioned_application",
        base = "AndroidManifest.xml",
        set_version = True,
        build_name = "2.1",
        build_number = "42",
        tags = ["manual"],
    )
    add(
        _android_version_args_settings_test,
        "android_repeats_application_settings",
        target_under_test = ":_android_repeats_application",
        expected = {"--version-code": "123", "--version-name": "3.0"},
    )

    # A `versionCode` of `manifest_values` is written as it is, and cannot
    # follow the setting.
    add(
        _expect_failure_settings_test,
        "android_manifest_values_settings",
        target_under_test = ":_android_manifest_values_from_application",
        messages = [
            "`versionCode` in `manifest_values` = \"42\", and " +
            "`--@rules_flutter//flutter:build_number=123` gives the application ",
            "_versioned_application that version for this build.",
        ],
    )
    add(
        _version_json_settings_test,
        "web_settings",
        target_under_test = ":_web_given",
        version = "3.0",
        build_number = "123",
    )

    # A value the platform cannot carry fails, naming the setting.
    add(
        _expect_failure_invalid_number_test,
        "android_invalid_setting",
        target_under_test = ":_android_from_application",
        messages = ["`--@rules_flutter//flutter:build_number` = \"0\" is not a valid Android versionCode"],
    )
    add(
        _expect_failure_invalid_name_test,
        "apple_invalid_setting",
        target_under_test = ":_apple_from_application",
        messages = ["`--@rules_flutter//flutter:build_name` = \"1.0-beta\" is not a valid CFBundleShortVersionString"],
    )

    native.test_suite(name = name, tests = tests)
