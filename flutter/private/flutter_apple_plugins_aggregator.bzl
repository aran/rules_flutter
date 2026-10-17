"""Aggregates Apple plugin libraries from a Flutter application's
transitive dep graph into a single CcInfo + SwiftInfo target so the
runner's swift_library or xtool runner compilation can depend on it.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")

def _flutter_apple_plugins_aggregator_impl(ctx):
    flutter_info = ctx.attr.application[FlutterApplicationInfo]
    target_platform = ctx.attr.platform

    cc_infos = []
    swift_infos = []
    for entry in flutter_info.apple_plugin_libraries.to_list():
        if entry.platform != target_platform:
            continue
        if entry.cc_info:
            cc_infos.append(entry.cc_info)
        if entry.swift_info:
            swift_infos.append(entry.swift_info)

    merged_cc_info = cc_common.merge_cc_infos(cc_infos = cc_infos)
    return [
        DefaultInfo(files = merged_cc_info.compilation_context.headers),
        merged_cc_info,
        SwiftInfo(swift_infos = swift_infos),
    ]

flutter_apple_plugins_aggregator = rule(
    implementation = _flutter_apple_plugins_aggregator_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target whose transitive deps carry " +
                  "Apple plugin libraries via FlutterApplicationInfo.apple_plugin_libraries.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "platform": attr.string(
            doc = "Target platform: 'macos' or 'ios'.",
            mandatory = True,
            values = ["macos", "ios"],
        ),
    },
    doc = "Merges transitive Apple plugin libraries from a flutter_application " +
          "into a single CcInfo + SwiftInfo target the runner can depend on.",
)
