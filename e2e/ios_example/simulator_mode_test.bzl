"""The simulator app is refused outside debug mode.

The simulator engine runs only kernel under the JIT, so an AOT bundle for it
launches to a white screen. `flutter_ios_app` must refuse that build at
analysis rather than produce it.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _refused_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        "The iOS simulator runs debug builds only, and this is a fastbuild build.",
    )
    return analysistest.end(env)

simulator_fastbuild_refused_test = analysistest.make(
    _refused_impl,
    expect_failure = True,
    config_settings = {"//command_line_option:compilation_mode": "fastbuild"},
)
