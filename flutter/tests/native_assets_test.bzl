"""Analysis-time validation tests for the Native Assets rules.

These tests specify the documented contract of the manifest an application
writes from its code assets: invalid
configurations must fail at analysis time, not silently produce something
that breaks at runtime.

Each test uses `analysistest.make(expect_failure = True)` and pairs the
target under test with an `asserts.expect_failure(env, "<substring>")`
check against the produced error message — so we both assert the rule
fails *and* assert the failure message points the user at the right
fix.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_dart//dart:defs.bzl", "dart_code_asset")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "PROGRAM_ASSETS_TOOLCHAINS", "program_assets_attrs")
load("//flutter/private:common.bzl", "check_unreplaced_hooks")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//flutter/private:flutter_native_assets.bzl", "apple_framework_names", "native_asset_framework_name", "native_assets_target_string", "resolve_native_assets", "write_native_assets_manifest")

# -- Pure-function tests for the manifest helpers ----------------------

def _target_string_macos_arm64_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "macos_arm64", native_assets_target_string("macos", "arm64"))
    asserts.equals(env, "ios_arm64", native_assets_target_string("ios", "arm64"))
    asserts.equals(env, "linux_x64", native_assets_target_string("linux", "x64"))
    asserts.equals(env, "android_arm64", native_assets_target_string("android", "arm64"))
    return unittest.end(env)

def _target_string_unknown_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "", native_assets_target_string("", ""))
    asserts.equals(env, "", native_assets_target_string("macos", ""))
    asserts.equals(env, "", native_assets_target_string("plan9", "arm64"))
    return unittest.end(env)

def _framework_name_impl(ctx):
    env = unittest.begin(ctx)

    # flutter_tools 3.50's cases for `frameworkUri` (native_assets_host_test.dart).
    for filename, framework in [
        ("libfoo.dylib", "foo"),
        ("foo", "foo"),
        ("foo_foo", "foo_foo"),
        ("foo-foo", "foo-foo"),
        ("foo$foo", "foofoo"),
        ("foo.foo", "foo.foo"),
        ("foo.1.2.3", "foo.1.2.3"),
        ("libatoolongfilenameforaframework.dylib", "atoolongfilenameforaframework"),
    ]:
        asserts.equals(env, framework, native_asset_framework_name(filename), filename)

    # A `.dylib` loses its extension and then its `lib`; periods before it stay.
    asserts.equals(env, "objective_c", native_asset_framework_name("objective_c.dylib"))
    asserts.equals(env, "foo.bar", native_asset_framework_name("foo.bar.dylib"))
    asserts.equals(env, "foo.bar", native_asset_framework_name("libfoo.bar.dylib"))

    # Anything else keeps its `lib` and its extension.
    asserts.equals(env, "libfoo", native_asset_framework_name("libfoo"))
    asserts.equals(env, "libfoo.so", native_asset_framework_name("libfoo.so"))

    # Only ASCII letters and digits, `.`, `_` and `-` are kept.
    asserts.equals(env, "my-lib_2", native_asset_framework_name("my-lib_2.dylib"))
    asserts.equals(env, "foobar", native_asset_framework_name("foo bar+é.dylib"))
    return unittest.end(env)

def _framework_names_impl(ctx):
    env = unittest.begin(ctx)

    # flutter_tools 3.50's `framework name conflicts` cases: a name taken
    # gains `1`, then `2`. Upstream's repeat one file name; an app's file
    # names are distinct, so here distinct names reach one framework name.
    files = [
        struct(basename = name)
        for name in [
            "libfoo.dylib",
            "foo.dylib",
            "foo",
            "libatoolongfilenameforaframework.dylib",
            "atoolongfilenameforaframework.dylib",
            # Repeats, as a library reached twice, are one library.
            "foo",
        ]
    ]
    asserts.equals(
        env,
        {
            # In file-name order: `foo`, then `foo.dylib`, then `libfoo.dylib`.
            "foo": "foo",
            "foo.dylib": "foo1",
            "libfoo.dylib": "foo2",
            "atoolongfilenameforaframework.dylib": "atoolongfilenameforaframework",
            "libatoolongfilenameforaframework.dylib": "atoolongfilenameforaframework1",
        },
        apple_framework_names(files),
    )

    # A name no other takes is the one its file name gives.
    asserts.equals(env, {"libmul.dylib": "mul"}, apple_framework_names([struct(basename = "libmul.dylib")]))
    return unittest.end(env)

_target_string_t0_test = unittest.make(_target_string_macos_arm64_impl)
_target_string_t1_test = unittest.make(_target_string_unknown_impl)
_framework_name_test = unittest.make(_framework_name_impl)
_framework_names_test = unittest.make(_framework_names_impl)

# -- Manifest probe ----------------------------------------------------

def _manifest_probe_impl(ctx):
    """Resolve `code_assets` and write their manifest for a fixed (os, arch) pair.

    `write_native_assets_manifest` needs a rule context, so exercising
    its analysis-time contract needs a rule to host it. This one stands
    in for `flutter_application`'s aggregation step without dragging the
    whole compile pipeline (and a Flutter toolchain) into a unit test.
    """
    output = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = output,
        native_assets = resolve_native_assets(
            ctx,
            package = None,
            deps = [],
            code_assets = [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
        ).assets,
        target_os = ctx.attr.target_os,
        target_arch = ctx.attr.target_arch,
        layout = ctx.attr.layout,
    )
    return [DefaultInfo(files = depset([output]))]

_manifest_probe = rule(
    implementation = _manifest_probe_impl,
    attrs = program_assets_attrs() | {
        "code_assets": attr.label_list(providers = [DartCodeAssetInfo]),
        "layout": attr.string(mandatory = True),
        "target_arch": attr.string(mandatory = True),
        "target_os": attr.string(mandatory = True),
    },
    toolchains = PROGRAM_ASSETS_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = ["cpp"],
)

def _manifest_path_test_impl(ctx):
    """Assert the path a bundled asset gets under a given layout.

    The two layouts answer different questions — "where in the bundle" versus
    "where in the runfiles tree" — and only one of them is reachable from an
    e2e on this host, so the shapes are pinned here where both are cheap.
    """
    env = analysistest.begin(ctx)
    writes = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and
           a.outputs.to_list()[0].basename.endswith(".native_assets.json")
    ]
    asserts.equals(env, 1, len(writes), "expected exactly one manifest write")
    content = writes[0].content
    for expected in ctx.attr.expected_substrings:
        asserts.true(
            env,
            expected in content,
            "%r missing from manifest: %s" % (expected, content),
        )
    for forbidden in ctx.attr.forbidden_substrings:
        asserts.false(
            env,
            forbidden in content,
            "%r should not appear in manifest: %s" % (forbidden, content),
        )
    return analysistest.end(env)

manifest_path_test = analysistest.make(
    _manifest_path_test_impl,
    attrs = {
        "expected_substrings": attr.string_list(),
        "forbidden_substrings": attr.string_list(),
    },
)

# -- Where a flutter_test's libraries are built ------------------------

_CODE_ASSET_LIBRARIES = ["libasset_fixture.dylib", "libplugin_asset_fixture.dylib"]
_CODE_ASSET_IDS = [
    "package:asset_fixture/src/ffi/asset_fixture.g.dart",
    "package:plugin_asset_fixture/plugin_asset.dart",
]

def _test_host_assets_test_impl(ctx):
    """Assert that a `flutter_test` loads the libraries `deps` builds for its target.

    They are built once, in the target configuration, and the manifest names
    them under the target's ABI, which is the host's when the test runs on a
    host matching its target.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    writes = [
        a
        for a in actions
        if a.mnemonic == "FileWrite" and
           a.outputs.to_list()[0].basename.endswith(".native_assets.json")
    ]
    asserts.equals(env, 1, len(writes), "expected exactly one manifest write")
    abis = json.decode(writes[0].content)["native-assets"]
    asserts.equals(env, 1, len(abis), "expected one ABI in the manifest: %s" % abis)
    for abi, section in abis.items():
        asserts.true(env, abi.startswith("macos_"), "manifest keyed by %s, not the target's ABI" % abi)
        asserts.equals(env, sorted(_CODE_ASSET_IDS), sorted(section.keys()))

    # A library the test re-declares into its own namespace is a symlink: what
    # was built is the symlink's input.
    symlinked = {}
    for a in actions:
        if a.mnemonic == "Symlink":
            for out in a.outputs.to_list():
                symlinked[out.path] = a.inputs.to_list()[0]
    runfiles = target[DefaultInfo].default_runfiles.files.to_list()
    for name in _CODE_ASSET_LIBRARIES:
        found = [f for f in runfiles if f.basename == name]
        asserts.equals(env, 1, len(found), "%s in the test's runfiles" % name)
        if not found:
            continue
        built = symlinked.get(found[0].path, found[0])
        asserts.equals(
            env,
            False,
            "-exec" in built.path,
            "%s built at %s" % (name, built.path),
        )
    return analysistest.end(env)

