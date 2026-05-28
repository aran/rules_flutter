"""Flutter macOS App.framework assembly and native lib extraction.

Two rules:

1. `flutter_macos_framework` — assembles the AOT dylib (release) or kernel
   .dill (debug) into an App.framework with macOS directory structure.
   The framework is placed into the .app via additional_contents (NOT linked
   against the runner binary), matching how `flutter build macos` works.

2. `flutter_macos_native_libs` — exposes native plugin .dylib files for
   bundling via additional_contents.

These are exported as `flutter_macos_framework_gen` and `flutter_macos_native_libs_gen`
from flutter/macos.bzl.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")

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

    # Use a wrapper directory so that additional_contents preserves the
    # App.framework/ level. Tree artifacts placed via additional_contents have
    # their contents expanded into the destination, so the internal structure
    # must include the App.framework/ directory name.
    wrapper_dir = ctx.actions.declare_directory("app_framework")

    inputs = [flutter_assets]
    shell_parts = [
        "set -e",
        'FW="$1/App.framework"',
        'mkdir -p "$FW/Resources"',
    ]

    # $1 = wrapper dir, $2 = AOT/dill source, $3 = flutter_assets dir
    args = ctx.actions.args()
    args.add(wrapper_dir.path)

    if is_debug:
        if app_info.kernel_dill:
            inputs.append(app_info.kernel_dill)
            args.add(app_info.kernel_dill.path)

            # The debug engine looks for kernel_blob.bin in flutter_assets/.
            # We copy it after flutter_assets is assembled (see shell_parts below).
            shell_parts.append("")  # placeholder — kernel copy happens after flutter_assets
        else:
            args.add("")  # placeholder
    else:
        if not app_info.aot_output:
            fail("flutter_macos_framework requires an AOT build (not debug mode) or a kernel_dill in debug mode.")
        inputs.append(app_info.aot_output)
        args.add(app_info.aot_output.path)
        shell_parts.append('cp "$2" "$FW/App"')

    args.add(flutter_assets.path)

    # Copy flutter_assets and write Info.plist inside Resources/.
    shell_parts.extend([
        'cp -RL "$3"/. "$FW/Resources/flutter_assets"',
        'cat > "$FW/Resources/Info.plist" << \'PLISTEOF\'\n' + _APP_FRAMEWORK_INFO_PLIST + "PLISTEOF",
    ])

    # In debug mode, place the kernel dill and VM snapshots into flutter_assets/.
    # The debug engine looks for kernel_blob.bin there. The vm_snapshot_data and
    # isolate_snapshot_data are needed for the kernel service isolate (hot reload).
    if is_debug and app_info.kernel_dill:
        shell_parts.append('cp "$2" "$FW/Resources/flutter_assets/kernel_blob.bin"')
        vm_snapshot = flutter_sdk_info.vm_isolate_snapshot
        iso_snapshot = flutter_sdk_info.isolate_snapshot
        if vm_snapshot:
            inputs.append(vm_snapshot)
            shell_parts.append('cp "%s" "$FW/Resources/flutter_assets/vm_snapshot_data"' % vm_snapshot.path)
        if iso_snapshot:
            inputs.append(iso_snapshot)
            shell_parts.append('cp "%s" "$FW/Resources/flutter_assets/isolate_snapshot_data"' % iso_snapshot.path)

    ctx.actions.run_shell(
        command = "\n".join(shell_parts),
        arguments = [args],
        inputs = inputs,
        outputs = [wrapper_dir],
        mnemonic = "FlutterMacOSFramework",
        progress_message = "Assembling App.framework for %s" % ctx.label,
    )

    return [DefaultInfo(files = depset([wrapper_dir]))]

flutter_macos_framework = rule(
    implementation = _flutter_macos_framework_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    },
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
    doc = "Assembles the Flutter AOT dylib and assets into App.framework for macOS.",
)

# -- flutter_macos_native_libs (dylib extraction for additional_contents) ------

def _flutter_macos_native_libs_impl(ctx):
    """Exposes native plugin .dylib files for bundling via additional_contents.

    Includes both the legacy `native_libs` set (from `native_deps`-style
    FFI cc_library targets) and the modern `bundled_code_assets` set
    contributed by `flutter_native_asset(link_mode = "dynamic_loading_bundle")`.
    rules_apple's `additional_contents = {target: "Frameworks"}` machinery
    code-signs the dylibs as part of the outer `macos_application` build —
    no bespoke codesign action needed here.
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    files = list(app_info.native_libs)
    files.extend(app_info.bundled_code_assets.to_list())
    return [DefaultInfo(files = depset(files))]

flutter_macos_native_libs = rule(
    implementation = _flutter_macos_native_libs_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    },
    doc = "Extracts native plugin .dylib files for macOS bundling via additional_contents.",
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
