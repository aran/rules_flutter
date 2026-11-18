"""A `flutter_library` with no files and no `package` is no package.

It wraps its dependencies, so it is no second package of the name its directory
gives it: a wrapper of pub's `collection` in a directory called `collection`
used to make a program that depends on it fail with "supplied by different
packages".
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")

def _contributes_no_package_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartInfo]
    asserts.equals(env, [], [p.package_name for p in info.packages], "the wrapper is no package")
    asserts.equals(
        env,
        ["collection"],
        [p.package_name for p in info.transitive_packages.to_list()],
        "it passes its dependency's package on",
    )
    return analysistest.end(env)

contributes_no_package_test = analysistest.make(_contributes_no_package_impl)

def _program_has_one_package_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[DartAnalyzableInfo].dart_info
    roots = [p.package_root for p in info.transitive_packages.to_list() if p.package_name == "collection"]
    asserts.equals(env, ["flutter/tests/sourceless_library_fixture/pubdep"], roots, "the program has the one `collection`")
    return analysistest.end(env)

program_has_one_package_test = analysistest.make(_program_has_one_package_impl)

def _carries_data_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, [], [p.package_name for p in target[DartInfo].packages], "no package")
    carried = [f.basename for f in target[DefaultInfo].default_runfiles.files.to_list()]
    asserts.equals(env, ["data.txt"], carried, "its `data` is in its runfiles")
    return analysistest.end(env)

carries_data_test = analysistest.make(_carries_data_impl)

def _reports_deps_coverage_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[InstrumentedFilesInfo]
    asserts.equals(
        env,
        ["collection.dart"],
        [f.basename for f in info.instrumented_files.to_list()],
        "coverage reaches its dependency's sources and no others",
    )
    return analysistest.end(env)

reports_deps_coverage_test = analysistest.make(
    _reports_deps_coverage_impl,
    config_settings = {"//command_line_option:collect_code_coverage": True},
)
