"""Flutter iOS application bundling (private implementation).

Produces the intermediate artifacts needed for an iOS .ipa:
- Release (AOT): App.framework/App (Mach-O dylib) + Info.plist + flutter_assets/
- Debug (JIT): App.framework/App (stub dylib) + Info.plist + flutter_assets/ (with kernel_blob.bin)

The framework is packaged by flutter_ios_framework_gen (a macro in flutter/ios.bzl)
which wraps it with apple_dynamic_framework_import for seamless integration
with rules_apple's ios_application. Debug mode uses bundle_only=True to
embed the framework without linking (stub binary is not loaded at runtime).

Usage: see flutter/ios.bzl for public API.
"""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:dicts.bzl", "dicts")

# framework_import_support is rules_apple-internal, but it is the only way to
# construct AppleFrameworkImportInfo (its init is banned) for the N transitive
# native-asset frameworks that apple_dynamic_framework_import can't express
# (it accepts a single .framework). This is the same helper that rule uses.
# buildifier: disable=bzl-visibility
load("@rules_apple//apple/internal:framework_import_support.bzl", "framework_import_support")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:constants.bzl", "IOS_MINIMUM_OS_VERSION")
load("//flutter/private:flutter_native_assets.bzl", "native_asset_framework_name")

def _flutter_ios_application_impl(ctx):
    """Bundles Flutter compilation outputs for iOS packaging."""
    app_info = ctx.attr.application[FlutterApplicationInfo]
    flutter_assets = app_info.flutter_assets
    native_libs = app_info.native_libs

    outputs = [flutter_assets] + native_libs
    output_groups = {
        "flutter_assets": depset([flutter_assets]),
        "native_libs": depset(native_libs),
    }

    if app_info.aot_output:
        outputs.append(app_info.aot_output)
        output_groups["aot_dylib"] = depset([app_info.aot_output])

    return [
        DefaultInfo(files = depset(outputs)),
        OutputGroupInfo(**output_groups),
        # Pass through FlutterApplicationInfo so downstream rules can access it.
        app_info,
    ]

flutter_ios_application = rule(
    implementation = _flutter_ios_application_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing the compiled artifacts.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    },
    doc = "Bundles Flutter compilation outputs for iOS packaging.",
)

# -- App.framework assembly rule --

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
    <key>MinimumOSVersion</key>
    <string>{minimum_os_version}</string>
