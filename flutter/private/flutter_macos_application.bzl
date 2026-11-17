"""Flutter macOS App.framework assembly and native lib staging.

Two rules:

1. `flutter_macos_app_framework` — assembles the AOT dylib (release) or kernel
   .dill (debug) into an App.framework with macOS directory structure.
   The framework is placed into the .app via additional_contents (NOT linked
   against the runner binary), matching how `flutter build macos` works.

2. `flutter_macos_native_libs` — stages native .dylib files, flat under their
   basenames, for bundling via additional_contents.

These are exported as `flutter_macos_app_framework_gen` and `flutter_macos_native_libs_gen`
from flutter/macos.bzl.
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")

# framework_import_support is rules_apple-internal, but it is the only way to
# construct AppleFrameworkImportInfo (its init is banned), which is how a dSYM
# reaches the bundle's `dsyms` output group. See `flutter_ios_application.bzl`.
# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal:framework_import_support.bzl", "framework_import_support")
load("@rules_dart//dart:utils.bzl", "program_assets_action_args")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterSdkRecordInfo")
load("//flutter/private:apple_xcode.bzl", "XCODE_TOOL_ATTRS", "XCODE_TOOL_FRAGMENTS", "XCODE_TOOL_TOOLCHAINS", "declare_dsym", "split_and_strip_aot_binary")
load("//flutter/private:assemble_directory.bzl", "ASSEMBLE_DIRECTORY_ATTRS", "assemble_directory")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_TOOL_ATTRS", "candidate_code_asset_libraries", "run_code_assets_tool")
load("//flutter/private:program_analysis.bzl", "bundled_program_info")

# -- flutter_macos_app_framework (App.framework assembly) -------------------------

_APP_FRAMEWORK_INFO_PLIST = """\
<?xml version="1.0" encoding="UTF-8"?>
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

