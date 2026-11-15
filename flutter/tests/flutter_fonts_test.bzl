"""Tests of the fonts a package's `flutter_font_family` targets bundle.

Every font a package declares reaches the bundle with its own file, keyed as
flutter_tools keys it, and a font that is no file of the package fails the
build unless its `asset` names another package's.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions", "package_root_of")

def _analysis_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

analysis_fails_test = analysistest.make(
    _analysis_fails_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)

def _fonts_bundled_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    program_root = package_root_of(target) if ctx.attr.own_package else None
    deps = [target, ctx.attr.also_through] if ctx.attr.also_through else [target]
    manifest, copies, _ = aggregate_pub_contributions(deps, program_root = program_root)
    asserts.equals(env, json.decode(ctx.attr.manifest), manifest)
    font_keys = [font["asset"] for family in manifest for font in family["fonts"]]
    files = {
        key: f.short_path.removeprefix(ctx.label.package + "/")
        for key, f in copies
        if key in font_keys
    }
    asserts.equals(env, ctx.attr.files, files)
    return analysistest.end(env)

# `manifest` is the JSON of the library's FontManifest entries; `files` maps
# each font's bundle path to its file, relative to this test's package. Both
# are as a program of another package bundles them, or with `own_package` as
# a program of the library's own package does. `also_through` is a second dep
# of the program that reaches the same library.
fonts_bundled_test = analysistest.make(
    _fonts_bundled_test_impl,
    attrs = {
        "also_through": attr.label(),
        "files": attr.string_dict(mandatory = True),
        "manifest": attr.string(mandatory = True),
        "own_package": attr.bool(),
    },
)

def _assets_owner_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    owned = sorted([
        "{}:{}".format(entry.package_name, entry.asset_path)
        for entry in target[FlutterInfo].pub_assets.to_list()
    ])
    asserts.equals(env, sorted(ctx.attr.assets), owned)
    return analysistest.end(env)

# `assets` lists each asset as `<package>:<path>`; the bundle keys it
# `packages/<package>/<path>`.
assets_owner_test = analysistest.make(
    _assets_owner_test_impl,
    attrs = {"assets": attr.string_list(mandatory = True)},
)
