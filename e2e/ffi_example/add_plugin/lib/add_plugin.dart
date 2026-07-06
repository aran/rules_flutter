/// Plugin that wraps the native `add` function via the Dart Native Assets
/// pipeline (`flutter_native_asset`, no dart_plugin_class). One `@Native`
/// binding works on every platform: the VM resolves this library's default
/// asset id (`package:add_plugin/add_plugin.dart`) at first call through the
/// native-assets mapping the frontend_server embedded in the kernel, then
/// dlopens the bundled library — `add.framework/add` on iOS (signed
/// framework), a loose `libadd.dylib`/`libadd.so`/`add.dll` elsewhere.
///
/// Note asset ids resolve only at `@Native` bind time. Raw
/// `DynamicLibrary.open('package:...')` does NOT consult the mapping — the
/// Dart VM passes the literal string to dlopen, on every platform. For the
/// classic open-by-path pattern, see `mul_plugin`.
library add_plugin;

import 'dart:ffi' as ffi;

typedef _AddNative = ffi.Int32 Function(ffi.Int32 a, ffi.Int32 b);

@ffi.Native<_AddNative>(symbol: 'add')
external int _addViaAsset(int a, int b);

/// Call the native `add` function from the bundled shared library.
int add(int a, int b) => _addViaAsset(a, b);