def _flutter_macos_app_framework_impl(ctx):
    """Assembles App.framework as a flat macOS framework (tree artifact).

    The layout has no `Versions/` directory and no symlinks:
        App.framework/
            App                          (AOT binary, release only)
            Resources/
                Info.plist
                flutter_assets/          (asset bundle)

    In debug mode the kernel (`kernel_blob.bin`) and VM snapshots sit inside
    `flutter_assets/`.

    The framework is NOT linked against the runner binary. Instead it is placed
    into the .app bundle via additional_contents, matching how `flutter build
    macos` works. The Flutter engine discovers and loads it at runtime via
    NSBundle.
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    tools = portable_tools(ctx)
    is_debug = app_info.is_debug
    flutter_assets = app_info.flutter_assets

    # Use a wrapper directory so that additional_contents preserves the
    # App.framework/ level. Tree artifacts placed via additional_contents have
    # their contents expanded into the destination, so the internal structure
    # must include the App.framework/ directory name.
    #
    # Named after this target, at the package root. Not in a subdirectory:
    # rules_apple puts the contents under the directory holding the wrapper,
    # relative to its package, so `<name>/app_framework` would bundle as
    # `Frameworks/<name>/App.framework`. And not a fixed name: two apps in one
    # package built from different applications would both declare it, which
    # fails analysis with conflicting actions.
    wrapper_dir = ctx.actions.declare_directory(ctx.label.name)

    dsym_files = []

    # What App.framework holds, in the order it is placed: the AOT binary
    # (release only), the assets, the Info.plist, and in debug mode the kernel
    # and VM snapshots inside the assets.
    steps = []

    if not is_debug:
        if not app_info.aot_output:
            fail("flutter_macos_app_framework requires an AOT build (not debug mode) or a kernel_dill in debug mode.")

        # Extract the dSYM and strip the binary, as `flutter build macos` does.
        # Not under the wrapper directory, which is all the bundle takes.
        binary = ctx.actions.declare_file("%s_binary/App" % ctx.label.name)
        dsym = declare_dsym(ctx, ctx.label.name + "_dsym")
        dsym_files = dsym.files
        split_and_strip_aot_binary(
            ctx,
            dylib = app_info.aot_output,
            object = app_info.aot_object,
            binary = binary,
            dsym = dsym,
            strip = app_info.strip_aot,
        )
        steps.append(("file", "App.framework/App", binary))

    steps.append(("tree", "App.framework/Resources/flutter_assets", flutter_assets))

    # The engine must hold the app's CPU, and an app of a custom SDK keeps the
    # record of the checked pieces it was built from.
    sdk_record = ctx.attr._sdk_record[FlutterSdkRecordInfo]
    arch = apple_support.target_arch_from_rule_ctx(ctx)
    if sdk_record.engine_cpus and arch not in sdk_record.engine_cpus:
        fail(("%s: the engine %s contains %s, and this build is for %s. " +
              "Build the engine for %s, or build for %s.") % (
            ctx.label,
            sdk_record.engine_label,
            ", ".join(sdk_record.engine_cpus),
            arch,
            arch,
            ", ".join(sdk_record.engine_cpus),
        ))
    if sdk_record.record:
        steps.append(("file", "App.framework/Resources/flutter_assets/flutter_sdk.json", sdk_record.record))

    info_plist = ctx.actions.declare_file(ctx.label.name + "_framework_inputs/Info.plist")
    ctx.actions.write(info_plist, _APP_FRAMEWORK_INFO_PLIST)
    steps.append(("file", "App.framework/Resources/Info.plist", info_plist))

    # In debug mode, place the kernel dill and VM snapshots into flutter_assets/.
    # The debug engine looks for kernel_blob.bin there. The vm_snapshot_data and
    # isolate_snapshot_data are needed for the kernel service isolate (hot reload).
    if is_debug and app_info.kernel_dill:
        steps.extend([
            ("file", "App.framework/Resources/flutter_assets/kernel_blob.bin", app_info.kernel_dill),
            ("file", "App.framework/Resources/flutter_assets/vm_snapshot_data", tools.vm_isolate_snapshot),
            ("file", "App.framework/Resources/flutter_assets/isolate_snapshot_data", tools.isolate_snapshot),
        ])

    assemble_directory(
        ctx,
        tools,
        wrapper_dir,
        steps,
        mnemonic = "FlutterMacOSFramework",
        progress_message = "Assembling App.framework for %s" % ctx.label,
    )

    providers = [
        DefaultInfo(files = depset([wrapper_dir])),
        OutputGroupInfo(dsym = depset(dsym_files)),
    ]
    if dsym_files:
        # A framework import that imports no framework: all it carries is the
        # dSYM, which rules_apple puts in the app's `dsyms` output group.
        providers.append(framework_import_support.framework_import_info_with_dependencies(
            build_archs = [apple_support.target_arch_from_rule_ctx(ctx)],
            deps = [],
            dsyms = dsym_files,
        ))

    # For the app to pass on to analysis (`flutter_apple_app`).
    return providers + bundled_program_info(ctx.attr.application)

flutter_macos_app_framework = rule(
    implementation = _flutter_macos_app_framework_impl,
    attrs = dicts.add(
        XCODE_TOOL_ATTRS,
        ASSEMBLE_DIRECTORY_ATTRS,
        {
            "application": attr.label(
                doc = "A flutter_application target providing FlutterApplicationInfo.",
                mandatory = True,
                providers = [FlutterApplicationInfo],
            ),
            "_sdk_record": attr.label(
                default = "//flutter/private:sdk_record",
                providers = [FlutterSdkRecordInfo],
            ),
        },
    ),
    # Copies and a plist: the same bytes on any host. Signing is rules_apple's.
    # Only the release binary's dSYM and strip run Xcode's tools.
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = XCODE_TOOL_FRAGMENTS,
    toolchains = XCODE_TOOL_TOOLCHAINS,
    doc = """Assembles the Flutter AOT dylib and assets into App.framework for macOS.

