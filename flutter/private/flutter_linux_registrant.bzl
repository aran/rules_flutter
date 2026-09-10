"""Linux native plugin registrant rule.

Generates generated_plugin_registrant.cc and .h from FlutterApplicationInfo plugin metadata.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:plugin_registrant.bzl", "generate_native_plugin_registrant", "generate_native_plugin_registrant_header")

def _flutter_linux_registrant_impl(ctx):
    plugins = ctx.attr.application[FlutterApplicationInfo].plugins
    registrant = generate_native_plugin_registrant(ctx, plugins, "linux")
    header = generate_native_plugin_registrant_header(ctx, "linux")
    files = [registrant]
    if header:
        files.append(header)
    return [DefaultInfo(files = depset(files))]

flutter_linux_registrant = rule(
    implementation = _flutter_linux_registrant_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo with plugin metadata.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    },
    doc = "Generates the C++ native plugin registrant (.cc and .h) for Linux.",
)
