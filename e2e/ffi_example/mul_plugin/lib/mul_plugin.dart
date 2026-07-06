/// Plugin that wraps the native `mul` function via FFI using the classic
/// open-by-path pattern (`native_deps`, no asset ids): the library is opened
/// with `DynamicLibrary.open` at its conventional per-platform location,
/// exactly like the standard Flutter FFI plugin template. rules_flutter
/// bundles the `native_deps` library where each platform's loader expects
/// it, so these conventional paths resolve under Bazel just as they do under
/// the flutter tool. For the zero-path `@Native` asset-id pattern, see
/// `add_plugin`.
library mul_plugin;

import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

typedef _MulNative = ffi.Int32 Function(ffi.Int32 a, ffi.Int32 b);
typedef _MulDart = int Function(int a, int b);

ffi.DynamicLibrary _openMulLib() {
  // iOS bundles the dylib as an embedded `mul.framework`; the framework
  // partial path is how the Flutter plugin template opens it (dyld resolves
  // it against the app's Frameworks directory). The other platforms bundle
  // a loose shared library opened by filename.
  if (Platform.isIOS) return ffi.DynamicLibrary.open('mul.framework/mul');
  if (Platform.isMacOS) return ffi.DynamicLibrary.open('libmul.dylib');
  if (Platform.isLinux) return ffi.DynamicLibrary.open('libmul.so');
  if (Platform.isWindows) return ffi.DynamicLibrary.open('mul.dll');
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Call the native `mul` function from the bundled shared library.
int mul(int a, int b) => _mulFn(a, b);

final _mulFn = _openMulLib().lookupFunction<_MulNative, _MulDart>('mul');
