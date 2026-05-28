/// Plugin that wraps the native `add` function via FFI.
///
/// Demonstrates a flutter_plugin with native_deps only (no dart_plugin_class).
/// The native shared library is bundled automatically via FlutterInfo.
library add_plugin;

import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

typedef _AddNative = ffi.Int32 Function(ffi.Int32 a, ffi.Int32 b);
typedef _AddDart = int Function(int a, int b);

String _nativeLibName(String baseName) {
  if (Platform.isMacOS) return 'lib$baseName.dylib';
  if (Platform.isLinux) return 'lib$baseName.so';
  if (Platform.isWindows) return '$baseName.dll';
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Call the native `add` function from the bundled shared library.
int add(int a, int b) => _addFn(a, b);

final _addFn = ffi.DynamicLibrary.open(_nativeLibName('add'))
    .lookupFunction<_AddNative, _AddDart>('add');
