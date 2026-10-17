"""Providers for Flutter rules."""

FlutterSdkInfo = provider(
    doc = """Information about the Flutter engine provided by the toolchain.

Core host fields (`version`, `engine_revision`, `dart`, `dartaotruntime`, \
`flutter_tester`, `frontend_server`, `platform_kernel_dill`, `patched_sdk`, \
`icu_data`, `impellerc`, `shader_lib`, `vm_isolate_snapshot`, \
`isolate_snapshot`, `tool_files`, `dart_vm_files`, `dart_pub_files`, \
`dart2wasm_files`, `dart2js_files`, `target_os`, `target_arch`) are populated \
directly on `ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info`.

Lazy-fetched fields (`gen_snapshot`, `platform_kernel_dill_product`, \
`const_finder`, `font_subset`, `engine_library`, `linux_sysroot`, \
`material_icons_font`) live on optional sub-toolchains so builds only fetch \
the repositories they need. Custom rules that read those fields should \
declare `toolchains = ["@rules_flutter//flutter:toolchain_type"] + FLUTTER_OPTIONAL_TOOLCHAINS` \
(or the specific sub-toolchain types they need) and call \
`resolve_flutter_sdk_info(ctx)`.""",
    fields = {
        "version": "str: The Flutter SDK version string (e.g. `3.41.2`).",
        "engine_revision": "str: The engine commit hash.",
        "dart": "File: Deprecated. The `dart` executable from the Flutter-bundled Dart SDK. " +
                "Prefer `@rules_dart//dart:exec_tools_toolchain_type` (`resolve_exec_dart(ctx)`).",
        "dartaotruntime": "File: The `dartaotruntime` executable for running AOT snapshots.",
        "gen_snapshot": "File or None: The `gen_snapshot` AOT compiler binary (resolved via `@rules_flutter//flutter:aot_toolchain_type` and `resolve_flutter_sdk_info`).",
        "flutter_tester": "File or None: The `flutter_tester` binary — a headless Flutter engine " +
                          "used to run widget tests (`flutter_test` rule). None if the host SDK " +
                          "doesn't include it (e.g. cross-compilation targets).",
        "frontend_server": "File: The `frontend_server_aot.dart.snapshot` for kernel compilation.",
        "platform_kernel_dill": "File: `platform_strong.dill` — the debug platform kernel.",
        "platform_kernel_dill_product": "File or None: `platform_strong_product.dill` — the release platform kernel (resolved via `@rules_flutter//flutter:product_tools_toolchain_type` and `resolve_flutter_sdk_info`).",
        "patched_sdk": "Target: The Flutter patched Dart SDK root directory.",
        "icu_data": "File: `icudtl.dat` — ICU data file required by the engine.",
        "tool_files": "depset[File]: Deprecated. All files in the bundled Dart SDK and patched SDK. " +
                      "Prefer action-specific sets (`dart_vm_files`, `dart_pub_files`, `dart2wasm_files`, `dart2js_files`).",
        "dart_vm_files": "depset[File]: Host Dart SDK files required for `dart` to run a precompiled kernel snapshot (e.g. `const_finder.dart.snapshot`).",
        "dart_pub_files": "depset[File]: Host Dart SDK files required for `dart pub`.",
        "dart2wasm_files": "depset[File]: Host Dart SDK files required for `dart compile wasm`.",
        "dart2js_files": "depset[File]: Host Dart SDK files required for `dart compile js`.",
        "engine_library": "Target or None: The platform-specific Flutter engine runtime library " +
                          "(FlutterMacOS.framework, libflutter_linux_gtk.so, flutter_windows.dll). " +
                          "None for mobile/web or when engine runtime is not downloaded (resolved via `@rules_flutter//flutter:desktop_engine_toolchain_type` and `resolve_flutter_sdk_info`).",
        "const_finder": "File or None: The `const_finder.dart.snapshot` for icon tree shaking (resolved via `@rules_flutter//flutter:product_tools_toolchain_type` and `resolve_flutter_sdk_info`).",
        "font_subset": "File or None: The `font-subset` binary for font subsetting (resolved via `@rules_flutter//flutter:product_tools_toolchain_type` and `resolve_flutter_sdk_info`).",
        "impellerc": "File or None: The `impellerc` shader compiler binary.",
        "shader_lib": "list[File]: Shader include files for impellerc (shader_lib/ directory contents).",
        "material_icons_font": "File or None: MaterialIcons-Regular.otf font file (resolved via `@rules_flutter//flutter:material_icons_toolchain_type` and `resolve_flutter_sdk_info`).",
        "vm_isolate_snapshot": "File or None: `vm_isolate_snapshot.bin` — VM bootstrap snapshot for debug mode.",
        "isolate_snapshot": "File or None: `isolate_snapshot.bin` — isolate bootstrap snapshot for debug mode (includes kernel service).",
        "target_os": "str: Cross-compilation target OS, or empty for native.",
        "target_arch": "str: Cross-compilation target architecture, or empty for native.",
        "linux_sysroot": "Target or None: Chromium sysroot filegroup for hermetic Linux GTK3 builds. None on non-Linux platforms (resolved via `@rules_flutter//flutter:desktop_engine_toolchain_type` and `resolve_flutter_sdk_info`).",
    },
)

