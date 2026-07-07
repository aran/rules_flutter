# rules_flutter

> **Status: v0.0.1 — early/alpha.** Usable today, but the public API may change before 1.0. Feedback and contributions welcome.

Bazel rules for building Flutter applications. Provides Bazel-native compilation, asset bundling, AOT compilation, and platform-specific packaging for all Flutter target platforms.

Built on top of [rules_dart](https://github.com/aran/rules_dart) for Dart compilation and delegates platform packaging to mature ecosystem rulesets (`rules_android`, `rules_apple`, etc.).

## Why Bazel?

If you're already using `flutter build`, here's what you gain by switching to Bazel:

- **Hermetic, reproducible builds** — every input is tracked; the same source always produces the same output, regardless of machine state.
- **Remote caching** — build artifacts are content-addressed and shared across your team. A change that only touches one package doesn't rebuild anything else.
- **Remote Build Execution (RBE)** — offload compilation to cloud workers. Build macOS, Linux, and Android targets from the same `bazel build` invocation.
- **Monorepo interoperability** — Flutter apps, backend services, Rust libraries, C++ libraries, and infrastructure code all live in one build graph with correct dependency tracking.
- **Native code composition** — depend on `cc_library`, `rust_shared_library`, or `swift_library` targets directly via `native_deps`. No CMake, no Gradle, no CocoaPods.
- **No build_runner** — code generators (json_serializable, freezed, etc.) run as hermetic Bazel actions via `dart_codegen`.

## Compatibility

- **Bazel**: 9+
- **Flutter SDK**: 3.44.1

## Prerequisites

| Platform | Requirements |
|----------|-------------|
| All | Bazel 9+ |
| macOS | Xcode (for `rules_apple` and `rules_swift`) |
| iOS | Xcode + valid signing identity (simulator works without signing) |
| Android | Android SDK (`$ANDROID_HOME` set), Android NDK (`$ANDROID_NDK_HOME` set), rules_android, rules_android_ndk, rules_kotlin |
| Linux | C++ toolchain (native or LLVM cross-toolchain from macOS) |
| Windows | MSVC (native builds), or C++ cross-toolchain (debug JIT only from macOS/Linux) |
| Web | None (Dart-to-WASM/JS compilation is fully hermetic) |

## Required `.bazelrc`

rules_flutter's transitive Java toolchain (`rules_jvm_external` 7+, `rules_android` 0.7.2+) ships internal tool jars compiled at Java 21+ and uses Java 14+ language features in its sources. Bazel's defaults for the tool exec configuration are older than that, so without setting them explicitly you will hit either `UnsupportedClassVersionError` at action execution time or `could not locate class file for java.lang.Record` at compile time.

Windows builds additionally require Bazel symlink support, which `rules_python` 2.0+ depends on.

Paste this block into your project's `.bazelrc`:

```bazelrc
# Required for rules_flutter — bumps the tool exec JDK above Bazel's
# `remotejdk_11` default so transitive rulesets' Java 21+ tool jars run.
common --tool_java_language_version=25
common --tool_java_runtime_version=remotejdk_25

# Required on Windows for rules_python 2+.
startup --windows_enable_symlinks
```

## Quickstart

Add the following to your `MODULE.bazel`:

```starlark
bazel_dep(
    name = "rules_flutter",
    version = <latest from registry.bazel.build/modules/rules_flutter>,
)

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(flutter_version = "3.44.1")
use_repo(flutter, "flutter_toolchains")

register_toolchains("@flutter_toolchains//:all")
```

Then in your `BUILD.bazel`:

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_application", "flutter_library")

flutter_library(
    name = "my_lib",
    srcs = glob(["lib/**/*.dart"]),
    assets = glob(["assets/**"]),
)

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = [":my_lib"],
)
```

`flutter_application` is the core compilation target shared by all platforms. It produces a `FlutterApplicationInfo` provider that platform-specific packaging rules consume.

`package_name` is required — it matches `pubspec.yaml`'s `name:` field, keys the kernel under stable `package:` URIs for hot reload, and lets the compile reach codegen siblings.

## Debug vs Release Builds

Build mode is controlled by Bazel's standard compilation mode flag:

| Flag | Mode | Compilation | Use case |
|------|------|-------------|----------|
| `-c dbg` | Debug | Kernel `.dill` (JIT) | Development, hot reload |
| (default) | Fastbuild | AOT native code | CI, testing |
| `-c opt` | Release | AOT native code (stripped) | Production |

## Cross-Compilation

`gen_snapshot` (the AOT compiler) is a cross-compiler: it runs on the host but produces code for the target. Different binaries exist per host/target pair.

### Host-to-Target Matrix

| Host | Target | AOT (release) | JIT (debug) | Notes |
|------|--------|:---:|:---:|-------|
| macOS | macOS | Yes | Yes | Native build |
| macOS | iOS | Yes | Yes | Via `rules_apple` platform transition |
| macOS | Android | Yes | Yes | `--platforms=...:android_arm64` |
| macOS | Linux | No | Yes | Cross-compile with LLVM CC toolchain; JIT only (no cross gen_snapshot for desktop) |
| macOS | Windows | No | Yes | JIT only; requires Windows CC cross-toolchain |
| macOS | Web | Yes | N/A | Web uses dart2wasm/dart2js, not gen_snapshot |
| Linux | Linux | Yes | Yes | Native build |
| Linux | Android | Yes | Yes | `--platforms=...:android_arm64` |
| Linux | iOS | No | No | Requires Xcode (macOS only) |
| Linux | Web | Yes | N/A | |
| Windows | Windows | Yes | Yes | Native build |
| Windows | Android | Yes | Yes | `--platforms=...:android_arm64` |
| Windows | Web | Yes | N/A | |

**Key limitation:** Desktop-to-desktop AOT cross-compilation (e.g. macOS→Linux release) is not supported because Flutter does not publish cross-gen_snapshot binaries for desktop targets. Use debug/JIT mode for cross-compiled desktop bundles, or build natively on the target platform.

## Platform Rules

Each platform has a **Tier 1 convenience macro** (recommended) and **Tier 2 composable rules** (advanced).

The Tier 1 macros auto-discover runner files from `flutter create` output and wire up all internal targets. The Tier 2 rules give full control over each component.

### macOS

> **macOS only** — requires Xcode and `rules_apple`.

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = [":my_lib"],
)

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    app_name = "My App",
)
```

