"""Core rules for building Flutter applications.

This is the main entry point for rules_flutter. It exports platform-agnostic
rules that compile Dart code, bundle assets, and run tests.

## Recommended (start here)

- `flutter_application`: Compiles Dart code (kernel + AOT) and bundles assets.
    This is the primary rule — it produces a `FlutterApplicationInfo` provider
    that platform-specific packaging rules consume.
- `flutter_library`: Collects Flutter Dart sources and assets into a reusable
    dependency. Wire into `flutter_application` via `deps`.
- `flutter_plugin`: Declares a Flutter plugin with optional Dart registration
    class and/or native shared library dependencies.
- `flutter_test`: Runs Flutter widget tests using the flutter_tester runtime.

## Advanced / Low-Level

Most users don't need these directly. `flutter_application` composes them
internally. They are exported for advanced use cases like custom pipelines.

- `flutter_kernel_target`: Runs the Flutter frontend compiler to produce a
    kernel .dill file from Dart sources.
- `flutter_aot_target`: Runs gen_snapshot to AOT-compile a kernel .dill into
    native code (ELF .so or Mach-O dylib).
- `flutter_asset_bundle`: Bundles Flutter assets (images, fonts, shaders)
    into a flutter_assets/ tree artifact.

## Platform packaging

After `flutter_application`, use platform-specific rules to produce runnable
artifacts:

- `@rules_flutter//flutter:macos.bzl` — `flutter_macos_app` + composable rules
- `@rules_flutter//flutter:ios.bzl` — `flutter_ios_app` + composable rules
- `@rules_flutter//flutter:linux.bzl` — `flutter_linux_app` + composable rules
- `@rules_flutter//flutter:windows.bzl` — `flutter_windows_app` + composable rules
- `@rules_flutter//flutter:web.bzl` — `flutter_web_app` + composable rules (takes source directly, not a flutter_application target)
"""

load("//flutter/private:flutter_aot_target.bzl", _flutter_aot_target = "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", _flutter_application = "flutter_application")
load("//flutter/private:flutter_asset_bundle.bzl", _flutter_asset_bundle = "flutter_asset_bundle")
load("//flutter/private:flutter_kernel_target.bzl", _flutter_kernel_target = "flutter_kernel_target")
load("//flutter/private:flutter_library.bzl", _flutter_library = "flutter_library")
load("//flutter/private:flutter_plugin.bzl", _flutter_plugin = "flutter_plugin")
load("//flutter/private:flutter_test.bzl", _flutter_test = "flutter_test")

flutter_aot_target = _flutter_aot_target

def flutter_application(name, package_name = "", **kwargs):
    """Compiles a Flutter application with stable package: URIs for hot reload.

    Auto-derives `package_name` from the rule name if not explicitly set.
    This ensures the kernel uses `package:<name>/main.dart` URIs instead of
    sandbox `file:///` URIs, which is required for hot reload incremental
    deltas to match the running application's library URIs.

    Args:
        name: Target name.
        package_name: Dart package name (from pubspec.yaml). Defaults to name.
        **kwargs: All other arguments forwarded to the underlying rule.
    """
    _flutter_application(
        name = name,
        package_name = package_name or name,
        **kwargs
    )

flutter_asset_bundle = _flutter_asset_bundle
flutter_kernel_target = _flutter_kernel_target
flutter_library = _flutter_library
flutter_plugin = _flutter_plugin
flutter_test = _flutter_test
