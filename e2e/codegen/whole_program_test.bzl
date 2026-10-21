"""Runs a test built with `--@rules_dart//dart:modular_kernel=false`, whatever the command line asked for."""

def _whole_program_transition_impl(_settings, _attr):
    return {"@rules_dart//dart:modular_kernel": False}

_whole_program_transition = transition(
    implementation = _whole_program_transition_impl,
    inputs = [],
    outputs = ["@rules_dart//dart:modular_kernel"],
)

def _whole_program_test_impl(ctx):
    test = ctx.attr.test[0]
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = test[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    return [
        DefaultInfo(
            executable = executable,
            runfiles = ctx.runfiles(files = [executable]).merge(test[DefaultInfo].default_runfiles),
        ),
        test[RunEnvironmentInfo],
    ]

whole_program_test = rule(
    implementation = _whole_program_test_impl,
    test = True,
    doc = "Runs `test` compiled whole-program, as `--@rules_dart//dart:modular_kernel=false` compiles it.",
    attrs = {
        "test": attr.label(
            cfg = _whole_program_transition,
            executable = True,
            mandatory = True,
            doc = "The `flutter_test` to run.",
        ),
    },
)
