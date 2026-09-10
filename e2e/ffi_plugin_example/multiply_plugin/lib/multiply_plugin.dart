/// Plugin that wraps the native `multiply` function via FFI.
///
/// Demonstrates a flutter_plugin with both dart_plugin_class and native_deps.
/// The generated registrant calls MultiplyPlugin.registerWith(null) at startup,
/// and the native shared library is bundled via
/// FlutterInfo.transitive_native_libs.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

ffi.DynamicLibrary _openNativeLib(String baseName) {
  // On iOS, native code is statically linked into the app binary,
  // so symbols are available via the process's own symbol table.
  if (Platform.isIOS) return ffi.DynamicLibrary.process();

  if (Platform.isMacOS) return ffi.DynamicLibrary.open('lib$baseName.dylib');
  if (Platform.isLinux) return ffi.DynamicLibrary.open('lib$baseName.so');
  if (Platform.isWindows) return ffi.DynamicLibrary.open('$baseName.dll');
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Plugin exposing a native `multiply` through `dart:ffi`.
class MultiplyPlugin {
  static bool _initialized = false;

  /// Called by the generated plugin registrant at app startup.
  ///
  /// Dart-plugin (`dartPluginClass`) registration is no-arg by Flutter
  /// convention — the generated registrant calls
  /// `MultiplyPlugin.registerWith()`.
  static void registerWith() {
    _initialized = true;
  }

  /// Whether the plugin has been registered.
  static bool get isInitialized => _initialized;

  /// Call the native `multiply` function from the bundled shared library.
  static int multiply(int a, int b) => _multiplyFn(a, b);

  static final int Function(int, int) _multiplyFn = _openNativeLib('multiply')
      .lookupFunction<
        ffi.Int32 Function(ffi.Int32, ffi.Int32),
        int Function(int, int)
      >('multiply');
}
