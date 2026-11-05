"""Tests that `fonts_json` and `font_files` state the same fonts.

Every font a package declares must reach the bundle with its own file, and
every file listed must belong to a declared font. A mismatch fails the build,
as a missing font does for `flutter build`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _font_mismatch_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

font_mismatch_fails_test = analysistest.make(
    _font_mismatch_fails_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)
