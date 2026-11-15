"""Providers for Flutter rules."""

FlutterSdkInfo = provider(
    doc = "Information about the Flutter engine provided by the toolchain.",
    fields = {
        "version": "str: The Flutter SDK version string, as `flutter --version` reports it.",
        "engine_revision": "str: The engine commit hash.",
        "dart": "File: The `dart` executable from the Flutter-bundled Dart SDK.",
        "dartaotruntime": "File: The `dartaotruntime` executable for running AOT snapshots.",
        "gen_snapshot": "File or None: The `gen_snapshot` AOT compiler binary. None in debug mode, " +
                        "which compiles no snapshot, and for a toolchain that cannot compile one.",
        "flutter_tester": "File or None: The `flutter_tester` binary — a headless Flutter engine " +
                          "used to run widget tests (`flutter_test` rule). None if the host SDK " +
                          "doesn't include it (e.g. cross-compilation targets).",
        "frontend_server": "File: The `frontend_server_aot.dart.snapshot` for kernel compilation.",
        "kernel_worker": "File or None: `kernel_worker_aot.dart.snapshot`, which compiles one " +
                         "library target to a kernel module. None where `flutter_tester` is None.",
        "dart_libraries_json": "File: The Dart SDK's own `lib/libraries.json`, from which a " +
                               "`libraries.json` naming the dart: libraries a Flutter program can " +
                               "import is derived (`flutter_kernel_sdk`).",
        "platform_kernel_dill": "File: `platform_strong.dill` — the debug platform kernel.",
        "platform_kernel_dill_product": "File or None: `platform_strong_product.dill` — the release platform kernel. None in debug mode.",
        "patched_sdk": "Target: The Flutter patched Dart SDK root directory.",
        "sdk_defines": "list[str]: The `FLUTTER_VERSION`, `FLUTTER_FRAMEWORK_REVISION`, ... defines that describe " +
                       "the SDK's framework and engine (`sdk_defines.bzl`).",
        "sdk": "str: The name of the SDK this toolchain belongs to (`flutter`, the stock release, or the " +
               "name of a declared one).",
        "host_tools": "FlutterHostToolsInfo: The host tools slice the toolchain was assembled from.",
        "kernel_debug": "FlutterPlatformKernelInfo: The debug (non-product) platform kernel slice.",
        "kernel_release": "FlutterPlatformKernelInfo or None: The release (product) platform kernel slice. None in debug mode.",
        "engine": "FlutterEngineInfo or None: The engine slice `engine_library` is the target of.",
        "gen_snapshot_info": "FlutterGenSnapshotInfo or None: The gen_snapshot slice `gen_snapshot` is the binary of.",
        "framework_json": "File or None: The `flutter_framework.json` of the SDK's framework when it is not the release's.",
        "slice_labels": "dict[str, str]: The label of each slice the toolchain was assembled from, by role " +
                        "(`host_tools`, `platform_kernel`, `engine`, `gen_snapshot`).",
        "icu_data": "File: `icudtl.dat` — ICU data file required by the engine.",
        "tool_files": "depset[File]: Every file of the bundled Dart SDK and of the patched SDK, " +
                      "for running any SDK command (`dart pub`). An action that runs one tool " +
                      "takes only that tool's files from `sdk_files`: each input is linked into " +
                      "a sandbox and, remotely, hashed and staged, and the SDK is ~1,050 files.",
        "sdk_files": "DartSdkFilesInfo: The bundled Dart SDK's files by the use that reads them " +
                     "(`run`, `aot_run`, `kernel`, `dart2js`, `dart2wasm`, ...), as rules_dart " +
                     "declares them. `gen_snapshot` needs none of them.",
        "engine_library": "Target or None: The platform-specific Flutter engine runtime library " +
                          "(FlutterMacOS.framework, libflutter_linux_gtk.so, flutter_windows.dll) of the " +
                          "build mode: debug under `-c dbg`, profile under " +
                          "`--@rules_flutter//flutter:profile` where the toolchain has one, release " +
                          "otherwise. None for mobile/web or when engine runtime is not downloaded.",
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

FlutterSdkRecordInfo = provider(
    doc = "What an app records of the SDK it was built with: the record file, which is " +
          "written only when the framework or the engine is not the release's.",
    fields = {
        "record": "File or None: `flutter_sdk.json`, bundled into the app's `flutter_assets`.",
        "engine_label": "str: The label of the engine slice the app links, or empty.",
        "engine_cpus": "list[str]: The CPUs that engine contains, or empty where the app has none to check.",
        "engine_xcframework_slices": "list[str]: iOS only: the platform directories of that engine's Flutter.xcframework.",
    },
)

FlutterExecToolsInfo = provider(
    doc = "The Flutter SDK tools that run on one host and produce the same output " +
          "whatever the target platform: kernel compiles, shader and asset " +
          "bundling, web compiles, and `flutter_tester`. Provided by the " +
          "`@rules_flutter//flutter:exec_tools_toolchain_type` toolchain, which " +
          "constrains only the execution platform.",
    fields = {
        "version": "str: The Flutter SDK version string, as `flutter --version` reports it.",
        "engine_revision": "str: The engine commit hash.",
        "host_os": "str: The OS these tools run on (`macos`, `linux`, `windows`).",
        "host_arch": "str: The CPU these tools run on (`arm64`, `x64`).",
        "dart": "File: The `dart` executable from the Flutter-bundled Dart SDK.",
        "dartaotruntime": "File: The `dartaotruntime` executable for running AOT snapshots.",
        "frontend_server": "File: The `frontend_server_aot.dart.snapshot` for kernel compilation.",
        "kernel_worker": "File: `kernel_worker_aot.dart.snapshot`, which compiles one library target to a kernel module.",
        "dart_libraries_json": "File: The Dart SDK's own `lib/libraries.json`.",
        "platform_kernel_dill": "File: `platform_strong.dill` — the debug platform kernel.",
        "platform_kernel_dill_product": "File or None: `platform_strong_product.dill` — the release platform kernel.",
        "patched_sdk": "Target: The Flutter patched Dart SDK root directory.",
        "sdk_defines": "list[str]: The defines that describe the SDK's framework and engine.",
        "sdk": "str: The name of the SDK these tools belong to.",
        "host_tools": "FlutterHostToolsInfo: The host tools slice these were assembled from.",
        "flutter_tester": "File: The `flutter_tester` headless engine that runs widget tests.",
        "icu_data": "File: `icudtl.dat`, the ICU data `flutter_tester` loads.",
        "vm_isolate_snapshot": "File: `vm_isolate_snapshot.bin`, the VM bootstrap snapshot a debug app ships.",
        "isolate_snapshot": "File: `isolate_snapshot.bin`, the isolate bootstrap snapshot a debug app ships.",
        "font_subset": "File: The `font-subset` binary for font subsetting.",
        "impellerc": "File: The `impellerc` shader compiler binary.",
        "shader_lib": "list[File]: Shader include files for impellerc (shader_lib/ directory contents).",
        "shader_include_dir": "str: The execution path of the directory holding `shader_lib`, which " +
                              "impellerc takes as `--include`. A source directory, so path mapping " +
                              "leaves it as it is.",
        "sdk_files": "DartSdkFilesInfo: The bundled Dart SDK's files by the use that reads them " +
                     "(`run`, `aot_run`, `kernel`, `dart2js`, `dart2wasm`, ...). An action takes " +
                     "only its tool's set: `run` for a `dart script.dart` step, and for a front " +
                     "end the files it names itself.",
    },
)

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
        "shader_srcs": "depset[File]: The Flutter framework's own shader sources (.frag/.glsl), compiled per platform and bundled at `shaders/<file name>`. A package's shaders are `pub_shaders`.",
        "plugins": "list[struct]: Plugin metadata. Each struct has: name (str), platforms (dict of platform -> FlutterPluginPlatformInfo), dependencies (list[str]: the plugins its package depends on directly).",
        "transitive_native_libs": "depset[File]: Shared libs from plugin native_deps, merged transitively.",
        "native_lib_sources": "depset[struct]: Per `native_deps` library, the first-party sources it is built from (a code asset's are found by `code_asset_libraries.bzl`). Each struct has: library (File), sources (tuple[File]). A hot reload stats these to notice that a library went stale in an app whose reload runs no build of its own; see `native_sources.bzl`.",
        "binding_contracts": "depset[struct]: Per-library binding contracts contributed by transitive `flutter_native_library` wrappers in a plugin's `native_deps`. Each struct has: library (File), contract (tuple[File]). Paired rather than flattened because the dev tool's question is per library — a rebuilt library whose contract is unchanged may still take an increment, and one with no contract may not.",
        "apple_plugin_libraries": "depset[struct]: Apple plugin swift_libraries. Each struct has: platform (str: 'macos' | 'ios'), label (Label), cc_info (CcInfo or None), swift_info (SwiftInfo or None), package (str: pub package name). Used by the runner aggregator to merge per-platform link/compile inputs.",
        "linux_plugin_libraries": "depset[struct]: Linux plugin source bundles. Each struct has: label (Label), srcs (depset[File]), hdrs (depset[File]), include_dirs (depset[str]), linkopts (list[str]), link_errors (list[str]), package (str). The Linux runner folds these into its compile and link.",
        "windows_plugin_libraries": "depset[struct]: Windows plugin source bundles. Each struct has: label (Label), srcs (depset[File]), hdrs (depset[File]), include_dirs (depset[str]), linkopts (list[str]), link_errors (list[str]), package (str). The Windows runner folds these into its compile and link.",
        "apple_privacy_manifests": "depset[File]: Apple `PrivacyInfo.xcprivacy` files contributed by transitive plugins. Apple requires every framework to ship one since iOS 17.4 / macOS 14.4; the macOS / iOS application rules bundle them into `Contents/Resources/<pkg>/PrivacyInfo.xcprivacy` (or the iOS analog) so App Store submission's privacy aggregator picks them up.",
        "pub_fonts": "depset[struct]: Per-package font declarations from pub `flutter.fonts`. Each struct has: package_name (str — empty string sentinel for non-package contributions like the toolchain MaterialIcons target), package_root (str — the package's root, the directory above `lib/`, as a short_path; None for a non-package contribution), family (str), fonts (tuple[struct(asset_path, of_other_package, file, weight, style)] — each font's path from the package root, or the `packages/<other>/<path>` of a font of another package, whether it is one, and its File). A program keys the family and each font `packages/<pkg>/<...>` unless the package is its own (its root is the program's) or a non-package contribution; a font of another package keeps its path.",
        "pub_assets": "depset[struct]: Per-package asset files: a pub package's `flutter.assets`, and the `assets` of a `flutter_library` or `flutter_plugin`. Each struct has: package_name (str — empty sentinel for non-package), package_root (str — the package's root as a short_path), asset_path (str — the path from the package root, as a pubspec lists it), file (File), platforms (tuple[str] — the platforms its `platforms:` entry restricts it to; empty for all), flavors (tuple[str]). A program bundles each at `packages/<pkg>/<asset_path>`, or at bare `asset_path` when the package is its own (its root is the program's) or the package_name is empty, as `flutter build` keys a dependency's assets and the program's own.",
        "pub_shaders": "depset[struct]: Per-package shader files from pub `flutter.shaders`. Same shape as pub_assets (with `shader_path` for `asset_path`, and `platforms` likewise), plus `includes` (the files the shader may `#include`), and routed through the shader compile pipeline before bundling.",
        "additional_licenses": "depset[struct]: The licence files packages list under `flutter: licenses:`, for `NOTICES`. Each struct has: package_name (str), files (tuple[File] — in the order the package lists them). An application appends them to its `NOTICES` as they are, ordered by package name.",
        "android_libs": "depset[struct]: The Android libraries of the plugins reached, collected transitively. Each struct has: package (str: pub package name), group (str: the `group` of the plugin's Android `flutter_plugin_platform`, empty when unset), lib (Target: one of the plugin's `exports`, which carries `JavaInfo`). Only an Android build selects any, so this is empty on every other platform. `flutter_android_plugin_libs` links these into an application.",
    },
)