_test_host_assets_test = analysistest.make(_test_host_assets_test_impl)

# -- Analysis-time failure tests ---------------------------------------

def _expect_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_substring)
    return analysistest.end(env)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_substring": attr.string(mandatory = True),
    },
)

def _setup_failure_targets():
    """Declare the rule instances whose analysis-time errors we test.

    Wrapped in a function called from the test suite macro so each
    invocation only emits the targets once. `tags = ["manual"]` keeps
    them out of `bazel test //...` glob expansion — they're only built
    by the analysistests that wrap them.
    """

    # A bundled library, probed under the runfiles layout, which otherwise is
    # only exercised through a `flutter_test`. An application's manifest is
    # written by `code_assets.dart`, whose unit test pins its paths.
    dart_code_asset(
        name = "_layout_asset",
        asset_id = "package:layout/layout.dart",
        file = "//flutter/tests/dart_asset_fixture:layout_probe_shared",
        tags = ["manual"],
    )

    _manifest_probe(
        name = "_layout_runfiles",
        code_assets = [":_layout_asset"],
        layout = "runfiles",
        target_arch = "arm64",
        target_os = "macos",
        tags = ["manual"],
    )

def native_assets_test_suite(name):
    """Defines the analysis tests + pure-function tests for Native Assets.

    Args:
      name: The test_suite target name.
    """
    _setup_failure_targets()

    # The counterpart to the bridge probe below: an asset that never arrives
    # because the package's hook has no Bazel replacement. Silence here means
    # a manifest one entry short and an unresolved symbol at runtime, so the
    # application must refuse to build and name the package.
    _expect_failure_test(
        name = name + "_unreplaced_hook",
        target_under_test = "//flutter/tests/dart_asset_fixture/hook_app",
        expected_substring = "hook_fixture (hook/build.dart)",
    )

    # Ownership is checked where the asset is declared, not where it is
    # reached — so a package's declaration naming an id namespaced to some
    # other package fails on its own analysis, with no application involved.
    _expect_failure_test(
        name = name + "_misowned_code_asset",
        target_under_test = "//flutter/tests/dart_asset_fixture/not_owner:pubspec-metadata",
        expected_substring = "is not namespaced to this package",
    )

    # The same check from `flutter_test`. `hook_check_probe` above proves the
    # function's verdict; this proves the rule consults it — a test that
    # compiled a manifest one entry short would fail at run time with the
    # unresolved symbol this exists to pre-empt.
    _expect_failure_test(
        name = name + "_unreplaced_hook_in_test",
        target_under_test = "//flutter/tests/dart_asset_fixture/hook_app:hook_flutter_test",
        expected_substring = "hook_fixture (hook/build.dart)",
    )

    # A test has no bundle, so the same asset must be named by where it sits in
    # the runfiles tree — a path with separators, which is what makes the
    # loader resolve it against the test's working directory rather than
    # searching the system library path.
    manifest_path_test(
        name = name + "_runfiles_layout_path",
        size = "small",
        target_under_test = ":_layout_runfiles",
        expected_substrings = ["\"flutter/tests/_layout_runfiles_code_assets/liblayout_probe.dylib\""],
    )

    # A test loads the libraries `deps` builds for its target.
    _test_host_assets_test(
        name = name + "_test_host_is_target",
        target_under_test = "//flutter/tests/dart_asset_fixture/code_asset_test:code_asset_flutter_test.program",
        target_compatible_with = ["@platforms//os:macos"],
    )

    unittest.suite(
        name + "_pure",
        _target_string_t0_test,
        _target_string_t1_test,
        _framework_name_test,
        _framework_names_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unreplaced_hook",
            ":" + name + "_misowned_code_asset",
            ":" + name + "_unreplaced_hook_in_test",
            ":" + name + "_runfiles_layout_path",
            ":" + name + "_test_host_is_target",
            ":" + name + "_pure",
        ],
    )

