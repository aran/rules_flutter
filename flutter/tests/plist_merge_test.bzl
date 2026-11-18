"""Analysis tests for flutter_plist_merge.

Asserts the rule registers exactly one strict-merger action carrying the
mode, the base and every addition, and exposes the merged plist under the
caller-chosen basename — the contract `additional_entitlements` and the iOS
Dart VM service supplement both rely on. Also covers the base-less case:
an iOS app with no Xcode capabilities ships no entitlements file, and the
additions must still produce one.

And flutter_signing_entitlements under a `select()` of the profile, as an app
passes one that names a profile only for a device: where the select gives one,
the profile is read; where it gives `None`, the bundle keeps its own
entitlements, with no `$(AppIdentifierPrefix)` that rules_apple could fill in
only from a profile.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_plist_merge.bzl", "flutter_entitlements_merge", "flutter_plist_merge", "flutter_signing_entitlements")

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
        "merge_plists.dart" in input_basenames,
        "the merger tool must be an action input",
    )
    asserts.true(
        env,
        "plist_binary.dart" in input_basenames,
        "the binary plist reader the merger imports must be an action input",
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

def _signing_actions(env):
    return [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterSigningEntitlements"]

def _default_files(env):
    return analysistest.target_under_test(env)[DefaultInfo].files.to_list()

def _signed_selected_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = _signing_actions(env)
    asserts.equals(env, 1, len(actions), "the branch with a profile must read it")
    argv = actions[0].argv
    asserts.true(
        env,
        argv[argv.index("--profile") + 1].endswith("signing/stand_in.mobileprovision"),
        "--profile must be the selected profile",
    )
    asserts.true(
        env,
        argv[argv.index("--entitlements") + 1].endswith("plist_merge/Base.entitlements"),
        "--entitlements must be the app's own",
    )
    asserts.equals(env, actions[0].outputs.to_list(), _default_files(env))
    return analysistest.end(env)

def _unsigned_selected_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _signing_actions(env), "the branch without a profile must not read one")
    files = _default_files(env)
    asserts.equals(env, 1, len(files))
    asserts.true(
        env,
        files[0].short_path.endswith("plist_merge/Base.entitlements"),
        "without a profile the output must be the app's own entitlements, got %s" % files[0].short_path,
    )
    return analysistest.end(env)

def _unsigned_none_selected_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _signing_actions(env), "the branch without a profile must not read one")
    files = _default_files(env)
    asserts.equals(env, 1, len(files), "the bundle rule takes exactly one file")
    writes = [a for a in analysistest.target_actions(env) if a.outputs.to_list() == files]
    asserts.equals(env, 1, len(writes))
    asserts.true(
        env,
        "<dict/>" in writes[0].content,
        "an app with no entitlements and no profile must get an empty dictionary",
    )
    return analysistest.end(env)

_SIGNED_CONFIG = {"//command_line_option:compilation_mode": "opt"}

_signed_selected_test = analysistest.make(_signed_selected_test_impl, config_settings = _SIGNED_CONFIG)
_unsigned_selected_test = analysistest.make(_unsigned_selected_test_impl)
_unsigned_none_selected_test = analysistest.make(_unsigned_none_selected_test_impl)

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

    # Stands for whatever tells a device build from a simulator one: the
    # profile is selected only under it.
    native.config_setting(
        name = "_signing_selects_profile",
        values = {"compilation_mode": "opt"},
    )
    selected_profile = select({
        ":_signing_selects_profile": "signing/stand_in.mobileprovision",
        "//conditions:default": None,
    })

    flutter_signing_entitlements(
        name = "_signing_selected_under_test",
        entitlements = "plist_merge/Base.entitlements",
        provisioning_profile = selected_profile,
        tags = ["manual"],
    )

    flutter_signing_entitlements(
        name = "_signing_none_selected_under_test",
        provisioning_profile = selected_profile,
        tags = ["manual"],
    )

    _signed_selected_test(
        name = name + "_signed_selected",
        target_under_test = ":_signing_selected_under_test",
    )

    _unsigned_selected_test(
        name = name + "_unsigned_selected",
        target_under_test = ":_signing_selected_under_test",
    )

    _unsigned_none_selected_test(
        name = name + "_unsigned_none_selected",
        target_under_test = ":_signing_none_selected_under_test",
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
            ":" + name + "_signed_selected",
            ":" + name + "_unsigned_selected",
            ":" + name + "_unsigned_none_selected",
        ],
    )
