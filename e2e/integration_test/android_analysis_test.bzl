"""An Android integration test gives the analyzer its test file.

The app of an Android test is rules_android's `android_binary`, which passes on
nothing of the Flutter program inside it. The test finds the program's Dart
files through the app's `flutter_android_bundle`, so a test file that runs on
Android alone is analyzed too.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo")

def _impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, DartAnalyzableInfo in target, "the test gives the analyzer its program's files")
    if DartAnalyzableInfo in target:
        entries = [f.short_path for f in target[DartAnalyzableInfo].entry_srcs.to_list()]
        asserts.true(
            env,
            ctx.attr.src in entries,
            "the test file %s is among the program's own: %s" % (ctx.attr.src, entries),
        )
    return analysistest.end(env)

android_test_analyzed_test = analysistest.make(
    _impl,
    attrs = {
        "src": attr.string(doc = "The test file's short path."),
    },
)
