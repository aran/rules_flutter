"""The URI a native app's `main` is compiled under, in the build and the dev loop.

Hot reload applies an edit only when the dev tool's compiler names a library
exactly as the running kernel does. A `main` under its package's `lib/` has a
`package:` URI that is the same in the build's sandbox and the workspace. One
outside it — `flutter run -t test_driver/app.dart` — has no such URI, so both
sides name it under the app scheme instead, with the same root mounted. These
tests pin both halves: the build's kernel compile and the `_dev_config.json`
the dev tool compiles from.

The generated plugin registrant rides the same scheme, since a frontend_server
mounts one scheme at a time.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_application.bzl", "flutter_application")
load(":action_content.bzl", "written_json")

_PACKAGE = "ae_fixture"
_OUTSIDE_LIB_URI = "org-dartlang-app:///flutter/tests/web_fixture_main.dart"

def _kernel_argv(env):
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterKernelCompile"
    ]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    return kernels[0].argv if kernels else []

def _flag_values(argv, flag):
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == flag]

def _assert_registrant_on_app_scheme(env, argv):
    """The registrant's `--source`, its define and its root agree."""
    defines = [
        a[len("-Dflutter.dart_plugin_registrant="):]
        for a in argv
        if a.startswith("-Dflutter.dart_plugin_registrant=")
    ]
    asserts.equals(env, 1, len(defines), "a dbg app compiles a plugin registrant")
    if not defines:
        return
    registrant = defines[0]

    # The engine looks the define up as a library URI by exact string, so the
    # source it names has to be compiled under that same string.
    asserts.true(
        env,
        registrant in _flag_values(argv, "--source"),
        "the registrant define %r must be a --source" % registrant,
    )
    asserts.true(
        env,
        registrant.startswith("org-dartlang-app:///flutter/tests/"),
        "the registrant is named by its workspace path under the app scheme, got %r" % registrant,
    )

    # Generated, so it resolves under its output directory, not the exec root.
    roots = _flag_values(argv, "--filesystem-root")
    asserts.true(
        env,
        [r for r in roots if r.startswith("bazel-out/") and r.endswith("/bin")] != [],
        "the registrant's output directory must be mounted, got %r" % roots,
    )
    asserts.equals(env, ["org-dartlang-app"], _flag_values(argv, "--filesystem-scheme"))

def _outside_lib_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _kernel_argv(env)

    # The compilation root, and the exec root it resolves under.
    asserts.equals(env, _OUTSIDE_LIB_URI, argv[-1] if argv else None)
    asserts.true(
        env,
        "." in _flag_values(argv, "--filesystem-root"),
        "a source `main` outside lib/ needs the exec root mounted",
    )
    _assert_registrant_on_app_scheme(env, argv)

    # The dev loop names it the same way, from the same root — `""` is the
    # exec root in the dev config's exec-root-relative convention.
    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(env, _OUTSIDE_LIB_URI, config["appEntrypoint"])
        asserts.equals(env, [""], config["filesystemRoots"])
        asserts.equals(env, "org-dartlang-app", config["filesystemScheme"])

        # The `main`, and the sibling it imports: both reach the dev loop's
        # edit-to-URI map, the sibling because it is declared in `srcs` —
        # the build's compile sees nothing it does not declare, so this is
        # every file outside a package the app can read.
        asserts.equals(
            env,
            [
                {"path": "flutter/tests/web_fixture_main.dart", "uri": _OUTSIDE_LIB_URI},
                {"path": "flutter/tests/app_entrypoint_sibling.dart", "uri": "org-dartlang-app:///flutter/tests/app_entrypoint_sibling.dart"},
            ],
            config["appSources"],
        )
    return analysistest.end(env)

def _in_lib_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _kernel_argv(env)
    asserts.equals(
        env,
        "package:%s/web_fixture_main.dart" % _PACKAGE,
        argv[-1] if argv else None,
    )
    _assert_registrant_on_app_scheme(env, argv)

    # Nothing for the dev loop to mount: the entrypoint resolves through the
    # package config, and the dev tool compiles its own registrant as a file.
    config = written_json(env, "_dev_config.json")
    if config != None:
        asserts.equals(env, "package:%s/web_fixture_main.dart" % _PACKAGE, config["appEntrypoint"])
        asserts.equals(env, [], config["filesystemRoots"])
        asserts.equals(env, [], config["appSources"])
    return analysistest.end(env)

_DBG = {"//command_line_option:compilation_mode": "dbg"}

_outside_lib_test = analysistest.make(_outside_lib_test_impl, config_settings = _DBG)
_in_lib_test = analysistest.make(_in_lib_test_impl, config_settings = _DBG)

def app_entrypoint_test_suite(name):
    """Fixtures and tests for where a native app's `main` is compiled from.

    Args:
        name: The test suite name.
    """
    flutter_application(
        name = "_ae_outside_lib",
        srcs = [
            "app_entrypoint_sibling.dart",
            # Under `lib/`, so keyed by its `package:` URI and not listed.
            "lib/web_fixture_main.dart",
        ],
        package_name = _PACKAGE,
        main = "web_fixture_main.dart",
        tags = ["manual"],
    )
    flutter_application(
        name = "_ae_in_lib",
        package_name = _PACKAGE,
        main = "lib/web_fixture_main.dart",
        tags = ["manual"],
    )
    _outside_lib_test(
        name = name + "_outside_lib",
        target_under_test = ":_ae_outside_lib",
    )
    _in_lib_test(
        name = name + "_in_lib",
        target_under_test = ":_ae_in_lib",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_outside_lib",
            ":" + name + "_in_lib",
        ],
    )
