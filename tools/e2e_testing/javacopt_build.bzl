"""Builds targets with extra javac options, for a `build_test`.

A project may build with `--javacopt=-Xlint:all --javacopt=-Werror`, and then
every Java library of an app has to compile without warnings, the libraries
rules_flutter generates included. A `build_test` of a `javacopt_build` checks
that whatever flags the test is run with.
"""

_JAVACOPT = "//command_line_option:javacopt"

def _transition_impl(settings, attr):
    return {_JAVACOPT: settings[_JAVACOPT] + attr.javacopts}

_transition = transition(
    implementation = _transition_impl,
    inputs = [_JAVACOPT],
    outputs = [_JAVACOPT],
)

def _impl(ctx):
    return [DefaultInfo(
        files = depset(transitive = [t[DefaultInfo].files for t in ctx.attr.targets]),
    )]

javacopt_build = rule(
    implementation = _impl,
    doc = "Forwards the files of `targets`, built with `--javacopt` for each of `javacopts` added.",
    attrs = {
        "javacopts": attr.string_list(
            mandatory = True,
            doc = "The javac options to add, such as `-Xlint:all` and `-Werror`.",
        ),
        "targets": attr.label_list(
            cfg = _transition,
            mandatory = True,
            doc = "The targets to build with them, such as a `flutter_android_app`.",
        ),
    },
)
