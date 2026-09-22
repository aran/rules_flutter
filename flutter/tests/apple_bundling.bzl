"""Shared fixtures and tests for the iOS and macOS bundling rules.

These tests care about how a rule lays its outputs out, not about what a real
Flutter build produces, so their applications are fakes: compiling a real one
per fixture would cost minutes and need a device SDK.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:providers.bzl", "FlutterApplicationInfo")

def _fake_application_impl(ctx):
    """Placeholder outputs, every one declared under this target's name.

    So fakes in one package never share an output — which is the very defect
    the tests over them are checking the real rules for.

    A path named in both `native_libs` and `code_assets` is one File: the shape
    of one library arriving by both routes.
    """
    libs = {}
    for path in ctx.attr.native_libs + ctx.attr.code_assets:
        if path not in libs:
            lib = ctx.actions.declare_file("%s/%s" % (ctx.label.name, path))
            ctx.actions.write(lib, "%s %s" % (ctx.label, path))
            libs[path] = lib

    # Debug carries a kernel and no AOT dylib; release the reverse. Which one
    # a fixture wants is not cosmetic: a release Apple framework retags its
    # dylib with `vtool`, which rejects a placeholder that is not a Mach-O, so
    # a fixture that will actually be *built* has to be a debug one.
    if ctx.attr.debug:
        aot_output = None
        kernel_dill = ctx.actions.declare_file(ctx.label.name + "/app.dill")
        ctx.actions.write(kernel_dill, str(ctx.label))
    else:
        kernel_dill = None
        aot_output = ctx.actions.declare_file(ctx.label.name + "/app.so")
        ctx.actions.write(aot_output, str(ctx.label))

    flutter_assets = ctx.actions.declare_directory(ctx.label.name + "/flutter_assets")
    ctx.actions.run_shell(
        command = 'touch "$1/AssetManifest.bin"',
        arguments = [flutter_assets.path],
        outputs = [flutter_assets],
    )

    return [FlutterApplicationInfo(
        aot_output = aot_output,
        kernel_dill = kernel_dill,
        is_debug = ctx.attr.debug,
        flutter_assets = flutter_assets,
        native_libs = [libs[path] for path in ctx.attr.native_libs],
        bundled_code_assets = depset([libs[path] for path in ctx.attr.code_assets]),
    )]

fake_application = rule(
    implementation = _fake_application_impl,
    attrs = {
        "code_assets": attr.string_list(),
        "debug": attr.bool(default = False),
        "native_libs": attr.string_list(),
    },
    doc = "A fake FlutterApplicationInfo for tests over Apple bundling rules.",
)

def _outputs_under_target_dir_test_impl(ctx):
    """Every output this rule declares sits under a directory named after it.

    The invariant both Apple framework rules exist under: two apps in one
    package are two targets, and Bazel gives a declared file the package's path
    plus whatever name the rule asks for, with nothing of the target's own in
    between. A rule that hardcodes its layout therefore has both targets
    writing one path, which fails the build with conflicting actions as soon as
    the two apps differ enough for their actions to differ. A pair built from
    the *same* application hides it, because Bazel shares identical actions.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    own = "/".join([p for p in [target.label.package, target.label.name] if p])

    outputs = target[DefaultInfo].files.to_list()
    asserts.true(env, len(outputs) > 0, "the rule declared no outputs to check")
    for f in outputs:
        asserts.true(
            env,
            f.short_path == own or f.short_path.startswith(own + "/"),
            "%s is not the directory %s nor under it, so a second app in the " % (f.short_path, own) +
            "package would declare it too",
        )
    return analysistest.end(env)

outputs_under_target_dir_test = analysistest.make(
    _outputs_under_target_dir_test_impl,
)