**Prerequisites:** Run `flutter create --platforms=macos .` to generate `macos/Runner/` with Swift sources and XIB files.

| Attribute | Description |
|-----------|-------------|
| `application` | A `flutter_application` target (required). |
| `bundle_id` | macOS bundle identifier (required). |
| `app_name` | Display name (menu bar, window title). Defaults to target name. |
| `minimum_os_version` | Minimum macOS version. Default: `"10.14"`. |
| `info_plist` | Override the conventional `macos/Runner/Info.plist`. |
| `version` | An `apple_bundle_version` target. Defaults to `"1.0"`. |

Produces a `.app` bundle with `FlutterMacOS.framework`, `App.framework`, and `flutter_assets/`.

<details>
<summary>Advanced: Tier 2 composable rules</summary>

For full control over the macOS bundle (custom runner, custom framework layout, etc.):

```starlark
load("@rules_flutter//flutter:macos.bzl",
    "flutter_macos_engine",
    "flutter_macos_framework_gen",
    "flutter_macos_info_plist_gen",
    "flutter_macos_menu_xib_gen",
    "flutter_macos_native_libs_gen",
    "flutter_macos_registrant_gen",
    "flutter_macos_runner_lib_gen")

flutter_macos_framework_gen(name = "my_framework", application = ":my_app")
flutter_macos_registrant_gen(name = "my_registrant", application = ":my_app")
flutter_macos_engine(name = "my_engine")
flutter_macos_native_libs_gen(name = "my_native_libs", application = ":my_app")
flutter_macos_info_plist_gen(name = "my_info_plist", app_name = "My App")
flutter_macos_menu_xib_gen(name = "my_menu_xib", app_name = "My App")

flutter_macos_runner_lib_gen(
    name = "my_runner",
    registrant = ":my_registrant",
    engine = ":my_engine",
)

macos_application(
    name = "my_macos_app",
    bundle_id = "com.example.myapp",
    additional_contents = {
        ":my_framework": "Frameworks",
        ":my_native_libs": "Frameworks",
    },
    infoplists = [":my_info_plist"],
    resources = [":my_menu_xib"],
    deps = [":my_runner"],
)
```

</details>

### iOS

> **macOS only** — requires Xcode, `rules_apple`, and `rules_swift`.

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_app")

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = [":my_lib"],
)

flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
)
```

**Prerequisites:** Run `flutter create --platforms=ios .` to generate `ios/Runner/` with Swift sources.

Add to your `MODULE.bazel`:

```starlark
use_repo(flutter, "flutter_toolchains", "flutter_ios_engine")
```

| Attribute | Description |
|-----------|-------------|
| `application` | A `flutter_application` target (required). |
| `bundle_id` | iOS bundle identifier (required). |
| `families` | Device families. Default: `["iphone"]`. |
| `app_name` | Display name. Defaults to target name. |
| `minimum_os_version` | Minimum iOS version. Default: `"12.0"`. |
| `info_plist` | Override conventional `ios/Runner/Info.plist`. |
| `version` | An `apple_bundle_version` target. Defaults to `"1.0"`. |
| `launch_storyboard` | Override launch storyboard. |

The platform transition to iOS arm64 is handled automatically by `rules_apple`'s `ios_application`.

<details>
<summary>Advanced: Tier 2 composable rules</summary>

```starlark
load("@rules_flutter//flutter:ios.bzl",
    "flutter_ios_engine",
    "flutter_ios_framework_gen",
    "flutter_ios_info_plist_gen",
    "flutter_ios_registrant_gen",
    "flutter_ios_runner_lib_gen")

flutter_ios_framework_gen(name = "my_framework", application = ":my_app")
flutter_ios_registrant_gen(name = "my_registrant", application = ":my_app")
flutter_ios_engine(name = "my_engine")
flutter_ios_info_plist_gen(name = "my_info_plist", app_name = "My App")

flutter_ios_runner_lib_gen(
    name = "my_runner",
    registrant = ":my_registrant",
    engine = ":my_engine",
)

ios_application(
    name = "my_ios_app",
    bundle_id = "com.example.myapp",
    families = ["iphone"],
    minimum_os_version = "12.0",
    deps = [":my_framework", ":my_runner"],
)
```

</details>

### Android

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
load("@rules_flutter//flutter:android.bzl", "flutter_android_app")

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = [":my_lib"],
)

flutter_android_app(
    name = "my_app_android",
    application = ":my_app",
    package_name = "com.example.myapp",
)
```

**Prerequisites:** Run `flutter create --platforms=android .` to generate `android/app/src/main/` with manifest, resources, and Kotlin sources. The macro handles everything automatically — no edits to the `flutter create` output needed.

Add to your `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_android_ndk", version = "0.1.5")

use_repo(flutter, "flutter_toolchains", "flutter_android_engine_arm64")

# Android NDK CC toolchain (required for --platforms=android_arm64).
android_ndk_repository_extension = use_extension(
    "@rules_android_ndk//:extension.bzl",
    "android_ndk_repository_extension",
)
use_repo(android_ndk_repository_extension, "androidndk")
register_toolchains("@androidndk//:all")
```

Set `ANDROID_NDK_HOME` to your NDK path (e.g. in `.bazelrc.user`: `build --action_env=ANDROID_NDK_HOME=/path/to/ndk`).

Build with cross-compilation:

```sh
bazel build //:my_app_android --platforms=@rules_flutter//flutter/platforms:android_arm64
```

| Attribute | Description |
|-----------|-------------|
| `application` | A `flutter_application` target (required). |
| `package_name` | Android package name, e.g. `"com.example.myapp"` (required). |
| `app_name` | Display name. Defaults to target name. |
| `android_abi` | Engine ABI — `"arm64"` (default), `"x64"`, or `"arm"`. |
| `min_sdk_version` | Minimum Android SDK version. |
| `target_sdk_version` | Target Android SDK version. |
| `manifest` | Override AndroidManifest.xml (auto-discovered from `flutter create` output or generated). |
| `multidex` | Multidex mode. Default: `"native"`. |

<details>
<summary>Advanced: Tier 2 composable rules</summary>

For full control over the Android build (custom manifest, custom runner activity, etc.):

```starlark
load("@rules_flutter//flutter:android.bzl",
    "flutter_android_bundle",
    "flutter_android_engine",
    "flutter_android_manifest_gen",
    "flutter_android_runner_lib_gen")
load("@rules_android//android:rules.bzl", "android_binary")

flutter_android_bundle(name = "my_bundle", application = ":my_app")
flutter_android_engine(name = "my_engine")
flutter_android_manifest_gen(name = "my_manifest", package_name = "com.example.myapp")

flutter_android_runner_lib_gen(
    name = "my_runner",
    package_name = "com.example.myapp",
    engine = ":my_engine",
)

android_binary(
    name = "my_apk",
    manifest = ":my_manifest",
    multidex = "native",
    deps = [":my_bundle_native_libs", ":my_engine", ":my_runner"],
)
```

`flutter_android_bundle` output groups:

