"""Android native plugin registrant rule.

Generates `io/flutter/plugins/GeneratedPluginRegistrant.java` from
FlutterApplicationInfo plugin metadata. The Java file calls
`flutterEngine.getPlugins().add(new <FullyQualified.PluginClass>())`
for each plugin whose `flutter.plugin.platforms.android.pluginClass`
is set, mirroring `flutter pub get`'s registrant.

The `flutter_android_application.bzl` machinery (or the `flutter_android_app`
Tier-1 macro) compiles the registrant + every transitive plugin's
`kt_android_library` / `android_library` into the final `android_binary`.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "ANDROID_ABIS")
load("//flutter/private:flutter_android_application.bzl", "android_platform_transition")
load("//flutter/private:plugin_registrant.bzl", "generate_native_plugin_registrant")

def _flutter_android_registrant_impl(ctx):
    plugins = ctx.attr.application[FlutterApplicationInfo].plugins
    registrant = generate_native_plugin_registrant(ctx, plugins, "android")
    return [DefaultInfo(files = depset([registrant]))]

flutter_android_registrant = rule(
    implementation = _flutter_android_registrant_impl,
    cfg = android_platform_transition,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo with plugin metadata.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "android_abi": attr.string(
            doc = """Android ABI to build for ("arm64-v8a" or "x86_64").

Transitions `application` to the matching Android platform and configuration so
it shares the exact same configuration as `flutter_android_bundle` instead of
re-analyzing `application` in the outer/host configuration.""",
            default = "arm64-v8a",
            values = ANDROID_ABIS.keys(),
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Generates the Java native plugin registrant for Android (GeneratedPluginRegistrant.java).",
)