FLUTTER_OPTIONAL_TOOLCHAINS = [
    config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
    config_common.toolchain_type("@rules_flutter//flutter/private:aot_toolchain_type", mandatory = False),
    config_common.toolchain_type("@rules_flutter//flutter/private:desktop_engine_toolchain_type", mandatory = False),
    config_common.toolchain_type("@rules_flutter//flutter/private:material_icons_toolchain_type", mandatory = False),
    config_common.toolchain_type("@rules_flutter//flutter/private:font_subset_toolchain_type", mandatory = False),
]

_DART_EXEC_TOOLS_TOOLCHAIN_TYPE = "@rules_dart//dart:exec_tools_toolchain_type"

def _lookup_sub_toolchain(ctx, private_type, public_type):
    if private_type in ctx.toolchains:
        return ctx.toolchains[private_type]
    if public_type in ctx.toolchains:
        return ctx.toolchains[public_type]
    return None

def resolve_flutter_sdk_info(ctx):
    """Resolves `FlutterSdkInfo` from the primary toolchain and any optional sub-toolchains.

    Preserves every field on the primary `FlutterSdkInfo` generically and overlays
    `platform_kernel_dill_product`, `const_finder`, `font_subset`, `gen_snapshot`,
    `engine_library`, `linux_sysroot`, and `material_icons_font` from any optional
    sub-toolchains declared on the rule.
    """
    flutter_toolchain = ctx.toolchains["@rules_flutter//flutter:toolchain_type"]
    info = flutter_toolchain.flutter_sdk_info

    product_tc = _lookup_sub_toolchain(
        ctx,
        "@rules_flutter//flutter/private:product_tools_toolchain_type",
        "@rules_flutter//flutter:product_tools_toolchain_type",
    )
    aot_tc = _lookup_sub_toolchain(
        ctx,
        "@rules_flutter//flutter/private:aot_toolchain_type",
        "@rules_flutter//flutter:aot_toolchain_type",
    )
    desktop_tc = _lookup_sub_toolchain(
        ctx,
        "@rules_flutter//flutter/private:desktop_engine_toolchain_type",
        "@rules_flutter//flutter:desktop_engine_toolchain_type",
    )
    material_tc = _lookup_sub_toolchain(
        ctx,
        "@rules_flutter//flutter/private:material_icons_toolchain_type",
        "@rules_flutter//flutter:material_icons_toolchain_type",
    )
    font_subset_tc = _lookup_sub_toolchain(
        ctx,
        "@rules_flutter//flutter/private:font_subset_toolchain_type",
        "@rules_flutter//flutter:font_subset_toolchain_type",
    )

    if not product_tc and not aot_tc and not desktop_tc and not material_tc and not font_subset_tc:
        return info

    fields = {
        k: getattr(info, k)
        for k in dir(info)
        if k not in ("to_json", "to_proto")
    }
    if product_tc:
        for k in ("platform_kernel_dill_product", "const_finder", "font_subset"):
            if not fields.get(k):
                fields[k] = getattr(product_tc, k, None)
    if font_subset_tc:
        for k in ("const_finder", "font_subset"):
            if not fields.get(k):
                fields[k] = getattr(font_subset_tc, k, None)
    if aot_tc and not fields.get("gen_snapshot"):
        fields["gen_snapshot"] = getattr(aot_tc, "gen_snapshot", None)
    if desktop_tc:
        for k in ("engine_library", "linux_sysroot"):
            if not fields.get(k):
                fields[k] = getattr(desktop_tc, k, None)
    if material_tc and not fields.get("material_icons_font"):
        fields["material_icons_font"] = getattr(material_tc, "material_icons_font", None)

    return FlutterSdkInfo(**fields)