| Group | Contents |
|-------|----------|
| `native_libs` | `libapp.so` (AOT) + any `native_deps` shared libraries |
| `flutter_assets` | `flutter_assets/` tree |
| `mobile_install` | JNI-structured symlinks + assets for `bazel mobile-install` |

</details>

### Linux

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
load("@rules_flutter//flutter:linux.bzl", "flutter_linux_app")

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = [":my_lib"],
)

flutter_linux_app(
    name = "my_app_linux",
    application = ":my_app",
    gtk_app_id = "com.example.myapp",
)
```

**Prerequisites:** Run `flutter create --platforms=linux .` to generate `linux/runner/` with C++ sources. If no runner files are found, the built-in template is used automatically.

Cross-compile from macOS (debug/JIT only):

```sh
bazel build //:my_app_linux -c dbg --platforms=@rules_flutter//flutter/platforms:linux_x64
```

| Attribute | Description |
|-----------|-------------|
| `application` | A `flutter_application` target (required). |
| `app_name` | Binary name. Defaults to target name. |
| `gtk_app_id` | GTK application identifier. Default: `"com.example.flutter"`. |

Output directory structure:

```
my_app/
  my_app                     (GTK runner executable)
  lib/
    libapp.so                (AOT-compiled Dart code)
    libflutter_linux_gtk.so  (Flutter engine)
    *.so                     (native plugin libraries, if any)
  data/
    flutter_assets/          (fonts, images, shaders, asset manifest)
    icudtl.dat               (ICU internationalization data)
```

<details>
<summary>Advanced: Tier 2 composable rules</summary>

```starlark
load("@rules_flutter//flutter:linux.bzl",
    "flutter_linux_bundle",
    "flutter_linux_engine",
    "flutter_linux_registrant_gen",
    "flutter_linux_runner_lib_gen")

flutter_linux_engine(name = "flutter_engine")
flutter_linux_registrant_gen(name = "app_registrant", application = ":my_app")

flutter_linux_runner_lib_gen(
    name = "my_runner",
    engine = ":flutter_engine",
    registrant = ":app_registrant",
    gtk_app_id = "com.example.myapp",
)

flutter_linux_bundle(
    name = "my_linux_app",
    application = ":my_app",
    runner = ":my_runner",
)
```

</details>

### Windows

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
load("@rules_flutter//flutter:windows.bzl", "flutter_windows_app")

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = [":my_lib"],
)

flutter_windows_app(
    name = "my_app_windows",
    application = ":my_app",
)
```

**Prerequisites:** Run `flutter create --platforms=windows .` to generate `windows/runner/` with C++ sources. If no runner files are found, the built-in template is used automatically.

| Attribute | Description |
|-----------|-------------|
| `application` | A `flutter_application` target (required). |
| `app_name` | Binary name. Defaults to target name. |

Output directory structure:

```
my_app/
  my_app.exe             (Win32 runner executable)
  flutter_windows.dll    (Flutter engine)
  app.so                 (AOT-compiled Dart code as ELF)
  data/
    flutter_assets/      (fonts, images, shaders, asset manifest)
    icudtl.dat           (ICU internationalization data)
```

<details>
<summary>Advanced: Tier 2 composable rules</summary>

```starlark
load("@rules_flutter//flutter:windows.bzl",
    "flutter_windows_bundle",
    "flutter_windows_engine",
    "flutter_windows_registrant_gen",
    "flutter_windows_runner_lib_gen")

flutter_windows_engine(name = "flutter_engine")
flutter_windows_registrant_gen(name = "app_registrant", application = ":my_app")

flutter_windows_runner_lib_gen(
    name = "my_runner",
    engine = ":flutter_engine",
    registrant = ":app_registrant",
)

flutter_windows_bundle(
    name = "my_windows_app",
    application = ":my_app",
    runner = ":my_runner",
)
```

</details>

### Web

```starlark
load("@rules_flutter//flutter:web.bzl", "flutter_web_app")

flutter_web_app(
    name = "my_app_web",
    package_name = "my_app",
    deps = ["@deps//:flutter"],
    app_name = "My App",
)
```

**Prerequisites:** Run `flutter create --platforms=web .` to generate `web/` with `index.html`, `manifest.json`, and icons. If these files don't exist, the built-in templates are used automatically.

Add to your `MODULE.bazel`:

```starlark
use_repo(flutter, "flutter_toolchains", "flutter_web_sdk")
```

> **Note:** Unlike other platforms, web rules take `main` + `deps` (Dart source) directly — not a `flutter_application` target. Web compilation uses dart2wasm/dart2js which have a structurally different pipeline from AOT platforms.

