# Testing Guide

Complete instructions for testing rules_flutter changes. Run **all applicable sections** before considering work done.

> **Never run `bazel clean`** — it destroys the cache and causes long rebuilds.

## 1. Root workspace

```sh
bazel test //...
```

## 2. dev_tool tests

Unit tests (fast, no external dependencies):
```sh
cd tools/dev_tool && dart test --exclude-tags=e2e
```

E2e tests (spawn real builds, require platform toolchains — run sequentially):
```sh
cd tools/dev_tool && dart test test/e2e/ --tags=e2e --concurrency=1
```

### Dev tool e2e test matrix

| Test file | Platform | What it validates |
|-----------|----------|-------------------|
| `macos_e2e_test.dart` | macOS | `--screenshot` (VM service), `--machine` screenshot, `--quit-after-start` |
| `web_e2e_test.dart` | Any (needs Chrome) | WASM + JS `--screenshot` (CDP), `--machine` screenshot |
| `ios_simulator_e2e_test.dart` | macOS | `--screenshot` (simctl), `--machine` screenshot |
| `machine_protocol_e2e_test.dart` | macOS | Protocol lifecycle events, unknown-method error (reload/restart correctness is manual — see "Hot reload / hot restart (manual)") |
| `attach_e2e_test.dart` | macOS | Launch app externally → attach → VM service connects |
| `dart_defines_e2e_test.dart` | macOS | `--dart-define` reaches the app (comma-in-value intact) and survives a hot reload (frontend_server -D replay) |
| `agent_e2e_test.dart` | macOS | Full `app.*` agent surface (tap/enterText/getText/…), and that it still works **after `app.restart`** (engine-hook registrant re-registers extensions) |
| `plugin_example_e2e_test.dart` | macOS/iOS-sim/Android | Plugin apps render non-blank frames; Dart plugin registration survives `app.restart` (macOS) |

### Dev tool screenshot mechanisms

| Device | Debug mode (VM service) | Profile/release (no VM service) |
|--------|------------------------|---------------------------------|
| macOS | `_flutter.screenshot` via VM service | `screencapture -x` |
| Linux | `_flutter.screenshot` via VM service | `scrot` |
| Windows | `_flutter.screenshot` via VM service | PowerShell `CopyFromScreen` |
| Android | `_flutter.screenshot` via VM service | `adb screencap` |
| iOS Simulator | `simctl io screenshot` (always) | `simctl io screenshot` (always) |
| Chrome/Web | CDP `Page.captureScreenshot` (always) | N/A (web is always debug) |

Note: `_flutter.screenshot` captures only the Flutter widget tree (no OS chrome). OS-level tools capture the full screen/window.

## 3. E2E workspaces (automated)

Run `bazel test //...` in each workspace. All non-manual tests run automatically.

```sh
cd e2e/smoke && bazel test //...
cd e2e/hello_world && bazel test //...
cd e2e/codegen && bazel test //...
cd e2e/ffi_example && bazel test //...
cd e2e/ffi_plugin_example && bazel test //...
cd e2e/plugin_example && bazel test //...
cd e2e/macos_example && bazel test //...
cd e2e/ios_example && bazel test //...
cd e2e/multi_window_example && bazel test //...
cd e2e/android_example && bazel test //...
cd e2e/web_example && bazel test //...
cd e2e/linux_example && bazel test //...    # Linux-only (target_compatible_with)
cd e2e/windows_example && bazel test //...  # Windows-only (target_compatible_with)
```

