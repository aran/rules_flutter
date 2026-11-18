"""The App and engine xcframeworks of Apple add-to-app.

`flutter_ios_app_xcframework` and `flutter_macos_app_xcframework` build an
application's `App.xcframework`; `flutter_ios_engine_xcframework` and
`flutter_macos_engine_xcframework` copy Flutter's own `Flutter.xcframework`
and `FlutterMacOS.xcframework` of the build mode, keeping Flutter's signature,
as `flutter build ios-framework` and `macos-framework` do. Each builds the mode
of its configuration (see `apple_add_to_app.bzl` for the slices).
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterSdkRecordInfo")
load("//flutter/private:apple_add_to_app.bzl", "BUNDLE_ATTRS", "SLICES", "SLICES_TRANSITION", "assemble_bundle", "dsym_steps", "framework_root", "relative_to", "xcframework_info_plist")
load("//flutter/private:apple_xcode.bzl", "XCODE_TOOL_ATTRS", "XCODE_TOOL_FRAGMENTS", "XCODE_TOOL_TOOLCHAINS", "declare_dsym", "run_xcode_tool", "split_and_strip_aot_binary")
load("//flutter/private:assemble_directory.bzl", "ASSEMBLE_DIRECTORY_ATTRS")
load("//flutter/private:constants.bzl", "IOS_MINIMUM_OS_VERSION", "MACOS_MINIMUM_OS_VERSION")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_ios_application.bzl", "ios_app_framework")

visibility("//flutter/...")

_MINIMUM_OS_VERSION = {"ios": IOS_MINIMUM_OS_VERSION, "macos": MACOS_MINIMUM_OS_VERSION}

_MACOS_APP_FRAMEWORK_INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>App</string>
	<key>CFBundleIdentifier</key>
	<string>io.flutter.flutter.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>App</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
</dict>
</plist>
"""

def _ios_app_slice(ctx, slice, app_info, sdk_record):
    framework = ios_app_framework(
        ctx,
        app_info = app_info,
        is_device = slice.device,
        arch = slice.arch,
        directory = "%s_slices/%s" % (ctx.label.name, slice.id),
        minimum_os_version = ctx.attr.minimum_os_version,
        sdk_record = sdk_record,
    )
    root = framework_root(slice, "App")
    return struct(
        steps = [
            ("file", root + "/App", framework.binary),
            ("file", root + "/Info.plist", framework.plist),
            ("tree", root + "/flutter_assets", framework.assets),
        ] + dsym_steps(slice, "App.framework", framework.dsym_files),
        has_dsym = bool(framework.dsym_files),
    )

def _macos_app_slice(ctx, slice, app_info, sdk_record):
    """A versioned App.framework, as `flutter build macos-framework` makes it."""
    tools = portable_tools(ctx)
    directory = "%s_slices/%s" % (ctx.label.name, slice.id)
    binary = ctx.actions.declare_file(directory + "/App")
    dsym_files = []
    if app_info.aot_output:
        dsym = declare_dsym(ctx, directory)
        dsym_files = dsym.files
        split_and_strip_aot_binary(
            ctx,
            dylib = app_info.aot_output,
            object = app_info.aot_object,
            binary = binary,
            dsym = dsym,
            strip = app_info.strip_aot,
        )
    else:
        # A stub: the engine runs the kernel in `flutter_assets/`, and an Xcode
        # host links the framework, so it needs a binary. Built as
        # `flutter build macos-framework` builds its debug one.
        run_xcode_tool(
            ctx,
            command = 'echo "static const int Moo = 88;" | xcrun -sdk macosx clang -x c - -arch "$3" -mmacosx-version-min="$4" -dynamiclib -Xlinker -rpath -Xlinker @executable_path/Frameworks -Xlinker -rpath -Xlinker @loader_path/Frameworks -fapplication-extension -install_name "$2" -o "$1"',
            arguments = [ctx.actions.args().add_all([binary, "@rpath/App.framework/App", slice.arch, ctx.attr.minimum_os_version])],
            outputs = [binary],
            mnemonic = "FlutterMacOSStubDylib",
            execution_requirements = PATH_MAPPING,
            progress_message = "Creating stub App.framework binary for debug mode",
        )
    plist = ctx.actions.declare_file(directory + "/Info.plist")
    ctx.actions.write(plist, _MACOS_APP_FRAMEWORK_INFO_PLIST)
    root = framework_root(slice, "App")
    assets = root + "/Resources/flutter_assets"
    steps = [
        ("file", root + "/App", binary),
        ("file", root + "/Resources/Info.plist", plist),
        ("tree", assets, app_info.flutter_assets),
    ]
    if sdk_record.record:
        steps.append(("file", assets + "/flutter_sdk.json", sdk_record.record))
    if not app_info.aot_output:
        steps.extend([
            ("file", assets + "/kernel_blob.bin", app_info.kernel_dill),
            ("file", assets + "/vm_snapshot_data", tools.vm_isolate_snapshot),
            ("file", assets + "/isolate_snapshot_data", tools.isolate_snapshot),
        ])
    return struct(
        steps = steps + dsym_steps(slice, "App.framework", dsym_files),
        has_dsym = bool(dsym_files),
    )

