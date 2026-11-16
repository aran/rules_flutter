"""`stray_output_test`: a `flutter_test` that must fail while a process it started holds its output."""

load("@rules_dart//dart:utils.bzl", "runfiles_path")

def _stray_output_test_impl(ctx):
    wrapped = ctx.attr.test
    workspace = ctx.workspace_name

    config = ctx.actions.declare_file(ctx.label.name + ".stray_output.json")
    ctx.actions.write(config, json.encode({
        "executable": runfiles_path(wrapped[DefaultInfo].files_to_run.executable, workspace),
        "env": wrapped[RunEnvironmentInfo].environment,
        "outputContains": ctx.attr.output_contains,
    }))

    target = ctx.executable._checker
    executable = ctx.actions.declare_file(ctx.label.name + ("." + target.extension if target.extension else ""))
    ctx.actions.symlink(output = executable, target_file = target, is_executable = True)
    runfiles = ctx.runfiles(files = [config]).merge(
        ctx.attr._checker[DefaultInfo].default_runfiles,
    ).merge(wrapped[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(
            environment = {"STRAY_OUTPUT_CONFIG": runfiles_path(config, workspace)},
            inherited_environment = wrapped[RunEnvironmentInfo].inherited_environment,
        ),
    ]

stray_output_test = rule(
    implementation = _stray_output_test_impl,
    attrs = {
        "test": attr.label(
            doc = "The test to run: `manual`, since it is meant to fail. It writes the process id of what it leaves running to `$STRAY_PID_FILE`.",
            mandatory = True,
            providers = [RunEnvironmentInfo],
        ),
        "output_contains": attr.string_list(
            doc = "Text its output must contain.",
        ),
        "_checker": attr.label(
            default = Label("//:stray_output_checker"),
            executable = True,
            cfg = "target",
        ),
    },
    test = True,
    doc = """Runs `test` with its own environment and passes when it fails, ending while
the process it left holding its output is still running, and its output says
what `output_contains` says.""",
)
