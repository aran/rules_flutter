"""Tests that `flutter_library` / `flutter_plugin` carry `resources`.

`DartInfo.transitive_resources` is how a package's non-Dart `lib/` files
(images, templates, JS, YAML) reach everything that stages a whole package —
`dart_analyze_test`, `dart_test`, the dev tool. A provider field that was
never set has no default, so a rule that drops its own `resources` on the
floor produces a package with pieces missing. The probe pins the contract:
files listed on the new `resources` attribute must land in the provider.

The `.dart` refusal mirrors `dart_library`: `resources` names the non-Dart
remainder of `lib/`; a Dart source there is a mis-filed `srcs` entry, and
identical paths with identical extensions would otherwise collide silently.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartInfo")

def _resources_probe_impl(ctx):
    got = sorted([
        f.basename
        for dep in ctx.attr.deps
        for f in dep[DartInfo].transitive_resources.to_list()
    ])
    want = sorted(ctx.attr.expected_basenames)
    if got != want:
        fail("%s: expected transitive_resources basenames %s, got %s" % (
            ctx.label,
            want,
            got,
        ))
    return [DefaultInfo(files = depset())]

resources_probe = rule(
    implementation = _resources_probe_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "expected_basenames": attr.string_list(),
    },
    doc = "Asserts the union of deps' `DartInfo.transitive_resources` basenames.",
)

def _dart_in_resources_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is a Dart source in `resources`")
    return analysistest.end(env)

dart_in_resources_fails_test = analysistest.make(
    _dart_in_resources_fails_test_impl,
    expect_failure = True,
)
