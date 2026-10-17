"""Analysis tests for flutter_plist_merge.

Asserts the rule registers exactly one strict-merger action carrying the
mode, the base and every addition, and exposes the merged plist under the
caller-chosen basename — the contract `additional_entitlements` and the iOS
Dart VM service supplement both rely on. Also covers the base-less case:
an iOS app with no Xcode capabilities ships no entitlements file, and the
additions must still produce one.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_plist_merge.bzl", "flutter_entitlements_merge", "flutter_plist_merge")

def _merge_action(env):
    actions = analysistest.target_actions(env)
    merge_actions = [a for a in actions if a.mnemonic == "FlutterPlistMerge"]
    asserts.equals(env, 1, len(merge_actions), "expected exactly one FlutterPlistMerge action")
    return merge_actions[0]

def _strict_add_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _merge_action(env)
    argv = action.argv

    asserts.true(env, "--mode" in argv, "argv must pass --mode")
    asserts.equals(
        env,
        "strict-add",
        argv[argv.index("--mode") + 1],
        "flutter_entitlements_merge must request the strict-add mode",
    )

    asserts.true(env, "--base" in argv, "argv must pass --base")
    base_arg = argv[argv.index("--base") + 1]
    asserts.true(
        env,
        base_arg.endswith("plist_merge/Base.entitlements"),
        "--base must be the base entitlements, got %s" % base_arg,
    )

    additions = [argv[i + 1] for i in range(len(argv)) if argv[i] == "--addition"]
    asserts.equals(env, 2, len(additions), "every addition must reach the tool")
    asserts.true(
        env,
        additions[0].endswith("plist_merge/Network.entitlements"),
        "additions must keep their declared order, got %s" % additions[0],
    )
    asserts.true(
        env,
        additions[1].endswith("plist_merge/Files.entitlements"),
        "additions must keep their declared order, got %s" % additions[1],
    )

    input_basenames = [f.basename for f in action.inputs.to_list()]
    asserts.true(
        env,
        "merge_plists" in input_basenames or "merge_plists.exe" in input_basenames,
        "the merger tool must be an action input",
    )

    outputs = action.outputs.to_list()
    asserts.equals(env, 1, len(outputs))
    asserts.equals(env, "Merged.entitlements", outputs[0].basename)

    target = analysistest.target_under_test(env)
    default_outputs = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(default_outputs), "rule must expose exactly the merged plist")
    asserts.equals(env, "Merged.entitlements", default_outputs[0].basename)

    return analysistest.end(env)

def _no_base_test_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _merge_action(env).argv

    # An iOS app without Xcode capabilities ships no entitlements file; the
    # additions must still merge, into an empty plist.
    asserts.false(
        env,
        "--base" in argv,
        "no --base may be passed when the rule has no base attribute",
    )
    additions = [argv[i + 1] for i in range(len(argv)) if argv[i] == "--addition"]
    asserts.equals(env, 1, len(additions))

    return analysistest.end(env)

def _supplement_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _merge_action(env)
    argv = action.argv

    asserts.equals(
        env,
        "supplement",
        argv[argv.index("--mode") + 1],
        "the supplement mode must reach the tool",
    )
    asserts.equals(env, "Info.plist", action.outputs.to_list()[0].basename)

    return analysistest.end(env)

_strict_add_test = analysistest.make(_strict_add_test_impl)
_no_base_test = analysistest.make(_no_base_test_impl)
_supplement_test = analysistest.make(_supplement_test_impl)

def plist_merge_test_suite(name):
    """Defines the analysis tests for flutter_plist_merge.

    Args:
      name: The test_suite target name.
    """
    flutter_entitlements_merge(
        name = "_entitlements_merge_under_test",
        base = "plist_merge/Base.entitlements",
        additions = [
            "plist_merge/Network.entitlements",
            "plist_merge/Files.entitlements",
        ],
        tags = ["manual"],
    )

    flutter_entitlements_merge(
        name = "_entitlements_merge_no_base_under_test",
        additions = ["plist_merge/Network.entitlements"],
        tags = ["manual"],
    )

    flutter_plist_merge(
        name = "_plist_supplement_under_test",
        base = "plist_merge/Base.entitlements",
        additions = ["plist_merge/Network.entitlements"],
        mode = "supplement",
        output_basename = "Info.plist",
        tags = ["manual"],
    )

    _strict_add_test(
        name = name + "_strict_add",
        target_under_test = ":_entitlements_merge_under_test",
    )

    _no_base_test(
        name = name + "_no_base",
        target_under_test = ":_entitlements_merge_no_base_under_test",
    )

    _supplement_test(
        name = name + "_supplement",
        target_under_test = ":_plist_supplement_under_test",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_strict_add",
            ":" + name + "_no_base",
            ":" + name + "_supplement",
        ],
    )
