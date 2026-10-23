"""Aggregates Apple plugin libraries from a Flutter application's
transitive dep graph into a single CcInfo + SwiftInfo target so the
runner's swift_library or xtool runner compilation can depend on it.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterApplicationInfo")

def _append_unique(acc, values):
    """Appends each value not already present, preserving first-seen order."""
    for value in values:
        if value not in acc:
            acc.append(value)

def _collect_apple_plugin_inputs(entries, target_platform):
    """Collects CcInfo/SwiftInfo/files/SDK-link inputs for one platform."""
    cc_infos = []
    swift_infos = []
    files = []
    sdk_frameworks = []
    sdk_dylibs = []
    for entry in entries:
        if entry.platform != target_platform:
            continue
        if entry.cc_info:
            cc_infos.append(entry.cc_info)
        if entry.swift_info:
            swift_infos.append(entry.swift_info)
        if hasattr(entry, "files") and entry.files:
            files.append(entry.files)
        if hasattr(entry, "sdk_frameworks") and entry.sdk_frameworks:
            _append_unique(sdk_frameworks, entry.sdk_frameworks)
        if hasattr(entry, "sdk_dylibs") and entry.sdk_dylibs:
            _append_unique(sdk_dylibs, entry.sdk_dylibs)
    return struct(
        cc_infos = cc_infos,
        swift_infos = swift_infos,
        files = files,
        sdk_frameworks = sdk_frameworks,
        sdk_dylibs = sdk_dylibs,
    )

def _flutter_apple_plugins_aggregator_impl(ctx):
    flutter_info = ctx.attr.application[FlutterApplicationInfo]
    target_platform = ctx.attr.platform

    collected = _collect_apple_plugin_inputs(flutter_info.apple_plugin_libraries.to_list(), target_platform)

    return [
        DefaultInfo(files = depset(transitive = collected.files)),
        cc_common.merge_cc_infos(cc_infos = collected.cc_infos),
        SwiftInfo(swift_infos = collected.swift_infos),
        FlutterApplePluginInfo(
            module_name = "",
            platform = target_platform,
            swift_srcs = depset(),
            objc_srcs = depset(),
            headers = depset(),
            modulemap = None,
            sdk_frameworks = tuple(collected.sdk_frameworks),
            sdk_dylibs = tuple(collected.sdk_dylibs),
        ),
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
