"""Tests that `fonts_json` and `font_files` state the same fonts.

Every font a package declares must reach the bundle with its own file, and
every file listed must belong to a declared font. A mismatch fails the build,
as a missing font does for `flutter build`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_library.bzl", "aggregate_pub_contributions")

def _font_mismatch_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

font_mismatch_fails_test = analysistest.make(
    _font_mismatch_fails_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)

def _fonts_bundled_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    manifest = aggregate_pub_contributions([target])[0]
    asserts.equals(env, json.decode(ctx.attr.manifest), manifest)
    files = {
        font.bundle_path: font.file.short_path.removeprefix(ctx.label.package + "/")
        for entry in target[FlutterInfo].pub_fonts.to_list()
        for font in entry.fonts
    }
    asserts.equals(env, ctx.attr.files, files)
    return analysistest.end(env)

# `manifest` is the JSON of the library's FontManifest entries; `files` maps
# each font's bundle path to its file, relative to this test's package.
fonts_bundled_test = analysistest.make(
    _fonts_bundled_test_impl,
    attrs = {
        "files": attr.string_dict(mandatory = True),
        "manifest": attr.string(mandatory = True),
    },
)
