"""Analysis tests for `flutter_gen_l10n` action inputs, argv, and validation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_gen_l10n")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")

def _find_l10n_action(env):
    found = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterGenL10n"
    ]
    asserts.equals(
        env,
        1,
        len(found),
        "expected exactly one FlutterGenL10n action, got %s" % [a.mnemonic for a in found],
    )
    return found[0] if found else None

def _declared_arbs_argv_test_impl(ctx):
    """`FlutterGenL10n` passes each declared `.arb` via `--arb-file=` and stages only declared inputs."""
    env = analysistest.begin(ctx)
    action = _find_l10n_action(env)
    input_paths = [f.path for f in action.inputs.to_list()]
    arb_inputs = [p for p in input_paths if p.endswith(".arb")]

    asserts.equals(
        env,
        [
            "flutter/tests/gen_l10n_fixture/lib/l10n/app_en.arb",
            "flutter/tests/gen_l10n_fixture/lib/l10n/app_es.arb",
        ],
        sorted(arb_inputs),
    )

    arb_flags = [arg for arg in action.argv if arg.startswith("--arb-file=")]
    asserts.equals(
        env,
        [
            "--arb-file=flutter/tests/gen_l10n_fixture/lib/l10n/app_en.arb",
            "--arb-file=flutter/tests/gen_l10n_fixture/lib/l10n/app_es.arb",
        ],
        arb_flags,
    )

    for undeclared in ["app_es_419.arb", "app_en_US.arb", "app_de.arb"]:
        asserts.false(
            env,
            any([undeclared in arg for arg in action.argv]),
            "undeclared %s must not appear in FlutterGenL10n argv: %s" % (undeclared, action.argv),
        )
        asserts.false(
            env,
            any([undeclared in p for p in input_paths]),
            "undeclared %s must not appear in FlutterGenL10n inputs: %s" % (undeclared, arb_inputs),
        )

    out_names = sorted([f.basename for f in action.outputs.to_list()])
    asserts.equals(
        env,
        [
            "subset_localizations.dart",
            "subset_localizations_en.dart",
            "subset_localizations_es.dart",
        ],
        out_names,
    )
    return analysistest.end(env)

def _mixed_source_and_generated_arbs_test_impl(ctx):
    """`FlutterGenL10n` accepts source and generated `.arb` files in the same package directory."""
    env = analysistest.begin(ctx)
    action = _find_l10n_action(env)
    arb_flags = [arg for arg in action.argv if arg.startswith("--arb-file=")]
    asserts.equals(env, 2, len(arb_flags))
    asserts.equals(
        env,
        "--arb-file=flutter/tests/gen_l10n_fixture/lib/l10n/app_en.arb",
        arb_flags[0],
    )
    asserts.true(
        env,
        arb_flags[1].startswith("--arb-file=") and
        arb_flags[1].endswith("/flutter/tests/gen_l10n_fixture/lib/l10n/app_fr.arb"),
        "expected generated app_fr.arb in --arb-file=, got %r" % arb_flags[1],
    )
    asserts.false(
        env,
        any(["app_en_GB.arb" in arg for arg in action.argv]),
        "undeclared generated app_en_GB.arb must not appear in argv: %s" % action.argv,
    )
    return analysistest.end(env)

def _different_dirs_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "every arb must sit in one directory")
    return analysistest.end(env)

def _duplicate_basename_fails_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, 'multiple arb files named "app_en.arb"')
    return analysistest.end(env)

_declared_arbs_argv_test = analysistest.make(_declared_arbs_argv_test_impl)
_mixed_source_and_generated_arbs_test = analysistest.make(_mixed_source_and_generated_arbs_test_impl)
_different_dirs_fails_test = analysistest.make(
    _different_dirs_fails_test_impl,
    expect_failure = True,
)
_duplicate_basename_fails_test = analysistest.make(
    _duplicate_basename_fails_test_impl,
    expect_failure = True,
)

def gen_l10n_test_suite(name):
    """Test suite for flutter_gen_l10n analysis and action wiring.

    Args:
      name: Name of the test suite.
    """
    write_file(
        name = "_other_dir_es_arb",
        out = "other_l10n/app_es.arb",
        content = ['{"@@locale": "es"}'],
        tags = ["manual"],
    )

    flutter_gen_l10n(
        name = "_mismatched_dirs_l10n",
        arbs = [
            "//flutter/tests/gen_l10n_fixture:lib/l10n/app_en.arb",
            ":_other_dir_es_arb",
        ],
        tags = ["manual"],
    )

    write_file(
        name = "_duplicate_en_arb",
        out = "dup_l10n/app_en.arb",
        content = ['{"@@locale": "en"}'],
        tags = ["manual"],
    )

    flutter_gen_l10n(
        name = "_duplicate_basename_l10n",
        arbs = [
            "//flutter/tests/gen_l10n_fixture:lib/l10n/app_en.arb",
            ":_duplicate_en_arb",
        ],
        tags = ["manual"],
    )

    _declared_arbs_argv_test(
        name = name + "_declared_arbs_argv",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = "//flutter/tests/gen_l10n_fixture:l10n_subset",
    )

    _mixed_source_and_generated_arbs_test(
        name = name + "_mixed_source_and_generated_arbs",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = "//flutter/tests/gen_l10n_fixture:l10n_mixed_generated",
    )

    _different_dirs_fails_test(
        name = name + "_different_dirs_fails",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = ":_mismatched_dirs_l10n",
    )

    _duplicate_basename_fails_test(
        name = name + "_duplicate_basename_fails",
        target_compatible_with = HOST_COMPATIBLE,
        target_under_test = ":_duplicate_basename_l10n",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_declared_arbs_argv",
            ":" + name + "_mixed_source_and_generated_arbs",
            ":" + name + "_different_dirs_fails",
            ":" + name + "_duplicate_basename_fails",
        ],
    )