FlutterFontInfo = provider(
    doc = "One font file of a font family, with the weight and style a pubspec's `fonts:` entry gives it (`flutter_font`).",
    fields = {
        "file": "File: The font file.",
        "weight": "int or None: Its weight, 100 to 900 in steps of 100; None for none.",
        "style": "str or None: `normal` or `italic`; None for none.",
        "asset": "str or None: `packages/<package>/<path>` when the font is the file `<path>` of another Dart package, as a pubspec's `asset:` names one; None for a file of the package that lists the family.",
    },
)

FlutterFontFamilyInfo = provider(
    doc = "A font family, as an entry of a pubspec's `flutter: fonts:` declares it (`flutter_font_family`).",
    fields = {
        "family": "str: The family name, as the pubspec's `family:` gives it.",
        "fonts": "tuple[FlutterFontInfo]: Its fonts, in the order they are listed.",
    },
)

FlutterPluginPlatformInfo = provider(
    doc = "A plugin's registration for one platform and that platform's native library, as an entry of a pubspec's `flutter: plugin: platforms:` declares it (`flutter_plugin_platform`).",
    fields = {
        "platform": "str: `android`, `ios`, `linux`, `macos`, `web` or `windows`.",
        "plugin_class": "str: `pluginClass`, the class registered with the platform's plugin registry; empty for none.",
        "dart_plugin_class": "str: `dartPluginClass`, the Dart class whose `registerWith()` the Dart plugin registrant calls; empty for none.",
        "dart_file_name": "str: `dartFileName`, the library of `lib/` that declares `dart_plugin_class`; empty for `<package>.dart`.",
        "file_name": "str: `fileName`, the library of `lib/` that declares a web `plugin_class`; empty for `<package>.dart`.",
        "ffi_plugin": "bool: `ffiPlugin`, whether the platform's native code is a library Dart opens through `dart:ffi`.",
        "default_package": "str: `default_package`, the package that implements a federated plugin on this platform; empty for none.",
        "package": "str: `package`, the Java package of an Android `plugin_class`; empty for none.",
        "group": "str: The Maven group an Android plugin is published under in a `flutter_android_aar` repository (Gradle's `group`); empty for none.",
        "lib": "Target or None: The platform's native library, analysed only in a build for that platform.",
    },
)

