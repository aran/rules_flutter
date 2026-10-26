"""Analysis tests: every action that declares `supports-path-mapping` carries
its paths in a form Bazel can map.

Under `--experimental_output_paths=strip`, the command line an analysis test
reads (`Action.argv`, param files inlined) is the mapped one: every output
path Bazel can see reads `bazel-out/cfg/...`. A path still naming a real
configuration came from a string built at analysis time, which keeps two
configurations' actions apart and, inside the action, points at a directory
that does not exist. The same goes for an environment variable, which Bazel
never maps.

So each test asserts, for the mnemonics it names, that the target declares
at least one such action, that every one of them names some mapped path
(which proves the action opted in), and that none names an unmapped one.

One argument is allowed to: a debug kernel's `rules_flutter.build_info`
define, whose `assetsDir` is the real path of the app's `flutter_assets/`.
The dev tool tells an app's configurations apart by it (an Android wrapper
reaches one application in several), so the configuration in it is the
point. It is a string the compiler stores, not a path the action opens, so
the action still runs mapped; it only does not share a debug kernel between
configurations.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_ios_application.bzl", "flutter_ios_framework")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")
load("//flutter/private:flutter_macos_application.bzl", "flutter_macos_framework", "flutter_macos_native_libs")
load("//flutter/private:flutter_web_application.bzl", "flutter_web_bundle")
load(":apple_bundling.bzl", "fake_application")

_STRIP = "//command_line_option:experimental_output_paths"

_BUILD_INFO_DEFINE = "-Drules_flutter.build_info="

def config_paths(text):
    """The `bazel-out/<config>/` prefixes in `text` that are not `cfg`.

    Args:
        text: An argument or environment value.

    Returns:
        A list of the unmapped `bazel-out/<config>` prefixes found.
    """
    found = []
    pieces = text.split("bazel-out/")
    for piece in pieces[1:]:
        segment = piece.split("/")[0]
        if segment != "cfg" and "/" in piece:
            found.append("bazel-out/" + segment)
    return found

def _path_mapped_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    for mnemonic in ctx.attr.mnemonics:
        matching = [a for a in actions if a.mnemonic == mnemonic]
        asserts.true(env, len(matching) > 0, "no %s action to check" % mnemonic)
        for action in matching:
            argv = action.argv or []
            asserts.true(
                env,
                any(["bazel-out/cfg/" in arg for arg in argv]),
                "%s names no mapped path, so it does not declare supports-path-mapping: %s" % (mnemonic, argv),
            )
            for arg in argv:
                if arg.startswith(_BUILD_INFO_DEFINE):
                    continue
                unmapped = config_paths(arg)
                asserts.equals(
                    env,
                    [],
                    unmapped,
                    "%s argument %r names a configuration's output directory as a string" % (mnemonic, arg),
                )
            for key, value in (action.env or {}).items():
                asserts.equals(
                    env,
                    [],
                    config_paths(value),
                    "%s environment variable %s=%r names a configuration's output directory" % (mnemonic, key, value),
                )

    # A file the target writes and one of these actions reads is read inside
    # the mapped sandbox, so it must not name a configuration either.
    read = {}
    for action in actions:
        if action.mnemonic in ctx.attr.mnemonics:
            for f in action.inputs.to_list():
                read[f] = action.mnemonic
    for action in actions:
        if action.mnemonic != "FileWrite":
            continue
        written = action.outputs.to_list()[0]
        if written in read:
            asserts.equals(
                env,
                [],
                config_paths(action.content),
                "%s, read by %s, names a configuration's output directory:\n%s" % (written.short_path, read[written], action.content),
            )
    return analysistest.end(env)

_ATTRS = {"mnemonics": attr.string_list(mandatory = True)}

_path_mapped_test = analysistest.make(
    _path_mapped_test_impl,
    attrs = _ATTRS,
    config_settings = {_STRIP: "strip"},
)

_path_mapped_opt_test = analysistest.make(
    _path_mapped_test_impl,
    attrs = _ATTRS,
    config_settings = {
        _STRIP: "strip",
        "//command_line_option:compilation_mode": "opt",
    },
)

_path_mapped_dbg_test = analysistest.make(
    _path_mapped_test_impl,
    attrs = _ATTRS,
    config_settings = {
        _STRIP: "strip",
        "//command_line_option:compilation_mode": "dbg",
    },
)

def _config_paths_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], config_paths("--x=bazel-out/cfg/bin/a"))
    asserts.equals(env, ["bazel-out/k8-opt"], config_paths("--x=bazel-out/k8-opt/bin/a"))
    asserts.equals(env, [], config_paths("bazel-out"))
    asserts.equals(env, ["bazel-out/a"], config_paths("bazel-out/cfg/bin/x:bazel-out/a/bin/y"))
    return unittest.end(env)

_config_paths_test = unittest.make(_config_paths_test_impl)

_PACKAGE = "path_mapping_fixture"
_MAIN = "lib/web_fixture_main.dart"

def path_mapping_test_suite(name):
    """Declares the fixtures and the path-mapping tests over them.

    The Flutter fixtures have no `deps`, so they would not compile; the tests
    read the actions analysis declares.

    Args:
        name: The test_suite name.
    """
    flutter_application(
        name = name + "_app",
        package_name = _PACKAGE,
        main = _MAIN,
        deps = ["//flutter/tests/resources_fixture:resources_library"],
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = name + "_kernel",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_aot_target(
        name = name + "_aot",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = name + "_web",
        package_name = _PACKAGE,
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = name + "_web_js",
        package_name = _PACKAGE,
        main = _MAIN,
        compiler = "dart2js",
        tags = ["manual"],
    )
    for debug in [True, False]:
        suffix = "_debug" if debug else "_release"
        fake_application(
            name = name + "_fake_app" + suffix,
            debug = debug,
            native_libs = ["libadd.dylib"],
            tags = ["manual"],
        )
        flutter_macos_framework(
            name = name + "_macos_framework" + suffix,
            application = name + "_fake_app" + suffix,
            tags = ["manual"],
        )
        flutter_ios_framework(
            name = name + "_ios_framework" + suffix,
            application = name + "_fake_app" + suffix,
            tags = ["manual"],
        )
    flutter_macos_native_libs(
        name = name + "_macos_native_libs",
        application = name + "_fake_app_debug",
        tags = ["manual"],
    )

    # The host's own AOT format: an `opt` build of these targets compiles for
    # the machine running the test.
    aot = select({
        "@platforms//os:macos": ["FlutterAotMacho"],
        "//conditions:default": ["FlutterAotElf"],
    })

    cases = {
        "app": ("app", _path_mapped_test, ["FlutterKernelCompile", "FlutterAssetBundle", "FlutterShaderCompile"]),
        "app_opt": ("app", _path_mapped_opt_test, ["FlutterKernelCompile", "FlutterAssetBundle"] + aot),
        "app_dbg": ("app", _path_mapped_dbg_test, ["FlutterKernelCompile", "FlutterAssetBundle", "FlutterShaderCompile"]),
        "kernel": ("kernel", _path_mapped_test, ["FlutterKernelCompile"]),
        "aot": ("aot", _path_mapped_opt_test, ["FlutterKernelCompile"] + aot),
        "web": ("web", _path_mapped_test, ["FlutterKernelCompile", "FlutterAssetBundle", "FlutterDart2Wasm", "FlutterDart2JS", "FlutterWebTemplate", "FlutterWebBundle"]),
        "web_dbg": ("web", _path_mapped_dbg_test, ["FlutterAssetBundle", "FlutterDart2Wasm", "FlutterDart2JS", "FlutterWebTemplate", "FlutterWebBundle"]),
        "web_js": ("web_js", _path_mapped_opt_test, ["FlutterDart2JS", "FlutterWebTemplate", "FlutterWebBundle"]),
        "macos_framework_debug": ("macos_framework_debug", _path_mapped_test, ["FlutterMacOSFramework"]),
        "macos_framework_release": ("macos_framework_release", _path_mapped_test, ["FlutterMacOSFramework"]),
        "macos_native_libs": ("macos_native_libs", _path_mapped_test, ["FlutterMacOSNativeLibs"]),
        "ios_framework_debug": ("ios_framework_debug", _path_mapped_test, ["FlutterIOSStubDylib", "FlutterIOSDebugAssets"]),
        "ios_framework_release": ("ios_framework_release", _path_mapped_test, ["FlutterIOSRetagDylib", "FlutterIOSCopyAssets"]),
    }

    # Targets an iOS rule: there is no Linux-host-to-iOS Flutter toolchain,
    # so the rule cannot be analysed on a Linux host.
    macos_only = ["ios_framework_debug", "ios_framework_release"]

    tests = []
    for case, (fixture, rule, mnemonics) in cases.items():
        test_name = "%s_%s_test" % (name, case)
        rule(
            name = test_name,
            target_under_test = ":%s_%s" % (name, fixture),
            mnemonics = mnemonics,
            target_compatible_with = ["@platforms//os:macos"] if case in macos_only else [],
        )
        tests.append(":" + test_name)

    for case, target, mnemonic in [
        ("gen_l10n", "//flutter/tests/gen_l10n_fixture:l10n", "FlutterGenL10n"),
        ("plist_merge", ":_plist_supplement_under_test", "FlutterPlistMerge"),
        ("manifest_merge", ":_manifest_merge_under_test", "FlutterManifestMerge"),
    ]:
        test_name = "%s_%s_test" % (name, case)
        _path_mapped_test(name = test_name, target_under_test = target, mnemonics = [mnemonic])
        tests.append(":" + test_name)

    _config_paths_test(name = name + "_config_paths_test")
    tests.append(":" + name + "_config_paths_test")

    native.test_suite(name = name, tests = tests)
