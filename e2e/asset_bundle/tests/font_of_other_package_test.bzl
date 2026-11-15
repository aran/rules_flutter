"""A pub package's font named `packages/<package>/<path>` keeps that path."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

# The aggregation an application's bundle goes through: there is no public name
# for it.
# buildifier: disable=bzl-visibility
load("@rules_flutter//flutter/private:flutter_library.bzl", "aggregate_pub_contributions")

def _impl(ctx):
    env = analysistest.begin(ctx)
    manifest = aggregate_pub_contributions([analysistest.target_under_test(env)])[0]
    asserts.equals(
        env,
        [{"family": "packages/fx_font_borrower/Borrowed", "fonts": [
            {"asset": "packages/fx_font_owner/fonts/Owner.ttf"},
            {"asset": "packages/fx_font_borrower/fonts/Self.ttf"},
        ]}],
        manifest,
    )
    return analysistest.end(env)

font_of_other_package_test = analysistest.make(_impl)