</dict>
</plist>
"""

def _flutter_ios_framework_impl(ctx):
    """Assembles Flutter artifacts into App.framework individual files.

    Release mode (AOT): App binary (retagged via vtool) + Info.plist + flutter_assets.
    Debug mode (JIT): stub binary + Info.plist + flutter_assets (with kernel_blob.bin +
        vm_isolate_snapshot.bin + isolate_snapshot.bin for kernel service).

    In debug mode a stub dylib is created because rules_apple's framework
    processor requires a binary. bundle_only=True prevents linking so the
    stub is never loaded — the engine uses kernel_blob.bin instead.
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    flutter_assets = app_info.flutter_assets
    minimum_os_version = ctx.attr.minimum_os_version

    # Common: Info.plist and flutter_assets tree artifact.
    framework_plist = ctx.actions.declare_file("App.framework/Info.plist")
    framework_assets = ctx.actions.declare_directory("App.framework/flutter_assets")

    ctx.actions.write(framework_plist, _APP_FRAMEWORK_INFO_PLIST.format(
        minimum_os_version = minimum_os_version,
    ))

    if app_info.aot_output:
        # Release mode: AOT binary + flutter_assets.
        dylib = app_info.aot_output

        # Detect device vs simulator via platform constraints.
        is_device = apple_support.target_environment_from_rule_ctx(ctx) == "device"
        vtool_platform = "ios" if is_device else "iossim"

        framework_binary = ctx.actions.declare_file("App.framework/App")

        # Copy the dylib and retag platform with vtool.
        # gen_snapshot tags output as macOS (the host), but iOS needs the binary
        # tagged as 'ios' (device) or 'iossim' (simulator) in LC_BUILD_VERSION.
        ctx.actions.run_shell(
            command = 'cp "$1" "$2" && xcrun vtool -set-build-version "$3" "$4" "$4" -replace -output "$2" "$2"',
            arguments = [dylib.path, framework_binary.path, vtool_platform, minimum_os_version],
            inputs = [dylib],
            outputs = [framework_binary],
            mnemonic = "FlutterIOSRetagDylib",
            progress_message = "Retagging App dylib for %s (min %s)" % (vtool_platform, minimum_os_version),
        )

        # Copy flutter_assets into the framework.
        ctx.actions.run_shell(
            command = 'cp -RL "$1"/. "$2"',
            arguments = [flutter_assets.path, framework_assets.path],
            inputs = [flutter_assets],
            outputs = [framework_assets],
            mnemonic = "FlutterIOSCopyAssets",
            progress_message = "Copying flutter_assets into App.framework",
        )

        return [DefaultInfo(files = depset([framework_binary, framework_plist, framework_assets]))]
    else:
        # Debug mode: stub binary + flutter_assets with kernel_blob.bin.
        kernel_dill = app_info.kernel_dill

        is_device = apple_support.target_environment_from_rule_ctx(ctx) == "device"
        sdk = "iphoneos" if is_device else "iphonesimulator"
        vtool_platform = "ios" if is_device else "iossim"
        framework_binary = ctx.actions.declare_file("App.framework/App")

        # Create a stub dylib — rules_apple's framework processor requires a
        # binary file. bundle_only=True prevents linking so it's never loaded.
        ctx.actions.run_shell(
            command = 'echo "" | xcrun -sdk "$1" clang -shared -o "$2" -x c - && xcrun vtool -set-build-version "$3" "$4" "$4" -replace -output "$2" "$2"',
            arguments = [sdk, framework_binary.path, vtool_platform, minimum_os_version],
            outputs = [framework_binary],
            mnemonic = "FlutterIOSStubDylib",
            progress_message = "Creating stub App.framework binary for debug mode",
        )

        # Copy flutter_assets and add kernel_blob.bin + VM snapshots.
        # The vm_isolate_snapshot.bin and isolate_snapshot.bin are required for
        # the Dart VM to bootstrap the kernel service isolate, which enables
        # hot reload (reloadSources) and expression evaluation.
        vm_snapshot = flutter_sdk_info.vm_isolate_snapshot
        iso_snapshot = flutter_sdk_info.isolate_snapshot

        copy_cmd = 'cp -RL "$1"/. "$2" && cp "$3" "$2/kernel_blob.bin"'
        copy_args = [flutter_assets.path, framework_assets.path, kernel_dill.path]
        copy_inputs = [flutter_assets, kernel_dill]

        if vm_snapshot:
            copy_cmd += ' && cp "$4" "$2/vm_snapshot_data"'
            copy_args.append(vm_snapshot.path)
            copy_inputs.append(vm_snapshot)
        if iso_snapshot:
            copy_cmd += ' && cp "%s" "$2/isolate_snapshot_data"' % ("$5" if vm_snapshot else "$4")
            copy_args.append(iso_snapshot.path)
            copy_inputs.append(iso_snapshot)

        ctx.actions.run_shell(
            command = copy_cmd,
            arguments = copy_args,
            inputs = copy_inputs,
            outputs = [framework_assets],
            mnemonic = "FlutterIOSDebugAssets",
            progress_message = "Assembling debug App.framework with kernel and VM snapshots",
        )

        return [DefaultInfo(files = depset([framework_binary, framework_plist, framework_assets]))]

flutter_ios_framework = rule(
    implementation = _flutter_ios_framework_impl,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        {
            "application": attr.label(
                doc = "A flutter_ios_application target providing Flutter compilation outputs.",
                mandatory = True,
                providers = [FlutterApplicationInfo],
            ),
            "minimum_os_version": attr.string(
                doc = "Minimum iOS deployment target version.",
                default = IOS_MINIMUM_OS_VERSION,
            ),
        },
    ),
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
    doc = "Assembles Flutter artifacts into App.framework for iOS (release: AOT binary + assets; debug: assets + kernel).",
)

# -- flutter_ios_native_frameworks (dylib -> framework wrapping) ---------------

