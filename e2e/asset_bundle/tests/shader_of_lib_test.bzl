"""A pub package's shader listed as `packages/<itself>/<path>` is its file `lib/<path>`."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_flutter//flutter:providers.bzl", "FlutterInfo")

def _impl(ctx):
    env = analysistest.begin(ctx)
    shaders = {
        entry.shader_path: entry.file
        for entry in analysistest.target_under_test(env)[FlutterInfo].pub_shaders.to_list()
    }
    asserts.true(env, "shaders/in_lib.frag" in shaders, "no shader is keyed shaders/in_lib.frag: %s" % shaders.keys())
    file = shaders.get("shaders/in_lib.frag")
    if file:
        # The file of the package's `lib/` itself: the repository puts nothing
        # at `shaders/in_lib.frag`, where the package's root has a `shaders/`.
        asserts.true(
            env,
            file.short_path.endswith("/lib/shaders/in_lib.frag"),
            "keyed shaders/in_lib.frag is %s, not the package's lib/shaders/in_lib.frag" % file.short_path,
        )
    return analysistest.end(env)

shader_of_lib_test = analysistest.make(_impl)