def resolve_exec_dart(ctx, flutter_sdk_info = None):
    """Resolves the host `dart` executable from `@rules_dart//dart:exec_tools_toolchain_type`.

    Falls back to `flutter_sdk_info.dart` when the Dart exec-tools toolchain is
    not declared or not resolved (for example in unit tests with synthetic
    toolchains).

    Args:
      ctx: Rule context.
      flutter_sdk_info: Optional pre-resolved `FlutterSdkInfo` for the fallback path.

    Returns:
      The `dart` executable `File`.
    """
    if _DART_EXEC_TOOLS_TOOLCHAIN_TYPE in ctx.toolchains:
        dart_tc = ctx.toolchains[_DART_EXEC_TOOLS_TOOLCHAIN_TYPE]
        if dart_tc and getattr(dart_tc, "dart_sdk_info", None) and dart_tc.dart_sdk_info.dart:
            return dart_tc.dart_sdk_info.dart
    if flutter_sdk_info == None:
        flutter_sdk_info = resolve_flutter_sdk_info(ctx)
    return flutter_sdk_info.dart

def resolve_exec_dart_vm(ctx, flutter_sdk_info = None):
    """Resolves `(dart_exe, runtime_files_depset)` for running a `.dill` tool on the exec platform.

    Prefers `@rules_dart//dart:exec_tools_toolchain_type` (`dart_sdk_info.dart`
    and `dart_sdk_info.runtime_files`), falling back to `flutter_sdk_info.dart`
    and `flutter_sdk_info.dart_vm_files`.

    Args:
      ctx: Rule context.
      flutter_sdk_info: Optional pre-resolved `FlutterSdkInfo` for the fallback path.

    Returns:
      A tuple `(dart_exe, runtime_files_depset)`.
    """
    if _DART_EXEC_TOOLS_TOOLCHAIN_TYPE in ctx.toolchains:
        dart_tc = ctx.toolchains[_DART_EXEC_TOOLS_TOOLCHAIN_TYPE]
        if dart_tc and getattr(dart_tc, "dart_sdk_info", None) and dart_tc.dart_sdk_info.dart:
            return dart_tc.dart_sdk_info.dart, dart_tc.dart_sdk_info.runtime_files
    if flutter_sdk_info == None:
        flutter_sdk_info = resolve_flutter_sdk_info(ctx)
    return flutter_sdk_info.dart, flutter_sdk_info.dart_vm_files

