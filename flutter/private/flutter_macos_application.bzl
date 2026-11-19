"""Flutter macOS App.framework assembly and native lib staging.

Two rules:

1. `flutter_macos_app_framework` — assembles the AOT dylib (release) or kernel
   .dill (debug) into an App.framework with macOS directory structure.
   The framework is placed into the .app via additional_contents (NOT linked
   against the runner binary), matching how `flutter build macos` works.

2. `flutter_macos_native_libs` — stages the native libraries for bundling via
   additional_contents: each code asset in a framework of its own, each
   `native_deps` library under its basename.

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
load("//flutter/private:apple_xcode.bzl", "NATIVE_LIBRARY_SYMBOLS_ATTRS", "XCODE_TOOL_ATTRS", "XCODE_TOOL_FRAGMENTS", "XCODE_TOOL_TOOLCHAINS", "declare_dsym", "declare_library_dsym", "native_library_symbols", "process_native_library", "rewrite_install_names", "split_and_strip_aot_binary")
load("//flutter/private:assemble_directory.bzl", "ASSEMBLE_DIRECTORY_ATTRS", "assemble_directory")
load("//flutter/private:exec_groups.bzl", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_native_assets.bzl", "APPLE_FRAMEWORK_NAMES_FILE", "AppleFrameworkNamesInfo", "CODE_ASSETS_TOOL_ATTRS", "add_apple_framework_args", "app_macos_framework_names", "bundled_library_debug_info", "candidate_code_asset_libraries", "run_code_assets_tool", "shipped_dsyms")
load("//flutter/private:native_libraries.bzl", "native_library_files")
load("//flutter/private:program_analysis.bzl", "bundled_program_info")

visibility("//flutter/...")

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
    """Stages the native libraries that ship, for bundling via additional_contents.

    Includes both the legacy `native_libs` set (from `native_deps`-style
    FFI cc_library targets), which always ships, and the code assets
    (`dart_code_asset(link_mode = "dynamic_loading_bundle")` libraries) that
    ship: in a release build a package's link hook chooses among its code
    assets, so the staging action reads which from the program's assets
    file. rules_apple's `additional_contents = {target: "Frameworks"}`
    machinery code-signs them as part of the outer `macos_application`
    build — no bespoke codesign action needed here.

    Each code asset ships in a framework of its own,
    `Contents/Frameworks/<name>.framework/<name>` with its
    `Resources/Info.plist`, under the install name
    `@rpath/<name>.framework/<name>`, and the links between them are
    rewritten to those names, as flutter_tools 3.50's
    `copyNativeCodeAssetsMacOS` does; the native-assets manifest names that
    install name. The framework is flat, as App.framework is here: a tree
    artifact carries no symlinks for `Versions/`. A `native_deps` library, and
    a code asset whose library is one, ships as
    `Contents/Frameworks/<basename>`, where a bare-name `DynamicLibrary.open`
    finds it.

    Handing rules_apple the files themselves does not place them so. It
    places a plain file at its path relative to its owning package, so a
    library that is not at its package root (a vendored
    `third_party/foo/lib/libfoo.dylib`, a genrule writing into a subdirectory)
    lands in `Frameworks/lib/`, which codesign rejects as a malformed bundle
    and dyld never searches. So they are copied into one directory, and that
    directory is what this target provides: rules_apple expands a tree
    artifact's contents into the destination, as it does for App.framework's
    wrapper. The directory is named after this target, which keeps two apps in
    one package from declaring the same output. No two libraries can share a
    basename there: `flutter_application` checks every candidate.
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    if not native_library_files(app_info) and not candidate_code_asset_libraries(app_info.program_assets):
        return [DefaultInfo(files = depset())]

    # Each candidate is prepared as the app's own binary is (stripped, with a
    # dSYM) before the staging action, which runs anywhere, picks the ones
    # that ship: which do is known only once the link hooks have run. A code
    # asset in a framework is prepared in every build, for its install name.
    symbols = native_library_symbols(ctx)
    native_libs = native_library_files(app_info)
    frameworks = app_macos_framework_names(native_libs, app_info.program_assets)
    framework_names = ctx.actions.declare_file("%s_frameworks/%s" % (ctx.label.name, APPLE_FRAMEWORK_NAMES_FILE))
    ctx.actions.write(framework_names, json.encode_indent(frameworks, indent = "  ") + "\n")
    debug_info = bundled_library_debug_info(ctx.attr.application) if symbols.dsym else {}
    by_file_name = {library.basename: library for library in candidate_code_asset_libraries(app_info.program_assets)}
    install_name_changes = rewrite_install_names(
        ctx,
        ctx.label.name + "_install_names",
        [(by_file_name[file_name], "@rpath/%s.framework/%s" % (name, name)) for file_name, name in sorted(frameworks.items())],
    )
    copies = []
    copies_as = []
    always_dsyms = []
    candidate_dsyms = []
    prepared = {}
    for library in list(native_libs) + candidate_code_asset_libraries(app_info.program_assets):
        if library in prepared:
            continue
        name = frameworks.get(library.basename)
        if name:
            # Its dSYM is `<name>.framework.dSYM`, as `flutter build macos`
            # names it.
            copy = ctx.actions.declare_file("%s_frameworks/%s.framework/%s" % (ctx.label.name, name, name))
            dsym = declare_library_dsym(ctx, ctx.label.name + "_dsyms", name + ".framework", name) if symbols.dsym else None
            process_native_library(
                ctx,
                library = library,
                output = copy,
                symbols = symbols,
                mnemonic = "FlutterMacOSNativeAssetFramework",
                dsym = dsym,
                debug_info = debug_info.get(library),
                install_name = "@rpath/%s.framework/%s" % (name, name),
                install_name_changes = install_name_changes,
            )
            copies_as.append((library.basename, copy))
        elif symbols.dsym or symbols.strip:
            copy = ctx.actions.declare_file("%s_libraries/%s" % (ctx.label.name, library.basename))
            dsym = declare_library_dsym(ctx, ctx.label.name + "_dsyms", library.basename, library.basename) if symbols.dsym else None
            process_native_library(ctx, library = library, output = copy, symbols = symbols, mnemonic = "FlutterMacOSNativeLibrary", dsym = dsym, debug_info = debug_info.get(library))
            if library not in native_libs:
                copies.append(copy)
        else:
            continue
        prepared[library] = copy
        if dsym and library in native_libs:
            always_dsyms.append(dsym)
        elif dsym:
            candidate_dsyms.append((library.basename, dsym))
    native_libs = [prepared.get(library, library) for library in native_libs]

    staged = ctx.actions.declare_directory(ctx.label.name)
    code_assets = program_assets_action_args(ctx.actions, app_info.program_assets, data = False)
    args = ctx.actions.args()
    args.add("--os", "macos")
    args.add_all("--output", [staged], expand_directories = False)
    args.add_all(native_libs, before_each = "--library")
    args.add_all(copies, before_each = "--copy")
    for file_name, copy in copies_as:
        args.add("--copy-as", file_name)
        args.add(copy)
    add_apple_framework_args(args, frameworks)
    run_code_assets_tool(
        ctx,
        "place",
        [args, code_assets.args],
        depset(native_libs + copies + [copy for _, copy in copies_as], transitive = [code_assets.inputs]),
        [staged],
        mnemonic = "FlutterMacOSNativeLibs",
        progress_message = "Staging native libraries for %{label}",
    )
    providers = [
        DefaultInfo(files = depset([staged])),
        # For the dev tool, which finds a code asset's running image by its
        # framework (`flutter_native_hot_patch_aspect`).
        AppleFrameworkNamesInfo(file = framework_names),
    ]
    dsyms = shipped_dsyms(ctx, app_info.program_assets, always_dsyms, candidate_dsyms)
    if dsyms:
        # A framework import that imports no framework: all it carries is the
        # dSYMs of the libraries that ship, which rules_apple puts in the
        # app's `dsyms` output group.
        providers.append(framework_import_support.framework_import_info_with_dependencies(
            build_archs = [apple_support.target_arch_from_rule_ctx(ctx)],
            deps = [],
            dsyms = [dsyms],
        ))
    return providers