FlutterNativeLibraryInfo = provider(
    doc = """A native library in `native_deps`, or a code asset, together with the contract its bindings were built against.

Produced by `flutter_native_library` and read where the dev config is written —
off `native_deps` directly, and for a code asset by `code_asset_libraries.bzl`,
which finds the wrapper in its owning package's `code_assets`. A
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

FlutterApplicationInfo = provider(
    doc = "Outputs of the Flutter application compilation pipeline.",
    fields = {
        "aot_output": "File or None: The AOT compiled native code (.so, .dylib, or .S). None in debug mode.",
        "aot_object": "File or None: The relocatable object gen_snapshot wrote beside an Apple `aot_output` (`--macho-object`), which the dylib's debugging map points at and its dSYM is read from. None unless this is an Apple AOT build.",
        "strip_aot": "bool: Whether the shipped AOT binary is stripped of its local symbols. False when `extra_gen_snapshot_options` holds `--no-strip`, as in `flutter build`. An Apple framework rule strips after extracting the dSYM unless this is False.",
        "kernel_dill": "File or None: The kernel .dill file for JIT mode. None in release mode.",
        "flutter_assets": "File: The flutter_assets/ tree artifact.",
        "icu_data": "File: The icudtl.dat file.",
        "native_libs": "list[File]: Shared libraries from native_deps (for dart:ffi).",
        "is_debug": "bool: True if built in debug/JIT mode.",
        "native_assets_manifest": "File or None: The native-assets manifest the app ships as `flutter_assets/NativeAssetsManifest.json`, which the engine resolves `@Native(assetId:)` bindings through: each code asset that ships, by id. Always emitted (an empty map when none ships).",
        "program_assets": "DartProgramAssetsInfo: What the program ships, from rules_dart's program assets operation: the packages' declared assets, or after linking what the link hooks emit and the declared ones of packages without a hook. Its data assets are bundled under `flutter_assets/packages/<pkg>/<name>`; its code assets are placed by each platform's bundler, from what an action reading it (`program_assets_action_args`) finds ships.",
        "apple_privacy_manifests": "depset[File]: Aggregated Apple `PrivacyInfo.xcprivacy` files from transitive plugins. The macOS / iOS application rules thread these into `additional_contents` of the bundle so Apple's App Store submission validator sees the merged privacy declaration.",
        "plugins": "list[struct]: Deduplicated plugin metadata aggregated from the application's whole dependency graph. Each struct has: name (str), platforms (dict of platform -> FlutterPluginPlatformInfo), dependencies (list[str]). In registration order: each plugin after those its package depends on, others by name, as flutter_tools orders them. The per-platform registrant generators read this to emit `GeneratedPluginRegistrant`.",
        "apple_plugin_libraries": "depset[struct]: Aggregated Apple plugin swift_libraries, same shape as `FlutterInfo.apple_plugin_libraries`. Read by the runner aggregator to merge per-platform link/compile inputs.",
        "linux_plugin_libraries": "depset[struct]: Aggregated Linux plugin source bundles, same shape as `FlutterInfo.linux_plugin_libraries`. The Linux runner folds these into its compile.",
        "windows_plugin_libraries": "depset[struct]: Aggregated Windows plugin source bundles, same shape as `FlutterInfo.windows_plugin_libraries`. The Windows runner folds these into its compile.",
        "android_libs": "depset[struct]: Aggregated Android plugin libraries, same shape as `FlutterInfo.android_libs`: only the plugins this application depends on. `flutter_android_plugin_libs` links these into the APK.",
    },
)

FlutterApplicationInputsInfo = provider(
    doc = "The program a `flutter_application` compiled, as the value its analysis ran over: what `flutter_application_variant` changes and compiles again.",
    fields = {
        "inputs": "struct: `flutter_program_inputs` of the application. `label` is the application's own, and with it the package that `package:<name>/…` imports and asset keys are in; `main`, `srcs`, `assets` and the other source fields are Files; `deps`, `native_deps` and `code_assets` are the Targets the application's attributes named, with the providers its aspects attached.",
    },
)

FlutterLinuxRuntimeInfo = provider(
    doc = "The X server, GTK, Mesa and libraries a Linux integration test runs with, in place of the host's: a `flutter_linux_runtime`. A Linux runner of the desktop or web family carries it.",
    fields = {
        "files": "depset[File]: everything the runtime is, for the test's runfiles.",
        "libraries": "depset[File]: the runtime's files a program it runs may load, which a check of another program's needs is given.",
        "config": "struct: JSON-able runfiles paths for the host runner: `root` (the runtime's `/`), `triple` (the multiarch directory of its libraries), `xvfb` and `fontsConf`.",
        "floor": "dict: the newest symbol version of each host library a file may ask for (`GLIBC` to `2.39`): the oldest host supported.",
    },
)

FlutterIntegrationRunnerInfo = provider(
    doc = "Where an integration test runs: the family of device, what the host runner needs to reach one, and how the test is placed. Returned by the runner rules (`flutter_desktop_runner` and the others) and read by the test rule of the same family.",
    fields = {
        "family": "string: `\"web\"`, `\"desktop\"`, `\"ios_simulator\"` or `\"android\"`. A test rule takes only a runner of its own family.",
        "launcher_config": "struct: JSON-able settings for the host runner, which are the family's own (Chrome's runfiles path, a simulator's device type and runtime, an emulator's image).",
        "runfiles": "depset[File]: what the runner needs at run time beside the app (a Chrome, an emulator, a system image).",
        "execution_requirements": "dict: the test's `execution_requirements`. `no-remote` and `no-sandbox` for every family but web: the app runs on this machine, in this machine's session, or on a device attached to it. A web test runs a headless browser of its own and has neither.",
        "target_compatible_with": "list[Label]: the platforms the runner works on, which a macro puts on the test it declares.",
    },
)

FlutterTestProgramInfo = provider(
    doc = """A compiled Flutter test program: what `flutter_tester` runs, with everything the runner needs beside it. Returned by `flutter_test_program`, and by any rule that compiles a test of its own; `flutter_program_test` runs the program.

The kernel's entry point speaks the `package:test_api` `RemoteListener` protocol over the WebSocket named by `FLUTTER_TEST_HARNESS_PORT`, as the bootstrap `flutter_test_program` generates does.""",
    fields = {
        "kernel": "File: the kernel flutter_tester is started with: one `.dill`, or, when `kernel_list` is true, a list of the kernels in `kernels`, which the runner joins into one when it starts flutter_tester.",
        "kernel_list": "bool: whether `kernel` is a list of kernels rather than a kernel.",
        "kernels": "depset[File]: the kernels `kernel` names, when it is a list; empty otherwise.",
        "assets": "File: the `flutter_assets` directory the test runs with: shaders, fonts and the package assets that `rootBundle` reads.",
        "tester": "File: the `flutter_tester` that runs the kernel, for the platform the program is built for.",
        "icu_data": "File: the ICU data `flutter_tester` is given.",
        "display_path": "string: the suite's path in the runner's reports.",
        "source": "File: the test library's source, which the runner reads for its `@Tags` annotations.",
        "packages": "list[DartPackageInfo]: every package the program runs, its own included, by which `bazel coverage` finds the file of each library it reports.",
        "native_assets_manifest": "File: the Native Assets manifest the kernel was compiled with (`dart:ffi` `@Native` resolution).",
        "native_files": "list[string]: runfiles paths of the native-asset libraries the runner puts on the loader's search path (Windows); empty elsewhere.",
        "enable_impeller": "bool: whether the test renders with Impeller.",
        "target_os": "string: the OS the program is built for (`macos`, `linux`, `windows`, ...).",
        "runfiles": "runfiles: everything the program needs when it runs, less the runner itself: the kernels, `flutter_tester`, the ICU data, the assets, the source, native-asset libraries and `data` (goldens included). Every File above is in it.",
    },
)
