"""Unit and analysis tests for macOS application validation and bundling."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter/private:flutter_macos_application.bzl", "flutter_macos_app_framework", "flutter_macos_native_libs")
load("//flutter/private:validation.bzl", "is_valid_bundle_id", "minimum_os_version_is_below")
load(":apple_bundling.bzl", "fake_application", "native_library_symbols_test", "native_library_untouched_test", "outputs_under_target_dir_test", "strip_step_test")

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

def _without_config(path):
    # A command line is path-mapped under `--experimental_output_paths=strip`
    # (`bazel-out/cfg/...`) while `File.path` is not, so the two are compared
    # without the configuration segment.
    if path.startswith("bazel-out/"):
        return path.split("/", 2)[2]
    return path

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
    argv = [_without_config(arg) for arg in actions[0].argv]
    fake_prefix = "/%s/" % ctx.attr.fake_application_name

    def in_fake(paths):
        return [path.split(fake_prefix, 1)[1] for path in paths if fake_prefix in "/" + path]

    # `place --os macos --output <dir>`, then a `--library` for each
    # `native_deps` library, which always ships, and the program-assets file,
    # from which the tool places the code assets that ship.
    asserts.true(env, "place" in argv, "the action runs `code_assets.dart place`: %s" % argv)
    asserts.equals(env, "macos", argv[argv.index("--os") + 1])
    asserts.equals(env, _without_config(staged.path), argv[argv.index("--output") + 1])
    asserts.equals(
        env,
        ctx.attr.expected_libraries,
        in_fake([argv[i + 1] for i, arg in enumerate(argv) if arg == "--library"]),
    )

    # Analysis shows a param file's lines in place of the flag that names it.
    asserts.equals(env, "code", argv[argv.index("--holds") + 1], "the libraries view, without the data assets")

    # It reads every candidate library, and no data asset.
    inputs = in_fake([_without_config(f.path) for f in actions[0].inputs.to_list()])
    asserts.equals(env, sorted(ctx.attr.expected_inputs), sorted([i for i in inputs if not i.endswith(".code_selection")]))
    return analysistest.end(env)

_native_libs_staged_test = analysistest.make(
    _native_libs_staged_test_impl,
    attrs = {
        "expected_inputs": attr.string_list(mandatory = True),
        "expected_libraries": attr.string_list(mandatory = True),
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
        dropped_code_assets = ["assets/libdropped.dylib"],
        data_assets = ["data/blob.txt"],
        # Debug: a release framework runs `dsymutil` on its dylib, which rejects
        # a placeholder that is not a Mach-O, and `_two_apps_one_package` below
        # really builds this one.
        debug = True,
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
        expected_libraries = ["libadd.dylib", "vendor/lib/libsub.dylib"],
        expected_inputs = ["libadd.dylib", "vendor/lib/libsub.dylib", "assets/libasset.dylib", "assets/libdropped.dylib"],
    )

    # The libraries the bundle carries beside its binary, stripped and with a
    # dSYM each, as rules_apple treats the binary; every candidate, since
    # which ship is known only once the app is built. The app's `dsyms` group
    # has those that ship: `libdropped`'s is a candidate, which the action
    # collecting them leaves out.
    native_library_symbols_test(
        name = name + "_native_libs_symbols",
        target_under_test = name + "_native_libs",
        mnemonic = "FlutterMacOSNativeLibrary",
        expected_dsyms = [
            "libadd.dylib.dSYM/libadd.dylib",
            "libsub.dylib.dSYM/libsub.dylib",
            "libasset.dylib.dSYM/libasset.dylib",
            "libdropped.dylib.dSYM/libdropped.dylib",
        ],
        expected_always = ["libadd.dylib.dSYM", "libsub.dylib.dSYM"],
        expected_candidates = ["libasset.dylib.dSYM", "libdropped.dylib.dSYM"],
        target_compatible_with = ["@platforms//os:macos"],
    )
    native_library_untouched_test(
        name = name + "_native_libs_untouched",
        target_under_test = name + "_native_libs",
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

    # A second, different app in the same package. Built together with the
    # first, any output the two declare under one name conflicts in analysis —
    # which a pair built from the *same* application hides, because identical
    # actions are shared.
    fake_application(
        name = name + "_fake_app_other",
        debug = True,
        native_libs = ["libadd.dylib"],
        tags = ["manual"],
    )
    for app in [staged_app, name + "_fake_app_other"]:
        flutter_macos_app_framework(
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

    # A release framework runs Xcode's tools on its dylib, so these are only
    # analysed, never built: the fake's dylib is not a Mach-O. Whether the
    # binary is stripped follows the application, as `flutter build` follows
    # `--no-strip`.
    for strip in [True, False]:
        suffix = "_stripped" if strip else "_unstripped"
        fake_application(
            name = name + "_fake_release" + suffix,
            strip_aot = strip,
            tags = ["manual"],
        )
        flutter_macos_app_framework(
            name = name + "_release_framework" + suffix,
            application = name + "_fake_release" + suffix,
            tags = ["manual"],
        )
        strip_step_test(
            name = name + "_release_framework" + suffix + "_test",
            expect_strip = strip,
            target_under_test = name + "_release_framework" + suffix,
            target_compatible_with = ["@platforms//os:macos"],
        )

    return [
        name + "_framework_outputs_under_target_dir",
        name + "_native_libs_staged",
        name + "_native_libs_symbols",
        name + "_native_libs_untouched",
        name + "_native_libs_nothing_to_bundle",
        name + "_two_apps_one_package",
        name + "_release_framework_stripped_test",
        name + "_release_framework_unstripped_test",
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
