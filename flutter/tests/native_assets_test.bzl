"""Analysis-time validation tests for the Native Assets rules.

These tests specify the documented contract of `flutter_native_asset` /
`flutter_data_asset`: invalid configurations must fail at analysis time,
not silently produce something that breaks at runtime.

Each test uses `analysistest.make(expect_failure = True)` and pairs the
target under test with an `asserts.expect_failure(env, "<substring>")`
check against the produced error message — so we both assert the rule
fails *and* assert the failure message points the user at the right
fix.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_dart//dart:providers.bzl", "DartInfo", "DartPackageInfo")
load("//flutter:native_assets.bzl", "flutter_data_asset", "flutter_native_asset")
load("//flutter:providers.bzl", "FlutterNativeAssetInfo")
load("//flutter/private:common.bzl", "check_unreplaced_hooks")
load("//flutter/private:flutter_native_assets.bzl", "bridge_dart_code_assets", "native_asset_framework_name", "native_assets_target_string", "write_native_assets_manifest")

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

    # Strips the `.dylib` extension; sanitizes nothing it doesn't need to.
    asserts.equals(env, "objective_c", native_asset_framework_name("objective_c.dylib"))

    # Strips a leading `lib` only when it's a dylib (matches frameworkUri).
    asserts.equals(env, "sqlite3", native_asset_framework_name("libsqlite3.dylib"))

    # Sanitizes characters outside [A-Za-z0-9_-].
    asserts.equals(env, "my-lib_2", native_asset_framework_name("my-lib_2.dylib"))
    asserts.equals(env, "foobar", native_asset_framework_name("foo.bar.dylib"))

    # A `lib` prefix is kept when there is no `.dylib` extension to strip.
    asserts.equals(env, "libfoo", native_asset_framework_name("libfoo"))
    return unittest.end(env)

def _identical_assets_dedup_impl(ctx):
    """Pin how identical asset declarations behave in the propagation depset.

    `FlutterInfo.native_assets` is a depset of these providers, so two
    targets declaring byte-identical assets collapse to one element before
    the manifest writer ever sees them. That is why the duplicate-id
    `fail()` catches *conflicting* declarations rather than repeated ones.
    """
    env = unittest.begin(ctx)

    def executable_asset():
        return FlutterNativeAssetInfo(
            asset_id = "package:foo/foo.dart",
            link_mode = "dynamic_loading_executable",
            file = None,
            bundle_filename = "",
            system_uri = "",
        )

    asserts.equals(env, 1, len(depset([executable_asset(), executable_asset()]).to_list()))

    # Conflicting declarations stay distinct, so they still reach the
    # writer as two entries and trip its duplicate-id check.
    conflicting = [
        FlutterNativeAssetInfo(
            asset_id = "package:foo/foo.dart",
            link_mode = "dynamic_loading_system",
            file = None,
            bundle_filename = "",
            system_uri = uri,
        )
        for uri in ["libfoo.so.1", "libfoo.so.2"]
    ]
    asserts.equals(env, 2, len(depset(conflicting).to_list()))
    return unittest.end(env)

_target_string_t0_test = unittest.make(_target_string_macos_arm64_impl)
_target_string_t1_test = unittest.make(_target_string_unknown_impl)
_framework_name_test = unittest.make(_framework_name_impl)
_identical_assets_dedup_test = unittest.make(_identical_assets_dedup_impl)

# -- Manifest probe ----------------------------------------------------

def _manifest_probe_impl(ctx):
    """Run the manifest writer over `assets` for a fixed (os, arch) pair.

    `write_native_assets_manifest` needs a rule context, so exercising
    its analysis-time contract needs a rule to host it. This one stands
    in for `flutter_application`'s aggregation step without dragging the
    whole compile pipeline (and a Flutter toolchain) into a unit test.
    """
    output = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = output,
        native_assets = [dep[FlutterNativeAssetInfo] for dep in ctx.attr.assets],
        target_os = ctx.attr.target_os,
        target_arch = ctx.attr.target_arch,
        layout = ctx.attr.layout,
    )
    return [DefaultInfo(files = depset([output]))]

_manifest_probe = rule(
    implementation = _manifest_probe_impl,
    attrs = {
        "assets": attr.label_list(providers = [FlutterNativeAssetInfo]),
        "layout": attr.string(default = "bundle"),
        "target_arch": attr.string(mandatory = True),
        "target_os": attr.string(mandatory = True),
    },
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
    flutter_native_asset(
        name = "_static_link_mode",
        asset_id = "package:foo/foo.dylib",
        link_mode = "static",
        tags = ["manual"],
    )

    flutter_native_asset(
        name = "_bundle_missing_library",
        asset_id = "package:foo/foo.dylib",
        link_mode = "dynamic_loading_bundle",
        bundle_filename = "foo.dylib",
        tags = ["manual"],
    )

    flutter_native_asset(
        name = "_system_missing_uri",
        asset_id = "package:foo/foo.dylib",
        link_mode = "dynamic_loading_system",
        tags = ["manual"],
    )

    flutter_data_asset(
        name = "_data_bad_id",
        asset_id = "not-a-package-id",
        file = "BUILD.bazel",
        tags = ["manual"],
    )

    # Two declarations of one asset id reaching a single application:
    # the manifest can only carry one entry per id, so this must break
    # loudly instead of letting one silently shadow the other.
    flutter_native_asset(
        name = "_duplicate_id_a",
        asset_id = "package:foo/foo.dylib",
        link_mode = "dynamic_loading_system",
        system_uri = "libfoo.so.1",
        tags = ["manual"],
    )

    flutter_native_asset(
        name = "_duplicate_id_b",
        asset_id = "package:foo/foo.dylib",
        link_mode = "dynamic_loading_system",
        system_uri = "libfoo.so.2",
        tags = ["manual"],
    )

    _manifest_probe(
        name = "_duplicate_asset_ids",
        assets = [
            ":_duplicate_id_a",
            ":_duplicate_id_b",
        ],
        target_arch = "arm64",
        target_os = "macos",
        tags = ["manual"],
    )

    # A `flutter_native_asset`-declared bundled library, probed under both
    # layouts. This is the arm the Native Assets e2e does not reach — that one
    # goes through `bridge_dart_code_assets` — so without these the runfiles
    # layout is only ever exercised for bridged assets.
    flutter_native_asset(
        name = "_layout_asset",
        asset_id = "package:layout/layout.dart",
        library = "//flutter/tests/dart_asset_fixture:asset_fixture_shared",
        bundle_filename = "liblayout_probe.dylib",
        link_mode = "dynamic_loading_bundle",
        tags = ["manual"],
    )

    _manifest_probe(
        name = "_layout_bundle",
        assets = [":_layout_asset"],
        layout = "bundle",
        target_arch = "arm64",
        target_os = "macos",
        tags = ["manual"],
    )

    _manifest_probe(
        name = "_layout_runfiles",
        assets = [":_layout_asset"],
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

    _expect_failure_test(
        name = name + "_static_fails",
        target_under_test = ":_static_link_mode",
        expected_substring = "link_mode = \"static\"",
    )

    _expect_failure_test(
        name = name + "_bundle_requires_library",
        target_under_test = ":_bundle_missing_library",
        expected_substring = "requires `library = ",
    )

    _expect_failure_test(
        name = name + "_system_requires_uri",
        target_under_test = ":_system_missing_uri",
        expected_substring = "requires `system_uri",
    )

    _expect_failure_test(
        name = name + "_data_asset_id_format",
        target_under_test = ":_data_bad_id",
        expected_substring = "must start with `package:`",
    )

    _expect_failure_test(
        name = name + "_duplicate_asset_ids",
        target_under_test = ":_duplicate_asset_ids",
        expected_substring = "duplicate native asset id \"package:foo/foo.dylib\"",
    )

    # The counterpart to the bridge probe below: an asset that never arrives
    # because the package's hook has no Bazel replacement. Silence here means
    # a manifest one entry short and an unresolved symbol at runtime, so the
    # application must refuse to build and name the package.
    _expect_failure_test(
        name = name + "_unreplaced_hook",
        target_under_test = "//flutter/tests/dart_asset_fixture:hook_app",
        expected_substring = "hook_fixture (hook/build.dart)",
    )

    # Ownership is checked where the asset is declared, not where it is
    # reached — so a `flutter_library` naming an id namespaced to some other
    # package fails on its own analysis, with no application involved.
    _expect_failure_test(
        name = name + "_misowned_code_asset",
        target_under_test = "//flutter/tests/dart_asset_fixture:misowned_asset_fixture",
        expected_substring = "is not namespaced to this package",
    )

    # The same check from `flutter_test`. `hook_check_probe` above proves the
    # function's verdict; this proves the rule consults it — a test that
    # compiled a manifest one entry short would fail at run time with the
    # unresolved symbol this exists to pre-empt.
    _expect_failure_test(
        name = name + "_unreplaced_hook_in_test",
        target_under_test = "//flutter/tests/dart_asset_fixture:hook_flutter_test",
        expected_substring = "hook_fixture (hook/build.dart)",
    )

    # An application resolves a bundled library inside its bundle slot, so the
    # bare filename is all the engine needs.
    manifest_path_test(
        name = name + "_bundle_layout_path",
        size = "small",
        target_under_test = ":_layout_bundle",
        expected_substrings = ["\"liblayout_probe.dylib\""],
        # The distinguishing part: no directory component at all, so the engine
        # resolves it inside the bundle slot rather than anywhere else.
        forbidden_substrings = ["flutter/tests/"],
    )

    # A test has no bundle, so the same asset must be named by where it sits in
    # the runfiles tree — a path with separators, which is what makes the
    # loader resolve it against the test's working directory rather than
    # searching the system library path.
    manifest_path_test(
        name = name + "_runfiles_layout_path",
        size = "small",
        target_under_test = ":_layout_runfiles",
        expected_substrings = ["\"flutter/tests/liblayout_probe.dylib\""],
    )

    unittest.suite(
        name + "_pure",
        _target_string_t0_test,
        _target_string_t1_test,
        _framework_name_test,
        _identical_assets_dedup_test,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_static_fails",
            ":" + name + "_bundle_requires_library",
            ":" + name + "_system_requires_uri",
            ":" + name + "_data_asset_id_format",
            ":" + name + "_duplicate_asset_ids",
            ":" + name + "_unreplaced_hook",
            ":" + name + "_misowned_code_asset",
            ":" + name + "_unreplaced_hook_in_test",
            ":" + name + "_bundle_layout_path",
            ":" + name + "_runfiles_layout_path",
            ":" + name + "_pure",
        ],
    )

# --- check_unreplaced_hooks tolerance ---
#
# The hook check reads a field off `DartPackageInfo`, which is rules_dart's
# provider and is documented to tolerate a record built before a given field
# existed. A record from such a producer must read as "no hook" rather than
# failing analysis — it is not an offender, and it could not have been one.

def _legacy_dart_library_impl(ctx):
    # The pre-`has_unreplaced_hook` record shape, matching rules_dart's own
    # `//dart/tests/no_lv_fixture`: `package_name` and `lib_root` and nothing
    # else. Built by hand on purpose — a fixture asserting that older producers
    # still work cannot be written through a constructor that makes them
    # current.
    pkg = DartPackageInfo(
        package_name = ctx.attr.package_name,
        lib_root = ctx.label.package,
    )
    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        DartInfo(
            package_name = ctx.attr.package_name,
            lib_root = ctx.label.package,
            transitive_srcs = depset(ctx.files.srcs),
            transitive_resources = depset(),
            transitive_packages = depset([pkg]),
        ),
    ]

legacy_dart_library = rule(
    implementation = _legacy_dart_library_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "srcs": attr.label_list(allow_files = [".dart"]),
    },
    doc = "Emits a `DartPackageInfo` predating `has_unreplaced_hook`.",
)

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

# --- bridge_dart_code_assets ---
#
# Assets rules_dart propagates on `DartPackageInfo.code_assets` must reach the
# application without anyone writing a `flutter_native_asset`. The probe below
# runs the bridge over a real `dart_library` graph and reports what it lifted.

def _bridge_probe_impl(ctx):
    lifted = bridge_dart_code_assets(ctx, ctx.attr.deps)
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
    attrs = {
        "deps": attr.label_list(),
        "expected_asset_ids": attr.string_list(),
    },
    doc = "Asserts which rules_dart code assets the Flutter bridge lifts.",
)
