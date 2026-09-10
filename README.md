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
- **Flutter SDK**: 3.47.2

## Prerequisites

| Platform | Requirements |
|----------|-------------|
| All | Bazel 9+ |
| macOS | Xcode (for `rules_apple` and `rules_swift`) |
| iOS | Xcode + valid signing identity (simulator works without signing) |
| Android | Android SDK (`$ANDROID_HOME`), Android NDK (`$ANDROID_NDK_HOME`, pointing at a *versioned* `ndk/<version>` directory), rules_android, rules_android_ndk, rules_kotlin — see [Android](#android) |
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
flutter.toolchain(flutter_version = "3.47.2")
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
| macOS | Android | Yes | Yes | Automatic platform transition in the Android rules |
| macOS | Linux | No | Yes | Cross-compile with LLVM CC toolchain; JIT only (no cross gen_snapshot for desktop) |
| macOS | Windows | No | Yes | JIT only; requires Windows CC cross-toolchain |
| macOS | Web | Yes | N/A | Web uses dart2wasm/dart2js, not gen_snapshot |
| Linux | Linux | Yes | Yes | Native build |
| Linux | Android | Yes | Yes | Automatic platform transition in the Android rules |
| Linux | iOS | No | No | Requires Xcode (macOS only) |
| Linux | Web | Yes | N/A | |
| Windows | Windows | Yes | Yes | Native build |
| Windows | Android | Yes | Yes | Automatic platform transition in the Android rules |
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
| `entitlements` | Replace the entitlements wiring wholesale. By default the macro auto-discovers `macos/Runner/{DebugProfile,Release}.entitlements` and selects between them by compilation mode. |
| `additional_entitlements` | Entitlement plist files merged into the selected base in **every** compilation mode. See [Release builds and permissions](#release-builds-and-permissions). |
| `app_icons` | The app icon. Defaults to the `macos/Runner/Assets.xcassets/AppIcon.appiconset` that `flutter create` writes, so an app ships the icon already in its tree without asking. Pass a list to name a different `.appiconset` or an Icon Composer `.icon` bundle; pass `[]` to ship none. See [App icons](#app-icons). |

Produces a `.app` bundle with `FlutterMacOS.framework`, `App.framework`, and `flutter_assets/`.

<details>
<summary>Advanced: Tier 2 composable rules</summary>

For full control over the macOS bundle (custom runner, custom framework layout, etc.):

```starlark
load("@rules_flutter//flutter:macos.bzl",
    "flutter_entitlements_merge",
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

# rules_apple's `entitlements` takes one file; this merges additions into
# it (add-only, with a hard error on a conflicting value). Also exported
# from flutter:ios.bzl.
flutter_entitlements_merge(
    name = "my_entitlements",
    base = "macos/Runner/Release.entitlements",
    additions = ["entitlements/Network.entitlements"],
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
| `entitlements` | Replace the entitlements wiring. By default the macro auto-discovers `ios/Runner/Runner.entitlements` if present; its absence is a valid, capability-less app. |
| `additional_entitlements` | Entitlement plist files merged into the base in **every** compilation mode. Works when the app ships no entitlements file at all. See [Release builds and permissions](#release-builds-and-permissions). |
| `provisioning_profile` | A `.mobileprovision` file (usually a `local_provisioning_profile` target) to sign a device build with. Required for device builds; unused by simulator builds. See [Running an iOS example on a physical device](#running-an-ios-example-on-a-physical-device). |
| `app_icons` | The app icon. Defaults to the `ios/Runner/Assets.xcassets/AppIcon.appiconset` that `flutter create` writes, so an app ships the icon already in its tree without asking. Pass a list to name a different `.appiconset` or an Icon Composer `.icon` bundle; pass `[]` to ship none. See [App icons](#app-icons). |

The platform transition to iOS arm64 is handled automatically by `rules_apple`'s `ios_application`.

### App icons

On Apple platforms the icon comes from an **asset catalog**, not from loose
files: `actool` compiles the catalog and has to be told which set inside it is
the app icon, which is what `rules_apple`'s `app_icons` attribute says and what
listing the same PNGs under `resources` cannot. `flutter_ios_app` and
`flutter_macos_app` discover
`{ios,macos}/Runner/Assets.xcassets/AppIcon.appiconset` — the catalog
`flutter create` writes — and forward it, so an app that has never mentioned
its icon ships the one already in its tree, as `flutter build` does from the
same sources.

To ship something else, name it: `app_icons` takes the files of an
`.appiconset` or of an Icon Composer `.icon` bundle (`rules_apple` 4.5+
generates the pre-26 sizes from the latter). It refuses the two together, so
name exactly one. `app_icons = []` ships no icon.

**Discovery is per-platform, and a missing catalog is silent.** A tree that ran
`flutter create --platforms=ios .` has `ios/Runner/Assets.xcassets` and no
macOS counterpart, so the iOS app gets an icon and the macOS app quietly does
not — there is no error, because an app with no catalog and no `app_icons` has
said nothing either way. If one platform shows your icon and the other shows
the placeholder, look for the catalog before looking anywhere else.

macOS icons want the platform's own grid rather than a full-bleed square: the
rounded shape inset to roughly 824 of the 1024pt canvas, which is what makes it
sit correctly beside other Dock icons. The rules pass the catalog through
untouched and impose nothing here.

One `flutter create` detail is handled for you on macOS. Its `Info.plist`
declares `CFBundleIconFile` as an empty string for Xcode to fill in;
`macos_application` generates its own value from the catalog, and Apple's
plisttool refuses two different values for one key — `found key
"CFBundleIconFile" in two plists with different values: "" != "AppIcon"`. The
macro drops the empty placeholder, so the scaffold needs no edit. A plist that
names a *real* icon file is left alone, and still conflicts if you also pass
`app_icons`.

<details>
<summary>Advanced: Tier 2 composable rules</summary>

```starlark
load("@rules_flutter//flutter:ios.bzl",
    "flutter_entitlements_merge",
    "flutter_ios_engine",
    "flutter_ios_framework_gen",
    "flutter_ios_info_plist_gen",
    "flutter_ios_native_frameworks_gen",
    "flutter_ios_registrant_gen",
    "flutter_ios_runner_lib_gen")

flutter_ios_framework_gen(name = "my_framework", application = ":my_app")
flutter_ios_registrant_gen(name = "my_registrant", application = ":my_app")
flutter_ios_engine(name = "my_engine")
flutter_ios_info_plist_gen(name = "my_info_plist", app_name = "My App")

# Frameworks for the app's native assets and `native_deps` dylibs. Omitting
# this from `deps` below builds and renders a perfectly normal-looking app
# that fails every native-asset call at runtime.
flutter_ios_native_frameworks_gen(name = "my_native_frameworks", application = ":my_app")

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
    deps = [":my_framework", ":my_native_frameworks", ":my_runner"],
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

# Android NDK CC toolchain (used for native/FFI deps built for Android).
android_ndk_repository_extension = use_extension(
    "@rules_android_ndk//:extension.bzl",
    "android_ndk_repository_extension",
)
use_repo(android_ndk_repository_extension, "androidndk")
register_toolchains("@androidndk//:all")
```

**Environment.** Android builds need *two* variables, both read by repository
rules during fetch:

| Variable | Value | Read by |
|---|---|---|
| `ANDROID_HOME` | the SDK root, e.g. `~/Library/Android/sdk` | `rules_android`'s `android_sdk_repository` |
| `ANDROID_NDK_HOME` | a **versioned** NDK directory, e.g. `$ANDROID_HOME/ndk/28.2.13676358` | `rules_android_ndk`'s `android_ndk_repository` |

`ANDROID_NDK_HOME` must name the versioned directory, not its `ndk/` parent.
Pointing at the parent fails inside the NDK repository rule with a message that
mentions neither the variable nor the mistake:

```
Error in readdir: can't readdir(), not a directory:
  .../Android/sdk/ndk/toolchains/llvm/prebuilt/darwin-x86_64
```

Exporting both in the environment works. Putting them in a `.bazelrc` requires
`--repo_env`, **not** `--action_env` — `--action_env` reaches build actions
only, and repository rules never see it, so an `--action_env` line fails
exactly as if nothing were set:

```bazelrc
common --repo_env=ANDROID_HOME=/path/to/Android/sdk
common --repo_env=ANDROID_NDK_HOME=/path/to/Android/sdk/ndk/28.2.13676358
```

With `ANDROID_NDK_HOME` unset, the build stops during repository fetch, before
anything Android-specific is analyzed:

```
ERROR: An error occurred during the fetch of repository
  'rules_android_ndk++android_ndk_repository_extension+androidndk':
  Error in fail: Either the ANDROID_NDK_HOME environment variable or the
  path attribute of android_ndk_repository must be set.
```

Build — no platform flags needed. `flutter_android_bundle` transitions the
Flutter application (AOT compile, FFI deps, and all) to the Android platform
matching its `android_abi`:

```sh
ANDROID_HOME=~/Library/Android/sdk \
ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/28.2.13676358 \
  bazel build //:my_app_android
```

| Attribute | Description |
|-----------|-------------|
| `application` | A `flutter_application` target (required). |
| `package_name` | Android package name, e.g. `"com.example.myapp"` (required). |
| `app_name` | Display name. Defaults to target name. |
| `android_abi` | Target ABI — `"arm64"` (default) or `"x64"`. Selects the engine and the Android platform the app is built for. |
| `min_sdk_version` | Minimum Android SDK version. |
| `target_sdk_version` | Target Android SDK version. |
| `manifest` | Override AndroidManifest.xml (auto-discovered from `flutter create` output or generated). Used verbatim: `${applicationName}` is **not** substituted, so this attribute cannot take `flutter create`'s own `android/app/src/main/AndroidManifest.xml` — let the macro discover that one instead. |
| `debug_manifest` | Variant manifest whose permissions merge into `-c dbg` APKs only. `None` (default) discovers `android/app/src/debug/AndroidManifest.xml`; a label overrides discovery; `False` disables variant handling. |
| `permissions` | Permission names added to the effective manifest in **every** compilation mode, e.g. `["android.permission.INTERNET"]`. See [Release builds and permissions](#release-builds-and-permissions). |
| `multidex` | Multidex mode. Default: `"native"`. |

<details>
<summary>Advanced: Tier 2 composable rules</summary>

For full control over the Android build (custom manifest, custom runner activity, etc.):

```starlark
load("@rules_flutter//flutter:android.bzl",
    "flutter_android_bundle",
    "flutter_android_engine",
    "flutter_android_manifest_gen",
    "flutter_android_manifest_merge",
    "flutter_android_permissions_manifest",
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

**GTK3 and your cc toolchain.** rules_flutter ships its own hermetic Chromium
sysroot for GTK3 headers and libraries, and links those libraries **as explicit
files** — it adds no `-L` to the link line and never passes `-lgtk-3`-style
flags. Your cc toolchain's `--sysroot` is untouched and remains the sole owner
of libc, libm and the rest of the C runtime. (This matters: a Debian sysroot's
`libm.so` is a GNU ld script holding absolute paths that `lld` rewrites only for
scripts found beneath `--sysroot`, so a second sysroot on the `-l` search path
would break `-lm` with a "no such file" error naming a file that exists.)

Cross-compile from macOS. Desktop cross-compiles are **debug/JIT only** — see
[Cross-Compilation](#cross-compilation); Flutter publishes no
cross-`gen_snapshot` for desktop targets, so there is no `-c opt` equivalent of
this command:

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
| `pwa` | Ship `flutter_service_worker.js` and register it from the generated bootstrap. Default: `True`. Adds no offline caching — like `flutter build web`, which [deprecated its caching worker](https://github.com/flutter/flutter/issues/156910), the worker unregisters itself and reloads its clients, freeing visitors who still hold a caching worker from an earlier deployment. Visitors without one never get a worker registered. |

#### Content-Security-Policy

A `<meta http-equiv="Content-Security-Policy">` in `web/index.html` applies to
the built bundle **and** to `flutter_bazel run -d chrome`, because the dev loop
serves the same page the bundle ships. Measured on `e2e/web_example` against
Flutter 3.47:

| Policy | Built bundle (`--wasm`) | DDC dev loop |
| --- | --- | --- |
| `script-src 'self' 'wasm-unsafe-eval'` | renders | **blank page** |
| `script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'` | renders | renders |

The dev loop needs `'unsafe-inline'` — not `'unsafe-eval'`, which changes
nothing — and the failure is silent: DWDS connects, the VM service answers, 311
DDC modules load, no CSP violation reaches the console, and the app never
paints. `connect-src 'self' ws: wss:` is enough for the dev loop's WebSocket.

A bundle under `default-src 'self'` must also serve its own renderer:
`use_local_canvaskit = True`, or the engine's `skwasm.js` fetch to
`www.gstatic.com` is blocked and the page stays blank. Flutter's font fallback
(`fonts.gstatic.com`) is blocked too — harmless unless the app needs those
glyphs.

So a policy strict enough to be worth having cannot live in `web/index.html`
today: it has to reach the bundled page only. Compose `flutter_web_bundle`
directly with a generated `index_html` if you need that split now.

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

#### Golden files

**Goldens must be declared in `data`, or the test cannot see them.**

```starlark
flutter_test(
    name = "widget_test",
    main = "test/widget_test.dart",
    data = glob(["test/goldens/**"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)
```

This is the first thing to check when a golden fails, because the failure does
not describe it. The comparator reads goldens out of runfiles, so a PNG sitting
in the source tree that is not an input of the target is invisible — and it
fails as `Could not be compared against non-existent file`, **word for word the
message you get when the file really is absent**. A file you can see on disk,
reported as non-existent, is the confusing case; undeclared is almost always the
reason.

That the two are indistinguishable is deliberate rather than an oversight: a
comparison whose inputs are all declared is one whose cached pass still means
something. Undeclared inputs would make a cached green meaningless.

Otherwise `matchesGoldenFile('goldens/x.png')` means what it means under
`flutter test`: the golden is read from
`<directory of the test's `main`>/goldens/x.png`, and a mismatch reports
upstream's pixel percentage. The comparator is installed into the generated
bootstrap at the point `flutter test` installs its own.

Regenerate with upstream's flag, under `bazel run`:

```sh
bazel run //:widget_test -- --update-goldens
```

That writes the PNGs back to the **source** tree, next to the test, and names
each file it wrote. The same flag under `bazel test` is refused with exit 64: a
test action cannot write to the source tree, and a golden regenerated into the
sandbox would report success while changing nothing. There is no repo-wide
regeneration command — it is one `bazel run` per target, which
`bazel query 'tests(//...)'` can drive.

When a comparison fails, the four diff images (`masterImage`, `testImage`,
`isolatedDiff`, `maskedDiff`) are written to
`bazel-testlogs/<pkg>/<target>/test.outputs/failures/`, which is what the
failure message names. Upstream points at a directory beside the test; under
Bazel that is inside the sandbox and is deleted before you can open it.

Two limits worth knowing, both inherited from Flutter rather than introduced
here:

- **Goldens are host-specific.** Font rasterisation and antialiasing differ
  between operating systems, so a PNG generated on macOS may not match one
  rendered on Linux or Windows. Regenerate on the platform that will check it,
  or keep per-OS golden directories.
- **Replacing the comparator disables regeneration.** If a test assigns its own
  `goldenFileComparator`, `--update-goldens` routes through that object's
  `update()` instead — typically `LocalFileComparator`'s, which writes into
  runfiles. The run reports PASS, prints nothing, and leaves the source PNG
  untouched.

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

### `flutter_gen_l10n`

Generates Flutter's `AppLocalizations` from `.arb` files — the Bazel equivalent
of `flutter gen-l10n`.

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_gen_l10n")

flutter_gen_l10n(
    name = "app_l10n",
    arbs = [
        "lib/l10n/app_en.arb",
        "lib/l10n/app_es.arb",
        "lib/l10n/app_es_419.arb",
    ],
)

flutter_test(
    name = "l10n_test",
    package_name = "my_app",
    srcs = [":app_l10n"],
    main = "test/l10n_test.dart",
    deps = [
        "@deps//:flutter",
        "@deps//:flutter_localizations",
        "@deps//:flutter_test",
        "@deps//:intl",
    ],
)
```

The generated files land beside the `.arb` files, so a consumer collects them
by listing the target in `srcs`.

**Keep `@@locale` consistent with the filename.** The rule derives the declared
output names from the arb *filenames*, while the generator decides what to write
from each file's `@@locale` field. If `app_english.arb` declares
`"@@locale": "en"`, Bazel expects `app_localizations_english.dart` and the
generator writes `app_localizations_en.dart`, which surfaces as an opaque
"output was not created". Bazel cannot read file contents during analysis, so
this is a convention the rule cannot check for you.

**`l10n.yaml` is not read.** Configuration comes from rule attributes instead.
Bazel must know the output file names during analysis, and a config file read
when the action runs cannot inform that. The attributes mirror upstream's flags
(`template_arb_file`, `output_class`, `use_deferred_loading`, …) with upstream's
defaults.

**Outputs are grouped by primary language subtag.** `app_es.arb` and
`app_es_419.arb` produce a *single* `app_localizations_es.dart` holding both
`AppLocalizationsEs` and `AppLocalizationsEs419`, matching upstream. Listing one
output per input arb is therefore wrong.

**Two behaviours differ from the `flutter` CLI**, both deliberate:

- Generated files always use LF line endings. Upstream mirrors the project
  `pubspec.yaml`'s line endings, which would make build output depend on a file
  that is not a declared action input.
- `format` is not offered and setting it upstream-style is an error rather than
  a silent no-op. Formatting shells out to the `dart` binary, which the action
  does not have; check the generated sources with a `dart_format_test` if you
  want it enforced.

**Two `intl`s are in play.** The generator resolves its own `intl` from
`//flutter/private/gen_l10n:pubspec.lock`; an app *using* the generated code
needs `intl` in its own lock. Upstream has the same split.

**Bumping Flutter** re-validates this rule by design. The generator is vendored
out of `flutter_tools` at fetch time by seven patches; a release that moves
their context makes `repository_ctx.patch` fail, and a new release also needs
`source_sha256` in `//flutter/private:versions.bzl`. Both are loud. Two things
neither catches:

- A newly introduced **undeclared runtime read** — reading a file at run time
  that the action never declared. No static analysis surfaces it; the symptom
  is a `PathNotFoundException` naming the file.
- A newly adopted **`dart:io` API**. flutter_tools is only ever compiled by its
  own bundled Dart, so it can use APIs newer than the Dart a `dart_binary`
  gets from rules_dart; the symptom is a compile error naming a missing
  `dart:io` type. The fix is to cut the dead code that uses it — the seventh
  patch does exactly this for the unused `NetworkInterface` wrapper — not to
  reach for a toolchain override.

See `//flutter/private:flutter_gen_l10n_repo.bzl`.

**Windows note:** the repository rule extracts all of `packages/flutter_tools`
(about 19 MB, 1400 files) and uses 20 of them. The deepest extracted path is
roughly 130 characters relative to the repository root, which is within
`MAX_PATH` given the short `output_user_root` Windows CI already sets, but it is
more of that budget than the rule needs.

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

### Regenerating `pubspec.lock`

Bazel *consumes* `pubspec.lock` — it never writes one. Resolve it with the
toolchain rules_flutter pins, not with a Flutter installed separately:

```sh
bazel run @rules_flutter//flutter:pub -- get       # after editing pubspec.yaml
bazel run @rules_flutter//flutter:pub -- upgrade
bazel run @rules_flutter//flutter:pub -- add qr
```

Arguments pass through to `dart pub` unchanged, and the command runs in your
workspace root, so `pubspec.lock` lands where `flutter.pub()` reads it.

**Why not the `flutter` on your `PATH`.** The version matters and the failure is
silent. Pub's solver treats the running Dart SDK's version and the Flutter SDK's
version as constraints, so an installation older than the pinned toolchain
quietly selects older packages — and the lock it writes is still perfectly
valid, so nothing downstream can tell. Resolving `e2e/plugin_example` with a
host Flutter 3.41.6 (Dart 3.11.4) pins `meta 1.17.0`; the pinned 3.44.1
toolchain (Dart 3.12.1) pins `meta 1.18.0`.

The fetched toolchain is engine artifacts plus a Dart SDK — there is no
`bin/flutter` in it, and no `pub` executable — so this target runs `dart pub`
with `FLUTTER_ROOT` pointed at `@flutter_dev_root`, a tree assembled from the
same flutter/flutter tag the toolchain pins. That repository is fetched the
first time you run the target and by nothing else.

Two consequences of it being `dart pub` rather than `flutter pub`: it writes
`pubspec.lock` and `.dart_tool/package_config.json` (both already covered by
`flutter create`'s `.gitignore` for the latter), and it does not write
`.flutter-plugins-dependencies` — rules_flutter generates plugin registrants
from the build graph, so nothing here reads that file.

**A package below the workspace root** — this repo's own
`flutter/private/gen_l10n`, or a `tools/*` package — is still resolved by the
same target. Arguments pass through unchanged, so `dart pub`'s `--directory`
reaches it:

```sh
bazel run @rules_flutter//flutter:pub -- get --directory flutter/private/gen_l10n
```

The target always runs at `BUILD_WORKSPACE_DIRECTORY`, so the path is relative
to the workspace root and does not change with your shell's location. Without
`--directory` it resolves the root `pubspec.yaml`, which in a ruleset does not
exist.

This form exists so there is never a reason to reach for a separately installed
Dart. Resolving a nested package by hand is the same silent trap the warning
above describes, and it is worse here than at the root, because nothing about
the resulting lock looks wrong.

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
| `version` | `str` | Flutter SDK version string (e.g. `"3.47.2"`). |
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

### App output

A running app's console output — `print`, `debugPrint`, `NSLog`, Java stack traces, uncaught errors — is forwarded for the whole life of the run, starting before the VM service comes up so that startup failures are visible.

Where it goes depends on the mode:

| Mode | Destination |
| --- | --- |
| terminal (default) | the app's stdout → the tool's stdout, its stderr → the tool's stderr, matching `flutter run` |
| `--machine` | `app.log` events. Nothing app-related is written to raw stdout, which belongs to the JSON-RPC stream |

With more than one `-d`, terminal output is prefixed `[<device>] ` so an interleaved multi-device run stays readable — same convention as `flutter run -d all`. Machine mode never prefixes: each `app.log` event already carries its `appId`.

Each platform has exactly **one** log source, because a Dart `print()` reaches both the process's stdout and the VM service's `Stdout` stream, and reading both would duplicate every line:

| Platform | Source |
| --- | --- |
| macOS / Linux / Windows | the app process's stdout + stderr |
| Android | `adb logcat`, filtered host-side to `flutter*`, `DartVM`, `AndroidRuntime`, `System.err` and fatal records |
| iOS Simulator | a dedicated `simctl spawn log stream` scoped to the app process (separate from the stream used for VM-service discovery) |
| iOS device | `devicectl --console`, plus lldb's own output — lldb stays attached for the whole run |
| Chrome, DDC dev mode | the DWDS VM service's `Stdout`/`Stderr` streams |
| Chrome, WASM / production JS | CDP `Runtime.consoleAPICalled` |
| `attach` | the VM service's `Stdout`/`Stderr` streams — the app wasn't spawned here, so there is no process to read |

**Physical iOS devices.** Output comes from `devicectl --console` — which also
carries devicectl's own progress banners (`Acquired tunnel connection…`,
`Launched application with…`) — together with lldb's, since lldb stays attached
for the whole run holding the debugserver the JIT depends on. Upstream treats
the pair the same way: on a CoreDevice with Xcode ≥ 26 `flutter_tools` selects a
combined `devicectlAndLldb` log source, noting that `idevicesyslog` "stopped
working with at least Xcode 26."

Expect the first line to take longer than on a host. Starting a debug build
under the JIT breakpoint is not free: the engine traps to the debugger for every
executable page it allocates, and the handler writes to device memory over the
debugserver link. Setting `--auto-continue` on the breakpoint changes nothing,
because the cost is the memory write rather than the stop/resume handshake. On a
recent iPhone with a healthy Xcode install, resume to the engine's first log
measured **~8 s over a cable and ~40 s over the network**. A cable
is still several times faster, but the network is not a different order of
magnitude.

Minutes-long launches mean something is wrong on the *host*, not on the phone.
The usual cause is an unfinished Xcode symbol copy, which leaves lldb without
the on-disk shared cache; check that Xcode has finished copying symbols for the
device before looking anywhere else. The tool prints a "still waiting" note at 45 s so
a slow launch stays distinguishable from a hang.

### Finding the VM service

On every platform except physical iOS hardware, the URI arrives in-band: the
engine prints it, and discovery reads the same log stream that carries app
output. Nothing extra is involved.

A physical iOS device is the exception. A wirelessly attached device has no
console channel at all, and the one a wired device has belongs to the `devicectl`
invocation that launched the app. So the URI comes from the app's **mDNS
advertisement** instead — the one channel both connections share. Every Flutter app built in
debug or profile mode advertises `_dartVmService._tcp` with its port in the SRV
record and its service auth code in the TXT record; the generated debug/profile
`Info.plist` declares the matching `NSBonjourServices` entry
(`flutter/private/runners/ios/DartVmServiceMdns.plist`), so this works for any
app built through these rules with no extra configuration.

This is the single mechanism for iOS hardware — nothing races it — and it is
what makes wireless devices work at all:

| Connection | VM service host | Port |
| --- | --- | --- |
| wired | `127.0.0.1` through an `iproxy` forward, because the service binds to the device's loopback | the advertised device-side port, forwarded |
| wireless | the device's own address, resolved from the advertisement | the advertised port, dialed directly |

The two halves are chosen together from what `devicectl list devices` reports:
a wireless launch also passes `--vm-service-host=0.0.0.0` so the service is
reachable off-device, and a wired launch deliberately does not.

Three things are worth knowing when it fails:

- **Local Network permission.** On macOS the mDNS socket needs it. Denied, the
  failure is a specific error naming System Settings > Privacy & Security >
  Local Network — not a silent timeout. The device also prompts once, on its
  own, the first time an app advertises.
- **mDNS queries get lost.** They are UDP, and RFC 6762 §5.1 requires a querier
  to retransmit. Against a USB-attached iPhone a single query succeeded roughly
  two times in five, so discovery retransmits with the specified backoff; in
  practice it resolves in ~200 ms and worst-observed 3.3 s.
- **`dns-sd` is not evidence of what this tool can see**, in either direction.
  It answers from mDNSResponder's table, which holds records a raw multicast
  socket cannot reach: over USB, CoreDevice proxies the device's Bonjour records
  in as **local-only registrations**, invisible to a multicast socket by design.
  So `package:multicast_dns` seeing nothing over USB while `dns-sd` lists the
  phone is correct on both sides. The table also keeps **ghosts** — stale
  `_dartVmService` registrations on `lo0` from booted simulators, with no app
  running. Unplugged, the phone multicasts for real on `en0`/`en1` and the raw
  socket sees it. If you do reach for `dns-sd`, read the interface index on each
  `Add` line — interface 1 is `lo0` and proves nothing about the device.

Hot reload and hot restart get the same allowance. A reload is quick — only the
changed library is compiled and no pages are re-JITed — but a restart re-runs
`main()` and so pays the breakpoint cost again, taking about as long as the
original launch. The per-call budget is five minutes wired and fifteen wireless,
against thirty seconds on a host. Those are backstops for a run that will never
succeed, deliberately sized for the worst host state seen rather than for the
seconds a healthy one takes: too short a budget does not merely wait less, it
abandons the RPC and force-closes the VM-service connection, reporting a timeout
for a restart that was on its way to succeeding.

`devicectl list devices` also lists devices that were paired once and are not
attached now. Those are filtered out, so `-d ios` picks the device that is
actually there; with two attached, it asks for `-d ios:<udid>` rather than
guessing. Either identifier works there — a device has two, the hardware UDID
Xcode shows and the CoreDevice UUID `devicectl` prints as `identifier`. Only the
hardware one means anything to usbmuxd, so that is what `iproxy` and `lldb` are
addressed with; getting this wrong yields a port forward that binds locally and
then resets every connection, which surfaces much later as a DDS failure.

### Assets and fonts

An edit to a bundled asset goes live the same way an edit to a `.dart` file
does, on hot reload or a watched save. The tool tracks the built
`flutter_assets` tree, so it knows which workspace directories feed it and can
answer "did an asset change?" from a few directory listings — a run whose assets
are untouched never pays for a `bazel build` on a Dart edit.

When one has changed, the bundle is rebuilt and only the differing entries are
uploaded into the app's devFS, which is what makes this work on a phone, inside
an APK, and inside a sandboxed `flutter create` macOS app — none of which can
read `bazel-out`. Everything not uploaded still resolves to what shipped: the
engine keeps the original bundle behind the devFS directory. A changed font
additionally re-registers the engine's font collection, so re-exporting a `.ttf`
in place takes effect (upstream ignores that until a restart).

On web the dev server already serves `assets/` off the build tree per request,
so only the page's caches have to be dropped. Fonts are the exception there —
the web engine registers them once at startup and exposes no reload hook — and
the reload says so rather than reporting success.

### Debugging from the first line

`flutter_bazel run --start-paused` holds the app at the beginning of `main()`
so a debugger can attach before any app code runs. The switch reaches each
platform the way that platform accepts one — `FLUTTER_ENGINE_SWITCH_<N>` on
desktop, an `--ez start-paused true` intent extra on Android, trailing argv on
iOS — and on web there is no switch at all: DWDS gates `main()`, so the tool
simply withholds the run request and DWDS starts the app when a client resumes
it.

The pause is reported only once it has been *observed* (the main isolate's own
`pauseEvent`), so a target that ignored the switch is called out rather than
leaving you waiting at a debugger for an app that already ran. While paused,
`app.*` commands answer with the reason instead of blocking on an isolate that
cannot run, and `--route` / `--trace-startup` are skipped with a warning —
both need a framework that has not started yet.

### Agent / external-tool control surface

`flutter_bazel run` starts an HTTP control channel by default (disable with `--no-http-control-channel`). External tools — IDE integrations, AI coding agents, end-to-end test harnesses — drive the running app over this channel without needing a TTY.

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- \
  run --target //:my_app --machine
# stderr emits the channel's own record — as a JSON line under LOG_FORMAT=json,
# carrying every endpoint below as data rather than as prose. Each one comes
# with the URL that works, token included; the token is a query parameter
# (`tokenParam`), not an Authorization header:
#   {"message":"http_control_channel","uri":"http://localhost:PORT",
#    "token":"...","tokenParam":"token","endpoints":[
#      {"method":"POST","path":"/command",
#       "url":"http://localhost:PORT/command?token=...", ...}, ...]}
# stdout emits the protocol stream, starting with daemon.connected:
#   [{"event":"app.start","params":{"appId":"...","deviceId":"macOS", ...}}]
```

**What counts as protocol on stdout.** A line is a protocol message if and
only if it is a `[{…}]` envelope; anything else is passthrough output and a
client should hand it to the user rather than parse it. That is upstream's own
convention — `flutter_tools`' DAP and the Dart-Code extension both filter
exactly this way — and it is what makes the invocation above safe: under
`bazel run`, this tool's stdout **is** bazel's stdout, and bazel forwards a
successful action's stdout to it. So a run that has to rebuild the tool first
prints, for instance, `Generated: /…/flutter_bazel` from `dart compile exe`
ahead of the first envelope. Nothing before `daemon.connected` is addressed to
a protocol client.

Once the channel is up:

| Endpoint | Verb | Purpose |
| --- | --- | --- |
| `/command?token=<token>` | `POST` | Run a machine-protocol method against a running session. Body: `{"method":"app.<X>", "params":{"appId":"...", ...}}`. |
| `/sessions/{appId}/screenshot/flutter?token=<token>` | `GET` | PNG of the Flutter widget tree (`_flutter.screenshot` via VM service). **Not available on any device at the pinned Flutter** — see below. |
| `/sessions/{appId}/screenshot/native?token=<token>` | `GET` | PNG of the app as the platform sees it (`screencapture` / `scrot` / `simctl io screenshot` / `adb screencap` on a physical Android device, `adb emu screenrecord screenshot` on an emulator / CDP). Works on every device. |

**When the picture was taken.** Both endpoints wait for the app to go idle before capturing, so a screenshot taken straight after an `app.tap` includes what the tap did. Without that wait a capture is just a moment — it returns the frame from *before* the action painted, and a stale picture is indistinguishable from a feature that did not work. The answer says which you got: `X-Settled: yes` (idle first), `no` (the wait ran out, or the app is backgrounded), or `skipped` (`&settle=false`, or this run has no VM service to ask — `--wasm`, `--profile`), with `X-Settle-Detail` carrying the reason for anything but `yes`. Never fatal: an app that cannot settle is the one whose picture is most worth having. `app.settle` is the same wait as a command, for use between two of your own.
| `/commands?token=<token>` | `GET` | What this run can be asked to do: `{"protocolVersion", "commands":[{"name","longRunning"}]}`. See below. |
| `/sessions/{appId}/logs?token=<token>` | `GET` | The app's console output, from a bounded ring buffer. See below. |

**Which screenshot.** `screenshot/flutter` captures only the widget tree, with no OS chrome, by asking the engine — but the engine cannot encode a compressed screenshot under **Impeller**, and there is no engine screenshot on web at all. Since Flutter 3.47 every platform renders with Impeller by default, so every device answers `501` naming `screenshot/native`, rather than a `500` that reads as transient. An app that turns Impeller off could serve it; the dev tool does not try to detect that, because the renderer is a runtime property of the app and `screenshot/native` captures both. `screenshot/native` is the one that works everywhere.

**Which commands.** The set is not fixed when a client connects — it grows
through a run, and it is a statement about *this* run rather than about the
tool. A web run gains `app.setViewport` once the browser is up and never
offers `app.buildInfo` at all, because only a `-c dbg` native build carries
the record that command reads; a native debug run gains `app.buildInfo` once
the plan is resolved. The agent commands (`app.tap`, `app.getText`, …) are
offered once the plan says this run has a VM service to reach the app's
extensions through — every native run, and on a browser only the DDC dev
loop — and answer once that service actually exists, which on web and on an
iOS device is well after `app.started`. So re-read `/commands` rather than
caching the first answer. `longRunning` marks the commands that
rebuild or recompile before they answer — the ones worth a generous timeout,
and the ones `app.progress` is emitted for.

A `--machine` client does not need this endpoint: it is handed the list on
`daemon.connected` and again on every `daemon.commandsChanged`, because it
reads stdout from the first byte and cannot miss either. `daemon.connected`
also carries `protocolVersion`, which says which of these fields to expect.

It is also told things this channel has no way to push: `app.devTools` carries
the DevTools URL for the app once there is one to serve, `app.debugPort` the
VM service's `port`, `wsUri` and `baseUri`, and `app.webLaunchUrl` the address
a web run is served at — the browser this tool launches uses a scratch profile
and may be headless, so that URL is how you open the page in your own browser.
The full event list is the header of
`tools/dev_tool/lib/machine_protocol.dart`, which is the registry rather than
a copy of it.

**Reading logs.** `/logs` is a cursor-polling endpoint rather than a stream: there is no long-lived connection, and a caller reads exactly as much as it asks for.

| `since` | meaning |
| --- | --- |
| omitted | tail the last 200 lines — what you want with no prior cursor |
| `-N` | tail the last `N` lines |
| `0` | everything still buffered, oldest first |
| `N > 0` | resume at line `N` (feed back a previous `nextCursor`) |

`limit` caps the page (default and maximum 500). A non-numeric `since`, or a non-positive `limit`, is a `400` rather than a silent fallback — a typo'd cursor would otherwise look like a working poll loop that re-reads the tail forever.

```sh
# Tail, then poll forward.
curl -s "$URI/sessions/$APP/logs?token=$T"
# {"lines":[{"index":812,"text":"flutter: meter -18dB","error":false}],
#  "nextCursor":813,"launch":1,"missed":0,"dropped":0,"closed":false}

curl -s "$URI/sessions/$APP/logs?token=$T&since=813"
```

`error` marks lines that arrived on an error channel — the process's stderr, a VM-service `Stderr` event, `console.error` — the same bit, under the same name, that `app.log` uses. It is a *channel*, not a severity: platforms that hand the whole device log over one stream (iOS via `devicectl`/`simctl`, Android via `logcat`) deliver engine `[ERROR:…]` lines with `error:false`, so match on the text when you care about engine errors there.

`missed` is non-zero when the requested cursor had already been evicted, so a poller learns it has a gap instead of reading a short page as though it were complete; `dropped` is the total evicted over the run. `closed` turns true once the app's output source has ended — no further lines can arrive, so a poll loop can stop. The buffer survives the app's exit, so a crashed app's final output is still readable.

`launch` is which launch of the app the page came from: `1` for the original, one more for each relaunch (see `app.restart` below). Each launch buffers its own output from zero, so a cursor only means anything within one launch — when `launch` changes, drop your cursor and re-tail.

App-driving methods (proxied to the agent extensions the app registers before `main()` on every launch, so they survive hot restart — from the generated plugin registrant the engine invokes on native, and from the dev tool's generated entrypoint on web):

`app.dumpWidgetTree`, `app.tap`, `app.longPress`, `app.doubleTap`, `app.drag`,
`app.scrollIntoView`, `app.enterText`, `app.getText`, `app.getRect`,
`app.waitFor`, `app.waitForAbsent`, `app.pageBack`, `app.settle`.

Two more are offered only by the runs that can serve them, and appear in
`/commands` when they are: `app.buildInfo` — which build tree backs the
running app, read from a record `flutter_compile_kernel` bakes into `-c dbg`
native builds — and `app.setViewport`, which resizes a web run's browser.

**A web run without a VM service offers none of them.** `--wasm`, `--profile`
and `--no-hot` serve a bundle built by dart2wasm or dart2js, where
`dart:developer`'s `registerExtension` is a no-op stub and there is no service
to dispatch through in any case, so the driving methods above are absent from
`/commands` rather than present and refusing. The run says so once, up front,
as an `agent_surface_unavailable` log record. What such a run can still do:
`/logs` (its console arrives over CDP), `/sessions/{appId}/screenshot/native`
(CDP's own capture) and `app.restart` (a bazel rebuild plus a page reload).
To drive the widget tree, run the same target as the DDC dev loop — neither
`--wasm` nor `--profile`.

These are answerable later than `app.started` suggests, on every platform. `app.started` means `main()` has begun running — the same thing upstream's daemon protocol means by it — and an app that has begun running has not yet built a widget tree. On `-d chrome` the gap is DWDS: the browser's VM service only exists once the page has connected, and DWDS holds `main()` back until it does, so nothing is registered for the first few seconds of a run or of a hot restart. On a physical device the gap is the app's own start: a debug build on an iPhone JITs through the debugger and its VM service answers *nothing* — not an agent call, not `getVersion` — until the app paints, measured at 61s after `app.started`.

A command issued in that window waits it out rather than failing, so you can fire on `app.started` and need no readiness poll of your own. The wait is reported as an `app.progress` pair (`Waiting for the app to render its first frame`) so a client can show it, and an app that never paints is refused with a reason rather than a bare timeout. Waiting for a widget is still yours to ask for, with `app.waitFor`.

Lifecycle methods: `app.hotReload`, `app.restart`, `app.stop`, `daemon.shutdown`.

`app.stop` stops the **one app** its `appId` names, as upstream's does; a run
driving two devices carries on with the other, and ends when its last app
does. It needs the `appId` — a bare `app.stop` is refused rather than read as
"all of them". `daemon.shutdown` is the one that ends the run: every app, the
browser, the compiler and this process.

**How a command says no.** Every failure, on either transport, is a top-level
`error` carrying the reason — there is no second place to look. Over HTTP the
status says which kind it is: `404` the command or the app does not exist
here, `400` the request was malformed (a missing parameter, two selectors),
`501` this run cannot serve it (an engine screenshot under Impeller), `422` it
was asked properly and could not be done — the app refused, or never answered.
A `500` means the tool itself broke, which is the one case worth retrying or
reporting. On the stdin protocol the same failure is upstream's
`{"id":…, "error":"<reason>"}`, with `error` a string.

What stays inside `result` is an outcome that carries its own verdict: a hot
reload answers `{"succeeded":false, "error":…}`, because it ran and reported a
failure rather than refusing to run.

**Restarts that relaunch.** A hot restart swaps Dart code into the running process, which cannot replace a native library it has already `dlopen`ed. So `app.restart` first rebuilds the app and, when the bundle's loose native libraries (`native_deps`) changed, relaunches the process instead of restarting the isolate:

```json
{"message":"Restart relaunched the app: native libraries changed (…). …",
 "relaunched":true,"nativeLibsChanged":["…/libmul.dylib"],
 "launch":{"<appId>":2},"ready":true}
```

The channel is a property of the *run*, not of the app process: the port, the token and the `appId` are unchanged, and there is no second banner because none is needed — keep using the ones you started with. The machine protocol re-emits `app.debugPort` and `app.started` for the replacement process. `ready` says the relaunched app rendered a first frame before the response returned, so its service extensions are registered and the next `app.*` call will land; a `false` means that wait timed out, not that the app is broken. The one thing that does not carry over is `/logs`: the new process buffers its output from zero, so compare `launch` and re-tail. Only `app.stop` and `daemon.shutdown` end a session.

**Selecting a widget.** Methods that target a widget (`tap`, `longPress`, `doubleTap`, `drag`, `getRect`, `getText`, `enterText`, `scrollIntoView`, `waitFor`, `waitForAbsent`) take **exactly one** selector — mirroring `flutter_driver`'s finder vocabulary:

| param | matches |
| --- | --- |
| `key` | a widget whose `ValueKey` value equals the string |
| `text` | a `Text`/`EditableText` whose content equals the string |
| `tooltip` | a `Tooltip` whose `message` equals the string |
| `type` | a widget whose runtime type name equals the string (e.g. `ElevatedButton`) |
| `semanticsLabel` | a widget whose semantics label equals the string |

Passing zero or more than one selector returns a clear error. Other params: `durationMs` (longPress/drag/scrollIntoView), `dx`/`dy` (drag/scrollIntoView), `scrollableKey` (scrollIntoView, `ValueKey` only), `timeoutMs`, `settle`, `requireHit`.

A selector reaches the same distance for every method: put the `Key` on the widget you would point at — the `Chip`, the `ListTile`, the button — not on the `Text` or `EditableText` it happens to build.

- **`getText`** returns the text of the first text-bearing descendant of the match in pre-order (`Text`, including `Text.rich`; `RichText`; `EditableText`), and lists every one of them in `texts` — so a container holding two strings is visible as two rather than silently reported as its first. `{"text":"Increment (agent)","texts":["Increment (agent)"]}`.
- **`enterText`** takes `text` as the string to type, which is why it is the one method whose selector vocabulary excludes the `text` selector: `key`, `tooltip`, `type` and `semanticsLabel` apply. With a selector it focuses the first `EditableText` under the match and types into it — no preceding `tap` needed — and echoes what it typed into: `{"enteredText":"hi","into":"ValueKey(emailField)"}`. With no selector it types into whatever is focused (`flutter_driver`'s model), reporting `"into":"focused"`.

**Settling and timeouts.** After dispatching input, interaction methods wait until the app is idle (no animations in flight) before returning, so a follow-up `getRect`/`getText` sees post-action layout — the same model as `flutter_driver`. The wait is bounded by `timeoutMs` (default 10000); if the app can't settle within it the method returns a `TimeoutException` error rather than blocking forever, and the error says how many animations were still in flight — zero means the app was backgrounded mid-command and the frame being awaited never arrived. **The input is still delivered**, so that error means "I cannot promise the result is observable yet", never "nothing happened"; retrying it taps twice. An app that was *already* backgrounded returns immediately instead: backgrounding is what stops frames (minimizing or covering its window does not), so there is no frame to wait for and none of `timeoutMs` is spent.

**Reaching the widget.** Being in the tree is not the same as being where a pointer can land. A child of a scroll view that is scrolled past is laid out at coordinates outside the viewport; one behind a dialog or an overlay is covered. A selector still finds it and it still has a rect, so `tap`, `longPress`, `doubleTap` and `drag` hit-test the point before dispatching and **refuse** when nothing there resolves to the target. The refusal names which case it is and gives the matching remedy — scroll it into view, or move what covers it; a coordinate that lands in a different pane is the second, and telling you to scroll a widget already on screen would send you nowhere. This is `WidgetController`'s `warnIfMissed` with the fatal choice made: a success response for an event nobody received is worse than an error.

`app.scrollIntoView` is the way through, and it answers the question directly: its `reachable` field says whether a tap would now land. (`iterations` counts drag-scrolls of a lazy list; `0` means the target was already built and `Scrollable.ensureVisible` was used, which is not "there was nothing to do".) `requireHit: "false"` dispatches at the point anyway — upstream's `warnIfMissed: false`, for a caller who means it.

**`settle: "false"`** turns the wait off for one command — `flutter_driver`'s `runUnsynchronized` under a name that says what it disables. Some apps never go idle: a spinner, a progress indicator, a hand-rolled caret, any perpetual `AnimationController` holds a transient frame callback for as long as it runs, so *every* command against such an app spends its whole `timeoutMs` and fails. What you give up is the guarantee the wait exists for — an immediate `getText` after an unsynchronised `tap` races the rebuild and reads the pre-action value about as often as not — so resynchronise with `app.waitFor` on the value you expect rather than reading straight back. `settle` takes `"true"` or `"false"` and rejects anything else: a typo here would otherwise choose the opposite behaviour in silence.

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

## Release builds and permissions

**`flutter create`'s scaffold grants network access in debug only, and these
rules reproduce that faithfully.** An app that networks perfectly under
`-c dbg` can be silently offline under `-c opt`: there is no build error, no
runtime exception, and nothing in the app's own log — just an app that never
reaches anything. Every platform has the same shape, because on every
platform the debug-only grant exists for the *Dart VM service*, not for the
app.

| Platform | What debug has that release does not | Why it is there |
|----------|--------------------------------------|-----------------|
| macOS | `com.apple.security.network.server`, `com.apple.security.cs.allow-jit` in `DebugProfile.entitlements`; `Release.entitlements` declares only `app-sandbox` | The sandbox must let the VM service bind and the JIT engine map executable pages |
| Android | `android.permission.INTERNET`, from `android/app/src/debug/AndroidManifest.xml` | Android enforces `INTERNET` at the kernel level (AID_INET group membership) — without it the VM service cannot bind even a loopback socket |
| iOS | `NSBonjourServices`, `NSLocalNetworkUsageDescription`, merged by these rules into non-release builds | The engine advertises the VM service over mDNS |

None of that is the app's network grant, and none of it survives into
release. An app that networks for itself must say so, once, in a way that
applies to every compilation mode:

```starlark
flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    additional_entitlements = ["entitlements/Network.entitlements"],
)

flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    additional_entitlements = ["entitlements/Network.entitlements"],
)

flutter_android_app(
    name = "my_app_android",
    application = ":my_app",
    package_name = "com.example.myapp",
    permissions = ["android.permission.INTERNET"],
)
```

where `entitlements/Network.entitlements` is an ordinary plist fragment:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
```

These attributes are **additive**, which is the point: they merge into
whichever base the compilation mode selected, so one declaration covers
debug and release both, and `flutter create`'s files stay untouched.

- A key the base already declares with the *same* value is deduped —
  `DebugProfile.entitlements` already grants `network.server`, so declaring
  it above is safe in both configurations.
- A key the base declares with a *different* value is a hard error naming
  the key and both files, rather than a silent winner.
- `com.apple.security.network.client` is absent from **both** scaffold
  files. Most Flutter apps network through `NSURLSession`, which the sandbox
  exempts; a raw socket is not exempt. If you open one, you need this key.

### iOS Local Network Privacy

iOS 14+ gates LAN access behind `NSLocalNetworkUsageDescription` and
`NSBonjourServices`. These rules add both to non-release builds for the Dart
VM service and drop them in release, which is correct — they are the
debugger's, not the app's. An app that needs LAN access **for itself**
declares them in `ios/Runner/Info.plist`, where they survive into `-c opt`;
the rules merge the VM service keys into that file, keeping your usage
description and unioning your Bonjour service list with
`_dartVmService._tcp`.

> The iOS **simulator** does not enforce Local Network Privacy at all, so a
> simulator build proves nothing about these keys. Only a physical device
> does.

### Verifying, rather than assuming

These are exactly the defects a `build_test` cannot see. Check the artifact:

```sh
# macOS — the entitlements codesign actually embedded
unzip -oq bazel-bin/my_app_macos.zip -d /tmp/app && \
  codesign -d --entitlements - "/tmp/app/My App.app"

# Android — the compiled manifest inside the APK
aapt2 dump xmltree --file AndroidManifest.xml bazel-bin/my_app_android.apk

# iOS — the processed Info.plist inside the .ipa
unzip -oq bazel-bin/my_app_ios.ipa -d /tmp/ipa && \
  plutil -p "/tmp/ipa/Payload/my_app_ios.app/Info.plist"
```

Bazel's default `fastbuild` is *not* `-c dbg`, so a plain `bazel build`
already takes the release arm of each of these selects. `e2e/macos_example`,
`e2e/android_example` and `e2e/ios_example` each carry a test that reads the
built artifact this way.

## Running an iOS example on a physical device

iOS simulator builds need no code signing and run out of the box (e.g.
`flutter_bazel run -t //:hello_world_ios -d ios-simulator`). Device builds need
signing, which is per-developer and must stay out of version control.

`flutter_ios_app` takes the credential directly:

```starlark
load("@rules_apple//apple:apple.bzl", "local_provisioning_profile")

# In a git-ignored //device package, so the credential stays local.
local_provisioning_profile(
    name = "profile",
    profile_name = "iOS Team Provisioning Profile: *",
    tags = ["manual"],
)
```

```starlark
flutter_ios_app(
    name = "my_app_ios_device",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    provisioning_profile = "//device:profile",
)
```

That is the whole difference from the simulator target — the device bundle is
the same construction, not a second hand-assembled one. `flutter_ios_app`
defaults to `tags = ["manual"]`, so `bazel build //...` on a fresh clone does
not expand the target and therefore does not load the missing `//device`
package.

The same split applies when the app is hand-assembled from the Tier-2 `_gen`
rules: give the device `ios_application` `provisioning_profile` and the same
`deps` list as the simulator one, and keep both in the committed BUILD file.
Only `local_provisioning_profile` belongs in `//device` — it is the one fact
that is genuinely per-developer. Putting the assembly there instead hides it
from review, from CI and from every refactor, and it drifts: two of this
repository's own examples had a git-ignored device app that had silently
diverged from its committed simulator twin.

**Naming the profile.** `profile_name` matches the profile's `Name` field,
which is *not* always `iOS Team Provisioning Profile: <bundle id>`. Xcode mints
a per-bundle-id profile only for an App ID registered explicitly in the
developer portal; for an unregistered id — which an example or scratch app's
usually is — automatic signing issues the team **wildcard** profile instead,
named `iOS Team Provisioning Profile: *` over App ID `<TEAM>.*`, and that is
what covers your bundle id. List what you actually have:

```sh
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -extract Name raw -
done
```

Without `provisioning_profile`, a device build fails at analysis with
*"The provisioning_profile attribute must be set for device builds on this
platform (ios)"*.

**Obtaining the profile.** This is an Apple Developer account operation and
these rules cannot do it for you. You need a development provisioning profile
whose App ID matches your `bundle_id`, installed in
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Either:

- **From the Developer portal** — create the App ID and a development profile,
  download it, and double-click it. This works for any repository layout.
- **From any Xcode project** whose `PRODUCT_BUNDLE_IDENTIFIER` is your bundle
  id, using automatic signing:
  ```sh
  xcodebuild -project <some>.xcodeproj -scheme <scheme> -configuration Debug \
    -destination generic/platform=iOS \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
  ```
  Note this needs an `.xcodeproj`, and a `flutter create --platforms=ios .`
  tree checked into a Bazel repository has no reason to keep one —
  `flutter_ios_app` only ever reads `ios/Runner/*.swift` and
  `ios/Runner/Info.plist`. The project can be any scratch project with the
  right bundle id; it does not have to be, and usually is not, the app you
  are building with Bazel.

Free ("Personal Team") profiles expire after about seven days; when a build
fails with *"no provisioning profile was found named …"*, mint a fresh one the
same way.

Then: `flutter_bazel run -t //:my_app_ios_device -d ios`. Each iOS example
also ships a `device.example/` template — copy it to a git-ignored `device/`
package and set your bundle id.

## Observing an iOS release build

There is no way to *run* a release-configured iOS build without a signing
credential, which matters because release-only defects (see
[Release builds and permissions](#release-builds-and-permissions)) are found
by running, not by reading.

- **Device, `-c opt`** — the real thing, and it needs a provisioning profile.
- **Simulator, `-c opt`** — builds a complete `.ipa` with no warning, and
  `xcrun simctl install` and `launch` both return 0 and print a pid. The
  process then stays alive and renders **blank white forever**. It never
  crashes, so nothing appears in a crash log. The simulator slice of the
  engine is JIT and looks for `flutter_assets/kernel_blob.bin`, which an AOT
  bundle does not contain; the only evidence is in the simulator's system log:
  ```
  (Flutter) Failed to find snapshot at .../App.framework/flutter_assets/kernel_blob.bin
  (Flutter) [ERROR:flutter/shell/common/engine.cc(219)] Engine run configuration was invalid.
  ```
  Read it with
  `xcrun simctl spawn booted log show --last 5m --predicate 'eventMessage CONTAINS "kernel_blob"'`.

Use `-c dbg` on the simulator, and a device for release.

## License

See [LICENSE](LICENSE).
