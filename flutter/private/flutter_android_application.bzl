"""Flutter Android application bundling.

Produces the native artifacts needed for an Android APK:
- A .jar containing lib/arm64-v8a/libapp.so (AOT-compiled Dart code)
- flutter_assets/ tree artifact

The user wires these outputs into rules_android's android_binary:

    load("@rules_flutter//flutter:android.bzl", "flutter_android_bundle")

    flutter_application(
        name = "my_app_flutter",
        main = "main.dart",
    )

    flutter_android_bundle(
        name = "my_app_android",
        application = ":my_app_flutter",
    )

    # Wire into android_binary via java_import:
    java_import(
        name = "my_app_native",
        jars = [":my_app_android_native_libs.jar"],
    )

    android_binary(
        name = "my_app",
        manifest = "AndroidManifest.xml",
        deps = [":my_app_native", "@flutter_android_engine_arm64//:flutter_embedding"],
        ...
    )

The native_libs.jar packages libapp.so at lib/<abi>/libapp.so inside a jar,
matching the same convention as flutter.jar (which packages libflutter.so).
This lets android_binary extract and package the .so into the APK automatically.

flutter_android_bundle applies a platform transition derived from its
`android_abi` attribute, so the application — including its AOT compile and
any FFI/native deps — always builds for the matching Android platform
(//flutter/platforms:android_arm64 or :android_x64) with no --platforms
flag from the user. Every native library is validated to be an ELF shared
object with the ABI's machine type before packaging; a host-format binary
is a hard build error.
"""

load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "ANDROID_ABIS", "android_elf_machine_for_abi", "android_platform_for_abi", "compute_android_jni_path")

def _android_platform_transition_impl(_settings, attr):
    return {"//command_line_option:platforms": [android_platform_for_abi(attr.android_abi)]}

