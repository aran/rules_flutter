"""Flutter macOS App.framework assembly and native lib staging.

Two rules:

1. `flutter_macos_framework` — assembles the AOT dylib (release) or kernel
   .dill (debug) into an App.framework with macOS directory structure.
   The framework is placed into the .app via additional_contents (NOT linked
   against the runner binary), matching how `flutter build macos` works.

2. `flutter_macos_native_libs` — stages native .dylib files, flat under their
   basenames, for bundling via additional_contents.

These are exported as `flutter_macos_framework_gen` and `flutter_macos_native_libs_gen`
from flutter/macos.bzl.
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")

# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal:framework_import_support.bzl", "framework_import_support")

# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal:providers.bzl", "new_applebundleinfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterDarwinFrameworkInfo", "resolve_exec_dart_vm")
load("//flutter/private:constants.bzl", "MACOS_MINIMUM_OS_VERSION")

# -- flutter_macos_framework (App.framework assembly) -------------------------

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

def _prepare_macos_framework_binary(ctx, dart_exe, dart_vm_files, app_info, is_debug, stub_arch, minimum_os_version):
    """Prepares the App binary: a stub dylib in debug, the retagged AOT dylib otherwise."""
    prepared_binary = ctx.actions.declare_file("%s_macho/App" % ctx.label.name)
    if is_debug:
        ctx.actions.run(
            executable = dart_exe,
            arguments = [
                ctx.executable._macho_edit.path,
                "stub",
                "--output",
                prepared_binary.path,
                "--arch",
                stub_arch,
                "--platform",
                "macos",
                "--min-os",
                minimum_os_version,
                "--sdk-version",
                minimum_os_version,
                "--install-name",
                "@rpath/App.framework/Versions/A/App",
            ],
            inputs = depset(
                direct = [ctx.executable._macho_edit],
                transitive = [dart_vm_files],
            ),
            outputs = [prepared_binary],
            mnemonic = "FlutterMacOSStubDylib",
            progress_message = "Creating stub macOS App.framework binary for debug mode",
        )
        return prepared_binary
    if not app_info.aot_output:
        fail("flutter_macos_framework requires an AOT build (not debug mode) or a kernel_dill in debug mode.")
    patch_args = [
        ctx.executable._macho_edit.path,
        "patch",
        "--input",
        app_info.aot_output.path,
        "--output",
        prepared_binary.path,
        "--platform",
        "macos",
        "--min-os",
        minimum_os_version,
        "--sdk-version",
        minimum_os_version,
        "--install-name",
        "@rpath/App.framework/Versions/A/App",
    ]
    for allowed in ctx.attr.allow_non_macho:
        patch_args.extend(["--allow-non-macho", allowed])
    ctx.actions.run(
        executable = dart_exe,
        arguments = patch_args,
        inputs = depset(
            direct = [app_info.aot_output, ctx.executable._macho_edit],
            transitive = [dart_vm_files],
        ),
        outputs = [prepared_binary],
        mnemonic = "FlutterMacOSRetagDylib",
        progress_message = "Retagging App dylib for macos (min %s)" % minimum_os_version,
    )
    return prepared_binary

def _macos_framework_assemble_inputs(ctx, flutter_sdk_info, app_info, is_debug, flutter_assets, prepared_binary, prepared_plist, stage_dir, framework_zip):
    """Builds the assemble action's inputs and args, including debug kernel inputs.

    In debug mode, places the kernel dill and VM snapshots into
    flutter_assets/. The debug engine looks for kernel_blob.bin there. The
    vm_snapshot_data and isolate_snapshot_data are needed for the kernel
    service isolate (hot reload).
    """
    inputs = [flutter_assets, prepared_binary, prepared_plist, ctx.executable._macho_edit]
    assemble_args = [
        ctx.executable._macho_edit.path,
        "assemble-macos-framework",
        "--binary",
        prepared_binary.path,
        "--info-plist",
        prepared_plist.path,
        "--assets",
        flutter_assets.path,
        "--output-dir",
        stage_dir,
        "--output-zip",
        framework_zip.path,
    ]
    if is_debug and app_info.kernel_dill:
        inputs.append(app_info.kernel_dill)
        assemble_args.extend(["--kernel-blob", app_info.kernel_dill.path])
        vm_snapshot = flutter_sdk_info.vm_isolate_snapshot
        iso_snapshot = flutter_sdk_info.isolate_snapshot
        if vm_snapshot:
            inputs.append(vm_snapshot)
            assemble_args.extend(["--vm-snapshot-data", vm_snapshot.path])
        if iso_snapshot:
            inputs.append(iso_snapshot)
            assemble_args.extend(["--isolate-snapshot-data", iso_snapshot.path])
    return inputs, assemble_args

def _flutter_macos_framework_impl(ctx):
    """Assembles App.framework as a versioned macOS framework bundle zip.

    Uses the standard macOS versioned framework layout required by NSBundle
    and `/usr/bin/codesign`:
        App.framework/
            App -> Versions/Current/App
            Resources -> Versions/Current/Resources
            Versions/
                A/
                    App                          (AOT dylib or debug stub)
                    Resources/
                        Info.plist
                        flutter_assets/          (asset bundle)
                Current -> A

    The framework is NOT linked against the runner binary. Instead it is placed
    into the .app bundle via additional_contents, matching how `flutter build
    macos` works. The Flutter engine discovers and loads it at runtime via
    NSBundle.

    Bazel does not preserve directory symlinks inside tree artifacts when it
    stages them as action or test inputs (a link to a directory is materialized
    as a real directory, on local execution as well as on disk-cache hits), so
    the versioned layout travels between actions ONLY as the deterministic
    `App.framework.zip` below — never as a tree artifact. Every consumer
    extracts it locally with the rules' own tools (`extractFrameworkZip` in
    `macho_edit.dart`, used directly and via `xtool_pack.dart`), which
    recreate the `Versions/Current`, `App`, and `Resources` symlinks exactly.

    Returning `AppleBundleInfo(archive = framework_zip)` causes rules_apple's
    `macos_additional_contents_partial` to merge `App.framework.zip` via
    `bundle_merge_zips` (which preserves `S_IFLNK` symlinks) rather than
    `bundle_merge_files` (`os.walk` + `open()`, which drops directory symlinks
    `Versions/Current` and `Resources` and dereferences `App.framework/App`
    into a duplicate regular file that `codesign` rejects as ambiguous).
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    is_debug = app_info.is_debug
    flutter_assets = app_info.flutter_assets
    minimum_os_version = ctx.attr.minimum_os_version
    target_arch = apple_support.target_arch_from_rule_ctx(ctx)
    stub_arch = "arm64" if target_arch == "arm64" else "x86_64"
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx, flutter_sdk_info)

    # The versioned layout is emitted as a deterministic `App.framework.zip`
    # for `AppleBundleInfo.archive` so `rules_apple`'s `bundletool` preserves
    # the `Versions/Current`, `App`, and `Resources` symlinks. The zip sits
    # directly under this target's directory so two apps in one package never
    # share an output. The assembly staging directory is deliberately NOT a
    # declared output: a tree artifact carrying the version links must never
    # reach a consumer, because Bazel's input staging materializes directory
    # symlinks as real directories (see the rule docstring).
    framework_zip = ctx.actions.declare_file("%s/App.framework.zip" % ctx.label.name)
    stage_dir = framework_zip.path + ".stage"
    prepared_binary = _prepare_macos_framework_binary(ctx, dart_exe, dart_vm_files, app_info, is_debug, stub_arch, minimum_os_version)

    prepared_plist = ctx.actions.declare_file("%s_macho/Info.plist" % ctx.label.name)
    ctx.actions.write(prepared_plist, _APP_FRAMEWORK_INFO_PLIST)

    inputs, assemble_args = _macos_framework_assemble_inputs(ctx, flutter_sdk_info, app_info, is_debug, flutter_assets, prepared_binary, prepared_plist, stage_dir, framework_zip)

    ctx.actions.run(
        executable = dart_exe,
        arguments = assemble_args,
        inputs = depset(
            direct = inputs,
            transitive = [dart_vm_files],
        ),
        outputs = [framework_zip],
        mnemonic = "FlutterMacOSFramework",
        progress_message = "Assembling App.framework for %s" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([framework_zip])),
        new_applebundleinfo(
            archive = framework_zip,
            binary = prepared_binary,
            bundle_extension = ".framework",
            bundle_id = "io.flutter.flutter.app",
            bundle_name = "App",
            executable_name = "App",
            infoplist = prepared_plist,
            minimum_os_version = minimum_os_version,
            platform_type = "macos",
            product_type = "com.apple.product-type.framework",
            uses_swift = False,
        ),
        framework_import_support.framework_import_info_with_dependencies(
            build_archs = [target_arch],
            deps = [],
            framework_imports = [framework_zip],
        ),
        FlutterDarwinFrameworkInfo(
            framework_name = "App",
            framework_files = depset([framework_zip]),
            framework_dir = framework_zip.path,
            headers = depset(),
            is_dynamic = True,
        ),
    ]

