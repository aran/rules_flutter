"""Runs a test built with `--@rules_dart//dart:extra_dart_defines` set for it.

The flag adds a define to every Dart compile in a build. A test of what it
does needs it set, and setting it in a workspace's `.bazelrc` would change
every other app's compile there too. An `extra_dart_defines_test` sets it for
the one test it runs, as the command line would, and runs that test as itself.
"""

load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo")

_FLAG = str(Label("@rules_dart//dart:extra_dart_defines"))

def _transition_impl(settings, attr):
    return {_FLAG: settings[_FLAG] + attr.defines}

_transition = transition(
    implementation = _transition_impl,
    inputs = [_FLAG],
    outputs = [_FLAG],
)

def _impl(ctx):
    test = ctx.attr.test[0]
    target = test[DefaultInfo].files_to_run.executable

    # The test's own executable under this rule's name, with the extension
    # the host needs (`.exe` on Windows), run with the test's runfiles and
    # environment.
    extension = "." + target.extension if target.extension else ""
    executable = ctx.actions.declare_file(ctx.label.name + extension)
    ctx.actions.symlink(output = executable, target_file = target, is_executable = True)
    providers = [
        DefaultInfo(
            executable = executable,
            runfiles = ctx.runfiles().merge(test[DefaultInfo].default_runfiles),
        ),
        coverage_common.instrumented_files_info(ctx, dependency_attributes = ["test"]),
    ]

    # Its environment, and its checks and analysis closure, so that the
    # `dart_analyze` aspect checks its sources through this target.
    for provider in [RunEnvironmentInfo, OutputGroupInfo, DartAnalyzableInfo]:
        if provider in test:
            providers.append(test[provider])
    return providers

extra_dart_defines_test = rule(
    implementation = _impl,
    doc = "Runs `test` built with `--@rules_dart//dart:extra_dart_defines` " +
          "for each of `defines` added to the flag's value. Tag `test` " +
          "`manual`, so that `//...` runs it only through this rule.",
    attrs = {
        "defines": attr.string_list(
            mandatory = True,
            doc = "The defines to add, each `KEY=VALUE`, as the flag takes them one per occurrence.",
        ),
        "test": attr.label(
            cfg = _transition,
            executable = True,
            mandatory = True,
            doc = "The test to run, such as a `flutter_test`.",
        ),
    },
    test = True,
)
