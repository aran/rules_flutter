"""Builds an attribute for the host platform (`@platforms//host`), the machine running Bazel."""

visibility(["//flutter/...", "//tools/dev_tool/..."])

def _host_platform_transition_impl(_settings, _attr):
    return {"//command_line_option:platforms": [Label("@platforms//host")]}

host_platform_transition = transition(
    implementation = _host_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)
