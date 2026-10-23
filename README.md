# rules_flutter

Bazel rules for building Flutter apps.

> **Status: alpha.** It works today, but the public API may still change. Feedback and contributions are welcome.

rules_flutter compiles Dart to kernel or AOT native code, bundles assets, and packages the result for macOS, iOS, Android, Linux, Windows, and the web. It builds on [rules_dart](https://github.com/aran/rules_dart) for Dart compilation and hands platform packaging to the rulesets that already do it well: `rules_apple`, `rules_android`, and friends. It also ships a dev tool, `flutter_bazel`, that gives you hot reload, hot restart, and an HTTP channel for driving a running app from a script.

## Why build Flutter with Bazel

If `flutter build` works for you, here is what Bazel adds:

- **Reproducible builds.** Every input is tracked, so the same source produces the same output on every machine.
- **Remote caching.** Build outputs are content-addressed and shared across a team. A change to one package rebuilds only what depends on it.
- **Remote execution.** Compile on cloud workers, and build macOS, Linux, and Android targets from one `bazel build`.
- **One build graph.** Flutter apps, backend services, Rust and C++ libraries, and infrastructure code live together with real dependency tracking.
- **Native code without a second build system.** Depend on `cc_library`, `rust_shared_library`, or `swift_library` targets directly. No CMake, Gradle, or CocoaPods.
- **No build_runner.** Code generators such as json_serializable and freezed run as ordinary Bazel actions.

## Contents

- [Getting started](#getting-started)
- [Flutter SDK versions](docs/flutter-sdk-versions.md): pins, custom releases, offline SDKs, mirrors
- [Dependencies](#dependencies): pub packages, build hooks, native code
- [Building for each platform](#building-for-each-platform): macOS, iOS, Android, Linux, Windows, web, cross-compiling, release permissions
- [Rules reference](#rules-reference): libraries, applications, tests, plugins, code generation, providers
- [Incremental kernel compiles](docs/incremental-kernel.md): the opt-in warm `frontend_server` worker for debug builds
- [The dev tool](#the-dev-tool): running apps, hot reload, driving an app from a script
- [Examples](#examples)

## Getting started

### Requirements

| Platform | What you need |
|---|---|
| All | Bazel 9 or newer. The rules download Flutter 3.47.7 themselves. |
| macOS | Xcode, for `rules_apple` and `rules_swift`. |
| iOS | Xcode. The simulator needs no signing identity. A physical device does; see [Running on an iOS device](#running-on-an-ios-device). |
| Android | The Android SDK and NDK, with `ANDROID_HOME` and `ANDROID_NDK_HOME` set. See [Android](#android). |
| Linux | A C++ toolchain. From macOS, an LLVM cross-toolchain. |
| Windows | MSVC for native builds. From macOS or Linux, a C++ cross-toolchain, debug builds only. |
| Web | Nothing extra. Compiling Dart to WASM or JavaScript is fully hermetic. |

### MODULE.bazel

`rules_flutter` is released from the [`Mivr/rules_flutter`](https://github.com/Mivr/rules_flutter) fork together with the [`Mivr/rules_dart`](https://github.com/Mivr/rules_dart) fork it builds on. Take both from the GitHub releases with `archive_override` in your root `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_flutter", version = "0.5.0")
bazel_dep(name = "rules_dart", version = "0.11.1")

archive_override(
    module_name = "rules_flutter",
    urls = ["https://github.com/Mivr/rules_flutter/releases/download/v0.5.0/rules_flutter-v0.5.0.tar.gz"],
    integrity = "sha256-nJoGOvU1GLkZnWw8QrpzyyhkWL5K8Ia5SIksLM8tJhc=",
    strip_prefix = "rules_flutter-0.5.0",
)

archive_override(
    module_name = "rules_dart",
    urls = ["https://github.com/Mivr/rules_dart/releases/download/v0.11.1/rules_dart-v0.11.1.tar.gz"],
    integrity = "sha256-cBJ3Yu142yo14j9nlaR4nzR5nef9+RQO/yCy3uwCER8=",
    strip_prefix = "rules_dart-0.11.1",
)

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(flutter_version = "3.47.7")
flutter.pub(
    name = "deps",
    lock = "//:pubspec.lock",
)
use_repo(flutter, "deps", "flutter_toolchains")

register_toolchains("@flutter_toolchains//:all")
```

`flutter.toolchain` downloads the Flutter SDK and engine. `flutter.pub` reads your `pubspec.lock` and creates a repository, here named `deps`, with one target per package: `@deps//:flutter`, `@deps//:flutter_test`, `@deps//:collection`, and so on. See [Pub packages](#pub-packages).

Some platforms need one more repository from the same extension. Add it to `use_repo` when you build for that platform:

| Platform | Add to `use_repo` |
|---|---|
| macOS | `flutter_macos_engine` |
| iOS | `flutter_ios_engine` |
| Android | `flutter_android_engine_arm64`, or `flutter_android_engine_x64` for `android_abi = "x64"` |
| Web | `flutter_web_sdk` |

Static analysis needs nothing extra. rules_dart's analysis resolves `dart:ui` in a `flutter_library`, `flutter_plugin` or `flutter_test` through the `sky_engine` package, which those rules add to the analyzer's closure themselves. Their compiled output does not change.

### Flutter SDK versions

The stock release is pinned by `flutter.toolchain(flutter_version = ...)`, and every SDK byte it downloads is verified against a sha256 recorded in `flutter/private/versions.bzl` — a missing checksum fails the fetch rather than accepting unverified bytes. Your root module's pin wins over any version a dependency requests.

Two extensions cover the rest. A root-registered custom release (an older stable, a rebuild, an enterprise engine) carries its own pinned checksums through `flutter.version`, and `flutter.toolchain(local_path = ...)` sources every repository out of a pre-extracted SDK on disk instead of the network. To mirror stock bytes, keep the stock version and point Bazel at the mirror with `--downloader_config` so the recorded checksums still verify everything. See [Flutter SDK versions](docs/flutter-sdk-versions.md).

#### Overriding `rules_dart`

`rules_flutter` uses APIs from the [`Mivr/rules_dart`](https://github.com/Mivr/rules_dart) fork (`@rules_dart//dart:hooks.bzl`, `@rules_dart//dart/private:record_use.bzl`, and `dart_codegen(package_name = ...)`) that are not in the `rules_dart` releases on the Bazel Central Registry. Its floor is `rules_dart` 0.11.1, a fork release, so a root module that overrides only `rules_flutter` fails fast with a version error instead of a missing-symbol error at load. The `archive_override` pair in [MODULE.bazel](#modulebazel) above is the supported setup; every downloaded byte is verified against its `integrity` hash.

To live at the forks' heads instead (local development against a checkout of each), replace the two `archive_override` blocks with overrides onto your clones. Because Bzlmod ignores module overrides in non-root modules, the overrides go in your root `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_dart", version = "0.11.1")

git_override(
    module_name = "rules_dart",
    commit = "dc0b9a23bf74fc832c89a8f5a0f95d999c8a6f0a",
    remote = "https://github.com/Mivr/rules_dart.git",
)
```

with the matching `local_path_override` (or `--override_module`) for `rules_flutter` itself, as the `e2e/*` workspaces show.

### .bazelrc

Two settings are required. Paste them into your project's `.bazelrc`:

```bazelrc
# rules_flutter's Java dependencies (rules_jvm_external 7+, rules_android 0.8+)
# ship tool jars compiled for Java 21+. Bazel's default tool JDK is older.
common --tool_java_language_version=25
common --tool_java_runtime_version=remotejdk_25

# Windows only: lets Bazel create real symlinks (runfiles trees and SDK
# layouts use them where available) instead of falling back to copies.
startup --windows_enable_symlinks
```

Without the Java settings you get `UnsupportedClassVersionError` when an action runs, or `could not locate class file for java.lang.Record` when one compiles.

### Your first app

Start from a project made with `flutter create`. It has `lib/main.dart`, a `pubspec.yaml`, and one folder per platform. rules_flutter reads those files as they are. You add a `BUILD.bazel`:

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_application")
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    assets = glob(["assets/**"]),
    deps = [
        "@deps//:flutter",
        "@rules_flutter//flutter:material_icons",
    ],
)

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.my_app",
)
```

`flutter_application` compiles the Dart code and bundles the assets. Each platform then has a macro, like `flutter_macos_app`, that wraps it in a runnable app. Two attributes deserve a note:

- `package_name` must match the `name:` field in `pubspec.yaml`. Hot reload and code generation both rely on it.
- `@rules_flutter//flutter:material_icons` bundles the Material icon font. Any app that uses Material widgets needs it in `deps`.

Build it, or run it with hot reload:

```sh
bazel build //:my_app_macos
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_macos -d macos
```

The second command is long. [Shorter commands with bazel_env](#shorter-commands-with-bazel_env) turns it into `fl run -t //:my_app_macos -d macos`.

### Build modes

Bazel's compilation mode flag selects how the Dart is compiled:

| Flag | Mode | Dart compilation | Use it for |
|---|---|---|---|
| `-c dbg` | Debug | Kernel `.dill`, run by the JIT | Development, hot reload |
| none (fastbuild) | Release | AOT native code | CI, tests |
| `-c opt` | Release | AOT native code, stripped | Production |
| `-c opt --@rules_flutter//flutter:profile` | Profile | AOT native code, stripped, with the Dart VM service | Measuring performance with DevTools |

Note that a plain `bazel build` is a release build, not a debug one. That matters for [permissions](#release-builds-and-permissions).

Profile mode is `flutter run --profile`: release-speed code that still serves the Dart VM service, so DevTools can record timelines and CPU profiles. It has no hot reload. Profile uses its own engine and gen_snapshot on every platform, downloaded the first time a profile build needs them, because the engine refuses a snapshot compiled for a different mode. The flag needs `-c opt`, and the build fails if it is set with any other `-c`. Like upstream Flutter, there is no profile mode for the iOS simulator: build profile for a physical device. A `.bazelrc` config saves typing:

```
build:profile -c opt --@rules_flutter//flutter:profile
```

## Dependencies

### Pub packages

`flutter.pub` turns `pubspec.lock` into Bazel targets. Every package in the lock gets a target in the hub repository: `@deps//:collection`, `@deps//:url_launcher`, `@deps//:flutter_test`. List them in `deps` like any other target:

```starlark
flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = [
        "@deps//:flutter",
        "@deps//:collection",
        "@deps//:url_launcher",
        "@rules_flutter//flutter:material_icons",
    ],
)
```

Plugins need no special treatment. A pub package that is a Flutter plugin arrives as a plugin target, and the platform macros register it and build its native code. On Android the hub also exposes `@deps//android:all_android_plugin_libs`, the Kotlin and Java of every plugin, and `flutter_android_app` adds it to the APK for you.

Permissions a plugin declares in its own manifest, such as `record_android`'s `RECORD_AUDIO`, reach the app's manifest as they do under Gradle. You don't need `--merge_android_manifest_permissions`.

### Path dependencies

A `path:` entry with `relative: true` in the lock is resolved against the lock file's own directory and linked into a `flutter_pub_path_package` spoke as a tree of symlinks, so the workspace never copies the package. The spoke links only what its generator reads or exposes — `lib/`, the pubspec, hook scripts, declared assets, fonts, and shaders (plus each shader's own directory), and the plugin's declared platform directories — parsed from the package's own `pubspec.yaml` and mirrored one file at a time into real repository directories. `example/`, `build/`, `.dart_tool/`, dot-directories, undeclared files, and the package's own BUILD files stay unlinked (skipped subtrees are not even watched), so machine-local output such as `example/build/` or a `.plugin_symlinks` cycle can never affect the fetch; real directories (never whole-directory symlinks) mean the generated BUILD files land in the spoke, never in the user's source tree. Every linked file and directory is watched, so adding, changing, or removing one refetches the spoke; without the watch, files added inside nested asset directories would stay invisible until something else retriggered the fetch. A source symlink resolving to the package or one of its ancestors fails the fetch naming the package and the link, and a path that escapes the workspace, or resolves to the workspace root itself, fails the extension evaluation rather than symlinking outside the workspace. Shader `shader_includes` cover only the declared shaders' own directories, so `example/build/` output can never become an include.

The lock must belong to the root module. A `relative: true` path resolves in the lock-owning module, and module-extension label attributes already resolve in the defining module while the spoke's `workspace_root` is always the root module, so a lock owned by a non-root module has no repository-local root to resolve against; resolving it in the consumer workspace would silently link the wrong directory. A path dependency locked by another module therefore fails the extension evaluation, naming the hub, the package, and the owning module — declare the `path:` dependency in the root module's own lock instead.

### Platform- and flavor-conditional assets

A pub package's `flutter.assets` entries may carry `platforms` and `flavors` lists, and the bundle keeps exactly what `flutter_tools` keeps (verified against Flutter 3.47.7: `asset.dart` `matchesFlavor` at line 1532 runs before `matchesPlatform` at line 1544 in `ManifestAssetBundle`, lines 1119–1128; `TargetPlatform.osName` in `build_info.dart`, line 701). Flavor is checked first: a flavor-restricted entry bundles only when a flavor is selected, and rules_flutter selects none yet, so flavor-restricted entries bundle nowhere — on every platform, `tester` included. Then platform: an empty list or the `tester` platform keeps the asset, anything else must name the target platform. So an Android build bundles `android`-listed entries but not `web`-listed ones, while a widget test bundles every platform's entries (but still no flavor-restricted ones).

An entry naming a platform Flutter does not know fails the package fetch, naming the package, the asset entry, and every valid name (`android`, `ios`, `linux`, `macos`, `web`, `windows` — the `_kValidPluginPlatforms` set `flutter_manifest.dart` validates against, lines 20 and 909). A misspelled platform would otherwise bundle nowhere on every target, silently. Directory entries (a trailing-slash `path`) expand to every file underneath at fetch time, each file inheriting the entry's conditions. When several entries expand to the same file, the file bundles on the union of the entries' platforms: any entry without `platforms` makes the file unconditional, otherwise the file ships wherever any of its entries ships. Entries for one file whose `flavors` sets differ fail the package fetch, naming the package, the file and both flavor lists (equal sets in a different order agree). Packages without conditions emit no extra attributes, so their spokes are byte-identical to before.

### Android native (Gradle) dependencies

A plugin's `android/build.gradle` (`build.gradle.kts`) runtime dependencies (`implementation`, `api`, `runtimeOnly`) are translated to `@rules_android_maven` labels automatically. Gradle evaluates exactly one build file per project directory, so when both files are present the rule reads `build.gradle` for everything — dependencies, namespace, native-build and ProGuard detection alike. Common AndroidX artifacts are built in; anything else must be mapped in `MODULE.bazel`:

```starlark
flutter.pub(
    name = "deps",
    lock = "//:pubspec.lock",
    android_maven_deps = {
        "com.example:thing": "@rules_android_maven//:com_example_thing_thing",
    },
)
```

A plugin dependency found in neither table fails the spoke fetch naming the package, the build file, and every offending entry — a missing native library would otherwise compile and crash on the device. A coordinate that genuinely needs no label goes in `android_maven_ignore`; declarations that are not Maven coordinates at all (version-catalog `libs.*` refs, variables, local jars) need a plugin overlay instead, via `flutter.plugin_overlays`.

The parser reads the build script statement by statement (comments stripped outside string literals; statements split on newlines, `;`, `{` and `}` at bracket depth 0, so a parenthesised call spanning lines reads as one statement), so layout is insignificant: a single-line `dependencies { implementation '...' }`, two declarations on one line separated by `;`, and Gradle's `add('implementation', '...')` (single- or double-quoted, both DSLs) all resolve. Only `dependencies` blocks outside `buildscript` count. `apply from:` scripts in every DSL spelling (`apply from: 'x.gradle'`, `apply(from: 'x.gradle')`, `apply(from = "x.gradle.kts")`) are read when the path stays inside the package, recursively, with cycle detection and a depth cap. The Android namespace is read from the same statement model (`namespace` in any `android` block, even on one line or nested, or top-level `android.namespace = ...`; the last declaration wins; commented-out or string-embedded declarations never count). Anything unmodellable fails the fetch instead of dropping the dependency: nested blocks such as `constraints {}`, `dependencies` mentions outside the block form (`project.dependencies.add(...)`), map notation, catalog refs, variables, interpolated coordinates, an unbalanced bracket, a non-literal namespace, and `apply from:` with a URL, an absolute or escaping path, a missing file, or a non-literal argument. The plugin's Android namespace must be a valid Java package name, and every `android_maven_deps` value must be a label (`@...` or `//...`); anything else fails naming the plugin or the key.

### Regenerating pubspec.lock

Bazel reads `pubspec.lock` and never writes it. To regenerate it, use the Flutter toolchain the rules pin rather than a Flutter installed on your machine:

```sh
bazel run @rules_flutter//flutter:pub -- get       # after editing pubspec.yaml
bazel run @rules_flutter//flutter:pub -- upgrade
bazel run @rules_flutter//flutter:pub -- add qr
```

Arguments pass through to `dart pub` unchanged, and the command runs at your workspace root, so the lock lands where `flutter.pub` reads it.

The version of Flutter that resolves the lock matters, and a mismatch is easy to miss. Pub treats the running Dart and Flutter versions as constraints, so an older installation quietly picks older packages, and the lock it writes is still valid. For example, resolving `e2e/plugin_example` with Flutter 3.41.6 pins `meta 1.17.0`, while the pinned 3.44.1 toolchain pins `meta 1.18.0`. Nothing downstream can tell the difference.

The fetched toolchain contains engine artifacts and a Dart SDK but no `bin/flutter`, so this target runs `dart pub` with `FLUTTER_ROOT` pointed at a tree assembled from the same Flutter release. That tree is fetched the first time you run the target. Because it is `dart pub` rather than `flutter pub`, it writes `pubspec.lock` and `.dart_tool/package_config.json` and does not write `.flutter-plugins-dependencies`. rules_flutter generates plugin registrants from the build graph, so nothing needs that file.

A package below the workspace root, such as a `tools/*` package, is resolved by the same target with pub's `--directory` flag. The path is relative to the workspace root:

```sh
bazel run @rules_flutter//flutter:pub -- get --directory tools/my_tool
```

### Packages with build hooks

Some pub packages compile native code through a Dart `hook/build.dart` (Dart Native Assets). Bazel does not run those hooks. Instead:

- **Curated replacements.** rules_dart keeps a registry of Bazel-native equivalents (`@rules_dart//dart/ext:registry.bzl`). Where one exists, such as `sqlite3`, `flutter.pub` attaches it automatically. An app that depends on `drift` gets `libsqlite3` without naming it.
- **Overlays.** For a package with a hook and no curated entry, you can write a `BUILD.bazel.tpl` that reproduces what the hook builds. rules_flutter bundles overlays under `ext/`, and you can add your own with `flutter.plugin_overlays(roots = [...])`. Authoring one is described in [docs/TESTING.md](docs/TESTING.md) under "Native Assets overlay authoring".
- **Ignoring a hook.** If a package's native code is never reached in your app, say so: `flutter.pub(ignore_hooks = ["<package>"])`.

A hook that nothing replaces is an error when `flutter_application` reaches it. The alternative would be a build that succeeds and then fails at runtime on an unresolved `@Native` symbol.

### Native code from Bazel

A Flutter app can depend on native code built by any Bazel rule that produces a shared library: `rules_cc`, `rules_rust`, and so on. List the library in `native_deps` and it is bundled beside the app, where `dart:ffi` can open it:

```starlark
cc_shared_library(
    name = "my_native_lib",
    deps = [":my_cc_lib"],
)

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    native_deps = [":my_native_lib"],
    deps = ["@deps//:flutter"],
)
```

If you would rather bind with `@Native(assetId: ...)` and let the Dart VM find the library, declare it as a Native Asset with `flutter_native_asset` from `@rules_flutter//flutter:native_assets.bzl`, and carry it on a `flutter_plugin`. `e2e/ffi_example` shows both styles side by side.

#### Hot reload across a native rebuild

A running process cannot pick up a rebuilt native library; it keeps the one it already loaded. So when a native library goes stale under a hot reload, the dev tool has to decide whether the Dart it is about to inject still matches that library. Without more information it withholds the reload, and a pending native change blocks your Dart edits until you restart.

The build tells it which files each native library is built from, so a reload notices an edit to a `.c` or `.rs` file even in an app that runs no build of its own — the reload stats those files, and nothing more. Before that, such an app reported a reload as successful while it went on running the machine code it launched with.

You can tell it what the bindings were generated from, and then it can decide:

```starlark
flutter_native_library(
    name = "bridge",
    library = "@my_bridge//bridge:bridge_shared",
    binding_contract = ["@my_bridge//bridge:codegen.ir"],
)

flutter_application(
    name = "my_app",
    native_deps = [":bridge"],
    # ...
)
```

`binding_contract` is whatever file decides what may be called and how: a binding generator's interface description, or the C header a hand-written FFI binding follows. The dev tool compares the bytes of those files and nothing else, so what matters is that every change to the wire format shows up in them, and that changes which do not affect the wire do not.

With that declared, a reload has three outcomes:

| What changed | What the reload does |
|---|---|
| Nothing native | Ordinary reload. |
| The library's code, but not its contract | Delivers the edit and reports that the native code in the process is stale. |
| The contract | Withholds the edit. Restart to pick up the new library — unless the library declares a `hot_patch` builder, which is asked instead (below). |

#### Patching native code into a running app

A process cannot replace a library it has loaded, but it can load a second one and send calls there. If the toolchain that builds your library can build such a patch, and the library routes its calls so that a patch can take them over, a hot reload delivers a native edit into the running app the way it delivers a Dart edit: state kept, no relaunch. Name the target that builds patches as `hot_patch`:

```starlark
flutter_native_library(
    name = "bridge",
    library = "@my_bridge//bridge:bridge_shared",
    binding_contract = ["@my_bridge//bridge:codegen.ir"],
    hot_patch = "@my_bridge//bridge:bridge_hot_patch",
)
```

On each hot reload the dev tool checks the source files that target declares. When none moved, that is a `stat` per file and nothing else. When one did, it builds the patch for the configuration the app is running in, puts it where the app can load it (signed with the app's own identity on an iOS device), has the app load it, and then applies the Dart half of the edit. A widget that shows a native result is rebuilt, so the new answer appears even when no Dart changed.

| What changed | What the reload does |
|---|---|
| A function body | Patches it into the running app. The reply names the library and what was patched. |
| The contract | Asks the patch builder, which is the half that holds both interfaces. A patch that carries the new surface — a bridged function added, say — is delivered like any other. |
| Anything the builder says a patch cannot carry (a struct's layout, say) | Withholds the edit and says why, in the builder's words. Restart to pick it up. |
| An edit undone after it was patched | Sends calls back to the code the app launched with. |

A restart (`R`) is still the reset: if any patch is live, or the rebuilt bundle differs from the launched one, it relaunches the app.

What a `hot_patch` target builds, and what the library exports, is a small contract documented on the attribute in `flutter/private/flutter_native_library.bzl`. `e2e/ffi_example` implements it by hand for a C library (`native/mul_hot_patch.c` and `tools/c_patch_tool.dart`), and its `live 3 × 4` line changes on screen when you edit `native/mul.c` and press `r`. Anything created before a patch keeps the code it was created with, as with Dart closures.

Patches reach apps on macOS, the iOS simulator, iOS devices and Android. Linux, Windows and web apps report the edit the way they did before: stale until restart.

On the web the same wrapper goes in `flutter_web_bundle`'s `native_modules`, which both serves the `.wasm` module and declares it. The situation is the same: the page instantiates the module once and a hot reload does not re-run `main()`. A web hot restart does re-run `main()`, so it re-fetches the module with no relaunch.

### Bazel modules

What a plain consumer's module graph pulls in, by feature. Floors are what `rules_flutter`'s own `MODULE.bazel` declares; higher versions resolve by MVS as usual, except where noted.

| Feature | Modules | Notes |
|---|---|---|
| Every app | `rules_dart` 0.11.1 (the `Mivr` fork release, taken via `archive_override` above), `bazel_skylib`, `platforms`, `package_metadata` | Dart compilation, hooks, codegen. |
| iOS / macOS bundles | `rules_apple` ≥ 4.5.3, `rules_swift`, `apple_support`, `rules_cc` | 4.5.3 is the proven floor: `e2e/min_versions` pins it exactly and builds both Apple legs. `rules_swift`/`apple_support` float to the graph's maxima (4.5.3 accepts Swift at compatibility level 3). |
| Android APK | `rules_android` 0.8.0, `rules_kotlin`, `rules_java`, `rules_jvm_external` 7.1, `rules_go` ≥ 0.59.0 | 0.8.0 is the floor: the signing overlay reads `rules_android`'s `apk_signing_method` flag, which exists only in 0.8.0+. The pinned `go_sdk.download` (Go 1.26.2, checksummed) in `rules_flutter`'s `MODULE.bazel` applies to every consumer without its own `go_sdk` block — it sorts before `rules_android`'s bundled unpinned 1.22.4 whatever order the root lists the modules in, while a root `go_sdk` block still wins; plain consumers fetch no Go SDK until a Go toolchain resolves. The `.bazelrc` Java settings above are required, and the build host needs `unzip` and `python3` for the AAR extractors. |
| xtool Darwin backend (opt-in) | `llvm` 0.8.19, exec-host toolchain archive only | Needs only `flutter.darwin_sdk(url = ..., sha256 = ...)` or `flutter.darwin_sdk(path = ...)` in the root module — no other `MODULE.bazel` lines. Plain consumers fetch no LLVM archive and register no LLVM toolchain (see `docs/dependencies.md`). |
| Dev tool, `gen_l10n` | Resolved inside `rules_flutter` | `dev_tool_deps` and `gen_l10n_deps` are the ruleset's own `flutter.pub` hubs; consumers never name them. |
| No feature | No `rules_python` | The iOS screenshot/tunnel helpers are `dart_binary` drivers over a host `python3` (a documented host prerequisite like Xcode), so neither this repo's graph nor any consumer's contains `rules_python`. |

Dev-only and never evaluated by consumers: `rules_multitool`, `buildifier_prebuilt`, `bazelrc-preset.bzl`, the eight `@llvm//toolchain:*` registrations, and the root-only `single_version_override` pinning this repo's own builds to `rules_apple` 5.2.0. (The `go_sdk.download` pin, by contrast, is a regular dependency so every consumer's Android host tools use it; it only downloads when a Go toolchain resolves. `llvm` itself is a regular dependency so the opt-in xtool backend can resolve it, but only a configured `flutter.darwin_sdk` — or this repo's own builds — fetches a toolchain archive.)

## Building for each platform

Every platform has two levels of API:

- **A convenience macro** such as `flutter_macos_app`. It finds the runner files `flutter create` wrote, wires up every internal target, and is what most apps should use.
- **Composable rules** such as `flutter_macos_runner_lib_gen`, for when you need control over a piece the macro decides for you. Each platform section shows them in a collapsed block.

The macros take `flutter create` output as it is. You do not need to edit the generated `Runner` folders.

### macOS

Requires Xcode. Run `flutter create --platforms=macos .` first so `macos/Runner/` exists.

```starlark
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    app_name = "My App",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `bundle_id` | The macOS bundle identifier. Required. |
| `app_name` | Display name for the menu bar and window title. Defaults to the target name. |
| `minimum_os_version` | Defaults to `"12.0"`, which is what the prebuilt engine is built for. A lower value is refused rather than warned about. |
| `info_plist` | Replaces the discovered `macos/Runner/Info.plist`. |
| `version` | An `apple_bundle_version` target. Defaults to `"1.0"`. |
| `entitlements` | Replaces the entitlements wiring. By default the macro finds `macos/Runner/DebugProfile.entitlements` and `Release.entitlements` and picks one by compilation mode. |
| `additional_entitlements` | Entitlement plist files merged into the selected base in every compilation mode. See [Release builds and permissions](#release-builds-and-permissions). |
| `app_icons` | Defaults to the `AppIcon.appiconset` in `macos/Runner/Assets.xcassets`. See [App icons](#app-icons). |
| `runner_deps` | `swift_library` targets linked into the runner. See [App Intents](#app-intents). |

The output is a `.app` bundle containing `FlutterMacOS.framework`, `App.framework`, and `flutter_assets/`.

<details>
<summary>Composable rules</summary>

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

# rules_apple's `entitlements` takes one file. This merges additions into it.
# Additions only; a key present in both with different values is an error.
# Also exported from flutter:ios.bzl.
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

Requires Xcode. Run `flutter create --platforms=ios .` first so `ios/Runner/` exists, and add `flutter_ios_engine` to `use_repo`.

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_app")

flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `bundle_id` | The iOS bundle identifier. Required. |
| `families` | Device families. Defaults to `["iphone"]`, unlike `flutter create` (iPhone and iPad). An iPhone-only app runs in a small window on iPadOS. Adding `"ipad"` needs an icon set without the 76x76@1x iPad icon `flutter create` generates, which `actool` rejects. |
| `app_name` | Display name. Defaults to the target name. |
| `minimum_os_version` | Defaults to `"15.0"`, which is what the prebuilt engine is built for. A lower value is refused rather than warned about. |
| `info_plist` | Replaces the discovered `ios/Runner/Info.plist`. |
| `version` | An `apple_bundle_version` target. Defaults to `"1.0"`. |
| `launch_storyboard` | Replaces the launch storyboard. |
| `entitlements` | Replaces the entitlements wiring. By default the macro uses `ios/Runner/Runner.entitlements` if it exists. An app with no entitlements file is fine. |
| `additional_entitlements` | Entitlement plist files merged into the base in every compilation mode. Works even when the app has no entitlements file. See [Release builds and permissions](#release-builds-and-permissions). |
| `provisioning_profile` | A `.mobileprovision` file, usually a `local_provisioning_profile` target. Required for device builds, unused by simulator builds. See [Running on an iOS device](#running-on-an-ios-device). |
| `app_icons` | Defaults to the `AppIcon.appiconset` in `ios/Runner/Assets.xcassets`. See [App icons](#app-icons). |
| `runner_deps` | `swift_library` targets linked into the runner. See [App Intents](#app-intents). |
| `exclude_plugins` | Plugin module names left out of the registrant. iOS only: the Android, Linux, macOS and Windows registrants take no such attribute and always register every collected native plugin. See [iOS plugin registrant](#ios-plugin-registrant). |

`rules_apple`'s `ios_application` handles the transition to iOS arm64.

<details>
<summary>Composable rules</summary>

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

# Frameworks for the app's Native Assets and `native_deps` libraries. If you
# leave this out of `deps` below, the app builds and renders normally and
# then fails every native call at runtime.
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
    minimum_os_version = "15.0",
    deps = [":my_framework", ":my_native_frameworks", ":my_runner"],
)
```

</details>

#### Running on an iOS device

Simulator builds need no code signing. Device builds need a provisioning profile, which is per-developer and should stay out of version control. `flutter_ios_app` takes it directly:

```starlark
# In a git-ignored //device package, so the credential stays local.
load("@rules_apple//apple:apple.bzl", "local_provisioning_profile")

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

That is the only difference from the simulator target, unless the app ships entitlements its profile cannot grant — see below. `flutter_ios_app` is tagged `manual` by default, so `bazel build //...` on a fresh clone does not try to load the missing `//device` package.

Keep the app target in the committed BUILD file and put only the `local_provisioning_profile` in `//device`. The profile is the one genuinely per-developer fact. If the whole device app lives in a git-ignored package it is invisible to review and CI, and it drifts. Two of this repository's own examples once had a device app that had quietly diverged from its committed simulator twin. The same advice applies if you assemble the app from the composable rules: give the device `ios_application` the same `deps` as the simulator one.

Then run it:

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_ios_device -d ios
```

Each iOS example ships a `device.example/` folder. Copy it to a git-ignored `device/` and set your bundle id.

**Finding the profile's name.** `profile_name` matches the profile's `Name` field, and that is not always `iOS Team Provisioning Profile: <bundle id>`. Xcode mints a per-bundle-id profile only for an App ID registered in the developer portal. For an unregistered id, which most example and scratch apps have, automatic signing issues the team wildcard profile, `iOS Team Provisioning Profile: *`, and that is what covers your bundle id. List what you have:

```sh
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -extract Name raw -
done
```

Without `provisioning_profile`, a device build fails at analysis with "The provisioning_profile attribute must be set for device builds on this platform (ios)".

**Entitlements your profile cannot grant.** A simulator build is ad-hoc signed and validates nothing. A device build is signed against the profile, and an entitlement the profile does not grant fails it:

```
Target "//:my_app_ios_device" uses entitlements with the "aps-environment" key,
but the profile does not have this key
```

`aps-environment` is the common one. Xcode writes it into `ios/Runner/Runner.entitlements` the moment Push Notifications is enabled, it stays there long after the code that used it is gone, and a team wildcard profile can never grant it — push requires a registered App ID. The message names the profile, so the file is the last place you look, and `flutter_ios_app` discovers it silently because it is on disk. Pass `entitlements = False` on the device target to ship none:

```starlark
flutter_ios_app(
    name = "my_app_ios_device",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    entitlements = False,
    provisioning_profile = "//device:profile",
)
```

Deleting the file is the wrong fix. It is the app's real answer for the profile that *does* grant push, and Xcode will write it again.

**Getting a profile.** This is an Apple Developer account operation, and the rules cannot do it for you. You need a development profile whose App ID matches your `bundle_id`, installed under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Either create the App ID and a profile in the developer portal, download it, and double-click it, or let Xcode do it from any project with the right bundle id and automatic signing:

```sh
xcodebuild -project <some>.xcodeproj -scheme <scheme> -configuration Debug \
  -destination generic/platform=iOS \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

The project can be a scratch project. It does not need to be the app you build with Bazel, which has no `.xcodeproj` at all. Free "Personal Team" profiles expire after about seven days. When a build fails with "no provisioning profile was found named …", mint a fresh one.

#### Checking an iOS release build

There is no way to run a release iOS build without a signing credential. That matters because release-only problems, such as [missing permissions](#release-builds-and-permissions), show up when you run the app, not when you read the code.

- **Device, `-c opt`.** The real thing. Needs a provisioning profile.
- **Simulator, `-c opt`.** Refused at analysis: "The iOS simulator runs debug builds only". So is the default `fastbuild`. The simulator engine runs kernel under the JIT and cannot load an AOT snapshot, so such a bundle would install, launch, and show a blank white screen with only `Engine run configuration was invalid` in the system log. `flutter build ios --simulator --release` refuses it too.

Use `-c dbg` on the simulator and a device for release. A test that needs a simulator bundle under a plain `bazel test //...` gets one from `flutter_ios_simulator_build`, which builds its `targets` with `-c dbg` whatever the command line says. Name it in a test's `data`, or use `flutter_ios_simulator_build_test` in place of a `build_test`:

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_simulator_build_test")

flutter_ios_simulator_build_test(
    name = "ios_app_build_test",
    targets = [":app_ios"],
)
```

#### iOS plugin registrant

The registrant is always `GeneratedPluginRegistrant.swift`: the runner is Swift and calls it directly. Apps whose runner is Objective-C (`AppDelegate.m`) need the Objective-C registrant instead, which is a composable-rules build: `language = "objc"` on `flutter_ios_registrant_gen` emits `GeneratedPluginRegistrant.h` and `GeneratedPluginRegistrant.m` matching the flutter tool's own template, exposed through the `hdrs` and `srcs` output groups. Wire the groups into your own library — `includes` names the registrant's output directory so other sources can use `#import "GeneratedPluginRegistrant.h"` (the `.m` needs no flag: it imports its sibling header with quotes):

```starlark
load("@rules_cc//cc:objc_library.bzl", "objc_library")

flutter_ios_registrant_gen(
    name = "my_registrant",
    application = ":my_app",
    language = "objc",
)

filegroup(name = "registrant_hdrs", srcs = [":my_registrant"], output_group = "hdrs")
filegroup(name = "registrant_srcs", srcs = [":my_registrant"], output_group = "srcs")

objc_library(
    name = "my_registrant_lib",
    hdrs = [":registrant_hdrs"],
    srcs = [":registrant_srcs"],
    includes = ["my_registrant"],
)
```

`exclude_plugins` drops named plugin modules from the registrant — no import and no registration call, in either language — for plugins compiled conditionally or linked elsewhere. It is iOS-only: the other platforms' registrants always register every collected native plugin, so an Android or desktop build cannot drop one. A name that is not a native iOS plugin of the application is an error listing the valid names, so a typo fails the build instead of silently shipping an unregistered plugin:

```starlark
flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    exclude_plugins = ["deferred_plugin"],
)
```

### App icons

On Apple platforms the icon comes from an asset catalog. `actool` compiles the catalog and needs to be told which set inside it is the app icon, which is what `rules_apple`'s `app_icons` attribute does and what listing the same PNGs under `resources` cannot. `flutter_ios_app` and `flutter_macos_app` find the `AppIcon.appiconset` that `flutter create` wrote and forward it, so an app that never mentions its icon ships the one in its tree, the same as `flutter build`.

To ship a different icon, pass `app_icons` the files of an `.appiconset` or of an Icon Composer `.icon` bundle. `rules_apple` 4.5+ generates the older sizes from an `.icon` bundle. Name one or the other, not both. `app_icons = []` ships no icon.

Discovery is per platform, and a missing catalog is not an error. A tree made with `flutter create --platforms=ios .` has `ios/Runner/Assets.xcassets` and no macOS counterpart, so the iOS app gets its icon and the macOS app gets the placeholder. If one platform shows your icon and the other does not, check for the catalog first.

macOS icons use the platform's own grid rather than a full-bleed square: the rounded shape sits inset to roughly 824 of the 1024-point canvas, which is what makes it line up with other Dock icons. The rules pass the catalog through untouched.

One `flutter create` quirk is handled for you on macOS. Its `Info.plist` declares `CFBundleIconFile` as an empty string for Xcode to fill in, while `macos_application` generates its own value from the catalog, and Apple's plisttool refuses two different values for one key. The macro drops the empty placeholder. A plist that names a real icon file is left alone, and will still conflict if you also pass `app_icons`.

### App Intents

To ship App Intents, give the Swift library to two attributes. `runner_deps` links it into the runner, so its code is in the binary. rules_apple's `app_intents` (which passes through `**kwargs`) extracts the metadata into the bundle: `Contents/Resources/Metadata.appintents` on macOS, `Metadata.appintents` at the bundle root on iOS. `app_intents` does not link the library, and `runner_deps` does not extract anything, so an app that gives it to only one ships either metadata with no code or code that the system never learns about.

```starlark
swift_library(
    name = "intents",
    srcs = ["Intents/PingIntent.swift"],
    # rules_apple's aspect refuses a library that does not name the framework.
    linkopts = ["-Wl,-framework,AppIntents"],
    module_name = "Intents",
)

flutter_macos_app(
    name = "app",
    app_intents = [":intents"],
    runner_deps = [":intents"],
    # ...
)
```

`e2e/macos_example` and `e2e/ios_example` each build such an app and check the bundle names the intent and the binary links it. When `appintentsmetadataprocessor` fails on a schema validation error, rules_apple's wrapper reports `version.json.sorted: No such file or directory` and hides the processor's own message. Run the processor by hand to read the real error.

### App extensions

Widgets, Control Center controls, share extensions and other app extensions are written in Swift and built with rules_apple's `ios_extension` or `macos_extension`. `flutter_ios_app` and `flutter_macos_app` pass `extensions` through to `ios_application` and `macos_application`, which embed each `.appex` in `PlugIns/` (iOS) or `Contents/PlugIns/` (macOS). Flutter does not run inside an extension: an extension cannot link the Flutter engine or Dart code from these rules. Share data with the app through an App Group instead.

```starlark
load("@rules_apple//apple:ios.bzl", "ios_extension")
load("@rules_apple//apple:versioning.bzl", "apple_bundle_version")
load("@rules_swift//swift:swift.bzl", "swift_library")

apple_bundle_version(
    name = "version",
    build_version = "1.0",
    short_version_string = "1.0",
)

swift_library(
    name = "widgets_lib",
    srcs = ["extensions/Widgets.swift"],
    linkopts = ["-Wl,-framework,AppIntents"],
    module_name = "Widgets",
)

ios_extension(
    name = "widgets",
    app_intents = [":widgets_lib"],
    bundle_id = "com.example.myapp.widgets",
    entitlements = "extensions/AppGroup.entitlements",
    families = ["iphone"],
    infoplists = ["extensions/Widgets-Info.plist"],
    minimum_os_version = "17.0",
    version = ":version",
    deps = [":widgets_lib"],
)

flutter_ios_app(
    name = "my_app_ios",
    additional_entitlements = ["extensions/AppGroup.entitlements"],
    application = ":my_app",
    bundle_id = "com.example.myapp",
    extensions = [":widgets"],
)
```

What the extension needs:

- **A version equal to the app's.** rules_apple gives an extension no version unless you pass one, and the system expects an extension's version to match its app's. `flutter_ios_app` and `flutter_macos_app` default to 1.0, so pass an `apple_bundle_version` of 1.0, or the same one you give the app.
- **A bundle id under the app's**, such as `com.example.myapp.widgets`.
- **An Info.plist with the bundle keys.** Besides `NSExtension` and its `NSExtensionPointIdentifier`, give `CFBundleName` (`$(PRODUCT_NAME)`), `CFBundleExecutable` (`$(EXECUTABLE_NAME)`), `CFBundleIdentifier` (`$(PRODUCT_BUNDLE_IDENTIFIER)`) and `CFBundlePackageType` `XPC!`. Without them the simulator refuses to install the app.
- **Its App Intents.** A control's button, an interactive widget or a configurable widget runs an App Intent in the extension, so give the library to the extension's `app_intents` as well as its `deps`. rules_apple 5.2.0's `macos_extension` has no `app_intents` attribute. `e2e/macos_example/patches/` has a patch that adds it; apply it with `single_version_override(module_name = "rules_apple", version = "5.2.0", patch_strip = 1, patches = [...])`. Overrides only apply in the root module, so an app needs the override in its own `MODULE.bazel`; it does not come with rules_flutter.
- **On macOS, a sandbox.** macOS loads a widget or share extension only if its entitlements include `com.apple.security.app-sandbox`.
- **Visibility** to the package of the app target, if it lives elsewhere. `flutter_ios_app` and `flutter_macos_app` must sit in the package that holds `ios/Runner/` or `macos/Runner/`.

An extension can have a higher `minimum_os_version` than the app. rules_apple accepts that without comment and each bundle records its own minimum, so the system skips the extension on an older OS. Control Center controls need iOS 18 or macOS 26; either raise the extension's minimum or include the control in the `WidgetBundle` behind `if #available`, as the examples do.

**App Groups.** Give each extension an `entitlements` file with `com.apple.security.application-groups`, and merge the same file into the app with `additional_entitlements`. A simulator build is not checked against anything, so the group works there. On macOS, the `group.` form needs a provisioning profile that lists the group, and the team-prefixed form (`<TEAM ID>.name`) needs a signature from that team, which a team wildcard profile gives without listing any group. An app signed ad hoc gets neither: it builds, and its extensions register, but writes into the group container are refused.

**Signing.** rules_apple signs each extension in its own target, so the app's `provisioning_profile` does not reach its extensions. Give each extension its own `provisioning_profile`. On macOS, an extension without one is signed with the build's `--@rules_apple//apple/build_settings:signing_certificate_name`, and with none set, ad hoc, so it has no team and loses its App Group even inside a team-signed app. A profile can only grant an App Group if it is made for an explicit App ID that has the group, so a device build with groups needs an App ID and a profile for the app and for each extension, registered in the developer portal. The team wildcard profile (`iOS Team Provisioning Profile: *`) covers any bundle id but grants no App Group, and a device build that asks for an entitlement its profile lacks fails. `e2e/ios_example` has a device variant, `:app_extensions_device`, signed with the wildcard; it leaves the App Group out of the app and its extensions for that reason. On macOS the wildcard is enough with a team-prefixed group: `e2e/macos_example`'s `:app_extensions_team` gives the app and each extension the `Mac Team Provisioning Profile: *` wildcard, and the app writes into its group container. Its profile and group live in a git-ignored `//device` package made from `device.example/`, because the group carries the team id. A macOS `local_provisioning_profile` needs `profile_extension = ".provisionprofile"`; rules_apple otherwise looks for a `.mobileprovision`. `codesign --verify --deep --strict` passes on an app whose extension was signed ad hoc, so it does not catch a missing profile; compare `TeamIdentifier` across the bundles instead, as `:verify_macos_team_signing_test` does.

`e2e/ios_example` and `e2e/macos_example` each build an app with a widget extension holding a widget and a control, and a share extension, and check where each lands, what each declares, and that all share one App Group.

### Android

Run `flutter create --platforms=android .` first so `android/app/src/main/` exists with its manifest, resources, and Kotlin sources.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_app")

flutter_android_app(
    name = "my_app_android",
    application = ":my_app",
    package_name = "com.example.myapp",
)
```

Add these to `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_android_ndk", version = "0.1.5")

use_repo(flutter, "deps", "flutter_toolchains", "flutter_android_engine_arm64")

# The NDK CC toolchain, used for native and FFI deps built for Android and
# to strip the engine's native libraries, as a Gradle build does.
android_ndk_repository_extension = use_extension(
    "@rules_android_ndk//:extension.bzl",
    "android_ndk_repository_extension",
)
use_repo(android_ndk_repository_extension, "androidndk")
register_toolchains("@androidndk//:all")
```

**Environment variables.** Two are needed, and both are read by repository rules while Bazel fetches:

| Variable | Value | Read by |
|---|---|---|
| `ANDROID_HOME` | The SDK root, for example `~/Library/Android/sdk`. | `rules_android` |
| `ANDROID_NDK_HOME` | A versioned NDK directory, for example `$ANDROID_HOME/ndk/28.2.13676358`. | `rules_android_ndk` |

`ANDROID_NDK_HOME` has to name the versioned directory, not the `ndk/` folder above it. Pointing at the parent fails with a message that mentions neither the variable nor the mistake:

```
Error in readdir: can't readdir(), not a directory:
  .../Android/sdk/ndk/toolchains/llvm/prebuilt/darwin-x86_64
```

Exporting the variables in your shell works. To put them in `.bazelrc`, use `--repo_env`. `--action_env` only reaches build actions, and repository rules never see it:

```bazelrc
common --repo_env=ANDROID_HOME=/path/to/Android/sdk
common --repo_env=ANDROID_NDK_HOME=/path/to/Android/sdk/ndk/28.2.13676358
```

With `ANDROID_NDK_HOME` unset, the build stops during fetch:

```
ERROR: An error occurred during the fetch of repository
  'rules_android_ndk++android_ndk_repository_extension+androidndk':
  Error in fail: Either the ANDROID_NDK_HOME environment variable or the
  path attribute of android_ndk_repository must be set.
```

No platform flags are needed to build. `flutter_android_app` transitions the application, including its AOT compile and FFI deps, to the Android platform for its `android_abi`:

```sh
bazel build //:my_app_android
```

**Pure Go host tools.** `flutter_android_app` builds rules_android's Go host tools in rules_go pure mode: without a C++ toolchain, so the hermetic LLVM runtimes are never compiled from source. The APK is unchanged (only the host tools' own binaries differ). The setting is scoped to the app — desktop builds and your own Go targets keep their configuration. Opt out with `--@rules_flutter//flutter:android_pure_go=false`; you need that only if the app's own subtree contains cgo Go code, which pure mode cannot compile. Hand-assembled Tier-2 `android_binary` targets are unaffected either way: add the global `--@rules_go//go/config:pure=true` yourself if you want the same saving there and have no cgo Go code.

**Release signing.** The APK signs with the debug keystore, as an `android_binary` does. To ship to Google Play, pass `keystore` (a `.jks` or PKCS#12 `.p12` file) together with `keystore_password_file` and `key_alias`; set `key_password_file` as well when the key has its own password. Both passwords travel as `file:` references to file inputs, so their text never appears on the command line. When `key_password_file` is unset, `--key-pass` is omitted and apksigner unlocks the key with the keystore password. Only each file's first line is read, so end it with a newline. A `keystore` without its password file or alias fails analysis naming the missing attribute. When `keystore` is unset, the `//flutter:android_release_keystore`, `//flutter:android_release_keystore_password_file` and `//flutter:android_release_key_alias` flags supply the same three values, so CI can inject a secret without editing BUILD files; an explicit attribute always wins over its flag. Every secret setting must name a target with exactly one file: a flag or attribute pointing at an empty or multi-file target fails analysis naming the setting, the target and the file count, instead of silently falling back to debug signing. Never hide a secret behind an `allow_empty` glob — a CI secret that was never written would otherwise have shipped a debug-signed release.

The release signing action always runs locally (`no-remote`): Bazel never uploads the keystore or the password files to a remote executor or a remote cache. A password file's content digest would otherwise land in the shared action cache, an execution log or a build event stream, where it is an offline brute-force oracle for a human-chosen password. Keep the secrets out of version control — have CI write them to gitignored files and point the flags at those — and out of remote and disk caches: a secret checked into the source tree is still an action input whose digest is recorded in the local disk cache and in any build event output you keep.

```sh
# //secret is a gitignored directory the CI job populates, never committed:
bazel build //:my_app_android \
  --@rules_flutter//flutter:android_release_keystore=//secret:upload \
  --@rules_flutter//flutter:android_release_keystore_password_file=//secret:store_pass \
  --@rules_flutter//flutter:android_release_key_alias=upload
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `package_name` | The Android package name, for example `"com.example.myapp"`. Required. |
| `app_name` | Display name. Defaults to the target name. |
| `android_abi` | `"arm64"` (default) or `"x64"`. Selects the engine and the Android platform. |
| `min_sdk_version` | Minimum Android SDK version. |
| `target_sdk_version` | Target Android SDK version. |
| `manifest` | A manifest you wrote yourself, used verbatim. Placeholders like `${applicationName}` are not substituted, so do not pass `flutter create`'s own manifest here; let the macro discover that one. |
| `debug_manifest` | A variant manifest whose permissions merge into `-c dbg` builds only. `None` (default) discovers `android/app/src/debug/AndroidManifest.xml`. A label overrides discovery. `False` disables variant handling. |
| `profile_manifest` | The same for profile builds. `None` (default) discovers `android/app/src/profile/AndroidManifest.xml`. |
| `permissions` | Permission names added to the manifest in every compilation mode, for example `["android.permission.INTERNET"]`. See [Release builds and permissions](#release-builds-and-permissions). |
| `keystore` | Release keystore (`.jks` or PKCS#12 `.p12`) signing the APK instead of the debug key. Needs `keystore_password_file` and `key_alias`. See [Release signing](#release-signing). |
| `keystore_password_file` | File holding the keystore password, read by apksigner through `--ks-pass file:<path>`. Falls back to the `//flutter:android_release_keystore_password_file` flag. |
| `key_alias` | Alias of the signing key inside `keystore`. Falls back to the `//flutter:android_release_key_alias` flag. |
| `key_password_file` | File holding the signing key's own password, read through `--key-pass file:<path>`. When unset, `--key-pass` is omitted and the keystore password unlocks the key. |
| `multidex` | Defaults to `"native"`. |

<details>
<summary>Composable rules</summary>

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
|---|---|
| `native_libs` | `libapp.so` (AOT code) plus any `native_deps` libraries |
| `flutter_assets` | The `flutter_assets/` tree |
| `mobile_install` | JNI-structured symlinks and assets for `bazel mobile-install` |

</details>

### Linux

Run `flutter create --platforms=linux .` first. If `linux/runner/` is missing, the rules use a built-in runner.

```starlark
load("@rules_flutter//flutter:linux.bzl", "flutter_linux_app")

flutter_linux_app(
    name = "my_app_linux",
    application = ":my_app",
    gtk_app_id = "com.example.myapp",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `app_name` | Binary name. Defaults to the target name. |
| `gtk_app_id` | GTK application id. Defaults to `"com.example.flutter"`. A `linux/runner/` from `flutter create` gets it as `APPLICATION_ID`. |
| `window_title` | Window title. Defaults to `app_name`, then the target name. A `linux/runner/` from `flutter create` sets its own title and ignores this. |

The output directory:

```
my_app/
  my_app                     GTK runner executable
  lib/
    libapp.so                AOT-compiled Dart
    libflutter_linux_gtk.so  Flutter engine
    *.so                     native plugin libraries, if any
  data/
    flutter_assets/          fonts, images, shaders, asset manifest
    icudtl.dat               ICU data
```

**GTK3 and your C++ toolchain.** rules_flutter ships its own hermetic sysroot for the GTK3 headers and libraries, and links those libraries as explicit files. It adds no `-L` and no `-lgtk-3` flags. Your toolchain's `--sysroot` stays the only owner of libc, libm, and the rest of the C runtime. This matters because a Debian sysroot's `libm.so` is a linker script with absolute paths that `lld` rewrites only for scripts under `--sysroot`; a second sysroot on the search path would break `-lm` with a "no such file" error naming a file that exists.

**Cross-compiling from macOS** works in debug mode only, because Flutter publishes no cross-compiling `gen_snapshot` for desktop targets. See [Cross-compiling](#cross-compiling).

```sh
bazel build //:my_app_linux -c dbg --platforms=@rules_flutter//flutter/platforms:linux_x64
```

<details>
<summary>Composable rules</summary>

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

Run `flutter create --platforms=windows .` first. If `windows/runner/` is missing, the rules use a built-in runner.

```starlark
load("@rules_flutter//flutter:windows.bzl", "flutter_windows_app")

flutter_windows_app(
    name = "my_app_windows",
    application = ":my_app",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `app_name` | Binary name. Defaults to the target name. |

The output directory:

```
my_app/
  my_app.exe             Win32 runner executable
  flutter_windows.dll    Flutter engine
  app.so                 AOT-compiled Dart, as ELF
  data/
    flutter_assets/      fonts, images, shaders, asset manifest
    icudtl.dat           ICU data
```

<details>
<summary>Composable rules</summary>

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

Run `flutter create --platforms=web .` first so `web/` has its `index.html`, `manifest.json`, and icons. Any of those that are missing are replaced by built-in templates. Add `flutter_web_sdk` to `use_repo`.

```starlark
load("@rules_flutter//flutter:web.bzl", "flutter_web_app")

flutter_web_app(
    name = "my_app_web",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = ["@deps//:flutter", "@rules_flutter//flutter:material_icons"],
    app_name = "My App",
)
```

Unlike the other platforms, the web macro takes `main` and `deps` directly rather than a `flutter_application`. Web compilation goes through dart2wasm or dart2js, which is a different pipeline from the AOT one.

| Attribute | Description |
|---|---|
| `package_name` | The Dart package name, same as `pubspec.yaml`. Required. |
| `deps` | `dart_library` or `flutter_library` targets. Required. |
| `main` | The entry point. Defaults to `"lib/main.dart"`. It can sit outside the package's `lib/`; list any file it imports by relative path in `srcs`. |
| `app_name` | Used for the HTML title and manifest. Defaults to the target name. |
| `base_href` | Substituted for `$FLUTTER_BASE_HREF` in `web/index.html`. Defaults to `"/"`. `flutter_bazel run -d chrome` serves the app under it, as `flutter run` does. |
| `extra_web_assets` | Extra files copied into the bundle root, for generated files the `web/` glob cannot see. |
| `web_dir` | The directory the runner files are discovered in and served from at the bundle root. Defaults to `"web"`. Give each app its own, such as `"web_apps/reminders"`, to build several web apps from one package. `flutter_web_bundle` takes it too. |
| `pwa` | Ship `flutter_service_worker.js` and register it. Defaults to `True`. The worker adds no offline caching. Like `flutter build web`, which [deprecated its caching worker](https://github.com/flutter/flutter/issues/156910), it unregisters itself and reloads its clients, which frees visitors still holding a caching worker from an older deployment. |

The macro always compiles with dart2wasm and renders with skwasm. Compiler settings such as `optimization_level_wasm` and `minify_wasm` pass through to `flutter_web_bundle`. For dart2js or CanvasKit, use `flutter_web_bundle` directly.

The files under `web/` are treated as templates and substituted the way `flutter build web` substitutes them, so raw `flutter create` output works unchanged: `web/index.html`, `web/flutter_bootstrap.js`, `web/manifest.json`, and `web/version.json` are each discovered when present, and everything else under `web/` is copied into the bundle root.

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:web.bzl", "flutter_web_bundle")

# WASM, the default:
flutter_web_bundle(
    name = "my_app_web",
    package_name = "my_app",
    main = "lib/main.dart",
    deps = ["@deps//:flutter"],
)

# JavaScript, for wider browser support:
flutter_web_bundle(
    name = "my_app_web_js",
    package_name = "my_app",
    main = "lib/main.dart",
    compiler = "dart2js",
    renderer = "canvaskit",
    deps = ["@deps//:flutter"],
)
```

</details>

#### Content-Security-Policy

A `<meta http-equiv="Content-Security-Policy">` in `web/index.html` applies both to the built bundle and to the dev loop (`flutter_bazel run -d chrome`), because the dev loop serves the same page. Measured on `e2e/web_example` with Flutter 3.47:

| Policy | Built bundle (WASM) | Dev loop (DDC) |
|---|---|---|
| `script-src 'self' 'wasm-unsafe-eval'` | Renders | Blank page |
| `script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'` | Renders | Renders |

The dev loop needs `'unsafe-inline'`. Adding `'unsafe-eval'` instead changes nothing. The failure is silent: DWDS connects, the VM service answers, every module loads, no CSP violation reaches the console, and the app never paints. `connect-src 'self' ws: wss:` is enough for the dev loop's WebSocket.

A bundle served under `default-src 'self'` must also serve its own renderer, with `use_local_canvaskit = True`. Otherwise the engine's fetch of `skwasm.js` from `www.gstatic.com` is blocked and the page stays blank. Flutter's font fallback from `fonts.gstatic.com` is blocked too, which is harmless unless the app needs those glyphs.

So a policy strict enough to be useful cannot live in `web/index.html` today, because the dev loop reads the same file. If you need one, compose `flutter_web_bundle` directly with a generated `index_html` for the production bundle.

### Cross-compiling

`gen_snapshot`, the AOT compiler, runs on the host and produces code for the target. Flutter publishes a different binary per host and target pair, and not every pair exists.

| Host | Target | AOT (release / profile) | JIT (debug) | Notes |
|---|---|:---:|:---:|---|
| macOS | macOS | Yes | Yes | Native build |
| macOS | iOS | Yes | Yes | `rules_apple` handles the transition |
| macOS | Android | Yes | Yes | The Android rules handle the transition |
| macOS | Linux | No | Yes | Needs an LLVM cross-toolchain |
| macOS | Windows | No | Yes | Needs a Windows cross-toolchain |
| macOS | Web | Yes | n/a | Web uses dart2wasm or dart2js, not gen_snapshot |
| Linux | Linux | Yes | Yes | Native build |
| Linux | Android | Yes | Yes | The Android rules handle the transition |
| Linux | iOS | No | Yes | Debug/JIT kernel only; AOT requires a Darwin-target `gen_snapshot` (macOS host) |
| Linux | macOS | No | Yes | Debug/JIT kernel only; AOT requires a Darwin-target `gen_snapshot` (macOS host) |
| Linux | Windows | No | Yes | Needs a Windows cross-toolchain |
| Linux | Web | Yes | n/a | |
| Windows | Windows | Yes | Yes | Native build |
| Windows | Android | Yes | Yes | The Android rules handle the transition |
| Windows | macOS | No | Yes | Debug/JIT kernel only; AOT requires a Darwin-target `gen_snapshot` (macOS host) |
| Windows | Linux | No | Yes | Needs a Linux cross-toolchain |
| Windows | Web | Yes | n/a | |

The gap is desktop-to-desktop and non-macOS-to-Apple AOT:
- **Apple release and profile AOT (`ios_*`, `macos_*`) requires a macOS host (or a Darwin-target `gen_snapshot`).** Each `gen_snapshot` binary has its target OS and ABI compiled in at build time (`DART_TARGET_OS_*` in the Dart VM); `--snapshot_kind=app-aot-macho-dylib` only selects the Mach-O container format and does not change the generated machine code's target ABI. In particular, Apple arm64 reserves register `x18` for the platform and uses a different FFI argument ABI from Linux/Android arm64, and `dart:ui` calls the Flutter engine through `@Native` FFI. Because Flutter only publishes Darwin-targeted `gen_snapshot` binaries for macOS hosts, release and profile AOT builds for iOS and macOS are only registered on macOS hosts and fail at analysis on Linux and Windows. Debug/JIT (`-c dbg`) compiles platform-independent kernel `.dill` with `frontend_server` and works from Linux and Windows.
- **Desktop to desktop:** there is no release or profile AOT cross-compile between desktop OSes (macOS, Linux, Windows), because Flutter does not publish cross-OS desktop `gen_snapshot` binaries. Build debug bundles across with `-c dbg`, or build release/profile natively on the target OS.
- **Linux-to-Apple debug builds (`backend = "xtool"` and `flutter.darwin_sdk`):** Opt-in Linux-to-iOS/macOS debug cross-compilation (`backend = "xtool"` or `--@rules_flutter//flutter/settings:apple_backend=xtool`) compiles the native Swift/Objective-C runner against an `xtool` `darwin.artifactbundle` (`iPhoneOS.sdk`, `iPhoneSimulator.sdk`, `MacOSX.sdk`) configured via `flutter.darwin_sdk(...)` in your root `MODULE.bazel`.
  > **Important — Apple SDK licensing:** `rules_flutter` never bundles, hosts, or downloads an Apple SDK by default (`url` and `path` both default to `""`). Apple's Xcode and platform SDKs (`iPhoneOS.sdk`, `iPhoneSimulator.sdk`, `MacOSX.sdk`) are proprietary software governed by the Apple Xcode and Apple SDKs Agreement. You must obtain and supply your own `darwin.artifactbundle` (via `flutter.darwin_sdk(url = ..., sha256 = ...)` from your own private artifact store or `flutter.darwin_sdk(path = ...)` on disk) in compliance with Apple's licensing terms.
- **Apple `xtool` backend (`backend = "xtool"`):** `flutter_ios_app` and `flutter_macos_app` accept `backend = "xtool"` (with `--@rules_flutter//flutter/settings:apple_backend=xtool`) to assemble `.ipa` and `.app.zip` bundles via `xtool_pack` without instantiating `rules_apple` targets. On macOS, when `menu_xib` is omitted and no `macos/Runner/Base.lproj/MainMenu.xib` is present on disk, the runner builds a default application menu programmatically; passing any `menu_xib` explicitly or leaving a conventional `macos/Runner/Base.lproj/MainMenu.xib` on disk fails at analysis because compiling `.xib` files requires Xcode `ibtool` (remove `macos/Runner/Base.lproj/MainMenu.xib` and omit `menu_xib`, or use `backend = "rules_apple"`). When signing with `zsign` and a PKCS#12 `certificate` (`.p12`), pass the certificate password via `certificate_password_file` (a file label read at execution time) or `certificate_password_env` (an environment variable name read at execution time, forwarded with `--action_env`). Plain-text `certificate_password` is rejected at analysis so signing secrets never appear on action command lines, build event streams, or `bazel aquery` output.

### Release builds and permissions

`flutter create`'s scaffold grants network access in debug and profile builds only, and these rules reproduce that. An app that reaches the network under `-c dbg` can be offline under `-c opt` with no build error, no exception, and nothing in its log. The same shape exists on every platform, because in every case the debug-only grant is for the Dart VM service, not for the app:

| Platform | What debug has that release does not | Why |
|---|---|---|
| macOS | `com.apple.security.network.server` and `com.apple.security.cs.allow-jit` in `DebugProfile.entitlements`, which profile builds use too. `Release.entitlements` has only `app-sandbox`. | The sandbox must let the VM service bind and the JIT map executable pages. |
| Android | `android.permission.INTERNET`, from `android/app/src/debug/AndroidManifest.xml` (and `src/profile/` in profile builds). | Android enforces `INTERNET` at the kernel level. Without it the VM service cannot bind even a loopback socket. |
| iOS | `NSBonjourServices` and `NSLocalNetworkUsageDescription`, merged in by these rules for non-release builds. | The engine advertises the VM service over mDNS. |

An app that uses the network for itself has to say so once, in a way that applies to every compilation mode:

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

where `entitlements/Network.entitlements` is an ordinary plist:

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

These attributes add to whichever base file the compilation mode selected, so one declaration covers debug and release, and the `flutter create` files stay untouched. A key the base already has with the same value is deduplicated, so declaring `network.server` above is safe even though `DebugProfile.entitlements` already grants it. A key the base has with a different value is an error naming the key and both files.

Note that `com.apple.security.network.client` is in neither scaffold file. Most Flutter apps go through `NSURLSession`, which the sandbox exempts. A raw socket is not exempt, so if you open one, you need this key.

**iOS local network privacy.** iOS 14 and later gate LAN access behind `NSLocalNetworkUsageDescription` and `NSBonjourServices`. The rules add both to non-release builds for the VM service and drop them in release. An app that needs LAN access for itself declares them in `ios/Runner/Info.plist`, where they survive into `-c opt`. The rules merge the VM service keys into that file, keeping your usage description and adding `_dartVmService._tcp` to your Bonjour list. The iOS simulator does not enforce local network privacy, so only a physical device tells you whether these keys are right.

**Check the artifact.** A `build_test` cannot see any of this. Read the built app:

```sh
# macOS: the entitlements codesign embedded
unzip -oq bazel-bin/my_app_macos.zip -d /tmp/app && \
  codesign -d --entitlements - "/tmp/app/My App.app"

# Android: the compiled manifest inside the APK
aapt2 dump xmltree --file AndroidManifest.xml bazel-bin/my_app_android.apk

# iOS: the processed Info.plist inside the .ipa
unzip -oq bazel-bin/my_app_ios.ipa -d /tmp/ipa && \
  plutil -p "/tmp/ipa/Payload/my_app_ios.app/Info.plist"
```

Remember that a plain `bazel build` is a release build, so it already takes the release side of each of these choices. `e2e/macos_example`, `e2e/android_example`, and `e2e/ios_example` each have a test that reads the built artifact this way.

## Rules reference

The core rules load from `@rules_flutter//flutter:defs.bzl`.

### flutter_library

Collects Dart sources and assets for a Flutter package. It does not compile anything. It carries `DartInfo` and `FlutterInfo` to whatever depends on it.

```starlark
flutter_library(
    name = "my_lib",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@deps//:some_package"],
    assets = glob(["assets/**"]),
    package_name = "my_lib",
)
```

| Attribute | Description |
|---|---|
| `srcs` | Dart source files. Required. |
| `deps` | `dart_library` or `flutter_library` targets. |
| `assets` | Asset files: images, fonts, and so on. Each file must sit under the target's package directory; it is bundled at `packages/<package_name>/<path relative to that directory>`. See [Asset keys](#asset-keys). |
| `pkg_shaders` | The package's fragment shaders, as `{file: path}` mirroring `flutter: shaders:` in `pubspec.yaml`. Bundled at `packages/<package_name>/<path>`, where `FragmentProgram.fromAsset` looks for them. |
| `shader_includes` | Files the `pkg_shaders` may `#include`, such as `glob(["shaders/**/*.glsl"])`. A shader compiles with only its declared inputs, so an include not listed here is not found. |
| `shaders` | Shaders bundled at `shaders/<file name>`, as Flutter's own are. A package's own shaders go in `pkg_shaders`. |
| `package_name` | The Dart package name. Defaults to the last component of the Bazel package path. |
| `language_version` | The Dart language version, matching the `sdk:` constraint in `pubspec.yaml`. |

### flutter_application

Compiles a Flutter app. In debug mode (`-c dbg`) it produces a kernel `.dill` for the JIT. Otherwise it produces AOT native code. Either way it also builds the `flutter_assets/` bundle. The platform macros consume its `FlutterApplicationInfo`.

```starlark
flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = [
        ":my_lib",
        "@deps//:flutter",
        "@rules_flutter//flutter:material_icons",
    ],
    native_deps = [":my_native_lib"],
)
```

| Attribute | Description |
|---|---|
| `main` | The entry point. Required. It can sit outside the package's `lib/`, as `flutter run -t` allows: `test_driver/app.dart`, say. See [Hot reload and hot restart](#hot-reload-and-hot-restart). |
| `package_name` | The Dart package name, the same as `pubspec.yaml`'s `name:`. Required. It keys the compiled libraries under stable `package:` URIs, which hot reload matches against, and resolves `package:<self>/...` imports. |
| `srcs` | Other Dart sources in the app package, including generated ones. List here any file a `main` outside `lib/` imports by relative path. |
| `deps` | `dart_library` or `flutter_library` targets. Add `@rules_flutter//flutter:material_icons` to bundle the Material icon font. |
| `assets` | Asset files for the bundle. Each file must sit under the target's package directory; it is bundled at its path relative to that directory. See [Asset keys](#asset-keys). |
| `native_deps` | Shared libraries to bundle for `dart:ffi`. |
| `defines` | Dart environment defines, the `-D` flags. |
| `language_version` | The Dart language version, matching `pubspec.yaml`. |
| `obfuscate` | Obfuscate Dart symbols in the AOT output. Pair with `split_debug_info`. Default `False`. |
| `split_debug_info` | Write debug info to a separate `.symbols` file. Default `False`. |
| `extra_gen_snapshot_options` | Extra flags for `gen_snapshot`. |
| `track_widget_creation` | Record widget creation locations for the DevTools inspector. Default `False`. |
| `shaders` | Fragment shaders to compile with impellerc. Each file must sit under the target's package directory; it is bundled at its path relative to that directory, where `FragmentProgram.fromAsset` looks for it. See [Asset keys](#asset-keys). |
| `shader_includes` | Files the `shaders` may `#include`. |
| `require_sksl_shaders` | Fail the build when a shader cannot be compiled for Skia (SkSL). By default such a shader, say one that indexes a uniform array in a loop, is compiled for Impeller alone with a warning, as `flutter build` does, and fails to load only where the app renders with Skia. Web builds always need SkSL. Default `False`. |
| `tree_shake_icons` | Keep only the icon glyphs the app uses. Default `True`. |
| `link_hook_assets` | The data assets packages' link hooks emit, each `package:<package>/<name>`. See [Link hooks](#link-hooks). |
| `license_files` | License and NOTICE files to include in `NOTICES.Z`. |
| `min_os_version` | Minimum Apple deployment target, passed to `gen_snapshot` as `--macho-min-os-version`. |

**Defines from the command line.** The repeatable flag `--@rules_flutter//flutter:extra_dart_defines=KEY=VALUE` adds a define to every Dart compile: native kernel, `flutter_test`, dart2wasm, and dart2js. Each occurrence of the flag is one define, so values may contain commas. When a key is set both by the flag and by the `defines` attribute, the flag wins. Reserved defines (`dart.vm.*`, `dart.library.*`, `dart.tool.*`, `flutter.*`) are set by the build and SDK and cannot be passed. The dev tool's `--dart-define` forwards to this flag and replays the defines on hot reload and restart, matching `flutter run --dart-define`.

### flutter_test

Compiles and runs widget and unit tests on the Dart VM with Flutter's test engine. Assertions are enabled.

```starlark
flutter_test(
    name = "widget_test",
    package_name = "my_app",
    main = "test/widget_test.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)
```

It takes the compile attributes of `flutter_application` (`main`, `srcs`, `deps`, `defines`, `package_name`, `language_version`, `assets`, `shaders`) plus the usual `data` and `env`. Values in `env` are literal; there is no `$(location)` expansion.

`enable_impeller = True` renders with Impeller in `flutter_tester`, as `flutter test --enable-impeller` does, instead of software Skia. A test that draws a shader SkSL cannot compile needs it, and so does a golden meant to match an Impeller device. Shaders are compiled for `flutter_tester` either way, with the SkSL and Vulkan stages `flutter test` gives them.

Bazel's test protocol applies, as it does to `dart_test`:

- **Time.** The target's `size` or `timeout` replaces `package:test`'s 30-second default, so a test with no `timeout:` of its own runs as long as Bazel lets the target run. A `timeout:` written on a test still applies, and `Timeout.factor` scales Bazel's limit.
- **`--test_filter`.** A regular expression matched against each test's full name, group names included, like `flutter test --name`. A target the filter matches nothing in passes, so `bazel test //... --test_filter=x` runs only what it names.
- **`shard_count`.** Splits the suite's tests into contiguous shares, one per shard.
- **Tags.** `include_tags` runs only tests matching every one of these `package:test` tag selectors (library, group or test level), as `flutter test --tags` intersects them; each entry is a boolean selector (`a && b`, `a || b`, `!a`, parentheses), and several entries — or comma-separated values in one entry — all have to match. `exclude_tags` skips tests matching any of them, as `flutter test --exclude-tags` unions them, and wins over `include_tags`. An attribute selection that matches no test fails the target, so a misspelled tag is a failure rather than an empty pass; a `--test_env=FLUTTER_TEST_TAGS=...` (or `FLUTTER_TEST_EXCLUDE_TAGS`) selection that matches nothing still passes with a note. A `--test_env=...` value at run time overrides the attribute. A `@Tags` on the test entrypoint itself is extracted at build time and always honoured, reaching every test through the suite's root group; a `@Tags` on a file the entrypoint imports stays invisible, as under `flutter test`.
- **Results.** Each case is reported in the `test.xml` Bazel collects, so CI shows cases rather than one pass or fail per target.

#### Golden files

Goldens must be listed in `data`, or the test cannot see them:

```starlark
flutter_test(
    name = "widget_test",
    main = "test/widget_test.dart",
    data = glob(["test/goldens/**"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)
```

This is the first thing to check when a golden fails, because the failure message does not say it. The comparator reads goldens from runfiles, so a PNG in the source tree that is not an input of the test is invisible to it, and it fails with `Could not be compared against non-existent file`, the same message you get when the file really is absent. If you can see the file on disk and the test says it does not exist, it is almost certainly undeclared. Making declared inputs the only inputs is what keeps a cached pass meaningful.

Otherwise `matchesGoldenFile('goldens/x.png')` means what it means under `flutter test`: the golden is read from `goldens/x.png` next to the test's `main`, and a mismatch reports the pixel difference the same way. When a comparison fails, the four diff images (`masterImage`, `testImage`, `isolatedDiff`, `maskedDiff`) are written under `bazel-testlogs/<pkg>/<target>/test.outputs/failures/`, and the failure message names the path. Upstream writes them beside the test, which under Bazel would be inside the sandbox and gone before you could open them.

To regenerate goldens, use upstream's flag under `bazel run`:

```sh
bazel run //:widget_test -- --update-goldens
```

That writes the PNGs into the source tree next to the test and names each one. The same flag under `bazel test` exits with code 64, because a test action cannot write to the source tree and a golden regenerated into the sandbox would report success while changing nothing. There is no repo-wide command; it is one `bazel run` per target, which `bazel query 'tests(//...)'` can drive.

Two limits come from Flutter rather than from these rules:

- **Goldens are host-specific.** Font rendering and antialiasing differ between operating systems, so a PNG generated on macOS may not match on Linux or Windows. Regenerate on the platform that checks them, or keep per-OS golden directories.
- **Replacing the comparator disables regeneration.** If a test assigns its own `goldenFileComparator`, `--update-goldens` calls that object's `update()`, which for `LocalFileComparator` writes into runfiles. The run passes, prints nothing, and leaves the source PNG unchanged.

#### Modular compilation and the test action's cache key

Each library in a `flutter_test` closure is compiled once into its own outline kernel (a separate, action-cached build action), and the test action links the entry module against those outlines and runs the resulting kernel under `flutter_tester`. Editing one library therefore recompiles only that library's outline plus the link — other libraries' outlines are reused.

A test action re-runs only when its cache key changes. The key is the test kernel plus the `flutter_assets/` tree plus the runner binary plus the test env: editing a library that no test links, touching an asset no test bundles, or changing an unrelated target leaves a passing test cached.

#### flutter_prebuilt_test

Runs an already built test kernel under the same `flutter_tester` runtime — the same runner, protocol, env contract, JUnit XML and golden handling as `flutter_test` — without compiling anything itself. Use it when your own pipeline builds the kernel: split a large suite so one kernel build feeds many test shards, or reuse one kernel across targets whose test env differs. A `flutter_test` exposes exactly what it needs as output groups:

```starlark
filegroup(
    name = "widget_test_kernel",
    srcs = [":widget_test"],
    output_group = "test_kernel",
)

filegroup(
    name = "widget_test_assets",
    srcs = [":widget_test"],
    output_group = "test_assets",
)

flutter_prebuilt_test(
    name = "widget_prebuilt_test",
    dill = ":widget_test_kernel",
    assets = ":widget_test_assets",
)
```

`test_kernel` is the test `.dill`, `test_base_kernel` the base dill it links against at run time (empty for whole-program kernels), `test_assets` its `flutter_assets/` tree, and `test_library_tags` the entrypoint's `@Tags` as a `{"tags": [...]}` JSON file, for `flutter_prebuilt_test`'s `library_tags`. To build the assets tree yourself instead, use `flutter_asset_bundle` with the test's shaders (compiled for `flutter_tester`, as `flutter_test` compiles them) and the same `deps`: dep fonts, package assets and the Material shaders land in the bundle the same way.

To compile the kernel yourself, write the bootstrap with `flutter_test_bootstrap` from `@rules_flutter//flutter:utils.bzl` (merging `FLUTTER_TEST_BOOTSTRAP_ATTRS` into your rule's attrs for the golden block) and compile it as the entry point with `flutter_kernel_compile_action` (passing the bootstrap as `main`); then run the resulting dill under `flutter_prebuilt_test`. Extract the suite's `@Tags` with the public `//flutter/private/tools:extract_library_tags` tool and feed the JSON to `library_tags`, or the suite runs without its root-group tags. A kernel compiled from any other entry point does not dial the harness back and fails to connect. `e2e/hello_world/custom_test_kernel.bzl` is this pipeline as a running target, over the same suites its `flutter_test` twins run. For the modular variant — one entry-module compile against the dependency outlines plus a link, so body-only edits never recompile the whole program — use `flutter_modular_test_kernel` instead; `e2e/hello_world/custom_modular_test_kernel.bzl` is that pipeline as a running target, in both link modes. By default the link is complete (`use_base_dill = False`): every reachable module lands in the kernel and it runs under `flutter_prebuilt_test` with no `base_dill` — `:widget_modular_prebuilt_test` is that green run. With `use_base_dill = True` the kernel delta-links against the shared `flutter_test` base dill instead and the returned base dill must reach `flutter_prebuilt_test`'s `base_dill`: the delta is incomplete without it and `flutter_tester` aborts before connecting when it is missing — `:widget_modular_based_prebuilt_test` is that green run, fed from the kernel's `test_base_kernel` group.

### flutter_integration_test

Builds a Flutter application with an integration test (`package:integration_test` / `package:flutter_test` `WidgetTester` code) compiled in as its entrypoint, runs it on the target platform, and collects results as a Bazel test.

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_integration_test")

flutter_integration_test(
    name = "app_test",
    platform = "web",
    package_name = "my_app",
    main = "integration_test/app_test.dart",
    app_srcs = glob(["lib/**/*.dart"]),
    assets = glob(["assets/**"]),
    deps = [
        "@deps//:flutter",
        "@deps//:flutter_test",
        "@deps//:integration_test",
        "@rules_flutter//flutter:material_icons",
    ],
)
```

For `platform = "web"`, add `flutter_web_sdk` and `flutter_chrome_headless_shell` to `use_repo(flutter, ...)` in `MODULE.bazel`, and add `integration_test: {sdk: flutter}` under `dev_dependencies` in `pubspec.yaml`. The test runner serves the compiled web bundle from `127.0.0.1` on an ephemeral port, launches the hermetic pinned `chrome-headless-shell` binary with its pinned shared-library closure (`--no-sandbox`, `--disable-dev-shm-usage`), drives the in-app `WidgetTester` suite over a WebSocket channel, and fails the test on any assertion failure, uncaught error, browser crash, or timeout.

For `platform = "linux"`, the rule compiles the Linux desktop GTK runner, Dart kernel (or AOT `libapp.so`), bundled `flutter_assets/`, and any transitive native Linux plugins (`flutter_linux_plugin_library`) into a Linux application bundle. At test time, the runner starts a hermetic `Xvfb` virtual display (`@flutter_linux_headless_runtime`, choosing a free display via `-displayfd`) and runs the app against sha256-pinned GTK3, GLib, fontconfig, and Mesa `llvmpipe` software-rasterizer shared libraries — requiring no host X server, `Xvfb`, or GTK installation.

For `platform = "android"`, add `flutter_android_engine_x64` (or `flutter_android_engine_arm64` for `android_abi = "arm64"`) and `flutter_android_headless_runtime` to `use_repo(flutter, ...)` in `MODULE.bazel`. The rule compiles a full Android APK (`android_binary`) with the integration test as its entrypoint, generated `MainActivity` and `GeneratedPluginRegistrant`, bundled `flutter_assets/`, and any transitive Android plugins (`flutter_android_plugin_library` attached via `flutter_plugin.android_libs`). At test time on Linux (`x86_64` with `/dev/kvm`), the runner boots a hermetic sha256-pinned Android 35 `aosp_atd` `x86_64` emulator headless (`-no-window`, `-gpu swiftshader_indirect`, `-accel on`) against its pinned shared-library closure (`@flutter_android_headless_runtime`), installs and launches the APK via `adb`, forwards the test harness WebSocket port over `adb reverse`, and fails the test on any assertion failure, uncaught error, native crash, ANR, or timeout.

| Attribute | Description |
|---|---|
| `platform` | Target platform (`"web"`, `"linux"`, or `"android"`). Defaults to `"web"`. |
| `main` | Integration test Dart entrypoint. Required if `srcs` does not contain a single file. |
| `srcs` | Integration test Dart source files. If `main` is omitted and `srcs` has one file, that file is used as `main`. |
| `app_srcs` | Application Dart source files compiled alongside the integration test. |
| `deps` | `dart_library`, `flutter_library`, or `flutter_plugin` targets (`@deps//:flutter`, `@deps//:flutter_test`, `@deps//:integration_test`, or application libraries and plugins). |
| `assets` | Asset files bundled into `flutter_assets/`, keyed as on `flutter_application`. See [Asset keys](#asset-keys). |
| `package_name` | Dart package name matching `pubspec.yaml`. |
| `compiler` | Web compiler (`"dart2js"` or `"dart2wasm"`). Defaults to `"dart2js"`. |
| `renderer` | Web renderer (`"canvaskit"` or `"skwasm"`). Defaults to matching `compiler`. |
| `gtk_app_id` | Linux GTK application identifier (`platform = "linux"`). Defaults to `"com.example.flutter_integration_test"`. |
| `window_title` | Linux GTK window title (`platform = "linux"`). Defaults to the target name. |
| `android_package_name` | Android application package name (`platform = "android"`). Defaults to `"com.example.flutter_integration_test"`. |
| `android_abi` | Android ABI (`"x64"` or `"arm64"`, `platform = "android"`). Defaults to `"x64"`. |
| `include_tags` | Run only tests matching every one of these `package:test` tag selectors, as `flutter test --tags` intersects them. An attribute selection that matches no test fails the target. |
| `exclude_tags` | Skip tests matching any of these `package:test` tag selectors, as `flutter test --exclude-tags` unions them. Wins over `include_tags`. A `--test_env=FLUTTER_TEST_TAGS=...` (or `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute. A `@Tags` on the test entrypoint itself is extracted at build time and always honoured; a `@Tags` on an imported file stays invisible, as under `flutter test`. |

### flutter_plugin

Declares a Flutter plugin written in your workspace: its Dart code plus per-platform native implementations. Plugins from pub do not need this; the hub declares them.

```starlark
flutter_plugin(
    name = "multiply_plugin",
    srcs = ["lib/multiply_plugin.dart"],
    dart_plugin_class = "MultiplyPlugin",
    native_deps = ["//:multiply"],
    platforms = ["macos", "linux", "windows", "ios"],
)
```

| Attribute | Description |
|---|---|
| `srcs` | Dart sources. |
| `deps` | `dart_library` or `flutter_library` targets. |
| `platforms` | The platforms the plugin supports. |
| `dart_plugin_class` | The Dart class registered with the engine at startup. |
| `plugin_class` | The native plugin class, for plugins with a native registration. |
| `android_package` | The Java package of the Android `plugin_class`. Required when `platforms` lists `android` with a `plugin_class`. |
| `android_libs` | `flutter_android_plugin_library` targets auto-wired into `flutter_android_app` and `flutter_integration_test(platform = "android")`. |
| `linux_libs` | `flutter_linux_plugin_library` targets auto-wired into `flutter_linux_app` and `flutter_integration_test(platform = "linux")`. |
| `native_deps` | Shared libraries bundled for `dart:ffi`. |
| `native_assets` | `flutter_native_asset` targets, usually inside a `select()` on platform. |
| `assets`, `resources` | Asset and resource files. |
| `pkg_shaders`, `shader_includes` | The package's fragment shaders and what they `#include`, as on `flutter_library`. |
| `package_name`, `language_version`, `version` | The package's name, language version, and version. |
| `link_hook` | The package's `hook/link.dart`. See [Link hooks](#link-hooks). `flutter_library` takes it too. |

A plugin's native code is its own target. Swift goes in a `flutter_apple_plugin_library` per platform, passed as `apple_libs`. Kotlin or Java goes in a `flutter_android_plugin_library` passed as `android_libs` on `flutter_plugin` (or listed directly in `flutter_android_app(deps = ...)`), which packages it, registers its plugin class and merges its `manifest` (receivers, services, permissions) into the app's. Its `flutter_engine` is a `flutter_android_engine(neverlink = True)`: the plugin compiles against the engine and the app ships its own, of the app's ABI. `e2e/plugin_example/glass_plugin` and `e2e/integration_android/android_greeting_plugin` show both.

`e2e/ffi_example` shows a plugin built on Native Assets, `e2e/ffi_plugin_example` one with a Dart plugin class and `native_deps`, and `e2e/plugin_example` one with a Dart plugin class only.

### Asset keys

Bundle keys follow the `flutter build` rule, keyed off the package directory of the target that lists the file. An app, test, or bundle target's own `assets` are keyed by their path relative to that directory: `assets/logo.png` listed by `//apps/sub` loads as `assets/logo.png`, not `apps/sub/assets/logo.png`. The target's own `shaders` follow the same rule: `shaders/ripple.frag` listed by `//apps/sub` loads as `shaders/ripple.frag`, which is where `FragmentProgram.fromAsset` looks for it. A `flutter_library` or `flutter_plugin` asset is keyed `packages/<package_name>/<relative path>`, so `assets/brand.txt` on a library with `package_name = "brand"` loads as `packages/brand/assets/brand.txt`. Generated files follow the same directory rule by their repository-relative path, so a genrule output `apps/foo/gen/x.json` listed by `//apps/foo` loads as `gen/x.json`. Dependency keys travel untouched into every bundle on every platform, so app, `flutter_test` (`test_assets`), and `flutter_integration_test` bundles agree.

Two listings, one rule: every file in `assets` or `shaders` must sit under the listing target's package directory. A file from a nested subpackage's directory is still inside, so it keys relative to the listing directory. Only a file outside it — a sibling or parent directory, or another repository — fails the build naming the file and the target: move it into a `flutter_library` with a `package_name` and depend on it instead. Two different files keyed to the same path fail the build naming both. `pkg_assets` keeps its own `packages/<package>/<path>` keying, unchanged.

Migration note: this is a behavior change. Bundles used to key `assets` by raw workspace-relative path, so a target outside the workspace root shipped `apps/sub/assets/logo.png` where `flutter build` ships `assets/logo.png`. If a lookup uses a prefixed key, drop the prefix; if it relied on reaching another package's file through `assets`, move the file into a library and use its `packages/<name>/...` key. Targets at the workspace root keep exactly their old keys. The same change now applies to `shaders`: a target outside the workspace root ships its own shaders at package-relative keys, so a `FragmentProgram.fromAsset` lookup that used the prefixed path must drop the prefix.

### Link hooks

A package can decide what it ships from how the app uses it. Mark a `final class` with `@RecordUse()` from `package:meta` (1.19 or later), and write a `hook/link.dart` that reads the recorded uses with `package:record_use` and emits data assets with `package:data_assets`. The hook may import pure Dart from its own package's `lib/`, not Flutter.

```starlark
flutter_plugin(
    name = "symbols",
    srcs = glob(["lib/**/*.dart"]),
    link_hook = "hook/link.dart",
    platforms = [],
    deps = ["@deps//:data_assets", "@deps//:hooks", "@deps//:meta", "@deps//:record_use"],
)

flutter_application(
    name = "app",
    link_hook_assets = ["package:symbols/index.json"],
    deps = [":symbols", "@deps//:flutter"],
    # ...
)
```

Keep the hook file out of `srcs`. Bazel names every output before anything runs, so the application lists each asset its packages' hooks emit. A hook that emits an asset not listed, skips one that is, or reports an error fails the build with its own message. An application that sets `link_hook_assets` runs the hook of every package in its `deps` that has one.

In a release or profile build the kernel compile records the uses (`--recorded-uses`), each hook runs over them, and the assets are bundled at `flutter_assets/packages/<package>/<name>`, listed in `AssetManifest`, and loaded with `rootBundle.load('packages/<package>/<name>')`. Debug builds are JIT compiles, which record nothing: no hook runs and no asset is bundled, so load what the hook would have indexed on demand there. `e2e/_overlay_tests/link_hooks` is a working example, including the failing case.

### Lower-level rules

These are what `flutter_application` is made of. Most apps never need them.

| Rule | What it does |
|---|---|
| `flutter_kernel_target` | Compiles Dart to a kernel `.dill` with Flutter's patched platform kernel. |
| `flutter_aot_target` | Compiles Dart to an AOT shared library (`.so` on Linux and Android, `.dylib` on macOS) with `gen_snapshot`. |
| `flutter_asset_bundle` | Builds the `flutter_assets/` tree: `AssetManifest.bin`, `FontManifest.json`, `NOTICES.Z`, and the asset files. |
| `flutter_native_library` | Pairs a native library with its binding contract. See [Hot reload across a native rebuild](#hot-reload-across-a-native-rebuild). |
| `flutter_native_asset`, `flutter_data_asset` | Declare Dart Native Assets, from `@rules_flutter//flutter:native_assets.bzl`. A data asset is bundled at `flutter_assets/packages/<package>/<name>`. |

#### Composing your own compile rules (`flutter:utils.bzl`)

A rule in another module can run the same kernel compile `flutter_application` uses, loading only `@rules_flutter//flutter:utils.bzl`:

```starlark
load(
    "@rules_flutter//flutter:utils.bzl",
    "FLUTTER_KERNEL_COMPILE_ATTRS",
    "FLUTTER_KERNEL_COMPILE_TOOLCHAINS",
    "compile_package_config",
    "flutter_kernel_compile_action",
    "flutter_kernel_compile_tools",
)
```

`flutter_kernel_compile_tools(ctx)` resolves the tool files (`dartaotruntime`, `kernel_filter_tool`, `frontend_server`, `platform_dill` — the release dill with `product = True`), `compile_package_config` writes the `package_config.json` (with `extra_roots` for packages that contribute no sources, such as `flutter` or `sky_engine` from the toolchain — the caller must also make those roots' files action inputs), and `flutter_kernel_compile_action` runs the compile, with optional `vm_flags` (allow-listed Dart VM flags before the snapshot: heap/GC sizing such as `--old-gen-heap-size=1073741824`, and bare diagnostics such as `--enable-asserts`), `import_dill` (a pre-compiled summary passed as `--import-dill`), and `resource_set` (host resource constraints). Merge `FLUTTER_KERNEL_COMPILE_ATTRS` into the rule's `attrs` and declare `FLUTTER_KERNEL_COMPILE_TOOLCHAINS`; the rule keeps its own `main`, `srcs` and `deps`.

Soundness rule for `vm_flags` and `extra_flags`: only the documented tuning flags may precede the snapshot — anything naming a file or a host side effect (`--packages`, `--*-dill`, `--platform`, `--native-assets`, `--timeline-recorder`, `--snapshot*`, `--observe`, `--dfe` and similar in `vm_flags`; any `frontend_server` flag naming a file the compile does not declare in `extra_flags`) fails the build at analysis. The guard behind the compile (`kernel_filter`) takes every allowed read from a manifest the action writes from its declared files — never from the compile argv — so a smuggled flag cannot widen what the compile may read.

Soundness rule for `import_dill`: `frontend_server` re-reads an imported dill's whole source closure on every compile, so the consuming compile must still declare those sources — the guard accepts the declared reads and refuses anything undeclared. Pass `--incremental` (via `extra_flags`) so the compiler does not additionally re-read the dill's own entry main. `e2e/smoke` shows the full chain from another module: a plain kernel, one with `vm_flags` and `resource_set`, and one consuming a real `import_dill` dill.

The same file also publishes the modular path the built-in `flutter_test` and app rules compile with when eligible: `flutter_kernel_module_aspect` (the same aspect object the built-in rules use, so a library's module action keeps its action key across built-in and custom pipelines), the `FlutterKernelModuleInfo` provider it produces, the `FLUTTER_MODULAR_KERNEL_ATTRS` / `FLUTTER_MODULAR_KERNEL_TOOLCHAINS` dicts a calling rule merges and declares, and two entry functions — `flutter_modular_test_kernel(ctx, test_uri, deps, output, use_base_dill = False)`, which writes the `flutter_test` bootstrap protocol entry, compiles it against the dependency outlines and links it (run the result under `flutter_prebuilt_test`), and `flutter_modular_app_kernel(ctx, main, package_name, srcs, deps, output, use_base_dill = False)`, which does the same for an app entry point with the debug platform dill prepended.

Use the whole-program path when the pipeline needs `defines`, native assets, or a flag-bearing global `extra_dart_defines` to reach the compile: those route a custom modular kernel to a build error (it has no whole-program fallback), while the built-in rules silently fall back. Use the modular path when the closure is define-free and incremental rebuilds matter: a body-only edit to one library then recompiles only that library's module plus the entry/link actions, never the whole program — in both link modes. The default complete link (`use_base_dill = False`, as in rules_dart's `modular_executable_kernel`) puts every reachable module in the kernel, which runs with no `base_dill`; pass `use_base_dill = True` to delta-link against the shared `flutter_test` base instead, and feed the returned base dill to `flutter_prebuilt_test`'s `base_dill` exactly as a `flutter_test` kernel's `test_base_kernel` must. The delta pays off when many tests share one SDK base: each per-test dill stays small while the base builds once. The custom `deps` edge resets a non-empty global `extra_dart_defines` for the custom closure (which `kernel_worker` could not parse anyway when a value holds a comma) and leaves the configuration untouched when the flag is empty, so modules keep sharing action keys with the built-in rules. `e2e/hello_world/custom_modular_test_kernel.bzl` is both pipelines as running targets: a custom modular test kernel over two `flutter_library` packages under `flutter_prebuilt_test` (complete and base-linked), and a custom modular app kernel.

Stability note: `flutter:utils.bzl` is stable for external use. New optional parameters may be added to `flutter_kernel_compile_action`, but existing calls keep their command line and action keys.

### Code generation

rules_dart provides `dart_codegen` and `dart_aggregate_codegen`, which replace `build_runner` with ordinary Bazel actions. They load from `@rules_dart//dart:defs.bzl`. A generated file goes into the consuming target's `srcs`, and the rules place it next to its hand-written sibling so a `part` directive resolves:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_aggregate_codegen", "dart_codegen")

# One output per input file, for example a json_serializable part.
dart_codegen(
    name = "user_json",
    package_name = "my_app",
    src = "lib/user.dart",
    generator = "tools/json_generator.dart",
    output_suffixes = [".g.dart"],
)

# One output from all the inputs, for example a route registry.
dart_aggregate_codegen(
    name = "registry",
    package_name = "my_app",
    srcs = ["lib/model.dart", "lib/order.dart"],
    generator_script = "tools/aggregate_generator.dart",
    outputs = ["lib/registry.g.dart"],
)

flutter_application(
    name = "my_app",
    package_name = "my_app",
    main = "lib/main.dart",
    srcs = ["lib/user.dart", ":user_json", ":registry"],
    deps = ["@deps//:flutter"],
)
```

`e2e/codegen` is the worked example, including generated code in dependency packages and hot reload over regenerated sources.

#### flutter_gen_l10n

Generates `AppLocalizations` from `.arb` files, the equivalent of `flutter gen-l10n`.

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

The generated files land beside the `.arb` files, and a consumer collects them by listing the target in `srcs`. The attributes mirror the flags of `flutter gen-l10n` with the same defaults: `template_arb_file`, `output_class`, `use_deferred_loading`, and so on. `l10n.yaml` is not read, because Bazel has to know the output file names during analysis and a config file read while the action runs cannot tell it.

A few things to know:

- **Keep `@@locale` consistent with the filename.** The rule derives output names from the arb filenames, while the generator decides what to write from each file's `@@locale`. If `app_english.arb` declares `"@@locale": "en"`, Bazel expects `app_localizations_english.dart` and the generator writes `app_localizations_en.dart`, which surfaces as "output was not created". Bazel cannot read file contents during analysis, so the rule cannot check this for you.
- **Outputs are grouped by primary language.** `app_es.arb` and `app_es_419.arb` produce one `app_localizations_es.dart` holding both classes, matching upstream.
- **Generated files always use LF line endings.** Upstream copies the line endings of `pubspec.yaml`, which would make the output depend on a file the action does not declare.
- **There is no `format` attribute.** Formatting shells out to the `dart` binary, which the action does not have. Setting it is an error rather than a silent no-op. rules_dart's format check covers hand-written files only, so the generated sources are not checked.
- **Two copies of `intl` are in play.** The generator has its own. An app using the generated code needs `intl` in its own lock. Upstream has the same split.

The generator is carved out of `flutter_tools` at fetch time with a set of patches, so a Flutter version bump re-validates it. A release that moves the patch context fails the patch, and a new release also needs a `source_sha256` in `flutter/private/versions.bzl`. Two things those checks cannot catch: a newly added read of an undeclared file at run time, which shows up as a `PathNotFoundException`, and a newly adopted `dart:io` API newer than the Dart that rules_dart provides, which shows up as a compile error naming a missing type. The fix for the second is to cut the dead code that uses it, as the existing patches do for an unused `NetworkInterface` wrapper. See `flutter/private/flutter_gen_l10n_repo.bzl`.

On Windows, the repository rule extracts all of `packages/flutter_tools` (about 19 MB) and uses twenty of its files. The deepest path is around 130 characters from the repository root, which fits within `MAX_PATH` given a short `output_user_root`.

### Providers

**`FlutterSdkInfo`** comes from the toolchain and carries the engine binaries and SDK files a custom rule needs. Core host fields live directly on `@rules_flutter//flutter:toolchain_type`; lazy-fetched fields (`gen_snapshot`, `platform_kernel_dill_product`, `const_finder`, `font_subset`, `engine_library`, `linux_sysroot`, `material_icons_font`) live on optional sub-toolchains so builds only download the repositories they use. Use `resolve_flutter_sdk_info(ctx)` with `FLUTTER_OPTIONAL_TOOLCHAINS` (from `@rules_flutter//flutter:providers.bzl` or `@rules_flutter//flutter:toolchain.bzl`) to merge them:

```starlark
load("@rules_flutter//flutter:providers.bzl", "FLUTTER_OPTIONAL_TOOLCHAINS", "resolve_flutter_sdk_info")

# In rule(..., toolchains = ["@rules_flutter//flutter:toolchain_type"] + FLUTTER_OPTIONAL_TOOLCHAINS):
sdk = resolve_flutter_sdk_info(ctx)
```

| Field | Type | Description |
|---|---|---|
| `version` | `str` | The Flutter SDK version, for example `"3.47.7"`. |
| `engine_revision` | `str` | The engine commit hash. |
| `dart` | `File` | Deprecated. The `dart` executable from the bundled Dart SDK; prefer `@rules_dart//dart:exec_tools_toolchain_type`. |
| `dartaotruntime` | `File` | The runtime for AOT snapshots. |
| `gen_snapshot` | `File` or `None` | The AOT compiler (resolved via `@rules_flutter//flutter:aot_toolchain_type`). |
| `frontend_server` | `File` | `frontend_server_aot.dart.snapshot`, for kernel compilation. |
| `platform_kernel_dill` | `File` | `platform_strong.dill`, the debug platform kernel. |
| `platform_kernel_dill_product` | `File` or `None` | `platform_strong_product.dill`, the release platform kernel (resolved via `@rules_flutter//flutter:product_tools_toolchain_type`). |
| `patched_sdk` | `Target` | The Flutter-patched Dart SDK root. |
| `icu_data` | `File` | `icudtl.dat`. |
| `tool_files` | `depset[File]` | Deprecated. All files in the bundled Dart SDK and patched SDK; prefer `@rules_dart//dart:exec_tools_toolchain_type` or the action-specific `dart_*_files` sets. |
| `dart_vm_files` | `depset[File]` | Minimal Dart SDK files needed to run the `dart` VM on a snapshot (`bin/dart`, `bin/dartvm`). |
| `dart_pub_files` | `depset[File]` | Minimal Dart SDK files needed for `dart pub` (`bin/dart`, `bin/dartaotruntime`, `bin/snapshots/dartdev_aot.dart.snapshot`, `version`). |
| `dart2wasm_files` | `depset[File]` | Minimal Dart SDK files needed for `dart compile wasm` (`bin/dart`, `bin/dartaotruntime`, `bin/snapshots/dart2wasm_product.snapshot`, `bin/wasm-opt`). |
| `dart2js_files` | `depset[File]` | Minimal Dart SDK files needed for `dart compile js` (`bin/dart`, `bin/dartvm`, `bin/snapshots/dart2js.dart.snapshot`). |
| `engine_library` | `Target` or `None` | The platform engine runtime library. `None` for mobile and web (resolved via `@rules_flutter//flutter:desktop_engine_toolchain_type`). |
| `linux_sysroot` | `Target` or `None` | The Chromium sysroot filegroup for Linux GTK3 builds (resolved via `@rules_flutter//flutter:desktop_engine_toolchain_type`). |
| `const_finder` | `File` or `None` | `const_finder.dart.snapshot`, for icon tree shaking (resolved via `@rules_flutter//flutter:product_tools_toolchain_type`). |
| `font_subset` | `File` or `None` | The `font-subset` binary (resolved via `@rules_flutter//flutter:product_tools_toolchain_type`). |
| `material_icons_font` | `File` or `None` | `MaterialIcons-Regular.otf` (resolved via `@rules_flutter//flutter:material_icons_toolchain_type`). |
| `impellerc` | `File` or `None` | The shader compiler. |
| `shader_lib` | `list[File]` | Shader include files for impellerc. |
| `target_os`, `target_arch` | `str` | The cross-compilation target, or empty for a native build. |

A Flutter workspace's Dart toolchain is the Dart SDK bundled with its Flutter release. Analysis, formatting, codegen, `dart_test` and `dart_binary` all use it, so the workspace downloads one Dart SDK, not two. A root module that registers its own Dart toolchain before `@flutter_toolchains` keeps it.

**`FlutterInfo`** is carried by `flutter_library` and `flutter_plugin`:

| Field | Type | Description |
|---|---|---|
| `asset_dirs` | `depset[File]` | Directories containing assets. |
| `plugins` | `list[struct]` | Plugin metadata, each with `name` and `platforms`. |
| `transitive_native_libs` | `depset[File]` | Shared libraries from plugins' `native_deps`. |

**`FlutterApplicationInfo`** is carried by `flutter_application` and consumed by the platform rules:

| Field | Type | Description |
|---|---|---|
| `aot_output` | `File` or `None` | AOT native code. `None` in debug mode. |
| `kernel_dill` | `File` or `None` | The kernel `.dill`. `None` in release mode. |
| `flutter_assets` | `File` | The `flutter_assets/` tree. |
| `icu_data` | `File` | `icudtl.dat`. |
| `native_libs` | `list[File]` | Shared libraries from `native_deps`. |
| `is_debug` | `bool` | `True` for a debug build. |
| `native_plugin_registrant` | `File` or `None` | The generated plugin registrant source for desktop platforms. |

## The dev tool

`flutter_bazel`, in `tools/dev_tool/`, is the development loop: it builds a target, installs and launches it on a device, and gives you hot reload and hot restart. It speaks the same `--machine` JSON-RPC protocol as `flutter run`, so the existing IDE plugins for VS Code and IntelliJ work with it. It also opens an HTTP channel that scripts and coding agents can use to drive the running app.

### Running an app

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_macos -d macos
```

`run` builds the target, launches it, and then watches the filesystem. Saving a Dart file triggers a hot reload. The flags most people use:

| Flag | What it does |
|---|---|
| `-t`, `--target` | The Bazel target to build and run. Required. |
| `-d`, `--device` | Where to run it. Repeat for several devices at once. See below. |
| `-c`, `--config` | A Bazel config to build with. |
| `--build-arg` | An extra argument for `bazel build`. Repeatable. |
| `--dart-define KEY=VALUE` | A Dart define, forwarded to the build and replayed on reload and restart. Repeatable. |
| `--no-hot` | Run without hot reload. |
| `--profile` | Profile mode: AOT with the Dart VM service, for DevTools. Builds `-c opt --@rules_flutter//flutter:profile`. Not on the iOS simulator. |
| `--start-paused` | Hold the app at the start of `main()` until a debugger resumes it. |
| `--route` | The initial route. |
| `--no-watch` | Do not reload on save. Watching is on in terminal mode and off in `--machine` mode. |
| `--no-devtools` | Do not launch DevTools. |
| `--machine` | Speak the JSON-RPC protocol on stdout. |
| `--no-http-control-channel` | Do not open the HTTP channel. |
| `--wasm` | On the web, run the WASM build. No hot reload; edits rebuild and reload the page. |
| `--web-port`, `--web-hostname`, `--web-launch-url`, `--web-viewport`, `--web-run-headless`, `--web-header`, `--web-browser-flag` | Web dev server and browser settings. `--web-viewport 393x660@3` lays the app out at a phone-sized viewport regardless of the window. |

`flutter_bazel build` builds without running, and `flutter_bazel attach --debug-url <uri>` attaches to an app that is already running. `--help` on each command lists everything.

### Shorter commands with bazel_env

[bazel_env.bzl](https://github.com/buildbuddy-io/bazel_env.bzl) puts Bazel-built tools on your `PATH` under names you choose, so the dev tool becomes a two-letter command. Add it to `MODULE.bazel` and declare the tool:

```starlark
# MODULE.bazel
bazel_dep(name = "bazel_env.bzl", version = "0.9.0", dev_dependency = True)
```

```starlark
# BUILD.bazel
load("@bazel_env.bzl", "bazel_env")

bazel_env(
    name = "bazel_env",
    tools = {
        "fl": "@rules_flutter//tools/dev_tool:flutter_bazel",
    },
)
```

Then run `bazel run //:bazel_env` once. It builds the tool, writes a shim to `.bazel_env/bin/fl`, and prints setup instructions for [direnv](https://direnv.net), which amount to this `.envrc` next to `MODULE.bazel`:

```sh
watch_file .bazel_env/bin
PATH_add .bazel_env/bin
if [[ ! -d .bazel_env/bin ]]; then
  log_error "ERROR[bazel_env.bzl]: Run 'bazel run //:bazel_env' to regenerate .bazel_env/bin"
fi
```

After `direnv allow`, the command is `fl run -t //:my_app_macos -d macos`, from any directory in the workspace. The shim finds the workspace root with `bazel info workspace`, so it does not depend on being launched by `bazel run`. Add `.bazel_env` to `.gitignore`. Without direnv, `bazel run //:bazel_env print-path` prints the directory to add to `PATH` yourself.

The rest of this section spells the command out in full so it works before you set this up.

### Choosing a device

`-d` takes:

| Id | Reaches |
|---|---|
| `macos`, `linux`, `windows` | The host desktop. |
| `chrome` | A browser, through the dev module server. |
| `ios-simulator`, `ios-simulator:<udid>` | The booted simulator, or the one named. |
| `ios`, `ios:<udid>` | The attached iPhone, or the one named. |
| `android`, `android:<serial>` | Whichever device `adb` picks, or the one named. |

An id has to say what kind of device it names, so a bare UDID or serial is refused: an emulator is `-d android:emulator-5554`, not `-d emulator-5554`. Guessing the kind would mean asking `simctl`, `devicectl` and `adb` on every launch. When an id is refused, the tool asks them then, and names the form to pass, for example `pass -d ios-simulator:<udid>`.

For `-d ios`, the tool lists attached devices with `devicectl` and ignores devices that were paired once but are not attached now. With two attached, it asks for `-d ios:<udid>` rather than guessing. A device has two identifiers, the hardware UDID Xcode shows and the CoreDevice UUID that `devicectl` prints, and either works there.

### Hot reload and hot restart

In terminal mode, press `r` to reload and `R` to restart, or just save a file. A reload compiles only the changed libraries and injects them into the running isolate, keeping app state. A restart re-runs `main()`, so it also reflects changes to code that runs only at startup.

An edited shader reloads too, including one from a package in your workspace and one whose `#include` you changed: the reload recompiles it and has the engine reinitialize the program, as `flutter run` does. A web page cannot reinitialize a shader, so there the reload says so and a restart picks it up.

An app whose `main` sits outside its package's `lib/` reloads and restarts the same way, like `flutter run -t test_driver/app.dart`. Such a file has no `package:` URI, so the build and the dev loop both compile it as `org-dartlang-app:///<its workspace path>`. Edits to it, and to the files it imports by relative path, are picked up because the build lists them: its compile can read only the `main` and the `srcs` you declare, so declare the siblings in `srcs`. As in any Dart program, reach code under `lib/` through `package:` imports, not `../lib/...`. A relative import there loads a second copy of that library, and its types stop matching the originals.

A restart can go one step further. Dart code can be swapped into a running process, but a native library the process has already loaded cannot. So when a rebuild changes one of the app's native libraries (`native_deps` or Native Assets, including the `.framework` each becomes on iOS), `app.restart` relaunches the process instead of restarting the isolate, and says so in its response. If the replacement cannot launch, for example because the device has no room for the new install, the restart fails with the reason and the run ends, since the old process is already gone. The HTTP channel, its token, and the `appId` stay the same across a relaunch. Only the log buffer starts over.

A hot reload cannot relaunch anything, because replacing the process is exactly the state loss a reload exists to avoid. When a reload rebuilds a native library, what happens depends on whether the bindings changed with it, which is what `flutter_native_library`'s `binding_contract` tells the tool. See [Hot reload across a native rebuild](#hot-reload-across-a-native-rebuild). Without that declaration, the reload is withheld and a restart picks up the library. A plain Dart edit takes the fast path: the check costs a `stat` per declared file and reaches Bazel only when one of them moved.

### App output

A running app's console output (`print`, `debugPrint`, `NSLog`, Java stack traces, uncaught errors) is forwarded for the whole run, starting before the VM service is up so that startup failures are visible.

In terminal mode the app's stdout goes to the tool's stdout and its stderr to the tool's stderr, matching `flutter run`. With more than one `-d`, lines are prefixed with `[<device>] `. In `--machine` mode the output arrives as `app.log` events, and nothing else is written to raw stdout, which belongs to the protocol stream.

Each platform has exactly one log source, because a Dart `print()` reaches both the process's stdout and the VM service's `Stdout` stream, and reading both would duplicate every line:

| Platform | Source |
|---|---|
| macOS, Linux, Windows | The process's stdout and stderr. |
| Android | `adb logcat`, filtered to `flutter*`, `DartVM`, `AndroidRuntime`, `System.err`, and fatal records. |
| iOS simulator | A `simctl spawn log stream` scoped to the app process. |
| iOS device | `devicectl --console` plus lldb's output. lldb stays attached for the whole run. |
| Chrome, dev loop | The DWDS VM service's `Stdout` and `Stderr` streams. |
| Chrome, WASM or production JS | Chrome DevTools Protocol console events. |
| `attach` | The VM service's `Stdout` and `Stderr` streams, since there is no process to read. |

### Assets and fonts

An edit to a bundled asset goes live on hot reload or on save, the same as a Dart edit. The tool knows which workspace directories feed the `flutter_assets` tree, so it can tell whether an asset changed from a few directory listings. A run whose assets are untouched never pays for a `bazel build` on a Dart edit.

When an asset has changed, the bundle is rebuilt and only the differing entries are uploaded into the app's devFS. That is what makes it work on a phone, inside an APK, and inside a sandboxed macOS app, none of which can read `bazel-out`. Everything else still resolves to what shipped, because the engine keeps the original bundle behind the devFS directory. A changed font also re-registers the engine's font collection, so re-exporting a `.ttf` takes effect where upstream waits for a restart.

On the web the dev server serves `assets/` from the build tree on every request, so only the page's caches are dropped. Fonts are the exception: the web engine registers them once at startup with no reload hook, and the reload says so rather than reporting success.

### Debugging from the first line

`flutter_bazel run --start-paused` holds the app at the beginning of `main()` so a debugger can attach before any app code runs. Each platform gets the switch the way it accepts one: an engine switch on desktop, an intent extra on Android, argv on iOS. On the web there is no switch; DWDS holds `main()` until a client resumes it, so the tool withholds the run request.

The pause is reported only once the tool has observed it from the main isolate's own pause event, so a target that ignored the switch is called out rather than leaving you waiting at a debugger for an app that already ran. While paused, `app.*` commands answer with the reason instead of blocking, and `--route` and `--trace-startup` are skipped with a warning, because both need a framework that has not started.

### Physical iOS devices

On every platform except iOS hardware, the VM service URI arrives in the app's log: the engine prints it, and the tool reads it off the same stream that carries app output.

An iPhone is different. A wirelessly attached device has no console channel at all, and a wired device's console belongs to the `devicectl` call that launched the app. So the tool finds the URI through the app's mDNS advertisement instead. Every Flutter app built in debug or profile mode advertises `_dartVmService._tcp` with its port and auth code, and the generated debug and profile `Info.plist` declares the matching `NSBonjourServices` entry, so this works for any app built with these rules and no configuration.

| Connection | VM service host | Port |
|---|---|---|
| Wired | `127.0.0.1` through an `iproxy` forward, because the service binds to the device's loopback. | The advertised port, forwarded. |
| Wireless | The device's own address, from the advertisement. | The advertised port, dialed directly. |

The tool picks the pair from what `devicectl list devices` reports. A wireless launch also passes `--vm-service-host=0.0.0.0` so the service is reachable off-device, and a wired launch does not.

When discovery fails, three things are worth checking:

- **Local Network permission.** On macOS the mDNS socket needs it. If it is denied, the error names System Settings > Privacy & Security > Local Network. The device also prompts once, the first time an app advertises.
- **Lost queries.** mDNS is UDP and the spec requires retransmission. Against a USB-attached iPhone a single query succeeded about two times in five, so the tool retransmits with the specified backoff. In practice it resolves in around 200 ms, with 3.3 s the worst observed.
- **`dns-sd` does not show what this tool sees**, in either direction. It answers from mDNSResponder's table, which includes records a raw multicast socket cannot reach: over USB, CoreDevice proxies the device's Bonjour records in as local-only registrations. So `dns-sd` listing the phone while the tool sees nothing over USB is correct on both sides. The table also keeps stale `_dartVmService` records on `lo0` from booted simulators with no app running. Unplugged, the phone multicasts for real on `en0` or `en1` and the raw socket sees it. If you do use `dns-sd`, read the interface index on each `Add` line; interface 1 is `lo0` and proves nothing about the device.

**Launch times.** Expect the first log line to take longer than on a host. A debug build runs under the JIT breakpoint, and the engine traps to the debugger for every executable page it allocates, with each trap writing to device memory over the debugserver link. On a recent iPhone with a healthy Xcode install, the time from resume to the engine's first log line measured about 8 seconds over a cable and about 40 seconds over Wi-Fi. A cable is several times faster, but Wi-Fi works.

A launch that takes minutes means something is wrong on the host, not the phone. The usual cause is an unfinished Xcode symbol copy, which leaves lldb without the shared cache. Check that Xcode has finished copying symbols for the device before looking anywhere else. The tool prints a "still waiting" note at 45 seconds so a slow launch stays distinguishable from a hang.

Hot reload and restart get the same allowance. A reload is quick, since only the changed library is compiled. A restart re-runs `main()` and pays the breakpoint cost again, so it takes about as long as the launch. The per-call budget is five minutes wired and fifteen wireless, against thirty seconds on a host. Those are backstops for a run that will never succeed, sized for the slowest host state seen rather than the seconds a healthy one takes, because a budget that is too short does worse than wait less: it abandons the RPC and force-closes the VM service connection, reporting a timeout for a restart that was about to succeed.

**Debugger stops.** On iOS 26 and later the engine announces each new page of JIT code at a breakpoint, and the debugger has to write the page before the app may run it. The tool resumes every one of those stops itself rather than letting lldb continue on its own: lldb loses some of them when two threads allocate code at once ([llvm/llvm-project#190956](https://github.com/llvm/llvm-project/issues/190956)), and the app then stops on `EXC_BAD_ACCESS (code=50)` with its VM service silent. `flutter_tools` handles it the same way. Any other stop, such as a native crash, is written to the app's output with a backtrace, and the debugger detaches and the run ends, as it does when an app exits on any other platform. Stopping a run, or a launch that fails part way, terminates the app on the device and every helper process it started.

For log output, `devicectl --console` also carries devicectl's own progress banners, and lldb's output is included because lldb holds the debugserver the JIT depends on. Upstream does the same: with Xcode 26 and later, `flutter_tools` reads both, noting that `idevicesyslog` stopped working.

### Driving the app from a script

`flutter_bazel run` opens an HTTP control channel by default. IDE integrations, coding agents, and end-to-end test harnesses can drive the running app through it without a terminal: tap widgets, enter text, read text back, take screenshots, reload, restart, and shut down.

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- \
  run -t //:my_app_macos -d macos --machine
```

On stderr, the tool prints the channel's record. Under `LOG_FORMAT=json` it is one JSON line that carries every endpoint with a ready-made URL, token included. The token is a query parameter, not an `Authorization` header:

```json
{"message":"http_control_channel","uri":"http://localhost:PORT",
 "token":"...","tokenParam":"token","endpoints":[
   {"method":"POST","path":"/command",
    "url":"http://localhost:PORT/command?token=...", ...}, ...]}
```

On stdout, the protocol stream starts with `daemon.connected` and then reports `app.start`, `app.started`, and the rest.

**What counts as protocol on stdout.** A line is a protocol message if and only if it is a `[{…}]` envelope. Anything else is passthrough output that a client should show to the user rather than parse. That is upstream's convention too, and it is what makes `bazel run` safe here: bazel forwards a successful action's stdout, so a run that first has to rebuild the tool prints a line like `Generated: /…/flutter_bazel` before the first envelope.

#### Endpoints

| Endpoint | Verb | Purpose |
|---|---|---|
| `/command?token=…` | `POST` | Run a protocol method against the session. Body: `{"method":"app.<X>", "params":{"appId":"…", …}}`. |
| `/commands?token=…` | `GET` | What this run can do right now: `{"protocolVersion", "commands":[{"name","longRunning"}]}`. |
| `/sessions/{appId}/logs?token=…` | `GET` | The app's console output, from a bounded ring buffer. |
| `/sessions/{appId}/screenshot/native?token=…` | `GET` | A PNG of the app as the platform sees it. Works on every device. |
| `/sessions/{appId}/screenshot/flutter?token=…` | `GET` | A PNG of the widget tree from the engine. Not available at the pinned Flutter; see below. |

The endpoints speak plain HTTP/1.1, so `curl -s "$URI/..."` works. If your `curl` tries HTTP/2 by default, add `--http1.1`.

#### Which commands are available

The set of commands is not fixed when a client connects. It grows through the run and describes this run rather than the tool. A web run gains `app.setViewport` once the browser is up and never offers `app.buildInfo`, because only a `-c dbg` native build carries the record that command reads. The widget-driving commands are offered once the tool knows the run has a VM service, which is every native run and the DDC dev loop on the web, and they answer once that service exists, which on the web and on an iPhone is well after `app.started`. `app.pressKey` is offered at the same point on every run, since a web run without a VM service can still take keys through the browser. So re-read `/commands` rather than caching the first answer. `longRunning` marks commands that rebuild or recompile before answering; those deserve a generous timeout and are the ones `app.progress` events are emitted for.

A `--machine` client does not need the endpoint. It receives the list in `daemon.connected` and again in every `daemon.commandsChanged`. `daemon.connected` also carries `protocolVersion`. The protocol stream is also the only place for things the channel cannot push: `app.devTools` carries the DevTools URL, `app.debugPort` the VM service's `port`, `wsUri`, and `baseUri`, and `app.webLaunchUrl` the address a web run is served at. The browser the tool launches uses a scratch profile and may be headless, so that URL is how you open the page in your own browser. The full event list is the header comment of `tools/dev_tool/lib/machine_protocol.dart`.

**Driving the browser yourself.** `app.webLaunchUrl` also carries the browser's DevTools protocol endpoint: `cdpPort`, and `webSocketDebuggerUrl` for the app's page. The same two fields are on the `web_app_url` log record, for a client reading stderr. Chrome picks the port, so nothing else tells you where it is. With it you can send your own `Input.dispatchKeyEvent`, `Runtime.evaluate` or trace. The page URL is the one listed when the browser came up. It survived a `--wasm` hot restart when we checked, but if it stops answering, re-read `http://127.0.0.1:<cdpPort>/json` and pick the `page` target on the app's origin, as the tool does before each of its own uses. Chrome takes several DevTools clients at once, so yours does not displace the tool's.

The commands, once the app is up:

- **Widget driving:** `app.dumpWidgetTree`, `app.tap`, `app.longPress`, `app.doubleTap`, `app.drag`, `app.hover`, `app.hoverExit`, `app.setWindowActive`, `app.scrollIntoView`, `app.enterText`, `app.getText`, `app.getRect`, `app.waitFor`, `app.waitForAbsent`, `app.pageBack`, `app.settle`. These are served by extensions the app registers before `main()` on every launch, so they survive hot restart.
- **Keys:** `app.pressKey`, on every run, including `--wasm` and `--profile` web runs. See [Pressing keys](#pressing-keys).
- **Lifecycle:** `app.hotReload`, `app.restart`, `app.stop`, `daemon.shutdown`.
- **Run-specific:** `app.buildInfo` on native debug runs, `app.setViewport` on web runs.

**Hover, mouse presses and window focus.** `app.hover` moves a synthetic mouse over the widget a selector names (its centre) or to `x` and `y` in logical pixels, and `app.hoverExit` takes it off the app. Neither moves the system cursor's position, so the real mouse stays free. The mouse stays where it was left, as a real one does. `app.tap`, `app.longPress`, `app.doubleTap` and `app.drag` take `"pointer": "mouse"` to press from that mouse, with the primary button, instead of from a finger, so a widget sees hover and press together. All four also take `x` and `y` instead of a selector, and a mouse press with neither lands where the mouse already is: hover, then press. The `app.hover` reply carries `cursor`, the cursor the widget under the mouse asked for (`click`, `text`, and so on), so it can be checked without looking at the screen. The engine applies a hover's cursor to the host, so the tool puts the arrow straight back after each move, and the host's cursor is the arrow again by the time the reply comes; `app.hoverExit` puts it back too (`cursorRestored`). The host's cursor shape can still change for an instant, and a real pointer over the window gets its own shape at its next movement. A hover has no timer of its own: pass `"settle": "false"` and wait as long as the state you are reading needs, a tooltip's delay for one. `app.settle` and the wait after every command treat the app as idle when no frame is scheduled, as `pumpAndSettle` does, so a visible tooltip does not keep them from settling. `app.settle` answers `settled` as `yes`, `no` or `skipped`, with `settleDetail` when it is not `yes`, like every other command. `app.setWindowActive` with `"active": "true"` or `"false"` tells the framework the window is focused or not (`AppLifecycleState.resumed` or `inactive`) without changing the frontmost app. That is the framework's view only: the native window's key state is untouched, a real click or key in the window flips it back, and AppKit-drawn chrome such as the traffic lights does not follow. A macOS window with no title bar can never become key, so there it is the only way to see the active state.

`app.stop` stops the one app its `appId` names, as upstream's does. A run driving two devices carries on with the other. A bare `app.stop` with no `appId` is refused rather than read as "all of them". `daemon.shutdown` ends the run: every app, the browser, the compiler, and the tool itself.

**A web run without a VM service offers no widget driving.** `--wasm`, `--profile`, and `--no-hot` serve a bundle built by dart2wasm or dart2js, where `registerExtension` is a stub and there is no service to dispatch through. The commands are absent from `/commands` rather than present and refusing, and the run says so once at startup as an `agent_surface_unavailable` log record. Such a run can still serve `app.pressKey`, `/logs`, `screenshot/native`, and `app.restart`. To drive the widget tree on the web, run the DDC dev loop: neither `--wasm` nor `--profile`.

**Commands issued early wait.** `app.started` means `main()` has begun, which is what upstream's protocol means by it, and an app that has begun running has not built a widget tree yet. On `-d chrome` the gap is DWDS, which holds `main()` until the browser has connected. On an iPhone the gap is the app's own start, measured at 61 seconds after `app.started` for a debug build. A command sent in that window waits it out rather than failing, so you can fire on `app.started` without a readiness poll. The wait is reported as an `app.progress` pair — "Waiting for the app to render its first frame" opening it, and what the wait found closing it, so a client reading the stream can tell a frame that arrived from one that never did. An app that never paints is refused with a reason rather than a bare timeout. Waiting for a specific widget is still yours to ask for, with `app.waitFor`.

#### Reading logs

`/logs` is polled with a cursor. There is no long-lived connection, and each call returns exactly what you ask for.

| `since` | Meaning |
|---|---|
| omitted | The last 200 lines. Use this when you have no cursor yet. |
| `-N` | The last `N` lines. |
| `0` | Everything still buffered, oldest first. |
| `N > 0` | Resume at line `N`. Feed back a previous `nextCursor`. |

`limit` caps the page, with a default and maximum of 500. A non-numeric `since` or a non-positive `limit` is a `400`, because a mistyped cursor would otherwise look like a working poll loop that re-reads the tail forever.

```sh
# Tail, then poll forward.
curl -s "$URI/sessions/$APP/logs?token=$T"
# {"lines":[{"index":812,"text":"flutter: meter -18dB","error":false}],
#  "nextCursor":813,"launch":1,"missed":0,"dropped":0,"closed":false}

curl -s "$URI/sessions/$APP/logs?token=$T&since=813"
```

The fields in the response:

- `error` marks lines that arrived on an error channel: the process's stderr, a VM service `Stderr` event, `console.error`. It is a channel, not a severity. Platforms that deliver the whole device log over one stream (iOS and Android) deliver engine `[ERROR:…]` lines with `error: false`, so match on the text if you care about those.
- `missed` is non-zero when the cursor you asked for had already been evicted, so a poller learns it has a gap instead of reading a short page as complete. `dropped` is the total evicted over the run.
- `closed` turns true once the app's output has ended, so a poll loop can stop. The buffer survives the app's exit, so a crashed app's final output is still readable.
- `launch` is which launch of the app the page came from: 1 for the original, one more per relaunch. Each launch buffers from zero, so when `launch` changes, drop your cursor and re-tail.

#### Screenshots

`screenshot/native` captures the app the way the platform sees it (`screencapture`, `scrot`, `simctl io screenshot`, `adb screencap`, or the browser's own capture) and works on every device. `screenshot/flutter` asks the engine for the widget tree alone, with no window chrome, but the engine cannot produce it under Impeller and there is no engine screenshot on the web at all. Since Flutter 3.47 every platform renders with Impeller by default, so every device answers `501` naming `screenshot/native`. The tool does not try to detect an app that has turned Impeller off, because `screenshot/native` captures either way.

Both endpoints wait for the app to go idle before capturing, so a screenshot taken right after `app.tap` shows what the tap did. Without that wait you would get the frame from before the action painted, and a stale picture is indistinguishable from a feature that did not work. The response says what you got: `X-Settled: yes` means the app was idle first, `no` means the wait ran out or the app is backgrounded, and `skipped` means you passed `settle=false` or the run has no VM service to ask (`--wasm`, `--profile`). `X-Settle-Detail` carries the reason for anything but `yes`, percent-encoded so it can hold characters a header cannot; any URI-component decoder gives back the text. The wait is never fatal, since an app that cannot settle is the one whose picture you most want. `app.settle` is the same wait as a command, for use between two of your own.

#### Driving widgets

Methods that target a widget (`tap`, `longPress`, `doubleTap`, `drag`, `getRect`, `getText`, `enterText`, `scrollIntoView`, `waitFor`, `waitForAbsent`) take exactly one selector, following `flutter_driver`'s finder vocabulary:

| Param | Matches |
|---|---|
| `key` | A widget whose `ValueKey` value equals the string. |
| `text` | A widget whose displayed text equals the string, read the way `getText` reads it: a `Text`, including a `Text.rich` by its spans' plain text, a `RichText`, or a text field's contents. |
| `tooltip` | A `Tooltip` whose `message` equals the string. |
| `type` | A widget whose runtime type name equals the string, for example `ElevatedButton`. |
| `semanticsLabel` | A widget whose semantics label equals the string. |

Zero selectors or more than one is an error. Other params: `durationMs` (longPress, drag, scrollIntoView), `dx` and `dy` (drag, scrollIntoView), `scrollableKey` (scrollIntoView, `ValueKey` only), `timeoutMs`, `settle`, `requireHit`.

Put the `Key` on the widget you would point at, such as the `Chip`, the `ListTile`, or the button, rather than on the `Text` it builds. A selector reaches the same distance for every method.

- **`getText`** returns the text of the first text-bearing descendant of the match, in pre-order (`Text` including `Text.rich`, `RichText`, `EditableText`), and lists all of them in `texts`, so a container with two strings shows as two: `{"text":"Increment","texts":["Increment"]}`.
- **`enterText`** takes `text` as the string to type, which is why it is the one method that does not accept the `text` selector. With a selector it focuses the first `EditableText` under the match and types into it, with no preceding tap needed, and reports what it typed into: `{"enteredText":"hi","into":"ValueKey(emailField)"}`. With no selector it types into whatever is focused, reporting `"into":"focused"`.

**Settling.** After dispatching input, a method waits until the app is idle before returning, so a follow-up `getRect` or `getText` sees the post-action layout. The wait is bounded by `timeoutMs`, default 10000. Every input command's reply says how that wait ended, in `settled`: `yes`, `no`, or `skipped` (for `settle: "false"`, or an app that is backgrounded). These are the values `app.pressKey`'s browser route and the screenshot headers use. When it is not `yes`, `settleDetail` says why. A wait that runs out is `no` on an otherwise successful reply, not an error. The input was delivered before the wait began, so do not send the command again, or it taps twice. `settleDetail` gives the number of animations still running; zero means the app was backgrounded mid-command. An app that was already backgrounded returns immediately, because backgrounding is what stops frames, so there is nothing to wait for. On macOS a window that has been in front and is then hidden, or fully covered by another app's window, counts as backgrounded; one that was covered from the moment it opened keeps drawing, because the embedder reacts only to a change.

**A backgrounded app takes input, and shows nothing.** An app the OS has backgrounded stops producing frames: a locked screen on a device, or on macOS a window hidden or covered after it had been in front. Input still lands and its handler still runs, but nothing rebuilds, so a `getText` straight afterwards answers with the tree as it was and not with what your tap changed. Every input command says so in that state, with a `notRendering` field on an otherwise successful reply, and so do `app.getText`, `app.getRect`, `app.waitFor` and `app.waitForAbsent`. When one of those finds nothing, its error carries the same note. That matters most after a restart in that state, when the tree holds only what `runApp`'s first frame built, and a widget the app shows once its data loads is not there yet. On a locked Pixel this looked like a tap that did nothing; the value appears when the device is unlocked.

Some apps never go idle: a spinner, a progress indicator, any perpetual `AnimationController` keeps a frame callback pending for as long as it runs, so every command against such an app spends its whole timeout before answering `settled: "no"`. `settle: "false"` turns the wait off for one command, the equivalent of `flutter_driver`'s `runUnsynchronized`. What you give up is the guarantee: an immediate `getText` after an unsynchronised `tap` races the rebuild and reads the old value about half the time, so resynchronise with `app.waitFor` on the value you expect. `settle` accepts only `"true"` and `"false"`, because a typo would otherwise choose the opposite behaviour in silence.

**Reaching the widget.** Being in the tree is not the same as being where a pointer can land. A child of a scroll view that is scrolled off screen is laid out outside the viewport, and a widget behind a dialog is covered. A selector still finds it and it still has a rect, so `tap`, `longPress`, `doubleTap`, and `drag` hit-test the point first and refuse when nothing there resolves to the target. The refusal says which case it is and what to do: scroll it into view, or move what covers it. This is `WidgetController`'s `warnIfMissed` with the fatal choice made, on the view that a success response for an event nobody received is worse than an error. `requireHit: "false"` dispatches at the point anyway, for a caller who means it.

`app.scrollIntoView` is the way through, and its `reachable` field answers whether a tap would now land. `iterations` counts drag-scrolls of a lazy list; `0` means the target was already built and `Scrollable.ensureVisible` was used.

#### Pressing keys

`app.pressKey` presses one key, or one key with modifiers held, in whatever has focus:

```sh
curl -s -X POST "$URI/command?token=$T" \
  -d '{"method":"app.pressKey","params":{"appId":"'$APP'","key":"Control+K"}}'
```

Keys are named the way Playwright's `keyboard.press` names them, since that is what agents already know: a character (`a`, `A`, `!`), a `KeyboardEvent` key or code (`Enter`, `Tab`, `Backspace`, `ArrowDown`, `Escape`, `KeyA`, `Digit1`, `Space`), and modifiers joined with `+` (`Control+K`, `Shift+Tab`, `Meta+A`). `ControlOrMeta` is Meta on Apple platforms and Control elsewhere. An unknown name is refused by name, with the spelling it probably meant: `Ctrl` gets "did you mean `Control`". Two Playwright details carry over: a single character is case-sensitive, and `Shift+a` types `a`, so write `A` or `Shift+KeyA` for a capital. One difference: only modifiers can be held, so `a+b` is refused. Send one command per key.

It takes no selector. Focus the field first, with `app.tap` on it or by pressing `Tab`.

How the key reaches the app depends on the device, and the reply names the route in `route`:

| `route` | Devices | What happens | What it reaches |
|---|---|---|---|
| `browser` | Chrome: the DDC dev loop, `--wasm`, `--profile` | Real, trusted input sent to the app's page over the DevTools protocol (`Input.dispatchKeyEvent`). | What a keyboard reaches in that browser: the browser's own text editing, and the key events Flutter's web engine sees. |
| `framework` | macOS, iOS, Android, Linux, Windows | Simulated inside the app, modeled on `flutter_test`'s key simulator: each key as a `ui.KeyData` plus the legacy `flutter/keyevent` message the engine sends. A key the framework leaves unhandled then goes where the platform's input method would take it: typed text into the focused field, Return to the field's action (which is what fires `onSubmitted`), and on macOS the Cocoa editing selectors AppKit would produce, sent as `TextInputClient.performSelectors`. | Shortcuts, focus traversal and text editing. Not the OS and not its input method: IMEs, dead keys, system shortcuts and OS key remapping are never involved. |

A pass on the framework route is not evidence about OS-level input, which is why every reply says which route ran.

The reply also says what was sent:

- **browser:** `sent` is the CDP events, in order. `focus` is what had the browser's focus, as tag names through shadow roots; a focused Flutter text field reads `flutter-view > input`. When the key types text and the focus is not in a text field, `warning` says the text reached nothing.
- **framework:** `sent` lists each key event and whether the framework handled it, `handled` is the answer for the main key, and `textInput` is what went to the field: `{"inserted":"a"}`, `{"selectors":["moveDown:"]}`, `{"action":"TextInputAction.done"}`, or `{"skipped":"<why>"}`. On desktop, a key pressed while the app's window is not the focused one, because another app is in front or after `app.setWindowActive` with `"false"`, first makes the app active, as a real key press would find it: the framework had taken focus off the field while the window was inactive, and gets it back. `activated` says this happened. The real window stays where it is.

```json
{"route":"framework","key":"ArrowDown","handled":false,
 "sent":[{"type":"down","key":"Arrow Down","handled":false},{"type":"up","key":"Arrow Down"}],
 "textInput":{"selectors":["moveDown:"]}}
```

**Mac editing keys in a browser.** On a Mac, a browser edits text through the Cocoa command AppKit attaches to a key, and CDP input enters below AppKit. So the browser route attaches the command a Mac would, from Playwright's `macEditingCommands` table. We measured the difference on a Flutter web text field: `Control+K` deletes to the end of the line only when it carries `deleteToEndOfParagraph`, while Backspace, the arrow keys and Enter worked with or without their commands. Enter carries `insertNewline` anyway, and in a textarea it inserted exactly one newline either way.

**Waiting.** Both routes wait for the app to go idle before answering, with the same `timeoutMs` and `settle` as the other input commands, and report how the wait ended in `settled` and `settleDetail`: `yes`, `no` or `skipped`, the values the screenshot headers use. The browser route can ask only on the DDC dev loop. The keys were delivered in every case. A `--wasm` or `--profile` run has no VM service to ask, so it answers `skipped`; take a screenshot to see what the key did. A page in a hidden, minimized or covered window draws no frames, so the key's effect does not show until the page is visible again. The reply says `no` with that reason, and `--web-run-headless` avoids the problem.

#### Reload and restart responses

A reload or restart that landed in an app that is not drawing says so. The app is running the new code, so `succeeded` is `true`, and `notShown` says, per app, why the screen does not show it yet:

```json
{"succeeded":true,"runningCode":"updated",
 "notShown":{"<appId>":"the app is not drawing, because the OS reports it cannot be seen (lifecycle state \"hidden\": …). It shows the change once it can be seen again"},
 "message":"Restart successful, but the app is not drawing, because the OS reports it cannot be seen …"}
```

The reply comes as soon as the app has built its first frame and said it cannot draw, rather than after the ten seconds the tool gives a frame to arrive. On the macOS plugin example, restarts into a window hidden after it had been in front took 11.3 s before this and 1.4 s after. An app that neither draws nor says why, such as one attached to without the rules' agent extensions, still gets the ten seconds, and `notShown` then says only that no frame came.

A restart that relaunched the process because a native library changed says so:

```json
{"succeeded":true,"runningCode":"updated","relaunched":true,
 "nativeLibsChanged":["…/libmul.dylib"],"launch":{"<appId>":2},"ready":true,
 "message":"Restart successful — the app was relaunched because its native libraries changed (…). …"}
```

`ready` says the relaunched app rendered a first frame before the response returned, so its extensions are registered and the next `app.*` call will land. `false` means that wait timed out, not that the app is broken. The protocol stream re-emits `app.debugPort` and `app.started` for the new process.

A reload after a native rebuild, with the bindings unchanged, delivers the edit and reports the stale library:

```json
{"succeeded":true,"runningCode":"updated",
 "nativeLibsStale":["…/libbridge.dylib"],
 "message":"Hot reload successful. …/libbridge.dylib was rebuilt and its bindings did not change, so the increment is live over the library the app already loaded — the new native code is not running. A restart (R) relaunches the app on it."}
```

With the bindings changed, or nothing declaring them, the edit is withheld:

```json
{"succeeded":false,"runningCode":"unchanged",
 "nativeLibsStale":["…/libbridge.dylib"],
 "message":"Hot reload withheld: …/libbridge.dylib changed, and so did what its bindings are generated from …"}
```

Nothing is compiled and nothing is sent, so the app keeps the code and the library it launched with, and `app.restart` picks up the new one. `nativeLibsStale` means the same thing in both replies, and `succeeded` says whether the edit landed. The check costs no Bazel of its own: a `stat` per declared file, and a content hash only for a file the build rewrote.

A reload that patched native code into the app says what it patched, and `nativeReverted` lists libraries sent back to their launched code:

```json
{"succeeded":true,"runningCode":"updated",
 "nativePatched":{"libmul.dylib":["mul_body"]},
 "message":"Hot reload successful. Patched libmul.dylib in the running app (mul_body)"}
```

A patch that cannot be delivered withholds the reload with the patch builder's reasons in `nativePatchRestart`, and one that did not load names the apps in `nativePatchFailed` and `nativePatchApplied`.

#### How a command says no

Every failure, on either transport, is a top-level `error` carrying the reason. Over HTTP the status says which kind: `404` the command or app does not exist here, `400` the request was malformed (a missing parameter, two selectors), `501` this run cannot serve it (an engine screenshot under Impeller), `422` it was asked properly and could not be done (the app refused, or never answered). A `500` means the tool itself broke, which is the one case worth retrying or reporting. On the stdin protocol the same failure is upstream's `{"id":…, "error":"<reason>"}`.

An outcome that carries its own verdict stays inside `result`. A hot reload that ran and failed answers `{"succeeded":false, "error":…}`, because it ran and reported a failure rather than refusing to run.

### Working with a coding agent

The control channel is what lets a coding agent such as Claude Code check its own work: it can reload the app after an edit, read text back, and look at a screenshot rather than guessing from the code. Three choices make that work well.

**Start the app in machine mode, in the background.** The run lives for the whole session, so start it once and send its output to files. `--machine` keeps stdout to protocol events, `LOG_FORMAT=json` makes the channel record on stderr one parseable line, and `--no-devtools` avoids opening a browser tab nobody will look at. On the web, add `--web-run-headless`.

```sh
LOG_FORMAT=json fl run -t //:my_app_macos -d macos --machine --no-devtools \
  > /tmp/app.out 2> /tmp/app.err &
```

The agent reads the URL and token from the `http_control_channel` line in the stderr file, and waits for `app.started` in the stdout file before sending commands.

**Choose a watch strategy.** In terminal mode the tool reloads on every save. In machine mode watching is off by default, and that is the better setting for an agent. An agent edits several files in a row, and a reload after each save would compile half-finished changes. Have the agent call `app.hotReload` itself when it is done editing. The reply says whether the reload landed and which files were recompiled, which is exactly the evidence the agent should be reporting. If the agent needs watch mode anyway, pass `--watch` and have it call `app.settle` before reading anything back.

**Ask for screenshots before and after every change.** An agent that edits code without looking at the result will happily report success on a blank screen. Put the rule in the file your agent reads at startup, such as `CLAUDE.md` or `AGENTS.md`:

```markdown
## Running the app

Start the app once per session, in the background, and keep it running:

    LOG_FORMAT=json fl run -t //:my_app_macos -d macos --machine --no-devtools \
      > /tmp/app.out 2> /tmp/app.err &

The control channel URL and token are on the `http_control_channel` line of
/tmp/app.err. Wait for an `app.started` event in /tmp/app.out before driving
the app. The `appId` is in that event.

## Every code change

1. Before editing, save a screenshot: GET /sessions/<appId>/screenshot/native.
2. Edit, then reload: POST /command with
   {"method":"app.hotReload","params":{"appId":"<appId>"}}.
   Use app.restart instead when the change touches main() or startup code.
   Read `succeeded` from the reply. A reload that fails is not done.
3. After the reload, save a second screenshot and compare it with the first.
   Say in your report what changed on screen, not just what changed in code.
   A reply with `notShown`, or a read with `notRendering`, means the window
   is hidden or covered: bring it to the front before trusting the screen.
4. Check GET /sessions/<appId>/logs for exceptions before moving on.

Stop the app with daemon.shutdown at the end of the session.
```

Adjust the target and device to your project. With the long form of the command in place of `fl`, this works without bazel_env. The screenshot endpoint waits for the app to settle, so a capture taken straight after a tap or a reload shows the result; see [Screenshots](#screenshots).

## Examples

The `e2e/` directory holds working workspaces, each with its own tests:

| Directory | What it shows |
|---|---|
| `e2e/smoke` | The smallest possible toolchain check. |
| `e2e/hello_world` | A minimal app on every platform: kernel, AOT, assets, macOS, iOS, Android, Linux, Windows, and web. |
| `e2e/codegen` | Per-file and aggregate code generation, generated code in dependency packages, and hot reload over generated sources. |
| `e2e/ffi_example` | Native code as Dart Native Assets and as `native_deps`, side by side. |
| `e2e/ffi_plugin_example` | A `flutter_plugin` with a Dart plugin class and `native_deps`. |
| `e2e/plugin_example` | Pub plugins from the hub, and a `flutter_plugin` with a Dart plugin class only. |
| `e2e/macos_example` | A full macOS app with bundle structure checks. |
| `e2e/ios_example` | An iOS app. Requires Xcode. |
| `e2e/android_example` | An Android APK built three ways, with APK content checks. |
| `e2e/linux_example` | A Linux app built three ways, with bundle checks. |
| `e2e/windows_example` | A Windows app built three ways, with bundle checks. |
| `e2e/web_example` | WASM and JavaScript web builds with `web_assets`. |
| `e2e/integration_web` | End-to-end web `flutter_integration_test` running in hermetic `chrome-headless-shell`. |
| `e2e/integration_linux` | End-to-end Linux desktop `flutter_integration_test` with a native C++ plugin running under hermetic `Xvfb` and Mesa `llvmpipe`. |
| `e2e/integration_android` | End-to-end Android `flutter_integration_test` with a Kotlin method-channel plugin running in a hermetic headless Android emulator with KVM. |
| `e2e/cross_compile_example` | A Linux bundle cross-compiled from macOS. |
| `e2e/multi_window_example` | Multi-window macOS and multi-scene iOS with `FlutterEngineGroup`. |
| `e2e/dual_hub` | Two pub hubs in one workspace that disagree on a package version. |

[docs/TESTING.md](docs/TESTING.md) describes how the repository itself is tested, including the manual checks that need a display or a device.

## License

See [LICENSE](LICENSE).
