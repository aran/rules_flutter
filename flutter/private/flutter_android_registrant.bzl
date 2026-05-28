"""Android native plugin registrant rule.

Generates `io/flutter/plugins/GeneratedPluginRegistrant.java` from
FlutterInfo plugin metadata. The Java file calls
`flutterEngine.getPlugins().add(new <FullyQualified.PluginClass>())`
for each plugin whose `flutter.plugin.platforms.android.pluginClass`
is set, mirroring `flutter pub get`'s registrant.

The `flutter_android_application.bzl` machinery (or the `flutter_android_app`
Tier-1 macro) compiles the registrant + every transitive plugin's
`kt_android_library` / `android_library` into the final `android_binary`.
"""

load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:plugin_registrant.bzl", "generate_native_plugin_registrant")

def _flutter_android_registrant_impl(ctx):
    plugins = ctx.attr.application[FlutterInfo].plugins
    registrant = generate_native_plugin_registrant(ctx, plugins, "android")
    return [DefaultInfo(files = depset([registrant]))]

flutter_android_registrant = rule(
    implementation = _flutter_android_registrant_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterInfo with plugin metadata.",
            mandatory = True,
            providers = [FlutterInfo],
        ),
    },
    doc = "Generates the Java native plugin registrant for Android (GeneratedPluginRegistrant.java).",
)
