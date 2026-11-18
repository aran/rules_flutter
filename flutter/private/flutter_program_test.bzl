"""The run half of a Flutter test: runs a compiled test program under flutter_tester.

`flutter_program_test` takes any target that provides `FlutterTestProgramInfo`
(`flutter_test_program` is one) and runs it as a Bazel test. It speaks the same
`package:test_api` `RemoteListener` protocol `flutter test` does and reports
through the Bazel test protocol: the XML report, JUnit, `@Tags` selection
(`include_tags`, `exclude_tags`, `DART_TEST_TAGS`), golden comparison,
`--update-goldens` under `bazel run`, sharding and coverage.

The rule is bound to the name `flutter_test` here, and not to
`flutter_program_test`, so that `kind("^flutter_test rule$", ...)` finds every test
`flutter_test` and `flutter_program_test` declare, as `ios_unit_test` is found
for the tests rules_apple's macro builds from two rules.
"""

load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo")
load("@rules_dart//dart:utils.bzl", "COVERAGE_ATTRS", "runfiles_path", "test_coverage")
load("//flutter:providers.bzl", "FlutterTestProgramInfo")
load("//flutter/private:test_tags.bzl", "tag_selectors")

visibility("//flutter/...")

# The environment variables the runner starts from. A target's own `env` never
# sets one of these: it is the runner's start-up contract, and a target that
# quietly replaced one would fail far from the cause.
def program_environment(info, workspace_name):
    """The runner's start-up variables for a program: runfiles-relative paths.

    Args:
      info: The `FlutterTestProgramInfo` to run.
      workspace_name: The main repository's name, which runfiles paths start with.

    Returns:
      dict: environment variable to value.
    """
    env = {
        "FLUTTER_TEST_TESTER": runfiles_path(info.tester, workspace_name),
        "FLUTTER_TEST_ICU": runfiles_path(info.icu_data, workspace_name),
        "FLUTTER_TEST_DILL": runfiles_path(info.kernel, workspace_name),
        "FLUTTER_TEST_ASSETS": runfiles_path(info.assets, workspace_name),
        "FLUTTER_TEST_PATH": info.display_path,
        "FLUTTER_TEST_IMPELLER": "1" if info.enable_impeller else "",
    }
    if info.kernel_list:
        # flutter_tester takes one kernel file: the runner joins the list.
        env["FLUTTER_TEST_KERNEL_LIST"] = "1"
    if info.native_files:
        env["FLUTTER_TEST_NATIVE_FILES"] = "\n".join(info.native_files)
    return env

def add_user_env(ctx, kind, env):
    """Merges the target's `env` into `env`, never over the rule's own keys.

    Those are the runner's start-up contract, and a target that quietly
    replaced one would fail far from the cause.

    Args:
      ctx: The rule context.
      kind: The rule's name, for messages.
      env: The dict to add to.
    """
    for key, value in ctx.attr.env.items():
        if key in env:
            fail((
                "{kind} {name}: env key {key} is set by the rule itself " +
                "and cannot be overridden."
            ).format(kind = kind, name = ctx.label.name, key = key))
        env[key] = value

def _flutter_test_impl(ctx):
    info = ctx.attr.program[FlutterTestProgramInfo]

    # Symlink the prebuilt runner as the test executable.
    tool = ctx.attr._tool
    ext = ".exe" if info.target_os == "windows" else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )

    env = program_environment(info, ctx.workspace_name) | {
        # The test's source in the runfiles, which the runner reads for the
        # library annotations (`@Tags`) the way `flutter test` does.
        # FLUTTER_TEST_PATH stays the display path.
        "FLUTTER_TEST_SOURCE": runfiles_path(info.source, ctx.workspace_name),
    }
    for key, attr_name in [
        ("FLUTTER_TEST_INCLUDE_TAGS", "include_tags"),
        ("FLUTTER_TEST_EXCLUDE_TAGS", "exclude_tags"),
    ]:
        selectors = tag_selectors(ctx, attr_name, "flutter_test")
        if selectors:
            env[key] = "\n".join(selectors)

    # Under `bazel coverage`, what turns the VM's coverage of the program into
    # the tracefile Bazel merges: rules_dart's converter, where each package's
    # `lib/` is, and the sources whose `coverage:ignore` comments it honours.
    # This rule has no sources of its own: the program it runs reports them.
    coverage = test_coverage(ctx, info.packages, [], [ctx.attr.program])
    if coverage:
        env["FLUTTER_TEST_COVERAGE_CONVERTER"] = coverage.converter
        env["FLUTTER_TEST_COVERAGE_SOURCES"] = coverage.sources
    add_user_env(ctx, "flutter_test", env)

    runfiles = info.runfiles.merge(tool[DefaultInfo].default_runfiles).merge(
        ctx.runfiles(files = ctx.files.data),
    )
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)
    if coverage:
        runfiles = runfiles.merge(coverage.runfiles)

    providers = [
        DefaultInfo(executable = executable, runfiles = runfiles),
        testing.TestEnvironment(env),
        # The program's sources and `deps` are what a coverage run reports.
        coverage_common.instrumented_files_info(ctx, dependency_attributes = ["program"]),
    ]

    # The program's checks and analysis closure, which belong to the test the
    # user names as much as to the program behind it.
    for provider in [OutputGroupInfo, DartAnalyzableInfo]:
        if provider in ctx.attr.program:
            providers.append(ctx.attr.program[provider])
    return providers

