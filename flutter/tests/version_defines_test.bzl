"""A program is compiled with the defines `flutter_tools` adds: its version and the SDK's.

`appBuildName`, `appBuildNumber` and `FlutterVersion` read them as
`String.fromEnvironment`, and read null without. They are in every compile, in
the dev config's `dartDefines` that the dev tool replays on every reload and
restart, and not in the `build_info` the app reports, whose `extraDartDefines`
the dev tool passes back as flags to a build of the same target. A `defines` entry
that sets one is refused, as `flutter_tools` refuses it.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@flutter_version_pin//:version.bzl", "FLUTTER_VERSION")
load("//flutter:defs.bzl", "flutter_application")
load("//flutter/private:flutter_kernel.bzl", "flutter_kernel")
load("//flutter/private:flutter_test.bzl", "flutter_test")
load("//flutter/private:sdk_defines.bzl", "VERSION_DEFINE_KEYS", "sdk_dart_defines", "sdk_engine_revision", "version_dart_defines")
load("//flutter/private:validation.bzl", "is_valid_dart_define")
load("//flutter/private:versions.bzl", "FLUTTER_VERSIONS")
load(":action_content.bzl", "written_json")

_DBG = {"//command_line_option:compilation_mode": "dbg"}
_BUILD_INFO = "-Drules_flutter.build_info="

def pinned_version_defines(build_name = "1.0.0", build_number = "1"):
    """The defines the pinned release's programs get, written out from its versions.bzl entry.

    Args:
        build_name: The program's version name.
        build_number: The program's build number.

    Returns:
        The `KEY=VALUE` defines, in the order `flutter_tools` adds them.
    """
    meta = FLUTTER_VERSIONS[FLUTTER_VERSION]
    return [
        "FLUTTER_BUILD_NAME=" + build_name,
        "FLUTTER_BUILD_NUMBER=" + build_number,
        "FLUTTER_VERSION=" + FLUTTER_VERSION,
        "FLUTTER_CHANNEL=stable",
        "FLUTTER_GIT_URL=https://github.com/flutter/flutter.git",
        "FLUTTER_FRAMEWORK_REVISION=" + meta.framework_revision[:10],
        "FLUTTER_ENGINE_REVISION=" + meta.engine_revision[:10],
        "FLUTTER_DART_VERSION=" + meta.dart_version,
    ]

def _is_version_define(arg):
    key = arg.removeprefix("-D").removeprefix("--define").strip().partition("=")[0]
    return key in VERSION_DEFINE_KEYS

def _sdk_defines_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [
        "FLUTTER_VERSION=3.50.0",
        "FLUTTER_CHANNEL=stable",
        "FLUTTER_GIT_URL=https://github.com/flutter/flutter.git",
        "FLUTTER_FRAMEWORK_REVISION=ab2912035e",
        "FLUTTER_ENGINE_REVISION=371f77202a",
        "FLUTTER_DART_VERSION=3.14.0",
    ], sdk_dart_defines("3.50.0"))
    asserts.equals(env, [
        "FLUTTER_BUILD_NAME=1.0.0",
        "FLUTTER_BUILD_NUMBER=1",
    ], version_dart_defines("3.50.0", "", "")[:2], "unset is flutter create's 1.0.0+1")
    asserts.equals(env, [
        "FLUTTER_BUILD_NAME=2.1",
        "FLUTTER_BUILD_NUMBER=42",
    ], version_dart_defines("3.50.0", "2.1", "42")[:2], "as given, not padded to three numbers")
    return unittest.end(env)

_sdk_defines_test = unittest.make(_sdk_defines_test_impl)

def _engine_revision_test_impl(ctx):
    # The commit the toolchain and the dev root's manifest both report: the
    # engine's own record's, not the release's it is paired with.
    env = unittest.begin(ctx)
    release = FLUTTER_VERSIONS[FLUTTER_VERSION].engine_revision
    asserts.equals(env, "0123abc", sdk_engine_revision({"engine_revision": "0123abc"}, FLUTTER_VERSION))
    asserts.equals(env, release, sdk_engine_revision({}, FLUTTER_VERSION))
    asserts.equals(env, release, sdk_engine_revision({"dart_version": "3.12.0"}, FLUTTER_VERSION))
    asserts.equals(env, "", sdk_engine_revision({}, ""))
    return unittest.end(env)

_engine_revision_test = unittest.make(_engine_revision_test_impl)

def _every_release_describes_itself_test_impl(ctx):
    env = unittest.begin(ctx)
    for version, meta in FLUTTER_VERSIONS.items():
        asserts.equals(env, 40, len(meta.framework_revision), "framework_revision of %s is a 40-char hash" % version)
        asserts.true(env, meta.dart_version[0].isdigit(), "dart_version of %s is a version" % version)
        asserts.equals(env, 6, len(sdk_dart_defines(version)))
    return unittest.end(env)

_every_release_describes_itself_test = unittest.make(_every_release_describes_itself_test_impl)

def _reserved_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, 8, len(VERSION_DEFINE_KEYS))
    for key in VERSION_DEFINE_KEYS:
        asserts.false(env, is_valid_dart_define(key + "=x"), "%s is reserved" % key)
        asserts.false(env, is_valid_dart_define(key), "bare %s is reserved" % key)
    asserts.true(env, is_valid_dart_define("FLUTTER_BUILD_NAMES=x"), "only the keys themselves")
    return unittest.end(env)

_reserved_test = unittest.make(_reserved_test_impl)

def _kernel(env):
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernels), "expected one DartKernel")
    return kernels[0] if kernels else None

def _compile_impl(ctx):
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel != None:
        got = [a.removeprefix("-D") for a in kernel.argv if _is_version_define(a)]
        asserts.equals(env, pinned_version_defines(ctx.attr.build_name, ctx.attr.build_number), got, "version defines in the compile: %s" % kernel.argv)
    return analysistest.end(env)

_compile_test = analysistest.make(
    _compile_impl,
    attrs = {"build_name": attr.string(default = "1.0.0"), "build_number": attr.string(default = "1")},
)

# `--@rules_flutter//flutter:build_name` and `build_number` replace the
# program's own, as `flutter build --build-name` and `--build-number` do.
_SETTINGS = {
    str(Label("//flutter:build_name")): "3.0.0",
    str(Label("//flutter:build_number")): "123",
}
_compile_settings_test = analysistest.make(
    _compile_impl,
    attrs = {"build_name": attr.string(default = "1.0.0"), "build_number": attr.string(default = "1")},
    config_settings = _SETTINGS,
)

def _dev_loop_impl(ctx):
    env = analysistest.begin(ctx)
    kernel = _kernel(env)
    if kernel == None:
        return analysistest.end(env)
    info = [a for a in kernel.argv if a.startswith(_BUILD_INFO)]
    asserts.equals(env, 1, len(info), "expected the build_info define: %s" % kernel.argv)
    if info:
        replayed = json.decode(info[0][len(_BUILD_INFO):])["extraDartDefines"]
        asserts.equals(env, ["FLAG=2"], replayed, "the app's report holds the flag alone: the target has its defines and versions")
    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(
            env,
            ["USER=1", "FLAG=2"] + pinned_version_defines("2.3.4", "7"),
            config["dartDefines"],
            "the dev tool replays the version on every reload and restart",
        )
    return analysistest.end(env)

_dev_loop_test = analysistest.make(_dev_loop_impl, config_settings = _DBG | {
    str(Label("@rules_dart//dart:extra_dart_defines")): ["FLAG=2"],
})

def _test_compile_impl(ctx):
    env = analysistest.begin(ctx)
    compiles = [a for a in analysistest.target_actions(env) if a.mnemonic == ctx.attr.mnemonic]
    asserts.equals(env, 1, len(compiles), "expected one %s" % ctx.attr.mnemonic)
    for action in compiles:
        # `-D<define>` to frontend_server, `--define <define>` to the kernel tool.
        got = [a.removeprefix("-D") for a in action.argv if _is_version_define(a)]

        # The SDK's come with the kernel SDK's runtime and the app's from the
        # configuration, so the order is not the one `flutter_tools` writes.
        asserts.equals(env, sorted(pinned_version_defines("1.0.0", "1")), sorted(got), "version defines of %s: %s" % (ctx.attr.mnemonic, action.argv))
    return analysistest.end(env)

_test_compile_attrs = {"mnemonic": attr.string(mandatory = True)}
_modular_test = analysistest.make(_test_compile_impl, attrs = _test_compile_attrs)
_whole_program_test = analysistest.make(
    _test_compile_impl,
    attrs = _test_compile_attrs,
    config_settings = {str(Label("@rules_dart//dart:modular_kernel")): False},
)

# `flutter test` takes no `--build-name` or `--build-number`: a test keeps its own.
_test_settings_test = analysistest.make(
    _test_compile_impl,
    attrs = _test_compile_attrs,
    config_settings = _SETTINGS,
)

def version_defines_test_suite(name):
    """Fixtures and tests for the version defines of an application, a kernel target and a test.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_version_app",
        package = ":pubspec-metadata",
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_application(
        name = "_versioned_app",
        package = ":pubspec-metadata",
        build_name = "2.3.4",
        build_number = "7",
        defines = ["USER=1"],
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_kernel(
        name = "_version_kernel",
        package = ":pubspec-metadata",
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_test(
        name = "_version_test",
        package = ":pubspec-metadata",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
        deps = ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
    )
    _compile_test(name = name + "_app", target_under_test = ":_version_app")
    _compile_test(
        name = name + "_app_versioned",
        target_under_test = ":_versioned_app",
        build_name = "2.3.4",
        build_number = "7",
    )
    _compile_test(name = name + "_kernel_target", target_under_test = ":_version_kernel")
    _compile_settings_test(
        name = name + "_app_settings",
        target_under_test = ":_versioned_app",
        build_name = "3.0.0",
        build_number = "123",
    )
    _compile_settings_test(
        name = name + "_kernel_target_settings",
        target_under_test = ":_version_kernel",
        build_name = "3.0.0",
        build_number = "123",
    )
    _test_settings_test(name = name + "_test_settings", target_under_test = ":_version_test.program", mnemonic = "DartEntryKernel")
    _dev_loop_test(name = name + "_dev_loop", target_under_test = ":_versioned_app")
    _modular_test(name = name + "_test_modular", target_under_test = ":_version_test.program", mnemonic = "DartEntryKernel")
    _whole_program_test(name = name + "_test_whole_program", target_under_test = ":_version_test.program", mnemonic = "DartKernel")
    _sdk_defines_test(name = name + "_sdk_defines")
    _engine_revision_test(name = name + "_engine_revision")
    _every_release_describes_itself_test(name = name + "_every_release")
    _reserved_test(name = name + "_reserved")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_app",
            ":" + name + "_app_versioned",
            ":" + name + "_kernel_target",
            ":" + name + "_app_settings",
            ":" + name + "_kernel_target_settings",
            ":" + name + "_test_settings",
            ":" + name + "_dev_loop",
            ":" + name + "_test_modular",
            ":" + name + "_test_whole_program",
            ":" + name + "_sdk_defines",
            ":" + name + "_engine_revision",
            ":" + name + "_every_release",
            ":" + name + "_reserved",
        ],
    )