flutter_macos_native_libs = rule(
    implementation = _flutter_macos_native_libs_impl,
    attrs = dicts.add(
        XCODE_TOOL_ATTRS,
        NATIVE_LIBRARY_SYMBOLS_ATTRS,
        {
            "application": attr.label(
                doc = "A flutter_application target providing FlutterApplicationInfo.",
                mandatory = True,
                providers = [FlutterApplicationInfo],
            ),
        },
        CODE_ASSETS_TOOL_ATTRS,
    ),
    # The staging runs anywhere; stripping and dSYMs run Xcode's tools.
    exec_groups = PORTABLE_EXEC_GROUPS,
    fragments = XCODE_TOOL_FRAGMENTS + ["cpp"],
    toolchains = XCODE_TOOL_TOOLCHAINS,
    doc = """Stages the native libraries that ship for macOS bundling via additional_contents.

Each code asset ships in a framework of its own, `<name>.framework/<name>`,
as `flutter build macos` wraps it; a `native_deps` library ships under its
basename. Each is stripped of its local symbols and debugging map with
`--objc_enable_binary_stripping` in `-c opt`, and its dSYM
(`<name>.framework.dSYM`, or `<basename>.dSYM`) made with
`--apple_generate_dsym`, as rules_apple treats the app's own binary. The
dSYMs are in the `dsyms` output group of the app that bundles them.""",
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