| Attribute | Description |
|-----------|-------------|
| `deps` | `dart_library` or `flutter_library` dependencies (required). |
| `main` | The main `.dart` entry point. Default: `"lib/main.dart"`. |
| `app_name` | Application name for HTML title and manifest. Defaults to target name. |
| `pwa` | Generate service worker for offline support. Default: `True`. |

<details>
<summary>Advanced: Tier 2 composable rules</summary>

For full control over compiler/renderer:

```starlark
load("@rules_flutter//flutter:web.bzl", "flutter_web_bundle")

# WASM (modern, default):
flutter_web_bundle(
    name = "my_app_web",
    main = "lib/main.dart",
    deps = ["@deps//:flutter"],
)

# JavaScript (legacy):
flutter_web_bundle(
    name = "my_app_web_js",
    main = "lib/main.dart",
    compiler = "dart2js",
    renderer = "canvaskit",
    deps = ["@deps//:flutter"],
)
```

</details>

## Core Rules

Loaded from `@rules_flutter//flutter:defs.bzl`.

### `flutter_library`

Collects Flutter/Dart sources and assets. Propagates `DartInfo` and `FlutterInfo` providers to downstream targets. Does not compile — serves as the dependency unit for Flutter packages.

```starlark
flutter_library(
    name = "my_lib",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@pub_deps//:some_package"],
    assets = glob(["assets/**"]),
    package_name = "my_lib",  # optional, defaults to last component of Bazel package path
)
```

| Attribute | Description |
|-----------|-------------|
| `srcs` | Dart source files (mandatory). |
| `deps` | `dart_library` or `flutter_library` dependencies. |
| `assets` | Flutter asset files (images, fonts, etc.). |
| `package_name` | Dart package name. Defaults to the last component of the Bazel package path. |

### `flutter_application`

Core compilation pipeline that chains sources to kernel `.dill`, AOT native code, and asset bundle. Mode-aware: debug (`-c dbg`) produces kernel `.dill` + assets for JIT; release (`-c opt` or default) produces AOT native code + assets.

```starlark
flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = [
        ":my_lib",
        "@rules_flutter//flutter:material_icons",  # if app uses Material widgets
    ],
    native_deps = [":my_native_lib"],  # optional, for dart:ffi
)
```

Apps that use Material widgets must list `@rules_flutter//flutter:material_icons` in `deps` to bundle `MaterialIcons-Regular.otf` into `flutter_assets/`. The font is shipped by the active Flutter toolchain; the dep is the explicit opt-in.

| Attribute | Description |
|-----------|-------------|
| `main` | The main `.dart` entry point (mandatory). |
| `package_name` | Dart package name; same value as `pubspec.yaml`'s `name:` (mandatory). Keys the kernel's libraries under stable `package:` URIs (hot-reload parity), anchors codegen sibling co-location, and resolves `package:<self>/...` imports. |
| `srcs` | Additional Dart source files. |
| `deps` | `dart_library` or `flutter_library` dependencies. Add `@rules_flutter//flutter:material_icons` to bundle the MaterialIcons font. |
| `assets` | Asset files to include in the bundle. |
| `native_deps` | Shared libraries for dart:ffi bundling. |
| `defines` | Dart environment defines (`-D` flags). |
| `profile` | If True, compile in profile mode (AOT, unstripped, with service extensions for profiling). Default: `False`. |
| `obfuscate` | If True, obfuscate Dart symbols in the AOT output. Pair with `split_debug_info`. Default: `False`. |
| `split_debug_info` | If True, extract debug info into a separate `.symbols` file. Default: `False`. |
| `extra_gen_snapshot_options` | Additional flags passed directly to `gen_snapshot`. |
| `track_widget_creation` | If True, track widget creation locations for the DevTools inspector. Default: `False`. |
| `shaders` | Fragment shader files (`.frag`) to compile with impellerc. |
| `tree_shake_icons` | If True, tree-shake icon fonts to only include used glyphs. Default: `True`. |
| `license_files` | License/NOTICE files to include in `NOTICES.Z`. |
| `min_os_version` | Minimum OS deployment target for Apple platforms. Passed to `gen_snapshot` as `--macho-min-os-version`. |

#### Dart defines from the command line

