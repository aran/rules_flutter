"""The plugin registrant of iOS add-to-app: `FlutterPluginRegistrant.xcframework`.

`flutter build ios-framework` of a module builds `FlutterPluginRegistrant`, a
static framework holding upstream's Objective-C `GeneratedPluginRegistrant`,
from a CocoaPods pod that depends on every plugin, and an app project copies
the `GeneratedPluginRegistrant.h` and `.m` into the output instead. A Bazel
`flutter_application` is both, so this rule makes the framework and gives the
two files as well: the host either links the framework or compiles the files.

The registrant imports each plugin's module, so it is compiled against the
plugin frameworks `flutter_ios_plugin_xcframeworks` built, slice by slice, and
its framework holds only the registrant (no plugin code).
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:apple_add_to_app.bzl", "BUNDLE_ATTRS", "SLICES", "SLICES_TRANSITION", "assemble_bundle", "xcframework_info_plist")
load("//flutter/private:apple_xcode.bzl", "XCODE_TOOL_ATTRS", "XCODE_TOOL_FRAGMENTS", "XCODE_TOOL_TOOLCHAINS", "run_xcode_tool")
load("//flutter/private:constants.bzl", "IOS_MINIMUM_OS_VERSION")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS")
load("//flutter/private:flutter_info.bzl", "plugins_on_platform")

visibility("//flutter/...")

_NAME = "FlutterPluginRegistrant"

# Upstream's `_objcPluginRegistryHeaderTemplate` (flutter_plugins.dart).
_HEADER = """//
//  Generated file. Do not edit.
//

// clang-format off

#ifndef GeneratedPluginRegistrant_h
#define GeneratedPluginRegistrant_h

#import <Flutter/Flutter.h>

NS_ASSUME_NONNULL_BEGIN

@interface GeneratedPluginRegistrant : NSObject
+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry;
@end

