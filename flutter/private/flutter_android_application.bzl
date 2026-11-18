"""Flutter Android application bundling.

Produces the native artifacts needed for an Android APK:
- libapp.so (AOT-compiled Dart code), as a native library of the APK
- the app's other native libraries (FFI, Native Assets)
- the flutter_assets/ tree, at `<name>/assets/flutter_assets/`

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

    filegroup(
        name = "my_app_flutter_assets",
        srcs = [":my_app_android"],
        output_group = "flutter_assets",
    )

    # Put the bundle in android_binary's `deps`: it provides its native
    # libraries as `AndroidNativeLibsInfo`, as an `aar_import` does. Its
    # flutter_assets tree goes in `assets`.
    android_binary(
        name = "my_app",
        manifest = "AndroidManifest.xml",
        assets = [":my_app_flutter_assets"],
        assets_dir = "assets",
        nocompress_extensions = [".so"],
        deps = [":my_app_android", ...],
        ...
    )

The bundle's native libraries are one zip of `lib/<abi>/<name>` entries,
stored uncompressed: `libapp.so`, the `native_deps` libraries and the code
assets that ship (in a release or profile build, those the packages' link
hooks keep), each stripped as a Gradle build strips it. `android_binary`
builds its dependencies once for each platform
of `--@rules_android//flags:android_platforms` and merges each build's zip
into the APK. The zip is also the `native_libs` output group.

The bundle is built for whichever Android platform `android_binary` builds it
for, and takes its ABI from that platform, so the application behind it (its
AOT compile and any FFI/native deps) is built for the same one. Every native
library is validated to be an ELF shared object with the ABI's machine type
before the APK is packaged; a host-format binary is a hard build error.
`flutter_android_bundle`, the macro in android.bzl, makes the bundle
incompatible with any platform that is not Android arm, arm64 or x86_64:
building it there fails as incompatible, and `bazel build //...` skips it.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_android//providers:providers.bzl", "AndroidNativeLibsInfo")
load("@rules_android//rules:utils.bzl", android_utils = "utils")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING", "program_assets_action_args")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterSdkRecordInfo")
load("//flutter/private:android_strip.bzl", "STRIP_ATTRS", "STRIP_EXEC_GROUPS", "run_strip_native_libs")
load("//flutter/private:assemble_directory.bzl", "ASSEMBLE_DIRECTORY_ATTRS", "assemble_directory")
load("//flutter/private:common.bzl", "android_elf_machine_for_abi")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:flutter_native_assets.bzl", "CODE_ASSETS_TOOL_ATTRS", "run_code_assets_tool")
load("//flutter/private:mobile_engine_check.bzl", "check_android_engine")
load("//flutter/private:native_libraries.bzl", "native_library_files", "plugin_native_libraries")
load("//flutter/private:program_analysis.bzl", "bundled_program_info")

visibility("//flutter/...")

FlutterAndroidBundleLibsInfo = provider(
    doc = "Which of a `flutter_android_bundle`'s native libraries are its plugins'.",
    fields = {
        "plugin_libraries": "list[str]: The names, in the `native_libs` zip, of the `native_deps` libraries of the plugins with an Android library (`FlutterApplicationInfo.android_libs`). An APK packages them with the app's; a module AAR leaves them to the AAR of each plugin (`flutter_android_plugin_aars`), as `flutter build aar` does.",
    },
)

# The ABIs of devices that can have 16 KB pages: Android's 64-bit ones. Every
# native library packaged for them is checked to be aligned for that.
_SIXTEEN_KB_ABIS = ["arm64-v8a", "x86_64"]
_PAGE_SIZE = 16384

# The attributes `android_abi` and `validate_android_native_libs` read.
ANDROID_NATIVE_LIBS_ATTRS = {
    "_allow_4kb_aligned_native_libraries": attr.label(
        default = "//flutter:allow_4kb_aligned_native_libraries",
        providers = [BuildSettingInfo],
    ),
    "_android_constraint": attr.label(default = "@platforms//os:android"),
    "_arm64_constraint": attr.label(default = "@platforms//cpu:aarch64"),
    "_armv7_constraint": attr.label(default = "@platforms//cpu:armv7"),
    "_validate_tool": attr.label(
        default = "//flutter/private/tools:validate_android_elf.dart",
        allow_single_file = True,
    ),
    "_x86_64_constraint": attr.label(default = "@platforms//cpu:x86_64"),
}

def android_abi(ctx):
    """The ABI of the Android platform the target is built for.

    Args:
        ctx: Rule context, with `ANDROID_NATIVE_LIBS_ATTRS`.

    Returns:
        "armeabi-v7a", "arm64-v8a" or "x86_64", or None for a platform that is
        not Android arm, arm64 or x86_64.
    """
    if ctx.target_platform_has_constraint(ctx.attr._android_constraint[platform_common.ConstraintValueInfo]):
        if ctx.target_platform_has_constraint(ctx.attr._arm64_constraint[platform_common.ConstraintValueInfo]):
            return "arm64-v8a"
        if ctx.target_platform_has_constraint(ctx.attr._x86_64_constraint[platform_common.ConstraintValueInfo]):
            return "x86_64"
        if ctx.target_platform_has_constraint(ctx.attr._armv7_constraint[platform_common.ConstraintValueInfo]):
            return "armeabi-v7a"
    return None

def _android_abi(ctx):
    """The ABI of the Android platform this bundle is built for, or a failure."""
    abi = android_abi(ctx)
    if abi:
        return abi
    fail((
        "{label} is built for the platform {platform}, which is not Android arm, arm64 or " +
        "x86_64. An Android app is built for the platforms of --@rules_android//flags:android_platforms: pass " +
        "--@rules_android//flags:android_platforms=@rules_android//:arm64-v8a (and " +
        ":armeabi-v7a or :x86_64 for a second ABI), or build it through flutter_android_build."
    ).format(label = ctx.label, platform = ctx.fragments.platform.platform))

def validate_android_native_libs(ctx, tools, abi, libs, name):
    """Checks that a device of `abi` can load `libs`, in a build action.

    Each library must be an ELF shared object of the ABI's machine type and,
    for a 64-bit ABI, have its segments aligned for 16 KB pages, unless
    `--@rules_flutter//flutter:allow_4kb_aligned_native_libraries` is set.

    The check is a Dart script run by the exec-tools toolchain's `dart`, so it
    runs on any host.

    Args:
        ctx: Rule context, with `ANDROID_NATIVE_LIBS_ATTRS` and the `PORTABLE`
            exec group.
        tools: The `FlutterExecToolsInfo` of the host the action runs on.
        abi: Android ABI string (e.g. "arm64-v8a").
        libs: `.so` files, and `.zip` files of them (an AAR's native
            libraries, as rules_android extracts them).
        name: The name of the stamp file, unique in the package.

    Returns:
        The validation stamp the build must produce.
    """
    validated = ctx.actions.declare_file(name)

    # Every path is an argument, so path mapping can rewrite it.
    args = ctx.actions.args()
    args.add(ctx.file._validate_tool)
    args.add("--abi", abi)
    args.add("--machine", str(android_elf_machine_for_abi(abi)))
    if abi in _SIXTEEN_KB_ABIS and not ctx.attr._allow_4kb_aligned_native_libraries[BuildSettingInfo].value:
        args.add("--min-load-align", str(_PAGE_SIZE))
    args.add("--stamp", validated)
    args.add_all(libs)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [args],
        inputs = depset(
            direct = [ctx.file._validate_tool] + libs,
            transitive = [tools.sdk_files.run],
        ),
        outputs = [validated],
        mnemonic = "FlutterValidateNativeLibs",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Validating Android native libs for %s %s" % (abi, ctx.label),
    )
    return validated

def _package_native_libs(ctx, tools, app_info, abi):
    """The app's native libraries as the APK holds them, and their validation.

    One zip of `lib/<abi>/<name>` entries, stored uncompressed: `libapp.so`
    (the AOT output, whatever `gen_snapshot` called it: the engine loads the
    Dart snapshot via `System.loadLibrary("app")`), the `native_deps`
    libraries and the code assets that ship. Which code assets ship is known
    only when a release build's link hooks have run, so the action reads the
    program's assets file, and `android_binary` takes the zip as it takes an
    `aar_import`'s libraries (`AndroidNativeLibsInfo`), for this ABI.

    Every library is stripped as a Gradle build strips the libraries it
    packages (android_strip.bzl), in every build mode: an APK or AAR carries
    no symbol table or debug info of them. The `.symbols` of `libapp.so` are
    the application's `debug_info`.

    Every library is validated (`validate_android_native_libs`) before the APK
    is packaged: a library a device cannot load fails the build instead of
    producing an APK that crashes on device. Two libraries under one name fail
    the packaging action: the APK could hold only one of them.

    Args:
        ctx: Rule context.
        tools: The `FlutterExecToolsInfo` of the host the action runs on.
        app_info: The application's `FlutterApplicationInfo`.
        abi: Android ABI string (e.g. "arm64-v8a").

    Returns:
        A tuple of the zip and the validation stamp the build must produce.
    """
    unstripped = ctx.actions.declare_file("%s_native_libs/unstripped.zip" % ctx.label.name)
    code_assets = program_assets_action_args(ctx.actions, app_info.program_assets, data = False)
    args = ctx.actions.args()
    args.add("--abi", abi)
    args.add("--output", unstripped)
    if app_info.aot_output:
        args.add("--library-as", "libapp.so")
        args.add(app_info.aot_output)
    args.add_all(native_library_files(app_info), before_each = "--library")
    run_code_assets_tool(
        ctx,
        "android-libs",
        [args, code_assets.args],
        depset(
            ([app_info.aot_output] if app_info.aot_output else []) + list(native_library_files(app_info)),
            transitive = [code_assets.inputs],
        ),
        [unstripped],
        mnemonic = "FlutterAndroidNativeLibs",
        progress_message = "Packaging the %s native libraries of %%{label}" % abi,
    )
    zip = ctx.actions.declare_file("%s_native_libs/libs.zip" % ctx.label.name)
    run_strip_native_libs(
        ctx,
        inputs = [unstripped],
        libs = [zip],
        mnemonic = "FlutterStripNativeLibs",
        progress_message = "Stripping the %s native libraries of %%{label}" % abi,
    )
    validated = validate_android_native_libs(
        ctx,
        tools,
        abi,
        [zip],
        ctx.label.name + "_native_libs.validated",
    )
    return zip, validated

# -- The configurations of an APK's ABIs ---------------------------------------

def _abi_split_impl(settings, _attr):
    """The configurations `android_binary` builds its native code in, one for each ABI.

    Exactly the settings rules_android's `android_split_transition` changes
    (`rules/android_split_transition.bzl`, private to rules_android): each
    platform of `--@rules_android//flags:android_platforms` (or of Bazel's
    native `--android_platforms`) as the only one, those flags cleared, and
    `--dynamic_mode=off`. With none, the one platform of `--platforms`. So the
    application is built in the configurations the APK's native libraries
    already are, and not again.

    rules_android's transition also sets its `//rules/flags:bytecode_transformer`
    from a `bytecode_transformer` attribute of the rule it is on. None of its
    rules has one (through 0.8.1), so its split leaves the flag as it is, and
    so does this one.
    """
    platforms = android_utils.get_android_platforms({
        android_utils.ANDROID_PLATFORMS_SETTING: settings[_ANDROID_PLATFORMS_SETTING],
        android_utils.add_cls_prefix("android_platforms"): settings[android_utils.add_cls_prefix("android_platforms")],
    })
    if not platforms:
        platforms = [android_utils.only(android_utils.get_cls(settings, "platforms"))]
    result = {}
    for platform in platforms:
        split = dict(settings)
        split[android_utils.add_cls_prefix("android_platforms")] = []
        split[_ANDROID_PLATFORMS_SETTING] = []
        split[android_utils.add_cls_prefix("platforms")] = [platform]
        split[android_utils.add_cls_prefix("dynamic_mode")] = "off"
        result[platform.name] = split
    return result

# rules_android's flag, which its own transitions name relative to rules_android.
_ANDROID_PLATFORMS_SETTING = str(Label("@rules_android//flags:android_platforms"))

_SPLIT_SETTINGS = [
    "//command_line_option:android_platforms",
    _ANDROID_PLATFORMS_SETTING,
    "//command_line_option:dynamic_mode",
    "//command_line_option:platforms",
]

_abi_split = transition(
    implementation = _abi_split_impl,
    inputs = _SPLIT_SETTINGS,
    outputs = _SPLIT_SETTINGS,
)

def _own_split(ctx):
    """The key of the split of `application` built for this bundle's own platform.

    `android_binary` builds itself, and so its `assets`, for the first
    platform of its ABIs, and each of its native-code dependencies for one
    ABI. Either way that is a key of the split. Built any other way, the
    bundle is for no ABI the split has, and fails.
    """
    splits = ctx.split_attr.application
    own = ctx.fragments.platform.platform
    if own.name in splits:
        return own.name
    fail((
        "{label} is built for {platform}, which is none of the Android platforms its application " +
        "is split for ({splits}). Build it through an android_binary, or for one Android platform " +
        "of --@rules_android//flags:android_platforms."
    ).format(label = ctx.label, platform = own, splits = ", ".join(sorted(splits.keys()))))

def _apk_assets(ctx, tools, flutter_assets, additions):
    """The flutter_assets tree at `<name>/assets/flutter_assets/`, as an APK holds it.

    That is the layout `android_binary` takes with `assets_dir = "assets"`.
    The tree is the application's, symlinked, or, with `additions` (name and
    file pairs placed at its root), a copy that holds them too.
    """

    # Under the label name: two bundles in one package (a Tier 1 macro's and
    # an explicit Tier 2 one) must not declare the same directory.
    out = ctx.actions.declare_directory(ctx.label.name + "/assets/flutter_assets")
    if not additions:
        ctx.actions.symlink(output = out, target_file = flutter_assets)
        return out
    assemble_directory(
        ctx,
        tools,
        out,
        [("tree", ".", flutter_assets)] + [("file", name, file) for name, file in additions],
        mnemonic = "FlutterAndroidAssets",
        progress_message = "Assembling the flutter_assets of %{label}",
    )
    return out

def _merged_manifest(ctx):
    """The native-assets manifest of every ABI the APK has, or None for one ABI.

    Each ABI's build names its own target alone, and an APK has one
    `flutter_assets` for all of them, so it carries one manifest naming each
    ABI's code assets under its target, as flutter_tools writes it.
    """
    splits = ctx.split_attr.application
    if len(splits) < 2:
        return None
    merged = ctx.actions.declare_file(ctx.label.name + "_native_assets/NativeAssetsManifest.json")
    args = ctx.actions.args()
    args.add("--output", merged)
    inputs = []
    for key, app in splits.items():
        info = app[FlutterApplicationInfo]
        args.add("--manifest", key)
        args.add(info.native_assets_manifest)
        inputs.append(info.native_assets_manifest)
    run_code_assets_tool(
        ctx,
        "merge-manifests",
        [args],
        depset(inputs),
        [merged],
        mnemonic = "FlutterNativeAssetsManifestMerge",
        progress_message = "Merging the native-assets manifests of %{label}",
    )
    return merged

def _flutter_android_bundle_impl(ctx):
    """Bundles Flutter compilation outputs for Android packaging."""
    application = ctx.split_attr.application[_own_split(ctx)]
    app_info = application[FlutterApplicationInfo]
    tools = portable_tools(ctx)
    abi = _android_abi(ctx)

    # The engine must have been built for the app's ABI, and an app of a
    # custom SDK keeps the record of the checked pieces it was built from.
    sdk_record = ctx.attr._sdk_record[FlutterSdkRecordInfo]
    check_android_engine(ctx.label, sdk_record, abi)

    # A debug app runs on the JIT: the engine looks for `kernel_blob.bin` in
    # flutter_assets/, as `flutter build apk --debug` puts it, and the VM
    # snapshots there serve the kernel service isolate (hot reload and
    # expression evaluation).
    additions = []
    if app_info.kernel_dill and not app_info.aot_output:
        additions += [
            ("kernel_blob.bin", app_info.kernel_dill),
            ("vm_snapshot_data", tools.vm_isolate_snapshot),
            ("isolate_snapshot_data", tools.isolate_snapshot),
        ]
    if sdk_record.record:
        additions.append(("flutter_sdk.json", sdk_record.record))
    merged = _merged_manifest(ctx)
    if merged:
        additions.append(("NativeAssetsManifest.json", merged))
    flutter_assets = _apk_assets(ctx, tools, app_info.flutter_assets, additions)

    packaged, validated = _package_native_libs(ctx, tools, app_info, abi)

    outputs = [flutter_assets, packaged]

    return [
        DefaultInfo(files = depset(outputs)),
        # What `android_binary` packages, for the ABI it builds this for: the
        # libraries an `aar_import` brings arrive the same way. The empty
        # `CcInfo` is what makes this a dependency `android_binary` accepts.
        AndroidNativeLibsInfo(native_libs = depset([packaged])),
        CcInfo(),
        FlutterAndroidBundleLibsInfo(plugin_libraries = sorted({
            record.library.basename: None
            for record in plugin_native_libraries(app_info)
        }.keys())),
        OutputGroupInfo(
            native_libs = depset([packaged]),
            flutter_assets = depset([flutter_assets]),
            # The `.symbols` of each ABI's `libapp.so` the app ships: built
            # in `android_binary`'s own configuration (its `assets`), the
            # application is split one an ABI, as the APK's native code is.
            debug_info = depset(transitive = [
                bundled_program_info(app)[0].debug_info
                for app in ctx.split_attr.application.values()
            ]),
            _validation = depset([validated]),
        ),
    ] + (
        # The application's `debug_info` group, built for this ABI: the
        # `.symbols` of the `libapp.so` above, for what packages the bundle
        # to pass on (`android_binary` passes on no group of its deps').
        bundled_program_info(application)
    )

flutter_android_bundle = rule(
    implementation = _flutter_android_bundle_impl,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing the compiled artifacts.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
            cfg = _abi_split,
        ),
        "_sdk_record": attr.label(
            default = "//flutter/private:sdk_record",
            providers = [FlutterSdkRecordInfo],
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    } | ANDROID_NATIVE_LIBS_ATTRS | ASSEMBLE_DIRECTORY_ATTRS | CODE_ASSETS_TOOL_ATTRS | STRIP_ATTRS,
    # Packaging copies and checks what the application built, the same bytes on
    # any host. Stripping takes the NDK's tool, in an exec group of its own.
    exec_groups = PORTABLE_EXEC_GROUPS | STRIP_EXEC_GROUPS,
    fragments = ["cpp", "platform"],
    doc = """Bundles Flutter compilation outputs for Android packaging.

