"""Unit and analysis tests for package-relative Flutter asset keys (`assets`).

The rule, from flutter_tools (`lib/src/asset.dart` at the pinned SDK): an
asset of the listing target's own package is keyed by its path relative to
that package's directory; a `flutter_library` or `flutter_plugin` asset is
keyed `packages/<package_name>/...`. The rule is by directory, not by Bazel
package boundary: a nested subpackage's files are still under the directory
and keyed, never refused. A file outside the directory tree is refused, as
are two files sharing one key. `pkg_assets` already keys correctly and is
not covered here.

The pure path math is pinned by unit tests (including the external-repository
and workspace-root spellings, which no in-repo target can exhibit). The rule
wiring is pinned by analysis tests over `//flutter/tests/asset_keys_fixture`
targets: a fixture subpackage, so every key proves its prefix was stripped.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("//flutter:providers.bzl", "FlutterInfo")
load(
    "//flutter/private:asset_keys.bzl",
    "bundle_asset_entries",
    "is_within_package",
    "relative_key",
)

_FIXTURE = "//flutter/tests/asset_keys_fixture"

def _root_key_is_short_path_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "assets/logo.png",
        relative_key("", "", "assets/logo.png"),
    )
    return unittest.end(env)

def _subpackage_key_strips_package_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "assets/sub.txt",
        relative_key("", "apps/sub", "apps/sub/assets/sub.txt"),
    )
    return unittest.end(env)

def _external_key_strips_repo_root_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "assets/x.png",
        relative_key("external/foo", "bar", "../foo/bar/assets/x.png"),
    )
    return unittest.end(env)

def _external_root_key_strips_repo_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "assets/x.png",
        relative_key("external/foo", "", "../foo/assets/x.png"),
    )
    return unittest.end(env)

def _generated_key_strips_bazel_out_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "gen.txt",
        relative_key("", "apps/sub", "bazel-out/k8-fastbuild/bin/apps/sub/gen.txt"),
    )
    return unittest.end(env)

def _root_contains_same_repo_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_within_package("", "", "anything/at/all.png"))
    asserts.false(env, is_within_package("", "", "../other_repo/a.png"))
    return unittest.end(env)

def _subpackage_membership_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_within_package("", "apps/sub", "apps/sub/a.txt"))
    asserts.false(env, is_within_package("", "apps/sub", "apps/other.txt"))
    asserts.false(env, is_within_package("", "apps/sub", "top.txt"))
    return unittest.end(env)

def _cross_repo_is_outside_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, is_within_package("", "apps/sub", "../foo/bar/a.txt"))
    asserts.false(env, is_within_package("external/foo", "bar", "apps/sub/a.txt"))
    return unittest.end(env)

def _nested_dir_is_within_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_within_package("", "apps/sub", "apps/sub/nested/a.txt"))
    asserts.equals(
        env,
        "nested/a.txt",
        relative_key("", "apps/sub", "apps/sub/nested/a.txt"),
    )
    return unittest.end(env)

def _root_generated_key_is_repo_relative_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "root_gen.txt",
        relative_key("", "", "bazel-out/k8-fastbuild/bin/root_gen.txt"),
    )
    asserts.equals(
        env,
        "flutter/tests/asset_keys_fixture/assets/brand.txt",
        relative_key("", "", "flutter/tests/asset_keys_fixture/assets/brand.txt"),
    )
    return unittest.end(env)

_t0_test = unittest.make(_root_key_is_short_path_test_impl)
_t1_test = unittest.make(_subpackage_key_strips_package_test_impl)
_t2_test = unittest.make(_external_key_strips_repo_root_test_impl)
_t3_test = unittest.make(_external_root_key_strips_repo_test_impl)
_t4_test = unittest.make(_generated_key_strips_bazel_out_test_impl)
_t5_test = unittest.make(_root_contains_same_repo_test_impl)
_t6_test = unittest.make(_subpackage_membership_test_impl)
_t7_test = unittest.make(_cross_repo_is_outside_test_impl)
_t8_test = unittest.make(_nested_dir_is_within_test_impl)
_t9_test = unittest.make(_root_generated_key_is_repo_relative_test_impl)

def _entry_keys(info):
    return sorted([e.key for e in info.assets.to_list()])

def _library_keys_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]
    asserts.equals(env, ["packages/brand/assets/brand.txt"], _entry_keys(info))
    asserts.false(
        env,
        info.asset_dirs.to_list() == [],
        "asset_dirs stays populated for compatibility",
    )
    return analysistest.end(env)

_library_keys_test = analysistest.make(_library_keys_test_impl)

def _consumer_forwards_keys_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]
    asserts.true(
        env,
        "packages/brand/assets/brand.txt" in _entry_keys(info),
        "the dependency's keyed entry must travel: %s" % _entry_keys(info),
    )
    return analysistest.end(env)

_consumer_forwards_keys_test = analysistest.make(_consumer_forwards_keys_test_impl)

_KeyProbeInfo = provider(
    doc = "The bundle entries a probe assembled, as keys.",
    fields = {"keys": "list[str]: Bundle-relative asset keys, in bundle order."},
)

def _entries_probe_impl(ctx):
    entries = bundle_asset_entries(ctx.label, ctx.files.assets, ctx.attr.deps)
    return [
        DefaultInfo(files = depset()),
        _KeyProbeInfo(keys = [e.key for e in entries]),
    ]

entries_probe = rule(
    implementation = _entries_probe_impl,
    attrs = {
        "assets": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [DartInfo]),
    },
    doc = "Assembles bundle entries like a bundling rule, exposing the keys.",
)

def _own_keys_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(
        env,
        ["asset_keys_own.txt", "packages/brand/assets/brand.txt"],
        analysistest.target_under_test(env)[_KeyProbeInfo].keys,
    )
    return analysistest.end(env)

_own_keys_test = analysistest.make(_own_keys_test_impl)

def _outside_lib_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "outside the target's package")
    return analysistest.end(env)

_outside_lib_fails_test = analysistest.make(
    _outside_lib_fails_test_impl,
    expect_failure = True,
)

def _outside_bundle_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "move it into a flutter_library with a package_name")
    return analysistest.end(env)

_outside_bundle_fails_test = analysistest.make(
    _outside_bundle_fails_test_impl,
    expect_failure = True,
)

def _collision_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        "share key 'packages/dup/assets/dup.txt': " +
        "flutter/tests/asset_keys_fixture/coll/assets/dup.txt " +
        "(from @@//flutter/tests/asset_keys_fixture/coll:dup_b) and " +
        "flutter/tests/asset_keys_fixture/coll_a/assets/dup.txt " +
        "(from @@//flutter/tests/asset_keys_fixture/coll_a:dup_a)",
    )
    return analysistest.end(env)

_collision_fails_test = analysistest.make(
    _collision_fails_test_impl,
    expect_failure = True,
)

def _nested_keys_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(
        env,
        ["asset_keys_fixture/coll/assets/dup.txt"],
        analysistest.target_under_test(env)[_KeyProbeInfo].keys,
    )
    return analysistest.end(env)

_nested_keys_test = analysistest.make(_nested_keys_test_impl)

def _generated_keys_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]
    asserts.equals(env, ["packages/genlib/gen_asset.txt"], _entry_keys(info))
    return analysistest.end(env)

_generated_keys_test = analysistest.make(_generated_keys_test_impl)

def asset_keys_test_suite(name):
    """Defines the asset-keys unit and analysis tests.

    Args:
        name: Name of the resulting test_suite.
    """
    unittest.suite(
        name + "_keys_pure",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
    )

    # The probe lists its own package's asset file, so its own entry proves
    # the "flutter/tests" prefix is stripped — the same computation every
    # bundling rule runs for its own `assets`.
    entries_probe(
        name = name + "_probe",
        assets = ["asset_keys_own.txt"],
        deps = [_FIXTURE + ":brand"],
        tags = ["manual"],
    )
    _own_keys_test(
        name = name + "_own_keys",
        target_under_test = ":" + name + "_probe",
    )

    # A nested subpackage's file, reached through its `exports_files`, is
    # still under this package's directory: keyed, never refused.
    entries_probe(
        name = name + "_nested_probe",
        assets = [_FIXTURE + "/coll:assets/dup.txt"],
        tags = ["manual"],
    )
    _nested_keys_test(
        name = name + "_nested_keys",
        target_under_test = ":" + name + "_nested_probe",
    )
    _generated_keys_test(
        name = name + "_generated_keys",
        target_under_test = _FIXTURE + ":gen_lib",
    )
    _library_keys_test(
        name = name + "_library_keys",
        target_under_test = _FIXTURE + ":brand",
    )
    _consumer_forwards_keys_test(
        name = name + "_consumer_forwards_keys",
        target_under_test = _FIXTURE + ":brand_consumer",
    )
    _outside_lib_fails_test(
        name = name + "_outside_lib_fails",
        target_under_test = _FIXTURE + ":outside_lib",
    )
    _outside_bundle_fails_test(
        name = name + "_outside_bundle_fails",
        target_under_test = _FIXTURE + ":outside_bundle",
    )
    _collision_fails_test(
        name = name + "_collision_fails",
        target_under_test = _FIXTURE + ":colliding_bundle",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_keys_pure",
            ":" + name + "_own_keys",
            ":" + name + "_nested_keys",
            ":" + name + "_generated_keys",
            ":" + name + "_library_keys",
            ":" + name + "_consumer_forwards_keys",
            ":" + name + "_outside_lib_fails",
            ":" + name + "_outside_bundle_fails",
            ":" + name + "_collision_fails",
        ],
    )
