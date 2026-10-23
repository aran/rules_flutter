"""Transition wrapper that builds and executes a `flutter_test` under `-c dbg`."""

def _dbg_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "dbg"}

_dbg_transition = transition(
    implementation = _dbg_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _dbg_flutter_test_impl(ctx):
    dep = ctx.attr.test[0]
    default_info = dep[DefaultInfo]
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    out = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = out,
        target_file = default_info.files_to_run.executable,
        is_executable = True,
    )
    return [
        DefaultInfo(
            executable = out,
            runfiles = default_info.default_runfiles,
        ),
        dep[RunEnvironmentInfo],
    ]

dbg_flutter_test = rule(
    implementation = _dbg_flutter_test_impl,
    attrs = {
        "test": attr.label(
            mandatory = True,
            cfg = _dbg_transition,
        ),
        "_windows_constraint": attr.label(
            default = Label("@platforms//os:windows"),
        ),
        "_allowlist_function_transition": attr.label(
            default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
        ),
    },
    test = True,
    doc = "Transitions a `flutter_test` target to `-c dbg` and runs it under `flutter_tester`.",
)