_NATIVE_ASSET_FRAMEWORK_INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleDevelopmentRegion</key>
\t<string>en</string>
\t<key>CFBundleExecutable</key>
\t<string>{name}</string>
\t<key>CFBundleIdentifier</key>
\t<string>{bundle_id}</string>
\t<key>CFBundleInfoDictionaryVersion</key>
\t<string>6.0</string>
\t<key>CFBundleName</key>
\t<string>{name}</string>
\t<key>CFBundlePackageType</key>
\t<string>FMWK</string>
\t<key>CFBundleShortVersionString</key>
\t<string>1.0</string>
\t<key>CFBundleSignature</key>
\t<string>????</string>
\t<key>CFBundleVersion</key>
\t<string>1.0</string>
\t<key>MinimumOSVersion</key>
\t<string>{minimum_os_version}</string>
</dict>
</plist>
"""

def _flutter_ios_native_frameworks_impl(ctx):
    """Wraps each native dylib in a signed `.framework` for iOS bundling.

    iOS forbids loose embedded dylibs, so every native dependency — the legacy
    `native_libs` set (FFI `native_deps`) and the `bundled_code_assets` set
    contributed by Native Assets `dynamic_loading_bundle` declarations — is
    repackaged as `<name>.framework/<name>` (binary + Info.plist) with its
    install name rewritten to `@rpath/<name>.framework/<name>`, matching
    flutter_tools' `copyNativeCodeAssetsIOS`. The resulting
    `AppleFrameworkImportInfo` lets `ios_application` embed and code-sign each
    framework; the engine `dlopen`s the framework-relative path the
    native-assets manifest records (see flutter_native_assets.bzl).
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    dylibs = list(app_info.native_libs) + app_info.bundled_code_assets.to_list()
    minimum_os_version = ctx.attr.minimum_os_version

    framework_files = []
    seen = {}
    for dylib in dylibs:
        name = native_asset_framework_name(dylib.basename)
        if name in seen:
            fail(
                "Two native dylibs map to the same iOS framework name %r " % name +
                "(from %s and %s). Rename one native asset." % (seen[name], dylib.basename),
            )
        seen[name] = dylib.basename

        binary = ctx.actions.declare_file("%s/%s.framework/%s" % (ctx.label.name, name, name))
        plist = ctx.actions.declare_file("%s/%s.framework/Info.plist" % (ctx.label.name, name))

        # Copy the dylib into the framework and rewrite its install name so the
        # dynamic linker resolves it from the embedded framework via @rpath.
        ctx.actions.run_shell(
            command = 'cp "$1" "$2" && xcrun install_name_tool -id "$3" "$2"',
            arguments = [
                dylib.path,
                binary.path,
                "@rpath/%s.framework/%s" % (name, name),
            ],
            inputs = [dylib],
            outputs = [binary],
            mnemonic = "FlutterIOSNativeAssetFramework",
            progress_message = "Wrapping %s into %s.framework" % (dylib.basename, name),
        )

        ctx.actions.write(plist, _NATIVE_ASSET_FRAMEWORK_INFO_PLIST.format(
            name = name,
            bundle_id = ("io.flutter.flutter.native_assets.%s" % name).replace("_", "-"),
            minimum_os_version = minimum_os_version,
        ))

        framework_files.append(binary)
        framework_files.append(plist)

    return [
        DefaultInfo(files = depset(framework_files)),
        framework_import_support.framework_import_info_with_dependencies(
            build_archs = [apple_support.target_arch_from_rule_ctx(ctx)],
            deps = [],
            framework_imports = framework_files,
        ),
    ]

flutter_ios_native_frameworks = rule(
    implementation = _flutter_ios_native_frameworks_impl,
    attrs = dicts.add(
        apple_support.platform_constraint_attrs(),
        {
            "application": attr.label(
                doc = "A flutter_application target providing FlutterApplicationInfo.",
                mandatory = True,
                providers = [FlutterApplicationInfo],
            ),
            "minimum_os_version": attr.string(
                doc = "Minimum iOS deployment target version (framework Info.plist).",
                default = IOS_MINIMUM_OS_VERSION,
            ),
        },
    ),
    doc = "Wraps native plugin/native-asset dylibs in signed .frameworks for iOS bundling.",
)

# -- flutter_ios_privacy_manifests (xcprivacy bundling) -----------------------

def _flutter_ios_privacy_manifests_impl(ctx):
    """Exposes plugin `PrivacyInfo.xcprivacy` files for iOS bundling.

    Apple requires every framework to ship a privacy manifest since
    iOS 17.4; the App Store submission validator walks the bundle and
    aggregates them. The ios_application rule consumes this through its
    `resources` attribute so each plugin's manifest lands inside the
    app bundle.

    `ios_application.resources` flattens all inputs with the same basename
    into the bundle root, so we can't pass the raw `PrivacyInfo.xcprivacy`
    files (every plugin ships the same basename). Symlink each input to a
    unique name encoding the source path — the resulting basenames don't
    collide and Apple's submission validator finds them all.
    """
    app_info = ctx.attr.application[FlutterApplicationInfo]
    inputs = app_info.apple_privacy_manifests.to_list()

    # Each input gets renamed to `<sanitized-path>.xcprivacy` so they're
    # unique. The sanitized path encodes the originating plugin's package
    # (e.g. `package_info_plus_Sources_package_info_plus_PrivacyInfo.xcprivacy`)
    # so the manifests remain attributable in the bundle.
    outputs = []
    for f in inputs:
        # Use the file's path components after the workspace prefix, joined
        # by underscores, to produce a unique basename per input.
        sanitized = f.short_path.replace("/", "_").replace("..", "_")
        if sanitized.endswith(".xcprivacy"):
            sanitized = sanitized[:-len(".xcprivacy")]
        out = ctx.actions.declare_file("%s_%s.xcprivacy" % (ctx.label.name, sanitized))
        ctx.actions.symlink(output = out, target_file = f)
        outputs.append(out)

    return [DefaultInfo(files = depset(outputs))]

flutter_ios_privacy_manifests = rule(
    implementation = _flutter_ios_privacy_manifests_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
    },
    doc = "Extracts plugin `PrivacyInfo.xcprivacy` files for iOS bundling via additional_contents.",
)