**Platform notes:**
- macOS-only targets (macos bundle tests, ios_example) are skipped on other platforms via `target_compatible_with`.
- Linux-only targets (linux bundle tests, linux_example) are skipped on macOS/Windows.
- Windows-only targets (windows_example) are skipped on macOS/Linux.
- `android_example` and `hello_world` (Android targets) require `ANDROID_HOME` to be set to the Android SDK path (e.g. `export ANDROID_HOME=$HOME/Library/Android/sdk` on macOS) and `ANDROID_NDK_HOME` to the NDK path (e.g. `export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/<version>`).
- Android builds need no platform flags: `flutter_android_bundle` transitions the application to the Android platform matching its `android_abi`, and packaging hard-fails on any non-ELF native library. `verify_android_apk_test` in `e2e/android_example` asserts every packaged `.so` is ELF with the ABI's machine type.
- If Xcode beta causes `local_config_xcode` errors, add `--repo_env=DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- `cross_compile_example` has no test targets; verify with `bazel build :cross_linux`.

### What the automated e2e tests cover

| Workspace | Key tests |
|-----------|-----------|
| smoke | Toolchain resolution for all platforms |
| hello_world | Kernel, AOT, application, and per-platform bundle builds; flutter_test |
| codegen | Per-file and aggregate dart_codegen, custom generators, hot-reload-with-codegen |
| ffi_example | Both FFI mechanisms — Native Assets (`add_plugin`, `@Native` asset-id bind) and `native_deps` (`mul_plugin`, conventional-path open) — bundle structure on macOS/Linux plus manual runtime proof on iOS simulator and macOS |
| ffi_plugin_example | FFI plugin build + macOS/Linux bundle structure with `libmultiply.dylib`/`.so` |
| plugin_example | Real pub.dev plugins (`path_provider`, `url_launcher`, `package_info_plus`) plus the hand-written `:greeting_plugin` regression case; per-platform bundle builds; Playwright web assertions; macOS runtime verifier asserting the four plugin-result strings. See **Plugin verification matrix** below. |
| macos_example | Full macOS app build + bundle structure verification (Info.plist, ObjC symbols, framework linkage, AOT dylib, flutter_assets) |
| ios_example | iOS app build (requires Xcode) |
| web_example | Web app builds (dart2wasm + dart2js) with web_assets |
| multi_window_example | Multi-window macOS + multi-scene iOS builds with FlutterEngineGroup; macOS bundle verification |
| android_example | Android APK build (3 approaches: flutter_android_app, Bazel-generated manifest, custom manifest) + APK content verification + web build |
| linux_example | Linux desktop app (2 approaches: flutter_linux_app, Bazel-generated runner) + bundle structure verification |
| windows_example | Windows desktop app (3 approaches: flutter_windows_app, Bazel-generated runner, custom cc_binary) + bundle structure verification |

### Plugin verification matrix

`e2e/plugin_example` exercises three real pub.dev plugins — `path_provider` (federated, SwiftPM Apple, Kotlin Android, pure-Dart Linux/Windows), `url_launcher` (federated, SwiftPM Apple, Kotlin Android, real C++ Linux/Windows, web Dart), `package_info_plus` (monolithic, every platform including web) — plus the hand-written `:greeting_plugin` (regression case for pure-Bazel-deps plugins). `lib/main.dart` resolves four strings from those plugins and renders + emits them on a single `plugin_example_results …` log line. Each platform's e2e check asserts the line is correct; empty/null/error content fails loudly.

| Assertion | Source | Expected |
|---|---|---|
| `appName=…` | `PackageInfo.fromPlatform()` | `Plugin Example` on macOS/iOS (from `CFBundleName` in the generated Info.plist), `plugin_example` on web (from the auto-generated `version.json`'s `app_name`). Failure means the `package_info_plus` registrant didn't fire on that platform. |
| `documentsPath=…` | `getApplicationDocumentsDirectory().path` (`kIsWeb`-guarded) | `/Users/…` on macOS, `/var/…` on iOS, `/home/…` on Linux, `C:\Users\…` on Windows, `/data/user/0/…` on Android, `web: not supported` on web. |
| `tempPath=…` | `getTemporaryDirectory().path` (`kIsWeb`-guarded) | Absolute path with the platform-appropriate prefix; web shows `web: not supported`. |
| `launchOk=launch ok` | `canLaunchUrl(Uri.parse('https://flutter.dev'))` | Exact `launch ok`. Failure means the `url_launcher` registrant didn't fire. |
| `greeting=Hello from GreetingPlugin!` | `//greeting_plugin:greeting_plugin` (regression case) | Exact match. |