The release binary is stripped, as `flutter build macos` strips it (not with
`--no-strip` in the application's `extra_gen_snapshot_options`); its dSYM
is made either way. It is in the `dsym` output group, and in the `dsyms` output
group of the app that bundles this.""",
)

# -- flutter_macos_native_libs (dylib staging for additional_contents) -------

def _flutter_macos_native_libs_impl(ctx):
    """Stages native .dylib files flat, for bundling via additional_contents.

    Includes both the legacy `native_libs` set (from `native_deps`-style
    FFI cc_library targets), which always ships, and the code assets
    (`dart_code_asset(link_mode = "dynamic_loading_bundle")` libraries) that
    ship: in a release build a package's link hook chooses among its code
    assets, so the staging action reads which from the program's assets
    file. rules_apple's `additional_contents = {target: "Frameworks"}`
    machinery code-signs the dylibs as part of the outer `macos_application`
    build — no bespoke codesign action needed here.

    Every library ships as `Contents/Frameworks/<basename>`, because that is
    where the loader finds it: a bare-name `DynamicLibrary.open` resolves
    there, and so does a Native Assets manifest entry. Handing rules_apple the
    files themselves does not achieve that. It places a plain file at its path
    relative to its owning package, so a library that is not at its package
    root (a vendored `third_party/foo/lib/libfoo.dylib`, a genrule writing into
    a subdirectory) lands in `Frameworks/lib/`, which codesign rejects as a
    malformed bundle and dyld never searches.

    So the libraries are copied into one directory under their basenames, and
    that directory is what this target provides: rules_apple expands a tree
    artifact's contents into the destination, as it does for App.framework's
    wrapper. The directory is named after this target, which keeps two apps in
    one package from declaring the same output. No two libraries can share a
    basename there: `flutter_application` checks every candidate.
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    if not app_info.native_libs and not candidate_code_asset_libraries(app_info.program_assets):
        return [DefaultInfo(files = depset())]

    staged = ctx.actions.declare_directory(ctx.label.name)
    code_assets = program_assets_action_args(ctx.actions, app_info.program_assets, data = False)
    args = ctx.actions.args()
    args.add("--os", "macos")
    args.add_all("--output", [staged], expand_directories = False)
    args.add_all(app_info.native_libs, before_each = "--library")
    run_code_assets_tool(
        ctx,
        "place",
        [args, code_assets.args],
        depset(app_info.native_libs, transitive = [code_assets.inputs]),
        [staged],
        mnemonic = "FlutterMacOSNativeLibs",
        progress_message = "Staging native libraries for %{label}",
    )
    return [DefaultInfo(files = depset([staged]))]

flutter_macos_native_libs = rule(
    implementation = _flutter_macos_native_libs_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    } | CODE_ASSETS_TOOL_ATTRS,
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Stages the native .dylib files that ship under their basenames for macOS bundling via additional_contents.",
)

# -- flutter_macos_privacy_manifests (xcprivacy bundling) ---------------------

def _flutter_macos_privacy_manifests_impl(ctx):
    """Exposes plugin `PrivacyInfo.xcprivacy` files for bundling.

    Apple requires every framework to ship a privacy manifest since
    iOS 17.4 / macOS 14.4; the App Store submission validator walks the
    bundle and aggregates them. The macos_application rule consumes this
    as an `additional_contents` entry pointing at `Resources` so each
    plugin's manifest lands at
    `<App>.app/Contents/Resources/<pkg>/PrivacyInfo.xcprivacy`.

    Files are namespaced by the originating plugin's pub package via the
    on-disk path that `flutter_pub_package` lays them out at —
    `<pkg>/PrivacyInfo.xcprivacy` — so distinct plugins' manifests don't
    collide. rules_apple's `additional_contents` machinery places files
    at their package-relative path under the destination directory, so
    the plugin's auto-generated BUILD file stages the xcprivacy file in a
    package-named subdirectory before exposing it via `apple_privacy_files`.
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    return [DefaultInfo(files = app_info.apple_privacy_manifests)]

flutter_macos_privacy_manifests = rule(
    implementation = _flutter_macos_privacy_manifests_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    },
    doc = "Extracts plugin `PrivacyInfo.xcprivacy` files for macOS bundling via additional_contents.",
)