Beyond the per-target `defines` attr, the repeatable build flag `--@rules_flutter//flutter:extra_dart_defines=KEY=VALUE` appends defines to every Dart compile (native kernel, `flutter_test`, dart2wasm/dart2js). One define per flag occurrence, so values may contain commas. On a key collision the flag wins over the attr. The keys `dart.vm.profile` and `dart.vm.product` are reserved (the build sets them from the compilation mode) and rejected. The dev tool's `flutter_bazel run --dart-define KEY=VALUE` forwards to this flag and replays the defines on hot reload/restart recompiles, matching `flutter run --dart-define`.

### `flutter_test`

Compiles and runs Flutter widget/unit tests using the Dart VM with Flutter's platform `.dill`. Tests run with assertions enabled.

```starlark
flutter_test(
    name = "my_test",
    main = "my_test.dart",
    deps = [":my_lib"],
)
```

### `flutter_plugin`

Declares a Flutter plugin with Dart API code and per-platform native implementation dependencies.

```starlark
flutter_plugin(
    name = "url_launcher",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@pub_deps//:flutter"],
    platforms = ["android", "ios", "macos", "linux", "windows", "web"],
    dart_plugin_class = "UrlLauncherPlugin",
    native_deps = select({
        "@platforms//os:linux": [":url_launcher_linux_cc"],
        "@platforms//os:windows": [":url_launcher_windows_cc"],
        "//conditions:default": [],
    }),
)
```

### `flutter_kernel_target`

Compiles Flutter sources to a kernel `.dill` file using Flutter's patched platform kernel. This is the base compilation step shared by all platform targets.

### `flutter_aot_target`

Compiles Flutter sources to an AOT native shared library (`.so` on Linux/Android, `.dylib` on macOS) via `gen_snapshot`.

### `flutter_asset_bundle`

Generates a `flutter_assets/` tree artifact containing `AssetManifest.bin`, `FontManifest.json`, `NOTICES.Z`, and copied asset files.

## Code Generation Rules

Loaded from `@rules_flutter//flutter:codegen.bzl`. These replace `build_runner` with hermetic Bazel actions.

### `dart_codegen`

Per-file code generation. Runs a Dart script or pre-compiled binary as a code generator, producing one output file per input file. Supports persistent Bazel workers to amortize Dart VM startup.

```starlark
load("@rules_flutter//flutter:codegen.bzl", "dart_codegen")

dart_codegen(
    name = "models_generated",
    srcs = ["lib/model.dart", "lib/order.dart"],
    generator = "tools/my_generator.dart",
    output_suffix = ".g.dart",
    use_worker = True,  # optional, enables persistent worker mode
)
```

| Attribute | Description |
|-----------|-------------|
| `srcs` | Input `.dart` source files to process (mandatory). |
| `generator` | A `.dart` script to run as the generator. |
| `generator_bin` | A pre-compiled generator executable (alternative to `generator`). |
| `output_suffix` | Suffix for generated files, e.g. `.g.dart`, `.freezed.dart`. Default: `.g.dart`. |
| `generator_args` | Additional arguments passed to the generator. |
| `data` | Additional data files the generator needs as inputs. |
| `use_worker` | Enable persistent Bazel worker for `.dart` generators. Default: `False`. |

### `dart_aggregate_codegen`

Package-level code generation. Takes all sources in a package and produces a single aggregate output file.

```starlark
load("@rules_flutter//flutter:codegen.bzl", "dart_aggregate_codegen")

dart_aggregate_codegen(
    name = "routes",
    srcs = glob(["lib/**/*.dart"]),
    generator_script = "tools/route_generator.dart",
    output = "lib/router.gr.dart",
)
```

## Pub Integration

Use `rules_dart`'s `pub.from_lock()` to resolve pub packages:

```starlark
# In MODULE.bazel:
pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
pub.from_lock(name = "pub_deps", lock = "//:pubspec.lock")
use_repo(pub, "pub_deps")
```

```starlark
# In BUILD.bazel:
flutter_application(
    name = "app",
    package_name = "app",
    main = "main.dart",
    deps = [
        "@pub_deps//:collection",      # plain Dart package
        ":my_plugin",                   # local Flutter plugin
    ],
)

# For pub packages that are Flutter plugins, wrap them:
flutter_plugin(
    name = "my_plugin",
    deps = ["@pub_deps//:my_plugin"],
    dart_plugin_class = "MyPlugin",
    platforms = ["android", "ios", "macos"],
)
```

See `e2e/plugin_example/` for a complete example.

## Native Interop

Flutter applications can depend on native code built by other Bazel rules. This replaces Flutter's `native_assets` build hook system.

```starlark
cc_shared_library(
    name = "my_native_lib",
    deps = [":my_cc_lib"],
)

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = [":my_lib"],
    native_deps = [":my_native_lib"],
)
```

