/// Plugin that wraps the native `add` function via FFI (no
/// dart_plugin_class). The shared library is bundled loose on
/// macOS/Linux/Windows (`native_deps`) and opened by filename; on iOS it is
/// declared as a Dart Native Asset (`flutter_native_asset`), wrapped in a
/// signed `add.framework` (loose embedded dylibs are forbidden there), and
/// bound by asset id via `@Native`.
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

ffi.DynamicLibrary _openAddLib() {
  return ffi.DynamicLibrary.open(_nativeLibName('add'));
}

// iOS binds through Native Asset id resolution: the VM resolves the asset id
// lazily at first call, via the native-assets mapping the frontend_server
// embedded in the kernel, and dlopens the embedded `add.framework/add`.
//
// Note this only works with `@Native(assetId: ...)` (bind-time resolution).
// Raw `DynamicLibrary.open('package:add_plugin/add.dylib')` does NOT consult
// the mapping — the Dart VM passes the literal string to dlopen, on every
// platform — so an asset id is not a loadable path.
@ffi.Native<_AddNative>(symbol: 'add', assetId: 'package:add_plugin/add.dylib')
external int _addViaAsset(int a, int b);

/// Call the native `add` function from the bundled shared library.
int add(int a, int b) {
  if (Platform.isIOS) return _addViaAsset(a, b);
  return _addFn(a, b);
}

final _addFn = _openAddLib().lookupFunction<_AddNative, _AddDart>('add');