_TRACK_CREATION_LOCATIONS = str(Label("@rules_dart//dart:track_creation_locations"))

def _track_widget_creation_impl(_settings, _attr):
    return {_TRACK_CREATION_LOCATIONS: True}

# Widgets record where they were created, as under `flutter test`, whose
# `--track-widget-creation` is on by default and applies to any JIT build,
# which a test always is. rules_dart's flag of the same transform reaches every
# kernel module of `deps` and the entry compile alike, which a tracked class's
# constructors need to agree on, so the test sets it for itself and all it
# depends on rather than passing the front-end flag to its own compile only.
# The run rule has it too, so that its `data` and runner are built in the one
# configuration the program is.
track_widget_creation = transition(
    implementation = _track_widget_creation_impl,
    inputs = [],
    outputs = [_TRACK_CREATION_LOCATIONS],
)

flutter_test = rule(
    implementation = _flutter_test_impl,
    cfg = track_widget_creation,
    attrs = {
        "program": attr.label(
            doc = "The compiled test program to run: a target that provides " +
                  "`FlutterTestProgramInfo`, such as a `flutter_test_program`.",
            providers = [FlutterTestProgramInfo],
            mandatory = True,
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Runtime data deps, beside the program's own. Available in " +
                  "test runfiles. Use for fixtures, goldens, and FFI dylibs. " +
                  "Golden PNGs must be listed here (or on the program) or " +
                  "the comparator cannot see them.",
        ),
        "env": attr.string_dict(
            doc = "Extra environment variables for the test process. Values " +
                  "are literal — no Make-variable or $(location) expansion. " +
                  "The FLUTTER_TEST_* keys the rule sets itself cannot be " +
                  "overridden.",
        ),
        "include_tags": attr.string_list(
            doc = "Tag selectors a case must match to run, as `flutter test " +
                  "--tags` takes them and as `dart_test.yaml`'s " +
                  "`include_tags` does: each entry is one boolean selector " +
                  "(`golden`, `a && !b`), and a case must match every entry. " +
                  "Tags come from `@Tags` on the test library and `tags:` on " +
                  "`group` and `test`. These are `package:test` tags, not " +
                  "Bazel's `tags`. A target none of whose cases match fails. " +
                  "`--test_env=DART_TEST_TAGS=...` narrows further for one " +
                  "run.",
        ),
        "exclude_tags": attr.string_list(
            doc = "Tag selectors that drop a case, as `flutter test " +
                  "--exclude-tags` takes them and as `dart_test.yaml`'s " +
                  "`exclude_tags` does: a case matching any entry does not " +
                  "run. `package:test` tags, not Bazel's `tags`. A target " +
                  "none of whose cases remain fails. " +
                  "`--test_env=DART_TEST_EXCLUDE_TAGS=...` drops more for " +
                  "one run.",
        ),
        # Built for the target, where the test runs.
        "_tool": attr.label(
            default = Label("//flutter/private/tools:flutter_test_runner"),
            cfg = "target",
        ),
    } | COVERAGE_ATTRS,
    test = True,
    doc = """Runs a compiled Flutter test program under flutter_tester. This is \
the rule behind `flutter_test` and `flutter_program_test`, which is how \
`kind("^flutter_test rule$", ...)` finds every Flutter test.

The runner, flutter_tester and the program are built for the target platform, \
and like any Bazel test the run is placed on an execution platform matching \
it. Pin it elsewhere with `exec_group_compatible_with = {"test": [...]}`; \
`exec_compatible_with` constrains only the rule's default group.""",
)

def flutter_program_test(name, program, **kwargs):
    """Runs a compiled Flutter test program under flutter_tester.

    Tier 2 of the test rules: runs the program of any target that provides
    `FlutterTestProgramInfo` (`flutter_test_program` does, and so can a rule
    that compiles tests its own way) as a Bazel test, with everything
    `flutter_test` gives a test it compiles: the `package:test` result
    protocol, `@Tags` selection (`include_tags`, `exclude_tags`,
    `DART_TEST_TAGS`), JUnit output, golden comparison and `--update-goldens`
    under `bazel run`, Native Assets, sharding (`shard_count`) and coverage.
    The target's kind is `flutter_test`.

    Args:
        name: Target name.
        program: The program to run: a target providing `FlutterTestProgramInfo`.
        **kwargs: Forwarded to the rule: `data`, `env`, `include_tags`,
            `exclude_tags`, and the common test attributes (`size`, `timeout`,
            `shard_count`, `tags`, `args`, ...).
    """
    flutter_test(name = name, program = program, **kwargs)