FlutterInfo = provider(
    doc = """The channels a Flutter library contributes to its consumers.

Read this directly off any target that provides it. To *build* one, call \
`flutter_info()` from `//flutter/private:flutter_info.bzl` rather than this \
constructor: it takes what a target contributes itself and merges every \
dependency's values internally, so a field added here needs no change in the \
rules that produce `FlutterInfo`. Constructing it here means enumerating and \
merging each field by hand, and a field left empty rather than forwarded \
silently discards every dependency's contribution.""",
    fields = {
        "asset_dirs": "depset[File]: Directories containing Flutter assets.",
        "shader_srcs": "depset[File]: Raw shader source files (.frag/.glsl) to compile per-platform.",
        "plugins": "list[struct]: Plugin metadata. Each struct has: name (str), platforms (dict of platform -> {pluginClass, dartPluginClass, package}).",
        "transitive_native_libs": "depset[File]: Shared libs from plugin native_deps, merged transitively.",
        "native_lib_sources": "depset[struct]: Per library, the first-party sources it is built from — `native_deps` entries and Native Asset libraries alike. Each struct has: library (File), sources (tuple[File]). A hot reload stats these to notice that a library went stale in an app whose reload runs no build of its own; see `native_sources.bzl`.",
        "binding_contracts": "depset[struct]: Per-library binding contracts contributed by transitive `flutter_native_library` wrappers in a plugin's `native_deps`. Each struct has: library (File), contract (tuple[File]). Paired rather than flattened because the dev tool's question is per library — a rebuilt library whose contract is unchanged may still take an increment, and one with no contract may not.",
        "apple_plugin_libraries": "depset[struct]: Apple plugin swift_libraries. Each struct has: platform (str: 'macos' | 'ios'), label (Label), cc_info (CcInfo or None), swift_info (SwiftInfo or None), package (str: pub package name). Used by the runner aggregator to merge per-platform link/compile inputs.",
        "linux_plugin_libraries": "depset[struct]: Linux plugin source bundles. Each struct has: label (Label), srcs (depset[File]), hdrs (depset[File]), include_dirs (depset[str]), package (str). The Linux runner folds these into its compile.",
        "windows_plugin_libraries": "depset[struct]: Windows plugin source bundles. Each struct has: label (Label), srcs (depset[File]), hdrs (depset[File]), include_dirs (depset[str]), package (str). The Windows runner folds these into its compile.",
        "apple_privacy_manifests": "depset[File]: Apple `PrivacyInfo.xcprivacy` files contributed by transitive plugins. Apple requires every framework to ship one since iOS 17.4 / macOS 14.4; the macOS / iOS application rules bundle them into `Contents/Resources/<pkg>/PrivacyInfo.xcprivacy` (or the iOS analog) so App Store submission's privacy aggregator picks them up.",
        "native_assets": "depset[FlutterNativeAssetInfo]: Per-target Native Assets `CodeAsset` declarations contributed by transitive `flutter_native_asset` rules.",
        "data_assets": "depset[FlutterDataAssetInfo]: Per-package Native Assets `DataAsset` declarations contributed by transitive `flutter_data_asset` rules.",
        "pub_fonts": "depset[struct]: Per-package font declarations from pub `flutter.fonts`. Each struct has: package_name (str — empty string sentinel for non-package contributions like the toolchain MaterialIcons target), family (str), fonts (list[struct(asset, weight, style)]), files (list[File] — the .ttf/.otf File objects matching the asset paths). Bundle aggregator prefixes family + asset paths with `packages/<pkg>/` only when package_name is non-empty.",
        "pub_assets": "depset[struct]: Per-package asset files from pub `flutter.assets`. Each struct has: package_name (str — empty sentinel for non-package), asset_path (str — as declared in pubspec, before any prefixing), file (File). Bundle aggregator places them at `packages/<pkg>/<asset_path>` (or bare `asset_path` for empty package_name).",
        "pub_shaders": "depset[struct]: Per-package shader files from pub `flutter.shaders`. Same shape as pub_assets, plus `includes` (the files the shader may `#include`), and routed through the shader compile pipeline before bundling.",
    },
)

FlutterNativeAssetInfo = provider(
    doc = "A single Native Assets `CodeAsset` declaration captured by `flutter_native_asset`.",
    fields = {
        "asset_id": "str: The Dart asset id (e.g. `package:objective_c/objective_c.dylib`).",
        "link_mode": "str: One of `dynamic_loading_bundle`, `dynamic_loading_system`, `dynamic_loading_executable`, `dynamic_loading_process`.",
        "file": "File or None: The shared library to bundle into the application. None for non-bundled link modes.",
        "bundle_filename": "str: Filename inside the platform bundle slot (e.g. `objective_c.dylib`). Empty for non-bundled link modes.",
        "system_uri": "str: System library URI for `dynamic_loading_system`. Empty otherwise.",
    },
)

FlutterNativeLibraryInfo = provider(
    doc = """A native library in `native_deps` together with the contract its bindings were built against.

Produced by `flutter_native_library` and read where the dev config is written. A
`native_deps` entry without one is an ordinary shared library: the app bundles it
and nothing says what calling into it is supposed to look like, which is what
makes a rebuilt copy of it stop a hot reload rather than merely be reported.
""",
    fields = {
        "libraries": "depset[File]: The shared libraries (.so/.dylib/.dll) this entry contributes.",
        "binding_contract": "depset[File]: Files whose bytes decide what the generated bindings may call and how they encode a call. The dev tool compares these bytes and never parses them.",
        "hot_patch": "struct or None: What builds patches of these libraries for a running app — `manifest` (File, the `*.hot_patch.json`) and `files` (depset[File], everything the `hot_patch` target builds, the manifest included). None when the wrapper names no `hot_patch`.",
    },
)

FlutterDataAssetInfo = provider(
    doc = "A single Native Assets `DataAsset` declaration captured by `flutter_data_asset`.",
    fields = {
        "asset_id": "str: The Dart asset id (e.g. `package:my_pkg/blob.bin`).",
        "package": "str: The pub package name (parsed from `asset_id`).",
        "name": "str: The within-package asset name (everything after the package).",
        "file": "File: The on-disk asset file. Bundled at `flutter_assets/packages/<package>/<name>`.",
    },
)

