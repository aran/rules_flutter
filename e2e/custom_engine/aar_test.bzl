"""A module's AAR refuses an engine that is not the release's.

The module's POM names the engine's Maven artifacts by its revision, and only a
released engine has them: under the checkout's SDK, whose engine has a revision
but no artifacts, analysis fails saying so.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "the \"local\" Flutter SDK's engine is not the release's")
    asserts.expect_failure(env, "which are published for released engines only")
    return analysistest.end(env)

aar_of_local_engine_refused_test = analysistest.make(
    _refused_impl,
    expect_failure = True,
    config_settings = {str(Label("@rules_flutter//flutter:sdk")): "local"},
)
