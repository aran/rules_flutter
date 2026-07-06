/// Plugin that wraps the native `add` function via FFI (`native_deps`, no
/// dart_plugin_class). The shared library is bundled loose on
/// macOS/Linux/Windows; on iOS rules_flutter wraps it in a signed
/// `add.framework` (loose embedded dylibs are forbidden there).
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
  // iOS forbids loose embedded dylibs, so rules_flutter wraps the native
  // library in a signed `add.framework` (see flutter_ios_native_frameworks;
  // the `lib` prefix and `.dylib` suffix are stripped to form the framework
  // name). It loads via the app's @rpath (@executable_path/Frameworks). The
  // other platforms bundle a loose shared library opened by filename.
  if (Platform.isIOS) {
    return ffi.DynamicLibrary.open('@rpath/add.framework/add');
  }
  return ffi.DynamicLibrary.open(_nativeLibName('add'));
}

/// Call the native `add` function from the bundled shared library.
int add(int a, int b) => _addFn(a, b);

final _addFn = _openAddLib().lookupFunction<_AddNative, _AddDart>('add');