Put it in an `android_binary`'s `deps`: it provides the app's native libraries
(`libapp.so`, the `native_deps` libraries and the code assets that ship) as
`AndroidNativeLibsInfo`, one zip of `lib/<abi>/<name>` entries, as an
`aar_import` does; the zip is also its `native_libs` output group. Its
`flutter_assets` output group is the app's flutter_assets tree, at
`<name>/assets/flutter_assets/` as an APK holds it: give it to the
`android_binary`'s `assets`, with `assets_dir = "assets"`. Built there, in
the `android_binary`'s own configuration, its native-assets manifest names
the code assets of every ABI of the APK, each built in the configuration the
APK's native libraries of that ABI are.

The bundle is built for the Android platform `android_binary` builds it for,
one for each of `--@rules_android//flags:android_platforms`, and takes its ABI from that platform;
the application behind it is built for the same platform, so the AOT compile
and all native deps target Android with no further flag. An APK for several
ABIs therefore carries `libapp.so` of each. Native libraries are stripped
with the NDK's `llvm-strip --strip-unneeded`, as a Gradle build strips them in
every build type, and validated to be ELF for the platform's ABI at packaging
time. With
`--@rules_dart//dart:split_debug_info`, it provides the `.symbols` of the
snapshot it packages as `BundledProgramInfo`, which `flutter_android_aar`
passes on, and in its `debug_info` output group those of every ABI it is
split for: in the `android_binary`'s own configuration, every ABI of the APK.
The `flutter_android_bundle`
macro makes it incompatible with a platform that is not Android arm, arm64 or
x86_64; reached any other way on such a platform, it fails, naming the flag
to pass.""",
)
