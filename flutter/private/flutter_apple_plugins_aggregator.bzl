"""Aggregates Apple plugin libraries from a Flutter application's
transitive dep graph into a single CcInfo + SwiftInfo target so the
runner's swift_library can depend on it.

flutter_application transitively merges per-plugin
`apple_plugin_libraries` entries into FlutterInfo. Each entry holds the
CcInfo and SwiftInfo from a flutter_apple_plugin_library spoke. This
rule walks that depset, filters to the target platform, and merges:
  * CcInfo via cc_common.merge_cc_infos — gives the runner the static
    libs to link against and the include paths the registrant Swift
    needs for ObjC interop.
  * SwiftInfo via rules_swift's `SwiftInfo(swift_infos = [...])`
    constructor — gives the runner each plugin's Swift module so the
    generated registrant's `import <PluginModule>` resolves.

The runner_lib_gen swift_library has the aggregator target in its `deps`.
"""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterInfo")

def _flutter_apple_plugins_aggregator_impl(ctx):
    flutter_info = ctx.attr.application[FlutterInfo]
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

    # Always emit CcInfo + SwiftInfo, even when there are no plugins.
    # The runner's swift_library depends on this aggregator
    # unconditionally and rejects deps that lack one of those providers
    # ('//:__app_apple_plugins does not have mandatory providers').
    # The zero-plugin case (apps with no pub Apple plugins, e.g.
    # e2e/macos_example) still needs an aggregator that satisfies the
    # contract. cc_common.merge_cc_infos and SwiftInfo handle empty lists
    # cleanly and produce no-op merged providers.
    return [
        DefaultInfo(),
        cc_common.merge_cc_infos(cc_infos = cc_infos),
        SwiftInfo(swift_infos = swift_infos),
    ]

flutter_apple_plugins_aggregator = rule(
    implementation = _flutter_apple_plugins_aggregator_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target whose transitive deps carry " +
                  "Apple plugin libraries via FlutterInfo.apple_plugin_libraries.",
            mandatory = True,
            providers = [FlutterInfo],
        ),
        "platform": attr.string(
            doc = "Target platform: 'macos' or 'ios'.",
            mandatory = True,
            values = ["macos", "ios"],
        ),
    },
    doc = "Merges transitive Apple plugin libraries from a flutter_application " +
          "into a single CcInfo + SwiftInfo target the runner's swift_library " +
          "can depend on.",
)