def _app_xcframework_impl(ctx):
    platform = ctx.attr._platform
    slices = SLICES[platform]
    steps = []
    dsyms = []
    for slice in slices:
        app_info = ctx.split_attr.application[slice.id][FlutterApplicationInfo]
        sdk_record = ctx.split_attr._sdk_record[slice.id][FlutterSdkRecordInfo]
        built = (_ios_app_slice if platform == "ios" else _macos_app_slice)(ctx, slice, app_info, sdk_record)
        steps.extend(built.steps)
        if built.has_dsym:
            dsyms.append(slice.id)
    plist = ctx.actions.declare_file(ctx.label.name + "_slices/App.xcframework.plist")
    xcframework_info_plist(ctx, plist, "App", slices, dsyms = dsyms)
    xcframework = ctx.actions.declare_directory(ctx.label.name + "/App.xcframework")
    assemble_bundle(
        ctx,
        xcframework,
        [("file", "Info.plist", plist)] + steps,
        mnemonic = "FlutterAppXCFramework",
        progress_message = "Assembling App.xcframework for %{label}",
    )
    return [DefaultInfo(files = depset([xcframework]))]

def _app_xcframework_rule(platform):
    return rule(
        implementation = _app_xcframework_impl,
        attrs = dicts.add(
            XCODE_TOOL_ATTRS,
            ASSEMBLE_DIRECTORY_ATTRS,
            BUNDLE_ATTRS,
            {
                "application": attr.label(
                    doc = "The `flutter_application` whose Dart program and assets the framework holds.",
                    mandatory = True,
                    providers = [FlutterApplicationInfo],
                    cfg = SLICES_TRANSITION[platform],
                ),
                "minimum_os_version": attr.string(
                    doc = "The minimum %s version of the binaries." % ("iOS" if platform == "ios" else "macOS"),
                    default = _MINIMUM_OS_VERSION[platform],
                ),
                "_platform": attr.string(default = platform),
                "_sdk_record": attr.label(
                    default = "//flutter/private:sdk_record",
                    providers = [FlutterSdkRecordInfo],
                    cfg = SLICES_TRANSITION[platform],
                ),
            },
        ),
        exec_groups = PORTABLE_EXEC_GROUPS,
        fragments = XCODE_TOOL_FRAGMENTS,
        toolchains = XCODE_TOOL_TOOLCHAINS,
        doc = (
            "`App.xcframework`: the application's Dart program and assets, as `flutter build %s-framework` builds it, " +
            "in the build mode of the configuration.%s Profile and release slices carry `dSYMs/App.framework.dSYM`."
        ) % (
            platform,
            " The simulator slice is a debug build in every mode, as upstream's." if platform == "ios" else " The framework is versioned (`Versions/A`); a debug one has a stub binary, as upstream's.",
        ),
    )

flutter_ios_app_xcframework = _app_xcframework_rule("ios")
flutter_macos_app_xcframework = _app_xcframework_rule("macos")

_ENGINE = {
    "ios": struct(
        label = "@flutter_ios_engine//:Flutter_xcframework",
        name = "Flutter",
    ),
    "macos": struct(
        label = "@flutter_macos_engine//:xcframework",
        name = "FlutterMacOS",
    ),
}

def _engine_xcframework_impl(ctx):
    engine = _ENGINE[ctx.attr._platform]
    xcframework_name = engine.name + ".xcframework"
    framework_name = engine.name + ".framework"
    steps = []
    for f in ctx.files._engine:
        path = relative_to(f, xcframework_name)
        parts = path.split("/")

        # A versioned framework is its version directory alone in Bazel's
        # outputs: the files read through its links are left out.
        if framework_name in parts:
            inner = parts[parts.index(framework_name) + 1:]
            if inner and (inner[0] != "Versions" or (len(inner) > 1 and inner[1] == "Current")) and ctx.attr._platform == "macos":
                continue
        steps.append(("file", path, f))
    xcframework = ctx.actions.declare_directory(ctx.label.name + "/" + xcframework_name)
    assemble_bundle(
        ctx,
        xcframework,
        steps,
        mnemonic = "FlutterEngineXCFramework",
        progress_message = "Copying %s for %%{label}" % xcframework_name,
    )
    return [DefaultInfo(files = depset([xcframework]))]

def _engine_xcframework_rule(platform):
    return rule(
        implementation = _engine_xcframework_impl,
        attrs = dicts.add(BUNDLE_ATTRS, {
            "_engine": attr.label(default = _ENGINE[platform].label, allow_files = True),
            "_platform": attr.string(default = platform),
        }),
        exec_groups = PORTABLE_EXEC_GROUPS,
        doc = (
            "A copy of Flutter's `%s.xcframework` of the build mode, with Flutter's signature, " +
            "as `flutter build %s-framework` copies it."
        ) % (_ENGINE[platform].name, platform),
    )

flutter_ios_engine_xcframework = _engine_xcframework_rule("ios")
flutter_macos_engine_xcframework = _engine_xcframework_rule("macos")