flutter_macos_framework = rule(
    implementation = _flutter_macos_framework_impl,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        {
            "allow_non_macho": attr.string_list(
                doc = "Explicit allow-list of binary or framework names permitted to bypass Mach-O validation.",
                default = [],
            ),
            "application": attr.label(
                doc = "A flutter_application target providing FlutterApplicationInfo.",
                mandatory = True,
                providers = [FlutterApplicationInfo],
            ),
            "minimum_os_version": attr.string(
                doc = "Minimum macOS deployment target version.",
                default = MACOS_MINIMUM_OS_VERSION,
            ),
            "_macho_edit": attr.label(
                default = Label("//flutter/private/tools:macho_edit"),
                executable = True,
                cfg = "exec",
            ),
        },
    ),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "Assembles the Flutter AOT dylib and assets into App.framework for macOS.",
)

# -- flutter_macos_native_libs (dylib staging for additional_contents) -------

def _flutter_macos_native_libs_impl(ctx):
    """Stages native .dylib files flat, for bundling via additional_contents.

    Includes both the legacy `native_libs` set (from `native_deps`-style
    FFI cc_library targets) and the modern `bundled_code_assets` set
    contributed by `flutter_native_asset(link_mode = "dynamic_loading_bundle")`.
    rules_apple's `additional_contents = {target: "Frameworks"}` machinery
    code-signs the dylibs as part of the outer `macos_application` build —
    no bespoke codesign action needed here.

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
    artifact's contents into the destination. The directory is named after
    this target, which keeps two apps in one package from declaring the same
    output.

    Two different libraries with the same basename would overwrite one another
    there, so that fails the build and names both.
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]

    # One library can arrive by both routes; the same path is the same library.
    libs_by_path = {}
    for lib in app_info.native_libs + app_info.bundled_code_assets.to_list():
        libs_by_path[lib.path] = lib

    libs_by_basename = {}
    for lib in libs_by_path.values():
        other = libs_by_basename.get(lib.basename)
        if other:
            fail(
                ("%s: two native libraries would both be bundled as " +
                 "Contents/Frameworks/%s:\n  %s (from %s)\n  %s (from %s)\n" +
                 "macOS loads a bundled library by its file name, so only " +
                 "one of them can ship. Rename one.") % (
                    ctx.label,
                    lib.basename,
                    other.path,
                    other.owner,
                    lib.path,
                    lib.owner,
                ),
            )
        libs_by_basename[lib.basename] = lib

    if not libs_by_basename:
        return [DefaultInfo(files = depset())]

    minimum_os_version = ctx.attr.minimum_os_version
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    staged = ctx.actions.declare_directory(ctx.label.name)
    args = ctx.actions.args()
    args.add(ctx.executable._macho_edit.path)
    args.add("copy-files")
    args.add("--platform")
    args.add("macos")
    args.add("--min-os")
    args.add(minimum_os_version)
    args.add("--sdk-version")
    args.add(minimum_os_version)
    for allowed in ctx.attr.allow_non_macho:
        args.add("--allow-non-macho")
        args.add(allowed)
    args.add("--output-dir")
    args.add(staged.path)
    for basename, lib in libs_by_basename.items():
        args.add(lib)
        args.add(basename)
    ctx.actions.run(
        executable = dart_exe,
        arguments = [args],
        inputs = depset(
            direct = list(libs_by_basename.values()) + [ctx.executable._macho_edit],
            transitive = [dart_vm_files],
        ),
        outputs = [staged],
        mnemonic = "FlutterMacOSNativeLibs",
        progress_message = "Staging native libraries for %{label}",
    )
    return [DefaultInfo(files = depset([staged]))]

flutter_macos_native_libs = rule(
    implementation = _flutter_macos_native_libs_impl,
    attrs = {
        "allow_non_macho": attr.string_list(
            doc = "Explicit allow-list of binary names permitted to bypass Mach-O validation.",
            default = [],
        ),
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "minimum_os_version": attr.string(
            doc = "Minimum macOS deployment target version.",
            default = MACOS_MINIMUM_OS_VERSION,
        ),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "Stages native .dylib files under their basenames for macOS bundling via additional_contents.",
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
