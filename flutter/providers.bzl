"""Providers for Flutter rules."""

FlutterSdkInfo = provider(
    doc = "Information about the Flutter engine provided by the toolchain.",
    fields = {
        "version": "str: The Flutter SDK version string (e.g. `3.41.2`).",
        "engine_revision": "str: The engine commit hash.",
        "dart": "File: The `dart` executable from the Flutter-bundled Dart SDK.",
        "dartaotruntime": "File: The `dartaotruntime` executable for running AOT snapshots.",
        "gen_snapshot": "File: The `gen_snapshot` AOT compiler binary.",
        "flutter_tester": "File or None: The `flutter_tester` binary — a headless Flutter engine " +
                          "used to run widget tests (`flutter_test` rule). None if the host SDK " +
                          "doesn't include it (e.g. cross-compilation targets).",
        "frontend_server": "File: The `frontend_server_aot.dart.snapshot` for kernel compilation.",
        "platform_kernel_dill": "File: `platform_strong.dill` — the debug platform kernel.",
        "platform_kernel_dill_product": "File: `platform_strong_product.dill` — the release platform kernel.",
        "patched_sdk": "Target: The Flutter patched Dart SDK root directory.",
        "icu_data": "File: `icudtl.dat` — ICU data file required by the engine.",
        "tool_files": "depset[File]: All files needed to run Flutter build tools (for use in action inputs).",
        "engine_library": "Target or None: The platform-specific Flutter engine runtime library " +
                          "(FlutterMacOS.framework, libflutter_linux_gtk.so, flutter_windows.dll). " +
                          "None for mobile/web or when engine runtime is not downloaded.",
        "const_finder": "File or None: The `const_finder.dart.snapshot` for icon tree shaking.",
        "font_subset": "File or None: The `font-subset` binary for font subsetting.",
        "impellerc": "File or None: The `impellerc` shader compiler binary.",
        "shader_lib": "list[File]: Shader include files for impellerc (shader_lib/ directory contents).",
        "material_icons_font": "File or None: MaterialIcons-Regular.otf font file.",
        "vm_isolate_snapshot": "File or None: `vm_isolate_snapshot.bin` — VM bootstrap snapshot for debug mode.",
        "isolate_snapshot": "File or None: `isolate_snapshot.bin` — isolate bootstrap snapshot for debug mode (includes kernel service).",
        "target_os": "str: Cross-compilation target OS, or empty for native.",
        "target_arch": "str: Cross-compilation target architecture, or empty for native.",
        "linux_sysroot": "Target or None: Chromium sysroot filegroup for hermetic Linux GTK3 builds. None on non-Linux platforms.",
    },
)

FlutterInfo = provider(
    doc = "Information about a Flutter library's sources, dependencies, and assets.",
    fields = {
        "asset_dirs": "depset[File]: Directories containing Flutter assets.",
        "shader_srcs": "depset[File]: Raw shader source files (.frag/.glsl) to compile per-platform.",
        "plugins": "list[struct]: Plugin metadata. Each struct has: name (str), platforms (dict of platform -> {pluginClass, dartPluginClass, package}).",
        "transitive_native_libs": "depset[File]: Shared libs from plugin native_deps, merged transitively.",
        "apple_plugin_libraries": "depset[struct]: Apple plugin swift_libraries. Each struct has: platform (str: 'macos' | 'ios'), label (Label), cc_info (CcInfo or None), swift_info (SwiftInfo or None), package (str: pub package name). Used by the runner aggregator to merge per-platform link/compile inputs.",
        "linux_plugin_libraries": "depset[struct]: Linux plugin source bundles. Each struct has: label (Label), srcs (depset[File]), hdrs (depset[File]), include_dirs (depset[str]), package (str). The Linux runner folds these into its compile.",
        "windows_plugin_libraries": "depset[struct]: Windows plugin source bundles. Each struct has: label (Label), srcs (depset[File]), hdrs (depset[File]), include_dirs (depset[str]), package (str). The Windows runner folds these into its compile.",
        "android_plugin_libraries": "depset[struct]: Android plugin libraries. Each struct has: label (Label), package (str). flutter_android_application adds the labels to the android_binary's deps.",
        "apple_privacy_manifests": "depset[File]: Apple `PrivacyInfo.xcprivacy` files contributed by transitive plugins. Apple requires every framework to ship one since iOS 17.4 / macOS 14.4; the macOS / iOS application rules bundle them into `Contents/Resources/<pkg>/PrivacyInfo.xcprivacy` (or the iOS analog) so App Store submission's privacy aggregator picks them up.",
        "native_assets": "depset[FlutterNativeAssetInfo]: Per-target Native Assets `CodeAsset` declarations contributed by transitive `flutter_native_asset` rules.",
        "data_assets": "depset[FlutterDataAssetInfo]: Per-package Native Assets `DataAsset` declarations contributed by transitive `flutter_data_asset` rules.",
        "pub_fonts": "depset[struct]: Per-package font declarations from pub `flutter.fonts`. Each struct has: package_name (str — empty string sentinel for non-package contributions like the toolchain MaterialIcons target), family (str), fonts (list[struct(asset, weight, style)]), files (list[File] — the .ttf/.otf File objects matching the asset paths). Bundle aggregator prefixes family + asset paths with `packages/<pkg>/` only when package_name is non-empty.",
        "pub_assets": "depset[struct]: Per-package asset files from pub `flutter.assets`. Each struct has: package_name (str — empty sentinel for non-package), asset_path (str — as declared in pubspec, before any prefixing), file (File). Bundle aggregator places them at `packages/<pkg>/<asset_path>` (or bare `asset_path` for empty package_name).",
        "pub_shaders": "depset[struct]: Per-package shader files from pub `flutter.shaders`. Same shape as pub_assets but routes through the shader compile pipeline before bundling.",
    },
)

FlutterNativeAssetInfo = provider(
    doc = "A single Native Assets `CodeAsset` declaration captured by `flutter_native_asset`.",
    fields = {
        "asset_id": "str: The Dart asset id (e.g. `package:objective_c/objective_c.dylib`).",
        "link_mode": "str: One of `dynamic_loading_bundle`, `dynamic_loading_system`, `dynamic_loading_executable`, `dynamic_loading_process`.",
        "files": "depset[File]: Files to bundle into the application. Empty for non-bundled link modes.",
        "target_os": "str: Target OS this asset applies to (`macos`, `ios`, `linux`, `windows`, `android`).",
        "bundle_filename": "str: Filename inside the platform bundle slot (e.g. `objective_c.dylib`). Empty for non-bundled link modes.",
        "system_uri": "str: System library URI for `dynamic_loading_system`. Empty otherwise.",
    },
)

FlutterDataAssetInfo = provider(
    doc = "A single Native Assets `DataAsset` declaration captured by `flutter_data_asset`.",
    fields = {
        "asset_id": "str: The Dart asset id (e.g. `package:my_pkg/blob.bin`).",
        "package": "str: The pub package name (parsed from `asset_id`).",
        "name": "str: The within-package asset name (everything after the package).",
        "file": "File: The on-disk asset file. Bundled at `flutter_assets/data/<package>/<name>`.",
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
        "bundled_data_assets": "depset[FlutterDataAssetInfo]: Native-Assets `DataAsset` declarations to bundle under `flutter_assets/data/<pkg>/<name>`.",
        "apple_privacy_manifests": "depset[File]: Aggregated Apple `PrivacyInfo.xcprivacy` files from transitive plugins. The macOS / iOS application rules thread these into `additional_contents` of the bundle so Apple's App Store submission validator sees the merged privacy declaration.",
    },
)