# --- check_unreplaced_hooks ---

def _hook_check_probe_impl(ctx):
    err = check_unreplaced_hooks(ctx.label, ctx.attr.deps)
    if ctx.attr.expect_offender:
        if err == None:
            fail("%s: expected check_unreplaced_hooks to report an offender" % ctx.label)
    elif err != None:
        fail("%s: expected no offender, got: %s" % (ctx.label, err))
    return [DefaultInfo(files = depset())]

hook_check_probe = rule(
    implementation = _hook_check_probe_impl,
    attrs = {
        "expect_offender": attr.bool(default = False),
        "deps": attr.label_list(providers = [DartInfo]),
    },
    doc = "Runs `check_unreplaced_hooks` over `deps` and asserts the verdict.",
)

# --- resolve_native_assets ---
#
# Assets rules_dart propagates on `DartPackageInfo.code_assets` must reach the
# application from the package graph alone. The probe below
# runs the bridge over a real `dart_library` graph and reports what it lifted.

def _bridge_probe_impl(ctx):
    lifted = resolve_native_assets(ctx, None, ctx.attr.deps, []).assets
    ids = sorted([a.asset_id for a in lifted])
    if ids != sorted(ctx.attr.expected_asset_ids):
        fail("%s: expected %s, bridged %s" % (ctx.label, sorted(ctx.attr.expected_asset_ids), ids))
    for asset in lifted:
        if asset.link_mode == "dynamic_loading_bundle":
            if asset.file == None:
                fail("%s: bundled asset %s has no file" % (ctx.label, asset.asset_id))

            # The bundle filename must be the plain basename, staged out of
            # `_solib_<arch>/` and into this rule's own output namespace —
            # rules_apple resolves it package-relative.
            if asset.bundle_filename != asset.file.basename:
                fail("%s: bundle_filename %r != staged basename %r" %
                     (ctx.label, asset.bundle_filename, asset.file.basename))
            if "_solib" in asset.file.short_path:
                fail("%s: asset %s was not re-declared out of _solib: %s" %
                     (ctx.label, asset.asset_id, asset.file.short_path))
    return [DefaultInfo(files = depset([a.file for a in lifted if a.file != None]))]

bridge_probe = rule(
    implementation = _bridge_probe_impl,
    attrs = program_assets_attrs() | {
        "deps": attr.label_list(),
        "expected_asset_ids": attr.string_list(),
    },
    toolchains = PROGRAM_ASSETS_TOOLCHAINS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = ["cpp"],
    doc = "Asserts which rules_dart code assets the Flutter bridge lifts.",
)
