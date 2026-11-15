"""Analysis tests: each action takes only the SDK files its tool reads.

The Flutter SDK download holds a Dart SDK (about 1,050 files, 625 MB) and the
patched SDK. An action's inputs are linked into its sandbox and, under remote
execution, listed, hashed and staged, so an action that names the whole SDK
pays for the whole of it although its tool opens two to a dozen files.

rules_dart's `SDK_FILE_SETS` names the files each use of the Dart SDK reads.
Each test here collects the files of the Flutter SDK repository among an
action's inputs and asserts that every one belongs to the set for that
action's tool:

- a `dart script.dart` step (asset bundle, manifests, bundlers, templates):
  `run`, the launcher and the VM;
- `dart compile js` and `dart compile wasm`: `dart2js` and `dart2wasm`;
- a library, entry or whole-program compile through `DartKernelSdkInfo`:
  the `kernel` set;
- `gen_snapshot`: none. It is a standalone binary from the engine download.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:toolchain.bzl", "SDK_FILE_SETS")
load("//flutter:web.bzl", "flutter_web_bundle")
load("//flutter/private:flutter_aot_snapshot.bzl", "flutter_aot_snapshot")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load("//flutter/private:flutter_kernel.bzl", "flutter_kernel")
load("//flutter/private:flutter_macos_application.bzl", "flutter_macos_app_framework")
load(":apple_bundling.bzl", "fake_application")

_WHOLE_PROGRAM = {str(Label("@rules_dart//dart:modular_kernel")): False}

def _sets(*names):
    files = {}
    for name in names:
        for pattern in SDK_FILE_SETS[name]:
            if "*" in pattern:
                fail("sdk_inputs_test: the set %r holds a glob (%r); this test compares exact paths" % (name, pattern))
            files[pattern] = True
    return files

# What each tool reads of the Flutter SDK's `dart-sdk/`, by mnemonic. An action
# not named here runs a Dart script and takes the `run` set.
_RUN = _sets("run")
_SDK_FILES = {
    "DartKernel": _sets("kernel"),
    "FlutterAotElf": {},
    "FlutterAotMacho": {},
    "FlutterDart2JS": _sets("dart2js"),
    "FlutterDart2Wasm": _sets("dart2wasm"),
    "DartModule": _sets("kernel"),
    "DartEntryKernel": _sets("kernel"),
    "DartLinkKernel": _sets("kernel"),
}

# The patched SDK's files an action reads: the platform kernel, by name.
_PATCHED_SDK_FILES = ["platform_strong.dill"]

# The web SDK's files each web compile reads: its platform kernel, which the
# action names itself. The rest of the web SDK (the engine's CanvasKit builds,
# `flutter.js`, the `dart:` library sources) is for the bundle.
_WEB_SDK_FILES = {
    "FlutterDart2JS": ["web-sdk/kernel/dart2js_platform.dill"],
    "FlutterDart2Wasm": ["web-sdk/kernel/dart2wasm_platform.dill"],
}

def _split(path):
    """(`dart-sdk` file, `patched-sdk` file, web SDK file) of an input path: the part after the root, or None."""
    segments = path.split("/")
    if "external" not in segments:
        return None, None, None
    if any([s.endswith("flutter_web_sdk") or s.endswith("stock_web_sdk") for s in segments]):
        return None, None, "/".join(segments[segments.index("external") + 2:])
    if "dart-sdk" in segments:
        return "/".join(segments[segments.index("dart-sdk") + 1:]), None, None
    for root in ["flutter_patched_sdk", "flutter_patched_sdk_product"]:
        if root in segments:
            return None, "/".join(segments[segments.index(root) + 1:]), None
    return None, None, None

def sdk_inputs(action):
    """The Flutter SDK files among an action's inputs.

    Args:
        action: An analysis-test `Action`.

    Returns:
        A struct of `dart_sdk`, `patched_sdk` and `web_sdk`: the paths of the
        files under each root, relative to it.
    """
    dart_sdk = []
    patched_sdk = []
    web_sdk = []
    for f in action.inputs.to_list():
        dart, patched, web = _split(f.path)
        if dart != None:
            dart_sdk.append(dart)
        if patched != None:
            patched_sdk.append(patched)
        if web != None:
            web_sdk.append(web)
    return struct(dart_sdk = sorted(dart_sdk), patched_sdk = sorted(patched_sdk), web_sdk = sorted(web_sdk))

def _takes_only_what_it_reads_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    seen = {}
    for action in actions:
        found = sdk_inputs(action)
        seen[action.mnemonic] = seen.get(action.mnemonic, 0) + 1
        allowed = _SDK_FILES.get(action.mnemonic, _RUN)
        extra = [p for p in found.dart_sdk if p not in allowed and not (p.endswith(".exe") and p[:-4] in allowed)]
        asserts.equals(
            env,
            [],
            extra[:5],
            "%s takes %d Dart SDK files it does not read (%d in all); first five" % (action.mnemonic, len(extra), len(found.dart_sdk)),
        )
        extra_patched = [p for p in found.patched_sdk if p not in _PATCHED_SDK_FILES]
        asserts.equals(
            env,
            [],
            extra_patched[:5],
            "%s takes %d patched SDK files it does not read (%d in all); first five" % (action.mnemonic, len(extra_patched), len(found.patched_sdk)),
        )
        if action.mnemonic in _WEB_SDK_FILES:
            extra_web = [p for p in found.web_sdk if p not in _WEB_SDK_FILES[action.mnemonic]]
            asserts.equals(
                env,
                [],
                extra_web[:5],
                "%s takes %d web SDK files it does not read (%d in all); first five" % (action.mnemonic, len(extra_web), len(found.web_sdk)),
            )

    # The actions the test is about exist, so it cannot pass by looking at none.
    for mnemonic in ctx.attr.mnemonics:
        asserts.true(env, seen.get(mnemonic, 0) > 0, "no %s action to check; the target declares %s" % (mnemonic, sorted(seen)))
    return analysistest.end(env)

_ATTRS = {"mnemonics": attr.string_list(mandatory = True)}

_takes_only_what_it_reads_test = analysistest.make(_takes_only_what_it_reads_impl, attrs = _ATTRS)
_takes_only_what_it_reads_opt_test = analysistest.make(
    _takes_only_what_it_reads_impl,
    attrs = _ATTRS,
    config_settings = {"//command_line_option:compilation_mode": "opt"},
)
_takes_only_what_it_reads_whole_program_test = analysistest.make(
    _takes_only_what_it_reads_impl,
    attrs = _ATTRS,
    config_settings = _WHOLE_PROGRAM,
)

_MAIN = "lib/web_fixture_main.dart"

def sdk_inputs_test_suite(name):
    """Declares the fixtures and the SDK-input tests over them.

    The Flutter fixtures have no `deps`, so they would not compile; the tests
    read the actions analysis declares.

    Args:
        name: The test_suite name.
    """
    flutter_application(
        name = name + "_app",
        package = ":pubspec-metadata",
        main = _MAIN,
        deps = ["//flutter/tests/resources_fixture:resources_library"],
        tags = ["manual"],
    )
    flutter_kernel(
        name = name + "_kernel",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_aot_snapshot(
        name = name + "_aot",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_application(
        name = name + "_web_app",
        package = ":pubspec-metadata",
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = name + "_web",
        application = name + "_web_app",
        tags = ["manual"],
    )
    flutter_web_bundle(
        name = name + "_web_js",
        application = name + "_web_app",
        compiler = "dart2js",
        tags = ["manual"],
    )
    fake_application(
        name = name + "_fake_app",
        debug = True,
        native_libs = ["libadd.dylib"],
        tags = ["manual"],
    )
    flutter_macos_app_framework(
        name = name + "_macos_framework",
        application = name + "_fake_app",
        tags = ["manual"],
    )

    # The host's own AOT format: an `opt` build compiles for the machine
    # running the test.
    aot = select({
        "@platforms//os:macos": ["FlutterAotMacho"],
        "//conditions:default": ["FlutterAotElf"],
    })

    cases = {
        "app": (":%s_app" % name, _takes_only_what_it_reads_test, ["DartKernel", "FlutterAssetBundle", "FlutterShaderCompile"]),
        "app_opt": (":%s_app" % name, _takes_only_what_it_reads_opt_test, ["DartKernel", "FlutterAssetBundle"] + aot),
        "kernel": (":%s_kernel" % name, _takes_only_what_it_reads_test, ["DartKernel"]),
        "aot": (":%s_aot" % name, _takes_only_what_it_reads_opt_test, ["DartKernel"] + aot),
        "web": (":%s_web" % name, _takes_only_what_it_reads_test, ["FlutterDart2Wasm", "FlutterDart2JS", "FlutterAssetBundle", "FlutterWebTemplate", "FlutterWebBundle"]),
        "web_js": (":%s_web_js" % name, _takes_only_what_it_reads_opt_test, ["FlutterDart2JS", "FlutterWebTemplate", "FlutterWebBundle"]),
        "gen_l10n": ("//flutter/tests/gen_l10n_fixture:l10n", _takes_only_what_it_reads_test, ["FlutterGenL10n"]),
        "plist_merge": (":_plist_supplement_under_test", _takes_only_what_it_reads_test, ["FlutterPlistMerge"]),
        "manifest_merge": (":_manifest_merge_under_test", _takes_only_what_it_reads_test, ["FlutterManifestMerge"]),
        "flutter_test_modular": (
            "//flutter/tests/code_asset_fixture/test:wrapped_code_asset_test.program",
            _takes_only_what_it_reads_test,
            ["DartModule", "DartEntryKernel"],
        ),
        "flutter_test_whole_program": (
            "//flutter/tests/code_asset_fixture/test:wrapped_code_asset_test.program",
            _takes_only_what_it_reads_whole_program_test,
            ["DartKernel"],
        ),
        "macos_framework": (":%s_macos_framework" % name, _takes_only_what_it_reads_test, ["FlutterMacOSFramework"]),
    }

    tests = []
    for case, (target, rule, mnemonics) in cases.items():
        test_name = "%s_%s_test" % (name, case)
        rule(
            name = test_name,
            target_under_test = target,
            mnemonics = mnemonics,
            target_compatible_with = ["@platforms//os:macos"] if case in ["macos_framework", "flutter_test_modular", "flutter_test_whole_program"] else [],
        )
        tests.append(":" + test_name)

    native.test_suite(name = name, tests = tests)
