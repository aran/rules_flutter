"""Builds an attribute for the machine running Bazel."""

def _host_transition_impl(_settings, _attr):
    return {"//command_line_option:platforms": [Label("@platforms//host")]}

host_transition = transition(
    implementation = _host_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)
