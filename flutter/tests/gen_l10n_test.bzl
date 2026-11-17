"""Analysis tests of where `flutter_gen_l10n` declares its outputs."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _outputs_impl(ctx):
    env = analysistest.begin(ctx)
    files = analysistest.target_under_test(env)[DefaultInfo].files.to_list()
    asserts.equals(env, sorted(ctx.attr.expected), sorted([f.short_path for f in files]))
    return analysistest.end(env)

gen_l10n_outputs_test = analysistest.make(
    _outputs_impl,
    attrs = {"expected": attr.string_list(doc = "The outputs' short paths.")},
)
