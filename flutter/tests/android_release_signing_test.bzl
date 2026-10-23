"""Analysis tests for release-keystore APK signing in `flutter_android_app`.

`flutter_android_app` finishes its payload-free `android_binary` in
`flutter_android_apk_overlay`, which signs with the debug keystore by
default. Setting `keystore` (plus `keystore_password_file` and `key_alias`)
switches the overlay's `ApkSignerTool` action to the caller's keystore, with
both passwords passed only as `file:` references to password-file inputs —
never as literal text on the command line.

The overlay needs the Android SDK toolchains, which the root module does not
configure, so this suite injects stub toolchains through
`//command_line_option:extra_toolchains` (the same mechanism
`action_inputs_test` uses for its synthetic Dart SDK) and a fake
`android_binary` carrying a hand-built `ApkInfo`. Actions are created but
never executed under `analysistest`, so the stubs only have to exist as
files.

A flag that names any target but its default sentinel must resolve to exactly
one file: an empty flag target (for example an `allow_empty` glob over a CI
secret that was never written) or a multi-file one fails analysis instead of
silently debug-signing. The release `ApkSignerTool` action always runs with
`no-remote` so the keystore and password files never reach a remote executor
or cache; the debug action keeps no execution requirements.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//providers:providers.bzl", "ApkInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:flutter_android_apk_overlay.bzl", "flutter_android_apk_overlay", "release_execution_requirements")

_STORE_PASS = "release-test-store-pass"
_KEY_PASS = "release-test-key-pass"
_ALIAS = "release-test-alias"

def _fake_android_binary_impl(ctx):
    """Stands in for `android_binary`: an unsigned APK plus deploy info."""
    unsigned_apk = ctx.actions.declare_file(ctx.label.name + "_unsigned.apk")
    ctx.actions.write(output = unsigned_apk, content = "fake unsigned apk")
    signed_apk = ctx.actions.declare_file(ctx.label.name + "_signed.apk")
    ctx.actions.write(output = signed_apk, content = "fake signed apk")
    deploy_info = ctx.actions.declare_file(ctx.label.name + ".deploy_info.pb")
    ctx.actions.write(output = deploy_info, content = "")
    merged_manifest = ctx.actions.declare_file(ctx.label.name + "_AndroidManifest.xml")
    ctx.actions.write(output = merged_manifest, content = "<manifest/>")
    return [
        DefaultInfo(files = depset([signed_apk])),
        ApkInfo(
            signed_apk = signed_apk,
            unsigned_apk = unsigned_apk,
            deploy_jar = signed_apk,
            coverage_metadata = None,
            signing_keys = [],
            signing_lineage = None,
            signing_min_v3_rotation_api_version = "",
            keystore = None,
        ),
        JavaInfo(output_jar = signed_apk, compile_jar = signed_apk),
        OutputGroupInfo(android_deploy_info = depset([deploy_info, merged_manifest])),
    ]

_fake_android_binary = rule(
    implementation = _fake_android_binary_impl,
)

def _stub_android_sdk_impl(ctx):
    """Stands in for the Android SDK toolchain: `zipalign` and `apksigner`."""
    zipalign = ctx.actions.declare_file(ctx.label.name + "_zipalign.sh")
    ctx.actions.write(output = zipalign, content = "#!/bin/sh\nexit 0\n", is_executable = True)
    apksigner = ctx.actions.declare_file(ctx.label.name + "_apksigner.sh")
    ctx.actions.write(output = apksigner, content = "#!/bin/sh\nexit 0\n", is_executable = True)
    return [platform_common.ToolchainInfo(android_sdk_info = struct(zip_align = zipalign, apk_signer = apksigner))]

_stub_android_sdk = rule(
    implementation = _stub_android_sdk_impl,
)

def _stub_android_toolchain_impl(ctx):
    """Stands in for the Android toolchain: the deploy-info writer."""
    writer = ctx.actions.declare_file(ctx.label.name + "_deploy_info_writer.sh")
    ctx.actions.write(output = writer, content = "#!/bin/sh\nexit 0\n", is_executable = True)
    return [platform_common.ToolchainInfo(deploy_info_writer = struct(files_to_run = writer))]

_stub_android_toolchain = rule(
    implementation = _stub_android_toolchain_impl,
)

_EXTRA_TOOLCHAINS = [
    str(Label("//flutter/tests:_release_signing_stub_sdk_toolchain")),
    str(Label("//flutter/tests:_release_signing_stub_android_toolchain")),
]

def _sign_action(env):
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "ApkSignerTool"]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected exactly one ApkSignerTool action, got %s" % [a.mnemonic for a in analysistest.target_actions(env)],
    )
    return actions[0] if actions else None

def _flag_value(argv, flag):
    for i, arg in enumerate(argv):
        if arg == flag and i + 1 < len(argv):
            return argv[i + 1]
    return None

def _release_requirements_test_impl(ctx):
    """`no-remote` engages exactly when the signer reads release secrets.

    `analysistest` actions expose argv, inputs, env and outputs but not
    execution requirements, so the requirement mapping itself is pinned here
    while the analysistest suites above pin that each path (attribute and flag)
    reaches release signing: both flow through the one `_run_apksign` call
    site, which applies this mapping to the `ApkSignerTool` action.
    """
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        {"no-remote": "1"},
        release_execution_requirements(struct(keystore = "k")),
        "release signing must run locally so secrets never reach remote execution",
    )
    asserts.equals(
        env,
        {},
        release_execution_requirements(None),
        "debug signing keeps the default execution requirements",
    )
    return unittest.end(env)

def _release_signing_argv_test_impl(ctx):
    """The release signing action names the keystore and `file:` passwords."""
    env = analysistest.begin(ctx)
    action = _sign_action(env)
    argv = action.argv
    input_paths = [f.path for f in action.inputs.to_list()]

    keystore_paths = [p for p in input_paths if p.endswith("_release_keystore.p12")]
    asserts.equals(env, 1, len(keystore_paths), "expected the keystore among the signing inputs, got %s" % input_paths)
    asserts.equals(env, keystore_paths[0], _flag_value(argv, "--ks"))

    asserts.equals(env, _ALIAS, _flag_value(argv, "--ks-key-alias"))

    ks_pass = _flag_value(argv, "--ks-pass")
    asserts.true(
        env,
        ks_pass != None and ks_pass.startswith("file:"),
        "expected --ks-pass file:<path>, got %r in %s" % (ks_pass, argv),
    )
    asserts.true(
        env,
        ks_pass != None and ks_pass[len("file:"):] in input_paths,
        "--ks-pass path %r must be a signing action input" % ks_pass,
    )
    asserts.true(
        env,
        ks_pass != None and ks_pass.endswith("_release_store_pass.txt"),
        "--ks-pass must name the keystore password file, got %r" % ks_pass,
    )

    key_pass = _flag_value(argv, "--key-pass")
    asserts.true(
        env,
        key_pass != None and key_pass.startswith("file:"),
        "expected --key-pass file:<path>, got %r in %s" % (key_pass, argv),
    )
    asserts.true(
        env,
        key_pass != None and key_pass[len("file:"):] in input_paths,
        "--key-pass path %r must be a signing action input" % key_pass,
    )
    asserts.true(
        env,
        key_pass != None and key_pass.endswith("_release_key_pass.txt"),
        "--key-pass must name the key password file, got %r" % key_pass,
    )

    for arg in argv:
        asserts.false(
            env,
            arg.startswith("pass:"),
            "no password may appear literally on the signing command line, got %r in %s" % (arg, argv),
        )

    # The password files' contents enter the action key through their digests;
    # the text itself must reach neither argv nor env of any action.
    for a in analysistest.target_actions(env):
        for arg in a.argv:
            asserts.false(env, _STORE_PASS in arg, "store password leaked onto %s argv: %s" % (a.mnemonic, a.argv))
            asserts.false(env, _KEY_PASS in arg, "key password leaked onto %s argv: %s" % (a.mnemonic, a.argv))
        for value in a.env.values():
            asserts.false(env, _STORE_PASS in value, "store password leaked into %s env" % a.mnemonic)
            asserts.false(env, _KEY_PASS in value, "key password leaked into %s env" % a.mnemonic)
    return analysistest.end(env)

def _default_key_pass_test_impl(ctx):
    """Without `key_password_file`, `--key-pass` is omitted entirely.

    apksigner then unlocks the key with the keystore password. Repeating the
    keystore password file as `--key-pass` would not do the same: apksigner
    consumes one line per password read, so a second read from the same
    single-line file fails.
    """
    env = analysistest.begin(ctx)
    argv = _sign_action(env).argv
    asserts.false(env, "--key-pass" in argv, "expected no --key-pass without key_password_file, got %s" % argv)
    ks_pass = _flag_value(argv, "--ks-pass")
    asserts.true(
        env,
        ks_pass != None and ks_pass.startswith("file:"),
        "expected --ks-pass file:<path>, got %r in %s" % (ks_pass, argv),
    )
    return analysistest.end(env)

def _debug_signing_argv_test_impl(ctx):
    """Without `keystore`, the signing action keeps the debug `pass:` form."""
    env = analysistest.begin(ctx)
    argv = _sign_action(env).argv
    asserts.equals(env, "pass:android", _flag_value(argv, "--ks-pass"))
    for flag in ("--ks-key-alias", "--key-pass"):
        asserts.false(env, flag in argv, "debug signing must not pass %s, got %s" % (flag, argv))
    for arg in argv:
        asserts.false(env, arg.startswith("file:"), "debug signing must not pass file: passwords, got %s" % argv)
    return analysistest.end(env)

def _attr_beats_flag_test_impl(ctx):
    """An explicit `keystore` attribute wins over the release-keystore flag."""
    env = analysistest.begin(ctx)
    argv = _sign_action(env).argv
    ks = _flag_value(argv, "--ks")
    asserts.true(
        env,
        ks != None and ks.endswith("_release_keystore.p12"),
        "expected the attribute keystore in --ks, got %r in %s" % (ks, argv),
    )
    return analysistest.end(env)

def _flag_only_test_impl(ctx):
    """With no attributes, the release-keystore flags supply the signing."""
    env = analysistest.begin(ctx)
    argv = _sign_action(env).argv
    ks = _flag_value(argv, "--ks")
    asserts.true(
        env,
        ks != None and ks.endswith("_release_flag_keystore.p12"),
        "expected the flag keystore in --ks, got %r in %s" % (ks, argv),
    )
    asserts.equals(env, "flag-alias", _flag_value(argv, "--ks-key-alias"))
    ks_pass = _flag_value(argv, "--ks-pass")
    asserts.true(
        env,
        ks_pass != None and ks_pass.endswith("_release_flag_store_pass.txt"),
        "expected the flag password file in --ks-pass, got %r in %s" % (ks_pass, argv),
    )
    return analysistest.end(env)

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_release_signing_argv_test = analysistest.make(
    _release_signing_argv_test_impl,
    config_settings = {"//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS},
)
_release_requirements_test = unittest.make(_release_requirements_test_impl)
_default_key_pass_test = analysistest.make(
    _default_key_pass_test_impl,
    config_settings = {"//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS},
)
_debug_signing_argv_test = analysistest.make(
    _debug_signing_argv_test_impl,
    config_settings = {"//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS},
)
_attr_beats_flag_test = analysistest.make(
    _attr_beats_flag_test_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
        str(Label("//flutter:android_release_keystore")): str(Label("//flutter/tests:android_release_signing_test_release_flag_keystore")),
    },
)
_flag_only_test = analysistest.make(
    _flag_only_test_impl,
    config_settings = {
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
        str(Label("//flutter:android_release_keystore")): str(Label("//flutter/tests:android_release_signing_test_release_flag_keystore")),
        str(Label("//flutter:android_release_keystore_password_file")): str(Label("//flutter/tests:android_release_signing_test_release_flag_store_pass")),
        str(Label("//flutter:android_release_key_alias")): "flag-alias",
    },
)
_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
    config_settings = {"//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS},
)
_empty_flag_keystore_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
    config_settings = {
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
        str(Label("//flutter:android_release_keystore")): str(Label("//flutter/tests:android_release_signing_test_empty_keystore")),
    },
)
_two_flag_keystore_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
    config_settings = {
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
        str(Label("//flutter:android_release_keystore")): str(Label("//flutter/tests:android_release_signing_test_two_keystores")),
    },
)
_two_flag_store_pass_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
    config_settings = {
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
        str(Label("//flutter:android_release_keystore")): str(Label("//flutter/tests:android_release_signing_test_release_flag_keystore")),
        str(Label("//flutter:android_release_keystore_password_file")): str(Label("//flutter/tests:android_release_signing_test_two_store_passes")),
        str(Label("//flutter:android_release_key_alias")): "flag-alias",
    },
)

def _setup_fixtures(name):
    _stub_android_sdk(
        name = "_release_signing_stub_sdk",
        tags = ["manual"],
    )
    native.toolchain(
        name = "_release_signing_stub_sdk_toolchain",
        toolchain = ":_release_signing_stub_sdk",
        toolchain_type = "@rules_android//toolchains/android_sdk:toolchain_type",
    )
    _stub_android_toolchain(
        name = "_release_signing_stub_android",
        tags = ["manual"],
    )
    native.toolchain(
        name = "_release_signing_stub_android_toolchain",
        toolchain = ":_release_signing_stub_android",
        toolchain_type = "@rules_android//toolchains/android:toolchain_type",
    )
    write_file(
        name = name + "_release_keystore",
        out = name + "_release_keystore.p12",
        content = ["fake pkcs12 keystore"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_release_store_pass",
        out = name + "_release_store_pass.txt",
        content = [_STORE_PASS],
        tags = ["manual"],
    )
    write_file(
        name = name + "_release_key_pass",
        out = name + "_release_key_pass.txt",
        content = [_KEY_PASS],
        tags = ["manual"],
    )
    write_file(
        name = name + "_release_flag_keystore",
        out = name + "_release_flag_keystore.p12",
        content = ["fake flag pkcs12 keystore"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_release_flag_store_pass",
        out = name + "_release_flag_store_pass.txt",
        content = ["flag-store-pass"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_two_keystores_a",
        out = name + "_two_keystores_a.p12",
        content = ["fake pkcs12 keystore a"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_two_keystores_b",
        out = name + "_two_keystores_b.p12",
        content = ["fake pkcs12 keystore b"],
        tags = ["manual"],
    )
    native.filegroup(
        name = name + "_empty_keystore",
        srcs = [],
        tags = ["manual"],
    )
    native.filegroup(
        name = name + "_two_keystores",
        srcs = [
            ":" + name + "_two_keystores_a",
            ":" + name + "_two_keystores_b",
        ],
        tags = ["manual"],
    )
    write_file(
        name = name + "_two_store_pass_a",
        out = name + "_two_store_pass_a.txt",
        content = ["flag-store-pass-a"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_two_store_pass_b",
        out = name + "_two_store_pass_b.txt",
        content = ["flag-store-pass-b"],
        tags = ["manual"],
    )
    native.filegroup(
        name = name + "_two_store_passes",
        srcs = [
            ":" + name + "_two_store_pass_a",
            ":" + name + "_two_store_pass_b",
        ],
        tags = ["manual"],
    )
    write_file(
        name = name + "_release_native_libs",
        out = name + "_release_native_libs.jar",
        content = ["fake native libs jar"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_release_flutter_assets",
        out = name + "_release_flutter_assets.zip",
        content = ["fake flutter assets"],
        tags = ["manual"],
    )
    _fake_android_binary(
        name = name + "_release_fake_binary",
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_release_overlay",
        binary = ":" + name + "_release_fake_binary",
        native_libs_jar = ":" + name + "_release_native_libs",
        flutter_assets = ":" + name + "_release_flutter_assets",
        keystore = ":" + name + "_release_keystore",
        keystore_password_file = ":" + name + "_release_store_pass",
        key_alias = _ALIAS,
        key_password_file = ":" + name + "_release_key_pass",
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_release_default_key_pass_overlay",
        binary = ":" + name + "_release_fake_binary",
        native_libs_jar = ":" + name + "_release_native_libs",
        flutter_assets = ":" + name + "_release_flutter_assets",
        keystore = ":" + name + "_release_keystore",
        keystore_password_file = ":" + name + "_release_store_pass",
        key_alias = _ALIAS,
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_release_missing_pass_overlay",
        binary = ":" + name + "_release_fake_binary",
        native_libs_jar = ":" + name + "_release_native_libs",
        flutter_assets = ":" + name + "_release_flutter_assets",
        keystore = ":" + name + "_release_keystore",
        key_alias = _ALIAS,
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_release_missing_alias_overlay",
        binary = ":" + name + "_release_fake_binary",
        native_libs_jar = ":" + name + "_release_native_libs",
        flutter_assets = ":" + name + "_release_flutter_assets",
        keystore = ":" + name + "_release_keystore",
        keystore_password_file = ":" + name + "_release_store_pass",
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_release_debug_overlay",
        binary = ":" + name + "_release_fake_binary",
        native_libs_jar = ":" + name + "_release_native_libs",
        flutter_assets = ":" + name + "_release_flutter_assets",
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_release_flag_only_overlay",
        binary = ":" + name + "_release_fake_binary",
        native_libs_jar = ":" + name + "_release_native_libs",
        flutter_assets = ":" + name + "_release_flutter_assets",
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_release_empty_attr_keystore_overlay",
        binary = ":" + name + "_release_fake_binary",
        native_libs_jar = ":" + name + "_release_native_libs",
        flutter_assets = ":" + name + "_release_flutter_assets",
        keystore = ":" + name + "_empty_keystore",
        keystore_password_file = ":" + name + "_release_store_pass",
        key_alias = _ALIAS,
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_release_two_attr_keystore_overlay",
        binary = ":" + name + "_release_fake_binary",
        native_libs_jar = ":" + name + "_release_native_libs",
        flutter_assets = ":" + name + "_release_flutter_assets",
        keystore = ":" + name + "_two_keystores",
        keystore_password_file = ":" + name + "_release_store_pass",
        key_alias = _ALIAS,
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_release_two_attr_pass_overlay",
        binary = ":" + name + "_release_fake_binary",
        native_libs_jar = ":" + name + "_release_native_libs",
        flutter_assets = ":" + name + "_release_flutter_assets",
        keystore = ":" + name + "_release_keystore",
        keystore_password_file = ":" + name + "_two_store_passes",
        key_alias = _ALIAS,
        tags = ["manual"],
    )

def android_release_signing_test_suite(name):
    """Defines analysis tests for release-keystore APK signing.

    Args:
        name: The test_suite target name.
    """
    _setup_fixtures(name)

    _release_signing_argv_test(
        name = name + "_argv",
        target_under_test = ":" + name + "_release_overlay",
    )
    _release_requirements_test(name = name + "_release_requirements")
    _default_key_pass_test(
        name = name + "_default_key_pass",
        target_under_test = ":" + name + "_release_default_key_pass_overlay",
    )
    _debug_signing_argv_test(
        name = name + "_debug_argv",
        target_under_test = ":" + name + "_release_debug_overlay",
    )
    _attr_beats_flag_test(
        name = name + "_attr_beats_flag",
        target_under_test = ":" + name + "_release_overlay",
    )
    _flag_only_test(
        name = name + "_flag_only",
        target_under_test = ":" + name + "_release_flag_only_overlay",
    )
    _expect_failure_test(
        name = name + "_missing_pass_fails",
        target_under_test = ":" + name + "_release_missing_pass_overlay",
        expected_substrings = ["keystore_password_file"],
    )
    _expect_failure_test(
        name = name + "_missing_alias_fails",
        target_under_test = ":" + name + "_release_missing_alias_overlay",
        expected_substrings = ["key_alias"],
    )
    _empty_flag_keystore_test(
        name = name + "_empty_flag_keystore_fails",
        target_under_test = ":" + name + "_release_flag_only_overlay",
        expected_substrings = ["android_release_keystore", "0 files"],
    )
    _two_flag_keystore_test(
        name = name + "_two_flag_keystore_fails",
        target_under_test = ":" + name + "_release_flag_only_overlay",
        expected_substrings = ["android_release_keystore", "2 files"],
    )
    _two_flag_store_pass_test(
        name = name + "_two_flag_store_pass_fails",
        target_under_test = ":" + name + "_release_flag_only_overlay",
        expected_substrings = ["android_release_keystore_password_file", "2 files"],
    )
    _expect_failure_test(
        name = name + "_empty_attr_keystore_fails",
        target_under_test = ":" + name + "_release_empty_attr_keystore_overlay",
        expected_substrings = ["`keystore`", "0 files"],
    )
    _expect_failure_test(
        name = name + "_two_attr_keystore_fails",
        target_under_test = ":" + name + "_release_two_attr_keystore_overlay",
        expected_substrings = ["`keystore`", "2 files"],
    )
    _expect_failure_test(
        name = name + "_two_attr_pass_fails",
        target_under_test = ":" + name + "_release_two_attr_pass_overlay",
        expected_substrings = ["keystore_password_file", "2 files"],
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_argv",
            ":" + name + "_release_requirements",
            ":" + name + "_default_key_pass",
            ":" + name + "_debug_argv",
            ":" + name + "_attr_beats_flag",
            ":" + name + "_flag_only",
            ":" + name + "_missing_pass_fails",
            ":" + name + "_missing_alias_fails",
            ":" + name + "_empty_flag_keystore_fails",
            ":" + name + "_two_flag_keystore_fails",
            ":" + name + "_two_flag_store_pass_fails",
            ":" + name + "_empty_attr_keystore_fails",
            ":" + name + "_two_attr_keystore_fails",
            ":" + name + "_two_attr_pass_fails",
        ],
    )
