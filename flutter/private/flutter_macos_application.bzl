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

def _flutter_macos_framework_impl(ctx):
    """Assembles App.framework as a versioned macOS framework (tree artifact).

    Uses the standard macOS versioned framework layout required by NSBundle:
        App.framework/
            App -> Versions/Current/App
            Resources -> Versions/Current/Resources
            Versions/
                A/
                    App                          (AOT dylib, release only)
                    Resources/
                        Info.plist
                        flutter_assets/          (asset bundle)
                        app.dill                 (kernel snapshot, debug only)
                Current -> A

    The framework is NOT linked against the runner binary. Instead it is placed
    into the .app bundle via additional_contents, matching how `flutter build
    macos` works. The Flutter engine discovers and loads it at runtime via
    NSBundle.
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    is_debug = app_info.is_debug
    flutter_assets = app_info.flutter_assets
    minimum_os_version = ctx.attr.minimum_os_version
    target_arch = apple_support.target_arch_from_rule_ctx(ctx)
    stub_arch = "arm64" if target_arch == "arm64" else "x86_64"
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx, flutter_sdk_info)

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
    else:
        if not app_info.aot_output:
            fail("flutter_macos_framework requires an AOT build (not debug mode) or a kernel_dill in debug mode.")
        ctx.actions.run(
            executable = dart_exe,
            arguments = [
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
                "--allow-non-macho",
            ],
            inputs = depset(
                direct = [app_info.aot_output, ctx.executable._macho_edit],
                transitive = [dart_vm_files],
            ),
            outputs = [prepared_binary],
            mnemonic = "FlutterMacOSRetagDylib",
            progress_message = "Retagging App dylib for macos (min %s)" % minimum_os_version,
        )

    prepared_plist = ctx.actions.declare_file("%s_macho/Info.plist" % ctx.label.name)
    ctx.actions.write(prepared_plist, _APP_FRAMEWORK_INFO_PLIST)

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
        wrapper_dir.path,
    ]

    # In debug mode, place the kernel dill and VM snapshots into flutter_assets/.
    # The debug engine looks for kernel_blob.bin there. The vm_snapshot_data and
    # isolate_snapshot_data are needed for the kernel service isolate (hot reload).
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

    ctx.actions.run(
        executable = dart_exe,
        arguments = assemble_args,
        inputs = depset(
            direct = inputs,
            transitive = [dart_vm_files],
        ),
        outputs = [wrapper_dir],
        mnemonic = "FlutterMacOSFramework",
        progress_message = "Assembling App.framework for %s" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([wrapper_dir])),
        framework_import_support.framework_import_info_with_dependencies(
            build_archs = [target_arch],
            deps = [],
            framework_imports = [wrapper_dir],
        ),
        FlutterDarwinFrameworkInfo(
            framework_name = "App",
            framework_files = depset([wrapper_dir]),
            framework_dir = wrapper_dir.path + "/App.framework",
            headers = depset(),
            is_dynamic = True,
        ),
    ]

flutter_macos_framework = rule(
    implementation = _flutter_macos_framework_impl,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        {
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
    artifact's contents into the destination, as it does for App.framework's
    wrapper. The directory is named after this target, which keeps two apps in
    one package from declaring the same output.

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

    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    staged = ctx.actions.declare_directory(ctx.label.name)
    args = ctx.actions.args()
    args.add(ctx.executable._macho_edit.path)
    args.add("copy-files")
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
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
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
