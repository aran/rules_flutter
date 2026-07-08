"""Analysis tests for flutter_android_manifest_merge.

Asserts the rule registers exactly one strict-merger action over the base
and overlay manifests and exposes the merged AndroidManifest.xml as its
only output — the contract flutter_android_app's debug-variant select()
arm relies on.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter:android.bzl", "flutter_android_manifest_merge")

def _merge_action_test_impl(ctx):
    env = analysistest.begin(ctx)

    actions = analysistest.target_actions(env)
    merge_actions = [a for a in actions if a.mnemonic == "FlutterManifestMerge"]
    asserts.equals(env, 1, len(merge_actions), "expected exactly one FlutterManifestMerge action")
    action = merge_actions[0]

    argv = action.argv
    asserts.true(env, "--base" in argv, "argv must pass --base")
    asserts.true(env, "--overlay" in argv, "argv must pass --overlay")
    asserts.true(env, "--output" in argv, "argv must pass --output")
    base_arg = argv[argv.index("--base") + 1]
    overlay_arg = argv[argv.index("--overlay") + 1]
    asserts.true(
        env,
        base_arg.endswith("manifest_merge/AndroidManifest.xml"),
        "--base must be the base manifest, got %s" % base_arg,
    )
    asserts.true(
        env,
        overlay_arg.endswith("manifest_merge/DebugAndroidManifest.xml"),
        "--overlay must be the variant manifest, got %s" % overlay_arg,
    )

    input_basenames = [f.basename for f in action.inputs.to_list()]
    asserts.true(
        env,
        "merge_android_manifests.dart" in input_basenames,
        "the merger tool must be an action input",
    )

    outputs = action.outputs.to_list()
    asserts.equals(env, 1, len(outputs))
    asserts.equals(env, "AndroidManifest.xml", outputs[0].basename)

    target = analysistest.target_under_test(env)
    default_outputs = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(default_outputs), "rule must expose exactly the merged manifest")
    asserts.equals(env, "AndroidManifest.xml", default_outputs[0].basename)

    return analysistest.end(env)

_merge_action_test = analysistest.make(_merge_action_test_impl)

def manifest_merge_test_suite(name):
    """Defines the analysis tests for flutter_android_manifest_merge.

    Args:
      name: The test_suite target name.
    """
    flutter_android_manifest_merge(
        name = "_manifest_merge_under_test",
        base = "manifest_merge/AndroidManifest.xml",
        overlay = "manifest_merge/DebugAndroidManifest.xml",
        tags = ["manual"],
    )

    _merge_action_test(
        name = name + "_action",
        target_under_test = ":_manifest_merge_under_test",
    )

    native.test_suite(
        name = name,
        tests = [":" + name + "_action"],
    )