| Platform | Where the assertion runs |
|---|---|
| Web | `npx playwright test` in `e2e/plugin_example/playwright/web.spec.js` (asserts the four strings via captured console messages). |
| macOS | `:verify_macos_app_test` (manual stdout check) plus the `macOS e2e` group of `tools/dev_tool/test/e2e/plugin_example_e2e_test.dart` (runs `:plugin_macos`, captures a screenshot via the dev_tool's HTTP control channel, asserts the PNG is well-formed and non-blank). Run with `cd tools/dev_tool && dart test test/e2e/plugin_example_e2e_test.dart --tags=e2e --plain-name="macOS"`. |
| iOS Simulator | `iOS Simulator e2e` group of the same file. Boot any iOS simulator first (`xcrun simctl boot <udid>`), then run `dart test … --plain-name="iOS Simulator"`. |
| Android | `:android_bundle_build_test` (build) plus the `Android e2e` group. Pre-step: bring up a device — either USB-authorize a phone (`adb devices` shows `device`) or boot an emulator (`emulator -avd flutter_test &`). The test resolves the first authorized serial via `firstAndroidSerial()` and runs `:plugin_android` against it; both emulator and connected-device paths must pass. The dev_tool screenshot uses `_flutter.screenshot` for debug builds, falling back to `adb screencap`. |
| Linux | `:linux_bundle_build_test` (build only). Visual verification on the GCP VM is manual (see § Linux visual verification). |
| Windows | `:windows_bundle_build_test` (build only). Visual verification on the GCP VM is manual (see § Windows visual verification). |

The dev_tool screenshot is the dispositive end-to-end gate per platform: if Native Assets are broken the app crashes before drawing, and if plugin auto-wiring is broken `MissingPluginException` blanks the screen — both fail the non-blank PNG check (default threshold 4 KB, well above any blank/solid-color PNG).

### Native Assets overlay authoring

Pub packages that ship a `hooks/build.dart` Dart-Native-Assets build hook (e.g. `package:objective_c`) get translated to Bazel-native equivalents under `ext/<pkg>/<major>/BUILD.bazel.tpl`. The template is loaded by `flutter_pub_package` for any spoke whose package name + major version matches.

Template substitutions: `{HUB_NAME}` (the user's `flutter.pub(name = ...)`), `{PKG}` (the package name), `{VERSION}` (the resolved version).

Procedure:

1. Locate the package's hook source under `~/Library/Caches/bazel/_bazel_<user>/.../external/<hub>__<pkg>/hook/build.dart`. Read what it builds (file glob, link mode, target platforms, copts).
2. Reproduce the build with `cc_shared_library` + `objc_library` (Apple) / `cc_library` (other platforms). Set `shared_lib_name` to something *different* from the bundle filename — `flutter_native_asset` symlinks the cc output to `<bundle_filename>` in its own package, and matching names collide.
3. Wrap each per-platform output in `flutter_native_asset(name = "<pkg>_native_asset_<os>", asset_id = "package:<pkg>/<basename>", link_mode = "dynamic_loading_bundle", library = ":_<pkg>_dylib", bundle_filename = "<basename>", target_os = "<os>")`. Add a parallel target per supported OS, gated on `target_compatible_with`.
4. Hang a `flutter_plugin(name = "<pkg>", platforms = [], native_assets = select({...}))` over them. Even though the package is "pure Dart" from pub's perspective, the empty-`platforms` plugin shape is what carries the native-assets entry into `FlutterInfo` for the application's manifest.
5. Drop the template at `ext/<pkg>/<major>/BUILD.bazel.tpl`. The next `flutter pub get` + Bazel build picks it up automatically.

If the build fails at runtime with `Couldn't resolve native function "<symbol>"`, the most common cause is the `cc_shared_library`'s `install_name` not matching the asset id's basename — set `user_link_flags = ["-Wl,-install_name,@rpath/<basename>"]` on Apple targets. See `ext/objective_c/9/BUILD.bazel.tpl` for the canonical example.

## 4. Manual tests

These require a GUI environment and are skipped by `bazel test //...`.

### macOS runtime smoke test

Launches the app, polls for a window, and verifies dimensions > 100x100. Catches window sizing bugs (e.g. the 1x32 collapsed-window bug).

```sh
cd e2e/macos_example
bazel test :verify_macos_app_test --test_tag_filters= --strategy=TestRunner=standalone
```

**When to run:** After any change to macOS runner code (`flutter/private/runners/macos/`).

### FFI runtime tests (iOS simulator, macOS, Linux, Windows)

Behavioral verification that both native-library mechanisms work at runtime:
`add()` binds via `@Native` asset-id resolution (`flutter_native_asset` →
`--native-assets` kernel manifest), `mul()` raw-opens its conventional path
(`native_deps`). The app writes
`ffi_example_result add(3,4)=7 mul(3,4)=12` to its temp dir; the tests read
it back (via `simctl get_app_container` on iOS).

```sh
cd e2e/ffi_example
bazel test :verify_ios_simulator_test --test_tag_filters= --strategy=TestRunner=standalone
bazel test :verify_macos_runtime_test --test_tag_filters= --strategy=TestRunner=standalone
# Linux (headless boxes need Xvfb; XAUTHORITY must pass through):
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 \
  bazel test :verify_linux_runtime_test --test_tag_filters= \
    --strategy=TestRunner=standalone \
    --test_env=DISPLAY --test_env=XAUTHORITY --test_env=LIBGL_ALWAYS_SOFTWARE
# Windows (needs a display adapter — on GCP create the VM with --enable-display-device):
bazel test :verify_windows_runtime_test --test_tag_filters= --strategy=TestRunner=standalone
```

**When to run:** After any change to native-assets manifest emission
(`flutter_native_assets.bzl`, `flutter_native_asset.bzl`), native-library
bundling (`flutter_ios_native_frameworks`, `flutter_macos_native_libs`), or
kernel compilation flags.

### macOS visual verification

Launches the app binary directly, captures stdout/stderr, takes a screenshot, and prints structured JSON output. The screenshot file can be opened for visual verification.

```sh
cd e2e/macos_example && bazel build :app
# Extract the app
mkdir -p /tmp/macos_app && unzip -oq bazel-bin/app.zip -d /tmp/macos_app
# Run the diagnostic
dart run ../../e2e/_macos_test/verify_macos_app.dart /tmp/macos_app/app.app "Flutter App"
```

### Hot reload / hot restart (manual)

**MANDATORY** (CLAUDE.md verification policy item 6) for any change to the
dev_tool reload paths: `tools/dev_tool/lib/run_command.dart`,
`vm_service_client.dart`, `hot_reload/**`, `session.dart`. There is
intentionally **no automated assertion** for reload correctness — a weak
`expect(result, isNotNull)` smoke test previously stayed green through two
real macOS regressions (the `app.started`-before-orchestrator race and a
disposed VM-service connection). The bar is "I have seen the new text render
in the macOS window."

Verify all three, with `--no-devtools` (see Known issues):

1. **Race**: send `app.hotReload` *immediately* on the `app.started` event
   (no delay). Must return a success message, not
   `{"error":"Hot reload is still starting up."}` or
   `{"error":"No frontend server available"}`.
2. **Hot reload**: edit `lib/main.dart` visible text → `app.hotReload` →
   screenshot shows the new text.
3. **Hot restart**: edit again → `app.restart` → screenshot shows the
   change. Hot restart re-runs `main()` (engine `runInView`), so it must also
   reflect a change made *inside `main()`* (e.g. a value computed there) that a
   hot reload deliberately does NOT — verify a `main()`-level edit too.
4. **Agent surface after restart**: after `app.restart`, `app.getText` must
   still succeed. The `ext.rules_flutter.*` extensions are registered by the
   generated plugin registrant the engine invokes before `main()` on every
   root-isolate launch; if this errors with `Unknown method`, the registrant
   trio (`--source` ×2 + `-Dflutter.dart_plugin_registrant`) is missing from
   the dev tool's frontend_server invocation.

**Source-assembled (codegen) apps** — also verify against `e2e/codegen :app_macos`.
This is the coverage for apps that mix hand-written + generated sources, including
**dependency packages** that do so:
- app package `codegen_e2e`: `lib/user.dart` + `:user_json` → `lib/user.g.dart`
  (a generated `part`);
- dep `dep_part`: a generated `part` (`lib/settings.dart` + `:settings_gen`);
- dep `dep_lib`: a generated **standalone imported library** (`lib/catalog.dart`
  imports `lib/catalog.g.dart`).

`lib/main.dart` renders a value from all three in `build()`, so regenerated output
is reload-observable. Verify:
- **Codegen reload (the real flow — edit a codegen INPUT)**: add a field to a model
  source (`lib/user.dart`, or `dep_lib/lib/catalog.dart`) → `app.hotReload` → the
  regenerated output renders. The dev tool runs `bazel build` of the
  flutter_application (`refreshGenerated`) to regenerate `*.g.dart`, then the normal
  diff invalidates the changed library by its `package:` URI.
- **Hot restart over codegen**: edit the `User(...)` in `main()` → `app.restart` →
  the change renders and all generated code (app + deps) still resolves.
- **Dependency source edit**: edit a dep's hand-written source (e.g.
  `dep_part/lib/settings.dart`) → reload → renders. This exercises the
  `PackageUriResolver`, which keys every first-party source (app **and** deps) by its
  `package:` URI from the build-emitted `sourcePackages` — a dep edit must NOT be
  keyed `file://` (it would be silently dropped).

> **Gotcha — editing a generator SCRIPT mid-session is unreliable.** Don't verify
> codegen reload by editing the `dart_codegen` *generator script* (e.g.
> `tools/*_generator.dart`) and reloading. Rapid edit→revert cycles of a generator
> script can leave bazel's action cache in a state where it won't re-run the codegen
> action (reproducible with pure `bazel build`; a clean cache always re-runs).
> Editing the codegen **input** (a model source) is the realistic flow and is
> reliable.

Requires a `local_path_override` for `rules_dart` in `e2e/codegen/MODULE.bazel`
until the new rules_dart (`generate_dev_package_config` + `source_packages`) ships
in a release.

**Watch mode (filesystem-watcher-driven reload).** Machine mode defaults the watcher
off; pass `--watch` to drive reloads from on-disk edits instead of explicit
`app.hotReload` commands. Edit `lib/main.dart` and a **dependency** source on disk →
the watcher debounces and reloads → the change renders. Automated guard:
`tools/dev_tool/test/e2e/watch_reload_e2e_test.dart` (`dart test --tags=e2e`) asserts
the rendered output changes after watcher-triggered app + dep edits.

**Release/AOT codegen run.** `bazel build //:app_macos -c opt` (release/AOT), launch
the extracted `.app`, and capture its window (e.g. the bundled
`//tools/macos_screenshot:screenshot --pid <pid>`): the generated output from the
app package + both dep packages must render. This verifies the release `.pkgsrcs`
assembly + gen_snapshot path co-locates and compiles all generated code at runtime —
distinct from the dev multi-root path, and from the `build_test`s which only compile.

Tests the full dev tool hot reload cycle: launch app, take screenshot, edit source, hot reload, take screenshot, verify the change rendered, revert source.

```sh
cd e2e/macos_example

# 1. Start the dev tool with --machine for structured JSON events on stdout
dart run ../../tools/dev_tool/bin/flutter_bazel.dart run \
  -t :app -d macos --machine &

# 2. Read stdout for the app.started event (contains appId) and
#    http_control_channel event on stderr (contains URI and token)

# 3. Take a screenshot
curl -s "http://[::1]:PORT/sessions/APPID/screenshot/flutter?token=TOKEN" \
  -o /tmp/before.png

# 4. Edit lib/main.dart (change visible text)

# 5. Hot reload
curl -s -X POST "http://[::1]:PORT/command?token=TOKEN" \
  -H "Content-Type: application/json" -d '{"method": "app.hotReload"}'

# 6. Take another screenshot (should show the changed text)
curl -s "http://[::1]:PORT/sessions/APPID/screenshot/flutter?token=TOKEN" \
  -o /tmp/after.png

# 7. Revert the source change and stop the dev tool
```

**When to run:** After any change to the dev tool, frontend server integration, or hot reload logic.

**Known issues:**
- `app.hotReload` may report "no changes detected" if the file watcher already auto-reloaded the change. This only happens when the file watcher is enabled (terminal mode default); `--machine` disables it by default.

**Note:** the dev tool now owns DDS (starts it on the app's raw VM service and routes both its own VM client and DevTools through it), so `_flutter.screenshot` works with DevTools enabled — `--no-devtools` is no longer required.

### Linux visual verification (GCP VM)

Cross-compile a Linux debug bundle from macOS, deploy to a GCP VM, and verify the Flutter UI renders.

```sh
# 1. Cross-compile (requires LLVM toolchain — use cross_compile_example)
cd e2e/cross_compile_example && bazel build :cross_linux

# 2. Create a Linux VM
dart run tools/vm/create_linux_vm.dart flutter-linux-test

# 3. Deploy and verify
dart run tools/vm/deploy_bundle.dart flutter-linux-test e2e/cross_compile_example/bazel-bin/cross_linux

# 4. Clean up
gcloud compute instances delete flutter-linux-test --quiet
```

**When to run:** After any change to Linux runner code, engine selection, or bundle assembly.

### Windows visual verification (GCP VM)

Build natively on a Windows VM, take a DXGI screenshot — fully automated over SSH (no RDP needed).

The create script sets up auto-logon via sysprep specialize, so an interactive console session exists at boot. PsExec launches apps in that session and `dxcam` captures DXGI screenshots.

```sh
# 1. Create a Windows VM (auto-logon, MSVC, Python, dxcam, PsExec)
dart run tools/vm/create_windows_vm.dart flutter-windows-test

# 2. Deploy bundle and verify (automated — screenshot downloads locally)
dart run tools/vm/deploy_bundle.dart flutter-windows-test <bundle_path> --windows

# 3. Clean up
gcloud compute instances delete flutter-windows-test --quiet
```

**Key details:**
- `--enable-display-device` is mandatory — provides virtual GPU for D3D
- GDI `CopyFromScreen` captures D3D/Flutter surfaces as **black** — must use DXGI (`dxcam`)
- Console resolution is 800x600
- Files are written to `C:\temp\` (shared), not user profile dirs

**When to run:** After any change to Windows runner code, engine selection, or bundle assembly.

## 5. Playwright web tests

Playwright tests verify Flutter web apps load and render in a headless browser. These live in `playwright/` subdirectories within e2e workspaces.

| Workspace | What it tests |
|-----------|---------------|
| hello_world | Engine initializes, renders, correct page title |
| web_example | Engine initializes, renders, correct page title |
| plugin_example | Engine initializes, renders, correct page title |
| android_example | Engine initializes, renders, correct page title |

```sh
# From the e2e workspace, after building the web target:
cd e2e/hello_world
npx playwright test
```

Shared config and helpers are in `e2e/_playwright/`.

## 6. Standalone diagnostic scripts

These are not Bazel tests — they're standalone Dart scripts for manual investigation.

| Script | Purpose | Usage |
|--------|---------|-------|
| `e2e/_macos_test/verify_macos_app.dart` | Launch macOS app, verify window, screenshot | `dart run <script> <app.app> [title]` |
| `e2e/_linux_test/verify_linux_bundle.dart` | Verify Linux bundle directory structure | `dart run <script> <bundle_dir> [native_libs...]` |
| `e2e/_linux_test/verify_linux_app.dart` | Launch Linux GTK app under Xvfb, verify window, screenshot | `dart run <script> <bundle_dir> [title]` |
| `e2e/_windows_test/verify_windows_bundle.dart` | Verify Windows bundle directory structure | `dart run <script> <bundle_dir> [native_libs...]` |
| `e2e/_windows_test/verify_windows_app.dart` | Launch Windows app, verify window via PowerShell | `dart run <script> <bundle_dir> [title]` |
| `e2e/_windows_test/dxgi_screenshot.py` | Launch app + DXGI screenshot (captures D3D/Flutter) | `python <script> <exe_path> <output.png> [wait_s]` |
| `e2e/_compare/compare_artifacts.dart` | Diff flutter build vs bazel build outputs | `dart run <script> <flutter_dir> <bazel_dir>` |

## Quick reference: what to test when

| Change area | Minimum test scope |
|-------------|-------------------|
| Starlark rules (`flutter/*.bzl`) | Root `//...` + all e2e workspaces |
| macOS runner (`flutter/private/runners/macos/`) | macos_example `//...` + manual runtime test |
| Linux runner / bundle (`flutter/private/*linux*`) | linux_example, cross_compile_example, GCP VM visual test |
| Windows runner / bundle (`flutter/private/*windows*`) | windows_example (on Windows), GCP VM visual test |
| Desktop engine selection (debug/release) | cross_compile_example `bazel build :cross_linux` + verify on VM |
| Dart compilation / AOT | hello_world, ffi_example, macos_example |
| Asset bundling | hello_world, plugin_example |
| Web support | hello_world, plugin_example + Playwright |
| FFI / native deps / native assets | ffi_example (incl. manual iOS-sim + macOS runtime tests), ffi_plugin_example |
| Plugins | plugin_example, ffi_plugin_example |
| Toolchain / SDK | smoke, hello_world |
| dev_tool (unit) | `cd tools/dev_tool && dart test --exclude-tags=e2e` |
| dev_tool (e2e) | `cd tools/dev_tool && dart test test/e2e/ --tags=e2e --concurrency=1` |
| dev_tool reload paths (`run_command.dart`, `vm_service_client.dart`, `hot_reload/**`, `session.dart`) | dev_tool unit + e2e **and** manual hot reload **and** hot restart — see "Hot reload / hot restart (manual)" |
| Everything | All sections above |