Works with `rules_cc`, `rules_rust`, and any ruleset that produces shared libraries.

## Providers

### `FlutterSdkInfo`

Provided by the Flutter toolchain. Carries all engine binaries and SDK files needed by custom rules. Access via:

```starlark
flutter_sdk_info = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | `str` | Flutter SDK version string (e.g. `"3.44.1"`). |
| `engine_revision` | `str` | Engine commit hash. |
| `dart` | `File` | The `dart` executable from the Flutter-bundled Dart SDK. |
| `dartaotruntime` | `File` | The `dartaotruntime` executable for running AOT snapshots. |
| `gen_snapshot` | `File` | The `gen_snapshot` AOT compiler binary. |
| `frontend_server` | `File` | The `frontend_server_aot.dart.snapshot` for kernel compilation. |
| `platform_kernel_dill` | `File` | `platform_strong.dill` — debug platform kernel. |
| `platform_kernel_dill_product` | `File` | `platform_strong_product.dill` — release platform kernel. |
| `patched_sdk` | `Target` | Flutter patched Dart SDK root directory. |
| `icu_data` | `File` | `icudtl.dat` — ICU data file required by the engine. |
| `tool_files` | `depset[File]` | All files needed to run Flutter build tools (for action inputs). |
| `engine_library` | `Target or None` | Platform-specific Flutter engine runtime library. `None` for mobile/web. |
| `const_finder` | `File or None` | `const_finder.dart.snapshot` for icon tree shaking. |
| `font_subset` | `File or None` | `font-subset` binary for font subsetting. |
| `impellerc` | `File or None` | `impellerc` shader compiler binary. |
| `shader_lib` | `list[File]` | Shader include files for impellerc. |
| `target_os` | `str` | Cross-compilation target OS, or empty for native. |
| `target_arch` | `str` | Cross-compilation target architecture, or empty for native. |

### `FlutterInfo`

Propagated by `flutter_library` and `flutter_plugin`. Carries transitive assets, plugins, and native libs.

| Field | Type | Description |
|-------|------|-------------|
| `asset_dirs` | `depset[File]` | Directories containing Flutter assets. |
| `plugins` | `list[struct]` | Plugin metadata structs. Each has `name` (str) and `platforms` (dict). |
| `transitive_native_libs` | `depset[File]` | Shared libraries from plugin `native_deps`, merged transitively. |

### `FlutterApplicationInfo`

Propagated by `flutter_application`. Contains the outputs of the compilation pipeline for platform bundling rules to consume.

| Field | Type | Description |
|-------|------|-------------|
| `aot_output` | `File or None` | AOT compiled native code. `None` in debug mode. |
| `kernel_dill` | `File or None` | Kernel `.dill` file for JIT mode. `None` in release mode. |
| `flutter_assets` | `File` | The `flutter_assets/` tree artifact. |
| `icu_data` | `File` | The `icudtl.dat` file. |
| `native_libs` | `list[File]` | Shared libraries from `native_deps` (for dart:ffi). |
| `is_debug` | `bool` | `True` if built in debug/JIT mode. |
| `native_plugin_registrant` | `File or None` | Generated native plugin registrant source file for desktop platforms. |

## Dev Tool

The `tools/dev_tool/` directory contains `flutter_bazel`, a Dart program that handles the iterative development workflow: device management, app installation, hot reload, and hot restart. It speaks the `--machine` JSON-RPC protocol for IDE compatibility with existing Flutter IDE plugins (VS Code, IntelliJ).

### Agent / external-tool control surface

`flutter_bazel run` starts an HTTP control channel by default (disable with `--no-http-control-channel`). External tools — IDE integrations, AI coding agents, end-to-end test harnesses — drive the running app over this channel without needing a TTY.

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- \
  run --target //:my_app --machine
# stdout emits a JSON line: {"event":"http_control_channel","uri":"http://[::1]:PORT","token":"..."}
# stdout also emits {"event":"app.start","appId":"..."} when the app attaches
```

Once the channel is up:

| Endpoint | Verb | Purpose |
| --- | --- | --- |
| `/command?token=<token>` | `POST` | Run a machine-protocol method against a running session. Body: `{"method":"app.<X>", "params":{"appId":"...", ...}}`. |
| `/sessions/{appId}/screenshot/flutter?token=<token>` | `GET` | PNG of the Flutter widget tree (`_flutter.screenshot` via VM service). |
| `/sessions/{appId}/screenshot/native?token=<token>` | `GET` | PNG of the native window (`screencapture` / `scrot` / `adb screencap` / etc.). |

