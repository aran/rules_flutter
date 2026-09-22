"""Unit and analysis tests for macOS application validation and bundling."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:flutter_macos_application.bzl", "flutter_macos_framework", "flutter_macos_native_libs")
load("//flutter/private:validation.bzl", "is_valid_bundle_id", "minimum_os_version_is_below")
load(":apple_bundling.bzl", "fake_application", "outputs_under_target_dir_test")

def _valid_bundle_id_test_impl(ctx):
    env = unittest.begin(ctx)

    valid_ids = [
        "com.example.myapp",
        "com.example.my-app",
        "org.flutter.test123",
        "io.bazel.rules.flutter",
    ]
    for bid in valid_ids:
        asserts.true(env, is_valid_bundle_id(bid), "Expected '%s' to be valid" % bid)

    return unittest.end(env)

def _invalid_bundle_id_test_impl(ctx):
    env = unittest.begin(ctx)

    invalid_ids = [
        "com.example/myapp",
        "com.example my app",
        "com.example:myapp",
        "com.example@myapp",
    ]
    for bid in invalid_ids:
        asserts.false(env, is_valid_bundle_id(bid), "Expected '%s' to be invalid" % bid)

    return unittest.end(env)

def _bundle_id_segment_validation_test_impl(ctx):
    """Bundle IDs must have ≥2 dot-separated segments and no structural issues."""
    env = unittest.begin(ctx)

    # Empty string is invalid.
    asserts.false(env, is_valid_bundle_id(""), "Empty string should be invalid")

    # Single segment (no dots) is invalid.
    asserts.false(env, is_valid_bundle_id("myapp"), "Single segment 'myapp' should be invalid")

    # Leading dot is invalid.
    asserts.false(env, is_valid_bundle_id(".com.example"), "Leading dot should be invalid")

    # Trailing dot is invalid.
    asserts.false(env, is_valid_bundle_id("com.example."), "Trailing dot should be invalid")

    # Consecutive dots are invalid.
    asserts.false(env, is_valid_bundle_id("com..example"), "Consecutive dots should be invalid")

    # Two segments is the minimum valid.
    asserts.true(env, is_valid_bundle_id("com.example"), "Two segments should be valid")

    return unittest.end(env)

# The engine these rules vend is a prebuilt framework with a minimum of its
# own, and the constant is both the default and the floor. Compared segment by
# segment, because macOS spent years in the range where string order and
# version order disagree.
def _minimum_os_version_floor_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.true(env, minimum_os_version_is_below("14.0", "15.0"), "14.0 < 15.0")
    asserts.false(env, minimum_os_version_is_below("15.0", "15.0"), "equal is not below")
    asserts.false(env, minimum_os_version_is_below("16.2", "15.0"), "16.2 > 15.0")

    # "10.9" sorts above "10.14" as text and below it as a version — the whole
    # reason this is not a string comparison.
    asserts.true(env, minimum_os_version_is_below("10.9", "10.14"), "10.9 < 10.14")
    asserts.false(env, minimum_os_version_is_below("10.14", "10.9"), "10.14 > 10.9")

    # A version written short means the same version.
    asserts.false(env, minimum_os_version_is_below("15", "15.0"), "15 == 15.0")
    asserts.false(env, minimum_os_version_is_below("15.0.0", "15"), "15.0.0 == 15")

    return unittest.end(env)

_t0_test = unittest.make(_valid_bundle_id_test_impl)
_t1_test = unittest.make(_invalid_bundle_id_test_impl)
_t2_test = unittest.make(_bundle_id_segment_validation_test_impl)
_t3_test = unittest.make(_minimum_os_version_floor_test_impl)

# -- Bundling ------------------------------------------------------------------
#
# rules_apple places what `additional_contents` hands it under the directory
# that holds it, relative to its owning package. So the App.framework wrapper
# and the native-library staging are each a directory at the package root,
# named after its target so that two apps in one package cannot both declare
# it, with the layout the bundle needs inside it.

def _native_libs_staged_test_impl(ctx):
    """Every library is copied to its basename in one package-root directory."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    outputs = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(outputs), "expected one staged directory, got %s" % outputs)
    if len(outputs) != 1:
        return analysistest.end(env)
    staged = outputs[0]
    asserts.true(env, staged.is_directory, "%s is not a tree artifact" % staged.path)
    asserts.equals(
        env,
        "/".join([p for p in [target.label.package, target.label.name] if p]),
        staged.short_path,
        "the staged directory must sit at its package root, named after its target",
    )

    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterMacOSNativeLibs"
    ]
    asserts.equals(env, 1, len(actions), "expected one staging action")
    if len(actions) != 1:
        return analysistest.end(env)
    argv = actions[0].argv
    pairs = argv[argv.index(staged.path) + 1:]
    sources = pairs[0::2]
    fake_prefix = "/%s/" % ctx.attr.fake_application_name
    asserts.equals(
        env,
        ctx.attr.expected_sources,
        [path.split(fake_prefix, 1)[1] for path in sources],
        "each library once, deduplicated by path, in arrival order",
    )
    asserts.equals(env, ctx.attr.expected_basenames, pairs[1::2])
    asserts.equals(
        env,
        sorted(sources),
        sorted([f.path for f in actions[0].inputs.to_list()]),
        "the action's inputs must be exactly the libraries it copies",
    )
    return analysistest.end(env)