NS_ASSUME_NONNULL_END
#endif /* GeneratedPluginRegistrant_h */
"""

def registrant_implementation(plugins):
    """Upstream's `_objcPluginRegistryImplementationTemplate`, filled in.

    Args:
        plugins: Structs of `name` (the plugin's module) and `plugin_class`.

    Returns:
        The text of `GeneratedPluginRegistrant.m`.
    """
    text = """//
//  Generated file. Do not edit.
//

// clang-format off

#import "GeneratedPluginRegistrant.h"

"""
    for p in plugins:
        text += """#if __has_include(<{name}/{cls}.h>)
#import <{name}/{cls}.h>
#else
@import {name};
#endif

""".format(name = p.name, cls = p.plugin_class)
    text += """@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {
"""
    for p in plugins:
        text += '  [{cls} registerWithRegistrar:[registry registrarForPlugin:@"{cls}"]];\n'.format(cls = p.plugin_class)
    return text + """}

@end
"""

_MODULE_MAP = """framework module FlutterPluginRegistrant {
  umbrella header "FlutterPluginRegistrant-umbrella.h"
  export *
  module * { export * }
}
"""

_UMBRELLA = """#import <Foundation/Foundation.h>

#import "GeneratedPluginRegistrant.h"
"""

_INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>FlutterPluginRegistrant</string>
	<key>CFBundleIdentifier</key>
	<string>io.flutter.flutter.FlutterPluginRegistrant</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>FlutterPluginRegistrant</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>{minimum_os_version}</string>
</dict>
</plist>
"""

def _native_plugins(plugins):
    result = []
    for plugin in plugins_on_platform(plugins, "ios"):
        info = plugin.platforms.get("ios")
        if info and info.plugin_class and info.plugin_class != "none":
            result.append(struct(name = plugin.name, plugin_class = info.plugin_class))
    return result

def _engine_framework_dir(files, slice):
    """The directory holding `Flutter.framework` of the engine slice for `slice`."""
    for f in files:
        marker = "/Flutter.framework/"
        if marker not in f.path:
            continue
        parent = f.path[:f.path.index(marker)]
        if parent.endswith("-simulator") != (slice.variant == "simulator"):
            continue
        return parent
    fail("The iOS engine has no slice for %s" % slice.id)

def _registrant_xcframework_impl(ctx):
    plugins = _native_plugins(ctx.attr.application[FlutterApplicationInfo].plugins)
    header = ctx.actions.declare_file(ctx.label.name + "/GeneratedPluginRegistrant.h")
    source = ctx.actions.declare_file(ctx.label.name + "/GeneratedPluginRegistrant.m")
    ctx.actions.write(header, _HEADER)
    ctx.actions.write(source, registrant_implementation(plugins))

    plugin_xcframeworks = ctx.files.plugins
    modules = {p.name: True for p in plugins}
    found = {f.basename[:-len(".xcframework")]: f for f in plugin_xcframeworks if f.basename.endswith(".xcframework")}
    missing = [m for m in sorted(modules) if m not in found]
    if missing:
        fail("%s: `plugins` has no xcframework of %s, which the registrant registers" % (ctx.label, ", ".join(missing)))

    slices = SLICES["ios"]
    steps = []
    for slice in slices:
        toolchain = ctx.split_attr._cc_toolchain[slice.id][cc_common.CcToolchainInfo]
        engine_files = ctx.split_attr._engine[slice.id][DefaultInfo].files.to_list()
        feature_configuration = cc_common.configure_features(
            ctx = ctx,
            cc_toolchain = toolchain,
            requested_features = ctx.features,
            unsupported_features = ctx.disabled_features,
        )
        search = ["-F" + _engine_framework_dir(engine_files, slice)] + [
            "-F%s/%s" % (found[m].path, slice.id)
            for m in sorted(modules)
        ]
        _, outputs = cc_common.compile(
            name = "%s_slices/%s" % (ctx.label.name, slice.id),
            actions = ctx.actions,
            feature_configuration = feature_configuration,
            cc_toolchain = toolchain,
            srcs = [source],
            language = "objc",
            private_hdrs = [header],
            user_compile_flags = ["-fmodules", "-fobjc-arc"] + search,
            additional_inputs = engine_files + [found[m] for m in sorted(modules)],
        )
        objects = outputs.objects or outputs.pic_objects
        archive = ctx.actions.declare_file("%s_slices/%s/%s" % (ctx.label.name, slice.id, _NAME))
        run_xcode_tool(
            ctx,
            command = 'out="$1"; shift; xcrun libtool -static -no_warning_for_no_symbols -o "$out" "$@"',
            arguments = [ctx.actions.args().add(archive).add_all(objects)],
            inputs = objects,
            outputs = [archive],
            mnemonic = "FlutterPluginRegistrantArchive",
            execution_requirements = PATH_MAPPING,
            progress_message = "Archiving FlutterPluginRegistrant for %s" % slice.id,
        )
        root = "%s/%s.framework" % (slice.id, _NAME)
        steps.append(("file", "%s/%s" % (root, _NAME), archive))
        steps.append(("file", root + "/Headers/GeneratedPluginRegistrant.h", header))

    umbrella = ctx.actions.declare_file(ctx.label.name + "_slices/FlutterPluginRegistrant-umbrella.h")
    ctx.actions.write(umbrella, _UMBRELLA)
    module_map = ctx.actions.declare_file(ctx.label.name + "_slices/module.modulemap")
    ctx.actions.write(module_map, _MODULE_MAP)
    plist = ctx.actions.declare_file(ctx.label.name + "_slices/Info.plist")
    ctx.actions.write(plist, _INFO_PLIST.format(minimum_os_version = ctx.attr.minimum_os_version))
    for slice in slices:
        root = "%s/%s.framework" % (slice.id, _NAME)
        steps.extend([
            ("file", root + "/Headers/FlutterPluginRegistrant-umbrella.h", umbrella),
            ("file", root + "/Modules/module.modulemap", module_map),
            ("file", root + "/Info.plist", plist),
        ])
    xcframework_plist = ctx.actions.declare_file(ctx.label.name + "_slices/FlutterPluginRegistrant.xcframework.plist")
    xcframework_info_plist(ctx, xcframework_plist, _NAME, slices, static = True)
    xcframework = ctx.actions.declare_directory(ctx.label.name + "/FlutterPluginRegistrant.xcframework")
    assemble_bundle(
        ctx,
        xcframework,
        [("file", "Info.plist", xcframework_plist)] + steps,
        mnemonic = "FlutterPluginRegistrantXCFramework",
        progress_message = "Assembling FlutterPluginRegistrant.xcframework for %{label}",
    )
    return [DefaultInfo(files = depset([xcframework, header, source]))]

flutter_ios_registrant_xcframework = rule(
    implementation = _registrant_xcframework_impl,
    attrs = dicts.add(
        XCODE_TOOL_ATTRS,
        BUNDLE_ATTRS,
        {
            "application": attr.label(
                doc = "The `flutter_application` whose plugins the registrant registers.",
                mandatory = True,
                providers = [FlutterApplicationInfo],
            ),
            "plugins": attr.label(
                doc = "The application's `flutter_ios_plugin_xcframeworks`, whose modules the registrant imports.",
                mandatory = True,
                allow_files = True,
            ),
            "minimum_os_version": attr.string(
                doc = "The minimum iOS version of the framework.",
                default = IOS_MINIMUM_OS_VERSION,
            ),
            "_cc_toolchain": attr.label(
                default = "@rules_cc//cc:current_cc_toolchain",
                cfg = SLICES_TRANSITION["ios"],
            ),
            "_engine": attr.label(
                default = "@flutter_ios_engine//:Flutter_xcframework",
                allow_files = True,
                cfg = SLICES_TRANSITION["ios"],
            ),
        },
    ),
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = XCODE_TOOL_FRAGMENTS + ["cpp", "objc"],
    toolchains = XCODE_TOOL_TOOLCHAINS,
    doc = """`FlutterPluginRegistrant.xcframework`, a static framework of upstream's Objective-C
`GeneratedPluginRegistrant` (`+registerWithRegistry:`), as `flutter build ios-framework` builds it
for a module, and the `GeneratedPluginRegistrant.h` and `.m` it is built from, which
`flutter build ios-framework` gives an app project. Link the framework; do not embed it.""",
)

def swift_package_registrant(plugins, platform):
    """The `GeneratedPluginRegistrant.swift` of upstream's add-to-app Swift package.

    iOS: upstream's `_iosSwiftPluginRegistryTemplate`. macOS: its
    `_macosSwiftPluginRegistryTemplate`, public, as `flutter build
    swift-package` writes it for a package.

    Args:
        plugins: Structs of `name` (the plugin's module) and `plugin_class`.
        platform: `ios` or `macos`.

    Returns:
        The file's text.
    """
    imports = "".join(["import %s\n" % p.name for p in plugins])
    if platform == "ios":
        body = "".join([
            ('        if let {var} = registry.registrar(forPlugin: "{cls}") {{\n' +
             "            {cls}.register(with: {var})\n" +
             "        }}\n").format(var = p.plugin_class[0].lower() + p.plugin_class[1:], cls = p.plugin_class)
            for p in plugins
        ])
        return """//
//  Generated file. Do not edit.
//
import Flutter
import UIKit

{imports}
@objc public class GeneratedPluginRegistrant: NSObject {{
    @objc public static func register(with registry: FlutterPluginRegistry) {{
{body}    }}
}}
""".format(imports = imports, body = body)
    body = "".join([
        '  {cls}.register(with: registry.registrar(forPlugin: "{cls}"))\n'.format(cls = p.plugin_class)
        for p in plugins
    ])
    return """//
//  Generated file. Do not edit.
//

import FlutterMacOS
import Foundation

{imports}
public func RegisterGeneratedPlugins(registry: FlutterPluginRegistry) {{
{body}}}
""".format(imports = imports, body = body)

def _swift_package_registrant_impl(ctx):
    plugins = []
    for plugin in (plugins_on_platform(ctx.attr.application[FlutterApplicationInfo].plugins, ctx.attr.platform) if ctx.attr.register_plugins else []):
        info = plugin.platforms.get(ctx.attr.platform)
        if info and info.plugin_class and info.plugin_class != "none":
            plugins.append(struct(name = plugin.name, plugin_class = info.plugin_class))
    output = ctx.actions.declare_file(ctx.label.name + "/GeneratedPluginRegistrant.swift")
    ctx.actions.write(output, swift_package_registrant(plugins, ctx.attr.platform))
    return [DefaultInfo(files = depset([output]))]

flutter_apple_swift_package_registrant = rule(
    implementation = _swift_package_registrant_impl,
    attrs = {
        "application": attr.label(
            doc = "The `flutter_application` whose plugins the registrant registers.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "platform": attr.string(mandatory = True, values = ["ios", "macos"]),
        "register_plugins": attr.bool(
            doc = "Whether it registers the plugins; False when the host ships them itself.",
            default = True,
        ),
    },
    doc = "The Swift `GeneratedPluginRegistrant` of the add-to-app Swift package, as `flutter build swift-package` writes it.",
)