App-driving methods (proxied to the agent extensions registered from the generated plugin registrant, which the engine invokes before `main()` on every launch — so they survive hot restart):

`app.dumpWidgetTree`, `app.tap`, `app.longPress`, `app.doubleTap`, `app.drag`,
`app.scrollIntoView`, `app.enterText`, `app.getText`, `app.getRect`,
`app.waitFor`, `app.waitForAbsent`, `app.pageBack`.

Lifecycle methods: `app.hotReload`, `app.restart`, `app.stop`, `daemon.shutdown`.

**Selecting a widget.** Methods that target a widget (`tap`, `longPress`, `doubleTap`, `drag`, `getRect`, `getText`, `scrollIntoView`, `waitFor`, `waitForAbsent`) take **exactly one** selector — mirroring `flutter_driver`'s finder vocabulary:

| param | matches |
| --- | --- |
| `key` | a widget whose `ValueKey` value equals the string |
| `text` | a `Text`/`EditableText` whose content equals the string |
| `tooltip` | a `Tooltip` whose `message` equals the string |
| `type` | a widget whose runtime type name equals the string (e.g. `ElevatedButton`) |
| `semanticsLabel` | a widget whose semantics label equals the string |

Passing zero or more than one selector returns a clear error. Other params: `durationMs` (longPress/drag/scrollIntoView), `dx`/`dy` (drag/scrollIntoView), `scrollableKey` (scrollIntoView, `ValueKey` only), `text` (enterText), `timeoutMs`.

**Settling and timeouts.** After dispatching input, interaction methods wait until the app is idle (no animations in flight) before returning, so a follow-up `getRect`/`getText` sees post-action layout — the same model as `flutter_driver`. The wait is bounded by `timeoutMs` (default 10000); if the app can't settle within it — e.g. the window is minimized/occluded so the embedder has paused vsync — the method returns a `TimeoutException` error rather than blocking forever. The input is still delivered.

**curl note.** The endpoints speak plain HTTP/1.1; no special flags are needed — `curl -s "$URI/..."` works. (If your `curl` is configured to attempt HTTP/2, add `--http1.1`.)

This means an external agent can: build the app, launch it under `flutter_bazel`, drive an entire user flow (taps, text entry, waits, screenshots) over plain HTTP, and shut it down cleanly — no manual `q` keystroke needed.

## Examples

End-to-end examples are in the `e2e/` directory:

| Directory | Description |
|-----------|-------------|
| `e2e/smoke` | Minimal smoke test for toolchain setup. |
| `e2e/hello_world` | Minimal Flutter app: kernel compilation, AOT, asset bundling, macOS bundle, web build. |
| `e2e/codegen` | Per-file and aggregate code generation with `dart_codegen` and `dart_aggregate_codegen`, including custom generators; doubles as the hot-reload-with-codegen example. |
| `e2e/ffi_example` | `flutter_plugin` with `native_deps` only (FFI, no registration). |
| `e2e/ffi_plugin_example` | `flutter_plugin` with both `dart_plugin_class` and `native_deps`. |
| `e2e/plugin_example` | `flutter_plugin` with `dart_plugin_class` only (Dart-side registration). |
| `e2e/macos_example` | Full macOS app build + bundle structure verification. |
| `e2e/ios_example` | iOS app build (requires Xcode). |
| `e2e/android_example` | Android APK build (3 approaches) + APK content verification + web build. |
| `e2e/linux_example` | Linux desktop app (3 approaches) + bundle structure verification. |
| `e2e/windows_example` | Windows desktop app (3 approaches) + bundle structure verification. |
| `e2e/web_example` | Web app builds (dart2wasm + dart2js) with web_assets. |
| `e2e/cross_compile_example` | Cross-compile Linux bundle from macOS. |
| `e2e/multi_window_example` | Multi-window macOS + multi-scene iOS builds with FlutterEngineGroup. |

### Running an iOS example on a physical device

iOS simulator builds need no code signing and run out of the box (e.g.
`flutter_bazel run -t //:hello_world_ios -d ios-simulator`). Device builds need
signing, which is per-developer and must stay out of version control. Each iOS
example therefore ships a `device.example/` template: copy it to a git-ignored
`device/` package, set your bundle id, and generate a provisioning profile the
same way `flutter run` does (Xcode automatic signing). Then:
`flutter_bazel run -t //device:app -d ios`. See the header of any
`e2e/*/device.example/BUILD.bazel.example` for the exact steps.

## License

See [LICENSE](LICENSE).