FlutterApplicationInfo = provider(
    doc = "Outputs of the Flutter application compilation pipeline.",
    fields = {
        "aot_output": "File or None: The AOT compiled native code (.so, .dylib, or .S). None in debug mode.",
        "kernel_dill": "File or None: The kernel .dill file for JIT mode. None in release mode.",
        "flutter_assets": "File: The flutter_assets/ tree artifact.",
        "icu_data": "File: The icudtl.dat file.",
        "native_libs": "list[File]: Shared libraries from native_deps (for dart:ffi).",
        "is_debug": "bool: True if built in debug/JIT mode.",
        "package_config": "File: The package_config.json for the frontend server.",
        "native_assets_manifest": "File or None: The `native_assets.json` manifest passed to the frontend_server via `--native-assets`. Always emitted (empty manifest when there are no Native Assets).",
        "bundled_code_assets": "depset[File]: Native-Assets `CodeAsset` library files (.dylib/.so/.dll) to embed in the platform bundle. Each platform application rule reads this and threads the files into the platform's existing embedding mechanism.",
        "bundled_data_assets": "depset[FlutterDataAssetInfo]: Native-Assets `DataAsset` declarations to bundle under `flutter_assets/packages/<pkg>/<name>`.",
        "apple_privacy_manifests": "depset[File]: Aggregated Apple `PrivacyInfo.xcprivacy` files from transitive plugins. The macOS / iOS application rules thread these into `additional_contents` of the bundle so Apple's App Store submission validator sees the merged privacy declaration.",
        "plugins": "list[struct]: Deduplicated plugin metadata aggregated from the application's whole dependency graph. Each struct has: name (str), platforms (dict of platform -> {pluginClass, dartPluginClass, package}). The per-platform registrant generators read this to emit `GeneratedPluginRegistrant`.",
        "apple_plugin_libraries": "depset[struct]: Aggregated Apple plugin swift_libraries, same shape as `FlutterInfo.apple_plugin_libraries`. Read by the runner aggregator to merge per-platform link/compile inputs.",
        "linux_plugin_libraries": "depset[struct]: Aggregated Linux plugin source bundles, same shape as `FlutterInfo.linux_plugin_libraries`. The Linux runner folds these into its compile.",
        "windows_plugin_libraries": "depset[struct]: Aggregated Windows plugin source bundles, same shape as `FlutterInfo.windows_plugin_libraries`. The Windows runner folds these into its compile.",
    },
)

FlutterCompiledShadersInfo = provider(
    doc = "Pre-compiled shaders from transitive dependencies, keyed by bundle path.",
    fields = {
        "compiled_shaders": "depset[struct]: Structs with `bundle_path` (str), `file` (File), and `target_platform` (str) of compiled shaders.",
    },
)

FlutterDarwinFrameworkInfo = provider(
    doc = "Metadata and files for an Apple .framework or .xcframework slice consumed by the xtool backend.",
    fields = {
        "framework_name": "str: Framework module/binary name (e.g. 'Flutter', 'FlutterMacOS', 'App').",
        "framework_dir": "str or None: Path to the .framework directory (or parent -F search dir).",
        "framework_files": "depset[File]: All files belonging to the .framework bundle.",
        "headers": "depset[File]: Public header files exposed by the framework.",
        "is_dynamic": "bool: True if this is a dynamic framework that must be embedded in Frameworks/.",
    },
)

FlutterApplePluginInfo = provider(
    doc = "Carries Apple plugin Swift/ObjC sources, headers, modulemap, and target platform ('ios' or 'macos').",
    fields = {
        "module_name": "str: Swift/Clang module name of the plugin.",
        "platform": "str: Target platform ('ios' or 'macos').",
        "swift_srcs": "depset[File]: Swift source Files.",
        "objc_srcs": "depset[File]: Objective-C/C++ source Files.",
        "headers": "depset[File]: Header Files.",
        "modulemap": "File or None: Generated Clang modulemap file.",
        "sdk_frameworks": "list[str]: Linked Apple SDK frameworks.",
        "sdk_dylibs": "list[str]: Linked Apple SDK dylibs.",
    },
)
