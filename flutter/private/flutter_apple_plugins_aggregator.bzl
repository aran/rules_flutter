"""Aggregates Apple plugin libraries from a Flutter application's
transitive dep graph into a single CcInfo + SwiftInfo target so the
runner's swift_library can depend on it.

flutter_application transitively merges per-plugin
`apple_plugin_libraries` entries into FlutterApplicationInfo. Each entry holds the
CcInfo and SwiftInfo from a flutter_apple_plugin_library spoke. This
rule walks that depset, filters to the target platform, and merges:
  * CcInfo via cc_common.merge_cc_infos — gives the runner the static
    libs to link against and the include paths the registrant Swift
    needs for ObjC interop.
  * SwiftInfo via rules_swift's `SwiftInfo(swift_infos = [...])`
    constructor — gives the runner each plugin's Swift module so the
    generated registrant's `import <PluginModule>` resolves.

A plugin whose `Package.swift` decides its defines from the app is built
here, for this app: the Dart graph names it by a marker, and this rule links
the library the marker names from `@flutter_pub_apple_app_settings//:libraries`,
which it depends on through `swiftpm_app_transition` with the app's
`info_plist` and `swift_package_environment` (`swiftpm_app_settings.bzl`).

The runner_lib_gen swift_library has the aggregator target in its `deps`.
"""

# rules_apple has no public way to merge `AppleResourceInfo`s (5.4.0), so this
# is its internal `resources.merge_providers`: a rules_apple upgrade can move or
# change it. Check it on every upgrade, with `apple_resource_aspect` in
# flutter_plugin.bzl.
# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal:resources.bzl", "resources")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:swiftpm_app_settings.bzl", "FlutterSwiftPMAppLibrariesInfo", "SWIFTPM_APP_LIBRARIES", "app_library_entry", "check_swift_package_environment", "swiftpm_app_transition")
load("//flutter/private:unbuilt_native_code.bzl", "fail_on_unbuilt_native_code")

visibility("//flutter/...")

def _flutter_apple_plugins_aggregator_impl(ctx):
    flutter_info = ctx.attr.application[FlutterApplicationInfo]
    target_platform = ctx.attr.platform

    entries = [
        entry
        for entry in flutter_info.apple_plugin_libraries.to_list()
        if entry.platform == target_platform
    ]

    check_swift_package_environment(ctx)

    # The libraries whose Package.swift decides its defines from the app,
    # built for this one.
    if [e for e in entries if getattr(e, "app_library", None)]:
        built = ctx.attr._app_settings_libraries[0][FlutterSwiftPMAppLibrariesInfo]
        entries = [app_library_entry(e, built) for e in entries]

    # A plugin whose library for this platform its podspec builds by other
    # means (cargokit, a script phase, `ffiPlugin`) would link without it.
    fail_on_unbuilt_native_code(entries)

    cc_infos = []
    swift_infos = []
    resource_infos = []
    for entry in entries:
        if entry.cc_info:
            cc_infos.append(entry.cc_info)
        if entry.swift_info:
            swift_infos.append(entry.swift_info)
        if getattr(entry, "resource_info", None):
            resource_infos.append(entry.resource_info)

    # Always emit CcInfo + SwiftInfo, even when there are no plugins.
    # The runner's swift_library depends on this aggregator
    # unconditionally and rejects deps that lack one of those providers
    # ('//:__app_apple_plugins does not have mandatory providers').
    # The zero-plugin case (apps with no pub Apple plugins, e.g.
    # e2e/macos_example) still needs an aggregator that satisfies the
    # contract. cc_common.merge_cc_infos and SwiftInfo handle empty lists
    # cleanly and produce no-op merged providers.
    providers = [
        DefaultInfo(),
        cc_common.merge_cc_infos(cc_infos = cc_infos),
        SwiftInfo(swift_infos = swift_infos),
    ]

    # The plugins' resources, which the app's bundling takes from this
    # dependency of its runner as it takes any library's.
    if resource_infos:
        providers.append(resources.merge_providers(providers = resource_infos, default_owner = str(ctx.label)))
    return providers

flutter_apple_plugins_aggregator = rule(
    implementation = _flutter_apple_plugins_aggregator_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target whose transitive deps carry " +
                  "Apple plugin libraries via FlutterApplicationInfo.apple_plugin_libraries.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "info_plist": attr.label(
            allow_single_file = [".plist"],
            doc = "The app's Info.plist, as the app is built from it. A plugin " +
                  "whose Package.swift decides its defines from the app reads " +
                  "it, as under Xcode. Unset, such a manifest sees an app " +
                  "whose Info.plist is empty.",
        ),
        "swift_package_environment": attr.string_dict(
            doc = "The environment of the evaluation of each plugin's " +
                  "Package.swift that decides its defines from the app, as " +
                  "the shell's is under `flutter build`. Set what a plugin's " +
                  "README says to export: `{\"AUDIO_SESSION_MICROPHONE\": \"1\"}`.",
        ),
        "_app_settings_libraries": attr.label(
            default = SWIFTPM_APP_LIBRARIES,
            cfg = swiftpm_app_transition,
            providers = [FlutterSwiftPMAppLibrariesInfo],
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