_native_libs_staged_test = analysistest.make(
    _native_libs_staged_test_impl,
    attrs = {
        "expected_basenames": attr.string_list(mandatory = True),
        "expected_sources": attr.string_list(mandatory = True),
        "fake_application_name": attr.string(mandatory = True),
    },
)

def _native_libs_empty_test_impl(ctx):
    """An app with no native libraries gets nothing to bundle, and no action."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, [], target[DefaultInfo].files.to_list())
    asserts.equals(env, [], analysistest.target_actions(env))
    return analysistest.end(env)

_native_libs_empty_test = analysistest.make(_native_libs_empty_test_impl)

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_substrings": attr.string_list(mandatory = True),
    },
)

def _bundling_tests(name):
    """Declare the bundling fixtures and the tests over them.

    Args:
      name: Prefix for every target declared here.

    Returns:
      The test target names.
    """
    staged_app = name + "_fake_app"
    fake_application(
        name = staged_app,
        # `libadd` arrives by both routes. `libsub` is the case the staging
        # exists for: a library that is not at the root of its package.
        native_libs = ["libadd.dylib", "vendor/lib/libsub.dylib"],
        code_assets = ["libadd.dylib", "assets/libasset.dylib"],
        tags = ["manual"],
    )
    flutter_macos_native_libs(
        name = name + "_native_libs",
        application = staged_app,
        tags = ["manual"],
    )
    _native_libs_staged_test(
        name = name + "_native_libs_staged",
        target_under_test = name + "_native_libs",
        fake_application_name = staged_app,
        expected_sources = ["libadd.dylib", "vendor/lib/libsub.dylib", "assets/libasset.dylib"],
        expected_basenames = ["libadd.dylib", "libsub.dylib", "libasset.dylib"],
    )

    fake_application(
        name = name + "_fake_app_empty",
        tags = ["manual"],
    )
    flutter_macos_native_libs(
        name = name + "_native_libs_empty",
        application = name + "_fake_app_empty",
        tags = ["manual"],
    )
    _native_libs_empty_test(
        name = name + "_native_libs_nothing_to_bundle",
        target_under_test = name + "_native_libs_empty",
    )

    # Two different libraries that would both be Contents/Frameworks/libdup.dylib.
    fake_application(
        name = name + "_fake_app_duplicate",
        native_libs = ["one/libdup.dylib"],
        code_assets = ["two/libdup.dylib"],
        tags = ["manual"],
    )
    flutter_macos_native_libs(
        name = name + "_native_libs_duplicate",
        application = name + "_fake_app_duplicate",
        tags = ["manual"],
    )
    _expect_failure_test(
        name = name + "_native_libs_duplicate_basename_fails",
        target_under_test = name + "_native_libs_duplicate",
        expected_substrings = [
            "bundled as Contents/Frameworks/libdup.dylib",
            "_fake_app_duplicate/one/libdup.dylib",
            "_fake_app_duplicate/two/libdup.dylib",
        ],
    )

    # A second, different app in the same package. Built together with the
    # first, any output the two declare under one name conflicts in analysis —
    # which a pair built from the *same* application hides, because identical
    # actions are shared.
    fake_application(
        name = name + "_fake_app_other",
        native_libs = ["libadd.dylib"],
        tags = ["manual"],
    )
    for app in [staged_app, name + "_fake_app_other"]:
        flutter_macos_framework(
            name = app + "_framework",
            application = app,
            tags = ["manual"],
        )
    outputs_under_target_dir_test(
        name = name + "_framework_outputs_under_target_dir",
        target_under_test = staged_app + "_framework",
    )
    flutter_macos_native_libs(
        name = name + "_native_libs_other",
        application = name + "_fake_app_other",
        tags = ["manual"],
    )
    build_test(
        name = name + "_two_apps_one_package",
        targets = [
            staged_app + "_framework",
            name + "_fake_app_other_framework",
            name + "_native_libs",
            name + "_native_libs_other",
        ],
    )

    return [
        name + "_framework_outputs_under_target_dir",
        name + "_native_libs_staged",
        name + "_native_libs_nothing_to_bundle",
        name + "_native_libs_duplicate_basename_fails",
        name + "_two_apps_one_package",
    ]

def macos_test_suite(name):
    unittest.suite(name + "_bundle_id", _t0_test, _t1_test, _t2_test)
    unittest.suite(name + "_minimum_os_version", _t3_test)
    native.test_suite(
        name = name,
        tests = [
            ":" + t
            for t in [name + "_bundle_id", name + "_minimum_os_version"] +
                     _bundling_tests(name)
        ],
    )