# Builds the bundle and everything behind it (the flutter_application, its
# AOT compile, FFI cc deps, Native Assets) for the Android platform matching
# `android_abi`. The ABI attribute is the single source of truth: the platform
# is always derived from it, so the jar's lib/<abi>/ layout and the code inside
# it cannot disagree — including when android_binary's own split transition
# (--android_platforms) already re-configured this target.
_android_platform_transition = transition(
    implementation = _android_platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

# Shell function validating that a native library is an ELF shared object
# with the expected e_machine (2 bytes little-endian at offset 18). Android's
# linker can only load ELF for the APK's ABI; anything else (e.g. a host
# Mach-O dylib) would crash at app startup, so packaging fails instead.
_ELF_VALIDATION_DEF = """\
validate_android_elf() {
  local lib="$1" want_machine="$2" abi="$3"
  local bytes=( $(od -An -v -tu1 -N20 "$lib") )
  if [ "${#bytes[@]}" -lt 20 ] ||
      [ "${bytes[0]}" -ne 127 ] || [ "${bytes[1]}" -ne 69 ] ||
      [ "${bytes[2]}" -ne 76 ] || [ "${bytes[3]}" -ne 70 ]; then
    echo "ERROR: $lib is not an ELF binary. Android ($abi) cannot load it." >&2
    exit 1
  fi
  local machine=$(( bytes[18] | (bytes[19] << 8) ))
  if [ "$machine" -ne "$want_machine" ]; then
    echo "ERROR: $lib has ELF machine $machine; $abi requires $want_machine." >&2
    exit 1
  fi
}"""

def _symlink_to_jni(ctx, src, abi, basename):
    """Create a symlink placing a native lib into the jni/<abi>/ tree."""
    out = ctx.actions.declare_file(compute_android_jni_path(abi, basename))
    ctx.actions.symlink(output = out, target_file = src)
    return out

def _symlink_assets_dir(ctx, flutter_assets):
    """Symlink the flutter_assets tree into assets/flutter_assets/ for mobile-install."""

    # Use label name as prefix to avoid conflicts when multiple bundles
    # exist in the same package (e.g. Tier 1 macro + explicit Tier 2).
    out = ctx.actions.declare_directory(ctx.label.name + "_mi/assets/flutter_assets")
    ctx.actions.symlink(output = out, target_file = flutter_assets)
    return out

def _create_native_libs_jar(ctx, aot_output, native_libs, abi):
    """Package native libs into a jar at lib/<abi>/*.so.

    This matches flutter.jar's convention (which puts libflutter.so at
    lib/arm64-v8a/libflutter.so). java_import + android_binary then
    extract and package the .so files into the APK automatically.

    Every library is validated to be an ELF shared object with the ABI's
    machine type before it is zipped — a wrong-format library fails the
    build instead of producing an APK that crashes on device. Two libraries
    claiming the same packaged filename are a hard error too: the zip would
    otherwise silently drop one of them.

    Args:
        ctx: Rule context.
        aot_output: The AOT compile output, packaged as libapp.so (Android
            convention: the engine loads the Dart snapshot via
            System.loadLibrary("app")). None in debug/JIT mode.
        native_libs: Plugin/FFI .so files to package under their own names.
        abi: Android ABI string (e.g. "arm64-v8a").

    Returns:
        The output .jar File.
    """
    jar = ctx.actions.declare_file(ctx.label.name + "_native_libs.jar")
    expected_machine = android_elf_machine_for_abi(abi)

    entries = ([("libapp.so", aot_output)] if aot_output else []) + [
        (lib.basename, lib)
        for lib in native_libs
    ]

    commands = [_ELF_VALIDATION_DEF]
    zip_entries = []
    seen_basenames = {}
    for basename, lib in entries:
        if basename in seen_basenames:
            fail(
                "flutter_android_bundle: two native libraries would both be " +
                "packaged as lib/{abi}/{basename}: {first} and {second}. ".format(
                    abi = abi,
                    basename = basename,
                    first = seen_basenames[basename].path,
                    second = lib.path,
                ) +
                "Rename one of them — Android can only load one.",
            )
        seen_basenames[basename] = lib
        commands.append('validate_android_elf "{lib}" {machine} "{abi}"'.format(
            lib = lib.path,
            machine = expected_machine,
            abi = abi,
        ))
        zip_entries.append("lib/{abi}/{basename}={src}".format(
            abi = abi,
            basename = basename,
            src = lib.path,
        ))

    # cC = create, no compression (native libs don't benefit).
    commands.append('exec "{zipper}" cC "{jar}" "$@"'.format(
        zipper = ctx.executable._zipper.path,
        jar = jar.path,
    ))

    ctx.actions.run_shell(
        command = "\n".join(commands),
        arguments = zip_entries,
        inputs = [lib for _, lib in entries],
        tools = [ctx.executable._zipper],
        outputs = [jar],
        mnemonic = "FlutterNativeLibsJar",
        progress_message = "Packaging Flutter native libs into jar %s" % ctx.label,
    )
    return jar

def _copy_assets_with_kernel(ctx, flutter_assets, kernel_dill, flutter_sdk_info):
    """Copy flutter_assets and add kernel_blob.bin + VM snapshots for debug mode.

    On Android, the debug engine looks for kernel_blob.bin inside
    flutter_assets/ (same convention as `flutter build apk --debug`).
    The vm_snapshot_data and isolate_snapshot_data are needed for the
    kernel service isolate (hot reload and expression evaluation).
    """
    out = ctx.actions.declare_directory(ctx.label.name + "_debug_flutter_assets")

    cmd = 'cp -RL "$1"/. "$2" && cp "$3" "$2/kernel_blob.bin"'
    args = [flutter_assets.path, out.path, kernel_dill.path]
    inputs = [flutter_assets, kernel_dill]

    vm_snapshot = flutter_sdk_info.vm_isolate_snapshot
    iso_snapshot = flutter_sdk_info.isolate_snapshot
    if vm_snapshot:
        cmd += ' && cp "%s" "$2/vm_snapshot_data"' % vm_snapshot.path
        inputs.append(vm_snapshot)
    if iso_snapshot:
        cmd += ' && cp "%s" "$2/isolate_snapshot_data"' % iso_snapshot.path
        inputs.append(iso_snapshot)

    ctx.actions.run_shell(
        command = cmd,
        arguments = args,
        inputs = inputs,
        outputs = [out],
        mnemonic = "FlutterAndroidDebugAssets",
        progress_message = "Assembling debug flutter_assets with kernel and VM snapshots %s" % ctx.label,
    )
    return out

def _flutter_android_bundle_impl(ctx):
    """Bundles Flutter compilation outputs for Android packaging."""
    app_info = ctx.attr.application[FlutterApplicationInfo]
    flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
    flutter_assets = app_info.flutter_assets
    native_libs = list(app_info.native_libs)

    # Native Assets `dynamic_loading_bundle` shared libraries land in
    # `jniLibs/<abi>/` of the same `native_libs.jar` rules_android
    # already extracts into the APK.
    native_libs.extend(app_info.bundled_code_assets.to_list())

    kernel_dill = app_info.kernel_dill

    # Debug mode: include kernel_blob.bin in flutter_assets for JIT execution.
    if kernel_dill and not app_info.aot_output:
        flutter_assets = _copy_assets_with_kernel(ctx, flutter_assets, kernel_dill, flutter_sdk_info)

    # The AOT output is the libapp.so for Android.
    aot_output = app_info.aot_output
    all_native_libs = ([aot_output] if aot_output else []) + native_libs
    abi = ctx.attr.android_abi

    # Create a jar containing native libs at lib/<abi>/*.so.
    # In debug mode (JIT) with no plugin/FFI libs there is nothing to
    # package — create an empty jar so the java_import pipeline in the
    # macro doesn't break.
    if all_native_libs:
        native_libs_jar = _create_native_libs_jar(ctx, aot_output, native_libs, abi)
    else:
        native_libs_jar = ctx.actions.declare_file(ctx.label.name + "_native_libs.jar")

        # Zipper requires at least one entry, so use a minimal valid zip header.
        ctx.actions.run_shell(
            command = 'printf "\\x50\\x4b\\x05\\x06\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00" > "$1"',
            arguments = [native_libs_jar.path],
            outputs = [native_libs_jar],
            mnemonic = "FlutterEmptyNativeLibsJar",
            progress_message = "Creating empty native libs jar (debug mode) %s" % ctx.label,
        )

    outputs = [flutter_assets, native_libs_jar] + all_native_libs

    # mobile-install compatible output structure.
    mobile_install_files = []
    if ctx.attr.mobile_install_compatible:
        if aot_output:
            jni_libapp = _symlink_to_jni(ctx, aot_output, abi, "libapp.so")
            mobile_install_files.append(jni_libapp)

        for lib in native_libs:
            jni_lib = _symlink_to_jni(ctx, lib, abi, lib.basename)
            mobile_install_files.append(jni_lib)

        assets_dir = _symlink_assets_dir(ctx, flutter_assets)
        mobile_install_files.append(assets_dir)

        outputs.extend(mobile_install_files)

    return [
        DefaultInfo(files = depset(outputs)),
        OutputGroupInfo(
            native_libs = depset(all_native_libs),
            native_libs_jar = depset([native_libs_jar]),
            flutter_assets = depset([flutter_assets]),
            mobile_install = depset(mobile_install_files),
        ),
    ]

flutter_android_bundle = rule(
    implementation = _flutter_android_bundle_impl,
    cfg = _android_platform_transition,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing the compiled artifacts.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "mobile_install_compatible": attr.bool(
            doc = """Whether to produce output structured for `bazel mobile-install`.

When True (the default), native libs are symlinked into jni/<abi>/ and
flutter assets into assets/flutter_assets/, matching the directory layout
that mobile-install expects. A `mobile_install` output group is also
provided for selective fetching.

Set to False if you only build release APKs and do not need mobile-install.""",
            default = True,
        ),
        "android_abi": attr.string(
            doc = """Android ABI to build for ("arm64-v8a" or "x86_64").

Single source of truth for the target platform: the rule transitions itself
and the application to the matching //flutter/platforms target, so native
library placement (lib/<abi>/) and the code built into those libraries always
agree.""",
            default = "arm64-v8a",
            values = ANDROID_ABIS.keys(),
        ),
        "_zipper": attr.label(
            default = "@bazel_tools//tools/zip:zipper",
            executable = True,
            cfg = "exec",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    toolchains = ["@rules_flutter//flutter:toolchain_type"],
    doc = """Bundles Flutter compilation outputs for Android packaging.

Produces a native_libs.jar containing lib/<abi>/libapp.so and a flutter_assets
tree artifact. Use java_import on the jar and android_binary to assemble the APK.

The rule transitions itself and `application` to the Android platform derived
from `android_abi`, so the AOT compile and all native deps target Android
without any --platforms flag. Passing --android_platforms to android_binary
remains supported: this rule's transition re-normalizes its subgraph to the
declared ABI's platform, so the two compose to the same configuration. Native
libraries are validated to be ELF for the declared ABI at packaging time.

By default, outputs are also structured for `bazel mobile-install` compatibility.
Use the wrapping android_binary target with `bazel mobile-install` for fast
incremental deployment to a connected device.""",
)
