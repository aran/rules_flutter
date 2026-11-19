# rules_flutter

Bazel rules for building Flutter apps.

> **Status: beta.** It works today, but the public API may still change. Feedback and contributions are welcome.

rules_flutter compiles Dart to kernel or AOT native code, bundles assets, and packages the result for macOS, iOS, Android, Linux, Windows, and the web. It builds on [rules_dart](https://github.com/aran/rules_dart) for Dart compilation and hands platform packaging to the rulesets that already do it well: `rules_apple`, `rules_android`, and friends. It also ships a dev tool, `flutter_bazel`, that gives you hot reload, hot restart, and an HTTP channel for driving a running app from an AI agent or script. It also supports [frustrate](https://github.com/aran/frustrate), which allows Rust code to be used in apps built with rules_flutter.

## Migrating from 0.1.0

1. Bazel 9.3 or newer.
2. Flutter 3.50.0 or later. rules_flutter asks for 3.50.0, and 3.47 is no
   longer supported: `flutter.toolchain(flutter_version = "3.47.9")` fails.
   Raise the pin and regenerate `pubspec.lock` with the new Flutter (see
   [Regenerating pubspec.lock](#regenerating-pubspeclock)). A framework of
   your own must be 3.50 or later too. `package:flutter/material.dart` and
   `cupertino.dart` still work; to move to the `material_ui` and
   `cupertino_ui` packages, as `flutter create` now writes an app, add the
   package to `pubspec.yaml` and its `@deps` target to `deps` (see
   [Your first app](#your-first-app)).
3. Custom SDKs: `flutter.toolchain` takes only a release, and its
   `framework`, `engine` and `material_fonts_sha256` are removed. Each form
   of custom SDK has a tag of its own, which requires the attributes that
   form needs:
   - `framework` and `engine` → `flutter.custom_sdk(name, framework, engine, hosts)`,
     where `hosts` names the machines the engine serves (`["host"]` for
     `flutter_local_engine`).
     For a flutter/flutter checkout and the engine built in it,
     `flutter.checkout(name)` replaces both repositories and reads the
     engine from `$FLUTTER_CHECKOUT/engine/src/out`, never from
     `FLUTTER_ENGINE`.
   - `engine` with `flutter_version` →
     `flutter.custom_engine(name, engine, hosts, flutter_version)`.
   - `framework` with `flutter_version` →
     `flutter.custom_framework(name, framework, flutter_version)`.
   - `material_fonts_sha256` → the same attribute on `flutter.custom_sdk`,
     `flutter.custom_framework` or `flutter.checkout`.

   A custom SDK can't be named `flutter`, the release every module may ask
   a version of. To build with one by default, give it another name and
   choose it with `flutter.use_sdk(name = "<name>")` in `MODULE.bazel`,
   which replaces setting `--@rules_flutter//flutter:sdk=<name>` in
   `.bazelrc`; the flag still overrides it. The flag's default is now empty,
   meaning that choice, so a `config_setting` matching the flag to `flutter`
   no longer matches a build that does not set it. See
   [Custom engines and frameworks](#custom-engines-and-frameworks).
4. Every file in the `srcs` of a `flutter_application`,
   `flutter_application_variant` or `flutter_test` must be loaded from its
   `main`, through imports, exports and parts. A file it never loads fails
   the build, naming it: remove it from `srcs` or import it, and put a file
   read at run time in `data`. `bazel run @rules_dart//dart/unused_deps -- //...`
   lists them. `features = ["-dart_unused_deps"]` turns this check off,
   with the unused-deps check. See [Pub packages](#pub-packages).
5. Apple plugins that use remote Swift packages (the FlutterFire plugins'
   `firebase-ios-sdk`, say): your root module now declares those packages,
   and rules_flutter declares none. Run `bazel run @<hub>//swift:packages`
   and add what it prints: a `Package.swift` at the workspace root listing
   the packages, rules_swift_package_manager's `swift_deps.from_package` and
   `use_repo` in `MODULE.bazel`, and `inject_repo(flutter_pub, ...)` naming
   the packages' repositories. Keep `swift_package_resolved` on
   `flutter_pub.from_lock`, naming the same `Package.resolved`, and re-pin it
   with `bazel run @swift_package//:update`. A pin that a plugin's
   `Package.swift` doesn't accept fails the build. `bazel run @<hub>//swift:resolve`
   is removed. Firebase with explicit Clang modules also needs the target
   modifications in [Explicit Clang modules on macOS and iOS](#explicit-clang-modules-on-macos-and-ios).
   See [Swift packages a plugin depends on](#swift-packages-a-plugin-depends-on).
6. Signed iOS apps get the entitlements Xcode gives them (see `entitlements`
   under [iOS](#ios)), no longer all their provisioning profile grants:
   - An app with no entitlements file was signed with everything its profile
     grants. A grant it used only that way, such as push
     (`aps-environment`), associated domains or an App Group, now has to be
     in its entitlements file.
   - Without `keychain-access-groups` of its own, an app with no entitlements
     file, or one signed with a wildcard profile, saved keychain items to the
     group `<TEAM>.*` by default; it now saves them to
     `<TEAM>.<bundle id>`. To keep reading the old items, list
     `$(AppIdentifierPrefix)*` under `keychain-access-groups` in its
     entitlements.

   A macOS app with a `provisioning_profile` is also signed as Xcode signs
   it, which adds `com.apple.application-identifier`, the team identifier
   and, with a development profile, `com.apple.security.get-task-allow` to
   its own entitlements (see `entitlements` under [macOS](#macos)).
7. Split debug info is named as `flutter build --split-debug-info` names it:
   `<application>.symbols` → `<application>_symbols/app.<platform>-<arch>.symbols`,
   such as `app.ios-arm64.symbols`. Update a script that uploads it.
8. Rule authors:
   - `const_finder` is removed from `flutter_host_tools`,
     `FlutterHostToolsInfo` and `FlutterSdkInfo`. Icon tree shaking reads the
     icons the compiler records instead.
   - Each native library is described in one record. `FlutterInfo`'s
     `transitive_native_libs`, `native_lib_sources` and `binding_contracts`
     are replaced by `FlutterInfo.native_libraries`, and
     `FlutterApplicationInfo.native_libs` by
     `FlutterApplicationInfo.native_libraries`. Where you read a File from
     the old fields, read a record's `library`. Its `sources` and `contract`
     are what `native_lib_sources` and `binding_contracts` held for it. New
     fields: `package`, the Dart package whose `native_deps` brought it;
     `link_inputs`, what it was linked from; `dsym`, the dSYM its link made;
     and `link_inputs_unset_reason`, why the build can't see either. See
     [Providers](#providers).
9. With `--apple_generate_dsym`, an Apple app makes a dSYM of each native
   library it bundles, read from what the library was linked from, and fails
   when the build can't see that: a library a genrule writes, or a code asset
   whose `file` is a rule other than a `filegroup` that passes on a library
   another target links. Name the target that links the library instead, or
   have the rule that provides it return rules_dart's `DartLinkInputsInfo`
   (empty `inputs` for a library linked outside the build). A
   `rust_shared_library` gets the dSYM rustc makes on macOS, and on iOS one
   that holds its symbol table. See [dSYMs on iOS and macOS](#build-modes).
10. Engine sources: the `sky_engine` package is the selected SDK's engine's,
    for analysis and `NOTICES` alike. An engine source of your own must give
    `//sky_engine:sky_engine`, a `dart_library` of the package with
    `package_name = "sky_engine"`, and `//sky_engine:LICENSE`, beside its
    `//sky_engine:pubspec.yaml` (see
    [Writing an engine source](#writing-an-engine-source)). `flutter_local_engine`
    and `flutter.checkout` give them.
11. Android apps wired by hand: `flutter_android_plugin_libs` takes its
    application as a one-element list, `deps = [":app"]`, in place of the
    single label `deps = ":app"`. `flutter_android_app` and `flutter_android_aar`
    pass it for you.
12. Federated plugins: an application registers and links one
    implementation of each plugin on each platform, chosen as `flutter build`
    chooses it, where it used to register every implementation that reached
    it. An app that reaches two implementations of one plugin on a platform,
    neither of them in its `deps` and neither the plugin's `default_package`,
    now fails analysis with `Plugin <name>:<platform> has multiple possible
    implementations`: add the one you want to the application's `deps`. Two
    in its `deps` fail with `conflicting direct dependency implementations`:
    keep one. The native code of an implementation it does not choose is no
    longer bundled. See [flutter_plugin](#flutter_plugin).
13. A macOS app ships each code asset in a framework of its own, as
    `flutter build macos` does: `libfoo.dylib` is
    `Contents/Frameworks/foo.framework/foo`, under the install name
    `@rpath/foo.framework/foo`, with its dSYM `foo.framework.dSYM`, and so is
    a code asset's xcframework in macOS add-to-app (`foo.xcframework`, a
    framework now). `@Native` bindings find it as before. Code that opens a
    code asset's library by its file name, `DynamicLibrary.open('libfoo.dylib')`,
    opens `@rpath/foo.framework/foo` instead. A `native_deps` library still
    ships as itself.

## Road to 1.0

This project is getting dangerously close to being good. It's still a beta, but
we're approaching parity with the native tools, getting good performance, and
successfully using it to build Flutter apps across several platforms. There have
been several PRs and forks. Of course, the process of using AI to build software
like this is more like sculpting than careful assembly. Here, the form is taking
shape. In the latest round of changes, we made as many breaking changes as we
could, in the hopes of reducing how many breaking changes will need to be made
going forward. I'm still not committed to avoiding breaking changes, but I think
it's fair to discuss what it'll take to ship a 1.0 where there will be an
expectation that APIs will remain stable for quite some time.

As context, there are varying degrees of success possible for this project, and
I don't know where it will land. One possibility is that it remains small, used
by myself and a couple of others for small-scale, largely non-professional
projects. In this world, I'll label it 1.0 as a retroactive, descriptive
process. That is, when a few months go by where development has been happening
but the APIs have remained stable, we'll assume that they can probably be kept
stable for some time going forward, and we'll label it 1.0. This is probably the
most likely outcome.

Somewhere else in the range of possibilities, this project could get picked up
for professional use by others. It could even attract attention, and we could
end up with actual collaboration with teams within Google and others in the
Flutter and Bazel ecosystem. In an optimistic case, two or three profitable
companies start using it in production, and Google is potentially even tacitly
supportive of it, or at least not hostile to it. In this scenario, the road to
1.0 will be a little more formal and aligned with the interests and
contributions of those companies. In that scenario, we'll probably see a formal,
published release cycle, likely tied closely to Dart, Flutter and Bazel release
cycles. 1.0 will be tagged with a consensus of the early production users.

Now, of course, everything can change quickly in this world. Google could change
the way it supports Flutter or Bazel. Dart 4 is on its way and may engender
changes to projects like these. Everyone's expectations should be set
accordingly. I welcome discussions of this direction by email or in
[GitHub issues](https://github.com/aran/rules_flutter/issues), and of course, if
you are using or considering using this project professionally, please contact
me so we can collaborate.

## Why build Flutter with Bazel

- **Industrial-strength builds.** No stale caches, no `build_runner clean`, no "works on my machine." Bazel builds some of the largest codebases in the world, and serious bugs in it are rare. Every result is cached by its exact inputs, so a rebuild either reuses a correct result or redoes the work, and a teammate's machine or CI gets the same answer yours did.
- **Remote execution.** Builds, static analysis and test work can run remotely. You can hand Dart and Flutter builds and tests to big machines in the cloud. See [Remote execution](#remote-execution).
- **Hermetic builds.** rules_flutter downloads Flutter, its engines, your pub packages and, if you ask, the Android SDK and NDK, each at a pinned version with a recorded checksum. Your `pubspec.lock` pins the packages, and the Flutter version you name pins the rest. Bazel tracks every file a step reads. Two machines with the same Xcode or MSVC get the same build, whatever else they have installed.
- **Code generation without build_runner.** Each generator is a Bazel target that runs per file, in parallel and cached, instead of one whole-package `build_runner` pass. Shims come bundled for json_serializable, freezed, built_value, mockito, copy_with_extension_gen, stacked, drift and go_router_builder. See [Code generation](#code-generation).
- **Native code built by Bazel.** Native code comes from ordinary targets instead of a package's build hook, so it's cross-compiled, cached and remote-executable like everything else. You don't write CMake, Gradle or CocoaPods files.
- **One build graph.** Flutter apps, backend services, Rust and C++ libraries and the rest of your repository build together, and Bazel knows what depends on what.
- **AI-friendly tooling.** The dev tool is built from the ground up for Claude Code or other AI agents to develop your app quickly. This includes a custom protocol for machine use, full screenshot support, and tools to let your agent navigate your app in a fast and token-efficient way.

## Contents

- [Getting started](#getting-started)
- [Dependencies](#dependencies): pub packages, build and link hooks, native code
- [Building for each platform](#building-for-each-platform): macOS, iOS, Android, Linux, Windows, web, cross-compiling, release permissions, add-to-app
- [Custom engines and frameworks](#custom-engines-and-frameworks): a local flutter/flutter checkout and its engine, provenance, writing an engine source
- [Rules reference](#rules-reference): libraries, applications, tests, integration tests, plugins, code generation, providers
- [The dev tool](#the-dev-tool): running apps, hot reload, driving an app from a script
- [Examples](#examples)

## Getting started

### Requirements

You need Bazel 9.3 or newer. rules_flutter downloads Flutter itself, so you don't install Flutter, and this release builds with Flutter 3.50.0.

What else you need depends on what you build for:

| Building for | What you need |
|---|---|
| macOS | Xcode. |
| iOS | A Mac with Apple silicon, and Xcode. iOS builds are arm64 only, so an Intel Mac can't run the simulator builds. A simulator needs no signing identity; a physical device does (see [Running on an iOS device](#running-on-an-ios-device)). Screenshots from `flutter_bazel` need Xcode 27 or later. |
| Android | Nothing installed. [Android](#android) shows the `MODULE.bazel` lines that download the SDK and NDK. An SDK and NDK you have installed, at `ANDROID_HOME` and `ANDROID_NDK_HOME`, also work. |
| Linux | A C++ toolchain. GTK comes with rules_flutter. From a Mac you need an LLVM cross-toolchain, and you can only make debug builds. |
| Windows | MSVC. From a Mac or Linux you need a C++ cross-toolchain, and you can only make debug builds. |
| Web | Nothing extra to build. `flutter_bazel run -d chrome` uses the Chrome you have installed, or the one `CHROME_EXECUTABLE` names. |

### MODULE.bazel

```starlark
bazel_dep(name = "rules_flutter", version = "<latest from registry.bazel.build/modules/rules_flutter>")

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(flutter_version = "3.50.0")

flutter_pub = use_extension("@rules_flutter//flutter/pub:extensions.bzl", "pub")
flutter_pub.from_lock(
    name = "deps",
    lock = "//:pubspec.lock",
)
use_repo(flutter_pub, "deps")
```

`flutter.toolchain` pins the Flutter release you build with. Your pin is used exactly. rules_flutter itself asks for 3.50.0, and a module never gets an older Flutter than it asks for, so a lower pin fails and names the module that wants more. You can raise your pin, or set `allow_upgrade_by_dependencies = True` to build with the highest version any module asks for. If you leave `flutter.toolchain` out, that highest version is what you get.

`flutter_pub.from_lock` turns your `pubspec.lock` into a repository, here named `deps`, with one target per package: `@deps//:flutter`, `@deps//:flutter_test`, `@deps//:collection`. [Pub packages](#pub-packages) covers it in full. It is a separate extension from `flutter` so that if it rejects your lock, the toolchain still works, and so does `bazel run @rules_flutter//flutter/pub`, which regenerates the lock.

You may also want rules_dart, which rules_flutter builds on:

```starlark
bazel_dep(name = "rules_dart", version = "<the version rules_flutter's MODULE.bazel names>")
```

`dart_package_metadata` comes from rules_flutter, so a plain app doesn't need it. You do need it as soon as a BUILD file or `.bazelrc` names `@rules_dart` directly: to load `dart_library` or `dart_analysis_options`, or to set a flag such as `--@rules_dart//dart:split_debug_info`. Use at least the version rules_flutter depends on.

### .bazelrc

Building for macOS, iOS, Linux, Windows or the web needs no settings.

An Android build runs Java tools from rules_android and rules_jvm_external, which are compiled for Java 21 or newer. Bazel's default tool JDK is older, and it uses whatever JDK is installed locally to run the app's Java. Add these three lines:

```bazelrc
common --tool_java_language_version=25
common --tool_java_runtime_version=remotejdk_25
common --java_runtime_version=remotejdk_25
```

Without the first two, an action fails with `UnsupportedClassVersionError`, or a compile fails with `could not locate class file for java.lang.Record`. Without the third, a machine with no JDK installed fails every Android build during analysis with `Cannot find Java binary bin/java in .../local_jdk/nosystemjdk`.

One more setting is recommended, on macOS and Linux:

```bazelrc
common --enable_platform_specific_config
common:linux --experimental_output_paths=strip
common:macos --experimental_output_paths=strip
```

A Flutter build often does the same work in several configurations. Each Android ABI compiles the same release kernel and bundles the same assets, and `-c dbg` and `-c fastbuild` run the same code generation. Bazel normally keys an action by its output paths, which include the configuration, so each copy runs again. With this flag, Bazel rewrites `bazel-out/<config>/bin` to `bazel-out/cfg/bin` in the command line of every action that declares it can take it, and the second copy is a cache hit. Outputs still land in their own configuration's directory, so nothing that reads `bazel-out` changes.

Most of rules_flutter's actions declare it. One that does still won't share in two cases:

- It runs without a sandbox: a `local` or `no-sandbox` action, or any action on Windows. Windows has no sandbox, and there Bazel fails a path-mapped action with `requires sandboxing due to path mapping` rather than run it, which is why the lines above leave Windows out.
- It is a debug build's kernel. The kernel records the path of the app's `flutter_assets/`, which is how `flutter_bazel` tells an app's configurations apart.

#### Explicit Clang modules on macOS and iOS

For macOS and iOS apps, explicit Clang modules are recommended:

```bazelrc
common --features=swift.emit_c_module --host_features=swift.emit_c_module
common --features=swift.use_c_modules --host_features=swift.use_c_modules
```

Without them, rules_swift's compile worker builds the Clang modules a Swift compile imports (the SDK's, the engine's `FlutterMacOS` or `Flutter`, each plugin's) into one cache per configuration, `bazel-out/<config>/bin/_swift_module_cache`. No action declares that directory, so Bazel neither tracks nor clears it. After an engine repository is fetched again, a runner that imports a plugin's Clang module can fail with `module 'FlutterMacOS' is defined in both`. Deleting that directory makes the next build build every module again. With the lines above, each Clang module is precompiled by an action of its own into a declared output that Bazel caches like any other, and no Swift compile builds modules on the side.

The first build precompiles the SDK's system modules, a few hundred actions that took 15 to 20 seconds on a 16-core Mac, and later builds take them from the cache. After that, rebuilding a changed Swift module takes as long as it does without the lines.

Xcode 27.2's SDKs include private modules whose Swift interfaces do not compile, `MobileGestaltPrivate` and, in the iOS simulator's SDK, `CoreAudio_Private`. Leave them out in `MODULE.bazel`, which needs a `bazel_dep` on rules_swift to name its extension:

```starlark
bazel_dep(name = "rules_swift", version = "4.2.2")

system_sdk = use_extension("@rules_swift//swift:extensions.bzl", "system_sdk")
system_sdk.configure_sdks(exclude_modules = {
    "MacOSX": ["MobileGestaltPrivate"],
    "iPhoneOS": ["MobileGestaltPrivate"],
    "iPhoneSimulator": [
        "CoreAudio_Private",
        "MobileGestaltPrivate",
    ],
})
```

rules_swift reads this only from the root module, and `exclude_modules` replaces its own list for each SDK named, which is why `CoreAudio_Private` is restated. A module an SDK lacks is skipped, so these lines do no harm under another Xcode.

Apps that link Firebase (`firebase_core` and the other FlutterFire plugins) need three lines more in `MODULE.bazel` to build with explicit modules. firebase-ios-sdk's `Package.swift` makes FirebaseCore depend on its `Firebase` umbrella target, so that `import Firebase` works for anyone who uses FirebaseCore, while the umbrella's header imports FirebaseCore. Precompiled with only its declared dependencies, the umbrella fails with `'FirebaseCore/FirebaseCore.h' file not found`. Your root module declares firebase-ios-sdk (see [Swift packages a plugin depends on](#swift-packages-a-plugin-depends-on)), and rules_swift_package_manager's target modifications, which it takes only from the root module, reverse that edge:

```starlark
# firebase-ios-sdk 13.1.1. The first restates FirebaseCore's other
# dependencies as its Package.swift declares them; check them on an upgrade.
swift_deps.bazel_target_set_string_list(
    attr = "deps",
    target = "@swiftpkg_firebase_ios_sdk//:FirebaseCore.rspm_objc",
    value = [
        "@swiftpkg_firebase_ios_sdk//:FirebaseCoreInternal.rspm",
        "@swiftpkg_googleutilities//:GULEnvironment",
        "@swiftpkg_googleutilities//:GULLogger",
    ],
)
swift_deps.bazel_target_add(
    attr = "deps",
    target = "@swiftpkg_firebase_ios_sdk//:Firebase.rspm_objc",
    values = [":FirebaseCore.rspm_objc"],
)
swift_deps.bazel_target_add(
    attr = "deps",
    target = "@swiftpkg_firebase_ios_sdk//:FirebaseCore.rspm.__impl",
    values = [":Firebase.rspm_objc"],
)
```

In Swift code of your own, import each Firebase product by name (`import FirebaseCore`, `import FirebaseAuth`), as Firebase's examples do. With explicit modules the umbrella is precompiled on its own, where it finds only FirebaseCore: `import Firebase` brings in FirebaseCore and nothing else.

### Your first app

Start from a project made with `flutter create`. You keep its `lib/`, its `pubspec.yaml` and `pubspec.lock`, and its platform folders. `flutter_macos_app` reads `macos/Runner/` as `flutter create` wrote it, and pub still reads `pubspec.yaml` when you regenerate the lock.

The build itself takes nothing from your `pubspec.yaml`. You state the same facts in a `BUILD.bazel` beside it. Here are the parts of a pubspec that matter to the build:

```yaml
# pubspec.yaml
name: my_app
version: 1.0.0+1

environment:
  sdk: ^3.13.0

dependencies:
  flutter:
    sdk: flutter
  material_ui: ^1.1.0

flutter:
  uses-material-design: true
  assets:
    - assets/
```

And the same app in Bazel:

```starlark
# BUILD.bazel
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_application")
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",                       # name:
    # Optional. The <major>.<minor> of environment: sdk:. Left out, your code
    # compiles at the SDK's own language version, which may be newer than
    # `flutter build` would allow.
    language_version = "3.13",
    # Optional. Listed on the app's licence page.
    license_file = "LICENSE",
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = [
        "@deps//:material_ui",                     # dependencies: material_ui
        "@rules_flutter//flutter:material_icons",  # uses-material-design: true
    ],
    # Optional. flutter: assets:
    assets = glob(["assets/**"]),
    # Optional. version: 1.0.0+1, which is also the default.
    build_name = "1.0.0",
    build_number = "1",
)

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.my_app",
    # Optional. The name in the menu bar and window title; defaults to the
    # target name.
    app_name = "My App",
)
```

`dart_package_metadata` is the Bazel stand-in for `pubspec.yaml`: one per package, and every target of the package points at it with `package`. Its `package_name` should match the pubspec's `name:`, because it is the name your `package:my_app/...` imports use and the name hot reload keys libraries by. Bazel doesn't compare the two, but Gazelle does if you use it to write BUILD files. The target's name is up to you. `pubspec-metadata` is the convention, and the name Gazelle gives it.

`flutter_application` compiles the Dart and bundles the assets. Each platform then has a macro, here `flutter_macos_app`, that wraps it in an app you can run. `deps` lists the packages your code imports, by their `@deps` targets, and only those: a package none of your files imports fails the build, unless the app uses it some other way (see [Pub packages](#pub-packages)). Since Flutter 3.50 the Material and Cupertino widgets are the pub packages `material_ui` and `cupertino_ui`, which `flutter create` imports in place of `package:flutter/material.dart`, so a fresh project's `lib/main.dart` imports `material_ui` and no `package:flutter` library: `@deps//:flutter` is a dependency only of code that imports one. `@rules_flutter//flutter:material_icons` is the Material icon font, which `uses-material-design: true` adds in a `flutter build`.

Without the optional lines, the BUILD file for a fresh `flutter create` project is:

```starlark
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_application")
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = [
        "@deps//:material_ui",
        "@rules_flutter//flutter:material_icons",
    ],
)

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.my_app",
)
```

A fresh project has no `assets/` folder, so leave `assets` out until it does: Bazel fails a `glob` that matches nothing.

Build it, or run it with hot reload:

```sh
bazel build //:my_app_macos
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_macos -d macos
```

[Shorter commands with bazel_env](#shorter-commands-with-bazel_env) turns the second one into `fl run -t //:my_app_macos -d macos`.

### Build modes

Bazel's `-c` flag picks the Flutter build mode:

| Flag | Flutter mode | Dart compiled to | Use it for |
|---|---|---|---|
| `-c dbg` | Debug | Kernel (`.dill`), run by the JIT | Development and hot reload |
| none (`fastbuild`) | Release | AOT native code, stripped | CI and tests |
| `-c opt` | Release | AOT native code, stripped, with native C and C++ libraries compiled optimized | Shipping |
| `-c opt --@rules_flutter//flutter:profile` | Profile | AOT native code, stripped, with the Dart VM service | Measuring performance with DevTools |

A plain `bazel build` is a release build. `flutter build` defaults to release too, but `flutter run` defaults to debug, so this may surprise you. It matters for [permissions](#release-builds-and-permissions), and it means the iOS simulator needs `-c dbg`. The simulator runs debug builds only, and a release or profile build for it fails with a message saying so. `flutter_bazel run` builds `-c dbg` for you.

**Profile mode** is what `flutter run --profile` gives you: release-speed code that still serves the Dart VM service, so DevTools can record timelines and CPU profiles. It has no hot reload. The flag needs `-c opt`, and the build fails with any other `-c`. Profile builds use their own engine and `gen_snapshot`, because the engine refuses a snapshot compiled for another mode. They are downloaded the first time a profile build needs them. A `.bazelrc` config saves typing:

```bazelrc
build:profile -c opt --@rules_flutter//flutter:profile
```

To check a profile build in `bazel test` without those flags on the command line, wrap the app in [`flutter_profile_build`](#flutter_profile_build).

**dSYMs on iOS and macOS.** A non-debug build strips the local symbols from `App.framework/App` and keeps them in a dSYM, as `flutter build ios` and `flutter build macos` do. The dSYM carries the binary's UUID, so a crash reporter can symbolicate the shipped app with it. Keep it with each release. It is in the app target's `dsyms` output group:

```sh
bazel build -c opt //:my_app_macos --output_groups=+dsyms
```

With `--apple_generate_dsym`, the group also holds the runner's dSYM and the engine's: `Flutter.framework.dSYM` on iOS, and on macOS `FlutterMacOS.framework.dSYM` in a release build, the one mode Flutter ships it for. Only that flag downloads the macOS engine's dSYM, which comes in a 165 MB archive.

The native libraries the app bundles beside its binary (a `native_deps` library, a code asset) are treated as rules_apple treats the runner's binary. With `--apple_generate_dsym` each has a dSYM in the group: `<name>.framework.dSYM` for one the app ships in a framework (on iOS each, on macOS each code asset), and `<library>.dylib.dSYM` for a `native_deps` library on macOS. With `--objc_enable_binary_stripping` in `-c opt`, each is shipped without its local symbols and debugging map. A library's dSYM is read from the object files and static archives it was linked from, as `flutter build` reads it, so a crash in it symbolicates to the file and line. That takes the library's debugging map, which the link keeps in `-c opt` and Bazel's default `--strip=sometimes` removes in `fastbuild`, where the dSYM holds the library's symbol table, as a prebuilt library's does: a crash in it symbolicates to the function. The build has to see the link: a `native_deps` entry or a `dart_code_asset` `file` that is the `cc_shared_library` (or `cc_binary`) linking the library, or a `copy_file` or `filegroup` of one in `native_deps`. A `rust_shared_library`, in `native_deps` or as a code asset's `file`, is linked by rustc from objects it deletes, so its dSYM is the one rustc writes beside it on macOS. It has line tables when rustc compiled with debug information, which rules_rust turns on in `-c dbg` only; pass `--@rules_rust//rust/settings:extra_rustc_flag=-Cdebuginfo=2` for them in `-c opt`. Without debug information, and on iOS, where rules_rust keeps no dSYM, the library's dSYM holds its symbol table. A library another action wrote, a genrule that renames or strips one say, fails a build with `--apple_generate_dsym`, saying why, unless the rule that provides it states what the library was linked from in rules_dart's `DartLinkInputsInfo`: empty `inputs` for a library linked outside the build, `gone = True` for one whose objects its link deleted, which then gets a dSYM of its symbol table.

`extra_gen_snapshot_options = ["--no-strip"]` on the `flutter_application` keeps the symbols in the binary, as it does for `flutter build`. The dSYM is still made. A `flutter_aot_snapshot` on its own isn't stripped, and its object file is in the `macho_object` output group.

**Obfuscation and split debug info** work as `flutter build --obfuscate --split-debug-info=<dir>` does, through two build flags that apply to every app in the build:

```sh
bazel build -c opt //:my_app_macos \
    --@rules_dart//dart:split_debug_info \
    --@rules_flutter//flutter:obfuscate \
    --output_groups=+debug_info
```

`--@rules_dart//dart:split_debug_info` leaves the Dart debug information out of the AOT snapshot and writes it to a `.symbols` file named as `flutter build --split-debug-info` names it: `app.ios-arm64.symbols`, `app.darwin-arm64.symbols`, `app.android-arm64.symbols`, `app.linux-x64.symbols`. The file is in the `debug_info` output group of the `flutter_application` and a `flutter_aot_snapshot`. An app's own target holds the files of the snapshots it ships, since it builds the application in configurations of its own and the application's file at the top level is another build's:

- `flutter_ios_app`, `flutter_macos_app`, `flutter_linux_app` and `flutter_windows_app` hold their one `.symbols`.
- `flutter_android_app`'s `app_bundle` holds one for each ABI it ships (`app.android-arm.symbols`, `app.android-arm64.symbols`, `app.android-x64.symbols`), as `flutter build appbundle --split-debug-info` writes them. So does `flutter_android_release`, for its release build.
- `flutter_android_aar` holds one for each ABI of the AAR.
- The APK itself, rules_android's `android_binary`, passes on no output group of rules_flutter's, so the `flutter_android_debug_info` aspect gives it one: one `.symbols` for each ABI in the APK, as `flutter build apk --split-debug-info` writes them, from the builds the APK packages, so nothing compiles again. It works on an `android_binary` assembled from the composable rules too:

  ```sh
  bazel build -c opt //:my_app_android \
      --@rules_dart//dart:split_debug_info \
      --@rules_flutter//flutter:obfuscate \
      --aspects=@rules_flutter//flutter:android.bzl%flutter_android_debug_info \
      --output_groups=+debug_info
  ```

A rules_dart `dart_binary` writes `<name>.symbols`. `--@rules_flutter//flutter:obfuscate` renames the Dart symbols. It needs `split_debug_info`, as `--obfuscate` needs `--split-debug-info`, and the build fails without it. A debug build ignores both.

The dSYM of an obfuscated app holds the original Dart names, and `gen_snapshot` warns about it. Don't ship it inside the app.

**What the dev tool needs in a debug build.** A native debug build compiles in what `flutter_bazel` needs to drive the running app: the service extensions behind its agent commands (see [Driving the app from a script](#driving-the-app-from-a-script)), its build and render-state queries and its uncaught-error reports, native hot patching, all registered before `main()`, and a `rules_flutter.build_info` define that describes the build to the tool. A debug build that no dev tool runs, such as a CI artifact or a device test, can leave all of it out, so its program is the app's alone:

```sh
bazel build -c dbg --@rules_flutter//flutter:dev_tool_support=false //:my_app_android
```

`flutter_bazel` turns it back on for every build it runs, so setting it in a `.bazelrc` doesn't break `flutter_bazel run`. Release and profile builds never have any of it. A web debug build keeps it whatever the setting, as the dev loop it is for serves the extensions through the page.

### Lints and static analysis

`bazel test` runs `dart analyze` and the `dart format` check once you turn on rules_dart's `dart_analyze` aspect. Without these lines nothing is analysed. They name `@rules_dart`, so add its `bazel_dep` too (see [MODULE.bazel](#modulebazel)).

```bazelrc
test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
test --output_groups=+dart_analyze
test --output_groups=+dart_format     # optional: the format check
common --@rules_dart//dart:analysis_config=//:analysis_config
```

The last line names a target that lists your `analysis_options.yaml` files. A lint package such as `flutter_lints` reaches the analyzer through the options target, not through any library's `deps`:

```starlark
# BUILD.bazel, beside analysis_options.yaml
# (which has `include: package:flutter_lints/flutter.yaml`)
load("@rules_dart//dart:defs.bzl", "dart_analysis_config", "dart_analysis_options")

dart_analysis_options(
    name = "options",
    src = "analysis_options.yaml",
    deps = ["@deps//:flutter_lints"],  # the package `include:` names
)

dart_analysis_config(
    name = "analysis_config",
    options = [":options"],
)
```

`bazel test //...` then fails on any analyzer finding, down to an info. [`e2e/macos_example`](e2e/macos_example/BUILD.bazel) is set up this way. `dart:ui` resolves without anything extra.

Each target is checked over its own files. For a library, that is its sources. For a `flutter_test`, `flutter_application` or `flutter_application_variant`, it is `main` and `srcs`, whether or not they are under `lib/`. An iOS, macOS, Linux, Windows or web app, and an integration test, check the program they run. An Android app (rules_android's `android_binary`) checks nothing, so its program is checked through its `flutter_application`. `//...` skips a target tagged `manual`; list it in a `dart_analysis_test(targets = [...])` to check it.

### Linking the engine from your own rules

You don't need this to build an app: the rules find the engine and web SDK repositories themselves. If a BUILD file of yours names one, add it to `use_repo(flutter, ...)`: `flutter_macos_engine`, `flutter_ios_engine` or `flutter_web_sdk`. Android has no such repository; each ABI's engine belongs to rules_flutter.

`@flutter_macos_engine//:engine_library` and `@flutter_ios_engine//:Flutter_xcframework` follow the build mode. They are the debug engine under `-c dbg`, the profile engine under `-c opt --@rules_flutter//flutter:profile`, and the release engine under any other `-c opt`. To pin one engine whatever the mode, use `engine_debug_library`, `engine_profile_library` or `engine_release_library` on macOS, and `Flutter_xcframework_debug`, `Flutter_xcframework_profile` or `Flutter_xcframework_release` on iOS. The Linux and Windows engines in the SDK repositories use the same names as macOS.

### Remote execution

Everything above builds on the machine running Bazel. To send actions to more than one kind of execution platform, such as a Linux remote worker alongside your Mac, add:

```bazelrc
# Start py_binary tools with their own hermetic interpreter. A remote worker
# has no python3 on PATH.
common --@@rules_python+//python/config_settings:bootstrap_impl=script
```

rules_flutter's actions run where the tools they need are:

- on a Mac: `gen_snapshot` for iOS and macOS, Xcode tools, and signing;
- on any host with the Flutter SDK: kernel compiles, asset and shader bundling, and web compiles;
- on the machine running Bazel: stripping the Android engine's, the app's and the plugins' native libraries, which needs the NDK that machine has.

An Android app needs Linux x86_64 workers. Google publishes the Android SDK's build tools, aapt2 among them, for Linux only on x86_64, so a Linux arm64 worker can't build one. It also needs a fix to rules_go: see [Fixes to other rulesets](#fixes-to-other-rulesets).

Use the downloaded SDK and NDK from the [Android](#android) setup when actions run remotely. They declare which host each of their toolchains runs on, so a worker gets tools for its own platform. An installed NDK (rules_android_ndk 0.1.5, `ANDROID_NDK_HOME`) has toolchains that match any execution platform, so a remote worker would be sent this machine's clang.

### Fixes to other rulesets

Some builds hit bugs in rulesets that rules_flutter depends on. Until a release of each ruleset fixes its bug, add the fix to your own `MODULE.bazel`: overrides only take effect in the root module, so rules_flutter can't apply them for you. Our e2e workspaces apply each one, so CI tests the fix you copy. Drop a fix once you depend on a release that has it.

| When you need it | What goes wrong | Fix | Upstream |
|---|---|---|---|
| An Android app that builds C/C++ code: its plugins' native code, `native_deps`, code assets | rules_android_ndk 0.1.5 links arm64 libraries for 4 KB pages, and the [16 KB check](#16-kb-memory-pages) fails the build | `git_override` rules_android_ndk to a commit with the fix, as [16 KB memory pages](#16-kb-memory-pages) shows | Fixed by [#121](https://github.com/bazelbuild/rules_android_ndk/pull/121); not yet released |
| A macOS app extension that runs App Intents | rules_apple 5.4.0's `macos_extension` has no `app_intents` attribute | `git_override` rules_apple to a commit with it, as [App extensions](#app-extensions) shows | Fixed by [#3112](https://github.com/bazelbuild/rules_apple/pull/3112); not yet released |
| An Android build on a Windows host | A few of rules_android's JVMs at once fail with `There is insufficient memory for the Java Runtime Environment to continue` | `rules_android_no_initial_heap.patch` | Not fixed. [#496](https://github.com/bazelbuild/rules_android/pull/496) would let you lower the starting heap per action |
| An Android build on a Windows host, of an app with about a hundred Android libraries (a few plugins bring that many) | Resource packaging fails with `CreateProcess error=206, The filename or extension is too long` | `rules_android_aapt2_command_length.patch` | Not fixed |
| An Android build with [remote execution](#remote-execution) | rules_android's Go tools, when built for the Mac, have a Linux worker run Mac-built `protoc` | `rules_go_go_proto_exec_group.patch` | Not fixed |
| An iOS or macOS app that links Firebase, with [explicit Clang modules](#explicit-clang-modules-on-macos-and-ios) | Precompiling firebase-ios-sdk's `Firebase` module fails with `'FirebaseCore/FirebaseCore.h' file not found` | Three `swift_deps` target modifications, as [Explicit Clang modules](#explicit-clang-modules-on-macos-and-ios) shows | Not fixed: rules_swift_package_manager builds the dependency as `Package.swift` declares it |

The patches are in [`e2e/android_example/patches/`](e2e/android_example/patches/). Apply each in a `single_version_override` of its module, as [`e2e/android_example/MODULE.bazel`](e2e/android_example/MODULE.bazel) does.

## Dependencies

### Pub packages

You add a package to `pubspec.yaml` as usual, and pub records it in `pubspec.lock`. `flutter_pub.from_lock` gives every package in the lock a target in the hub repository, here `@deps`. Your BUILD file names those targets in `deps`:

```yaml
# pubspec.yaml
dependencies:
  flutter:
    sdk: flutter
  collection: ^1.19.0
  url_launcher: ^6.3.0
```

```starlark
# BUILD.bazel
flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    deps = [
        "@deps//:flutter",
        "@deps//:collection",
        "@deps//:url_launcher",
        "@rules_flutter//flutter:material_icons",
    ],
)
```

The version comes from the lock, so the BUILD file doesn't repeat it. After editing `pubspec.yaml`, regenerate the lock (see [Regenerating pubspec.lock](#regenerating-pubspeclock)).

Each target's `deps` are checked against its files' imports, both ways. A file that imports a package missing from `deps` fails the build, and so does a package in `deps` that no file imports or exports:

```
//:my_app: no file imports or exports these deps:
  @deps//:collection
bazel run @rules_dart//dart/unused_deps -- //:all removes them. One used without an import is exempt when its rule returns DartUsedWithoutImportInfo; features = ["-dart_unused_deps"] turns the check off.
```

The command it names fixes them for you: `bazel run @rules_dart//dart/unused_deps -- //...` removes each unused entry as it is written in your BUILD files, editing a macro's call rather than the targets the macro makes. `--dry-run` shows what it would change, and it lists by file and line any entry it can't edit, such as one in a shared list.

The unneeded edge compiles nothing in, but every change to that package would rebuild everything above it, so usually you remove it. Two kinds of package are used without an import, and may be in `deps` anyway: a plugin, which the app registers from native code, and a package with fonts, assets or shaders, which the app loads by key, as it does `cupertino_icons`' font. A rule of your own whose targets are used that way says so by returning `DartUsedWithoutImportInfo` from `@rules_dart//dart:providers.bzl`. To keep any other package, turn the second check off with `features = ["-dart_unused_deps"]` on the target, in the BUILD file's `package()`, or with `--features=-dart_unused_deps` for the whole build.

A `flutter_application`, `flutter_application_variant` or `flutter_test` must also load every file in its `srcs`, through imports, exports and parts starting from `main`. A file it never loads would make what it imports count as used, though the program never loads that either, so the build fails, naming the file:

```
//:my_app_test: main never imports, exports or includes as a part these srcs, so the program never loads them, while what they import counts as used:
  test/other_support.dart
Remove them from srcs; a file read at run time belongs in data. features = ["-dart_unused_deps"] turns the check off.
```

Remove the file from `srcs`, or import it from a file `main` loads. A file the program reads at run time rather than compiles goes in `data`. `bazel run @rules_dart//dart/unused_deps` names such files and keeps the deps only they import, since it can't tell which of the two you mean. The files in a directory that a rule generates, and those of one `srcs` entry that supplies several (a code generator's outputs, say), are exempt, since a BUILD file can't drop them one by one. The same `features = ["-dart_unused_deps"]` turns this check off with the unused-deps one.

A plugin needs nothing extra. A pub package that is a Flutter plugin arrives as a plugin target, and the platform macros register it and build its native code. An Android app links the Kotlin and Java only of the plugins it depends on. A plugin that is in the lock but not in the app's dependencies adds no code, manifest entries or Maven requirements to the APK.

A plugin you write in your workspace joins the same way. List its Android library in the `flutter_plugin`'s `exports`, under a `select()` so that other platforms never load it:

```starlark
exports = select({
    "@platforms//os:android": [":lib"],
    "//conditions:default": [],
}),
```

The Flutter SDK packages a lock lists with `source: sdk`, such as `flutter_test`, `integration_test` and `flutter_driver`, build too. Name whichever ones your lock lists, as `@deps//:integration_test`. `package:flutter` has a rule of its own. The others are built from `packages/<name>` of the Flutter source the toolchain pins, a tarball checked against the digest recorded for that version. If the pinned release doesn't have a package the lock names, a build that uses the package fails, naming it and the command that re-resolves the lock. An SDK package's own pubspec must allow the version the build uses of each package it depends on (`flutter_test` holds `test_api` at exactly one version). The build uses one version of each package, the highest any lock records, so a lock that raises one past what the SDK the build uses allows fails the build at that SDK package, naming the lock and the command that re-resolves it against that SDK. Another SDK's packages are not checked until a build uses that SDK, and every SDK's repositories still fetch, so `bazel fetch --all` works with a lock that fits only one of them.

An SDK package's Android library links into the apps that depend on the package, like a plugin's. `integration_test`'s needs `androidx.test:runner`, `androidx.test:rules`, `androidx.test.espresso:espresso-core` and `com.google.guava:guava` in your `maven.install`. An app that doesn't depend on `integration_test` doesn't need them.

#### Git packages

A dependency with `git:` in `pubspec.yaml` is listed in `pubspec.lock` with `source: git`. It builds like a hosted package: a plain package, one with assets, or a plugin, as its own `pubspec.yaml` says. The lock is what pins the commit, so run `bazel run @rules_flutter//flutter/pub -- get` after changing the dependency, and commit the lock.

The hub fetches the commit the lock records (`resolved-ref`). It lays out the package's directory of the repository (`path:`, the repository root by default) as `dart pub get` does, so a package in a monorepo is only its own directory.

- A `resolved-ref` that isn't a full commit id is refused when Bazel reads the lock, naming the lock and the package. Run `pub get` to have pub write the commit it resolved.
- The fetch uses the `git` on your machine and its configuration, so credential helpers, `url.<base>.insteadOf` mirrors and proxies work as they do for `dart pub get`. A `git` older than 2.14 is refused.
- Writing the files out uses none of your configuration. The repository's own `.gitattributes` apply, but your line-ending and filter settings don't, so one commit gives the same files on every machine.
- You can map a git package to a target of your own with `resolve` (next section). It is then never fetched.

#### Packages in your workspace (`path:` dependencies, forks)

A `path:` dependency is a package whose files are in your repository, and `pubspec.lock` lists it with `source: path`. Usually you build those files with a target of your own, and `resolve` tells the hub which target builds which package:

```yaml
# apps/greeter/pubspec.yaml
dependencies:
  greeting:
    path: ../../packages/greeting
  tagline:
    path: ../../packages/tagline
```

```starlark
# MODULE.bazel
flutter_pub.from_lock(
    name = "deps",
    lock = "//apps/greeter:pubspec.lock",
    resolve = {
        "greeting": "//packages/greeting",              # //packages/greeting:greeting
        "tagline": "//packages/tagline:tagline_lib",
    },
)
```

[`e2e/pub_resolve`](e2e/pub_resolve/MODULE.bazel) is set up this way. Depend on a mapped package as `@deps//:greeting`, or by its own label.

Bazel also reads a mapped `path` package's pubspec, where the lock says it is, inside the repository or outside it. A hosted package that depends on the mapped one while the mapped one depends back on it is a cycle that no target can build. Bazel refuses it when it plans the packages, and the message says how to build the package from its pubspec instead. A pubspec outside the repository that isn't there fails nothing. One inside the repository that isn't there, or that pub refuses, fails the builds that reach the package, saying why.

- The target is a `flutter_library`, `flutter_plugin` or `dart_library`, with any name. The `package_name` of its `dart_package_metadata` must be the pub package's name. If it isn't, analysis fails, naming the target, the key and the name it declares.
- For a package with assets, fonts or shaders, your target is also what bundles them, at `packages/<package>/<path>`, as `flutter build` does.
- The target must be `//visibility:public`, because the hub forwards to it.
- Usually the target is in the Bazel package at the path: `../../packages/greeting` from `apps/greeter` is `//packages/greeting`. Bazel doesn't check this, because the path matters only to pub. A package pub reads from a sibling checkout can map to a module Bazel takes it from, as `"ui_kit": "@ui_kit"`.
- If your target depends on a hosted package that depends back on it, the build fails with Bazel's cycle error. Pub allows that cycle and Bazel doesn't.

`resolve` can also replace a hosted, git or `sdk` package for the whole graph, with a fork or a patched copy from any repository. `@deps//:<package>` is then your target, and every hosted package that depends on it gets it too. The locked package is never fetched, and its version isn't checked against your target.

`runfiles` from pub.dev needs no `resolve`. rules_dart publishes it from `@rules_dart//dart/runfiles`, so the hub serves that target for it, whichever version the lock names, as rules_dart's `pub` does. A program can then depend on both `@deps//:runfiles` and `@rules_dart//dart/runfiles`. A `resolve` of `runfiles` of your own still wins. A `runfiles` that a lock takes from another registry, git or a path is a different package, and it is built from the lock as usual.

Every `path` package of the lock must be named in exactly one of `resolve`, `build_from_pubspec` and `ignored`. A `path` package named in none of them fails as soon as Bazel reads the lock, naming the lock and the package, with the lines to add. Naming a package the lock doesn't list is an error.

`build_from_pubspec` is for a `path` package with no Bazel build, such as the `<plugin>_android` package of a federated plugin, which is only Kotlin and a Gradle build. rules_flutter builds its directory exactly as it builds a package from pub.dev or git, and as `flutter build` builds every `path` package. That covers its Dart library, assets, fonts and shaders, and its Android, iOS, macOS, Linux and Windows plugin code. The plugin class, namespace, manifest, Maven dependencies and ProGuard files are read from its pubspec and Gradle files. Depend on it as `@deps//:<package>`.

`ignored` is for a `path` package that no Bazel build may contain, such as a tool you run with `dart run` outside Bazel. Give the reason:

```starlark
flutter_pub.from_lock(
    name = "deps",
    lock = "//:pubspec.lock",
    build_from_pubspec = ["keyboard_android"],
    ignored = {"release_tool": "run with `dart run` outside Bazel"},
)
```

The lock then loads, and a target that depends on `@deps//:release_tool` fails at analysis with ``package `release_tool` (in <lock>) is ignored: <reason>``.

A few more details of `build_from_pubspec`:

- The directory is the lock's path, relative to the lock's directory, as pub reads it. It may be outside the repository, by an absolute path or one that leaves it. Such a package ties the build to this machine, and a lock with an absolute path works only where it was written.
- The package's repository is local, wherever the directory is, as a `local_repository` is: `bazel vendor` leaves it out (inside the repository it builds from the checkout), and it is fetched again when Bazel's server restarts.
- Bazel reads `pubspec.yaml`, `lib/`, `hook/`, the license, the platform directories, and the directories the pubspec lists assets, fonts and shaders from. It sees edits to them. Tool output (`build/`, `.dart_tool/`, `android/.gradle/`, `android/build/`) is left out, and changes there don't make Bazel fetch the package again.
- A directory that holds a `BUILD`, `BUILD.bazel`, `MODULE.bazel`, `REPO.bazel` or `WORKSPACE` file is refused. It has a Bazel build, so map it with `resolve`.
- A package whose code is generated, or built by Bazel some other way (the Rust behind a flutter_rust_bridge `rust_builder`, say), needs `resolve` too. Its pubspec doesn't say how to build it.

Some limits of path packages:

- One lock serves one repository. A package's `BUILD.bazel` names one hub's labels (`@deps//:intl`), so two apps with two locks can't share a package this way. Use one lock for the monorepo, resolved from a pub workspace or from one app.
- The members of a pub workspace (`workspace:` in the root `pubspec.yaml`) aren't in the lock. Depend on them by label.
- A lock below the repository root is resolved with `bazel run @rules_flutter//flutter/pub -- get --directory=apps/greeter`.

#### Pub packages' assets

A package's `flutter: assets:` are bundled at `packages/<package>/<path>`, as `flutter build` bundles them, and with the same rules:

- A listed image ships its resolution variants from the `<number>x/` directories beside it.
- A listed directory (a trailing slash) ships the files directly in it, and nothing from the directories below it.
- An entry with `platforms:` ships only in builds for those platforms.
- An entry with `flavors:` ships only in a build of one of those flavors (an application's `flavor`), and in no build without a flavor. Two entries that give one file different flavors fail the build.
- An entry `packages/<other>/<path>` that is no file at that path is the file `<path>` of the `lib/` of the package `<other>` (this package or any other the lock builds, as in flutter_tools' package config), bundled at that key as listed. A listed directory is never read that way.
- A package's `flutter: shaders:` entries follow the same rules.
- A name with a space or a non-ASCII character is stored percent-encoded, the form the engine asks for, and listed in the manifest as written.

#### Packages that depend on each other

Pub allows packages to depend on each other in a cycle: `dio` and `dio_web_adapter` import each other. Bazel doesn't. rules_flutter builds such packages as one library, so `@deps//:dio` and `@deps//:dio_web_adapter` both name it. Each package keeps its own name, language version, assets and plugin, so the app gets what `flutter build` would give it.

A cycle is built this way only where it is declared, in `MODULE.bazel`:

```starlark
flutter_pub.cycle(packages = ["ping", "pong"])
```

You don't need to declare the cycles of well-known packages. rules_dart declares those itself, in `curated_cycles()` in `@rules_dart//dart/ext:registry.bzl`. Today that is `dio` and `dio_web_adapter`.

- An undeclared cycle fails when something first builds one of its packages. The message names every package in the cycle and the `flutter_pub.cycle()` to add.
- A declaration must name exactly one cycle at the versions the build uses. One that names packages in no cycle (because a new release dropped the dependency, say), or only part of a cycle, fails the same way, so a declaration can't outlive its cycle.
- A declaration that names a package the build doesn't build from a lock (`package:flutter`, or a package mapped with `resolve`) fails when the module is read.
- Like versions, cycles apply to the whole build, and the root module decides. Declarations from a module the root depends on, and rules_dart's own, apply where they name exactly a cycle and do nothing otherwise. That module can't fix what the root's versions made of them.
- A package built from a plugin overlay can't be in a cycle, and the build says so.

### Regenerating pubspec.lock

Bazel reads `pubspec.lock` and never writes it. Where you would run `flutter pub`, run the same command through the Flutter toolchain the rules pin:

| With Flutter installed | With rules_flutter |
|---|---|
| `flutter pub get` | `bazel run @rules_flutter//flutter/pub -- get` |
| `flutter pub upgrade` | `bazel run @rules_flutter//flutter/pub -- upgrade` |
| `flutter pub add qr` | `bazel run @rules_flutter//flutter/pub -- add qr` |

The arguments pass through to `dart pub` unchanged. The command runs at your workspace root, so the lock lands where `flutter_pub.from_lock` reads it. For a package below the root, such as a `tools/*` package or one app of a monorepo, add pub's `--directory` flag with a path from the workspace root. The lock lands beside that package's `pubspec.yaml`:

```sh
bazel run @rules_flutter//flutter/pub -- get --directory tools/my_tool
```

Use this rather than a Flutter installed on your machine, because the Flutter version that resolves the lock matters. Pub treats the running Dart and Flutter versions as constraints. An older installation quietly picks older packages, and the lock it writes is still valid, so nothing downstream can tell.

The toolchain rules_flutter downloads has a Dart SDK and engine artifacts, but no `bin/flutter`. So this target runs `dart pub`, with `FLUTTER_ROOT` pointing at a tree assembled from the same Flutter release, which is fetched the first time you run it. `dart pub` writes `pubspec.lock` and `.dart_tool/package_config.json`, but not `.flutter-plugins-dependencies`. Nothing needs that file: rules_flutter generates the plugin registrants from the build graph.

### Several locks in one build

A build can have several `flutter_pub.from_lock` tags, in your module or in modules you depend on. Each tag's hub, such as `@deps`, is a set of aliases for the packages its own lock names. Underneath, each package is one repository for the whole build, however many hubs list it.

So a build has one version of each package. Each lock's hosted entry is a request for at least that version, and the highest request is built. This is how Bazel's minimal version selection treats a `bazel_dep`, and rules_dart uses the same policy.

When another module's lock is raised, nothing is said, since that is what a minimum means. When a lock of the root module is raised, the build prints a warning, as Bazel's `--check_direct_dependencies` does for a `bazel_dep`:

```text
Package "meta" is built at 1.17.0, newer than the root module asks for:
  - 1.16.0, from the lock `//app:pubspec.lock`
Raised by:
  - 1.17.0, from the lock `//:pubspec.lock` in module `some_module`
Each request is a minimum and the highest wins. Raise the root's to 1.17.0:
  bazel run @rules_flutter//flutter/pub -- upgrade --directory=app meta
or set `flutter_pub.settings(check_direct_dependencies = "off")` in the root module to stop this check.
```

Run the command from the workspace root. It works even while the extension is failing. rules_flutter's own tools have a lock of their own, which counts as another module's, so a rules_flutter release that moves them ahead of your lock raises yours, with this warning.

The root module sets how this is reported, once:

```starlark
flutter_pub.settings(check_direct_dependencies = "error")  # "off", "warning" (the default) or "error"
```

At `"error"` the message fails every build that uses a hub. The toolchain comes from the other extension, so the `bazel run` fix still works.

Beyond versions, the locks must agree. A package that comes from different sources, registries or digests, from different git commits, or from different `build_from_pubspec` directories always fails. `resolve` applies to the whole build. Only the root module may use `flutter_pub.settings` and `ignore_hooks`. If another module uses them, the build fails.

### Plugins' Maven dependencies

A plugin's `android/build.gradle(.kts)` declares the Maven artifacts its Kotlin or Java compiles against. `shared_preferences_android` declares `androidx.datastore:datastore`, for example.

In Bazel those artifacts come from `@rules_flutter_maven`, rules_flutter's own rules_jvm_external repository, which also holds the embedding's androidx libraries. Your root `MODULE.bazel` adds to it with a `maven.install(name = "rules_flutter_maven")` of its own, which [Android](#android) shows under **Maven dependencies**. That is one resolution for the whole app, so there is one version of each artifact. When two plugins want different versions, the highest wins, as under Gradle. An app whose plugins declare no Maven artifacts needs no install, because rules_flutter's own lock covers the embedding.

To find out which artifacts your app needs, run its `<name>_maven_artifacts` target. Every `flutter_android_app` has one, so for an app named `my_app`:

```sh
bazel run //:my_app_maven_artifacts
```

It prints the lines to paste into `artifacts = [...]` for the plugins that app depends on, and no others, and marks those that are missing or too low:

```
"androidx.datastore:datastore:1.1.7",  # declared by package:shared_preferences_android 2.4.28; missing
"androidx.core:core:1.17.0",  # declared by package:url_launcher_android 6.3.29; resolves 1.0.0
```

A plugin that takes its versions from a BoM, as the FlutterFire plugins do, gets the BoM's line too, to paste into `boms = [...]`, and its artifacts are listed with no version:

```
"com.google.firebase:firebase-common",  # declared by package:firebase_core 5.1.0; missing
"com.google.firebase:firebase-bom:35.1.0",  # declared by package:firebase_core 5.1.0; missing
```

An artifact whose declaration excludes some of what it brings (`exclude group: ..., module: ...`) is printed as a `maven.artifact(..., exclusions = [...])` to add to `MODULE.bazel` instead, since `artifacts = [...]` can't say what to exclude.

It works while the build is failing for lack of them, which is when you need it. Add the lines, then re-pin the install's lock file:

```sh
REPIN=1 bazel run @rules_flutter_maven//:pin
```

Below the lines it also suggests one [buildozer](https://github.com/bazelbuild/buildtools/tree/main/buildozer) command that makes the same changes to `artifacts` and `boms`, adding what is missing and raising what the install lists too low, followed by the re-pin when the install has a lock file. It assumes the `maven.install` is in your root `MODULE.bazel` itself, not in a file that it `include()`s.

If you skip this, the Android build fails when it links the plugin, with one message listing the same lines. Only the plugins that app links are checked. Only Android builds read any of this, and a web or desktop build never fetches it.

Two other forms print the same kind of block:

- `flutter_android_maven_artifacts` declares the same target for an app you wire by hand.
- `bazel run @deps//android:maven_artifacts`, for any hub, prints the block for every plugin of the build. Use it to seed `maven.install` before any app exists, or for a workspace whose apps share one install.

#### Which Gradle lines are read

rules_flutter reads a plugin's Gradle file without running Gradle. It understands these forms:

- The configurations `implementation`, `api` and `compile` (compile and runtime classpath), `compileOnly` and `provided` (compile only), and `runtimeOnly`. Test, `androidTest`, lint and `classpath` lines are ignored.
- A string, `"group:artifact:version"`, in single or double quotes, with or without parentheses. A `:classifier` or `@packaging` suffix is dropped.
- `"group:artifact"` with no version, which takes its version from a BoM, and a BoM: `platform("group:artifact:version")` or `enforcedPlatform(...)`. A BoM goes in `maven.install(boms = [...])`, and the build checks that the install lists it at the highest version a plugin declares.
- A string computed as Gradle would compute it: `$x` and `${...}` take values from variables the file sets once (`def x = "..."`, `val`, `var`, `ext.x = ...`, `ext["x"] = ...`, `ext { x = ... }`), from the plugin's `android/gradle.properties` (`project.properties["x"]`, `findProperty("x")`, or the bare name), from another plugin's (`findProject(":firebase_core").properties["x"]`), and from functions the file defines whose bodies are `return` and `if (...) return` statements. A Bazel build has no root Gradle project, so `rootProject.ext` is empty, as it is in a `flutter create` app. If a version can't be computed, or is dynamic (`1.+`, `[1.0,2.0)`, `latest.release`), the build only checks that the artifact is present, at any version.
- A closure after the declaration whose statements are `exclude group: "g", module: "m"` (or `because`), which leave those artifacts out of what it brings.
- The scripts of the package that the file applies with `apply from:`, which are read as part of it.
- Another plugin's Gradle project, `implementation project(":x")`, `api findProject(":x")` or a variable set to one, as cloud_firestore depends on firebase_core. Flutter's Gradle build names each plugin's project after its package, so the plugin's library depends on package `x`'s Android library. A project that isn't a plugin of the lock with an Android library fails the plugin's Android build, naming the line. Without such a line, the library still depends on the Android library of each plugin that its `pubspec.yaml` lists under `dependencies:` (not `dev_dependencies:`), as Flutter's Gradle build makes it; image_picker_android depends on flutter_plugin_android_lifecycle this way.
- `org.jetbrains.kotlin:kotlin-stdlib*` and `io.flutter:*` are skipped, because the Kotlin rules and the engine provide them.
- The declaration must sit directly in the script's `dependencies { }` block, or in one inside `android { }`. A declaration inside an `if`, an `afterEvaluate` or any other block may or may not run under Gradle. It is linked when `@rules_flutter_maven` has the artifact, and not required.

A `buildConfigField` in `android { defaultConfig { } }` adds its field to the plugin's `BuildConfig`, as Gradle does, with its arguments computed as above. The FlutterFire plugins set `LIBRARY_VERSION` from their own `pubspec.yaml` with a regular expression; rules_flutter recognises those exact statements and gives the field the package's version with `+` as `-`, as Gradle does. A field whose value rules_flutter can't compute, or one in a build type, a flavor or a condition, fails the plugin's Android build, naming the line, rather than leaving the field out or giving it a value Gradle wouldn't. `flutter_pub.annotation(build_config_fields = ...)` below gives such a field its value.

Anything else in a plugin the app links is a warning, naming the plugin, its Gradle file and each line, because a reader that isn't Gradle can be wrong. That covers a declaration inside a block, and a dependency written any other way: a version catalog entry such as `libs.foo`, a `compileOnly` or `runtimeOnly` project, `files(...)`, Groovy map notation, any other statement in a declaration's closure, `kapt`, `ksp`, `annotationProcessor`, `coreLibraryDesugaring`, a variant configuration such as `debugImplementation`, or an `apply from:` of a script the package doesn't have. The plugin's library doesn't link those. `bazel run @<hub>//android:maven_artifacts` and an app's `<app>_maven_artifacts` list the same lines below the ones to paste, so they show before an app builds.

If the plugin's Android code then fails to compile for want of one, add the artifact to your `maven.install(name = "rules_flutter_maven")` and state it for that plugin in your root `MODULE.bazel`:

```starlark
flutter_pub.annotation(
    package = "some_plugin",
    android_deps = ["@rules_flutter_maven//:androidx_browser_browser"],
)
```

This works like `crate.annotation` for a Rust crate in rules_rust. Each label is added to the generated Android library of that one package, and counts as if the plugin's Gradle build had declared it. The app's build fails, naming it, when `@rules_flutter_maven` doesn't resolve it. `<app>_maven_artifacts` lists it as declared by the plugin, and the duplicate-class check below covers it. An annotated plugin no longer warns about its unread lines, since you have stated its dependencies.

`build_config_fields` gives the value of a `buildConfigField` that rules_flutter can't compute, by field name, as the Java expression Gradle's third argument holds. A string keeps its quotes:

```starlark
flutter_pub.annotation(
    package = "some_plugin",
    build_config_fields = {"LIBRARY_VERSION": "\"1.2.3\""},
)
```

The type stays the one the Gradle line declares, and the annotation wins over what rules_flutter reads or recognises. A field the plugin's Gradle build doesn't declare fails its Android build, naming the plugin and the field. An annotation names a package, not a version: a version written there goes stale when the lock moves the package, so update it with each bump.

Only the root module may use `flutter_pub.annotation`, once per package. It fails the build when no lock lists the package, or when the package isn't a plugin with Android sources whose library rules_flutter generates.

A plugin that needs more than dependencies can have an overlay instead (see [Packages with build hooks](#packages-with-build-hooks)). That is a `BUILD.bazel.tpl` for the package, and an `android/BUILD.bazel.tpl` that declares its Android library with the `@rules_flutter_maven` labels it needs. The `android/` template is used only beside the top-level one, and the top-level template's `flutter_plugin` must list that library in `exports`, as above, for an app to link it.

#### Versions Gradle would align

Gradle also aligns libraries that are published together. androidx `activity` 1.9.0 declares in its Gradle module metadata (the `.module` file beside its POM) that `activity-ktx` must be 1.9.0 too, because the Kotlin extensions moved from `activity-ktx` into `activity`. Coursier, which resolves the install, reads only POMs. So an install whose `preference` 1.2.1 asks for `activity-ktx` 1.5.1 keeps that version beside `activity` 1.9.0, and the two jars define the same classes differently.

So both `maven_artifacts` programs also read the `.module` file of every artifact the install resolves, and print a line for each artifact Gradle would raise:

```
"androidx.activity:activity-ktx:1.9.0",  # aligned with androidx.activity:activity 1.9.0; resolves 1.5.1
```

They read the metadata from the install's repositories, so they need network access, as the pin does. To run one offline, as a test does, record the metadata once with `bazel run //:my_app_maven_artifacts -- --record=<file>`, and read it back with `-- --metadata=<file>`. The second fails, naming any artifact the file lacks.

#### Duplicate classes

Building a `flutter_android_app` checks what it links. When two jars define a class with different bytes, the build fails and names both jars, with their Maven coordinates. Otherwise the app's deploy jar would keep whichever copy comes first, a mix of two versions of one library. Resource classes (`R`, `R$string`) aren't compared, since every Android library carries its own and `android_binary` replaces them with the app's.

Two differing jars can both be fine, as when either copy of an interface works, or an app shadows a library's class on purpose. Build with `--@rules_flutter//flutter:allow_duplicate_classes` to let them through, the equivalent of the Android Gradle plugin's `android.enableDuplicateClassesCheck=false`. The deploy jar then keeps the first copy.

The build also fails when one Maven library (`group:artifact`) reaches the app from two rules_jvm_external repositories, `@rules_flutter_maven` and another, since each resolves its versions on its own. The message names both targets. Depend on the `@rules_flutter_maven` one. If the other is a target of another module's repository, which you can't edit, send that repository's copy to ours from your root module:

```starlark
maven.override(
    name = "<its repository>",
    coordinates = "<group:artifact>",
    target = "@rules_flutter_maven//:<target>",
)
```

#### Exact version ranges

Coursier is stricter than Gradle about exact version ranges. `androidx.preference:preference:1.2.1`, which `shared_preferences_android` needs, depends on `androidx.fragment:fragment` as `[1.3.6]`, an exact version, while other artifacts want a higher one. Gradle lets the higher version win, and Coursier on its own reports a conflict.

rules_flutter's own `maven.install` passes Coursier `--reconciliation *:*:relaxed` through `additional_coursier_options`, which makes it pick the highest version too. rules_jvm_external joins those options across every module that declares an install of that name, so your `maven.install(name = "rules_flutter_maven")` inherits them, and you need no `force_version` entries for such ranges.

Don't set `resolver = "gradle"` or `"maven"` to get this. The Gradle resolver picks the JVM or desktop variant of Kotlin Multiplatform libraries (for example `androidx.lifecycle:lifecycle-runtime-desktop`) instead of the Android one. The Maven resolver reports the same conflict as Coursier.

#### An AAR that a POM asks for as a jar

With the FlutterFire plugins in an app, the re-pin can lock `androidx.datastore:datastore-preferences` wrongly, and the build then fails to fetch it:

```
Download from https://maven.google.com/.../datastore-preferences-1.2.1.jar failed:
  Checksum was 4cc64370… but wanted ae206842…
```

`firebase-common`'s POM asks for that artifact as `<type>jar</type>`, although it is an Android library published as an AAR (with a small jar beside it). rules_jvm_external then records a single jar entry carrying the AAR's checksum. Gradle reads the artifact's Gradle module metadata instead and uses the AAR. Until rules_jvm_external fixes this, name the AAR yourself and drop the jar-typed edge, then re-pin:

```starlark
maven.install(
    name = "rules_flutter_maven",
    artifacts = [
        "androidx.datastore:datastore-preferences:aar:1.2.1",
        # ...
    ],
    # ...
)

maven.artifact(
    name = "rules_flutter_maven",
    group = "com.google.firebase",
    artifact = "firebase-common",
    exclusions = ["androidx.datastore:datastore-preferences"],
)
```

Use the version your lock already resolves for `datastore-preferences`. The AAR you list provides the classes `firebase-common` needs. `e2e/plugin_example` builds a Firebase app this way.

#### Permissions in plugin manifests

Permissions a plugin declares in its own manifest, such as `record_android`'s `RECORD_AUDIO`, reach the app's manifest as they do under Gradle. You don't need `--merge_android_manifest_permissions`.

### System libraries of Linux and Windows plugins

A plugin's C++ sources are compiled into your Linux or Windows app, so the app must link the system libraries they call. rules_flutter reads those from the `target_link_libraries` calls in the plugin's `linux/CMakeLists.txt` or `windows/CMakeLists.txt` that name the plugin's library. `url_launcher_windows` links `shlwapi.lib` that way, so a Windows app with it links `shlwapi.lib`.

- `flutter` and `flutter_wrapper_plugin` on Windows, and `flutter` and `PkgConfig::GTK` on Linux, are what the app links already.
- A plain library name (`shlwapi`, `dwmapi.lib`, `m`) becomes a linker flag.
- A list variable (`${wmf_libs}`) is read when the file sets it once, outside any block, to literal values before the call, as in `set(wmf_libs mf.lib mfplat.lib)`. Its values are then read as above.
- Anything else needs CMake to evaluate it: any other variable, a generator expression, an imported target such as `PkgConfig::LIBSECRET`, a target the plugin defines or fetches, a path, a linker flag, or a call inside an `if()` or `foreach()` block.

If a plugin has something of the last kind, its Windows or Linux app fails to build, listing each line and its package. Other platforms are unaffected. To build it, supply a plugin overlay with `flutter_pub.plugin_overlays` (see [Packages with build hooks](#packages-with-build-hooks)): a `BUILD.bazel.tpl` for the package that declares its `flutter_windows_plugin_library` or `flutter_linux_plugin_library`, with the flags its sources need in `linkopts`.

### Plugins' Java and Kotlin level

A plugin's Android sources compile at the Java level its `android/build.gradle(.kts)` declares, as under Gradle: `compileOptions { targetCompatibility = JavaVersion.VERSION_17 }`, else Kotlin's `jvmTarget`, else the version of a Java toolchain (`kotlin { jvmToolchain(17) }`), else Java 11, the default of the Android Gradle plugin 9 that Flutter's templates use. `flutter create`'s plugin template declares 17. One level covers the plugin's Java and its Kotlin, and a level below 8 compiles at 8.

The level may be written as a variable the script, or a script of the package it applies (`apply from: "config.gradle"`), sets. When rules_flutter can't read a value that could decide the level (one held in `rootProject.ext`, say, which the app's Gradle build sets), an Android app that links the plugin fails to build, naming the package, the file and the line. So does one whose script declares no level it can read and applies a script it can't read, which could. Other platforms are unaffected. To build it, supply a plugin overlay with `flutter_pub.plugin_overlays` (see [Packages with build hooks](#packages-with-build-hooks)) whose `android/BUILD.bazel.tpl` sets the level as the `jvm_target` of a `kt_kotlinc_options` its `kt_android_library` takes as `kotlinc_opts`, as rules_flutter's bundled overlay for `package:jni` does.

### Plugins whose own build makes a native library

Some plugins make a library with their platform's build system, rather than from sources rules_flutter compiles. rules_flutter doesn't run Gradle, CocoaPods or CMake, so it can't make that library. It recognises these cases from the plugin's own files:

- Gradle's `externalNativeBuild` (CMake or ndk-build) in `android/build.gradle(.kts)`, which `package:jni` uses.
- cargokit, which `flutter_rust_bridge` plugins use to build a Rust crate with cargo: `apply from: ".../cargokit/gradle/plugin.gradle"` in the Gradle script, a podspec script phase running `cargokit/build_pod.sh`, or `apply_cargokit()` in a `CMakeLists.txt`.
- Any other CocoaPods script phase (`s.script_phase`) in the plugin's podspec, for a platform where the plugin has no `Package.swift`. Where it has one, Flutter builds that instead (see [Apple plugins built from their Package.swift](#apple-plugins-built-from-their-packageswift)).
- A `CMakeLists.txt` that sets `<plugin>_bundled_libraries`, Flutter's way of shipping a library the plugin's CMake build makes or downloads.
- `ffiPlugin: true` for the platform in the pubspec, which tells Flutter to build the plugin's native sources into a library that Dart opens. The exception is iOS or macOS when the plugin has a `Package.swift`.

An app built without the library would fail at run time when the plugin loads it. So the build for that platform fails instead, naming the package, the platform and the mechanism. Builds for the plugin's other platforms are unaffected.

To build the app, build the library with Bazel: a `rust_shared_library` from rules_rust for a Rust crate, or a `cc_shared_library` for C or C++. Then give the package a target that lists it in `native_deps`, in one of two ways:

- A plugin overlay (`flutter_pub.plugin_overlays`): a `BUILD.bazel.tpl` for the package whose `flutter_plugin` lists the library. rules_flutter's bundled overlay for `package:jni`, in `flutter/ext/jni/`, does this.
- A `flutter_plugin` of your own, which `flutter_pub.from_lock(resolve = {"<package>": "//your:target"})` puts in place of the package (see [Packages in your workspace](#packages-in-your-workspace-path-dependencies-forks)).

An iOS or macOS plugin built from its podspec (one with no `Package.swift` for that platform) can also need what CocoaPods adds to its build, which rules_flutter drops: the pods it depends on (`s.dependency`, except `Flutter`, `FlutterMacOS` and plugins its pubspec depends on), the frameworks and libraries it vendors (`vendored_frameworks`, `vendored_libraries`), and the preprocessor defines of its xcconfig (`GCC_PREPROCESSOR_DEFINITIONS`). The build for that platform fails at analysis, naming the package and each line. Give the package an overlay whose `flutter_apple_plugin_library` builds it with them: the pods and frameworks as Bazel targets in `deps`, the defines in `copts`.

### Apple plugins built from their Package.swift

Some Apple plugins are Swift packages on iOS or macOS: `ios/<plugin>/Package.swift`, or `darwin/<plugin>/Package.swift` with `sharedDarwinSource`. rules_flutter builds those as the manifest says, as `flutter build` does with Swift Package Manager.

It reads the manifest with Xcode's `swift package dump-package`. It compiles the targets of the plugin's library product (`flutter-qjs-next` for `flutter_qjs_next`), and the targets of the package they depend on for that platform. Each target is a module of its own. `video_player_avfoundation`, for example, has four. For each target it takes:

- its sources, Swift, Objective-C, C and C++ alike, as the target's `path`, `sources` and `exclude` give them;
- its public headers (`publicHeadersPath`) and header search paths;
- its resources (`.process` and `.copy`), in the bundle SwiftPM makes for them (`<package>_<target>.bundle`), which `Bundle.module` (Swift) and `SWIFTPM_MODULE_BUNDLE` (Objective-C) find;
- its Swift language mode: the target's `swiftLanguageMode`, else the newest of the package's `swiftLanguageModes`, else Swift 6 for `swift-tools-version: 6.0` and Swift 5 before;
- its settings: `.define` and `.unsafeFlags` in `cSettings`, `cxxSettings` and `swiftSettings`; `linkedFramework`, `linkedLibrary` and `.unsafeFlags` in `linkerSettings`; Swift's upcoming and experimental features; and the package's C and C++ language standards.

A setting for `.when(configuration: .debug)` applies to builds other than `-c opt`. One for `.release` applies to `-c opt`, which is Flutter's profile and release modes. One for other platforms applies to none.

As in `flutter build`, a plugin with a `Package.swift` is built from it whatever its podspec does, script phases included. An FFI plugin (`ffiPlugin: true`) with a `Package.swift` is linked into the app, where Dart finds its symbols with `DynamicLibrary.process()`.

C-family sources are compiled with Clang's module autolinking on, as Xcode compiles them. So an SDK framework the plugin imports without naming it (`permission_handler_apple`'s `CoreTelephony`) is linked into the app.

Only an iOS or macOS build reads the manifests, and it needs Xcode to do so, as any Apple build does. Other platforms and other hosts never evaluate a manifest.

Some manifests can't be built this way. An iOS or macOS app that links such a plugin fails at analysis, saying why. The cases are a library product of several targets none of which is named after the plugin (Flutter imports the module of that name), a binary target, or a setting rules_flutter doesn't apply. Other platforms are unaffected. Give such a plugin an overlay (`flutter_pub.plugin_overlays`) whose `flutter_apple_plugin_library` builds it.

#### Swift packages a plugin depends on

A plugin's package can depend on other Swift packages, as the Firebase plugins depend on `firebase-ios-sdk`:

```swift
.package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "13.1.1"),
```

Your root module declares those packages, as it declares the Maven artifacts of Android plugins. Under `flutter build`, Xcode resolves the plugins' packages together with your Runner's own and pins them in one `Package.resolved`. In Bazel, [rules_swift_package_manager](https://github.com/cgrindel/rules_swift_package_manager) does that from a `Package.swift` and a `Package.resolved` at your workspace root, and rules_flutter builds the plugins against the packages it declares. Your own Swift code and the plugins then share one copy of each package, and every rules_swift_package_manager setting applies to both.

To find out what to declare, run:

```sh
bazel run @deps//swift:packages      # `deps` being your flutter_pub.from_lock's name
```

It prints the lines for every Apple plugin in the lock, with a requirement every plugin accepts, and marks the packages your `Package.resolved` is missing or pins at a version a plugin doesn't accept:

```
// In the `dependencies` of the root module's Package.swift:

    .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "13.1.1"),  // package:firebase_core 5.1.0; missing from //:Package.resolved

# In the root MODULE.bazel (`bazel mod tidy` keeps the `use_repo`):

    bazel_dep(name = "rules_swift_package_manager", version = "1.25.0")

    swift_deps = use_extension("@rules_swift_package_manager//:extensions.bzl", "swift_deps")
    swift_deps.from_package(
        resolved = "//:Package.resolved",
        swift = "//:Package.swift",
    )
    use_repo(swift_deps, "swift_package", "swiftpkg_firebase_ios_sdk")

    # flutter_pub being your use_extension of rules_flutter's pub extension:
    inject_repo(flutter_pub, "swiftpkg_firebase_ios_sdk")
```

`Package.swift` needs only the dependencies, no targets:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "my_app",
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "13.1.1"),
        // Your own Swift code's packages, if any.
    ]
)
```

Name the same `Package.resolved` in your `flutter_pub.from_lock`, so rules_flutter can check its pins against what the plugins require:

```starlark
flutter_pub.from_lock(
    name = "deps",
    lock = "//:pubspec.lock",
    swift_package_resolved = "//:Package.resolved",
)
```

Then write the file with `bazel run @swift_package//:update` and commit both. rules_swift_package_manager declares a repository for each package the file pins, named `swiftpkg_` and its identity with `-` as `_`. A plugin reaches a repository only through `inject_repo`, which names the packages the plugins depend on directly. The packages those depend on need no line.

To build a package your own way (a fork, a patched target, a prebuilt framework), give the pub extension your repository under the name the plugins use. `inject_repo` takes it as a keyword argument, the plugins' name first:

```starlark
local_repository = use_repo_rule("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository")

local_repository(
    name = "my_firebase",
    path = "third_party/firebase",
)

# In place of inject_repo(flutter_pub, "swiftpkg_firebase_ios_sdk"):
inject_repo(flutter_pub, swiftpkg_firebase_ios_sdk = "my_firebase")
```

Its `BUILD.bazel` declares a target for each product the plugins use, named after the product and providing the module they import: `FirebaseCore` for `.product(name: "FirebaseCore", package: "firebase-ios-sdk")`, a `swift_library` or `objc_library` with `module_name = "FirebaseCore"`, say. Your own Swift code depends on the same targets. Keep the package in your `Package.swift` and `Package.resolved`: rules_flutter still checks the plugins' requirements against its pin, which should be the version your targets build.

An iOS or macOS app that links such a plugin fails at analysis when something is missing, and the message says what to add:

- a package the file doesn't pin, with its `.package(...)` line and `inject_repo` entry;
- a pin the plugin's `Package.swift` doesn't accept (`firebase-ios-sdk exact 13.1.1; pins 13.2.0`), with the line that asks for what it requires;
- a pinned package you didn't hand to rules_flutter, with the `inject_repo` line.

After a change to `pubspec.lock` that changes a plugin's Swift dependencies, run `@deps//swift:packages` again, change `Package.swift` to match and run `bazel run @swift_package//:update`. Each package is fetched only when an iOS or macOS build needs it. rules_swift_package_manager's own settings, such as `swift_deps.configure_package` and its target modifications, go in your `MODULE.bazel` as its documentation describes. Firebase needs one under explicit Clang modules (see [Explicit Clang modules on macOS and iOS](#explicit-clang-modules-on-macos-and-ios)). [`e2e/ios_example`](e2e/ios_example/MODULE.bazel) is a worked example, with Swift code of its own on FirebaseCore beside the FlutterFire plugin.

#### Plugins whose Package.swift reads the app

Some manifests compute their defines from what surrounds the build:

- `permission_handler_apple` finds the app it is built for, and turns on a permission's code only when the app's `Info.plist` has its usage description. `NSCameraUsageDescription` gives `PERMISSION_CAMERA=1`.
- `audio_session` reads the environment variable `AUDIO_SESSION_MICROPHONE`.
- `geolocator_apple` reads `BYPASS_PERMISSION_LOCATION_ALWAYS`.

Under `flutter build`, Xcode evaluates such a manifest once per app, from the app's folder, in your shell's environment. rules_flutter does the same for each app, during the build. A manifest that sets `.define`s and either imports more than `PackageDescription` or reads its `Context` is evaluated again for each iOS or macOS app that links the plugin.

It sees a stand-in for the app's folder, as it would under Xcode. That is a `pubspec.yaml`, and in `ios/` (or `macos/`) an Xcode project whose `INFOPLIST_FILE` is the Info.plist the app is built from: its `info_plist`, or `ios/Runner/Info.plist`. So an app whose Info.plist explains the camera gets permission_handler's camera code and no other permission's, with no extra attribute.

Its environment is the app's `swift_package_environment`, and nothing else from your shell. Set what the plugin's README tells you to export:

```starlark
flutter_ios_app(
    name = "app",
    application = ":app_flutter",
    bundle_id = "com.example.app",
    # What audio_session's README says to export before `flutter build`.
    swift_package_environment = {"AUDIO_SESSION_MICROPHONE": "1"},
)
```

`flutter_macos_app` takes the same attribute, and so do the add-to-app macros, `flutter_ios_xcframeworks` and `flutter_macos_xcframeworks`, with `info_plist` ([below](#add-to-app-ios-and-macos)). The dict is the environment of every such manifest in the app, as the shell is under Xcode, and each manifest still decides what each variable does.

The defines are the only part of such a manifest that may depend on the app. Its sources, header search paths, dependencies and other settings are read once, when the plugin is fetched. If an evaluation for an app gives any of those differently, the build fails, naming the difference.

The stand-in folder leaves out the rest of your app's tree, so a manifest that reads other files of the app doesn't find them. permission_handler's `permission_handler.yaml` flavors are one such file. In Bazel, a flavor is an app target of its own with its own Info.plist, which is what that file emulates.

Each such plugin is compiled once per distinct pair of Info.plist and environment. Two apps with the same plist target and the same environment share one compile, and a third with a different one gets its own. The app's runner and its other plugins are compiled with it, since a Swift compile cannot import one module built two ways, so in a workspace whose lock has such a plugin, apps with different pairs don't share their plugins' compiles. Without one, every app shares them.

`flutter_ios_app` and `flutter_macos_app` build the whole app with its plugins, so the Flutter application is built once. With the composable rules, only the runner from `flutter_ios_runner_lib_gen` or `flutter_macos_runner_lib_gen` is. If you set its `info_plist` or `swift_package_environment`, the rest of your `ios_application` or `macos_application` that reads `application` (the App.framework, the native frameworks, the version) builds the application a second time.

### Packages with build hooks

Some pub packages compile native code through a Dart `hook/build.dart` (Dart Native Assets). Bazel doesn't run those hooks. Each one needs one of these instead:

- **A curated replacement.** rules_dart keeps a registry of Bazel-native equivalents, in `@rules_dart//dart/ext:registry.bzl`. Where one exists, `flutter_pub.from_lock` attaches it for you. `sqlite3` is one, so an app that depends on `drift` gets `libsqlite3` without naming it.
- **An overlay.** For a package with a hook and no curated entry, you can write a `BUILD.bazel.tpl` that reproduces what the hook builds. rules_flutter bundles some overlays under `flutter/ext/`. Add your own with `flutter_pub.plugin_overlays(roots = [...])`, where each root anchors a tree of `<package>/<version>/BUILD.bazel.tpl` files. [docs/TESTING.md](docs/TESTING.md) describes writing one, under "Native Assets overlay authoring".
- **Ignoring the hook.** If a package's native code is never reached in your app, say so in the root module: `flutter_pub.from_lock(ignore_hooks = ["<package>"])`.

A hook that nothing replaces is an error when a `flutter_application` or `flutter_test` reaches it. Otherwise the build would succeed, and the app would fail at run time on an unresolved `@Native` symbol.

#### Data assets

A hook can also emit data assets: files the program reads by id. Declare each with `dart_data_asset`, and name it in the `data_assets` of the package's `dart_package_metadata`. That counts as replacing the hook, as `code_assets` does. The id is `package:<package>/<name>`, where `<package>` must be the declaring package. `dart_data_asset` is rules_dart's rule, and `@rules_flutter//flutter:defs.bzl` exports it too.

```starlark
dart_data_asset(
    name = "glyph_index",
    src = "data/index.json",
    asset_id = "package:glyphs/glyphs/index.json",
)

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "glyphs",
    data_assets = [":glyph_index"],
)
```

Every application that reaches the package bundles each asset at `flutter_assets/packages/<package>/<name>` and lists it in `AssetManifest`, as `flutter build` bundles a hook's data asset. So `rootBundle.load('packages/glyphs/glyphs/index.json')` reads it. The application's own package counts too, whether or not a library in its `deps` names the declaration. Web builds bundle them as well, under the bundle's `assets/`.

A debug build runs no hooks and ships every declared asset. In a release or profile build, native or web, a package with a link hook receives its declared assets and ships only those the hook emits (see [Link hooks](#link-hooks)). `e2e/package_assets/own_assets` loads one in a running app.

### Link hooks

A package can choose what it ships from how the app uses it, as with `flutter build`. Mark a `final class` with `@RecordUse()` from `package:meta` (1.19 or later). Then write a `hook/link.dart` that reads the recorded uses with `package:record_use` and emits data assets with `package:data_assets`. The hook may import pure Dart from its own package's `lib/`, but not Flutter. This is [`e2e/package_assets`](e2e/package_assets), where the hook ships only the glyphs the app constructs:

```starlark
# glyphs/BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "glyphs",
    data_assets = [":heart", ":moon", ":star"],  # dart_data_asset targets
    link_hook = "hook/link.dart",
)

flutter_plugin(
    name = "glyphs",
    package = ":pubspec-metadata",
    srcs = glob(["lib/**/*.dart"]),  # not hook/link.dart
    platforms = [],
    deps = ["@deps//:data_assets", "@deps//:hooks", "@deps//:meta", "@deps//:record_use"],
)

# BUILD.bazel
flutter_application(
    name = "app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    deps = ["//glyphs", "@deps//:flutter"],
)
```

Hooks run only in release and profile builds, where the compile records the uses: the kernel compile of a native app, and the dart2wasm compile of a web app (dart2js when it has no WebAssembly build). Every package of the application that has a hook runs it. That includes the application's own package, whether or not a library in `deps` names its `dart_package_metadata`, and its hook may import the application's files under `lib/`.

A hook receives its package's declared [data assets](#data-assets) and ships only those it emits. Packages without a hook ship theirs as declared. What ships is bundled at `flutter_assets/packages/<package>/<name>`, and loaded with `rootBundle.load('packages/<package>/<name>')`. A hook that reports an error fails the build with its own message; the example has an app that does this.

A debug build records nothing, so no hook runs. Every declared data asset ships, and nothing a hook would write does. Have the app load what the hook would have indexed on demand in a debug build.

A rule that names one of a hook's assets before the build runs can name only one the package promises. List its id in `dart_package_metadata(link_hook_assets = [...])`, and the hook must then always emit it.

A hook can also choose among its package's code assets, with `package:code_assets`. In a release or profile build, the app's Native Assets manifest and bundles, and its macOS add-to-app xcframeworks, carry only the libraries the hooks keep. iOS is different, because rules_apple embeds every framework it knows of when it analyses the app:

- A `flutter_ios_app` embeds every candidate, then removes the dropped ones before signing, with an `ipa_post_processor` of rules_flutter's. rules_apple runs one post-processor, so if you give the app your own, that one runs instead, and a hook that drops a code asset fails the build.
- iOS add-to-app (`flutter_ios_xcframeworks`) fails a release build when a hook drops a code asset, as `flutter build ios-framework` does. Its simulator slice is a debug build, which runs no hook.

### Native code from Bazel

A Flutter app can use native code built by any Bazel rule that produces a shared library: `cc_shared_library` from rules_cc, `rust_shared_library` from rules_rust, and so on. List the library in `native_deps`, and it is bundled beside the app, where `dart:ffi` can open it:

```starlark
cc_shared_library(
    name = "my_native_lib",
    deps = [":my_cc_lib"],
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    native_deps = [":my_native_lib"],
    deps = ["@deps//:flutter"],
)
```

What a library loads at run time is bundled beside it, as a native build that links it installs it: the libraries a `cc_shared_library` names in `dynamic_deps`, theirs in turn, and a prebuilt shared library (a `cc_import`) its `deps` link against. So `native_deps` needs only the libraries your Dart code opens. A library one of them links by another route, such as a `linkopts` flag, is not found this way: name it in `native_deps` too.

You can instead bind with `@Native(assetId: ...)` and let the Dart VM find the library. Declare it as a code asset with rules_dart's `dart_code_asset`, and name it in the `code_assets` of the package's `dart_package_metadata`, as a pub package's build hook would supply it. Every program that depends on the package then bundles the library, wrapped in a framework of its own on iOS and macOS (`libfoo.dylib` as `foo.framework/foo`, as `flutter build` wraps it) and under its file name elsewhere, and maps the id to it. An application maps it in `flutter_assets/NativeAssetsManifest.json`, which the engine reads at startup, as `flutter build` ships it. [`e2e/ffi_example`](e2e/ffi_example/BUILD.bazel) shows both styles side by side.

#### Choosing the library that serves an asset id

The package that owns an asset id supplies its library, through the `code_assets` of its `dart_package_metadata`. An application or a `flutter_test` can serve the id from a different library by naming one in its own `code_assets`. That replaces whatever its `deps` supply under that id, as on rules_dart's `dart_binary` and `dart_test`. Use this for a library that differs between programs of one package. A package has one declaration, so a second one stating other assets is refused.

Several ids can name one library. This is how two bridges linked into one shared library run against one copy of it:

```starlark
cc_shared_library(
    name = "combined",
    deps = ["//bridge_a:native", "//bridge_b:native"],
)

dart_code_asset(name = "a_combined", asset_id = "package:a/a", file = ":combined")
dart_code_asset(name = "b_combined", asset_id = "package:b/b", file = ":combined")

flutter_application(
    name = "my_app",
    code_assets = [":a_combined", ":b_combined"],
    deps = ["//a", "//b", "@deps//:flutter"],
    # ...
)
```

The library is bundled once, as one file or one `.framework` on iOS and macOS, and each id's manifest entry names it. So the process loads one image of it: one runtime and one copy of its static state, whichever id a call goes through.

To give each id the binding contract of its own bindings (see the next section), wrap each `dart_code_asset` in a `flutter_native_library`. The wrappers of one library may name a `hot_patch`. If several do, it must be the same one, since one patch of the shared library serves every id.

#### Hot reload across a native rebuild

A running process can't pick up a rebuilt native library. It keeps the one it loaded at launch. So when you edit a native library's sources during a hot reload session, the dev tool has to decide whether the Dart it is about to inject still matches the library the app is running.

The build tells the dev tool which source files each native library is built from. On each reload the tool reads those files and compares them with what the app launched with, so it notices an edit to a `.c` or `.rs` file even in an app whose reload runs no build. The check needs no Bazel.

Without more information, the tool can't tell whether the edit changed the bindings, so it withholds the reload, and a pending native change blocks your Dart edits until you restart. You can tell it what the bindings were generated from, with `binding_contract`, and then it can decide:

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

`binding_contract` is whatever file decides what may be called and how: a binding generator's interface description, or the C header a hand-written FFI binding follows. The dev tool compares the bytes of those files and nothing else. So every change to the wire format must show up in them, and changes that don't affect the wire shouldn't.

With a contract declared, a reload has three outcomes:

| What changed | What the reload does |
|---|---|
| Nothing native | An ordinary reload. |
| The library's code, but not its contract | Delivers the edit, and reports that the native code in the process is stale. |
| The contract | Withholds the edit. Restart to pick up the new library, unless the library has a `hot_patch` builder, which is asked instead (see the next section). |

A library that reaches Dart as a code asset (a target providing rules_dart's `DartCodeAssetInfo`, loaded through `@Native`) is wrapped the same way. The wrapper is itself that code asset, so it goes where the bare asset would have gone: in the `code_assets` of the `dart_package_metadata` of the package that owns the asset id, whether that package's targets are `flutter_plugin`, `flutter_library` or `dart_library`:

```starlark
flutter_native_library(
    name = "bridge",
    library = "@my_bridge//bridge:bridge_code_asset",
    binding_contract = ["@my_bridge//bridge:codegen.ir"],
)

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_bridge_bindings",
    code_assets = [":bridge"],
)

dart_library(
    name = "my_bridge_bindings",
    srcs = ["lib/bindings.dart"],
    package = ":pubspec-metadata",
)
```

The build finds a code asset's target however the package that owns it is reached. A package rule that makes its asset without a target of its own leaves nothing to find, and hot reload couldn't tell when that library changes. So a debug build of the application fails, naming the library. Declare the asset with a target of its own (a `dart_code_asset`, or a `flutter_native_library` wrapping one), and name it in the application's `code_assets`. Other builds bundle it as usual.

#### Patching native code into a running app

A process can't replace a library it has loaded, but it can load a second one and send calls there. Two things make that possible: the toolchain that builds your library can build such a patch, and the library routes its calls so that a patch can take them over. Then a hot reload delivers a native edit into the running app the way it delivers a Dart edit, with state kept and no relaunch.

Name the target that builds patches as `hot_patch`:

```starlark
flutter_native_library(
    name = "bridge",
    library = "@my_bridge//bridge:bridge_shared",
    binding_contract = ["@my_bridge//bridge:codegen.ir"],
    hot_patch = "@my_bridge//bridge:bridge_hot_patch",
)
```

On each hot reload the dev tool hashes the source files that target declares. If none changed, that is all it does. If one did, it builds the patch for the configuration the app is running in, and puts it where the app can load it, signed with the app's own identity on an iOS device. It has the app load the patch, and then applies the Dart half of the edit. A widget that shows a native result is rebuilt, so the new answer appears even when no Dart changed.

| What changed | What the reload does |
|---|---|
| A function body | Patches it into the running app. The reply names the library and what was patched. |
| The contract | Asks the patch builder, which is the part that knows both interfaces. A patch that carries the new surface, such as an added bridged function, is delivered like any other. |
| Anything the builder says a patch can't carry, such as a struct's layout | Withholds the edit and says why, in the builder's words. Restart to pick it up. |
| An edit undone after it was patched | Sends calls back to the code the app launched with. |

A restart (`R`) is still the reset. If any patch is live, or the rebuilt bundle differs from the launched one, it relaunches the app. Anything created before a patch keeps the code it was created with, as with Dart closures.

Patches reach apps on macOS, the iOS simulator, iOS devices and Android. On Linux, Windows and the web, a native edit is reported as stale until you restart.

What a `hot_patch` target builds, and what the library exports, is a small contract, documented on the attribute in `flutter/private/flutter_native_library.bzl`. [`e2e/ffi_example`](e2e/ffi_example/BUILD.bazel) implements it by hand for a C library, in `native/mul_hot_patch.c` and `tools/c_patch_tool.dart`. Its `live 3 × 4` line changes on screen when you edit `native/mul.c` and press `r`.

On the web the same wrapper goes in `flutter_web_bundle`'s `native_modules`, which both serves the `.wasm` module and declares it. The page instantiates the module once, and a hot reload doesn't re-run `main()`, so a native edit is stale there too. A web hot restart does re-run `main()`, so it fetches the module again, with no relaunch.

## Building for each platform

Each platform has a macro, such as `flutter_macos_app`, that turns a `flutter_application` into an app for that platform. It reads the runner files `flutter create` wrote, such as `macos/Runner/`, as they are, so you don't edit them. Most apps need nothing else.

When you need control over a piece the macro decides for you, the same work is available as separate rules, such as `flutter_macos_runner_lib_gen`, that you wire into rules_apple, rules_android or rules_cc yourself. Each platform section lists them in a collapsed block.

The iOS, macOS and Android macros tag the app `manual` unless you pass `tags`, so `bazel build //...` skips it and you build it by name. The Linux, Windows and web macros don't. An iOS or macOS app whose `tags` leave out `manual` is built by `//...` on a Mac, and reported as skipped on any other host, such as a Linux CI runner.

### App version

A Flutter project keeps its version in `pubspec.yaml`, or passes it to `flutter build`:

```yaml
# pubspec.yaml
version: 2.3.4+42
```

```sh
flutter build ios --build-name 2.3.4 --build-number 42
```

Here it is two attributes of the `flutter_application`:

```starlark
flutter_application(
    name = "my_app",
    # ...
    build_name = "2.3.4",
    build_number = "42",
)
```

Left out, they are `flutter create`'s `1.0.0` and `1`. The program reads them as `appBuildName` and `appBuildNumber` from `package:flutter/services.dart`, and every platform app built over the application puts them where that platform's own build does:

| Platform | `build_name` | `build_number` |
|---|---|---|
| Android | `versionName` | `versionCode`: a whole number from 1 to 2100000000 |
| iOS, macOS | `CFBundleShortVersionString`: numbers separated by periods, padded to three as `flutter build` pads them (`2.3` is `2.3.0`) | `CFBundleVersion`: numbers separated by periods |
| Web | `version` in `version.json` | `build_number` in `version.json` |
| Windows | The executable's version, `<build_name>+<build_number>`, and the first three of its four file version numbers: `MAJOR.MINOR.PATCH`, with an optional `-prerelease` | The fourth file version number: a whole number |

On iOS and macOS each key takes at most four numbers and 18 characters. On Windows each of the four file version numbers is at most 65535. Linux apps carry no version.

A value the platform can't use fails the build and says what the platform accepts. `flutter build` would change it without telling you: `0` becomes `1` on Android, `1.0-beta` becomes `1.0.0` on iOS, and a build number of `1.2` becomes `0` on Windows.

`flutter_android_app`, `flutter_ios_app`, `flutter_macos_app` and `flutter_windows_app` also take `build_name` and `build_number`. These must match the application's, or the build fails: the bundle would report one version and the program another. [`e2e/ios_example`](e2e/ios_example/BUILD.bazel) sets the same values on both.

For a version that changes with every build, such as a CI build number or a TestFlight upload's, pass it on the command line, as you would to `flutter build`:

```sh
flutter build ios --build-number 123
```

```sh
bazel build //app:ios --@rules_flutter//flutter:build_number=123
```

`--@rules_flutter//flutter:build_name` and `--@rules_flutter//flutter:build_number` replace every application's `build_name` and `build_number` for that build, as `flutter build`'s flags replace the pubspec's `version:`. The program reports the new version and every bundle built over the application carries it. A platform app's own `build_name` and `build_number`, which repeat the application's, follow the flag too, and so does a `flutter_apple_bundle_version` given the `application`. A value the platform can't use fails the build, naming the flag. A `flutter_test` keeps its own version, as `flutter test` takes neither flag. A change of version recompiles the program, as it does under `flutter build`.

To vary the version by configuration instead, give the application's arguments a `select()` over a `config_setting` of your own. `None` keeps the default:

```starlark
flutter_application(
    name = "my_app",
    # ...
    build_number = select({
        ":release": "42",
        "//conditions:default": None,
    }),
)
```

Each platform's own way of setting the version works too:

- **iOS, macOS:** `version`, an `apple_bundle_version` or `flutter_apple_bundle_version` target, the way to give the app's extensions its version (see [App extensions](#app-extensions)). Its values must be the application's, or the app's build fails. A `flutter_apple_bundle_version` given the same `application` takes them, flags included. Give your app extensions one of those rather than an `apple_bundle_version` stamped from `--embed_label`.
- **Android:** `android:versionCode` and `android:versionName` in your own manifest, or `versionCode` and `versionName` in `manifest_values`. Each must be the application's, or the build fails.
- **Web:** `version_json`, or a `web/version.json`, which `flutter_web_app` picks up. Its `version` and `build_number` must be the application's, `1.0.0` and `1` if it sets none, or the build fails.

These state their own values, which the flags don't change: built with a flag that gives the application another version, the app fails to build, naming both.

Use one way for each field. `version` beside the macro's own `build_name` or `build_number` fails the build, and so does a `manifest_values` key beside the matching argument.

On iOS and macOS, the `Info.plist` leaves the two version keys to the app's version. A literal `CFBundleShortVersionString` or `CFBundleVersion` that differs from it fails the build. The `$(FLUTTER_BUILD_NAME)` and `$(FLUTTER_BUILD_NUMBER)` that `flutter create` writes are fine, and so are Xcode's `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`.

### Flavors

With `flutter build`, a flavor is a flag, backed by Gradle product flavors and Xcode schemes:

```sh
flutter run --flavor paid
```

Here a flavor is a target. Give a `flutter_application` a `flavor`, declare one application per flavor, and put the platform targets of each beside it. This mirrors [`e2e/integration_test`](e2e/integration_test/BUILD.bazel):

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "app_paid",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    flavor = "paid",
    deps = [...],
)

flutter_macos_app(
    name = "macos_paid",
    application = ":app_paid",
    bundle_id = "com.example.myapp.paid",
    app_name = "My App Paid",
)

flutter_web_app(
    name = "web_paid",
    application = ":app_paid",
    app_name = "My App Paid",
)
```

`flavor` does what `flutter build --flavor` does in the Dart program:

- `appFlavor` (`package:flutter/services.dart`) is `'paid'`. Without `flavor` it is `null`. You can't set `FLUTTER_APP_FLAVOR` yourself: `defines` and `--dart-define` refuse it, as `flutter build` does.
- A pub package's `flutter: assets:` or `flutter: shaders:` entry with `flavors: [paid, ...]` is bundled into builds of that flavor, and left out of every other build, including those with no flavor.
- `flutter_bazel run -t //:macos_paid -d macos` runs the paid flavor. There is no `--flavor` flag, because the flavor is part of the target. Hot reload and hot restart keep it.

Everything else that differs between flavors is an attribute of that flavor's platform target:

| Macro | Attributes that usually differ per flavor |
|---|---|
| `flutter_android_app` | `application_id`, `app_name`, `manifest`, `resources` |
| `flutter_ios_app`, `flutter_macos_app` | `bundle_id`, `app_name`, `info_plist`, `app_icons`, `resources`, `entitlements` |
| `flutter_linux_app` | `application_id`, `app_name`, `window_title` |
| `flutter_windows_app` | `app_name` |
| `flutter_web_app` | `app_name`, `web_dir` |

rules_flutter adds no Gradle product flavors, Xcode schemes or CMake variables, and doesn't read `default-flavor` from the pubspec. A few more differences from `flutter build`:

- The app's own assets come from the application's `assets`, not from its pubspec, so a flavor's own assets go in that flavor's application. A library's flavor-only assets go in a small library that only that flavor's application depends on.
- Web bundles a flavor's `flavors:` assets and shaders, like the other platforms. `flutter build web` has no `--flavor` and bundles none of them.
- `flutter_test` takes `flavor` too, as `flutter test --flavor` does. The test sees `appFlavor`, and gets the pub assets and shaders whose `flavors:` name it. Without it, a test sees no `appFlavor` and no `flavors:` entry.

### macOS

You need Xcode. Run `flutter create --platforms=macos .` first, so that `macos/Runner/` exists.

```starlark
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    app_name = "My App",
)
```

```sh
bazel build //:my_app_macos
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_macos -d macos
```

The output is a `.app` bundle holding `FlutterMacOS.framework`, `App.framework` and `flutter_assets/`, and a `my_app_macos.zip` of it.

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `bundle_id` | The bundle identifier, as Xcode's `PRODUCT_BUNDLE_IDENTIFIER`. Required. |
| `app_name` | The bundle's name (`<app_name>.app`, and `$(PRODUCT_NAME)` in the `Info.plist`), which is the name in the menu bar and window title. Defaults to the target name. |
| `minimum_os_version` | Defaults to `"12.0"`, the macOS the prebuilt engine is built for. A lower value fails the build. |
| `info_plist` | Used in place of `macos/Runner/Info.plist`. |
| `build_name`, `build_number`, `version` | See [App version](#app-version). |
| `entitlements` | Used in place of the `flutter create` pair. By default the macro uses `macos/Runner/DebugProfile.entitlements` for debug and profile builds and `Release.entitlements` for the rest, as the Xcode project does. It fails if either file is missing. A signed app, one with a `provisioning_profile`, is signed with the entitlements Xcode gives it: its own, its `com.apple.application-identifier` (the profile's prefix and the bundle id), the profile's `com.apple.developer.team-identifier`, and `com.apple.security.get-task-allow` when the profile is a development profile, one that lists devices. Nothing else the profile grants is added. |
| `additional_entitlements` | Entitlement files merged into whichever file the build uses, in every mode. See [Release builds and permissions](#release-builds-and-permissions). |
| `app_icons` | Defaults to the `AppIcon.appiconset` in `macos/Runner/Assets.xcassets`. See [App icons](#app-icons). |
| `runner_deps` | `swift_library` targets linked into the runner. See [App Intents](#app-intents). |

Other arguments, such as `extensions` and `app_intents`, pass through to rules_apple's `macos_application`.

<details>
<summary>Composable rules</summary>

These are the pieces the macro assembles. This mirrors the Bazel-generated runner in [`e2e/macos_example`](e2e/macos_example/BUILD.bazel), which needs no `macos/Runner/`.

Give the app its version with a `flutter_apple_bundle_version` of the same `application`, which takes the version the program reports. rules_flutter doesn't see the `version` of a `macos_application` you write, so it can't check one that says otherwise. The generated `Info.plist` leaves the version keys to `version`, as `flutter create`'s does, and without one rules_apple fails on `$(FLUTTER_BUILD_NAME)`.

```starlark
load("@rules_apple//apple:macos.bzl", "macos_application")
load("@rules_flutter//flutter:macos.bzl",
    "MACOS_MINIMUM_OS_VERSION",
    "flutter_apple_bundle_version",
    "flutter_entitlements_merge",
    "flutter_macos_engine",
    "flutter_macos_app_framework_gen",
    "flutter_macos_info_plist_gen",
    "flutter_macos_menu_xib_gen",
    "flutter_macos_native_libs_gen",
    "flutter_macos_privacy_manifests_gen",
    "flutter_macos_registrant_gen",
    "flutter_macos_runner_lib_gen")

flutter_macos_app_framework_gen(name = "my_framework", application = ":my_app")
flutter_macos_registrant_gen(name = "my_registrant", application = ":my_app")
flutter_macos_engine(name = "my_engine")
flutter_macos_native_libs_gen(name = "my_native_libs", application = ":my_app")
flutter_macos_privacy_manifests_gen(name = "my_privacy_manifests", application = ":my_app")
flutter_macos_info_plist_gen(name = "my_info_plist", app_name = "My App")
flutter_macos_menu_xib_gen(name = "my_menu_xib", app_name = "My App")

# The application's version, which the program reports as appBuildName.
flutter_apple_bundle_version(name = "my_version", application = ":my_app")

flutter_macos_runner_lib_gen(
    name = "my_runner",
    # Links the app's plugins into the runner.
    application = ":my_app",
    registrant = ":my_registrant",
    engine = ":my_engine",
)

# rules_apple's `entitlements` takes one file. This merges more keys into it.
# A key in both files with different values fails the build.
# Also exported from flutter:ios.bzl.
flutter_entitlements_merge(
    name = "my_entitlements",
    base = "macos/Runner/Release.entitlements",
    additions = ["entitlements/Network.entitlements"],
)

macos_application(
    name = "my_macos_app",
    bundle_id = "com.example.myapp",
    minimum_os_version = MACOS_MINIMUM_OS_VERSION,
    additional_contents = {
        ":my_framework": "Frameworks",
        ":my_native_libs": "Frameworks",
        ":my_privacy_manifests": "Resources",
    },
    entitlements = ":my_entitlements",
    infoplists = [":my_info_plist"],
    resources = [":my_menu_xib"],
    version = ":my_version",
    deps = [":my_runner"],
)
```

</details>

### iOS

You need Xcode on a Mac with Apple silicon. Run `flutter create --platforms=ios .` first, so that `ios/Runner/` exists.

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_app")

flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
)
```

On an Apple silicon Mac, an iOS build is for the simulator unless you ask for a device. The simulator runs debug builds only, so build it with `-c dbg`. `flutter_bazel` does that for you, and runs the app in the simulator that is booted:

```sh
bazel build -c dbg //:my_app_ios
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_ios -d ios-simulator
```

The output is a `.app` bundle and a `my_app_ios.ipa` of it. A simulator build needs no signing identity: rules_apple signs it ad hoc, as Xcode and `flutter run` do. A device build needs one: see [Running on an iOS device](#running-on-an-ios-device).

That ad hoc signature is a step of every rebuild of the bundle. To skip it, add this line to your `.bazelrc`:

```bazelrc
build --features=apple.skip_codesign_simulator_bundles
```

The simulator runs an unsigned app, but APIs behind some entitlements, App Groups at least, stop working in it. A hot reload or restart after a Dart edit doesn't rebuild the bundle, so the line speeds up only the builds that do: a launch, or a restart that relaunches the app after a native edit.

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `bundle_id` | The bundle identifier, as Xcode's `PRODUCT_BUNDLE_IDENTIFIER`. Required. |
| `families` | Device families. Defaults to `["iphone"]`, where `flutter create` targets iPhone and iPad. An iPhone-only app runs in a small window on iPadOS. To add `"ipad"`, first remove the 76x76@1x icon from the icon set `flutter create` writes, because `actool` rejects it for an iPad app. |
| `app_name` | The bundle's name (`<app_name>.app`, and `$(PRODUCT_NAME)` in the `Info.plist`). Defaults to the target name. The name under the icon is the `CFBundleDisplayName` in `ios/Runner/Info.plist`. |
| `minimum_os_version` | Defaults to `"15.0"`, the iOS the prebuilt engine is built for. A lower value fails the build. |
| `info_plist` | Used in place of `ios/Runner/Info.plist`. Keep `UISceneDelegateClassName` as `$(PRODUCT_MODULE_NAME).SceneDelegate`, as `flutter create` writes it: the runner's module is named after the target, so `Runner.SceneDelegate` isn't found. |
| `build_name`, `build_number`, `version` | See [App version](#app-version). |
| `launch_storyboard` | Used in place of `ios/Runner/Base.lproj/LaunchScreen.storyboard`. |
| `entitlements` | Used in place of `ios/Runner/Runner.entitlements`, which the macro uses if it exists. `flutter create` writes none, and an app without one is fine. `False` ships none of the app's own even if the file exists (see [Running on an iOS device](#running-on-an-ios-device)). A signed app is signed with the entitlements Xcode gives it: its own, its `application-identifier` (the profile's prefix and the bundle id), and the profile's `com.apple.developer.team-identifier`, `beta-reports-active` and `get-task-allow` where the profile grants them. Nothing else the profile grants is added, so a capability the app uses, such as push or associated domains, has to be in its entitlements. See [Migrating from 0.1.0](#migrating-from-010) for keychain items saved before this. |
| `additional_entitlements` | Entitlement files merged into the app's, in every mode. With no `Runner.entitlements`, they are the app's entitlements. See [Release builds and permissions](#release-builds-and-permissions). |
| `provisioning_profile` | The profile a device build is signed with, usually a `local_provisioning_profile` target. Required for a device build, unused by a simulator build, so a `select()` may give `None` for the simulator. |
| `app_icons` | Defaults to the `AppIcon.appiconset` in `ios/Runner/Assets.xcassets`. See [App icons](#app-icons). |
| `runner_deps` | `swift_library` targets linked into the runner. See [App Intents](#app-intents). |

Other arguments, such as `extensions` and `app_intents`, pass through to rules_apple's `ios_application`.

Debug and profile builds add `NSBonjourServices` and `NSLocalNetworkUsageDescription` to the `Info.plist`, so the engine can advertise the Dart VM service on the local network, as `flutter build` does. Release builds leave them out. If the app needs local network access itself, declare both in `ios/Runner/Info.plist`. Your values are kept in every mode, and the VM service's entry is added to your `NSBonjourServices`.

<details>
<summary>Composable rules</summary>

These are the pieces the macro assembles. This mirrors the Bazel-generated runner in [`e2e/ios_example`](e2e/ios_example/BUILD.bazel), which needs no `ios/Runner/`.

As on macOS, give the app its version with a `flutter_apple_bundle_version` of the same `application`: rules_flutter can't check the `version` of an `ios_application` you write.

```starlark
load("@rules_apple//apple:ios.bzl", "ios_application")
load("@rules_flutter//flutter:ios.bzl",
    "IOS_DEFAULT_LAUNCH_STORYBOARD",
    "IOS_MINIMUM_OS_VERSION",
    "flutter_apple_bundle_version",
    "flutter_entitlements_merge",
    "flutter_ios_engine",
    "flutter_ios_app_framework_gen",
    "flutter_ios_dropped_frameworks_gen",
    "flutter_ios_info_plist_gen",
    "flutter_ios_native_frameworks_gen",
    "flutter_ios_privacy_manifests_gen",
    "flutter_ios_registrant_gen",
    "flutter_ios_runner_lib_gen")

flutter_ios_app_framework_gen(name = "my_framework", application = ":my_app")
flutter_ios_registrant_gen(name = "my_registrant", application = ":my_app")
flutter_ios_engine(name = "my_engine")
flutter_ios_privacy_manifests_gen(name = "my_privacy_manifests", application = ":my_app")

# Debug and profile builds also get the VM service's Info.plist keys.
flutter_ios_info_plist_gen(name = "my_info_plist", app_name = "My App")

# The application's version, which the program reports as appBuildName.
flutter_apple_bundle_version(name = "my_version", application = ":my_app")

# Frameworks for the app's native assets and `native_deps` libraries. Leave
# this out of `deps` below and the app builds and renders, then fails every
# native call at runtime.
flutter_ios_native_frameworks_gen(name = "my_native_frameworks", application = ":my_app")

# The frameworks above are every code asset that could ship. Outside debug
# builds, a link hook may drop some. The app carries the list, and the
# post-processor removes them before the app is signed.
flutter_ios_dropped_frameworks_gen(name = "my_dropped_frameworks", application = ":my_app")

flutter_ios_runner_lib_gen(
    name = "my_runner",
    # Links the app's plugins into the runner.
    application = ":my_app",
    registrant = ":my_registrant",
    engine = ":my_engine",
)

ios_application(
    name = "my_ios_app",
    bundle_id = "com.example.myapp",
    families = ["iphone"],
    minimum_os_version = IOS_MINIMUM_OS_VERSION,
    infoplists = [":my_info_plist"],
    launch_storyboard = IOS_DEFAULT_LAUNCH_STORYBOARD,
    resources = [":my_privacy_manifests"] + select({
        "@rules_flutter//flutter/private:dbg": [],
        "//conditions:default": [":my_dropped_frameworks"],
    }),
    ipa_post_processor = select({
        "@rules_flutter//flutter/private:dbg": None,
        "//conditions:default": "@rules_flutter//flutter:ios_code_asset_post_processor",
    }),
    version = ":my_version",
    deps = [":my_framework", ":my_native_frameworks", ":my_runner"],
)
```

</details>

#### Running on an iOS device

In Xcode you pick a team and a provisioning profile under Signing & Capabilities. Here the profile is an attribute of the app, `provisioning_profile`, and Xcode is still how you get one.

**Getting a profile.** You need a development profile that covers your `bundle_id` and lists your device, installed in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Getting one is an Apple Developer account operation, and the rules can't do it for you. Create it in the developer portal and double-click the download, or let Xcode's automatic signing make it from any project with the same bundle id:

```sh
xcodebuild -project <some>.xcodeproj -scheme <scheme> -configuration Debug \
  -destination generic/platform=iOS \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

The project can be a scratch one. The app you build with Bazel has no `.xcodeproj` and doesn't need one. `-allowProvisioningDeviceRegistration` adds the connected device to the profile.

**Naming the profile.** rules_apple's `local_provisioning_profile` finds an installed profile by its `Name`:

```starlark
# device/BUILD.bazel, in a git-ignored //device package
load("@rules_apple//apple:apple.bzl", "local_provisioning_profile")

local_provisioning_profile(
    name = "profile",
    profile_name = "iOS Team Provisioning Profile: *",
    tags = ["manual"],
)
```

The name isn't always `iOS Team Provisioning Profile: <bundle id>`. When Xcode covers your bundle id with the team's wildcard profile, as it does for the examples here, the name is `iOS Team Provisioning Profile: *`. To list the names of the profiles you have:

```sh
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -extract Name raw -
done
```

If several profiles have the name, rules_apple takes the newest. Its `team_id` attribute picks one team's. It doesn't skip expired profiles. Free "Personal Team" profiles expire after seven days, so when a device refuses an app that built, make a fresh profile the same way. A build that fails with `no provisioning profile was found named '...'` has no profile of that name at all.

**The device target.** Keep the device app in your committed BUILD file, beside the simulator one. The only difference is the profile:

```starlark
flutter_ios_app(
    name = "my_app_ios_device",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    provisioning_profile = "//device:profile",
)
```

Put only the `local_provisioning_profile` in the git-ignored package, because it is the one fact that differs between developers. A whole device app in an ignored package is invisible to review and CI, and drifts from the simulator app. If you assemble the app from the composable rules, give the device `ios_application` the same `deps` as the simulator one.

Without `provisioning_profile`, a device build fails during analysis. That holds for a build you don't sign as well (see "Signing later" below), because the bundle's `embedded.mobileprovision`, and the identifiers its entitlements are signed with, come from the profile.

`flutter_ios_app` is `manual` by default, so `bazel build //...` on a fresh clone doesn't load the missing `//device` package. `bazel query 'deps(//...)'` still follows the label into it. If you want that query to work on a fresh clone, point `provisioning_profile` at a `label_flag` whose default target fails with the setup steps, and set the flag to `//device:profile` in `.bazelrc.user`. [`e2e/ios_example`](e2e/ios_example/BUILD.bazel) does this.

**Running it.** `-d ios` runs on the attached device, and `-d ios:<id>` on a particular one. [`flutter_bazel devices`](#choosing-a-device) lists each device with its id. The tool builds the app for the device with `-c dbg`:

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_ios_device -d ios
```

To build it yourself, ask for the device's CPU:

```sh
bazel build //:my_app_ios_device -c opt --ios_multi_cpus=arm64
```

The first time a new app runs, the device asks for Local Network permission. Allow it, or `flutter_bazel` can't find the app's VM service. [Physical iOS devices](#physical-ios-devices) covers how the tool connects and what to check when it can't.

Each iOS example in `e2e/` has a `device.example/` folder. Copy it to `device/`, rename `device/BUILD.bazel.example` to `device/BUILD.bazel`, set `profile_name` to your profile's name, and add `common --//:device_profile=//device:profile` to the example's `.bazelrc.user`.

**Entitlements your profile can't grant.** A simulator build isn't checked against a profile. A device build is signed against one, and an entitlement the profile doesn't grant fails it:

```
Target "@@//:__my_app_ios_device_app" uses entitlements with the "aps-environment" key,
but the profile does not have this key
```

The target it names is the rules_apple app behind yours. `aps-environment` is the usual cause. Xcode writes it into `ios/Runner/Runner.entitlements` when you turn on Push Notifications, it stays after the code that used it is gone, and a team wildcard profile can't grant it, because push needs a registered App ID. `flutter_ios_app` picks the file up because it is on disk, so nothing in your BUILD file mentions it. Pass `entitlements = False` on the device target to ship none of its own:

```starlark
flutter_ios_app(
    name = "my_app_ios_device",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    entitlements = False,
    provisioning_profile = "//device:profile",
)
```

Don't delete the file. It is the right entitlements for a profile that does grant push, and Xcode will write it again.

**Signing later.** `flutter build ios --no-codesign` builds an app with no signing identity at hand, for a CI that signs elsewhere. The equivalent here is rules_apple's sign-later flow. Build the device app with `--features=disable_legacy_signing`, which leaves the `.ipa` unsigned, and take the `combined_dossier_zip` output group:

```sh
bazel build //:my_app_ios_device -c opt --ios_multi_cpus=arm64 \
    --features=disable_legacy_signing \
    --output_groups=+combined_dossier_zip
```

The dossier holds what rules_apple's `dossier_codesigningtool` needs to sign the bundle on a machine that has the identity. The profile is still required, because it supplies the bundle's `embedded.mobileprovision` and the identifiers its entitlements are signed with. Xcode's `--no-codesign` leaves the profile out too, and rules_apple has no equivalent of that.

#### Checking an iOS release build

You can't run a release iOS build without a provisioning profile, because only a device runs one. That matters because release-only problems, such as [missing permissions](#release-builds-and-permissions), show up when the app runs, not when you read the code.

- **Device, `-c opt`.** The real thing. Needs a provisioning profile.
- **Simulator, `-c opt`, or the default `fastbuild`.** Fails during analysis with "The iOS simulator runs debug builds only". The simulator engine runs kernel under the JIT and can't load an AOT snapshot, so the app would launch to a blank white screen, with only `Engine run configuration was invalid` in the system log. `flutter build ios --simulator --release` refuses it too.

So use `-c dbg` on the simulator, and a device for release. A test that needs a simulator app under a plain `bazel test //...` gets one from `flutter_ios_simulator_build`, which builds its `targets` with `-c dbg` whatever the command line says. Name it in a test's `data`, or use `flutter_ios_simulator_build_test` in place of a `build_test`:

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_simulator_build_test")

flutter_ios_simulator_build_test(
    name = "ios_app_build_test",
    targets = [":my_app_ios"],
)
```

### App icons

`flutter_ios_app` and `flutter_macos_app` ship the icon in your tree, as `flutter build` does. They pass the `AppIcon.appiconset` from `ios/Runner/Assets.xcassets` or `macos/Runner/Assets.xcassets` to rules_apple's `app_icons`, which tells `actool` which set in the catalog is the app icon. Listing the same PNGs under `resources` doesn't do that.

To ship a different icon, pass `app_icons` the files of an `.appiconset`, or of an Icon Composer `.icon` bundle. An `.icon` bundle needs Xcode 26 or later. Name one or the other: rules_apple fails a build given both. With `minimum_os_version` at 26 or above, rules_apple accepts only an `.icon` bundle. `app_icons = []` ships no icon.

If `Assets.xcassets/AppIcon.appiconset` is missing from `ios/Runner/` or `macos/Runner/`, that app ships the generic icon, with no warning. If one platform shows your icon and the other doesn't, check that platform's catalog first.

A macOS icon follows Apple's grid: the rounded shape sits inset at about 824 points of the 1024-point canvas, so that it lines up with other Dock icons. A full-bleed square looks too big. The rules pass the catalog through as it is.

The `Info.plist` `flutter create` writes for macOS has an empty `CFBundleIconFile` for Xcode to fill in. `macos_application` writes its own value from the catalog, and rules_apple refuses two different values for one key, so the macro drops the empty one. A plist that names a real icon file is left alone, and fails the build if you also have an icon set.

### App Intents

To ship App Intents, give the Swift library to two attributes. `runner_deps` links it into the runner, so its code is in the binary. rules_apple's `app_intents`, which the macros pass through, extracts its metadata into the bundle: `Contents/Resources/Metadata.appintents` on macOS, `Metadata.appintents` at the bundle root on iOS. Each does only its own half. Given to only one, the app ships metadata with no code, or code the system never learns about.

```starlark
swift_library(
    name = "intents",
    srcs = ["Intents/PingIntent.swift"],
    # rules_apple's app_intents fails a library that doesn't link AppIntents.
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

[`e2e/macos_example`](e2e/macos_example/BUILD.bazel) and [`e2e/ios_example`](e2e/ios_example/BUILD.bazel) each build such an app, and check that the bundle's metadata names the intent and the binary links it.

When `appintentsmetadataprocessor` fails on a schema validation error, rules_apple's wrapper reports `version.json.sorted: No such file or directory` and hides the processor's own message. Run the processor by hand to read it.

### App extensions

Widgets, Control Center controls, share extensions and other app extensions are written in Swift and built with rules_apple's `ios_extension` or `macos_extension`. Pass them to `flutter_ios_app` or `flutter_macos_app` as `extensions`, and rules_apple embeds each `.appex` in `PlugIns/` on iOS or `Contents/PlugIns/` on macOS. Flutter doesn't run in an extension: an extension can't link the Flutter engine or Dart code from these rules. To share data with the app, use an App Group.

```starlark
load("@rules_apple//apple:ios.bzl", "ios_extension")
load("@rules_flutter//flutter:ios.bzl", "flutter_apple_bundle_version", "flutter_ios_app")
load("@rules_swift//swift:swift.bzl", "swift_library")

# The application's version, for the app and its extension.
flutter_apple_bundle_version(
    name = "version",
    application = ":my_app",
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
    version = ":version",
)
```

What an extension needs:

- **The app's version.** rules_apple gives an extension no version unless you pass one, and the system expects an extension's version to match its app's. Declare the version once and pass it as the `version` of the app and of each extension. `flutter_apple_bundle_version`, from `flutter:ios.bzl` or `flutter:macos.bzl`, takes the version of the `application` you give it, so the bundles and `appBuildName` agree. rules_apple's `apple_bundle_version` works too, if it gives the application's version: the app's build fails on any other.
- **A bundle id under the app's**, such as `com.example.myapp.widgets`.
- **An Info.plist with the bundle keys.** Besides `NSExtension` and its `NSExtensionPointIdentifier`, give `CFBundleName` (`$(PRODUCT_NAME)`), `CFBundleExecutable` (`$(EXECUTABLE_NAME)`), `CFBundleIdentifier` (`$(PRODUCT_BUNDLE_IDENTIFIER)`) and a `CFBundlePackageType` of `XPC!`. Without them the simulator refuses to install the app.
- **Its App Intents.** A control's button, an interactive widget and a configurable widget each run an App Intent in the extension, so give the library to the extension's `app_intents` as well as its `deps`. rules_apple 5.4.0's `macos_extension` has no `app_intents` attribute; its main branch has it, and no release does yet. Until one does, pin rules_apple to a commit that has it in your own `MODULE.bazel`, as [`e2e/macos_example/MODULE.bazel`](e2e/macos_example/MODULE.bazel) does, and drop the pin once you depend on a release with it. It doesn't come with rules_flutter, because only the root module's overrides apply:

  ```starlark
  git_override(
      module_name = "rules_apple",
      commit = "7610d32139667a06a77d448e6b24b1a34c3e8d2e",
      remote = "https://github.com/bazelbuild/rules_apple.git",
  )
  ```
- **On macOS, the sandbox.** macOS loads a widget or share extension only if its entitlements include `com.apple.security.app-sandbox`.
- **Visibility** to the app's package, if the extension lives elsewhere. `flutter_ios_app` and `flutter_macos_app` have to sit in the package that holds `ios/Runner/` or `macos/Runner/`.

An extension can have a higher `minimum_os_version` than its app. Each bundle records its own minimum, and the system leaves the extension out on an older OS. Control Center controls need iOS 18 or macOS 26. Either raise the extension's minimum to that, or include the control in the `WidgetBundle` behind `if #available`, as the examples do.

**App Groups.** Give each extension an `entitlements` file with `com.apple.security.application-groups`, and merge the same file into the app with `additional_entitlements`. A simulator build isn't checked against a profile, so the group works there.

On a device, and on macOS, the group depends on how each bundle is signed:

- A profile grants an App Group only if it was made for an explicit App ID that has the group. So an iOS device build with a group needs an App ID and a profile for the app and for each extension, registered in the developer portal.
- The team wildcard profile, `iOS Team Provisioning Profile: *`, covers any bundle id but grants no App Group, and a device build that asks for an entitlement its profile lacks fails. [`e2e/ios_example`](e2e/ios_example/BUILD.bazel)'s device variant, `:app_extensions_device`, is signed with the wildcard, and leaves the group out of the app and its extensions for that reason.
- On macOS, a `group.` identifier needs a profile that lists the group. A team-prefixed one, `<TEAM ID>.name`, needs only a signature from that team, which the wildcard `Mac Team Provisioning Profile: *` gives. An app signed ad hoc gets neither: it builds and its extensions register, but writes into the group container are refused.

**Signing extensions.** rules_apple signs each extension as its own target, so the app's `provisioning_profile` doesn't reach its extensions. Give each extension its own `provisioning_profile`. On macOS, an extension without one is signed with the build's `--@rules_apple//apple/build_settings:signing_certificate_name`, or ad hoc if that isn't set. Then it has no team, and loses its App Group even inside a team-signed app. `codesign --verify --deep --strict` passes on such an app, so it doesn't catch a missing profile. Compare `TeamIdentifier` across the bundles instead.

A macOS `local_provisioning_profile` needs `profile_extension = ".provisionprofile"`. Without it, rules_apple looks for a `.mobileprovision`.

[`e2e/macos_example`](e2e/macos_example/BUILD.bazel)'s `:app_extensions_team` shows the team-prefixed group working. The app and each extension are signed with the Mac wildcard, and the app writes into its group container, which `:verify_macos_team_signing_test` checks. Because the group carries the team id, its profile and entitlements file live in a git-ignored `//device` package made from `device.example/`. The app reaches them through the `//:device_profile` and `//:device_app_group` flags, which `.bazelrc.user` sets to `//device:profile` and `//device:AppGroup.entitlements`.

`e2e/ios_example` and `e2e/macos_example` each build an app with a widget extension, holding a widget and a control, and a share extension. They check where each extension lands, what each declares, and that all of them share one App Group.

### Android

`flutter_android_app` builds an APK from your `flutter_application`. It reads `android/app/src/main/` as `flutter create --platforms=android .` writes it: the manifest, the resources and the Kotlin or Java runner. Without that directory it generates a manifest whose activity is Flutter's own `FlutterActivity`.

Here are the parts of `android/app/build.gradle.kts` that matter to the build:

```kotlin
// android/app/build.gradle.kts
android {
    namespace = "com.example.my_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.example.my_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
}
```

And the same app in Bazel:

```starlark
# BUILD.bazel
load("@rules_flutter//flutter:android.bzl", "flutter_android_app")

flutter_android_app(
    name = "my_app_android",
    application = ":my_app",
    application_id = "com.example.my_app",   # applicationId
    # Optional. namespace; defaults to application_id.
    namespace = "com.example.my_app",
    # Optional. minSdk; defaults to 24, as flutter.minSdkVersion.
    min_sdk_version = "24",
    # Optional. targetSdk; defaults to 36, as flutter.targetSdkVersion.
    target_sdk_version = "36",
)
```

`versionCode` and `versionName` come from the `flutter_application`'s `build_number` and `build_name`, as Gradle takes them from the pubspec's `version:` (see [App version](#app-version)). `compileSdk` and `ndkVersion` are set once for the whole build in `MODULE.bazel`, as the next section shows.

Build it for an arm64 phone, or run it on a connected device with hot reload:

```sh
bazel build //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_android -d android
```

The APK is `bazel-bin/my_app_android.apk`. `flutter_android_app` is tagged `manual` by default, so `bazel build //...` skips it. Build it by name, or pass `tags = []`. [Choosing ABIs](#choosing-abis) explains the platform flag, and how to set it once in `.bazelrc`.

rules_android's `bazel mobile-install` works too: it builds the app, installs it on the device `ANDROID_SERIAL` names (or the only one attached), with the `adb` on your PATH, and launches it.

```sh
bazel mobile-install //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a
```

It installs the app as split APKs, and a later run reinstalls only the splits that changed. A Dart edit still rebuilds `libapp.so` (under `-c dbg`, the kernel in the assets) and relaunches the app, losing its state; `flutter_bazel run` hot-reloads it instead. rules_android puts every asset in the base split, so under `-c dbg` a Dart edit reinstalls the base, kernel included (about 100 MB), which can take longer than an `adb install -r` of the APK. An `android_binary` of your own needs `custom_package` for mobile-install, as in the composable rules below, unless its BUILD file is under a `java/` directory; without it, mobile-install stops at analysis with "Unable to infer Java package".

#### Setting up the Android SDK and NDK

Add these lines to `MODULE.bazel`, below `rules_flutter`'s `bazel_dep`:

```starlark
bazel_dep(name = "rules_android", version = "0.8.1")
bazel_dep(name = "rules_android_ndk", version = "0.1.5")

# rules_android_ndk 0.1.5 links arm64 libraries for 4 KB pages: see "16 KB
# memory pages" below.
git_override(
    module_name = "rules_android_ndk",
    commit = "9946c72d5b617115d34dc2efb334f829c558a87b",
    remote = "https://github.com/bazelbuild/rules_android_ndk.git",
)

bazel_dep(name = "hermetic_android_toolchains", version = "0.5.0", dev_dependency = True)

android = use_extension("@hermetic_android_toolchains//:extensions.bzl", "android", dev_dependency = True)

# compileSdk, and the build tools.
android.sdk(
    build_tools_version = "35.0.0",
    version = "35",
)

# ndkVersion. The NDK builds your C/C++ code for Android and strips the native
# libraries an APK or AAR packages, as a Gradle build does. `api_level` is your
# app's `min_sdk_version`.
android.ndk(
    api_level = 24,
    version = "r28c",
)
use_repo(android, "androidndk", "androidsdk")

# Make every module's `@androidsdk` and `@androidndk` (rules_android's,
# rules_android_ndk's, rules_flutter's) these two.
rules_android_sdk = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension",
    dev_dependency = True,
)
override_repo(rules_android_sdk, "androidsdk")

rules_android_ndk = use_extension(
    "@rules_android_ndk//:extension.bzl",
    "android_ndk_repository_extension",
    dev_dependency = True,
)
override_repo(rules_android_ndk, "androidndk")

register_toolchains(
    "@androidndk//:all",
    "@androidsdk//:all",
    dev_dependency = True,
)
```

Then read the licences of the Android SDK and NDK. Once you accept them, add these lines to `.bazelrc`, naming the versions you accepted:

```bazelrc
common --repo_env=ACCEPTED_ANDROID_SDK_LICENSE_VERSION=35
common --repo_env=ACCEPTED_ANDROID_NDK_LICENSE_VERSION=r28c
```

Without them, the build stops while fetching and names the line to add:

```
Before using the hermetic Android SDK toolchain you must read and accept the license for the current version. Once you have done so, add this in your '.bazelrc':

common --repo_env=ACCEPTED_ANDROID_SDK_LICENSE_VERSION=35

Current ACCEPTED_ANDROID_SDK_LICENSE_VERSION value was unset.
```

[hermetic_android_toolchains](https://github.com/keith/hermetic_android_toolchains) downloads the SDK platform, build tools, platform tools and NDK of the versions you name, and checks each against its checksum. Nothing needs to be installed, and every machine and CI runner builds with the same tools. It has downloads for macOS, Linux x86_64 and Windows x86_64 hosts, the hosts Google publishes the NDK for. `r28c` (28.2.13676358) is the NDK Flutter's Gradle plugin builds with.

On a Mac the downloads are about 1.1 GB, 950 MB of it the NDK, which unpacks to 2.8 GB. Bazel keeps the archives in its repository cache and the unpacked NDK in its repository contents cache, which every workspace on the machine shares. Each workspace's output base holds its own 350 MB copy of the SDK.

**Keep `rules_flutter`'s `bazel_dep` above `rules_android`'s, or declare the Go SDK yourself.** rules_android builds some of its tools with Go, using the first Go SDK the module graph declares: your module's own, then each dependency's in the order your `MODULE.bazel` names them. rules_android 0.8.1 declares Go 1.22.4. That is too old for the Gazelle that comes with rules_go 0.63.0 and newer, which rules_flutter needs because older rules_go fails to build Go's standard library under the [path mapping](#bazelrc) above. rules_flutter declares a newer Go, which rules_go uses only when your `MODULE.bazel` names rules_flutter first. With rules_android named first, every Android build fails during analysis with `go: go.work requires go >= 1.24.12 (running go 1.22.4; GOTOOLCHAIN=local)`. To make the order irrelevant, declare the SDK in your own `MODULE.bazel`, which takes precedence over both:

```starlark
bazel_dep(name = "rules_go", version = "0.64.2")

go_sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk")
go_sdk.download(version = "1.27.3")
```

**Set the NDK's `api_level` to the app's `min_sdk_version`**, as Gradle compiles native code at `minSdk`. Your `cc_library` code (an FFI library, a plugin's C code) is built against that level. At a higher level it can call functions that older devices lack. Such a library installs on an older device, then fails to load there with an unresolved symbol. hermetic_android_toolchains defaults to 31.

The androidx and Kotlin jars the app links come pinned by rules_flutter's own lock. An app whose plugins declare no Maven artifacts needs nothing more. [Maven dependencies](#maven-dependencies) covers one whose plugins, or whose own Android code, do.

#### Using an installed SDK and NDK

rules_android and rules_android_ndk can use an SDK and NDK installed on the machine instead, found through environment variables. In `MODULE.bazel`, replace everything from `hermetic_android_toolchains` down with:

```starlark
android_ndk_repository_extension = use_extension(
    "@rules_android_ndk//:extension.bzl",
    "android_ndk_repository_extension",
)

# Your app's `min_sdk_version` (24 unless you set it).
android_ndk_repository_extension.configure(api_level = 24)
use_repo(android_ndk_repository_extension, "androidndk")

register_toolchains("@androidndk//:all")

# compileSdk. Without it, the newest Android platform installed on the machine.
android_sdk_repository_extension = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension",
)
android_sdk_repository_extension.configure(api_level = 35)
use_repo(android_sdk_repository_extension, "androidsdk")
```

Set the SDK's `api_level` to a platform you have installed. Left out, rules_android compiles against the newest one on the machine, so two machines can build the same app differently. A newer `android.jar` can, for instance, mark a method `@Nullable` that a plugin's Kotlin calls, and fail its compile. rules_android_ndk's `api_level` defaults to 31. Only the root module's `configure` counts. A dependency's is ignored.

Bazel reads two variables while it fetches:

| Variable | Value | Read by |
|---|---|---|
| `ANDROID_HOME` | The SDK root, for example `~/Library/Android/sdk`. | rules_android |
| `ANDROID_NDK_HOME` | A versioned NDK directory, for example `$ANDROID_HOME/ndk/28.2.13676358`. | rules_android_ndk |

`ANDROID_NDK_HOME` has to name the versioned directory, not the `ndk/` folder above it. The parent fails with a message that mentions neither the variable nor the mistake:

```
Error in readdir: can't readdir(), not a directory:
  .../Android/sdk/ndk/toolchains/llvm/prebuilt/darwin-x86_64
```

Every build needs `ANDROID_NDK_HOME`, not only Android ones. `register_toolchains("@androidndk//:all")` has Bazel fetch the `@androidndk` repository when it resolves toolchains, so a web build, for one, stops the same way without it. The downloaded NDK above has no such cost: its `@androidndk` is a small repository that points at the NDK, and a web build doesn't download the NDK itself.

With `ANDROID_NDK_HOME` unset, the build stops while fetching:

```
ERROR: An error occurred during the fetch of repository
  'rules_android_ndk++android_ndk_repository_extension+androidndk':
  Error in fail: Either the ANDROID_NDK_HOME environment variable or the
  path attribute of android_ndk_repository must be set.
```

You can export the variables in your shell. To set them in `.bazelrc`, use `--repo_env`. `--action_env` reaches only build actions, which run after the fetch:

```bazelrc
common --repo_env=ANDROID_HOME=/path/to/Android/sdk
common --repo_env=ANDROID_NDK_HOME=/path/to/Android/sdk/ndk/28.2.13676358
```

For [remote execution](#remote-execution), use the downloaded NDK. An installed NDK's toolchains match any execution platform.

#### Building on Windows

rules_android 0.8.1 starts its tool JVMs with an initial heap as large as their cap: `-Xms3G` for resource processing, and `-Xms8g` for desugaring, D8 and R8. A JVM commits its initial heap as it starts. Windows counts that against RAM plus the pagefile whether or not the JVM uses it, so on a 16 GB machine a few of these JVMs at once fail the build with `There is insufficient memory for the Java Runtime Environment to continue` and `The paging file is too small for this operation to complete`.

rules_android 0.8.1 also puts an `-A` (assets) and an `-R` (compiled resources) argument on the `aapt2 link` command line for every library the app links. With about a hundred libraries, which a few plugins bring, that passes Windows' limit of 32,767 characters, and resource packaging fails with `CreateProcess error=206, The filename or extension is too long`.

Apply `rules_android_no_initial_heap.patch` and `rules_android_aapt2_command_length.patch`, as [Fixes to other rulesets](#fixes-to-other-rulesets) says. The first keeps each heap cap and drops only the initial sizes. The second writes the `-R` list to a file once it is long, and leaves out asset directories that hold nothing to package. macOS and Linux build without them.

#### Choosing ABIs

An APK's ABIs are the platforms of `--@rules_android//flags:android_platforms`, as for any rules_android `android_binary`. One platform builds an APK for that ABI. Several build one APK for all of them, like the fat APK `flutter build apk` makes.

```sh
# arm64 phones
bazel build //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a

# x86_64 emulators
bazel build //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:x86_64

# 32-bit ARM phones
bazel build //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:armeabi-v7a

# one APK for all three, as `flutter build apk` makes by default
bazel build //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:armeabi-v7a,@rules_android//:arm64-v8a,@rules_android//:x86_64
```

`android_binary` builds its dependencies once for each platform, and packages what each build brings. So the Flutter engine, the app's `libapp.so`, the native libraries in your plugins' AARs and any C/C++ deps each arrive for every ABI.

Name the platforms exactly as shown. rules_android reads the flag and resolves each label from its own repository, so a platform of your own repository, or one of `@rules_flutter`, is not found. rules_android packages a platform's native libraries into `lib/<platform name>/`, which is why its platforms are named for their ABI. The flag names `@rules_android`, so your root `MODULE.bazel` needs the `bazel_dep` on rules_android from the setup above. The engine for each ABI comes with rules_flutter, and nothing of it goes in your `use_repo`.

Put the platforms you usually build for in `.bazelrc`, with a config for the others:

```bazelrc
common --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a
common:android-emulator --@rules_android//flags:android_platforms=@rules_android//:x86_64
common:android-fat --@rules_android//flags:android_platforms=@rules_android//:armeabi-v7a,@rules_android//:arm64-v8a,@rules_android//:x86_64
```

Without the flag, rules_android builds for `--platforms`, which is your machine. The engine and the Flutter bundle are incompatible with it, so the build fails with "incompatible", naming the platform that did not satisfy the constraint. `bazel build //...` skips them instead, along with whatever depends on them. `flutter_bazel run -d android` asks the device for its ABI and passes the matching platform itself.

To build an app for fixed ABIs whatever the command line says, as a test of the APK does, wrap it in [`flutter_android_build`](#flutter_android_build).

#### Maven dependencies

The androidx and Kotlin jars the runner and plugins compile against come from `@rules_flutter_maven`, rules_flutter's own rules_jvm_external repository. It is one resolution of the app's Android libraries, as Gradle makes one per app. rules_flutter declares the embedding's artifacts in it, with a lock of its own. An app that needs no other artifacts uses that lock. Each jar is fetched by checksum and kept in Bazel's repository cache, so a fresh output base or CI runner doesn't download it again.

When your plugins declare Maven artifacts, or your own Android code (a `kt_android_library` beside the app, say) needs some, declare an install of the same name in your root `MODULE.bazel`, with the artifacts and a lock file of your own:

```starlark
bazel_dep(name = "rules_jvm_external", version = "7.2")

maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
maven.install(
    name = "rules_flutter_maven",
    artifacts = ["androidx.browser:browser:1.9.0"],
    known_contributing_modules = ["rules_flutter"],
    lock_file = "//:rules_flutter_maven_install.json",
    repositories = [
        "https://maven.google.com",
        "https://repo1.maven.org/maven2",
    ],
)
use_repo(maven, "rules_flutter_maven")
```

Then create the lock and fill it:

```sh
touch rules_flutter_maven_install.json
REPIN=1 bazel run @rules_flutter_maven//:pin
```

rules_jvm_external merges your artifacts with rules_flutter's into the one resolution, and the lock pins both. Your code depends on them by the labels rules_jvm_external gives every artifact, such as `@rules_flutter_maven//:androidx_browser_browser`. Don't depend on another repository's copy of a library the app links. The build fails when one Maven library reaches the app from two repositories (see [Plugins' Maven dependencies](#plugins-maven-dependencies)).

- `known_contributing_modules` lists the other modules whose artifacts join yours. Without it, rules_jvm_external prints a notice naming them each time it evaluates the extension. With it, only the listed modules contribute, so a module you add later that declares artifacts for `rules_flutter_maven` has to be added to the list.
- `repositories` replaces the default, which is Maven Central alone and lacks the androidx artifacts.

Run `REPIN=1 bazel run @rules_flutter_maven//:pin` again after you change the artifacts or bump rules_flutter. The build fails until you do. rules_android's own tools resolve in its own repository, `@rules_android_maven`, with the lock it ships, and need nothing from you. [`e2e/plugin_example/MODULE.bazel`](e2e/plugin_example/MODULE.bazel) is a worked example for plugins, and [`e2e/android_example/MODULE.bazel`](e2e/android_example/MODULE.bazel) for an app's own Kotlin code.

#### Core library desugaring

A Gradle-built Flutter app has no core library desugaring: it is off until the app sets `isCoreLibraryDesugaringEnabled`. rules_android turns it on for every `android_binary` unless told otherwise. It rewrites calls to `java.time`, `java.util.stream` and other Java APIs newer than the app's minimum SDK onto a backport (desugar_jdk_libs, the `j$.*` classes). The whole backport goes into the APK and the App Bundle, about 2.6 MB of dex, and R8 doesn't shrink it. The Flutter embedding and the androidx libraries it uses don't need it at minimum SDK 24. Turn it off in `.bazelrc`:

```bazelrc
common --@rules_android//flags:desugar_java8_libs=false
```

It is a build-wide rules_android flag, so your project sets it and `flutter_android_app` can't. Leave it on if your own Android code or a plugin's calls one of those APIs. A plugin that does tells you in its setup to enable `isCoreLibraryDesugaringEnabled`.

#### 16 KB memory pages

Android 15 introduced devices with 16 KB memory pages. Such a device refuses a native library whose segments are aligned for 4 KB pages, and the app dies on launch. Google Play requires 16 KB support of apps that target Android 15 or later. A Gradle build gets 16 KB alignment from NDK r28 and later.

Bazel links an Android app's C/C++ code (the application's `native_deps`, its code assets, its plugins' native code and the `cc_library` targets in `deps`) with the Android C/C++ toolchain, and rules_flutter leaves the alignment to it. rules_android_ndk 0.1.5's toolchain, which the downloaded NDK's toolchains are also made from, links every arm64 library for 4 KB pages, whatever the NDK. Upstream fixed it in commit `efc0c191`, which no release has yet. Until one does, pin rules_android_ndk to a commit of its main branch that has the fix, below its `bazel_dep` in `MODULE.bazel`, as [Setting up the Android SDK and NDK](#setting-up-the-android-sdk-and-ndk) does:

```starlark
git_override(
    module_name = "rules_android_ndk",
    commit = "9946c72d5b617115d34dc2efb334f829c558a87b",
    remote = "https://github.com/bazelbuild/rules_android_ndk.git",
)
```

Drop it once you depend on a release with the fix. A toolchain of your own that links for 16 KB pages does as well. A 16 KB-aligned library loads on a 4 KB device too.

For arm64-v8a and x86_64, the build checks the native libraries the application and its plugins bring, including prebuilt ones inside the plugins' AARs. It fails, naming the library, when one is aligned for 4 KB pages, or when its `GNU_RELRO` segment ends partway through a 16 KB page that holds writable data after it. Such a library loads, then crashes when it writes that data. These are the two checks of Android's [16 KB page size guide](https://developer.android.com/guide/practices/page-sizes). With rules_android_ndk 0.1.5 as released, any C/C++ code an Android app builds fails the first.

An app that doesn't need 16 KB support can turn both checks off with `--@rules_flutter//flutter:allow_4kb_aligned_native_libraries`. That is an app that runs only on 4 KB devices, or one that sets `android:pageSizeCompat` for Android 16's page size compatibility mode.

`--norun_validations` skips the check of the plugins' libraries and not that of the application's own (`libapp.so`, `native_deps` and code assets). Those are checked as a step of packaging them, so that the check runs only where an APK takes them, and not again for the copy `android_binary` builds for its assets. Use the flag above to turn it off.

#### `flutter_android_app` attributes

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `application_id` | The application id, Gradle's `applicationId`, for example `"com.example.myapp"`. Required. |
| `namespace` | The package the runner's code declares, Gradle's `namespace`, and the package of the app's `R` class (the `android_binary`'s `custom_package`), as AGP makes it. Relative class names in the manifest (`.MainActivity`, `.sub.Receiver`, `MainActivity`) are written out in full against it, as AGP does. Defaults to `application_id`. |
| `app_name` | The `android:label` of the manifest the macro generates when there is no `android/app/src/main/AndroidManifest.xml`. Defaults to the target name. A `flutter create` manifest sets its own label, and this is unused. |
| `min_sdk_version` | Gradle's `minSdk`. Defaults to `"24"`, Flutter's `flutter.minSdkVersion` and the engine's own minimum. |
| `target_sdk_version` | Gradle's `targetSdk`. Defaults to `"36"`, as `flutter.targetSdkVersion`. |
| `build_name` | `versionName`. Defaults to the `flutter_application`'s, which defaults to `"1.0.0"`. See [App version](#app-version). |
| `build_number` | `versionCode`. Defaults to the `flutter_application`'s, which defaults to `"1"`. |
| `manifest_values` | Values for `${...}` placeholders in the manifest, as `android_binary` takes them. `applicationId`, `minSdkVersion` and `targetSdkVersion` come from the attributes above and can't be set here. `versionCode` and `versionName` can, while `build_number` and `build_name` are unset, and must then be the `flutter_application`'s. |
| `manifest` | A manifest you wrote yourself, used as it is. Its `${...}` placeholders, such as `${applicationName}`, are not substituted, so don't pass `flutter create`'s manifest here. The macro finds that one itself. With `manifest`, the macro also doesn't look for resources or runner sources under `android/app/src/main/`. |
| `debug_manifest` | A variant manifest whose permissions are merged into `-c dbg` builds only. `None` (the default) uses `android/app/src/debug/AndroidManifest.xml` if it exists. A label uses that file instead. `False` turns variant handling off. |
| `profile_manifest` | The same for profile builds, from `android/app/src/profile/AndroidManifest.xml`. |
| `permissions` | Permissions added to the manifest in every compilation mode, for example `["android.permission.INTERNET"]`. See [Release builds and permissions](#release-builds-and-permissions). |
| `resources` | Resource files added to those found under `android/app/src/main/res/`. |
| `deps` | Android libraries linked into the APK, such as a `kt_android_library` of your own. A plugin written in the workspace goes here as its `flutter_android_plugin_library`. The plugin registrant compiles against these too, so the plugin is both packaged and registered. Pub plugins arrive through the pub repository instead. |
| `proguard_specs` | The R8 configuration. By default a release build (`-c opt` without `--@rules_flutter//flutter:profile`) is shrunk with R8, resources too, as `flutter build apk --release` shrinks it. The rules are [`@rules_flutter//flutter:android_proguard_rules.pro`](flutter/android_proguard_rules.pro) (the Android Gradle plugin's `proguard-android-optimize.txt` and Flutter's own rules), then `android/app/proguard-rules.pro` if you have one. Debug and profile builds aren't shrunk. A list replaces the whole default in every compilation mode, and `[]` turns R8 off. |
| `app_bundle` | Also declares an App Bundle of the app under this name. See [Release: App Bundle and signing](#release-app-bundle-and-signing). |
| `bundle_config` | The bundletool `BundleConfig` of `app_bundle`. Defaults to [`@rules_flutter//flutter:android_bundle_config.pb.json`](flutter/android_bundle_config.pb.json), the Android Gradle plugin's: split by ABI, screen density and language, with native libraries and dex stored uncompressed and the libraries 16 KB-aligned. |

Other arguments, such as `visibility` or `shrink_resources`, pass through to `android_binary`.

#### Release: App Bundle and signing

`flutter build appbundle` and `flutter build apk --release` have one counterpart in two parts: an App Bundle that `flutter_android_app` declares, and a [`flutter_android_release`](#flutter_android_release) target that signs it with your upload key.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_app", "flutter_android_release")

flutter_android_app(
    name = "app",
    application = ":app_flutter",
    application_id = "com.example.myapp",
    app_bundle = "app_bundle",
)

flutter_android_release(
    name = "app_release",
    app_bundle = ":app_bundle",
)
```

```sh
# First time only: make the upload keystore that android/key.properties describes.
bazel run //:app_release -- create-key

# Each release: build, sign and check the bundle and the APK.
bazel run //:app_release
# -> build/app/outputs/bundle/release/app-release.aab
# -> build/app/outputs/flutter-apk/app-release.apk
```

`bazel run //:app_release` builds the bundle in release mode (`-c opt`, not profile) for armeabi-v7a, arm64-v8a and x86_64, whatever the command line says, as `flutter build appbundle` builds every ABI. Its `android_platforms` attribute changes the ABIs. Raise the app's `build_number` for each upload, because Play refuses a version code it has seen.

The key comes from `android/key.properties` under the target's package, the file Flutter's deployment guide has you write:

```properties
storePassword=...
keyPassword=...
keyAlias=upload
storeFile=/Users/me/keys/upload-keystore.jks
```

A relative `storeFile` is relative to `android/app/`, as in Gradle. Never commit the file or the keystore. `flutter create`'s `android/.gitignore` already ignores `key.properties` and `*.jks`. On CI, write the file from your secret store before `bazel run`. `--key-properties=<path>` reads another file, and `--output-dir=<dir>` writes `app-release.aab` and `app-release.apk` there instead.

Signing happens when the program runs, not in a build action, so the keystore and its passwords never reach Bazel. No attribute, action input, command line or cache entry holds them. rules_android itself signs only with debug keys.

`create-key` makes the keystore `storeFile` names: PKCS12, RSA 2048, valid for 10000 days, the values in Flutter's guide. It uses the JDK Bazel already has, so you need no Java installed. It refuses to replace an existing keystore. Back up the keystore and its password. A lost upload key can be reset through Play Console, but only by asking Google.

With Play App Signing, the bundle you upload is signed with the upload key, and Google signs the APKs it serves with the app signing key it keeps. `app-release.apk` is for distribution outside Play. It is the APK of the same release build, signed with the same key by the Android SDK's `apksigner` (which `flutter_android_release` takes from `@androidsdk`), so it won't update a copy installed from Play. As in a Gradle build, its native libraries are stored uncompressed and 16 KB-aligned.

A release bundle carries R8's mapping, `BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map`, from which Play deobfuscates the Java and Kotlin frames of crash reports, as it does for a Gradle-built bundle.

The bundle on its own is rules_android's `android_application`, built from the same arguments as the APK. `bazel build //:app_bundle` makes `app_bundle_unsigned.aab` for the ABIs and compilation mode of the command line, as for the APK. `bazel run //:app_bundle` installs it, signed with the debug key, through bundletool on the device `ANDROID_SERIAL` names, or the only one connected. The JDK, bundletool, `aapt2` and `adb` all come from the build, so nothing needs to be on your PATH.

<details>
<summary>Composable rules</summary>

`flutter_android_app` is these rules and rules_android's `android_binary`. [`e2e/android_example`](e2e/android_example/BUILD.bazel) builds an app this way as `:app_bazel_runner`.

```starlark
load("@rules_flutter//flutter:android.bzl",
    "flutter_android_bundle",
    "flutter_android_engine",
    "flutter_android_manifest_gen",
    "flutter_android_runner_lib_gen")
load("@rules_android//android:rules.bzl", "android_binary")

# The Flutter application's native libraries and its flutter_assets tree.
flutter_android_bundle(name = "my_bundle", application = ":my_app")
flutter_android_engine(name = "my_engine")

# The flutter_assets tree at assets/flutter_assets/, as the APK holds it.
filegroup(
    name = "my_flutter_assets",
    srcs = [":my_bundle"],
    output_group = "flutter_assets",
)

flutter_android_manifest_gen(name = "my_manifest", application_id = "com.example.myapp")

flutter_android_runner_lib_gen(
    name = "my_runner",
    namespace = "com.example.myapp",
    engine = ":my_engine",
)

android_binary(
    name = "my_apk",
    manifest = ":my_manifest",
    custom_package = "com.example.myapp",
    assets = [":my_flutter_assets"],
    assets_dir = "assets",
    # Stored uncompressed, as the manifest's android:extractNativeLibs="false"
    # requires. Android refuses to install the APK otherwise.
    nocompress_extensions = [".so"],
    # The bundle gives android_binary its native libraries for each ABI, as an
    # aar_import does.
    deps = [":my_bundle", ":my_engine", ":my_runner"],
)
```

`flutter_android_bundle` provides `AndroidNativeLibsInfo`, so it goes in `android_binary`'s `deps`, where `android_binary` builds it once for each ABI. Its output groups:

| Group | Contents |
|---|---|
| `native_libs` | One zip of `lib/<abi>/` entries, stored: `libapp.so` (the AOT code), the `native_deps` libraries and the code assets that ship. The bundle provides it to `android_binary` as `AndroidNativeLibsInfo` |
| `flutter_assets` | The `flutter_assets/` tree, at `<name>/assets/flutter_assets/`, for an `android_binary`'s `assets` with `assets_dir = "assets"`. A debug build's holds the kernel and VM snapshots too. No native libraries: they are `native_libs` |

The other Tier 2 rules are `flutter_android_manifest_merge` and `flutter_android_permissions_manifest`, which add a variant manifest's or a list's permissions to a manifest, and `flutter_android_plugin_libs`, `flutter_android_registrant` and `flutter_android_plugin_library`, which wire in plugins.

An App Bundle from these rules is rules_android's `android_application`, given the same arguments as the `android_binary` and `bundle_config_file = "@rules_flutter//flutter:android_bundle_config.pb.json"`. `bazel build` of it works, and `flutter_android_release` signs it. `bazel run` of it doesn't install it: rules_android's run script looks for the JDK where the build ran, gives bundletool no `aapt2`, runs bundletool without the Kotlin runtime its `install-apks` needs, and takes `adb` from your PATH. To install a bundle on a device, declare the app with `flutter_android_app` and its `app_bundle`, whose `bazel run` takes all those tools from the build, or install the APK, which `bazel run` of an `android_binary` does.

</details>

#### Add-to-app: Android

A native Android app can host Flutter in two ways. If Bazel builds the host app too, depend on the Flutter code directly, as `flutter_android_app` does. If Gradle builds it, the host takes the Flutter module as a local Maven repository. That is what `flutter build aar` makes, and what `flutter_android_aar` makes from a `flutter_application`:

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_aar")

flutter_android_aar(
    name = "module_aar",
    application = ":my_app",
    package_name = "com.example.my_module",
    # Optional, with their defaults:
    # build_number = "1.0",
    # abis = ["armeabi-v7a", "arm64-v8a", "x86_64"],
    # min_sdk_version = "24",
)
```

Each run builds one mode, the command line's, and adds it to `build/host/outputs/repo/` under the package beside what earlier runs of other modes wrote. Run it once per mode the host uses:

```sh
bazel run -c dbg //:module_aar                                      # debug
bazel run -c opt --@rules_flutter//flutter:profile //:module_aar    # profile
bazel run -c opt //:module_aar                                      # release
# -> build/host/outputs/repo/ (or `-- --output=<dir>`)
```

Like `flutter build aar`, each run then prints the host's steps:

1. Add the repository and `https://storage.googleapis.com/download.flutter.io` to the host's repositories.
2. Depend on `debugImplementation '<package_name>:flutter_debug:1.0'`, and `profileImplementation` and `releaseImplementation` likewise.
3. Give the host a `profile` build type that is `initWith debug`.

`bazel build //:module_aar` makes the repository of one mode in `bazel-bin`, without writing anything into the source tree.

The repository has upstream's coordinates and POMs:

- The module's AAR is `<package_name>:flutter_<mode>:<build_number>`. Its POM depends on Flutter's engine artifacts, `io.flutter:flutter_embedding_<mode>` and `io.flutter:<abi>_<mode>` at version `1.0.0-<engine revision>`, which the host fetches from `download.flutter.io`.
- With an engine that is not the release's (see [Custom engines and frameworks](#custom-engines-and-frameworks)), Google has no artifacts to fetch, so the repository holds that engine's own, as `flutter build aar --local-engine` does. `io.flutter:flutter_embedding_<mode>` holds the embedding's classes, with the engine's own POM (its slice's `embedding_pom`), which names the AndroidX artifacts the embedding needs at the versions the engine was built with. An engine source with no `embedding_pom` fails the module's build, naming it. Each `io.flutter:<abi>_<mode>` holds that ABI's `libflutter.so`, stripped. Both come from the engine's `flutter.jar`. Every POM names them at the version of that POM, as `flutter build aar --local-engine` does, so the host takes them from this repository. Keep it listed before `download.flutter.io`, as the printed steps do.
- Each plugin with Android code has an AAR at `<plugin group>:<plugin>_<mode>:<build_number>`. Its POM lists the Maven artifacts its Gradle build declares, and `io.flutter:flutter_embedding_<mode>` at compile scope, as Flutter's Gradle build adds it to every plugin. Its `jni/<abi>/` holds the plugin's native libraries, those its Android library links and those of its `native_deps` (package:jni's `libdartjni.so`, say); the module's AAR holds the app's own. Every one is stripped, as a Gradle build strips what it packages.
- Every artifact except the engine's has the build number as its version, plugins' included, as `flutter build aar` sets it. Each artifact's `maven-metadata.xml` lists the versions written so far.

A pub plugin is published under the Maven group its `android/build.gradle` sets (`group = "..."`, which `flutter create` writes). A plugin written in your workspace sets `group` on its Android `flutter_plugin_platform`: `flutter_plugin_platform(platform = "android", group = "com.example.my_plugin", ...)`. There is no default, since a wrong group would publish under someone else's coordinates. A plugin with no group fails the build, naming the plugin.

The module's manifest asks for `android.permission.INTERNET`, as upstream's module template does, because a debug host's Dart VM service needs it. Unlike Gradle's repository, this one has no `.module` files and no sources or javadoc jars.

The composable rules are `flutter_android_module_aar`, `flutter_android_plugin_aars` and `flutter_android_maven_repo`.

### Linux

`flutter_linux_app` builds a Linux app directory from your `flutter_application`. It reads `linux/runner/` as `flutter create --platforms=linux .` writes it. Without that directory, it uses a built-in GTK runner.

```starlark
load("@rules_flutter//flutter:linux.bzl", "flutter_linux_app")

flutter_linux_app(
    name = "my_app_linux",
    application = ":my_app",
    application_id = "com.example.myapp",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `application_id` | The application id GTK names the app by, `flutter create`'s `APPLICATION_ID`. Required: the desktop identifies an app by it, so each app needs its own. |
| `app_name` | The name of the directory and the executable. Defaults to the target name. |
| `window_title` | The built-in runner's window title. Defaults to `app_name`, then the target name. A `linux/runner/` from `flutter create` sets its own title, and this is unused. |

Linux apps carry no version. The output directory, here for `app_name = "my_app"`:

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

**GTK and your C++ toolchain.** rules_flutter brings its own sysroot for the GTK3 headers and libraries, so the build machine needs no GTK installed. It links those libraries as files, with no `-L` or `-lgtk-3` flags, so your toolchain's `--sysroot` stays the only source of libc, libm and the rest of the C runtime. This matters because the GTK sysroot's `libm.so` is a linker script with absolute paths, which `lld` rewrites only for scripts under `--sysroot`. If that directory were on the library search path, `-lm` would fail with "no such file", naming a file that exists.

**From a Mac**, you need an LLVM cross-toolchain, and you can build only in debug mode, because Flutter publishes no `gen_snapshot` that compiles for Linux on a Mac. See [Cross-compiling](#cross-compiling).

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
    application_id = "com.example.myapp",
    # Compiles the plugins' Linux C++ into the runner. Optional for an app
    # with no native plugins.
    application = ":my_app",
    # Optional. Your own runner sources; the built-in runner without them.
    # srcs = glob(["linux/runner/*.cc"]),
    # hdrs = glob(["linux/runner/*.h"]),
)

flutter_linux_bundle(
    name = "my_linux_app",
    application = ":my_app",
    runner = ":my_runner",
)
```

</details>

### Windows

`flutter_windows_app` builds a Windows app directory from your `flutter_application`. It reads `windows/runner/` as `flutter create --platforms=windows .` writes it. Without that directory, it uses a built-in Win32 runner.

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
| `app_name` | The name of the directory and the executable, and the built-in runner's window title. Defaults to the target name. |
| `build_name` | The version, `MAJOR.MINOR.PATCH`. Defaults to the `flutter_application`'s, which defaults to `"1.0.0"`. See [App version](#app-version). |
| `build_number` | The fourth version number. Defaults to the `flutter_application`'s, which defaults to `"1"`. |

As with `flutter build windows`, the executable carries what `windows/runner/` gives it. `Runner.rc` is compiled into its icon and version information: the version `build_name+build_number`, and the file version `MAJOR.MINOR.PATCH.BUILD`. `runner.exe.manifest` is embedded. The built-in runner has the `flutter create` icon and manifest.

Compiling `Runner.rc` takes a Windows resource compiler, registered for Bazel's `@bazel_tools//tools/res:toolchain_type`. On a Windows host with Visual Studio Build Tools, Bazel registers the Windows SDK's `rc.exe` itself, so there is nothing to do. From another host, the build fails until your `MODULE.bazel` registers one, such as `llvm-rc`, wrapped in `windows_resource_compiler_toolchain` from `@bazel_tools//tools/res:winsdk_toolchain.bzl`. rules_flutter registers none, so the choice stays with your module. From another host you also need a C++ cross-toolchain, and you can build only in debug mode (see [Cross-compiling](#cross-compiling)).

The output directory, here for `app_name = "my_app"`:

```
my_app/
  my_app.exe             Win32 runner executable
  flutter_windows.dll    Flutter engine
  *.dll                  native plugin libraries, if any
  data/
    app.so               AOT-compiled Dart, as ELF
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
    "flutter_windows_resources",
    "flutter_windows_runner_lib_gen")

flutter_windows_engine(name = "flutter_engine")
flutter_windows_registrant_gen(name = "app_registrant", application = ":my_app")

flutter_windows_resources(
    name = "my_resources",
    rc = "windows/runner/Runner.rc",
    srcs = glob(["windows/runner/*.h", "windows/runner/resources/**"]),
    build_name = "1.2.3",
    build_number = "4",
)

flutter_windows_runner_lib_gen(
    name = "my_runner",
    engine = ":flutter_engine",
    registrant = ":app_registrant",
    # Compiles the plugins' Windows C++ into the runner. Optional for an app
    # with no native plugins.
    application = ":my_app",
    srcs = glob(["windows/runner/*.cpp"]),
    hdrs = glob(["windows/runner/*.h"]),
    resources = [":my_resources"],
    manifest = "windows/runner/runner.exe.manifest",
    build_name = "1.2.3",
    build_number = "4",
)

flutter_windows_bundle(
    name = "my_windows_app",
    application = ":my_app",
    runner = ":my_runner",
)
```

</details>

### Web

`flutter_web_app` builds a web bundle from your `flutter_application`, as `flutter build web --wasm` does. It reads `web/` as `flutter create --platforms=web .` writes it.

```starlark
load("@rules_flutter//flutter:web.bzl", "flutter_web_app")

flutter_web_app(
    name = "my_app_web",
    application = ":my_app",
    # Optional. The page title and the manifest's name; defaults to the
    # target name.
    app_name = "My App",
)
```

Build it, or run it in Chrome with hot reload:

```sh
bazel build //:my_app_web
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_web -d chrome
```

The bundle is the directory `bazel-bin/my_app_web_web/`. Serve it as you would `build/web/`.

The files under `web/` are templates, substituted as `flutter build web` substitutes them, so `flutter create` output works unchanged. `web/index.html`, `web/flutter_bootstrap.js` and `web/manifest.json` are used when present, and built-in defaults take their place when not. `web/version.json` is used when present, and generated from the application's version when not. Everything else under `web/` is copied to the bundle's root.

One application serves every platform, and the web app takes its program and version from it: `main`, `deps`, assets, shaders, `defines`, `flavor`, `build_name` and `build_number`. It compiles that program from source with dart2wasm and dart2js. It doesn't use the application's AOT output, and it builds the program once for each compiler's web platform (see [Per-compiler code](#per-compiler-code)). As with `flutter build web`, nothing native is built: not the AOT compile, the `native_deps` or the code assets. The packages' link hooks do run, over what the web compile records using (see [Link hooks](#link-hooks)). A web app ships WebAssembly modules through `native_modules` instead.

`bazel build //...` also builds the application for the Dart VM, in a configuration of its own. An application whose code imports web-only libraries (`dart:js_interop`, `package:web`, `dart:ui_web`) without a conditional import fails there. Mark it web-only, so that `bazel build //...` skips it on the VM, while each web app still builds it for its compilers:

```starlark
flutter_application(
    name = "my_app",
    ...
    target_compatible_with = select({
        "@rules_dart//dart/constraints:vm": ["@platforms//:incompatible"],
        "//conditions:default": [],
    }),
)
```

| Attribute | Description |
|---|---|
| `application` | The `flutter_application` (or `flutter_application_variant`) the web app is built from. Required. Its `build_name` and `build_number` are `version` and `build_number` in the bundle's `version.json`, which the web `package_info_plus` reads (see [App version](#app-version)). |
| `app_name` | The HTML title and the manifest's name. Defaults to the target name. |
| `base_href` | Substituted for `$FLUTTER_BASE_HREF` in `web/index.html`. Must start and end with `/`. Defaults to `"/"`. `flutter_bazel run -d chrome` serves the app under it, as `flutter run` does. |
| `static_assets_url` | Substituted for `$FLUTTER_STATIC_ASSETS_URL` in `web/index.html`. Must end with `/`. Defaults to `"/"`, as in `flutter build web`. |
| `web_dir` | The directory the `web/` files are read from. Defaults to `"web"`. Give each app its own, such as `"web_apps/reminders"`, to build several web apps from one package. |
| `extra_web_assets` | Files copied to the bundle's root beside those of `web_dir`, for generated files a glob can't see. |
| `pwa` | Ship `flutter_service_worker.js` and register it. Defaults to `True`. Like the worker of `flutter build web`, which [deprecated its caching worker](https://github.com/flutter/flutter/issues/156910), it caches nothing. It unregisters itself and reloads its pages, which frees visitors still running a caching worker from an older deployment. To ship a worker of your own, set `pwa = False`. |
| `wasm_browsers`, `js_fallback` | Which browsers get the WebAssembly build. See below. |
| `cross_origin_embedder_policy` | See [Cross-origin isolation](#cross-origin-isolation). |
| `use_local_canvaskit` | Ship the renderer in the bundle and load it from there. See below. |
| `web_sdk` | Another web SDK repository, such as `"@my_flutter_web_sdk"`. |

The compiler settings pass through to `flutter_web_bundle`: `profile`, `optimization_level_wasm`, `minify_wasm`, `strip_wasm`, `optimization_level_js`, `minify_js`, `frequency_based_minification`, `dump_info`, `native_null_assertions`, `enable_experiments` and `source_maps`, as do `web_defines` and `keep_placeholders`.

`flutter_web_app` always compiles with dart2wasm and renders with skwasm. For dart2js alone, or CanvasKit, use `flutter_web_bundle` directly (see the composable rules below).

**Which browsers run WebAssembly.** The bundle has two builds, as `flutter build web --wasm` makes: `main.dart.wasm` (with `main.dart.mjs`), rendered by skwasm, and `main.dart.js`, rendered by CanvasKit. Flutter's loader, `flutter.js`, runs the first build the browser can, and the WebAssembly build comes first. A browser can't run it if it lacks WasmGC, or if skwasm isn't allowed in its engine. `flutter.js` allows skwasm in Chromium only by default (its `wasmAllowList` is `blink: true, gecko: false, webkit: false`), so Firefox and Safari run the JavaScript build. We measured Safari 27 loading `main.dart.js` from a default bundle and rendering it.

Two attributes change that:

- `wasm_browsers` names the engines allowed to run the skwasm build. `wasm_browsers = ["blink", "gecko", "webkit"]` serves WebAssembly to Chrome and Edge (`blink`), Firefox (`gecko`) and Safari (`webkit`). Exactly the engines you name are allowed, and unset is Flutter's default. Whether skwasm works well enough in a browser is your judgement, not the rule's. (We measured Safari 27 loading `main.dart.wasm` and rendering it, with `wasm_browsers` naming `webkit`.) The attribute sets `wasmAllowList` in the generated bootstrap. So it is refused alongside a `bootstrap_js` of your own, where you pass `config: {wasmAllowList: {...}}` to `_flutter.loader.load` instead. It is also refused where there is no skwasm build (`compiler = "dart2js"`, `renderer = "canvaskit"`).
- `js_fallback = False` makes the bundle WebAssembly only. No dart2js compile runs, and nothing the rule generates refers to `main.dart.js`. It is for an app that can't compile under dart2js. dart2js refuses the largest 64-bit integer literal at compile time and throws on `Int64List` at runtime, and the default build fails on the first. `e2e/web_example/int64/wasm_only` is an app that uses both, with `js_fallback = False`. If only part of the app needs WebAssembly, keep the fallback and give dart2js its own variant of that part instead (see [Per-compiler code](#per-compiler-code)).

`js_fallback = False` also changes the dev loop. `flutter_bazel run -d chrome` normally compiles with DDC, which produces JavaScript. A WebAssembly-only app would never ship that, so `flutter_bazel run` builds it with dart2wasm instead (see `--wasm` under [The dev tool](#the-dev-tool)). It halves the compile work. `optimization_level_js`, `minify_js`, `frequency_based_minification` and `dump_info` are refused, since nothing would use them.

What `js_fallback = False` costs is the browsers that can't run WebAssembly, which under the default allow-list are Firefox and Safari. There, the loader logs `Flutter Web: no compatible build found for this browser.` and rejects the promise `_flutter.loader.load` returns. The loader alone would leave the page as `index.html` left it, with no app and no word why. The generated `flutter_bootstrap.js` catches the rejection and shows "This app could not start. It is built for WebAssembly only, so it needs a browser that can run it." A bundle with the JavaScript build shows a plainer "could not start" message for any load failure. A `bootstrap_js` of your own gets neither unless it does the same. The usual WebAssembly-only deployment is `js_fallback = False` with `wasm_browsers` naming the engines you want.

**The renderer files.** By default `flutter.js` fetches the renderer from `www.gstatic.com` and never reads a local copy, so the bundle doesn't ship one. Two things put a `canvaskit/` directory in it: `use_local_canvaskit = True`, which also tells the loader to read it, and a debug build, whose dev loop renders with CanvasKit served from there. A `bootstrap_js` of your own that points `canvasKitBaseUrl` at the bundle must set `use_local_canvaskit = True` too, or the directory won't be there.

The loader never switches between skwasm and CanvasKit, with or without cross-origin isolation. (Without it, skwasm runs single-threaded from the same `skwasm.js` and `skwasm.wasm`.) So the directory holds only what the builds load. A WebAssembly-only skwasm bundle has `skwasm*` and `wimp*` and no CanvasKit (Safari and Firefox load `skwasm_heavy*`). A CanvasKit bundle has the reverse, and a bundle with both builds has both.

The renderer's `.symbols` files are emscripten's function-name maps. Nothing fetches them: we watched the dev loop and release runs, skwasm and CanvasKit, request by request. So they aren't shipped. To symbolize a crash, `bazel build //my:app --output_groups=symbols` links the ones for this bundle's engine under `bazel-bin/my/<name>_symbols/canvaskit/`.

**Compile CPUs.** An optimizing wasm compile (`-O1` and up, the default outside debug) reserves 4 CPUs, and its optimizer uses no more. `--@rules_flutter//flutter:wasm_opt_cpus=N` changes both. Fewer lets several web apps compile at once where Bazel has few CPUs to hand out. More makes one compile finish sooner. The output is the same either way.

<details>
<summary>Composable rules</summary>

`flutter_web_bundle` is the rule `flutter_web_app` wraps. It takes the `web/` files as attributes (`index_html`, `bootstrap_js`, `manifest_json`, `version_json`, `web_assets`) and lets you choose the compiler and renderer.

```starlark
load("@rules_flutter//flutter:web.bzl", "flutter_web_bundle")

# WebAssembly, with a dart2js build beside it for browsers that can't run
# WebAssembly (the default):
flutter_web_bundle(
    name = "my_app_web",
    application = ":my_app",
)

# WebAssembly only, for an app dart2js can't compile, served to every engine:
flutter_web_bundle(
    name = "my_app_web_wasm",
    application = ":my_app",
    js_fallback = False,
    wasm_browsers = ["blink", "gecko", "webkit"],
)

# JavaScript alone:
flutter_web_bundle(
    name = "my_app_web_js",
    application = ":my_app",
    compiler = "dart2js",
    renderer = "canvaskit",
)
```

</details>

#### Per-compiler code

A bundle compiles its program once for each compiler it uses: dart2wasm, dart2js for the fallback, and DDC for `flutter_bazel run -d chrome`. DDC compiles what dart2js does, so a debug bundle has at most two versions of the program.

The program can differ between them. Dart's own way is a conditional import on `dart.library.js_interop`, but that can't give dart2js and dart2wasm different declared types, or different files. For that, each compiler builds its dependencies for its own web platform. One carries the constraint value `@rules_dart//dart/constraints:wasm`, the other `:js`. A library picks its variant with a `select()` on those in its `deps`. This is [rules_dart's mechanism](https://github.com/aran/rules_dart#per-compiler-code), and a Flutter app uses it through `flutter_library` and `flutter_plugin` the same way.

Here a library `ids` is `Int64List` under WebAssembly and `List<int>` under JavaScript. `e2e/web_example/int64` is this app:

```starlark
# ids_typed/BUILD.bazel. ids_js/BUILD.bazel is the same, with its own
# lib/ids.dart: the same API, a different type.
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "ids",
)

flutter_library(
    name = "ids",  # typedef Ids = Int64List (in ids_js, List<int>)
    srcs = ["lib/ids.dart"],
    package = ":pubspec-metadata",
)

# ids/BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "ids_select",
)

flutter_library(
    name = "ids",
    package = ":pubspec-metadata",
    deps = select({
        "@rules_dart//dart/constraints:js": ["//ids_js"],
        # dart2wasm, and a build for no web platform (the VM's).
        "//conditions:default": ["//ids_typed"],
    }),
)

# BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "app",
)

flutter_application(
    name = "app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    deps = ["//ids", "@deps//:flutter"],
)

flutter_web_app(
    name = "app_web",
    application = ":app",
)
```

It renders `Int64List max: 9223372036854775807` from the WebAssembly build and `List<int> max: 9007199254740991` from the JavaScript one.

The variants are separate libraries, each in a directory of its own, whose `dart_package_metadata` give the same `package_name`. So the import is the same whichever is picked.

The `select()` goes in a library, not in the application's `deps`. A `select()` is resolved in the configuration of the target that holds it. The application's own `deps` are read in the configuration the web app was asked for, which isn't a web platform's.

What the bundle holds once comes from the primary compiler's version of the program, which is dart2wasm's for the default `compiler`: the plugin registrant, the assets and shaders. So a dependency that differs by compiler shouldn't differ in the plugins or assets it brings. Icon tree shaking keeps the icons either compiler's version uses, as `flutter build web` does.

Some targets are built once, however many compilers reach them:

- pub packages, and the Flutter SDK's packages;
- a `flutter_library` or `flutter_plugin` marked `runtime_independent = True`;
- `flutter_native_library`, `dart_code_asset` and `dart_data_asset`;
- `flutter_gen_l10n`, and `dart_codegen` and its siblings.

So code generation can't vary by compiler. A generator that needs a variant per compiler emits both, and a library above it chooses. Only the first-party libraries on the path from the bundle to a `select()` are analysed once per compiler. A library has no action of its own, so that costs analysis time only.

A library that has no variant outside the web says so as in rules_dart, so that `bazel build //...` skips it rather than failing on it:

```starlark
target_compatible_with = select({
    "@rules_dart//dart/constraints:vm": ["@platforms//:incompatible"],
    "//conditions:default": [],
}),
```

The platforms are rules_dart's `@rules_dart//dart/platforms:js` and `:wasm`, which carry only that constraint. A bundle builds for other platforms when its `js_platform` or `wasm_platform` names them. Each must carry the matching constraint, and the bundle refuses one that doesn't.

#### Content-Security-Policy

A `<meta http-equiv="Content-Security-Policy">` in `web/index.html` applies both to the built bundle and to the dev loop (`flutter_bazel run -d chrome`), because the dev loop serves the same page. Measured on `e2e/web_example` with Flutter 3.47:

| Policy | Built bundle (WebAssembly) | Dev loop (DDC) |
|---|---|---|
| `script-src 'self' 'wasm-unsafe-eval'` | Renders | Blank page |
| `script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'` | Renders | Renders |

The dev loop needs `'unsafe-inline'`, and `'unsafe-eval'` instead doesn't help. The failure is silent: DWDS connects, the VM service answers, every module loads, no CSP violation reaches the console, and the app never paints. `connect-src 'self' ws: wss:` is enough for the dev loop's WebSocket.

A bundle served under `default-src 'self'` or `script-src 'self'` must also serve its own renderer, with `use_local_canvaskit = True`. Otherwise the engine's import of `skwasm.js` from `www.gstatic.com` is blocked, the loader rejects, and the page shows the bootstrap's "could not start" message instead of the app. Flutter's font fallback from `fonts.gstatic.com` is blocked too, which is harmless unless the app needs those glyphs.

A page that is also cross-origin isolated (see below) needs `worker-src 'self' blob:` beside that policy. Multi-threaded skwasm starts its worker from a `blob:` URL. A policy with `script-src 'self'` and no `worker-src` refuses it, and the page stays blank with no message. We measured this in Chrome 156 with a local renderer: blank without the `worker-src`, rendered with it.

So a policy strict enough to be useful can't live in `web/index.html` today, because the dev loop reads the same file. If you need one, use `flutter_web_bundle` directly, with a generated `index_html` for the production bundle.

#### Cross-origin isolation

skwasm runs its renderer on threads only in a cross-origin-isolated page. That needs two response headers: `Cross-Origin-Opener-Policy: same-origin` and a `Cross-Origin-Embedder-Policy`. `flutter_bazel run --wasm` sends both, and whatever serves the deployed bundle must too. The embedder policy is the app's choice, set once on the target:

```starlark
flutter_web_app(
    name = "app_web",
    application = ":app",
    cross_origin_embedder_policy = "credentialless",  # default "require-corp"
)
```

- **`require-corp`** (the default) isolates the page in every browser. It blocks a cross-origin subresource, such as an image from a CDN, unless the response carries a `Cross-Origin-Resource-Policy` header or is fetched with CORS. Flutter's own load of the skwasm renderer from `www.gstatic.com` passes.
- **`credentialless`** loads such subresources without cookies instead of blocking them. Chrome and Firefox isolate the page under it. Safari doesn't, so skwasm runs single-threaded there. Upstream `flutter run` always sends this one.

The default renderer from `www.gstatic.com` works in an isolated page and runs multi-threaded. The CDN answers with `Access-Control-Allow-Origin: *` and `Cross-Origin-Resource-Policy: cross-origin`, and skwasm's worker is a same-origin `blob:` that imports the CDN script as a module. We measured release builds under `require-corp` in Chrome 156 and Safari 27. With the CDN renderer and with `use_local_canvaskit`, the app rendered and a worker started. Without isolation, neither started a worker, and the loader warned that skwasm runs single-threaded. So `use_local_canvaskit` is for air-gapped hosts and strict policies, not for threading.

The dev tool reads the policy from `<bundle>.serving.json`, which the build writes beside the bundle directory rather than inside it, so it isn't deployed. `--no-cross-origin-isolation` turns both headers off for a run, and `--web-header` can then set your own.

### Cross-compiling

`gen_snapshot`, the AOT compiler, runs on the build machine and produces code for the target. Flutter publishes a separate binary for each pair of host and target, and not every pair exists. A debug build compiles to kernel instead, so it needs no `gen_snapshot`.

| Host | Target | Release (AOT) | Debug (JIT) | Notes |
|---|---|:---:|:---:|---|
| macOS | macOS | Yes | Yes | |
| macOS | iOS | Yes | Yes | rules_apple handles the transition |
| macOS | Android | Yes | Yes | rules_android handles the transition |
| macOS | Linux | No | Yes | Needs an LLVM cross-toolchain |
| macOS | Windows | No | Yes | Needs a Windows cross-toolchain and resource compiler |
| macOS | Web | Yes | Yes | Web uses dart2wasm, dart2js and DDC, not `gen_snapshot` |
| Linux | Linux | Yes | Yes | |
| Linux | Android | Yes | Yes | rules_android handles the transition |
| Linux | iOS, macOS | No | No | Needs Xcode |
| Linux | Web | Yes | Yes | |
| Windows | Windows | Yes | Yes | |
| Windows | Android | Yes | Yes | rules_android handles the transition |
| Windows | Web | Yes | Yes | |

The gap is from one desktop OS to another. Flutter publishes no `gen_snapshot` that compiles for Linux or Windows on another OS, so build debug bundles across, or build release on the target OS. [`e2e/cross_compile_example`](e2e/cross_compile_example/MODULE.bazel) builds a Linux bundle on a Mac with the `llvm` module's toolchains.

### Release builds and permissions

`flutter create`'s scaffold grants network access in debug and profile builds only, and these rules do the same. So an app that reaches the network under `-c dbg` can be offline under `-c opt`, with no build error, no exception and nothing in its log. Each platform's debug-only grant is there for the Dart VM service, not for the app:

| Platform | What debug has that release doesn't | Why |
|---|---|---|
| macOS | `com.apple.security.network.server` and `com.apple.security.cs.allow-jit` in `DebugProfile.entitlements`, which profile builds use too. `Release.entitlements` has only `app-sandbox`. | The sandbox must let the VM service bind, and let the JIT map executable pages. |
| Android | `android.permission.INTERNET`, from `android/app/src/debug/AndroidManifest.xml` (and `src/profile/` in profile builds). | Android enforces `INTERNET` in the kernel. Without it the VM service can't bind even a loopback socket. |
| iOS | `NSBonjourServices` and `NSLocalNetworkUsageDescription`, which these rules add to non-release builds. | The engine advertises the VM service over mDNS. |

Remember that a plain `bazel build` is a release build, so it takes the release side of each row.

An app that uses the network for itself says so once, in a way that applies to every compilation mode:

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
    application_id = "com.example.myapp",
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

These attributes add to whichever base file the compilation mode selects, so one declaration covers debug and release, and the `flutter create` files stay untouched. A key the base already has with the same value is merged into one, so declaring `network.server` is safe even though `DebugProfile.entitlements` grants it. A key the base has with a different value is an error naming the key and both files.

`com.apple.security.network.client` is in neither scaffold file. Most Flutter apps reach the network through `NSURLSession`, which the sandbox exempts. A raw socket isn't exempt, so if you open one, you need this key.

**iOS local network privacy.** Since iOS 14, LAN access needs `NSLocalNetworkUsageDescription` and `NSBonjourServices`. The rules add both to non-release builds for the VM service, and leave them out in release. An app that needs LAN access for itself declares them in `ios/Runner/Info.plist`, where they survive into `-c opt`. In non-release builds the rules merge their keys into that file, keeping your usage description and adding `_dartVmService._tcp` to your Bonjour list. The iOS simulator doesn't enforce local network privacy, so only a physical device tells you whether these keys are right.

**Check the built app.** A `build_test` can't see any of this. Read the built artifact:

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

`e2e/macos_example`, `e2e/android_example` and `e2e/ios_example` each have a test that reads the built artifact this way.

### Add-to-app: iOS and macOS

A native app built with Bazel embeds Flutter through the Tier 2 rules of `flutter/ios.bzl` and `flutter/macos.bzl` (`flutter_ios_app_framework_gen`, `flutter_ios_engine` and the rest) in its own `ios_application` or `macos_application`.

A native app built with Xcode takes Flutter as xcframeworks instead, as `flutter build ios-framework` and `flutter build macos-framework` make them:

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_xcframeworks")

flutter_ios_xcframeworks(
    name = "module_ios",
    application = ":my_app",  # a flutter_application
)
```

Each build makes one mode, the configuration's. `bazel run` writes it to `build/ios/framework/<Mode>/` in the package (`-- --output=<dir>` writes elsewhere). It replaces what an earlier run wrote for that mode, and says which other modes are from earlier runs.

```sh
bazel run //:module_ios -c dbg                                     # build/ios/framework/Debug/
bazel run //:module_ios -c opt --@rules_flutter//flutter:profile   # .../Profile/
bazel run //:module_ios -c opt                                     # .../Release/
```

Build every mode from the same sources. Xcode picks the directory by its configuration, and a Debug `Flutter.xcframework` with a Release `App.xcframework` crashes at launch. `flutter_macos_xcframeworks` is the same for macOS, under `build/macos/framework/`.

What `<Mode>/` holds, as upstream:

| xcframework | What it is |
|---|---|
| `App.xcframework` | The Dart program and its assets: AOT in profile and release (with `dSYMs/`), kernel in debug. The iOS simulator slice is a debug build in every mode, as upstream's is, because the simulator engine runs nothing else. |
| `Flutter.xcframework`, `FlutterMacOS.xcframework` | Flutter's own engine xcframework for the mode, copied with Flutter's signature. |
| `<plugin>.xcframework` | One per plugin with Apple code, named after its module and holding only that plugin's code. It links Flutter at `@rpath`. Plugins built from a `Package.swift` are included, which upstream's CocoaPods-only command leaves out. Profile and release slices (not the iOS simulator's, a debug build) carry `dSYMs/`, and the binary keeps its symbols, as upstream's `xcodebuild build` of the plugins leaves them. |
| `<module>.xcframework` | One per module of the [Swift packages plugins depend on](#swift-packages-a-plugin-depends-on), such as `FirebaseCore` and `GoogleUtilities_Logger` for `firebase_core`, as upstream makes each pod a plugin depends on a framework of its own. A plugin's framework links them, so plugins on one package share its code. A plugin's `Package.swift` target that is a module other than the one named after the plugin, such as `firebase_core_objc`, is one too. Each holds its module's headers or Swift interface and its resource bundle. |
| `<prebuilt>.xcframework` | A prebuilt dynamic xcframework a plugin links, such as a Swift package's `binaryTarget` (rules_swift_package_manager's `apple_dynamic_xcframework_import`), copied as it is, with all its slices and its own signature, as upstream copies a pod's `vendored_frameworks`. A prebuilt *static* xcframework (`apple_static_xcframework_import`, a static `binaryTarget` such as FirebaseAnalytics') is instead a dynamic framework of its own, under its module's name, which every plugin that uses it links. Upstream links a static vendored framework into each plugin's framework that uses it and copies the original beside them, so a host that links what it's given has the code twice, with two copies of its singletons. Here it has one. |
| `<code asset>.xcframework` | One per code asset: a build hook's or a `flutter_native_asset`'s dynamic library. In profile and release (but the iOS simulator slice) it is stripped, with its dSYM in `dSYMs/`, as upstream strips it. |
| `FlutterPluginRegistrant.xcframework` | iOS only: a static framework of upstream's Objective-C `GeneratedPluginRegistrant`. |

Beside the modes are `GeneratedPluginRegistrant.h` and `.m` on iOS (use them or the framework), or `GeneratedPluginRegistrant.swift` on macOS. After a debug iOS build there are also `flutter_lldbinit` and `flutter_lldb_helper.py`, which a debug build on an iOS 26 or later device needs as the scheme's LLDB init file.

Integrate them as Flutter's [add-to-app guide for iOS](https://docs.flutter.dev/add-to-app/ios/project-setup) describes for `flutter build ios-framework`: link and embed the dynamic xcframeworks (Embed & Sign), link `FlutterPluginRegistrant` without embedding it, and point the paths at `$(CONFIGURATION)`.

**As a Swift package.** Each `<Mode>/` is also a Swift package, as `flutter build swift-package` writes one per mode. (Swift Package Manager is Flutter's default for plugins since 3.44.) Its `Package.swift` declares the static library `FlutterPluginRegistrant`: upstream's Swift `GeneratedPluginRegistrant`, over every xcframework of the mode as a binary target. `bazel run` points the `FlutterPluginRegistrant` link beside the modes at the mode it wrote. Add that directory to the host as a local package and link its library. Then make the scheme's build pre-action point it at the mode Xcode builds, as upstream's scripts do: `ln -sfn "$CONFIGURATION" <path>/FlutterPluginRegistrant`. Xcode then embeds and signs the dynamic frameworks itself. Unlike upstream's, a plugin here is a binary target, not its Swift package's source to build again.

**Signing.** The xcframeworks are built unsigned, so the build is the same on every machine and caches. Xcode signs the frameworks it embeds. To sign the xcframeworks themselves, as `flutter build ios-framework --codesign-identity` does, set `codesign_identity`: a certificate's name or SHA-1 as `codesign` takes it, or `-` for ad hoc. Signing then runs as a step of its own over the unsigned build, on this Mac and outside the sandbox, so `codesign` reaches the keychain. Each xcframework is signed with `--timestamp=none` except in release, as upstream signs it, and an xcframework that comes signed, Flutter's engine or a prebuilt one, keeps its signature. Changing the identity re-runs only the signing. The step is `flutter_apple_xcframeworks_codesign`, which also works over a layout you assemble yourself.

The frameworks have arm64 slices only, with no Intel simulator or Mac slice. So the host builds for arm64: set `ARCHS = arm64` in its build settings wherever Xcode would otherwise build every architecture (a release build, or a generic simulator destination).

Other attributes:

- `plugins = False` leaves the plugins out, as upstream's `--no-plugins` does, for a host that ships them itself.
- `static_plugins = True` makes them, and the Swift package modules, static frameworks to link and not embed, as `--static` does.
- `minimum_os_version` defaults to `"15.0"` on iOS and `"12.0"` on macOS.

A plugin that depends on a remote Swift package needs the package declared by your root module, as an app does ([Swift packages a plugin depends on](#swift-packages-a-plugin-depends-on)).

A plugin whose `Package.swift` reads the app's settings ([above](#plugins-whose-packageswift-reads-the-app)) is built for the module, which takes the same two attributes an app does. The host app's Info.plist can't be read here, since the frameworks are built before the host, so `info_plist` names the one whose usage descriptions the plugins should see; unset, the manifest sees an empty one. `swift_package_environment` stands in for the shell's environment under `flutter build ios-framework`; unset, the manifest sees none and takes its own defaults: `audio_session` compiles in its microphone code, and `permission_handler_apple` no permission's.

```starlark
flutter_ios_xcframeworks(
    name = "module_ios",
    application = ":module",
    # What audio_session's README says to export before `flutter build`.
    swift_package_environment = {"AUDIO_SESSION_MICROPHONE": "0"},
)
```

The pieces are Tier 2 rules of their own, each building the configuration's mode: `flutter_ios_app_xcframework`, `flutter_ios_engine_xcframework`, `flutter_ios_plugin_xcframeworks`, `flutter_ios_code_asset_xcframeworks` and `flutter_ios_registrant_xcframework`, and their `flutter_macos_*` counterparts except the registrant. All but the engine take `info_plist` and `swift_package_environment`: give each the same, as the macros do, so the module is built in one configuration. Bazel can't keep a symlink to a directory inside a directory artifact, so in `bazel-bin` a macOS framework is its `Versions/A/` alone. `bazel run` makes the links a versioned framework has.

## Custom engines and frameworks

By default an app builds against a Flutter release: the framework from the release's tag, and the engine from the official artifacts. You can also build against a framework and an engine of your own, such as a flutter/flutter checkout and the engine you built in it. That is what `flutter run --local-engine` does upstream. Each such pairing is a named *SDK*, declared next to the release, and each build picks one.

A framework of your own must be Flutter 3.50 or later, as a release must. Its `IconData` carries `@RecordUse()`, and a release or profile build learns from the uses the compiler records which icon glyphs to keep. An older framework records none, and its icon fonts would ship cut to one glyph.

### Building against a local checkout

Build the engine in the checkout as usual, with `engine/src/flutter/tools/gn` and `ninja`. Then declare an SDK over it in `MODULE.bazel`:

```starlark
flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")

# The release.
flutter.toolchain(flutter_version = "3.50.0")

# The checkout's framework and the engine built in it, as the SDK named "local".
flutter.checkout(name = "local")

# What the project builds with. Without this line, the release.
flutter.use_sdk(name = "local")
```

`flutter.checkout` gives the SDK both halves of one checkout: the framework from its `packages/`, and the engine from the out dirs of its `engine/src`. That is the pairing `flutter run --local-engine` makes, and the only one that is sure to compile, since a checkout's framework is written against its own engine's `dart:ui`. To pair a checkout's framework or engine with something else, declare the halves apart (see [Replacing one half](#replacing-one-half)).

The checkout's path is specific to your machine, so it never appears in `MODULE.bazel`. It goes in your untracked `.bazelrc.user`:

```bazelrc
common --repo_env=FLUTTER_CHECKOUT=/Users/me/src/flutter
```

`FLUTTER_CHECKOUT` is the flutter/flutter checkout. The engine is always read from its `engine/src/out`, and never from `FLUTTER_ENGINE`. To declare a second checkout, give its tag another variable with `path_env`, as in `flutter.checkout(name = "other", path_env = "OTHER_FLUTTER_CHECKOUT")`. A checkout whose `bin/internal/material_fonts.version` names a fonts archive that no pinned release uses also needs `material_fonts_sha256`.

The checkout's framework links its `packages/` and `bin/internal/`, so the next build sees an edit to the framework. Its engine scans `engine/src/out`. It reads each out dir's `args.gn` to learn what the out dir holds, and links in the files each piece of the engine needs. It takes the `sky_engine` package from the host debug out dir's `gen/dart-pkg/sky_engine`, as flutter_tools does. A ninja rebuild changes a linked file, and the next build picks it up.

Which out dir serves what, by the names `tools/gn` gives them. The CPU appears in a name only when it isn't the platform's default, so an Apple silicon Mac's host build is `host_debug_arm64`.

| Out dir | Serves |
|---|---|
| `host_debug[_unopt][_<cpu>]` | The host tools (the Dart SDK, `frontend_server`, `flutter_tester`, `impellerc` and so on) and the debug platform kernel. On a Mac, also the debug macOS engine |
| `host_profile...`, `host_release...` | On a Mac, that mode's macOS engine and `gen_snapshot`. On Linux or Windows, that mode's engine for the machine. `host_release` also gives the release platform kernel |
| `ios_debug_sim[_unopt][_<cpu>]` | The iOS simulator engine, which is what debug means for iOS |
| `ios_profile...`, `ios_release...` | The iOS device engine and its `gen_snapshot` |
| `android_<mode>[_unopt][_<cpu>]` | The Android engine (`flutter.jar`) and, for profile and release, its `gen_snapshot` |
| `linux_<mode>[_<cpu>]`, `win_<mode>[_<cpu>]` | A Linux or Windows engine built for another machine than this one, for debug cross-builds |
| `wasm_release` | The web SDK (`flutter_web_sdk/`, with `canvaskit/`) |

Build only the out dirs your builds need. A `-c dbg` macOS app needs `host_debug_<cpu>`. A release one needs `host_release_<cpu>` too.

If two out dirs fit the same slot (`host_debug_arm64` and `host_debug_unopt_arm64`, say), the build fails and lists them. Choose with `--repo_env=FLUTTER_LOCAL_ENGINES=host_debug_unopt_arm64`, a comma-separated list of out dir names, as upstream's `--local-engine` names one. A name chooses only for the slots it fits; the other slots are chosen as without it. A name that is no out dir fails the build.

The engine source directory also needs its Dart source, `flutter/third_party/dart`, which `gclient sync` fetches. rules_dart compiles each library's dependents against an outline of it: its kernel without function bodies. That way an edit inside a function body doesn't recompile them. The tool that makes outlines reads only the kernel format of its own Dart, so for an engine built from a checkout, it is built from that checkout's `pkg/kernel`. Without the Dart source, a build fails saying so, and names the two ways out: run `gclient sync`, or build with `--@rules_dart//dart:outline_kernel=false`.

Programs built with a custom SDK get its own `FLUTTER_VERSION`, `FLUTTER_FRAMEWORK_REVISION`, `FLUTTER_ENGINE_REVISION` and `FLUTTER_DART_VERSION` defines, from the checkout's version and commit and the engine's `args.gn`. The dev tool, and DevTools through it, report the same version and the engine's full revision. `flutter_test` runs under the selected SDK too: its modules compile against the checkout's platform kernel.

### Replacing one half

`flutter.custom_sdk` takes the halves of an SDK apart, for pairings other than a checkout with itself: an engine you built in one place with a framework from another. `flutter_local_framework` is a checkout's framework, and `flutter_local_engine` the out dirs of an engine source directory:

```starlark
flutter.custom_sdk(
    name = "mixed",
    engine = "@flutter_local_engine",
    framework = "@flutter_local_framework",
    hosts = ["host"],
)

local_framework = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_framework")
local_engine = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_engine")

local_framework(name = "flutter_local_framework")

local_engine(name = "flutter_local_engine")
```

The repositories these rules make load `@rules_dart`, so the module that declares them needs a `bazel_dep` on rules_dart. `flutter_local_framework` reads the checkout from `FLUTTER_CHECKOUT`, and `flutter_local_engine` the engine source directory, the directory whose `out/` holds the built out dirs, from `FLUTTER_ENGINE`. flutter_tools reads a variable of the same name, the default of `--local-engine-src-path`. Each is read from its own variable, so an engine built elsewhere works with any checkout's framework:

```bazelrc
common --repo_env=FLUTTER_CHECKOUT=/Users/me/src/flutter
common --repo_env=FLUTTER_ENGINE=/Users/me/src/engine/src
```

`hosts` names the machines the engine's host tools run on, which the SDK's toolchains are registered for alone: `darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64` or `windows-x64`, or `host`, the machine Bazel runs on. Out dirs are the build of the machine they were built on, so `flutter_local_engine` takes `["host"]`; an engine source with host tools for several machines lists them. Bazel runs an action on the first execution platform a toolchain is registered for, so with `--extra_execution_platforms` naming another OS, a host the engine doesn't serve would take the build and fail it. `flutter.checkout` needs no `hosts`: its engine is always the machine's.

To replace only one half, keep the other a release's: `flutter.custom_engine(name, engine, hosts, flutter_version)` puts the release's framework over your engine, and `flutter.custom_framework(name, framework, flutter_version)` your framework over the release's engine. The two halves must agree on `dart:ui`: an engine built in a flutter/flutter checkout fits that checkout's framework, and a release's framework only as far as the checkout's `dart:ui` is still the release's. Pair them wrongly and the framework fails to compile against the engine's `dart:ui`, with an error such as a `switch` that misses a value of an engine enum. To build with a checkout's engine, use `flutter.checkout`, which gives its framework too. A framework whose `bin/internal/material_fonts.version` names a fonts archive that no pinned release uses also needs `material_fonts_sha256`.

### Choosing the SDK

A build uses one SDK. `flutter.use_sdk(name = ...)` in the root module's `MODULE.bazel` chooses it for the project, and without it a build uses the release, which is named `flutter`. Only the root module may use the tag, once, and a name no tag declares fails, listing the names that are.

`--@rules_flutter//flutter:sdk=<name>` overrides that choice. Pass it for one build, or put it in `.bazelrc.user` to build with another SDK on one machine:

```sh
bazel build //:app --@rules_flutter//flutter:sdk=flutter
```

A name the flag gives that no tag declares fails too, listing the declared names.

An SDK's repositories are fetched only when a build selects it. On a machine without `FLUTTER_CHECKOUT` (or, for the halves, `FLUTTER_ENGINE`) set, the repositories still load, so `bazel query` and `bazel fetch --all` work. A build that selects the SDK there fails at analysis, with the `.bazelrc.user` line to add. Only the root module can declare an SDK other than `flutter`, and only it can declare one that is not a release. Those always have names of their own: `flutter` is the release every module may ask a version of.

All SDKs share one `pubspec.lock`. The `sdk: flutter` packages (`flutter`, `flutter_test` and so on) come from the selected SDK's framework. The build fails in two cases: when what the checkout's pubspecs ask of a hosted package doesn't match the lock, and when the lock needs a newer Flutter than the checkout is. It names each package and every SDK whose framework it is, and gives the commands that resolve the lock again against that framework, one for each of those SDKs. Any of them resolves the same packages:

```sh
bazel run --@rules_flutter//flutter:sdk=local @rules_flutter//flutter/pub -- get
```

### What the app records

An app built with a custom SDK carries `flutter_sdk.json` in its Flutter assets:

| App | Where |
|---|---|
| macOS | `App.framework/Resources/flutter_assets/` |
| iOS | `flutter_assets/` in `App.framework/` |
| Android | `assets/flutter_assets/` in the APK |
| Linux, Windows | `data/flutter_assets/` |
| Web | `assets/` |

An app built with the release carries none, so release apps are unchanged.

```json
{
  "engine": {
    "<engine repository>//host/darwin-arm64:tools": {
      "as_of": "gn",
      "content_hash": "...",
      "dart_version": "...",
      "engine_version": "4f1c...",
      "origin": "out_dir",
      "out_dir": "host_debug_arm64"
    },
    "<engine repository>//macos/release:engine": { "out_dir": "host_release_arm64", "...": "..." }
  },
  "framework": {
    "commit": "4f1c...",
    "dirty": true,
    "origin": "local",
    "version": "3.50.0-1.0.pre-210"
  },
  "kernel": {"format": 141, "sdk_hash": "0000000000"},
  "sdk": "local",
  "snapshot_hash": "6b959e9909a17b8e29b0663a6d99e646"
}
```

- `framework` is the checkout: its version, which is told from its git tags as `flutter --version` tells it (`3.50.0` at a tag, `3.50.1-0.0.pre-12` twelve commits past one), its commit, and whether it had uncommitted changes when the build read it.
- `engine` has one entry for each piece the app was built from, keyed by the piece's label: the host tools, the platform kernel, the engine and, in profile and release, the `gen_snapshot`. `engine_version`, `content_hash` and `dart_version` are what `tools/gn` wrote into the out dir's `args.gn`. `as_of: "gn"` says so: that commit is the one checked out when `tools/gn` generated the directory, which can be older than the last `ninja` run.
- `snapshot_hash` and `kernel` are the fingerprints the engine's Dart VM checks (see below). A web app has no `snapshot_hash`.
- The record holds no path of the machine that built the app. The checkout's path and every absolute path are left out.

### What fails, and how

Every failure names what is missing or which artifacts disagree, and how to fix it.

**A piece the out dirs don't have.** A build that needs an engine for a mode, platform or CPU that the out dirs lack fails at analysis. The message names the piece, the out dirs it found, and the `tools/gn` and `ninja` commands that build the missing one. One mode's engine never stands in for another's: a debug engine can't run AOT code, and a release engine rejects anything not compiled for release. Builds that don't need the missing piece are unaffected. So on an Apple silicon Mac, a checkout with only `host_debug_arm64` and its Dart source builds every `-c dbg` macOS app.

**An engine of the wrong CPU.** A locally built engine holds one CPU, where the release's macOS engine is universal. An app built for a CPU the engine lacks fails at analysis, naming the engine, the CPUs it holds and the CPU the build is for. An iOS app is checked the same way for the device or simulator slice it needs, and an Android app for each ABI it carries.

**Pieces built from different Darts.** Once per SDK, platform and mode, one action, `FlutterSdkCheck`, reads the fingerprints out of the artifacts. Every app of that combination depends on it, so it can't be skipped. It fails the build when:

- the engine's platform kernel and the Dart SDK's `vm_platform_strong.dill` have different kernel formats or SDK hashes;
- in profile and release, `gen_snapshot` and the engine binary share no snapshot hash (the engine's VM refuses a snapshot whose hash isn't its own);
- the Dart SDK's `dartaotruntime` is of another Dart than the engine.

For example:

```
The Flutter SDK does not match itself for release:
  gen_snapshot  <engine repository>//macos-arm64/release:gen_snapshot_darwin-arm64
                (.../macos-arm64/release/gen_snapshot)
                snapshot hash 9f3c...
  engine        <engine repository>//macos/release:engine
                (.../macos/release/FlutterMacOS.framework/Versions/A/FlutterMacOS)
                snapshot hash 0451...
An engine only runs code compiled by a gen_snapshot from the same Dart. Rebuild both from one checkout.
```

A web SDK has no engine binary or `gen_snapshot`, so a web build checks only the kernel: each of the web SDK's platform dills against the Dart SDK. A web app built with a custom engine loads its renderer from the web SDK rather than the CDN, which has nothing for an engine that isn't a release. So a web SDK without `canvaskit/` fails too.

**A checkout that isn't one.** A `FLUTTER_CHECKOUT` without `packages/flutter/pubspec.yaml`, a `flutter.checkout` whose checkout has no `engine/src/out/`, a `FLUTTER_ENGINE` without `out/`, or a `FLUTTER_LOCAL_ENGINES` naming an out dir that isn't there, fails a build that selects the SDK, at analysis, naming what is missing. The repositories still fetch, so `bazel fetch --all` and `bazel query` work on a machine whose checkout is elsewhere or unbuilt.

### Writing an engine source

`flutter_local_engine` is one *engine source*. Any repository that follows the same contract can be one, and `flutter.custom_engine` or `flutter.custom_sdk` uses it the same way. The release's engine is written to this contract too.

An engine source has a `flutter_engine.json` at its root, and a target, called a *slice*, at each of these labels. `<host>` is the machine the tools run on (`darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64` or `windows-x64`). `<mode>` is `debug`, `profile` or `release`.

| Label | Rule (provider) | Used by |
|---|---|---|
| `//:flutter_engine.json` | A file: `{"origin": ..., "description": ...}`, plus `engine_revision` and `dart_version` for the `FLUTTER_*` defines | Every build |
| `//host/<host>:tools` | `flutter_host_tools` (`FlutterHostToolsInfo`) | Every build whose actions run on `<host>` |
| `//kernel/debug:platform` | `flutter_platform_kernel` (`FlutterPlatformKernelInfo`) | Debug and profile Dart compiles |
| `//kernel/release:platform` | `flutter_platform_kernel` | Release Dart compiles |
| `//sky_engine:sky_engine` | `dart_library` of the engine's `sky_engine` package, with `package_name = "sky_engine"`: its `lib/` holds Flutter's `dart:` libraries as sources, and `lib/_embedder.yaml` | Analysis: it is how the analyzer resolves `dart:ui` |
| `//sky_engine:LICENSE` | A file: the engine's licences | `NOTICES`, which lists them as `sky_engine`'s |
| `//sky_engine:pubspec.yaml` | A file: the `pubspec.yaml` of the engine's `sky_engine` package, with the rest of the package beside it | Resolving `pubspec.lock` against a framework source (`@rules_flutter//flutter/pub`) |
| `//outline_tool:outline_tool` | The outline tool, for example an `alias` to the `:outline_tool` of a rules_dart `dart_kernel_source(path = ...)` of the engine's Dart | Builds with `--@rules_dart//dart:outline_kernel`, the default |
| `//macos/<mode>:engine` | `flutter_macos_engine_slice` (`FlutterEngineInfo`) | macOS apps |
| `//macos/<mode>:xcframework` | `flutter_macos_engine_slice`, whose files are a whole `FlutterMacOS.xcframework` | macOS add-to-app (`flutter_macos_xcframeworks`). Release macOS apps built with `--apple_generate_dsym` take the engine's dSYM from `release`'s, at `<slice>/dSYMs/FlutterMacOS.framework.dSYM` beside the framework; without one, the app's `dsyms` output group has no engine dSYM, as with `flutter build macos` |
| `//ios/<mode>:engine` | `flutter_ios_engine_slice` | iOS apps. `debug` is the simulator engine |
| `//android-<arch>/<mode>:engine` | `flutter_android_engine_slice` | Android apps. `<arch>` is `arm`, `arm64` or `x64`. Its optional `embedding_pom` is the out dir's `flutter_embedding_<mode>.pom`, which a module's Maven repository (`flutter_android_aar`) needs for an engine that is not the release's. `flutter_local_engine` links it from the out dir |
| `//linux-<arch>/<mode>:engine` | `flutter_linux_engine_slice` | Linux apps. `<arch>` is `x64` or `arm64` |
| `//windows-x64/<mode>:engine` | `flutter_windows_engine_slice` | Windows apps |
| `//<target>/<mode>:gen_snapshot_<host>` | `flutter_gen_snapshot` (`FlutterGenSnapshotInfo`) | Profile and release builds for `<target>` (`macos-<arch>`, `ios-arm64`, `android-<arch>`, `linux-<arch>` or `windows-x64`) that run on `<host>` |
| `//web:sdk` | `flutter_web_sdk` (`FlutterWebSdkInfo`), with the files a web app names beside it in `//web` (`files`, `dart2js_platform.dill`, `dart2wasm_platform.dill`, `ddc_outline.dill`, `libraries.json`, `ddc_dart_sdk.js`, `ddc_module_loader.js` and `dart_stack_trace_mapper.js`) | Web apps |

The rules and providers load from `@rules_flutter//flutter:engine.bzl`, whose docstrings list every field. A slice can be anything that returns the provider: one of these rules over downloaded files or over symlinks into a build directory, an `alias` into another repository, or a target that builds the files.

Every provider takes a `provenance` dict, which is what the app's record shows for that piece. Keep machine paths out of it. The record drops a `path` key and any value that is an absolute path (starting with `/`, `\\` or a drive letter), and nothing else.

Define every label. Make the ones you don't provide `flutter_missing_slice`s. A build that needs one then fails at analysis with your message, and a build that doesn't is unaffected:

```starlark
load("@rules_flutter//flutter:engine.bzl", "flutter_macos_engine_slice", "flutter_missing_slice")

# macos/release/BUILD.bazel
filegroup(
    name = "files",
    srcs = glob(["FlutterMacOS.framework/**"]),
)

flutter_macos_engine_slice(
    name = "engine",
    mode = "release",
    cpus = ["arm64"],
    files = ":files",
    binary = ":FlutterMacOS.framework/Versions/A/FlutterMacOS",
    provenance = {"origin": "my_build", "commit": "4f1c..."},
    visibility = ["//visibility:public"],
)
```

```starlark
# ios/release/BUILD.bazel
flutter_missing_slice(
    name = "engine",
    message = "This engine has no iOS build. Build iOS apps with the release.",
    visibility = ["//visibility:public"],
)
```

`cpus` is what the CPU check reads. `binary` is the file whose snapshot hash the check reads. For Android that is `flutter.jar`, with `binary_entry = "lib/<abi>/libflutter.so"`, and `embedding_pom` is the `flutter_embedding_<mode>.pom` the engine build writes beside it. Its version, `1.0.0-<engine revision>` from an engine build, is the one a module's Maven repository publishes the engine's artifacts at. An iOS slice also lists its `xcframework_slices`. The same `FlutterSdkCheck` runs on your pieces as on a checkout's.

A *framework source* is the other half: a repository whose root is a flutter/flutter tree, with `packages/`, `bin/internal/material_fonts.version`, and a `flutter_framework.json` saying what it is: `{"version": "...", "commit": "...", "dirty": false, "origin": "..."}`. `commit` may be empty. It may also hold `channel` and `repository_url` (a URL, or `null` for none), the channel and repository `flutter --version` reports, which programs are told as `FLUTTER_CHANNEL` and `FLUTTER_GIT_URL`. Left out, they are the release's: `stable`, and `https://github.com/flutter/flutter.git`.

### Limitations

- `flutter.checkout` and `flutter_local_engine` are tested against a stand-in checkout. `e2e/custom_engine` lays the official release's artifacts out the way a checkout's out dirs hold them, with matching `args.gn` files. The out dir layout and the `args.gn` fields it reads follow `tools/gn`, but haven't yet been checked against a real engine build.
- A debug iOS build is a simulator build. Out dirs give no debug build for an iOS device.
- Engines and `gen_snapshot`s for macOS and iOS are read only on a Mac.
- A desktop profile or release build uses the out dir's own `gen_snapshot`, which runs only on the machine it was built for. So those builds exist only for the machine's own platform. As with the release, release builds for another desktop OS don't cross-compile, and debug builds do.
- rules_flutter ships only two engine and framework sources: the release and a local checkout. Anything else, such as a fork's artifacts at a URL, needs a repository you write to the contract above.

## Rules reference

This section is for looking a rule up: what it is for, how to declare it, and its attributes. Each rule's docstring, in the `.bzl` file it is defined in, says more about each attribute. The README points you there when the extra detail matters.

| You want to | Use | Load from |
|---|---|---|
| Compile an app's Dart and bundle its assets | [`flutter_application`](#flutter_application) | `@rules_flutter//flutter:defs.bzl` |
| Share Dart code and assets between targets | [`flutter_library`](#flutter_library) | `defs.bzl` |
| Write a plugin in your workspace | [`flutter_plugin`](#flutter_plugin) | `defs.bzl` |
| Build the app with another entry point | [`flutter_application_variant`](#flutter_application_variant) | `@rules_flutter//flutter:integration_test.bzl` |
| Run widget and unit tests | [`flutter_test`](#flutter_test) | `defs.bzl` |
| Run tests in the real app, on a device or in a browser | [Integration tests](#integration-tests) | `integration_test.bzl` |
| Make build outputs with Flutter's renderer, such as screenshots | [`flutter_tester_binary`](#flutter_tester_binary) | `defs.bzl` |
| Test a profile build, or an APK for fixed ABIs, in a plain `bazel test` | [`flutter_profile_build`](#flutter_profile_build), [`flutter_android_build`](#flutter_android_build) | `defs.bzl`, `@rules_flutter//flutter:android.bzl` |
| Sign an Android release | [`flutter_android_release`](#flutter_android_release) | `android.bzl` |
| Generate code instead of running `build_runner` or `flutter gen-l10n` | [Code generation](#code-generation) | `@rules_dart//dart:defs.bzl`, `defs.bzl` |
| Write your own rule over these | [Providers](#providers), [Lower-level rules](#lower-level-rules) | `@rules_flutter//flutter:providers.bzl`, `defs.bzl` |

The platform rules (`flutter_macos_app` and the rest) are in [Building for each platform](#building-for-each-platform).

### flutter_application

Compiles an app's Dart and builds its `flutter_assets/` bundle. Under `-c dbg` the Dart becomes a kernel `.dill` that the JIT runs. Under any other `-c` it is AOT native code. Each platform's app rule takes the application as its `application` (see [Your first app](#your-first-app)). The web app rule compiles the application's program itself, with the web compilers (see [Web](#web)).

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
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

| Attribute | Default | Description |
|---|---|---|
| `main` | required | The entry point. It may be outside `lib/`, as `flutter run -t test_driver/app.dart` allows. |
| `package` | required | The app's `dart_package_metadata`. Its `package_name` is the `name:` of `pubspec.yaml`, which `package:my_app/...` imports and hot reload key libraries by. |
| `srcs` | `[]` | The app package's other Dart files, generated ones included. A `main` outside `lib/` that imports a file by relative path needs that file here. |
| `deps` | `[]` | `dart_library` and `flutter_library` targets. Add `@rules_flutter//flutter:material_icons` for the Material icon font. |
| `assets` | `[]` | Files of the application's Bazel package. Each is bundled under its path in that package (`assets/a.png`), the key `rootBundle` and `Image.asset` load it by, as with `flutter run`. A file from another package fails the build. |
| `native_deps` | `[]` | Shared libraries to bundle for `dart:ffi`. A web app bundles none. |
| `code_assets` | `[]` | The library this program uses for an asset id, in place of the one its packages supply. See [Choosing the library that serves an asset id](#choosing-the-library-that-serves-an-asset-id). |
| `defines` | `[]` | Dart environment defines, `flutter build`'s `--dart-define`. |
| `flavor` | `""` | `flutter build --flavor`. See [Flavors](#flavors). |
| `build_name`, `build_number` | unset: `1.0.0`, `1` | The pubspec's `version:`. `--@rules_flutter//flutter:build_name` and `build_number` replace them for one build, as `flutter build --build-name` and `--build-number` do. See [App version](#app-version). |
| `shaders` | `[]` | `.frag` or `.glsl` fragment shaders, compiled with `impellerc`. |
| `shader_includes` | `[]` | Files the `shaders` `#include`. A shader compiles with only its declared inputs, so an include not listed here is not found. |
| `require_sksl_shaders` | `False` | Fail the build when a shader can't be compiled for Skia. By default such a shader is compiled for Impeller alone, with a warning, as `flutter build` does. It then fails to load only where the app renders with Skia. Web builds always need Skia shaders. |
| `tree_shake_icons` | `True` | In a release or profile build, keep only the icon glyphs the app uses. As with `flutter build`, this needs every `IconData` to be a constant and each icon font family the app draws from to be one font file, and the build fails otherwise. `MaterialIcons` and `CupertinoIcons` ship cut to one glyph when the app uses none of their icons. The build learns which icons the app uses from what the compiler records of `IconData`, so a [custom framework](#custom-engines-and-frameworks) must be Flutter 3.50 or later. Set it to `False` to ship the fonts whole. |
| `track_widget_creation` | `True` | In a debug or profile build, record where each widget was created, for the DevTools inspector, as `flutter run` does. A release build never records it. |
| `extra_gen_snapshot_options` | `[]` | Flags for `gen_snapshot`. `--no-strip` keeps the shipped binary's symbols, as in `flutter build`, except on Android, where an APK or AAR strips `libapp.so` as the Android Gradle plugin does. It is read by the rules, not passed on. A flag that makes `gen_snapshot` write a file names it relative to the package: `--save-obfuscation-map=obfuscation.json` writes `<name>_gen_snapshot/obfuscation.json`, in the `gen_snapshot_files` output group. `--resolve-dwarf-paths` is refused. |
| `additional_licenses` | `[]` | The files `flutter: licenses:` lists in `pubspec.yaml`. They are appended to the licence notices as they are. |
| `minimum_os_version` | `""` | The Apple deployment target given to `gen_snapshot`. The iOS and macOS app rules set it, so you rarely do. |

**Licences.** An app's licence page reads `NOTICES.Z` from its bundle (`NOTICES` on the web). It lists the app's own licence, the `license_file` of its `dart_package_metadata`, under the package name. Then it lists the licence of each package in `deps`, and the Flutter engine's. A pub package's licence is its `NOTICES` or `LICENSE` file. A package of your workspace states its own, as the `license_file` of its `dart_package_metadata`.

**Defines from the command line.** `--@rules_dart//dart:extra_dart_defines=KEY=VALUE` adds a define to every Dart compile in the build: Flutter kernels, `flutter_test`, dart2wasm, dart2js, and rules_dart's `dart_test` and `dart_binary`. Repeat it for more defines. Tools built for the execution platform don't get them. When a key is in both the flag and `defines`, the flag wins. A value may contain commas, except in a `flutter_test`, which refuses one at analysis: its dependencies are compiled by the SDK's `kernel_worker`, which splits every value on commas. The keys the build sets itself are refused in both places: `dart.vm.profile` and `dart.vm.product`, `FLUTTER_APP_FLAVOR`, `FLUTTER_BUILD_NAME`, `FLUTTER_BUILD_NUMBER`, the `FlutterVersion` keys, and `flutter.dart_plugin_registrant`. `flutter_bazel run --dart-define` sets this flag, and keeps the defines for hot reload and hot restart, as `flutter run --dart-define` does.

### flutter_library

Collects a package's Dart sources and assets for other targets to depend on. It compiles nothing. Whatever depends on it compiles its sources and bundles its assets.

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_lib",
)

flutter_library(
    name = "my_lib",
    package = ":pubspec-metadata",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@deps//:some_package"],
    assets = glob(["assets/**"]),
)
```

A package's assets are keyed by their path from the package root, the directory above `lib/`, as its `pubspec.yaml` lists them. A program of another package bundles `assets/logo.png` of `my_lib` at `packages/my_lib/assets/logo.png`. A program of the same package (its own `flutter_test`, or the application whose code this is) bundles it at `assets/logo.png`. This is how `flutter build` keys them, and it applies to `fonts` and `shaders` too.

| Attribute | Default | Description |
|---|---|---|
| `srcs` | `[]` | The package's Dart files. They must be under its `lib/`. A library of only fonts, assets or shaders has none. |
| `package` | none | The package's `dart_package_metadata`, `:pubspec-metadata` in the BUILD file at the package root. Without it, the package is named after its root directory and states nothing else. |
| `deps` | `[]` | `dart_library` and `flutter_library` targets. |
| `assets` | `[]` | `flutter: assets:`. Files of the package, keyed as above. To bundle a file from elsewhere, such as a generated one, put it at a path of the package with a rule of the package, such as `copy_file`, and list that. |
| `fonts` | `[]` | `flutter: fonts:`, as `flutter_font_family` targets. See [Fonts](#fonts). |
| `shaders` | `[]` | `flutter: shaders:`. `FragmentProgram.fromAsset` loads each by its key. |
| `shader_includes` | `[]` | Files the `shaders` `#include`, such as `glob(["shaders/**/*.glsl"])`. |
| `asset_platforms`, `shader_platforms` | `{}` | The `platforms:` of an entry of `flutter: assets:` or `flutter: shaders:`: path to the platforms it ships on. A file not listed ships on all of them. |
| `asset_flavors`, `shader_flavors` | `{}` | The `flavors:` of an entry: path to the flavors it ships in. A file not listed ships in every build. |
| `resources` | `[]` | Non-Dart files under `lib/` that are part of the package but not bundled as assets, such as a template another package reads as `package:my_lib/...`. |
| `data` | `[]` | Files the library needs when it runs on the host: a fixture, a model, a tool it runs. They join the runfiles of every `flutter_test`, `flutter_tester_binary`, `dart_test` and `dart_binary` that reaches the library, found there with `rlocation`. An app doesn't ship them. A file an app loads at run time is an asset. |
| `additional_licenses` | `[]` | The files `flutter: licenses:` lists. |
| `runtime_independent` | `False` | Build the library once, rather than once per web compiler. See [Per-compiler code](#per-compiler-code). |

#### Fonts

Each entry of `flutter: fonts:` is a `flutter_font_family`. A font with a `weight` or `style` is a `flutter_font`:

```yaml
# pubspec.yaml
flutter:
  fonts:
    - family: Inter
      fonts:
        - asset: fonts/Inter-Regular.ttf
        - asset: fonts/Inter-Bold.ttf
          weight: 700
```

```starlark
flutter_font(
    name = "inter_bold",
    src = "fonts/Inter-Bold.ttf",
    weight = 700,
)

flutter_font_family(
    name = "inter",
    family = "Inter",
    fonts = [
        "fonts/Inter-Regular.ttf",  # a plain file: no weight, no style
        ":inter_bold",
    ],
)

flutter_library(
    name = "ui",
    package = ":pubspec-metadata",
    srcs = glob(["lib/**/*.dart"]),
    fonts = [":inter"],
)
```

| Rule | Attribute | Default | Description |
|---|---|---|---|
| `flutter_font_family` | `family` | the target's name | The name `TextStyle.fontFamily` selects. |
| | `fonts` | required | Its fonts, in order: `flutter_font` targets, or plain font files. |
| `flutter_font` | `src` | required | The font file. |
| | `weight` | none | `100` to `900`, in steps of 100. |
| | `style` | none | `normal` or `italic`. |
| | `asset` | none | For a font of another package, the `packages/<package>/<path>` that `asset:` names it by. Every program bundles `src` at that path. |

A font is a file of the package whose `flutter_library` or `flutter_plugin` lists the family, and is keyed like that package's assets. A file from another package fails the build unless `asset` names it.

**Fonts that `google_fonts` fetches.** `package:google_fonts` downloads a font the first time the app draws with it. A `flutter_test` answers every HTTP request with an error, so a widget drawn with such a font fails there, and an app that is offline falls back to another font. To ship the fonts instead, list their `.ttf` files (named as Google Fonts names them, `Lato-Regular.ttf`) in a `flutter_library`'s `assets`. `google_fonts` finds them by file name in the asset manifest. Then set `GoogleFonts.config.allowRuntimeFetching = false` before `runApp`.

### flutter_plugin

Declares a plugin written in your workspace: its Dart code, and its registration and native code on each platform. Plugins from pub don't need this, because the pub hub declares them.

Each entry of `flutter: plugin: platforms:` is a `flutter_plugin_platform`. This is [`e2e/plugin_example/glass_plugin`](e2e/plugin_example/glass_plugin/BUILD.bazel), whose iOS and macOS code is one Swift library:

```yaml
# pubspec.yaml
flutter:
  plugin:
    platforms:
      android:
        package: com.example.glass_plugin
        pluginClass: GlassPlugin
      ios:
        pluginClass: GlassPlugin
        sharedDarwinSource: true
      macos:
        pluginClass: GlassPlugin
        sharedDarwinSource: true
  shaders:
    - shaders/invert.frag
    - shaders/tint.frag
```

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_engine", "flutter_android_plugin_library")
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_plugin", "flutter_plugin_platform")
load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "glass_plugin",
)

flutter_plugin(
    name = "glass_plugin",
    package = ":pubspec-metadata",
    srcs = ["lib/glass_plugin.dart"],
    platforms = [":android", ":ios", ":macos"],
    shaders = ["shaders/invert.frag", "shaders/tint.frag"],
    shader_includes = glob(["shaders/*.glsl"]),
    # The plugin's Kotlin, which every Android app that depends on it links.
    exports = select({
        "@platforms//os:android": [":glass_plugin_android"],
        "//conditions:default": [],
    }),
    deps = ["@deps//:flutter"],
)

flutter_plugin_platform(
    name = "android",
    platform = "android",
    plugin_class = "GlassPlugin",
    package = "com.example.glass_plugin",
)

flutter_plugin_platform(
    name = "ios",
    platform = "ios",
    plugin_class = "GlassPlugin",
    lib = ":glass_plugin_apple",
)

flutter_plugin_platform(
    name = "macos",
    platform = "macos",
    plugin_class = "GlassPlugin",
    lib = ":glass_plugin_apple",
)

# platform = "darwin" compiles for whichever of iOS and macOS the build is for.
flutter_apple_plugin_library(
    name = "glass_plugin_apple",
    srcs = ["darwin/Classes/GlassPlugin.swift"],
    module_name = "glass_plugin",
    platform = "darwin",
)

# Compile-only: the app packages its own engine, for its own ABI.
flutter_android_engine(
    name = "android_engine",
    neverlink = True,
    tags = ["manual"],
)

flutter_android_plugin_library(
    name = "glass_plugin_android",
    srcs = glob(["android/src/main/kotlin/**/*.kt"]),
    flutter_engine = ":android_engine",
    java_package = "com.example.glass_plugin",
    manifest = "android/src/main/AndroidManifest.xml",
)
```

| Attribute of `flutter_plugin_platform` | pubspec key | Description |
|---|---|---|
| `platform` | the key under `platforms:` | `android`, `ios`, `linux`, `macos`, `web` or `windows`. Required. |
| `plugin_class` | `pluginClass` | The class registered with the platform's plugin registry. On the web, the Dart class whose `registerWith(Registrar)` the web registrant calls. |
| `dart_plugin_class` | `dartPluginClass` | The Dart class whose `registerWith()` runs before `main()`. |
| `dart_file_name` | `dartFileName` | The library under `lib/` that declares `dart_plugin_class`. Defaults to `<package>.dart`. Not on the web. |
| `file_name` | `fileName` | The library under `lib/` that declares a web `plugin_class`. Defaults to `<package>.dart`. Web only. |
| `ffi_plugin` | `ffiPlugin` | The platform's native code is a library Dart opens through `dart:ffi`. |
| `default_package` | `default_package` | The package that implements a federated plugin on this platform. |
| `package` | `package` | The Java package of an Android `plugin_class`. Android only, and required with a `plugin_class`. |
| `group` | `group` in `android/build.gradle` | The Maven group a `flutter_android_aar` repository publishes the plugin under. Android only, and required for that. |
| `lib` | | The native library: a `flutter_apple_plugin_library` on iOS and macOS, a `flutter_linux_plugin_library` or `flutter_windows_plugin_library` on the desktops. Only a build for `platform` analyses it. Android's goes in the plugin's `exports`, and the web has none. |

A platform needs a `plugin_class`, a `dart_plugin_class`, `ffi_plugin` or a `default_package`, as flutter_tools requires.

| Attribute of `flutter_plugin` | Description |
|---|---|
| `srcs` | The plugin's Dart files. |
| `deps` | `dart_library` and `flutter_library` targets. |
| `package` | The package's `dart_package_metadata`, as on `flutter_library`. It also carries the package's code and data assets (see [Data assets](#data-assets)) and its link hook (see [Link hooks](#link-hooks)). |
| `platforms` | A `flutter_plugin_platform` for each platform the plugin registers on. |
| `implements` | The app-facing plugin this one implements, the pubspec's `implements:`. |
| `exports` | The plugin's Android library, in a `select()` on `@platforms//os:android` with `[]` as the default. It is here, and not on the `android` platform, because rules_android finds a library to dex only through `exports`. |
| `native_deps` | Shared libraries to bundle for `dart:ffi`. |
| `apple_privacy_files` | The `PrivacyInfo.xcprivacy` files the plugin adds to an iOS or macOS app. |
| `assets`, `fonts`, `shaders`, `shader_includes`, `asset_platforms`, `asset_flavors`, `shader_platforms`, `shader_flavors`, `resources`, `data`, `additional_licenses`, `runtime_independent` | As on [`flutter_library`](#flutter_library). |

A federated plugin is an app-facing plugin (`url_launcher`) whose platforms other plugins implement (`url_launcher_android`, with `implements = "url_launcher"`); the app-facing plugin can name one of them its `default_package` on a platform. An application registers one implementation of each plugin on each platform, chosen as `flutter build` chooses it: the only one that reaches the application; else the one the application depends on directly; else the `default_package`. Two implementations depended on directly, or two with no default, fail analysis with flutter_tools' message. What the application depends on directly is the BUILD counterpart of an app pubspec's `dependencies`: the `deps` of the `flutter_application` (or `flutter_test`), and those of every `flutter_library` of the main repository it depends on. What a plugin, or a package from pub, depends on is not. To use another implementation than the default, add it to the application's `deps`. A `default_package` that does not reach the application, or that does not implement the plugin on that platform, is ignored, and the build prints flutter_tools' warning about it and succeeds.

A plugin in an app pubspec's `dev_dependencies` (a debugging overlay, say) is registered by `flutter run` and `flutter build` in debug and profile builds, and left out of release builds. rules_flutter has no `dev_dependencies`: an application registers a plugin exactly when its `deps` reach it, in every mode. To get flutter_tools' behaviour, list a dev-only plugin under a `select()` on `@rules_flutter//flutter:release`, which matches `-c opt` without the profile flag:

```starlark
flutter_application(
    name = "my_app",
    # ...
    deps = [
        "@deps//:url_launcher",
    ] + select({
        "@rules_flutter//flutter:release": [],
        "//conditions:default": ["@deps//:my_debug_overlay"],
    }),
)
```

Dart code that imports the plugin goes under the same `select()`, in a `flutter_library` of its own, say: a release build has no such package to compile it against.

A plugin's native code is a target of its own. Swift goes in a `flutter_apple_plugin_library`. Kotlin or Java goes in a `flutter_android_plugin_library`, whose `flutter_engine` is a `flutter_android_engine(neverlink = True)`: the plugin compiles against the engine, and each app ships an engine for its own ABI. An Android app that depends on the plugin packages the library, registers its plugin class, and merges its `manifest` (receivers, services, permissions) into the app's. The library gets a `BuildConfig` in its `java_package`, with `DEBUG` and `BUILD_TYPE` as Gradle would set them for the build's mode.

More plugins in the examples: [`e2e/plugin_example/greeting_plugin`](e2e/plugin_example/greeting_plugin/BUILD.bazel) has a Dart plugin class and no native code. [`e2e/ffi_example`](e2e/ffi_example) has plugins built on Native Assets, and [`multiply_plugin`](e2e/ffi_example/multiply_plugin/BUILD.bazel) there has a Dart plugin class with `native_deps`.

### flutter_application_variant

The same application with another `main`, as `flutter run -t test_driver/app.dart` runs one. The variant compiles the application's program again with the new entry point. It adds its own `srcs`, `deps` and `defines` to the application's, and keeps everything else: the Dart package, so `package:my_app/...` imports in the new `main` resolve, and the assets, native libraries, code assets, shaders and build options. The application's own `main` stays among the sources, so the new one can import it. The framework and each package are compiled once and shared by both.

It returns what `flutter_application` returns, so any platform rule takes it as its `application`. It loads from `integration_test.bzl`, because the integration test macros are built on it, but it works on its own:

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_application_variant")

flutter_application_variant(
    name = "driver_flutter",
    application = ":my_app",
    main = "test_driver/app.dart",
    srcs = ["test_driver/banner.dart"],
)

flutter_macos_app(
    name = "driver_app",
    application = ":driver_flutter",
    bundle_id = "com.example.myapp.driver",
)
```

| Attribute | Description |
|---|---|
| `application` | The `flutter_application` to rebuild. Required. It may be in another Bazel package. |
| `main` | The new entry point. Required. It may be outside `lib/`. |
| `srcs`, `deps`, `defines` | Added to the application's. A plugin that only the variant's `deps` bring is registered in the variant and not in the application. |
| `unchecked_srcs` | Added like `srcs`, but their imports are not checked against `deps`. For files a rule writes, whose imports are that rule's to get right. |
| `requires_packages` | Packages the program must have, by name. If no dependency brings one, analysis fails and names the `@<hub>//:<package>` target to add. |

### flutter_test

Compiles and runs widget and unit tests on Flutter's headless test engine, `flutter_tester`, as `flutter test` does. Assertions are on. This is [`e2e/hello_world`](e2e/hello_world/BUILD.bazel)'s:

```starlark
flutter_test(
    name = "widget_test",
    package = ":pubspec-metadata",
    main = "test/widget_test.dart",
    srcs = [
        "lib/common_widgets.dart",
        "lib/main.dart",
    ],
    deps = [
        "@deps//:flutter",
        "@deps//:flutter_test",
    ],
)
```

`flutter test` compiles a test in the package it is in. Here you name that package with `package`, and list in `srcs` the files of `lib/` the test imports. For a test of an app, name the app's `flutter_application` as `application` instead. The test then takes the application's package, sources, `deps`, code assets and assets, and its own `main`, `srcs`, `deps` and `code_assets` add to them:

```starlark
flutter_test(
    name = "widget_test",
    application = ":my_app",
    main = "test/widget_test.dart",
    deps = ["@deps//:flutter_test"],
)
```

The test's `defines`, `flavor`, `build_name` and `build_number` are its own, not the application's.

| Attribute | Description |
|---|---|
| `main` | The test file. Required. |
| `package` | The `dart_package_metadata` of the package the test is compiled in. Required, unless `application` is set. |
| `application` | A `flutter_application` or `flutter_application_variant` whose package the test is compiled in, as above. |
| `srcs`, `deps`, `code_assets`, `defines`, `flavor`, `build_name`, `build_number` | As on `flutter_application`. |
| `assets`, `shaders`, `shader_includes`, `require_sksl_shaders`, `additional_licenses` | As on `flutter_application`, for a test without `application`. |
| `data` | Files the test reads at run time: fixtures, FFI libraries, and [goldens](#golden-files). |
| `env` | Environment variables for the test. Values are literal, with no `$(location)` expansion. |
| `enable_impeller` | Render with Impeller, as `flutter test --enable-impeller` does, instead of software Skia. Default `False`. |
| `test_config` | The suite's `flutter_test_config.dart`, when it is above the BUILD file's package. See below. |
| `include_tags`, `exclude_tags` | Fixed `package:test` tag selection. See below. |

The usual test attributes (`size`, `timeout`, `shard_count`, `flaky`, `tags`, ...) work too.

**Running tests: `flutter test` and `bazel test` side by side.** The suite runs under Bazel's test protocol, as a `dart_test` does:

| `flutter test` | Bazel |
|---|---|
| `--name <regex>` | `--test_filter=<regex>`, matched against each test's full name, groups included. |
| `--tags golden`, `--exclude-tags slow` | For one run: `--test_env=DART_TEST_TAGS=golden`, `--test_env=DART_TEST_EXCLUDE_TAGS=slow`. Always: `include_tags = ["golden"]`, `exclude_tags = ["slow"]`. |
| `--total-shards`, `--shard-index` | `shard_count`. Each shard runs a contiguous share of the tests. |
| `--test-randomize-ordering-seed=<seed>` | `--test_env=DART_TEST_ORDERING_SEED=<seed>`, or `random`. |
| `--update-goldens` | `bazel run //:widget_test -- --update-goldens` (see [Golden files](#golden-files)). |
| `--coverage` | `bazel coverage --combined_report=lcov //...` |
| `--enable-impeller` | `enable_impeller = True` |
| `--dart-define` | `defines`, or `--@rules_dart//dart:extra_dart_defines` (see [flutter_application](#flutter_application)). |
| package:test's 30-second default timeout | The target's `size` or `timeout`. |

What differs:

- **Timeouts.** A test with no `timeout:` of its own runs as long as Bazel lets the target run. A `timeout:` written on a test still applies, and `Timeout.factor` scales Bazel's limit.
- **Tags.** The tags are `package:test`'s, from `@Tags` on the test library and `tags:` on a test. Bazel's own `tags` and `--test_tag_filters` choose targets, not cases. `include_tags` and `exclude_tags` take one boolean selector per entry, as `dart_test.yaml` does. `dart_test.yaml` itself is not read, so its per-tag settings, `add_tags` and presets don't apply.
- **Selecting nothing.** A target where `--test_filter` or `DART_TEST_TAGS` matches nothing passes, so `bazel test //... --test_filter=x` runs only the tests it names. A target whose `include_tags` or `exclude_tags` leave nothing fails. So does a suite that registers no test, as under `flutter test`.
- **Order.** A seed shuffles each group's cases after the filter, tags and shards have chosen them. The log prints `Shuffling test order with --test-randomize-ordering-seed=<seed>`, which repeats the order. Unset or `0` keeps the order of the file.
- **Library annotations.** `@Skip`, `@Timeout`, `@TestOn` and `@OnPlatform` apply as under `flutter test`. `@TestOn` and `@OnPlatform` are evaluated as runtime `vm` on the host's operating system, as `flutter test` does whatever the device. A suite that `@TestOn` excludes passes, with a note in the log.
- **Results.** Each case is in the `test.xml` Bazel collects, so CI shows cases rather than one result per target.
- **Coverage.** The merged LCOV report is `$(bazel info output_path)/_coverage/_coverage_report.dat`, and each test's own is `bazel-testlogs/<package>/<name>/coverage.dat`. It covers the `srcs` of the test and of every library and application it reaches that `--instrumentation_filter` selects (by default, the packages named on the command line). The test's `main` is not reported, as with every Bazel test. It counts lines only, not functions or branches.

**Widget creation tracking.** A widget built in a test records where it was built, as with `flutter test`'s `--track-widget-creation`. The test sets `--@rules_dart//dart:track_creation_locations` for itself and its `deps`, so every library agrees on it.

**Impeller.** `enable_impeller = True` is for a test that draws a shader Skia can't compile, or a golden meant to match an Impeller device. Impeller needs a GPU where the test runs, Metal on macOS or Vulkan on Linux, and a host without one, as most remote workers are, fails to start `flutter_tester`. Shaders are compiled for `flutter_tester` with the SkSL and Vulkan stages `flutter test` gives them, either way.

**`flutter_test_config.dart`** wraps the suite as under `flutter test`: its `testExecutable(FutureOr<void> Function() testMain)` runs it, so setup shared by a directory's tests lives in one file. The config used is the nearest one walking up from `main`'s directory, stopping after the directory holding `pubspec.yaml`. Bazel lets a BUILD file see only its own package, so the walk also stops at the package's top. For a config above it, set `test_config = "//path:flutter_test_config.dart"`. The config is compiled into the test, and its imports come from the test's `deps`.

**Where a test runs.** A test runs where its target platform runs, as a `cc_test` does. Its `deps`, native code included, and `flutter_tester` are built for the target platform, and Bazel runs the test on an execution platform that matches it. On a Mac, that is the Mac. To run tests elsewhere, such as on a Linux remote worker:

- `--platforms` builds every test for that platform, and Bazel runs them on a matching execution platform.
- For one test, wrap it in `platform_transition_test` from `@bazel_lib//lib:transitions.bzl` with `target_platform` set, and tag the `flutter_test` `manual`. `e2e/codegen`'s `:transitioned_native_asset_test` does this.
- `exec_group_compatible_with = {"test": [...]}` limits the execution platforms a test may run on, and a tag such as `no-remote-exec` keeps it local. Pin a test this way when its result depends on the machine, as a golden's does, or when it loads an FFI library from `data`.
- A toolchain of `@bazel_tools//tools/test:default_test_toolchain_type` in your root module changes where every test may run, `flutter_test` included.

A test sent to a machine other than the one it was built for fails when it starts, as a `cc_test` does.

#### Golden files

List the goldens in `data`, or the test can't see them:

```starlark
flutter_test(
    name = "widget_test",
    package = ":pubspec-metadata",
    main = "test/widget_test.dart",
    data = glob(["test/goldens/**"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)
```

Check this first when a golden fails. The comparator reads goldens from the test's runfiles, so a PNG that is in the source tree but not in `data` fails with `Could not be compared against non-existent file`. That is the same message as for a file that really is missing. Declaring every input is what keeps a cached pass meaningful.

Otherwise `matchesGoldenFile('goldens/x.png')` means what it means under `flutter test`. It reads `goldens/x.png` beside the test's `main`, and a mismatch reports the pixel difference. The four diff images (`masterImage`, `testImage`, `isolatedDiff`, `maskedDiff`) go to `bazel-testlogs/<package>/<target>/test.outputs/failures/`, and the failure message names the path. `flutter test` writes them beside the test, which under Bazel would be in a sandbox that is gone when the test ends.

To regenerate a target's goldens:

```sh
bazel run //:widget_test -- --update-goldens
```

This writes the PNGs into the source tree beside the test and names each one. The same flag under `bazel test` exits with code 64: a test can't write to the source tree, and regenerating into its sandbox would report success and change nothing. There is no command for the whole repository. Run one `bazel run` per target, which `bazel query 'tests(//...)'` can list.

Two limits come from Flutter itself:

- **Goldens depend on the host.** Fonts and antialiasing render differently on each operating system, so a PNG made on macOS may not match on Linux or Windows. Regenerate on the platform that checks them, or keep a golden directory per platform.
- **A comparator of your own disables regeneration.** If a test assigns its own `goldenFileComparator`, `--update-goldens` calls that comparator's `update()`. For a `LocalFileComparator` that writes into runfiles: the run passes, prints nothing, and leaves the source PNG unchanged.

### flutter_test_program and flutter_program_test

`flutter_test` is a macro over two rules. `flutter_test_program` compiles the test into a [`FlutterTestProgramInfo`](#providers), and `flutter_program_test` runs any target that provides one. `flutter_test(name = "x", ...)` declares the program `x.program` and the test `x`. It sends each attribute where it belongs: compile attributes to the program, run attributes (`include_tags`, `exclude_tags`, `env`, `size`, `timeout`, `shard_count`, `args`, `flaky`, `local`) to the test, and `data`, `tags`, `visibility` and the platform constraints to both.

The test's rule kind is `flutter_test` either way. To list every Flutter test, anchor the pattern, since `kind` matches a regular expression against `<rule> rule` and a bare `flutter_test` also matches `flutter_test_program` and `flutter_tester_binary`:

```sh
bazel query 'kind("^flutter_test rule$", //...)'
```

Use the two rules directly to put a step between compiling and running, or to run a program compiled another way. The test gets everything `flutter_test` gives one: the result protocol, tag selection, JUnit output, goldens and `--update-goldens`, code assets, sharding and coverage.

```starlark
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_program_test", "flutter_test_program")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_test_program(
    name = "widget_program",
    testonly = True,
    package = ":pubspec-metadata",
    main = "test/widget_test.dart",
    data = glob(["test/goldens/**"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)

flutter_program_test(
    name = "widget_test",
    program = ":widget_program",
    exclude_tags = ["slow"],
    shard_count = 2,
)
```

`flutter_test_program` takes `flutter_test`'s compile attributes and `data`. It builds the kernel, the `flutter_assets` tree, the code assets and the Native Assets manifest, and runs nothing. Mark it `testonly`, as `flutter_test` does. `flutter_program_test` takes `program`, `data`, `env`, `include_tags`, `exclude_tags`, and the usual test attributes.

A rule that compiles tests its own way returns `FlutterTestProgramInfo`, and `flutter_program_test` runs the result. Its kernel's entry point must speak `package:test_api`'s `RemoteListener` protocol over the WebSocket at `FLUTTER_TEST_HARNESS_PORT`, as the bootstrap `flutter_test_program` writes does. Its `source` is the file the runner reads `@Tags` from. That bootstrap is also what installs the golden comparator, so a program compiled another way must install one for `matchesGoldenFile` to compare anything.

### flutter_tester_binary

Runs a program on `flutter_tester` as an ordinary executable, with `bazel run` or as a tool of a build action. Use it to make build outputs with Flutter's renderer, such as store screenshots. Unlike a test's, those outputs don't have to be `testonly`.

```starlark
flutter_tester_binary(
    name = "render",
    package = ":pubspec-metadata",
    main = "tool/render.dart",
    enable_impeller = True,
    deps = ["//:my_app_lib", "@deps//:flutter", "@deps//:flutter_test"],
)

genrule(
    name = "screenshot",
    outs = ["screenshot.png"],
    cmd = "OUT=$@ $(execpath :render)",
    tools = [":render"],
)
```

You write the program as a test suite, because `flutter_tester` draws frames through `package:flutter_test`'s binding. Its work goes in the bodies of `testWidgets` and `test`, where `tester.pumpWidget`, `tester.view` and `RenderRepaintBoundary.toImage` work as they do in a test. The binary exits 0 when every case passes and non-zero when one fails, so a failed render fails the action. A suite that registers no test fails, and a case that runs past five minutes is stopped as stuck.

It is compiled as `flutter_test` compiles a test, and takes the same compile attributes, `enable_impeller` included, and `env`. It has no `include_tags` or `exclude_tags`, and `DART_TEST_TAGS` doesn't change it. Its `test_config` is not searched for: the program runs through a `flutter_test_config.dart` only when `test_config` names it.

The program gets the environment and working directory it was started with. For a build action that is the exec root, so you can hand it the paths of the action's inputs and outputs. Native Assets load from any working directory. Command-line arguments are not passed to the program.

Build it for the machine it runs on. `bazel run` does that. A rule that runs it in an action takes it as an executable attribute with `cfg = "exec"`, as `genrule` takes `tools`. With `enable_impeller = True` it needs that machine's GPU, so keep such actions off remote executors with `execution_requirements = {"no-remote-exec": "1"}`.

### Integration tests

`package:integration_test` tests run in the real app, on a device or in a browser. You write the test as `flutter create` users do, in `integration_test/app_test.dart`: `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`, then `testWidgets` that call the app's own `main()`. Each `testWidgets` is reported as a test case. `integration_test` goes in `pubspec.yaml`'s `dev_dependencies` with `sdk: flutter`, as usual.

There is one macro per platform, in `@rules_flutter//flutter:integration_test.bzl`. This is the macOS one:

```starlark
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_application")
load("@rules_flutter//flutter:integration_test.bzl", "flutter_macos_integration_test")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "app_flutter",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@deps//:flutter"],
)

flutter_macos_integration_test(
    name = "app_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    bundle_id = "com.example.myapp",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

`bazel test :app_test` does what `flutter test integration_test/app_test.dart -d macos` does. It builds the application with the test as its program, in debug mode whatever `-c` says, because the suite is driven over the VM service that a debug build serves. It launches the app on the host's desktop and drives the suite. The app's own `main` doesn't change: the test's program is a [`flutter_application_variant`](#flutter_application_variant) of the application.

| Platform | Macro | Extra required attribute | Where the app runs |
|---|---|---|---|
| macOS | `flutter_macos_integration_test` | `bundle_id` | The host's desktop, which must be unlocked and awake |
| Windows | [`flutter_windows_integration_test`](#windows-integration-tests) | | The desktop of the test's session |
| Linux | [`flutter_linux_integration_test`](#linux-integration-tests) | `application_id` | An X server the test starts for itself |
| Web | [`flutter_web_integration_test`](#web-integration-tests) | | A pinned headless Chrome |
| Android | [`flutter_android_integration_test`](#android-integration-tests) | `application_id` | An emulator the test boots for itself, or an attached device |
| iOS | [`flutter_ios_simulator_integration_test`](#ios-simulator-integration-tests) | `bundle_id` | A simulator the test makes for itself |

Every platform's macro takes `src`, `application`, `deps`, `srcs`, `test_config`, `data`, `env`, `include_tags`, `exclude_tags`, `runner`, and the usual test attributes. Other arguments pass through to the platform's app rule (`app_name`, `entitlements`, ...). The macro's own targets are named `__<name>_bootstrap`, `__<name>_program` and `__<name>_app`, and you don't name them.

On every platform:

- **One target per test file**, as `flutter test` launches the app once per file. `srcs` lists the files the test imports by relative path.
- **`deps` lists `@deps//:flutter_test` and `@deps//:integration_test`.** Without `flutter_test`, the BUILD file fails to load. Without `integration_test` in the test's or the application's `deps`, analysis fails and names the target to add.
- **Results are per case.** Each `testWidgets` is reported as it finishes, and the JUnit report names each one. `--test_filter` selects cases by full name and `shard_count` divides them among shards, as for `flutter_test`.
- **Tags, order and annotations work as for `flutter_test`.** The host reads `@Tags` on `src` and `tags:` on each `testWidgets`, so a case is selected the same way on every device. `DART_TEST_ORDERING_SEED` shuffles the cases. `@TestOn` and `@OnPlatform` are evaluated as runtime `vm` on the host's operating system, whatever the device, and a suite that `@TestOn` excludes passes without the app being launched.
- **Failures.** A failing case fails the target, and the report names it. So does an app that exits during the test, with the reason the device gives (`The macOS app exited with code 3 …`). A suite that registers no test fails.
- **`flutter_test_config.dart`** is found as for `flutter_test`, or named with `test_config`. It runs in the app, and on the host where goldens are compared, so a comparator or tolerance it installs applies to both. It is compiled in the app's package, so it may import the app's libraries as `package:<app>/…`.
- **Goldens work as in `flutter_test`.** `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the directory of `src`, so the goldens are `data`: `data = glob(["integration_test/goldens/**"])`. The app sends its picture to the host, which compares it with `flutter_test`'s comparator, on a phone or in a browser too. A mismatch fails the test, naming the golden and how far it is off, and leaves the failure's pictures in `bazel-testlogs/<target>/test.outputs/failures/`. `bazel run :app_test -- --update-goldens` writes the goldens into the source tree and names each file. A golden depends on the platform that drew it, so keep one per platform (the test chooses the path), and don't commit one that depends on the machine's fonts.
- **A test that can't run fails.** A locked screen, a missing simulator runtime, or no attached device is a failure, not a skip, because a skipped test reads as a pass.

On macOS:

- **The desktop must be unlocked and awake.** The runner keeps the display awake during the run, and fails, saying which, if the screen is locked or the display is asleep.
- **Tests take turns on the screen**, because a covered window stops drawing. They wait on a lock, `/tmp/rules_flutter-locks/macos-gui.lock`, which the operating system releases if a test dies.
- **`env`** reaches the runner and the app's process. `data` is available to the test at run time.

The macros are Tier 1. The Tier 2 rules they compose are below each platform's notes. All of them use `flutter_integration_bootstrap`, which turns the test file into a program, and `flutter_application_variant`. On macOS the others are `flutter_macos_app`, `flutter_desktop_app_integration_test` and `flutter_desktop_runner`.

#### Windows integration tests

`flutter_windows_integration_test` is `flutter test integration_test/app_test.dart -d windows`. It takes the macOS macro's arguments, without `bundle_id`, and passes `app_name` and the other `flutter_windows_app` arguments on.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_windows_integration_test")

flutter_windows_integration_test(
    name = "app_windows_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

- **It runs on a Windows host.** On a Mac or Linux host the test is skipped as incompatible. The app is built as `flutter_windows_app` builds it, with `windows/runner/` when the package has one and the built-in runner otherwise.
- **The window is real.** It is created on the desktop of the session the test runs in, and the test reads and taps what it draws. Windows that overlap keep drawing, so tests run at once with no lock. A session with no visible desktop, such as an SSH logon, still runs the test, but a screenshot needs an interactive session.
- **Use a short output base**, such as `bazel --output_base=C:/b test ...`. Windows limits a path to 260 characters, and a Flutter bundle is deep.
- An app that exits says `The Windows app exited with code 3 …`. `--update-goldens` writes the Windows goldens wherever the test's paths name, such as `goldens/windows/`.

Tier 2: `flutter_windows_app`, `flutter_desktop_app_integration_test` and `flutter_desktop_runner`.

#### Linux integration tests

`flutter_linux_integration_test` is `flutter test integration_test/app_test.dart -d linux`. It takes `application_id`, and passes `app_name` and the other `flutter_linux_app` arguments on.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_linux_integration_test")

flutter_linux_integration_test(
    name = "app_linux_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    application_id = "com.example.app_linux_test",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

- **It runs on a Linux host**, x86_64 or arm64. On a Mac or Windows host the test is skipped as incompatible.
- **It uses nothing of the host's but its C and C++ runtime.** The X server (`Xvfb`), GTK, Mesa's software OpenGL and the fonts come from a pinned set of Debian 13 packages, pinned by `sha256` for each architecture and downloaded only when a Linux integration test is analysed. The host needs no desktop, GTK or X server, and its own are not used, so a test runs the same on a workstation, over SSH and in CI. The host's glibc and libstdc++ must be at least Ubuntu 24.04's (glibc 2.39). The build checks every file of the runtime against that, and fails, naming the file, on one that asks for more.
- **Each test has its own X server**, so tests run at once with no lock, and never draw on your desktop.
- An app that exits says `The Linux app exited with code 3 …`.

Tier 2: `flutter_linux_app`, `flutter_desktop_app_integration_test`, and `flutter_desktop_runner`, whose `linux_runtime` is the runtime: `@flutter_linux_runtime_amd64//:runtime` or `@flutter_linux_runtime_arm64//:runtime`, a `flutter_linux_runtime`. To re-pin the runtime at a snapshot.debian.org timestamp, run `bazel run @rules_flutter//tools/update_linux_runtime -- <snapshot>`.

#### Web integration tests

`flutter_web_integration_test` runs the test in headless Chrome. `flutter test` refuses web devices (flutter/flutter#66264), and `flutter drive -d chrome` reports only a pass or a fail. This reports each `testWidgets` as a case, with `--test_filter`, tags and `shard_count`, as on the other platforms.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_web_integration_test")

flutter_web_integration_test(
    name = "app_web_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

The `flutter_web_app` arguments (`web_dir`, `base_href`, ...) pass through. The test's program is built as a web app in debug mode whatever `-c` says, served from a directory of its own on the loopback interface, and opened in the browser. `env` reaches the host runner only.

- **The browser is pinned:** Chrome for Testing's headless shell, downloaded by version and `sha256` for macOS (arm64, x64), Linux (x64, arm64) and Windows (x64). Only the host's own is downloaded, and only when a web integration test is analysed. A host with no pinned build skips the test, rather than run it in another browser. To use another, pass a `flutter_chrome_runner` of your own as `runner`. `bazel run @rules_flutter//tools/update_chrome_for_testing` prints a newer pin.
- **The suite is driven over the browser's DevTools protocol**, which a web app has in place of a VM service, so the page opens no port. The browser's profile is deleted and the browser killed when the test ends.
- **A lost page fails the target, saying why:** the browser exiting (`Chrome exited with code 139`), the page crashing, or the connection closing. A page that never starts the suite fails at the test's timeout, naming the step it didn't reach.
- **On Linux, the browser uses the pinned Linux runtime's libraries**, never the host's, and the build checks that it needs none the runtime lacks. It runs without Chrome's sandbox, as upstream's headless Chrome does: the sandbox needs unprivileged user namespaces, which Ubuntu has denied by default since 23.10, or Chrome's set-user-ID helper installed by root. Windows is not verified yet.

Tier 2: `flutter_web_app` or `flutter_web_bundle`, `flutter_web_app_integration_test` and `flutter_chrome_runner`. The bootstrap takes `src_import = "relative"`, because a web compile has no file-system root to name the test under.

#### Android integration tests

`flutter_android_integration_test` is `flutter test integration_test/app_test.dart -d <device>`. The app is built in debug mode for the device's ABI, installed, started, and its suite driven over the VM service, forwarded from the device.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_android_integration_test")

flutter_android_integration_test(
    name = "app_android_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    application_id = "com.example.myapp",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

```sh
bazel test :app_android_test        # on an emulator of its own
bazel test :app_android_test \
    --@rules_flutter//flutter/integration_test:android_device=attached \
    --test_env=ANDROID_SERIAL=<serial>  # on your phone
```

By default the test boots an emulator of its own:

- **The emulator and its system image are pinned:** emulator 36.2.12, and AOSP's Automated Test Device image of Android 15 (API 35), by `sha256`. Bazel downloads them for the host, about 1 GB, and only for a build that runs an Android test on the emulator. A Mac with Apple silicon boots the arm64-v8a image and Linux on x86_64 the x86_64 one, and the app is built to match. On other hosts (Windows, Intel Macs, Linux on arm64) the emulator test is skipped; run on an attached device there.
- **It needs the host's hypervisor:** Hypervisor.framework on macOS, KVM on Linux (`/dev/kvm` readable and writable by you; a cloud VM needs nested virtualisation). Without it the test fails before anything boots, and says how to enable it. On Linux the emulator loads its X client libraries from the pinned runtime of [Linux integration tests](#linux-integration-tests).
- **Each test has a fresh device.** It is made in the test's temporary directory and cold-booted with fresh data and no window, which takes 15 to 30 seconds on a Mac with Apple silicon, depending on its load. It is shut down however the test ends. A test needs nothing attached, booted or installed, and leaves nothing behind.
- **Emulator tests run side by side**, up to 16 at once. Each takes a pair of the ports `adb` knows emulators by (5554 to 5585, skipping those of emulators already running), under a lock (`/tmp/rules_flutter-locks/android-emulator-<port>.lock`). Bazel schedules each with three cores: two for the device and one for the emulator. The emulator talks to an `adb` server of the test's own that sees no USB or network device, so an attached phone is never touched. An emulator left behind by a killed test is shut down by the next test that takes its ports.
- **Logs.** The emulator's output and the device's whole log are kept with the test's outputs, as `emulator.log` and `logcat.txt` in `bazel-testlogs/<test>/test.outputs/`.

On an attached device (`--@rules_flutter//flutter/integration_test:android_device=attached`):

- The test runs on the device `ANDROID_SERIAL` names, or the only one attached. With none attached, or several and none named, it fails, naming `adb devices` and the variable. `ANDROID_SERIAL` given to a test that runs on the emulator fails it, naming the flag.
- Two tests on one device take turns on a lock (`/tmp/rules_flutter-locks/android-<serial>.lock`), which the operating system releases if a test dies.
- The app is built for arm64-v8a, and stays installed afterwards, as `flutter test` leaves it. `adb uninstall <application_id>` removes it.

On both:

- **`adb` and `aapt2` are the SDK's own**, from the `@androidsdk` your `MODULE.bazel` declares for building APKs (downloaded, or found at `ANDROID_HOME`), for the host the test runs on. An `adb` on your `PATH` is not used.
- **`abi`** sets the ABI the app is built for, whatever `--@rules_android//flags:android_platforms` says. It defaults to the emulator image's, or arm64-v8a on an attached device. The others are `x86_64` and `armeabi-v7a`. An emulator runner whose image runs another ABI fails analysis, naming both.
- **`integration_test`'s Android library is linked into the test's app**, and its Gradle build asks for `androidx.test:runner`, `androidx.test:rules`, `androidx.test.espresso:espresso-core` and `com.google.guava:guava`. Give each a version in your `MODULE.bazel`'s `rules_flutter_maven` install; Gradle's `1.2+`, `1.2+` and `3.3+` are ranges. Analysis names whatever is missing, and `bazel run @<hub>//android:maven_artifacts` prints the block. Your own app doesn't link it.
- **`env` is refused**, because an app the device starts can't be given an environment. Pass `defines` to the application instead.

To use another device, pass a runner of your own as `runner`: `flutter_android_emulator_runner(sdk = ..., emulator = ..., system_image = ...)`, whose `system_image` can be another `flutter_android_system_image` (another API level, say) and whose `cores` (default 2) and `memory_mb` (default 2048) size the device, or `flutter_android_device_runner(sdk = ...)`.

Tier 2: `flutter_android_app`, `flutter_android_app_integration_test`, `flutter_android_emulator_runner`, `flutter_android_system_image` and `flutter_android_device_runner`. With no `runner`, the macro also declares `__<name>_emulator` and `__<name>_device`, and the flag picks one.

#### iOS simulator integration tests

`flutter_ios_simulator_integration_test` is `flutter test integration_test/app_test.dart -d <simulator>`. The app is built for the simulator in debug mode, and the test makes a simulator, installs and starts the app, and drives the suite over the VM service.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_ios_simulator_integration_test")

flutter_ios_simulator_integration_test(
    name = "app_ios_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    bundle_id = "com.example.myapp",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

- **The simulator is the test's own:** an iPhone 16 on the newest installed iOS runtime that suits it, named `rules_flutter-<test>-<pid>-<start>`. It is shut down and deleted when the test ends, however it ends, a Bazel timeout included. It shares nothing with other tests or with your own simulators, so tests need no lock, and each shard gets its own. For another device type or runtime, pass `runner = flutter_ios_simulator_runner(device_type = ..., runtime = ...)`, with names that `xcrun simctl list devicetypes` and `xcrun simctl list runtimes` print.
- **It needs Xcode and an iOS runtime** (`xcodebuild -downloadPlatform iOS`). Without one the test fails, saying so. `DEVELOPER_DIR` reaches the test, so `xcrun` uses the Xcode you selected for the build.
- **The app is built for the arm64 simulator** (`sim_arm64`). An Intel Mac fails the test at analysis, saying so.
- **`env` is refused**, because an app the simulator starts can't be given an environment. Pass `defines` to the application instead.
- The test runs on macOS only, outside Bazel's sandbox, and never remotely. Bazel schedules it with two cores (the runner's `cpus`).

Tier 2: `flutter_ios_app`, `flutter_ios_app_integration_test` and `flutter_ios_simulator_runner`.

### flutter_profile_build

Builds its `targets` in profile mode, as `-c opt --@rules_flutter//flutter:profile` would, whatever the command line says. Use it to check a profile build in a plain `bazel test //...`, with no `--config=profile` in the CI job.

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_profile_build")

flutter_profile_build(
    name = "my_app_profile",
    tags = ["manual"],
    targets = [":my_app_macos"],
)

dart_test(
    name = "profile_bundle_test",
    data = [":my_app_profile"],
    main = "test/profile_bundle_test.dart",
)
```

| Attribute | Description |
|---|---|
| `targets` | The targets to build in profile mode, such as a `flutter_macos_app`. Required. |

The rule passes on the files of `targets`, so a test lists it in `data` and finds them in its runfiles. `tags = ["manual"]` keeps `bazel build //...` from building the profile app every time; the test that depends on it still builds it. A profile build needs the profile engine and `gen_snapshot` of the target platform, which are downloaded the first time. Its AOT snapshot can't be built for another desktop operating system, so give the target and its test the same `target_compatible_with` as the app. The iOS simulator has no profile mode.

### flutter_android_build

Builds its `targets` for the Android platforms in `android_platforms`, as `--@rules_android//flags:android_platforms=<those platforms>` would, whatever the command line says. Use it to check an APK for one ABI, or for several, in a plain `bazel test //...`.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_build")

flutter_android_build(
    name = "my_app_android_fat",
    android_platforms = [
        "@rules_android//:arm64-v8a",
        "@rules_android//:x86_64",
    ],
    tags = ["manual"],
    targets = [":my_app_android"],
)
```

| Attribute | Description |
|---|---|
| `android_platforms` | The platforms to build for, such as `@rules_android//:armeabi-v7a`, `@rules_android//:arm64-v8a` and `@rules_android//:x86_64`. One platform builds an APK for that ABI, several build one APK with all of them. Naming them in a BUILD file needs a `bazel_dep` on `rules_android`. Required. |
| `targets` | The targets to build, such as a `flutter_android_app`. Required. |

The rule passes on the files of `targets`, so a test lists it in `data` and finds the APK in its runfiles. Two builds of one APK have the same file name, so a test that reads more than one needs each under its own name. `e2e/plugin_example/android_apk.bzl` gives them one with a symlink.

### flutter_android_release

`bazel run` of it signs an App Bundle, and the APK of the same release build, with your upload key. It is the counterpart of `flutter build appbundle` and `flutter build apk --release`. [Release: App Bundle and signing](#release-app-bundle-and-signing) shows it in use.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_release")

flutter_android_release(
    name = "app_release",
    app_bundle = ":app_bundle",
)
```

| Attribute | Default | Description |
|---|---|---|
| `app_bundle` | required | An `android_application`: `flutter_android_app`'s `app_bundle`, or one you build from the composable rules with `bundle_config_file = "@rules_flutter//flutter:android_bundle_config.pb.json"`. It is built in release mode for `android_platforms`, whatever the command line says. |
| `android_platforms` | `@rules_android//:armeabi-v7a`, `:arm64-v8a`, `:x86_64` | The ABIs of the release build. |
| `key_properties` | `android/key.properties` | Where `key.properties` is, relative to the target's package in the source tree. It is a path, not a label, so the file and its passwords never enter the build. |
| `apksigner` | `@androidsdk//:apksigner` | The Android SDK's `apksigner`, which signs the APK. |

Commands, after `--`:

| Command | Flags |
|---|---|
| `sign` (the default) | `--key-properties=<path>`, `--output-dir=<dir>` |
| `create-key` | `--key-properties=<path>`, `--dname=<X.500 name>` (default `CN=Upload Key`) |

A relative path in a flag is relative to the directory you ran `bazel run` from. Signing uses the `jarsigner` and `keytool` of the Java runtime, so `--java_runtime_version` must name a full JDK, such as `remotejdk_25`.

### Code generation

rules_dart's `dart_codegen` and `dart_aggregate_codegen` replace `build_runner` with ordinary Bazel actions. They load from `@rules_dart//dart:defs.bzl`. A generated file goes in the `srcs` of the target that uses it, and lands beside its hand-written source, so a `part` directive resolves:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_aggregate_codegen", "dart_codegen")
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_application")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

# One output per input file, such as a json_serializable part.
dart_codegen(
    name = "user_json",
    package = ":pubspec-metadata",
    src = "lib/user.dart",
    generator = "//tools:json_generator",
    output_suffixes = [".g.dart"],
)

# One output from all the inputs, such as a route registry.
dart_aggregate_codegen(
    name = "registry",
    package = ":pubspec-metadata",
    srcs = ["lib/model.dart", "lib/order.dart"],
    generator = "//tools:aggregate_generator",
    outputs = ["lib/registry.g.dart"],
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = ["lib/user.dart", ":user_json", ":registry"],
    deps = ["@deps//:flutter"],
)
```

A `generator` is a `dart_binary` whose `main` hands a `package:build` `Builder` to rules_dart's shim runner. The runner speaks the rules' command line, runs as a persistent worker, and is built for the execution platform. The Builder reads its input with `buildStep.readAsString(buildStep.inputId)` and writes the file the rule declared, `buildStep.allowedOutputs.single`. An aggregate Builder finds the other sources with `buildStep.findAssets`. The rule's `config` reaches the Builder's factory as `options.config`.

```dart
// tools/json_generator.dart
import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, (_) => _JsonBuilder());

class _JsonBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final source = await buildStep.readAsString(buildStep.inputId);
    // ... derive the output from `source` ...
    await buildStep.writeAsString(buildStep.allowedOutputs.single, output);
  }
}
```

```starlark
# tools/BUILD.bazel
load("@rules_dart//dart:defs.bzl", "dart_binary")
load("@rules_dart//dart/ext:defs.bzl", "builder_shim_library")

builder_shim_library(
    name = "builder_shim",
    pub_hub = "@generator_pub_deps",
)

dart_binary(
    name = "json_generator",
    srcs = ["json_generator.dart"],
    code_assets_from_packages = False,
    main = "json_generator.dart",
    visibility = ["//visibility:public"],
    deps = [
        ":builder_shim",
        "@generator_pub_deps//:build",
    ],
)
```

The generators have a pub hub of their own, read from a `pubspec.lock` beside them by rules_dart's extension:

```starlark
# MODULE.bazel
dart_pub = use_extension("@rules_dart//dart/pub:extensions.bzl", "pub")
dart_pub.from_lock(
    name = "generator_pub_deps",
    lock = "//tools:pubspec.lock",
)
use_repo(dart_pub, "generator_pub_deps")
```

It must resolve the packages the shim runner links: `analyzer`, `args`, `bazel_worker`, `build`, `crypto`, `glob`, `logging`, `package_config`, `path`, `pub_semver` and `yaml`. [`e2e/codegen`](e2e/codegen) is the worked example these come from, with generated code in dependency packages and hot reload over regenerated sources. Its `tools/pubspec.yaml` lists those packages.

#### go_router_builder

rules_dart has macros for pure-Dart builders such as json_serializable and freezed (`@rules_dart//dart/ext:defs.bzl`). go_router_builder depends on Flutter, so rules_flutter has its macro: `go_router_codegen` writes the `.g.dart` part of each source that declares `@TypedGoRoute` routes, as `dart run build_runner build` would. The builder comes from rules_flutter's own lock. Your lock needs `go_router`, which your sources and the generated code import.

```starlark
load("@rules_flutter//flutter/ext/go_router:defs.bzl", "go_router_codegen")

# lib/routes.dart declares `part 'routes.g.dart';`.
go_router_codegen(
    name = "routes",
    package = ":pubspec-metadata",
    srcs = ["lib/routes.dart"],
    annotation_dep = "@deps//:go_router",
    deps = ["@deps//:flutter"],
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = ["lib/routes.dart", ":routes"],
    deps = ["@deps//:flutter", "@deps//:go_router"],
)
```

`annotation_dep` is your `go_router` library. It defaults to `@pub_deps//:go_router`, so with a hub named `pub_deps` you can leave it out. `config` takes the builder's options as JSON, as `build.yaml` gives them. For Gazelle to write these targets, register the builder in the BUILD file at your repository's root, with `runtime_dep` naming the same library as `annotation_dep`:

```starlark
# gazelle:dart_builder TypedGoRoute macro=@rules_flutter//flutter/ext/go_router:defs.bzl%go_router_codegen shim=@rules_flutter//flutter/ext/go_router:shim produces=.go_router.g.part runtime_dep=@deps//:go_router key=go_router_builder:go_router_builder
```

#### flutter_gen_l10n

Generates `AppLocalizations` from `.arb` files, as `flutter gen-l10n` does.

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
    package = ":pubspec-metadata",
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

The generated files land beside the `.arb` files, which must all be in one directory, or in `output_dir`. List the target in `srcs` to compile them. The app needs `intl` in its own lock, as with `flutter gen-l10n`; the generator has its own copy.

As with `flutter gen-l10n`, the generated `localizationsDelegates` list registers `package:flutter_localizations`'s Material and Cupertino delegates. Those localize `package:flutter`'s own widgets, not `material_ui`'s or `cupertino_ui`'s, so an app built on those packages finds no `MaterialLocalizations` in any locale but English. Such an app registers the generated `delegate` with its UI package's delegates instead:

```dart
// package:material_ui's
localizationsDelegates: [
  AppLocalizations.delegate,
  ...GlobalMaterialLocalizations.delegates,
],
```

`l10n.yaml` is not read, because Bazel must know the output file names during analysis, before any file is read. Its settings are attributes instead, with `flutter gen-l10n`'s defaults:

| `l10n.yaml` / `flutter gen-l10n` flag | Attribute | Default |
|---|---|---|
| `template-arb-file` | `template_arb_file` | `app_en.arb` |
| `output-dir` | `output_dir` (relative to the package, which stands for the project directory) | beside the `.arb` files |
| `output-localization-file` | `output_localization_file` | `app_localizations.dart` |
| `output-class` | `output_class` | `AppLocalizations` |
| `preferred-supported-locales` | `preferred_supported_locales` | `[]` |
| `header` | `header` | `""` |
| `use-deferred-loading` | `use_deferred_loading` | `False` |
| `nullable-getter` | `nullable_getter` | `True` |
| `required-resource-attributes` | `required_resource_attributes` | `False` |
| `use-escaping` | `use_escaping` | `False` |
| `relax-syntax` | `relax_syntax` | `False` |
| `use-named-parameters` | `use_named_parameters` | `False` |
| `suppress-warnings` | `suppress_warnings` | `False` |
| `format` | none | |

Where it differs from `flutter gen-l10n`:

- **Output names come from file names.** The rule names the outputs from the `.arb` file names, while the generator decides what to write from each file's `@@locale`. If `app_english.arb` declares `"@@locale": "en"`, Bazel expects `app_localizations_english.dart`, the generator writes `app_localizations_en.dart`, and the build fails with "output was not created". Keep the two consistent. Bazel can't read the files during analysis to check this for you.
- **One output per primary language.** `app_es.arb` and `app_es_419.arb` produce one `app_localizations_es.dart` holding both classes, as upstream does.
- **Line endings are always LF.** Upstream copies `pubspec.yaml`'s line endings, which would make the output depend on a file the action doesn't declare.
- **There is no `format`.** Formatting runs the `dart` binary, which the action doesn't have. rules_dart's format check covers only hand-written files, so the generated files are not checked either.

The generator is a part of `flutter_tools`, cut out with patches when the repository is fetched. A Flutter release that moves the code the patches touch fails the fetch. A failure at run time with a `PathNotFoundException`, or a compile error naming a missing `dart:io` type, also points at a newer release than the patches were made for. [`flutter/private/flutter_gen_l10n_repo.bzl`](flutter/private/flutter_gen_l10n_repo.bzl) explains what to check.

On Windows, the repository extracts all of `packages/flutter_tools` and uses twenty of its files. The longest path is around 130 characters from the repository root, which fits within the 260-character limit with a short `output_user_root`.

### Lower-level rules

`flutter_application` is made of these. Most apps never use them directly.

| Rule | What it does |
|---|---|
| `flutter_kernel` | Compiles Dart to a kernel `.dill` against Flutter's platform kernel. `aot = True` compiles for AOT in any mode. |
| `flutter_aot_snapshot` | Compiles Dart to AOT native code with `gen_snapshot`: a `.dylib` for macOS and iOS, an ELF `.so` for every other platform. |
| `flutter_asset_bundle` | Builds the `flutter_assets/` tree: `AssetManifest.bin`, `FontManifest.json`, `NOTICES.Z` (`NOTICES` for the web), and the asset files. |
| `flutter_native_library` | Pairs a native library with the files its bindings were built against. See [Hot reload across a native rebuild](#hot-reload-across-a-native-rebuild). |

### Providers

Load providers from `@rules_flutter//flutter:providers.bzl`. Each field's full description is there.

**`FlutterSdkInfo`** comes from the Flutter toolchain, and carries the SDK and engine files of the target platform:

```starlark
sdk = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
```

The fields a custom rule most often uses:

| Field | Type | Description |
|---|---|---|
| `version` | `str` | The Flutter version, such as `"3.50.0"`. |
| `engine_revision` | `str` | The engine commit. |
| `dart`, `dartaotruntime` | `File` | The bundled Dart SDK's `dart`, and its runtime for AOT snapshots. |
| `gen_snapshot` | `File` or `None` | The AOT compiler. `None` in debug mode, and for a toolchain that can't compile one. |
| `flutter_tester` | `File` or `None` | The headless engine tests run on. `None` where the SDK has none, such as a cross-compiling toolchain. |
| `frontend_server` | `File` | `frontend_server_aot.dart.snapshot`, the kernel compiler. |
| `platform_kernel_dill` | `File` | `platform_strong.dill`, the debug platform kernel. |
| `platform_kernel_dill_product` | `File` or `None` | `platform_strong_product.dill`, the release platform kernel. `None` in debug mode. |
| `patched_sdk` | `Target` | The Flutter-patched Dart SDK. |
| `icu_data` | `File` | `icudtl.dat`. |
| `sdk_files` | `DartSdkFilesInfo` | The Dart SDK's files, grouped by the tool that reads them (`run`, `aot_run`, `kernel`, `dart2js`, `dart2wasm`, ...), as rules_dart declares them. An action takes the group of the one tool it runs. |
| `tool_files` | `depset[File]` | Every file of the Dart SDK and the patched SDK, about 1,050 files and 650 MB, for running any SDK command such as `dart pub`. |
| `engine_library` | `Target` or `None` | The desktop engine library of the build mode: debug under `-c dbg`, profile under `--@rules_flutter//flutter:profile` where the toolchain has one, release otherwise. `None` for mobile and the web. |
| `font_subset` | `File` or `None` | The icon tree shaker's font subsetter. |
| `impellerc` | `File` or `None` | The shader compiler. |
| `shader_lib` | `list[File]` | The files shaders may include. |
| `target_os`, `target_arch` | `str` | The cross-compilation target, or empty for a native build. |

The rest describe how the toolchain was assembled (`sdk`, `sdk_defines`, `host_tools`, `kernel_debug`, `kernel_release`, `engine`, `gen_snapshot_info`, `framework_json`, `slice_labels`), and a few files only rules_flutter's own rules need (`kernel_worker`, `dart_libraries_json`, `material_icons_font`, `vm_isolate_snapshot`, `isolate_snapshot`, `linux_sysroot`).

An action whose output doesn't depend on the target platform, such as a kernel compile or shader compile, can take its tools from `@rules_flutter//flutter:exec_tools_toolchain_type` instead. Its `flutter_exec_tools_info` is a **`FlutterExecToolsInfo`**: the same tools, for the host they run on.

**`FlutterApplicationInfo`** is provided by `flutter_application` and `flutter_application_variant`, and read by the platform rules:

| Field | Type | Description |
|---|---|---|
| `aot_output` | `File` or `None` | The AOT native code. `None` in debug mode. |
| `aot_object` | `File` or `None` | On Apple platforms, the object file `gen_snapshot` wrote beside `aot_output`, which its dSYM is made from. |
| `strip_aot` | `bool` | Whether `gen_snapshot` strips the AOT binary. `False` with `--no-strip`. An Android app or AAR strips `libapp.so` whatever it says, as the Android Gradle plugin does. |
| `kernel_dill` | `File` or `None` | The kernel. `None` in a release or profile build. |
| `is_debug` | `bool` | Whether this is a debug build. |
| `flutter_assets` | `File` | The `flutter_assets/` tree. |
| `icu_data` | `File` | `icudtl.dat`. |
| `native_libraries` | `list[struct]` | The shared libraries of `native_deps`, one record each, as `FlutterInfo.native_libraries` has them, merged where a library arrives by more than one route, without those of a federated plugin's implementation the application did not choose. |
| `native_assets_manifest` | `File` | The Native Assets manifest the app ships, which `@Native(assetId:)` bindings resolve through. |
| `program_assets` | `DartProgramAssetsInfo` | The code and data assets the program ships, after link hooks. |
| `plugins` | `list[struct]` | The plugins of the whole app, each with `name` and `platforms`, a dict of platform to `FlutterPluginPlatformInfo`. |
| `apple_plugin_libraries`, `linux_plugin_libraries`, `windows_plugin_libraries`, `android_libs` | `depset[struct]` | The plugins' native libraries, which each platform's rules link. |
| `apple_privacy_manifests` | `depset[File]` | The plugins' `PrivacyInfo.xcprivacy` files. |

**`FlutterApplicationInputsInfo`** is also provided by `flutter_application` and `flutter_application_variant`. Its one field, `inputs`, is the program the application was compiled from, which `flutter_application_variant` changes and compiles again.

**`FlutterInfo`** is provided by `flutter_library`, `flutter_plugin` and the pub packages. It carries what a package contributes to the apps that depend on it, merged over its dependencies. Among its fields:

| Field | Type | Description |
|---|---|---|
| `pub_assets` | `depset[struct]` | Each package's asset files: `package_name`, `package_root`, `asset_path` (the path from the package root), `file`, and the `platforms` and `flavors` it is limited to. |
| `pub_fonts`, `pub_shaders` | `depset[struct]` | Each package's font families and shaders, in the same shape. |
| `plugins` | `list[struct]` | The plugins, each with `name` and `platforms`. |
| `native_libraries` | `depset[struct]` | The shared libraries of plugins' `native_deps`, and those they load through `dynamic_deps`, one record each: `library`, the `package` whose `native_deps` brought it, the first-party `sources` it is built from, the `contract` its bindings were generated from, the `link_inputs` it was linked from, or the `dsym` its link made (with `link_inputs_unset_reason` when the build cannot see either). |

**`FlutterFontFamilyInfo`** is provided by `flutter_font_family`: its `family`, and its `fonts`, each a **`FlutterFontInfo`** with `file`, `weight`, `style` and `asset`, as on `flutter_font`.

**`FlutterPluginPlatformInfo`** is provided by `flutter_plugin_platform`. Its fields are the rule's attributes, and `lib` is the native library in a build for that platform, `None` in any other.

**`FlutterNativeLibraryInfo`** is provided by `flutter_native_library`: its `libraries`, its `binding_contract` files, and its `hot_patch`.

**`FlutterTestProgramInfo`** is provided by `flutter_test_program` and read by `flutter_program_test`: a compiled test, and what the runner needs beside it.

| Field | Type | Description |
|---|---|---|
| `kernel` | `File` | The kernel `flutter_tester` starts with: a `.dill`, or, when `kernel_list` is true, a list of the kernels in `kernels`, which the runner joins when it starts `flutter_tester`. |
| `kernel_list` | `bool` | Whether `kernel` is a list of kernels. |
| `kernels` | `depset[File]` | The kernels `kernel` lists; empty when it is one kernel. |
| `assets` | `File` | The `flutter_assets` directory the test runs with. |
| `tester`, `icu_data` | `File` | `flutter_tester` and its ICU data, for the platform the program is built for. |
| `display_path` | `str` | The suite's path in the runner's reports. |
| `source` | `File` | The test file, read for its `@Tags`. |
| `packages` | `list[DartPackageInfo]` | Every package the program runs, its own included, which `bazel coverage` maps library files through. |
| `native_assets_manifest` | `File` | The Native Assets manifest the kernel was compiled with. |
| `native_files` | `list[str]` | Runfiles paths of native-asset libraries the runner puts on the loader's search path on Windows. Empty elsewhere. |
| `enable_impeller` | `bool` | Whether the test renders with Impeller. |
| `target_os` | `str` | The operating system the program is built for. |
| `runfiles` | `runfiles` | Everything the program needs at run time except the runner: every file above, native-asset libraries, and `data`, goldens included. |

**`FlutterIntegrationRunnerInfo`** is provided by the integration test runner rules (`flutter_desktop_runner`, `flutter_chrome_runner`, `flutter_android_emulator_runner`, `flutter_android_device_runner`, `flutter_ios_simulator_runner`). It holds the `family` of device (`"desktop"`, `"web"`, `"android"` or `"ios_simulator"`), the runner's `launcher_config`, the `runfiles` it needs, and the test's `execution_requirements` and `target_compatible_with`. A test rule takes only a runner of its own family.

**`FlutterLinuxRuntimeInfo`** is provided by `flutter_linux_runtime`: the files of the pinned Linux runtime, which a Linux runner carries.

## The dev tool

`flutter_bazel`, in `tools/dev_tool/`, is the development loop. It builds a target, installs and launches it on a device, and gives you hot reload and hot restart, as `flutter run` does. It speaks the same `--machine` JSON-RPC protocol as `flutter run`, so IDE plugins that drive `flutter run --machine` can drive it. It also opens an HTTP channel that scripts and coding agents can use to drive the running app.

### Running an app

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_macos -d macos
```

`run` builds the target, launches it, and watches your files. Saving a Dart file triggers a hot reload. These are the flags most people use, beside their `flutter run` equivalents where there is one:

| `flutter run` | `flutter_bazel run` | What it does |
|---|---|---|
| `-t lib/main.dart` | `-t`, `--target` | The Bazel target to build and run. Required. |
| `-d` | `-d`, `--device` | Where to run it. Repeat it for several devices at once. Left out, the host desktop. See [Choosing a device](#choosing-a-device). |
| `--debug`, `--release` | `-c`, `--compilation_mode` | Bazel's compilation mode: `dbg`, `opt` or `fastbuild`. A hot reload run builds `dbg` and a profile run `opt`, and naming another mode with those is refused. |
| `--profile` | `--profile` | Profile mode: AOT code with the Dart VM service, for DevTools. Builds `-c opt --@rules_flutter//flutter:profile`. Not on the iOS simulator. |
| `--no-hot` | `--no-hot` | Run without hot reload. |
| `--dart-define KEY=VALUE` | `--dart-define KEY=VALUE` | A Dart define, passed to the build and kept on reload and restart. Repeatable. |
| `--start-paused` | `--start-paused` | Hold the app at the start of `main()` until a debugger resumes it. |
| `--route` | `--route` | The initial route. |
| `--machine` | `--machine` | Speak the JSON-RPC protocol on stdout. |
| `--no-devtools` | `--no-devtools` | Don't launch DevTools. |
| | `--config` | A config from your workspace's `.bazelrc`, passed as `--config=<name>` to every Bazel command of the run, reloads included. Repeatable. |
| | `--build-arg` | An extra argument for `bazel build`. Repeatable. |
| | `--no-watch` | Don't reload on save. Watching is on in terminal mode and off in `--machine` mode. |
| | `--no-http-control-channel` | Don't open the HTTP channel. |
| `--wasm` | `--wasm`, `--no-wasm` | On the web, run the dart2wasm build (`--wasm`) or the DDC dev loop (`--no-wasm`). See below. |
| `--web-port` and the like | `--web-port`, `--web-hostname`, `--web-launch-url`, `--web-viewport`, `--web-run-headless`, `--web-header`, `--web-browser-flag` | Web dev server and browser settings. `--web-viewport 393x660@3` lays the app out at a phone-sized viewport whatever the window's size. |

On the web, with neither `--wasm` nor `--no-wasm`, the target decides. A `flutter_web_app` or `flutter_web_bundle` with `js_fallback = False` ships WebAssembly only, so it runs under dart2wasm, and the startup output says so. Any other target runs the DDC dev loop. Under dart2wasm the `app.*` agent commands work, but there is no hot reload: dart2wasm has no incremental compiler and can't swap code into a running module. A restart rebuilds and reloads the page, and an explicit `--hot` is refused. `--no-wasm` on a WebAssembly-only app runs it under DDC anyway, with a warning, and code that only works under WebAssembly (an `Int64List`, say) fails there.

`flutter_bazel build` builds without running. `flutter_bazel attach --debug-url <uri>` attaches to an app that is already running. `--help` on each command lists every flag.

### Shorter commands with bazel_env

[bazel_env.bzl](https://github.com/buildbuddy-io/bazel_env.bzl) puts Bazel-built tools on your `PATH` under names you choose, so the dev tool becomes a two-letter command. Add it to `MODULE.bazel` and declare the tool:

```starlark
# MODULE.bazel
bazel_dep(name = "bazel_env.bzl", version = "0.10.0", dev_dependency = True)
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

Then run `bazel run //:bazel_env` once.

It builds the tool, writes a shim to `.bazel_env/bin/fl`, and prints setup instructions for [direnv](https://direnv.net). They amount to this `.envrc` next to `MODULE.bazel`:

```sh
watch_file .bazel_env/bin
PATH_add .bazel_env/bin
if [[ ! -d .bazel_env/bin ]]; then
  log_error "ERROR[bazel_env.bzl]: Run 'bazel run //:bazel_env' to regenerate .bazel_env/bin"
fi
```

After `direnv allow`, the command is `fl run -t //:my_app_macos -d macos`, from any directory in the workspace. Outside `bazel run`, the tool finds the workspace root with `bazel info workspace`. Add `.bazel_env` to `.gitignore`. Without direnv, `bazel run //:bazel_env print-path` prints the directory to add to `PATH` yourself.

The rest of this section spells the command out in full, so it works before you set this up.

### Choosing a device

`-d` takes:

| Id | Reaches |
|---|---|
| `macos`, `linux`, `windows` | The host desktop. |
| `chrome` | A browser, through the dev module server. |
| `ios-simulator`, `ios-simulator:<udid>` | The booted simulator, or the one named. |
| `ios`, `ios:<udid>` | The attached iPhone, or the one named. |
| `android`, `android:<serial>` | Whichever device `adb` picks, or the one named. |

`flutter_bazel devices` lists every device `-d` can reach, with the `-d` id of each, as `flutter devices` does:

```console
$ bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- devices
Found 4 connected devices:
  sdk gphone64 arm64 (mobile) • android:emulator-5554 • android-arm64  • Android 16 (API 36) (emulator)
  iPhone 17 (mobile)          • ios-simulator:362F... • ios            • com.apple.CoreSimulator.SimRuntime.iOS-27-2 (simulator)
  macOS (desktop)             • macos                 • darwin-arm64   • macOS 27.2 26B123 darwin-arm64
  Chrome (web)                • chrome                • web-javascript • Google Chrome 157.0.8103.40
```

It lists booted simulators, attached and network-paired iOS devices, Android devices `adb` can use, the host desktop and an installed Chrome. A device that is listed but not usable, such as an unauthorized phone, is named under the list. Its options:

- `--machine` prints `flutter devices --machine`'s JSON.
- `--device-connection attached` or `wireless` keeps one kind.
- `--device-timeout <seconds>` gives each lookup (`simctl`, `devicectl`, `adb`) longer than its 3 seconds. A lookup that doesn't answer in time is named under the list rather than holding it up.
- `--config` and `--build-arg` reach the build of the workspace's `adb`, as on `run`.

An id has to say what kind of device it names, so a bare UDID or serial is refused. An emulator is `-d android:emulator-5554`, not `-d emulator-5554`. Guessing the kind would mean asking `simctl`, `devicectl` and `adb` on every launch. When an id is refused, the tool does ask them, and names the form to pass, for example `pass -d ios-simulator:<udid>`.

**Android.** The tool drives the device with the `adb` and `aapt2` of the workspace's own `@androidsdk`, the SDK the app builds with, whether downloaded or found at `ANDROID_HOME` (see [Android](#android)). It builds them for the host before it asks the device anything. Nothing needs to be on your `PATH`, and you don't need Android Studio. A workspace with no Android SDK lists no Android devices and builds nothing for Android, and `-d android` there fails, saying so.

The tools build with the same Bazel options as the run's app, so building them doesn't make Bazel discard the app's analysis. The options differ only by the device's ABI, and not at all when your `.bazelrc` already sets `--@rules_android//flags:android_platforms` to it. An adb server that Android Studio started keeps running: `adb` restarts the server only when it speaks another protocol version (the `1.0.41` that `adb version` prints), and current platform-tools releases all speak the same one.

**iOS.** For `-d ios`, the tool lists attached devices with `devicectl`, and ignores devices that were paired once but aren't attached now. With two attached, it asks for `-d ios:<udid>` rather than guessing. A device has two identifiers, the hardware UDID that Xcode shows and the CoreDevice UUID that `devicectl` prints, and either works there.

### Hot reload and hot restart

In terminal mode, press `r` to reload and `R` to restart, or just save a file. A reload compiles only the changed libraries and injects them into the running isolate, keeping app state. A restart re-runs `main()`, so it also picks up changes to code that runs only at startup.

An edited shader reloads too, including one from a package in your workspace and one whose `#include` you changed. The reload recompiles it and has the engine reinitialize the program, as `flutter run` does. A web page can't reinitialize a shader, so there the reload says so, and a restart picks it up.

An app whose `main` is outside its package's `lib/`, like `flutter run -t test_driver/app.dart`, reloads and restarts the same way. Such a file has no `package:` URI, so the build and the dev loop both compile it as `org-dartlang-app:///<its workspace path>`. Its compile can read only the `main` and `srcs` you declare, so list the files it imports by relative path in `srcs`, and edits to them are picked up. As in any Dart program, reach code under `lib/` through `package:` imports, not `../lib/...`. A relative import there loads a second copy of the library, and its types stop matching the originals.

**Native libraries.** Dart code can be swapped into a running process, but a native library the process has already loaded can't. When a rebuild changes one of the app's native libraries (`native_deps` or Native Assets, including the `.framework` each becomes on iOS), a restart (`app.restart` with `fullRestart: true`) relaunches the process instead of restarting the isolate, and says so in its response. The HTTP channel, its token and the `appId` stay the same across a relaunch, and only the log buffer starts over. If the new process can't launch, for example because the device has no room for the new install, the restart fails with the reason and the run ends, since the old process is already gone.

A hot reload never relaunches anything, because replacing the process loses the state a reload exists to keep. What it does after a native edit depends on what `flutter_native_library` declares; see [Hot reload across a native rebuild](#hot-reload-across-a-native-rebuild).

### App output

A running app's console output is forwarded for the whole run: `print`, `debugPrint`, `NSLog`, Java stack traces and uncaught errors. Forwarding starts before the VM service is up, so startup failures are visible.

In terminal mode the app's stdout goes to the tool's stdout and its stderr to the tool's stderr, as with `flutter run`. With more than one `-d`, lines are prefixed with `[<device>] `. In `--machine` mode the output arrives as `app.log` events, and nothing else is written to raw stdout, which belongs to the protocol stream.

A Dart `print()` reaches both the process's stdout and the VM service's `Stdout` stream, so reading both would print every line twice. Each platform therefore has exactly one log source:

| Platform | Source |
|---|---|
| macOS, Linux, Windows | The process's stdout and stderr. |
| Android | `adb logcat`, filtered to `flutter*`, `DartVM`, `AndroidRuntime`, `System.err`, and fatal records. |
| iOS simulator | A `simctl spawn log stream` scoped to the app process. |
| iOS device | `devicectl --console`, plus lldb's output. lldb stays attached for the whole run. |
| Chrome, dev loop | The DWDS VM service's `Stdout` and `Stderr` streams. |
| Chrome, WASM or production JS | Chrome DevTools Protocol console events. |
| `attach` | The VM service's `Stdout` and `Stderr` streams, since there is no process to read. |

### Assets and fonts

An edit to a bundled asset goes live on hot reload or on save, like a Dart edit. The tool knows which workspace directories feed the `flutter_assets` tree, so a few directory listings tell it whether an asset changed. A run whose assets are untouched doesn't run a `bazel build` for a Dart edit.

When an asset has changed, the bundle is rebuilt, and only the entries that differ are uploaded into the app's devFS. That is what makes it work on a phone, inside an APK, and inside a sandboxed macOS app, none of which can read `bazel-out`. Everything else still resolves to what shipped, because the engine keeps the original bundle behind the devFS directory. A changed font also re-registers the engine's font collection, so re-exporting a `.ttf` takes effect at once, where `flutter run` waits for a restart.

On the web the dev server serves `assets/` from the build tree on every request, so a reload only drops the page's caches. Fonts are the exception there: the web engine registers them once at startup and has no way to reload them, so the reload says so rather than reporting success.

### Debugging from the first line

`flutter_bazel run --start-paused` holds the app at the beginning of `main()`, so a debugger can attach before any app code runs. Each platform gets the switch the way it accepts one: an engine switch on desktop, an intent extra on Android, an argument on iOS. The web has no switch. DWDS holds `main()` until a client resumes it, so there the tool holds back the run request.

The tool reports the pause only once it has seen the main isolate's own pause event. A target that ignored the switch is called out, rather than leaving you waiting at a debugger for an app that already ran. While the app is paused, `app.*` commands answer with the reason instead of blocking. `--route` and `--trace-startup` are skipped with a warning, because both need a framework that has started.

### Physical iOS devices

**Finding the VM service.** On every other device, the engine prints the VM service URI in the app's log, and the tool reads it off the same stream as the app's output. An iPhone is different. A wirelessly attached device has no console channel, and a wired device's console belongs to the `devicectl` call that launched the app. So the tool finds the URI through the app's mDNS advertisement instead.

Every Flutter app built in debug or profile mode advertises `_dartVmService._tcp` with its port and auth code. The debug and profile `Info.plist` that rules_flutter generates declares the matching `NSBonjourServices` entry, so this works for any app built with these rules, with no configuration.

| Connection | VM service host | Port |
|---|---|---|
| Wired | `127.0.0.1`, through an `iproxy` forward, because the service binds to the device's loopback. | The advertised port, forwarded. |
| Wireless | The device's own address, from the advertisement. | The advertised port, dialled directly. |

The tool picks the connection from what `devicectl list devices` reports. A wireless launch also passes `--vm-service-host=0.0.0.0`, so the service is reachable from off the device. A wired launch doesn't.

If discovery fails, check these:

- **Local Network permission.** On macOS the mDNS socket needs it. If it is denied, the error names System Settings > Privacy & Security > Local Network. The device also prompts once, the first time an app advertises.
- **Lost queries.** mDNS runs over UDP, and the spec requires retransmission. Against a USB-attached iPhone a single query succeeded about two times in five, so the tool retransmits with the backoff the spec gives. In practice it resolves in about 200 ms, and the worst we have seen is 3.3 s.
- **`dns-sd` doesn't show what this tool sees**, in either direction. It answers from mDNSResponder's table, which includes records a raw multicast socket can't reach. Over USB, CoreDevice proxies the device's Bonjour records in as local-only registrations. So `dns-sd` listing the phone while the tool sees nothing over USB is correct on both sides. The table also keeps stale `_dartVmService` records on `lo0` from booted simulators with no app running. Unplugged, the phone multicasts for real on `en0` or `en1`, and the raw socket sees it. If you do use `dns-sd`, read the interface index on each `Add` line. Interface 1 is `lo0` and proves nothing about the device.

**Launch times.** Expect the first log line to take longer than on a host. A debug build runs under the JIT breakpoint, and the engine traps to the debugger for every executable page it allocates, each trap writing to device memory over the debugserver link. On a recent iPhone with a healthy Xcode install, the time from resume to the engine's first log line measured about 8 seconds over a cable and about 40 seconds over Wi-Fi.

A launch that takes minutes means something is wrong on the host, not the phone. The usual cause is an unfinished Xcode symbol copy, which leaves lldb without the shared cache, so check that Xcode has finished copying symbols for the device before looking anywhere else. The tool prints a "still waiting" note at 45 seconds, so you can tell a slow launch from a hang.

Hot reload and restart get the same allowance. A reload is quick, since only the changed library is compiled. A restart re-runs `main()` and pays the breakpoint cost again, so it takes about as long as the launch. The time allowed for each call is five minutes wired and fifteen wireless, against thirty seconds on a host. Those limits are only there to stop a run that will never succeed, so they are sized for the slowest host state we have seen. A shorter limit would be worse than waiting: it abandons the call and closes the VM service connection, reporting a timeout for a restart that was about to succeed.

**Debugger stops.** On iOS 26 and later, the engine announces each new page of JIT code at a breakpoint, and the debugger has to write the page before the app may run it. The tool resumes every one of those stops itself, as `flutter_tools` does, rather than letting lldb continue on its own. lldb loses some of them when two threads allocate code at once ([llvm/llvm-project#190956](https://github.com/llvm/llvm-project/issues/190956)), and the app then stops on `EXC_BAD_ACCESS (code=50)` with its VM service silent.

Any other stop, such as a native crash, is written to the app's output with a backtrace. The debugger then detaches and the run ends, as it does when an app exits on any other platform. Stopping a run, or a launch that fails part way, terminates the app on the device and every helper process the tool started.

The device's log comes from `devicectl --console`, which also carries devicectl's own progress banners, and from lldb, which holds the debugserver the JIT depends on. `flutter_tools` reads the same two with Xcode 26 and later, noting that `idevicesyslog` stopped working.

### Driving the app from a script

`flutter_bazel run` opens an HTTP control channel by default. IDE integrations, coding agents and end-to-end test harnesses can drive the running app through it, without a terminal: tap widgets, enter text, read text back, take screenshots, reload, restart, and shut down.

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- \
  run -t //:my_app_macos -d macos --machine
```

**Finding the channel.** The tool prints the channel's record on stderr. Under `LOG_FORMAT=json` that record is one JSON line, listing every endpoint with a ready-made URL, token included. The token goes in a query parameter, not an `Authorization` header:

```json
{"message":"http_control_channel","uri":"http://localhost:PORT",
 "token":"...","tokenParam":"token","endpoints":[
   {"method":"POST","path":"/command",
    "url":"http://localhost:PORT/command?token=...", ...}, ...]}
```

That record lists the per-app endpoints as templates, with `{appId}` in the path. Once an app is up, a `session_ready` record names it, with `uri`, `token` and the endpoints again with the id filled in. So a client reading stderr has everything in one line:

```json
{"message":"session_ready","appId":"___my_app_macos_macOS","uri":"http://localhost:PORT","token":"...",
 "endpoints":[{"method":"GET","path":"/sessions/___my_app_macos_macOS/logs",
   "url":"http://localhost:PORT/sessions/___my_app_macos_macOS/logs?token=..."}, ...]}
```

**The protocol on stdout.** With `--machine`, stdout carries the protocol stream. It starts with `daemon.connected` and then reports `app.start`, `app.started` and the rest. A line is a protocol message only if it is a `[{…}]` envelope. Anything else is passthrough output that a client should show to the user rather than parse. That is `flutter run`'s convention too, and it is what makes `bazel run` safe here: Bazel forwards a successful action's stdout, so a run that first rebuilds the tool prints a line like `Generated: /…/flutter_bazel` before the first envelope.

The examples below set `URI`, `T` (the token) and `APP` (the `appId`) from those records.

#### Endpoints

| Endpoint | Verb | Purpose |
|---|---|---|
| `/command?token=…` | `POST` | Run a protocol method against the session. Body: `{"method":"app.<X>", "params":{"appId":"…", …}}`. |
| `/commands?token=…` | `GET` | What this run can do right now: `{"protocolVersion", "commands":[{"name","longRunning"}]}`. |
| `/sessions/{appId}/logs?token=…` | `GET` | The app's console output, from a bounded ring buffer. See [Reading logs](#reading-logs). |
| `/sessions/{appId}/screenshot/native?token=…` | `GET` | A PNG of the app as the platform sees it. Works on every device. `&screen=<id or name>` picks a screen of a device that has several; see [Screens](#screens). |
| `/sessions/{appId}/screens?token=…` | `GET` | The device's screens, and which one the app is on. |
| `/sessions/{appId}/screenshot/flutter?token=…` | `GET` | A PNG of the widget tree from the engine. Not available at the pinned Flutter; see [Screenshots](#screenshots). |

The endpoints speak plain HTTP/1.1, so `curl -s "$URI/..."` works. If your `curl` tries HTTP/2 by default, add `--http1.1`.

#### Which commands are available

Once the app is up, these are the commands:

- **Reading the screen:** `app.dumpSemanticsTree`, the whole accessibility tree in one answer. See [Reading the semantics tree](#reading-the-semantics-tree).
- **Driving widgets:** `app.dumpWidgetTree`, `app.tap`, `app.longPress`, `app.doubleTap`, `app.drag`, `app.hover`, `app.hoverExit`, `app.setWindowActive`, `app.scrollIntoView`, `app.enterText`, `app.getText`, `app.getRect`, `app.waitFor`, `app.waitForAbsent`, `app.pageBack` and `app.settle`. Extensions the app registers before `main()` on every launch serve these, so they survive a hot restart. See [Driving widgets](#driving-widgets).
- **Keys:** `app.pressKey`, on every run, including `--profile` web runs. See [Pressing keys](#pressing-keys).
- **Lifecycle:** `app.hotReload`, `app.restart`, `app.stop` and `daemon.shutdown`.
- **Run-specific:** `app.buildInfo` on native debug runs, and `app.setViewport` on web runs.

The set of commands isn't fixed when a client connects. It grows through the run, and it describes this run rather than the tool:

- A web run gains `app.setViewport` once the browser is up. It never offers `app.buildInfo`, because only a `-c dbg` native build carries the record that command reads.
- The widget-driving commands are offered once the tool knows the run carries the agent extensions. That is every native run, the DDC dev loop on the web, and any web bundle built in debug (`--wasm`, or `--no-hot -c dbg`). They answer once the app is reachable, which on the web and on an iPhone is well after `app.started`.
- `app.pressKey` is offered on every run, since a web bundle without the extensions can still take keys through the browser.

So re-read `/commands` rather than caching the first answer. `longRunning` marks commands that rebuild or recompile before answering. Give those a generous timeout. They are the ones `app.progress` events are sent for.

A `--machine` client doesn't need the endpoint: it gets the list in `daemon.connected`, and again in every `daemon.commandsChanged`. `daemon.connected` also carries `protocolVersion`. The protocol stream is also the only place for things the channel can't push:

- `app.devTools` carries the DevTools URL.
- `app.debugPort` carries the VM service's `port`, `wsUri` and `baseUri`.
- `app.dtd` carries the Dart Tooling Daemon the app is registered with.
- `app.webLaunchUrl` carries the address a web run is served at. The browser the tool launches uses a scratch profile and may be headless, so that URL is how you open the page in your own browser.

The full list of events is in the header comment of `tools/dev_tool/lib/machine_protocol.dart`.

**Commands sent early wait.** `app.started` means `main()` has begun, which is what `flutter run`'s protocol means by it. An app that has begun running hasn't built a widget tree yet. On `-d chrome` the gap is DWDS, which holds `main()` until the browser has connected. On an iPhone it is the app's own start, measured at 61 seconds after `app.started` for a debug build.

A command sent in that window waits it out rather than failing, so you can send commands as soon as you see `app.started`, with no readiness poll. The wait is reported as a pair of `app.progress` events: "Waiting for the app to render its first frame" opens it, and what the wait found closes it, so a client can tell a frame that arrived from one that never did. The wait has no time limit. A first frame that arrives late, on a loaded host say, makes the app drivable whenever it arrives. While the tool waits, it logs a `first_frame_slow` warning, and on a host sends a "Still waiting" `app.progress` every thirty seconds. The wait ends when the app paints, when it exits (commands are then refused, saying it exited before rendering), or when the run ends. Waiting for a specific widget is still yours to ask for, with `app.waitFor`.

**Reload, restart and stop.** `app.restart` is `flutter run --machine`'s command. Without `fullRestart` it is a hot reload, and with `fullRestart: true` it is a restart. It also accepts `pause`, `reason` and `debounce`. `reason` and `debounce` have no effect, since this tool already runs one reload or restart at a time. `pause: true` is refused, since the tool doesn't leave the isolate paused. The replies are described in [Reload and restart responses](#reload-and-restart-responses).

`app.stop` stops the one app its `appId` names, as `flutter run`'s does, and a run driving two devices carries on with the other. A bare `app.stop` with no `appId` is refused, rather than read as "all of them". `daemon.shutdown` ends the run: every app, the browser, the compiler and the tool itself.

Both answer at once, even while a reload is waiting for the first build or a rebuild. When the run ends, any command still waiting or running is answered with an error saying the run is shutting down (HTTP 503 on the control channel).

An app that dies under a connected run ends the run too. The tool says why, in the platform's words and with the app's last output, and exits with a failure status. The `app.stop` event carries the reason in `error`, as `flutter run`'s does. An app that exits with code 0, one you stopped, and one closed on its device are not failures. On the iOS Simulator, for example, closing the app from the app switcher or with `xcrun simctl terminate` ends the run with status 0, while a crash fails it. An `attach` run ends with status 0 when the app's VM service closes for good.

#### Web runs

A web bundle is driven through a page bridge, and only in a debug build. `--wasm` and `--no-hot -c dbg` serve a bundle built by dart2wasm or dart2js, which has no VM service, so `registerExtension` there only fills a private table. A debug build therefore registers the agent extensions itself and installs a JavaScript bridge on the page, which the tool calls over the browser's DevTools protocol. The widget-driving commands then work as on the DDC dev loop, `app.dumpWidgetTree` included.

A `--profile` or release bundle compiles the extensions out. The commands are then absent from `/commands`, rather than present and refusing, and the run says so once at startup, in an `agent_surface_unavailable` log record. Such a run can still serve `app.pressKey`, `/logs`, `screenshot/native` and `app.restart`.

If a debug page never installs the bridge, as with a build from before the bridge existed, a command fails after 30 seconds, saying so. A page paused in the browser's own DevTools answers nothing until you resume it.

**Driving the browser yourself.** `app.webLaunchUrl` also carries the browser's DevTools protocol endpoint: `cdpPort`, and `webSocketDebuggerUrl` for the app's page. The same two fields are on the `web_app_url` log record, for a client reading stderr. Chrome picks the port, so nothing else tells you where it is. With it you can send your own `Input.dispatchKeyEvent`, `Runtime.evaluate` or trace. Chrome takes several DevTools clients at once, so yours doesn't displace the tool's.

The page URL is the one listed when the browser came up. It survived a `--wasm` hot restart when we checked. If it stops answering, re-read `http://127.0.0.1:<cdpPort>/json` and pick the `page` target on the app's origin, as the tool does before each of its own uses.

#### Reading the semantics tree

`app.dumpSemanticsTree` returns the app's accessibility tree as text: every node a screen reader would see, with its label, state, actions and position. It is the cheapest way to read a whole screen, and unlike a picture it says what each control is and where to tap it.

```sh
curl -s -X POST "$URI/command?token=$T" \
  -d '{"method":"app.dumpSemanticsTree","params":{"appId":"'$APP'"}}' | jq -r .result.text
```

```
view 0 800x600 @1x
#3 scopesRoute @400,300 800x600
  #30 header "Hello World" @400,28 120x28
  #6 "count: 0" @400,254 56x20
  #7 button "Increment (agent)" [tap] @400,280 171x32
  #8 textField [tap] @400,320 200x48
  #27 [scrollUp] @400,444 200x80
    #13 "item 0" @400,416 200x24
    #17 hidden "item 4"
  #31 button tooltip="Increment" [tap] @756,556 56x56
```

It takes `appId` and nothing else, and answers `{"text": …}`. Two fields can join it. `notRendering` means the app isn't drawing frames. `frameMissed` means a frame that was pending didn't finish within 5 seconds, so the tree is from before it.

How to read the text:

- Each view starts with a line `view <id> <width>x<height> @<pixel ratio>x`.
- Each node line is `#<id>`, then the node's role and flags, then its strings (`"label"`, `value=`, `hint=`, `tooltip=`, and `id=` for a `Semantics.identifier`), then its actions in brackets, then `@x,y`, the centre of the node in logical pixels, and its size.
- Indentation is nesting, and nodes come in the order a screen reader walks them.
- Flags are Flutter's names without `is` (`button`, `textField`, `header`, `obscured`, `readOnly`, `focused`). Each pair of states is folded into one word: `checked`, `unchecked` or `mixed`; `on` or `off`; `selected` on the one that is; `expanded` or `collapsed`; `disabled` for a control that isn't enabled.
- `hidden` marks a node scrolled out of view. It has no `@` point, because its rect lies under whatever is drawn there. Scroll it into view, then dump again.

Some nodes are left out. A node that carries nothing but its children is dropped, and its children move up a level. A node merged into its parent is dropped too, because its text and actions are already on the parent's line, which is how a screen reader sees it. Actions every focusable node has (`focus`, `showOnScreen`, cursor movement) aren't listed.

To act on a node, pass its `@` point to a pointer command, as `"x"` and `"y"` of `app.tap`. A node with a label can also be named with the `semanticsLabel` selector, for `getRect`, `waitFor` and the rest. To type into a field, tap it and then call `app.enterText` with no selector. Node ids aren't selectors: they last only as long as the widget that produced the node.

This isn't Flutter's own `debugDumpSemanticsTree` text. That text gives each rect in its parent's coordinates, some behind a transform matrix, so it doesn't say where to tap. Flutter still serves it, once semantics are on, through its `ext.flutter.debugDumpSemanticsTreeInTraversalOrder` extension, in DevTools or over the VM service.

On `hello_world` the dump is 1,135 bytes, which we estimate at 300 to 600 tokens, and Flutter's text is 8,198 bytes. A screenshot, by Anthropic's published rule of width × height / 750 after scaling to fit 1568 pixels and 1.15 megapixels, costs about 670 tokens for the 800x632 macOS window at 1x, and about 1,500 for the 1260x2736 iOS simulator or the 1080x2424 Pixel.

Semantics are off in a Flutter app until something asks for them. The first agent command of any kind turns them on, and they stay on until the app restarts, so the dump needs no setup step. The cost is what any app pays while a screen reader runs: the framework builds the semantics tree for each frame that changes it, and the platform's accessibility layer receives it.

The dump lists every view the app's main isolate renders. A window that runs its own engine, like the second window in `e2e/multi_window_example`, is a separate isolate, which the tool doesn't drive. Like the other agent commands, the dump is refused on a profile or release build, with the reason: the agent extensions are compiled into debug builds only.

#### Reading logs

You poll `/logs` with a cursor. There is no long-lived connection, and each call returns exactly what you ask for.

| `since` | Meaning |
|---|---|
| omitted | The last 200 lines. Use this when you have no cursor yet. |
| `-N` | The last `N` lines. |
| `0` | Everything still buffered, oldest first. |
| `N > 0` | Resume at line `N`. Pass a previous `nextCursor`. |

`limit` caps the page, with a default and maximum of 500. A non-numeric `since` or a non-positive `limit` is a `400`, because a mistyped cursor would otherwise look like a working poll loop that re-reads the tail forever.

```sh
# Tail, then poll forward.
curl -s "$URI/sessions/$APP/logs?token=$T"
# {"lines":[{"index":812,"text":"flutter: meter -18dB","error":false}],
#  "nextCursor":813,"launch":1,"missed":0,"dropped":0,"closed":false}

curl -s "$URI/sessions/$APP/logs?token=$T&since=813"
```

The fields in the response:

- `error` marks lines that arrived on an error channel: the process's stderr, a VM service `Stderr` event, or `console.error`. It is a channel, not a severity. iOS and Android deliver the whole device log over one stream, so there an engine `[ERROR:…]` line has `error: false`. Match on the text if you care about those.
- `missed` is non-zero when the cursor you asked for had already been evicted, so a poller learns it has a gap instead of reading a short page as complete. `dropped` is the total evicted over the run.
- `closed` turns true once the app's output has ended, so a poll loop can stop. The buffer survives the app's exit, so a crashed app's final output is still readable.
- `launch` is which launch of the app the page came from: 1 for the original, and one more for each relaunch. Each launch buffers from zero, so when `launch` changes, drop your cursor and tail again.

#### Screenshots

Use `screenshot/native`. It captures the app the way the platform sees it, and works on every device. It uses `screencapture` on macOS, a read of the X display on Linux, `devicectl device capture screenshot` on the iOS simulator and iPhones, `adb screencap` on Android, and the browser's own capture on the web. On iOS this needs Xcode 27 or later (see [Requirements](#requirements)), because the simulator and hardware both go through `devicectl device info displays` and `devicectl device capture screenshot`.

`screenshot/flutter` would ask the engine for the widget tree alone, with no window chrome. The engine can't produce that under Impeller, and there is no engine screenshot on the web at all. Since Flutter 3.47 every platform renders with Impeller by default, so every device answers `501`, naming `screenshot/native`. The tool doesn't try to detect an app that has turned Impeller off, because `screenshot/native` captures either way.

Both endpoints wait for the app to go idle before capturing, so a screenshot taken right after `app.tap` shows what the tap did. Without the wait you would get the frame from before the action painted, which looks the same as a feature that didn't work. The response says what you got, in `X-Settled`:

- `yes`: the app was idle first.
- `no`: the wait ran out, or the app is backgrounded.
- `skipped`: you passed `settle=false`, or the run's app can't be asked (a `--profile` or release web bundle).

For anything but `yes`, `X-Settle-Detail` gives the reason, percent-encoded so it can hold characters a header can't. Any URI-component decoder gives back the text. The wait never fails the capture, since an app that can't settle is the one whose picture you most want. `app.settle` is the same wait as a command, for use between two of your own.

A screenshot has one 30-second budget, starting once the app has drawn its first frame. Listing the screens, waiting for a posture and the capture all spend from it, and the error for running out says which step was waiting.

##### Screens

A device draws to a *screen*, and most have one. An iPhone Duo simulator has two built-in screens, and the app draws on the one its posture (folded, half open, open) turns on. An iPhone mirrored to a wireless display has a second, external one. `GET /sessions/{appId}/screens` lists them:

```json
{"screens": [
  {"id": "9552AE4F-…", "name": "LCD",   "type": "integrated", "width": 1398, "height": 2034, "active": true,  "primary": true},
  {"id": "40096A2C-…", "name": "LCD-1", "type": "integrated", "width": 2007, "height": 2853, "active": false, "primary": false}
]}
```

- `active` says whether the app is on that screen now. It is `null` where the device doesn't say, which is every device with one screen.
- `type` is what the platform calls the screen. On iOS that is Apple's display type: `integrated` for the device's own, `wireless`, `tvOut`, `carPlay`, and so on.
- An iOS screen with no unique id has the id `displayId:<n>`. A simulator's ids change on every boot, so read the list again rather than keeping one.

`screenshot/native` with no `screen` captures the screen the app is on:

- With one built-in screen, that one. An external screen (`wireless` and the like) is never chosen unless you name it.
- With several built-in screens, the one with `active: true`. A simulator doesn't report its posture for the first seconds after it boots, so the request asks again until it does.
- With several active, none active, or no report in time, the answer is `422`, with the screens listed in `error` and, as `screens`, in the body. The tool doesn't pick one.

`&screen=<id or name>` names a screen instead: its `id`, its `displayId:<n>`, or its `name`. An unknown name, or one that matches two screens, gets the same `422`. This is how you capture an external screen. An iOS screen with no unique id can be captured only as the primary one, and naming any other answers that it can't be captured.

`screen` and `window` are different parameters. `screen` is a display the device has. `window`, on macOS only, is one window of the app, matched by exact title, on that Mac's one screen. You may pass `screen` to a device with one screen, as long as it names that screen (`main`, or the device's name).

#### Driving widgets

The methods that target a widget (`tap`, `longPress`, `doubleTap`, `drag`, `getRect`, `getText`, `enterText`, `scrollIntoView`, `waitFor` and `waitForAbsent`) take exactly one selector. The selectors follow `flutter_driver`'s finders:

| Param | Matches |
|---|---|
| `key` | A widget whose `ValueKey` value equals the string. |
| `text` | A widget whose displayed text equals the string, read the way `getText` reads it: a `Text`, including a `Text.rich` by its spans' plain text, a `RichText`, or a text field's contents. |
| `tooltip` | A `Tooltip` whose `message` equals the string. |
| `type` | A widget whose runtime type name equals the string, for example `ElevatedButton`. |
| `semanticsLabel` | A widget whose semantics label equals the string. |

```sh
curl -s -X POST "$URI/command?token=$T" \
  -d '{"method":"app.tap","params":{"appId":"'$APP'","key":"increment"}}'
```

No selector, or more than one, is refused with a `422` (see [How a command says no](#how-a-command-says-no)). The other parameters are `durationMs` (longPress, drag, scrollIntoView), `dx` and `dy` (drag, scrollIntoView), `scrollableKey` (scrollIntoView, a `ValueKey` only), `timeoutMs`, `settle` and `requireHit`.

Put the `Key` on the widget you would point at, such as the `Chip`, the `ListTile` or the button, rather than on the `Text` it builds. A selector reaches the same distance for every method.

- **`getText`** returns the text of the first text-bearing descendant of the match, in pre-order (`Text` including `Text.rich`, `RichText`, `EditableText`). It lists all of them in `texts`, so a container with two strings shows as two: `{"text":"Increment","texts":["Increment"]}`.
- **`enterText`** takes `text` as the string to type, so it is the one method that doesn't accept the `text` selector. With a selector, it focuses the first `EditableText` under the match and types into it, with no tap needed first, and reports what it typed into: `{"enteredText":"hi","into":"ValueKey(emailField)"}`. With no selector, it types into whatever has focus, reporting `"into":"focused"`.

**Settling.** After sending input, a method waits until the app is idle before it answers, so a following `getRect` or `getText` sees the layout after the action. `timeoutMs` bounds the wait, 10000 by default. Every input command's reply says how the wait ended, in `settled`: `yes`, `no`, or `skipped` (for `settle: "false"`, or an app that is backgrounded). These are the same values `app.pressKey` and the screenshot headers use. When it isn't `yes`, `settleDetail` says why. It gives the number of animations still running, and zero means the app was backgrounded during the command.

A wait that runs out is `no` on an otherwise successful reply, not an error. The input was delivered before the wait began, so don't send the command again, or it taps twice. An app that was already backgrounded answers at once, because backgrounding is what stops frames, so there is nothing to wait for.

Some apps never go idle. A spinner, a progress indicator or any endless `AnimationController` keeps a frame callback pending for as long as it runs, so every command against such an app spends its whole timeout and then answers `settled: "no"`. `settle: "false"` turns the wait off for one command, like `flutter_driver`'s `runUnsynchronized`. You give up the guarantee: a `getText` straight after an unsynchronised `tap` races the rebuild and reads the old value about half the time, so wait for the value you expect with `app.waitFor`. `settle` accepts only `"true"` and `"false"`, because a typo would otherwise silently pick the opposite.

**A backgrounded app takes input but shows nothing.** An app the OS has backgrounded stops producing frames. That happens on a device with a locked screen, and on macOS when a window is hidden or covered after it had been in front. (A window that was covered from the moment it opened keeps drawing, because the embedder reacts only to a change.) Input still lands and its handler still runs, but nothing rebuilds, so a `getText` straight afterwards answers with the tree as it was, not with what your tap changed. On a locked Pixel this looked like a tap that did nothing, and the value appeared when the device was unlocked.

In that state every input command adds a `notRendering` field to an otherwise successful reply, and so do `app.getText`, `app.getRect`, `app.waitFor` and `app.waitForAbsent`. When one of those finds nothing, its error carries the same note. This matters most after a restart in that state, when the tree holds only what `runApp`'s first frame built, and a widget the app shows once its data loads isn't there yet.

**Reaching the widget.** Being in the tree isn't the same as being where a pointer can land. A child of a scroll view that is scrolled off screen is laid out outside the viewport, and a widget behind a dialog is covered. A selector still finds it, and it still has a rect. So `tap`, `longPress`, `doubleTap` and `drag` hit-test the point first, and refuse when nothing there resolves to the target. The refusal says which case it is and what to do: scroll the widget into view, or move what covers it. This is `WidgetController`'s `warnIfMissed`, made an error, because a success reply for an event nobody received is worse than an error. Pass `requireHit: "false"` to send the event at that point anyway.

`app.scrollIntoView` is the way through, and its `reachable` field says whether a tap would now land. `iterations` counts the drag-scrolls of a lazy list. `0` means the target was already built and `Scrollable.ensureVisible` was used.

**Hover and the mouse.** `app.hover` moves a synthetic mouse to the centre of the widget a selector names, or to `x` and `y` in logical pixels. `app.hoverExit` takes it off the app. Neither moves the system cursor, so the real mouse stays free. The synthetic mouse stays where you left it, as a real one does.

`app.tap`, `app.longPress`, `app.doubleTap` and `app.drag` take `"pointer": "mouse"` to press with that mouse's primary button instead of a finger, so a widget sees hover and press together. All four also take `x` and `y` instead of a selector. A mouse press with neither lands where the mouse already is, so you can hover, then press.

The `app.hover` reply carries `cursor`, the cursor the widget under the mouse asked for (`click`, `text` and so on), so you can check it without looking at the screen. The engine applies a hover's cursor to the host, so the tool puts the arrow straight back after each move, and the host's cursor is the arrow again by the time the reply comes. `app.hoverExit` puts it back too, and says so in `cursorRestored`. The host's cursor shape can still change for an instant, and a real pointer over the window gets its own shape when it next moves.

A hover has no timer of its own. To see a tooltip, pass `"settle": "false"` and wait as long as the tooltip's delay. `app.settle` and the wait after every command treat the app as idle when no frame is scheduled, as `pumpAndSettle` does, so a visible tooltip doesn't keep them from settling. `app.settle` answers `settled` as `yes`, `no` or `skipped`, with `settleDetail` when it isn't `yes`, like every other command.

**Window focus.** `app.setWindowActive` with `"active": "true"` or `"false"` tells the framework the window is focused or not (`AppLifecycleState.resumed` or `inactive`), without changing the frontmost app. Only the framework sees the change. The native window's key state is untouched, a real click or key in the window flips it back, and chrome AppKit draws, such as the traffic lights, doesn't follow. A macOS window with no title bar can never become key, so there this is the only way to see the active state.

#### Pressing keys

`app.pressKey` presses one key, or one key with modifiers held, in whatever has focus:

```sh
curl -s -X POST "$URI/command?token=$T" \
  -d '{"method":"app.pressKey","params":{"appId":"'$APP'","key":"Control+K"}}'
```

It takes no selector. Focus the field first, with `app.tap` on it or by pressing `Tab`.

Keys are named the way Playwright's `keyboard.press` names them, since that is what agents already know:

- A character: `a`, `A`, `!`. A single character is case-sensitive, and `Shift+a` types `a`, so write `A` or `Shift+KeyA` for a capital.
- A `KeyboardEvent` key or code: `Enter`, `Tab`, `Backspace`, `ArrowDown`, `Escape`, `KeyA`, `Digit1`, `Space`.
- Modifiers joined with `+`: `Control+K`, `Shift+Tab`, `Meta+A`. `ControlOrMeta` is Meta on Apple platforms and Control elsewhere.

An unknown name is refused by name, with the spelling it probably meant: `Ctrl` gets `Did you mean "Control"?`. Unlike Playwright, only modifiers can be held, so `a+b` is refused. Send one command per key.

How the key reaches the app depends on the device, and the reply names the route in `route`:

| `route` | Devices | What happens | What it reaches |
|---|---|---|---|
| `browser` | Chrome: the DDC dev loop, `--wasm`, `--profile` | Real, trusted input sent to the app's page over the DevTools protocol (`Input.dispatchKeyEvent`). | What a keyboard reaches in that browser: the browser's own text editing, and the key events Flutter's web engine sees. |
| `framework` | macOS, iOS, Android, Linux, Windows | Simulated inside the app, modelled on `flutter_test`'s key simulator: each key as a `ui.KeyData` plus the legacy `flutter/keyevent` message the engine sends. A key the framework leaves unhandled then goes where the platform's input method would take it: typed text into the focused field, Return to the field's action (which is what fires `onSubmitted`), and on macOS the Cocoa editing selectors AppKit would produce, sent as `TextInputClient.performSelectors`. | Shortcuts, focus traversal and text editing. Not the OS or its input method: IMEs, dead keys, system shortcuts and OS key remapping are never involved. |

A pass on the framework route is no evidence about OS-level input, which is why every reply says which route ran. The reply also says what was sent:

- **browser:** `sent` is the CDP events, in order. `focus` is what had the browser's focus, as tag names through shadow roots; a focused Flutter text field reads `flutter-view > input`. When the key types text and the focus isn't in a text field, `warning` says the text reached nothing.
- **framework:** `sent` lists each key event and whether the framework handled it. `handled` is the answer for the main key. `textInput` is what went to the field: `{"inserted":"a"}`, `{"selectors":["moveDown:"]}`, `{"action":"TextInputAction.done"}`, or `{"skipped":"<why>"}`.

```json
{"route":"framework","key":"ArrowDown","handled":false,
 "sent":[{"type":"down","key":"Arrow Down","handled":false},{"type":"up","key":"Arrow Down"}],
 "textInput":{"selectors":["moveDown:"]}}
```

On desktop, a key can arrive while the app's window isn't the focused one: because another app is in front, after `app.setWindowActive` with `"false"`, or while the window is hidden or covered. The framework took focus off the field when the window went inactive or hidden. So the key first makes the app active, as a real key press would find it, and the field gets its focus back. `activated` in the reply says this happened. The real window stays where it is.

**Mac editing keys in a browser.** On a Mac, a browser edits text through the Cocoa command AppKit attaches to a key, and CDP input enters below AppKit. So the browser route attaches the command a Mac would, from Playwright's `macEditingCommands` table. We measured the difference on a Flutter web text field. `Control+K` deletes to the end of the line only when it carries `deleteToEndOfParagraph`. Backspace, the arrow keys and Enter worked with or without their commands. Enter carries `insertNewline` anyway, and in a textarea it inserted exactly one newline either way.

**Waiting.** Both routes wait for the app to go idle before answering, with the same `timeoutMs` and `settle` as the other input commands, and report the result in `settled` and `settleDetail`. The keys are delivered in every case. The browser route can ask whether the app is idle on every run that offers the agent commands: the DDC dev loop and debug `--wasm` bundles. A `--profile` run can't be asked, so it answers `skipped`, and a screenshot shows what the key did. A page in a hidden, minimized or covered window draws no frames, so the key's effect doesn't show until the page is visible again. The reply then says `no` with that reason. `--web-run-headless` avoids the problem.

#### Reload and restart responses

A reload or restart that landed in an app that isn't drawing says so. The app is running the new code, so `succeeded` is `true`, and `notShown` says, for each app, why the screen doesn't show it yet:

```json
{"succeeded":true,"runningCode":"updated",
 "notShown":{"<appId>":"the app is not drawing, because the OS reports it cannot be seen (lifecycle state \"hidden\": …). It shows the change once it can be seen again"},
 "message":"Restart successful, but the app is not drawing, because the OS reports it cannot be seen …"}
```

The reply comes as soon as the app has built its first frame and said it can't draw. An app that neither draws nor says why, such as one attached to without the rules' agent extensions, gets the ten seconds the tool gives a frame to arrive, and `notShown` then says only that no frame came.

A restart that relaunched the process because a native library changed says so:

```json
{"succeeded":true,"runningCode":"updated","relaunched":true,
 "nativeLibsChanged":["…/libmul.dylib"],"launch":{"<appId>":2},"ready":true,
 "message":"Restart successful — the app was relaunched because its native libraries changed (…). …"}
```

`ready` says the relaunched app rendered a first frame before the response returned, so its extensions are registered and the next `app.*` call will land. `false` means that wait timed out, not that the app is broken. The protocol stream sends `app.debugPort` and `app.started` again for the new process.

The replies after a native edit follow [Hot reload across a native rebuild](#hot-reload-across-a-native-rebuild). A reload whose library changed but whose bindings didn't delivers the edit, and reports the stale library:

```json
{"succeeded":true,"runningCode":"updated",
 "nativeLibsStale":["…/libbridge.dylib"],
 "message":"Hot reload successful. …/libbridge.dylib was rebuilt and its bindings did not change, so the increment is live over the library the app already loaded — the new native code is not running. A restart (R, or `app.restart`) delivers it: it relaunches the app when the native code the app runs differs from what the tree builds, and otherwise restarts it in place."}
```

When the bindings changed, or nothing declares them, the edit is withheld:

```json
{"succeeded":false,"runningCode":"unchanged",
 "nativeLibsStale":["…/libbridge.dylib"],
 "message":"Hot reload withheld: …/libbridge.dylib changed, and so did what its bindings are generated from …"}
```

Nothing is compiled or sent, so the app keeps the code and the library it launched with, and `app.restart` with `fullRestart: true` picks up the new one. An `attach` run can't replace a process it didn't start, so there the reply says to launch the app again and attach to it. `nativeLibsStale` means the same thing in both replies, and `succeeded` says whether the edit landed.

A reload that patched native code into the app says what it patched:

```json
{"succeeded":true,"runningCode":"updated",
 "nativePatched":{"libmul.dylib":["mul_body"]},
 "message":"Hot reload successful. Patched libmul.dylib in the running app (mul_body)"}
```

`nativeReverted` lists libraries sent back to their launched code. A patch that can't be delivered withholds the reload, with the patch builder's reasons in `nativePatchRestart`. A patch that didn't load in every app names the apps in `nativePatchFailed` and `nativePatchApplied`.

#### How a command says no

Every failure, on either transport, is a top-level `error` carrying the reason. Over HTTP the status says which kind:

| Status | Meaning |
|---|---|
| `400` | The tool couldn't read the request: not JSON, no `method`, or `app.pressKey` without `key`. |
| `404` | The command or the app doesn't exist here. |
| `422` | The command was understood and couldn't be done: the app refused, or never answered. The app checks a widget command's own parameters, so a missing selector, or two, is a `422` carrying the app's reason, not a `400`. |
| `501` | This run can't serve it, such as an engine screenshot under Impeller. |
| `500` | The tool itself broke. This is the one case worth retrying or reporting. |

On the stdin protocol the same failure is `flutter run`'s `{"id":…, "error":"<reason>"}`.

An outcome that carries its own verdict stays inside `result`. A hot reload that ran and failed answers `{"succeeded":false, "error":…}`, because it ran and reported a failure rather than refusing to run.

### Working with a coding agent

The control channel lets a coding agent such as Claude Code check its own work. It can reload the app after an edit, read text back, and look at a screenshot, rather than guessing from the code.

**The skill.** This repository ships a skill, `flutter-bazel`, that teaches an agent the whole loop: starting a session, finding the channel, reading the UI, driving it, reloading, and reading failures. For Claude Code it is a plugin in this repository's marketplace:

```sh
claude plugin marketplace add aran/rules_flutter
claude plugin install rules-flutter@rules-flutter
```

Or, inside a session, `/plugin marketplace add aran/rules_flutter` and then `/plugin install rules-flutter@rules-flutter`. The skill itself is in the open Agent Skills format, in [`agent_plugin/skills/flutter-bazel`](agent_plugin/skills/flutter-bazel/SKILL.md), so any agent that reads that format can use the same directory.

With or without the skill, three choices make the loop work well.

**Start the app in machine mode, in the background.** The run lives for the whole session, so start it once and send its output to files. `--machine` keeps stdout to protocol events, `LOG_FORMAT=json` makes the channel's record on stderr one parseable line, and `--no-devtools` skips starting a DevTools server nobody will open. On the web, add `--web-run-headless`.

```sh
LOG_FORMAT=json fl run -t //:my_app_macos -d macos --machine --no-devtools \
  > /tmp/app.out 2> /tmp/app.err &
```

The agent reads the URL and token from the `http_control_channel` line in the stderr file, and waits for `app.started` in the stdout file before sending commands.

**Reload when the edit is done, not on every save.** In terminal mode the tool reloads on every save. In machine mode watching is off by default, which suits an agent better. An agent edits several files in a row, and a reload after each save would compile half-finished changes. Have the agent call `app.hotReload` itself when it has finished editing. The reply says whether the reload landed and which files were recompiled, which is the evidence the agent should report. If the agent needs watch mode anyway, pass `--watch`, and have it call `app.settle` before reading anything back.

**Ask for screenshots before and after every change.** An agent that edits code without looking at the result will report success on a blank screen. Put the rule in the file your agent reads at startup, such as `CLAUDE.md` or `AGENTS.md`:

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
   Use app.restart with "fullRestart":true instead when the change touches main() or startup code.
   Read `succeeded` from the reply. A reload that fails is not done.
3. After the reload, save a second screenshot and compare it with the first.
   Say in your report what changed on screen, not just what changed in code.
   A reply with `notShown`, or a read with `notRendering`, means the window
   is hidden or covered: bring it to the front before trusting the screen.
4. Check GET /sessions/<appId>/logs for exceptions before moving on.

Stop the app with daemon.shutdown at the end of the session.
```

Adjust the target and device to your project. With the long form of the command in place of `fl`, this works without bazel_env. The screenshot endpoint waits for the app to settle, so a capture taken straight after a tap or a reload shows the result (see [Screenshots](#screenshots)).

**Flutter's own agent tools find the app too.** Like `flutter run`, a run starts a Dart Tooling Daemon (DTD) and registers each app's VM service with it. So the Dart MCP server (`dart mcp-server`) and other DTD clients find a `flutter_bazel` run the way they find a `flutter run` one. `dart tooling-daemon --list` lists the run's DTD, and the server's `list_running_apps` and `dtd` tools show the app. Its `hot_reload` and `hot_restart` go through the tool's own reload, so they recompile with Bazel as `app.hotReload` does, and `get_runtime_errors` reads the app's errors. A `--machine` client gets the DTD's address from the `app.dtd` event, and in a terminal `--print-dtd` prints it. The DTD stops when the run ends.

Use the MCP server only for these running-app tools. Its `run_tests`, `launch_app` and `pub` use the Flutter installed on the machine, not the one the workspace builds with.

## Examples

The `e2e/` directory holds working workspaces, each with its own tests:

| Directory | What it shows |
|---|---|
| `e2e/smoke` | The smallest check: the Flutter toolchains resolve. |
| `e2e/hello_world` | A minimal app on every platform: kernel, AOT, assets, tests, profile builds, macOS, iOS, Android, Linux, Windows and web. |
| `e2e/asset_bundle` | Every asset a pubspec declares reaching the bundle under the key, variants and platforms `flutter build` gives it. |
| `e2e/codegen` | Per-file and aggregate code generation, generated code in dependency packages, and hot reload over generated sources. |
| `e2e/ffi_example` | Every way a Flutter app carries native code: Dart Native Assets, `native_deps`, and a `flutter_plugin` with a Dart plugin class and `native_deps` (`plugin_class`), plus native hot patching. |
| `e2e/plugin_example` | Pub plugins from the hub, plugins that register a Dart class or a native one, and Android plugin Maven dependencies. |
| `e2e/pub_resolve` | A monorepo app whose `path:` packages, and a fork of a hosted one, are workspace targets mapped with `resolve`. |
| `e2e/dual_hub` | Two pub hubs in one workspace that differ on a package version: one repository per package, at the higher version. |
| `e2e/macos_example` | A full macOS app with bundle structure checks. |
| `e2e/ios_example` | An iOS app. Requires Xcode. |
| `e2e/android_example` | An Android APK built three ways, with APK content checks. |
| `e2e/desktop_example` | One app built for Linux and for Windows, each three ways, with bundle checks. |
| `e2e/web_example` | WASM-with-JavaScript-fallback, WASM-only and JavaScript web builds with `web_assets`, and a WASM-only app dart2js can't compile. |
| `e2e/cross_compile_example` | A Linux bundle cross-compiled from macOS. |
| `e2e/multi_window_example` | Multi-window macOS and multi-scene iOS with `FlutterEngineGroup`. |
| `e2e/integration_test` | `package:integration_test` suites run in a real app, reported per test. |
| `e2e/custom_engine` | Builds against a local Flutter checkout and its engine, chosen per build. |
| `e2e/package_assets` | An app's own package's assets: link hooks deciding which data assets ship, and the Native Assets pipeline end to end with a code asset and a data asset (`own_assets`). |
| `e2e/external_module` | The published module, from its release archive: every target lists and analyses. |

[docs/TESTING.md](docs/TESTING.md) describes how the repository itself is tested, including the manual checks that need a display or a device.

## License

See [LICENSE](LICENSE).
