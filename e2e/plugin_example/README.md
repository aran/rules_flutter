# plugin_example

End-to-end demonstrator for `rules_flutter`'s pub.dev plugin pipeline. Imports three real Flutter plugins via `pubspec.yaml` — `path_provider`, `url_launcher`, `package_info_plus` — plus the hand-written `:greeting_plugin` (regression case for pure-Bazel-deps plugins). `lib/main.dart` resolves four strings from those plugins (`appName`, `documentsPath`, `tempPath`, `launchOk`) and renders + emits them on a single `plugin_example_results …` log line that the e2e tests assert against.

## Plugin choices

- **`path_provider`** — federated umbrella (`default_package` style). `path_provider_foundation` exercises Swift Package Manager (`darwin/path_provider_foundation/Sources/path_provider_foundation/`). `path_provider_linux` and `path_provider_windows` are pure Dart (no native dir). `path_provider_android` is Kotlin.
- **`url_launcher`** — federated. SwiftPM Apple. Real C++ on Linux (`xdg-open` via GTK) and Windows (`ShellExecuteW`). Kotlin Android. Web Dart impl.
- **`package_info_plus`** — monolithic; one package owns every platform's native code (ObjC on Apple, Kotlin Android, web Dart).
- **`//greeting_plugin`** — hand-written Bazel `flutter_plugin` target with `dart_plugin_class = "GreetingPlugin"`. Regression case for pure-Bazel-deps plugins.

## Building and verifying

Per-platform bundle targets: `:plugin_macos`, `:plugin_ios`, `:plugin_android`, `:plugin_linux`, `:plugin_windows`, `:plugin_web`. See `docs/TESTING.md` § "Plugin verification matrix" for how each platform's runtime assertion works.

## Adding more pub plugins

Drop them into `pubspec.yaml`, regenerate `pubspec.lock` with `flutter pub get`, add the `@deps//:<pkg>` to your `flutter_application.deps`. Auto-detection handles the common SwiftPM / `linux/` / `windows/` / `android/src/main/` layouts. When a plugin's layout is non-standard, supply an `ext/` overlay (see `flutter.plugin_overlays(...)` in `MODULE.bazel` for user roots).
