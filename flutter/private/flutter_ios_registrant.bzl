"""iOS native plugin registrant rule.

Generates GeneratedPluginRegistrant.swift from FlutterApplicationInfo plugin metadata.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:plugin_registrant.bzl", "generate_ios_objc_registrant", "generate_native_plugin_registrant")

def _flutter_ios_registrant_impl(ctx):
    plugins = ctx.attr.application[FlutterApplicationInfo].plugins
    if ctx.attr.language == "objc":
        header, impl = generate_ios_objc_registrant(
            ctx,
            plugins,
            exclude_plugins = ctx.attr.exclude_plugins,
        )
        return [
            DefaultInfo(files = depset([header, impl])),
            OutputGroupInfo(
                hdrs = depset([header]),
                srcs = depset([impl]),
            ),
        ]
    registrant = generate_native_plugin_registrant(
        ctx,
        plugins,
        "ios",
        exclude_plugins = ctx.attr.exclude_plugins,
    )
    return [
        DefaultInfo(files = depset([registrant])),
        OutputGroupInfo(
            swift = depset([registrant]),
        ),
    ]

flutter_ios_registrant = rule(
    implementation = _flutter_ios_registrant_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo with plugin metadata.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "exclude_plugins": attr.string_list(
            doc = """Plugin module names to leave out of the registrant.

No import and no registration call is emitted for a named plugin, in
either language. A name that is not a native iOS plugin of the
application is an error, listing the valid names.""",
        ),
        "language": attr.string(
            doc = """Registrant language: "swift" emits GeneratedPluginRegistrant.swift; "objc" emits GeneratedPluginRegistrant.h and GeneratedPluginRegistrant.m matching the flutter tool's own template, exposed through the `hdrs` and `srcs` output groups for an objc_library to consume.""",
            default = "swift",
            values = ["swift", "objc"],
        ),
    },
    doc = "Generates the native plugin registrant for iOS.",
)
