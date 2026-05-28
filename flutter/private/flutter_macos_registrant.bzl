"""macOS native plugin registrant rule.

Generates GeneratedPluginRegistrant.swift from FlutterInfo plugin metadata.
"""

load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:plugin_registrant.bzl", "generate_native_plugin_registrant")

def _flutter_macos_registrant_impl(ctx):
    plugins = ctx.attr.application[FlutterInfo].plugins
    registrant = generate_native_plugin_registrant(ctx, plugins, "macos")
    return [DefaultInfo(files = depset([registrant]))]

flutter_macos_registrant = rule(
    implementation = _flutter_macos_registrant_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterInfo with plugin metadata.",
            mandatory = True,
            providers = [FlutterInfo],
        ),
    },
    doc = "Generates the Swift native plugin registrant for macOS.",
)
