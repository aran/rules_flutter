import 'dart:ffi';
import 'dart:io';

final _dylib = DynamicLibrary.open(_libPath);

String get _libPath {
  if (Platform.isMacOS) return 'libadd.dylib';
  if (Platform.isLinux) return 'libadd.so';
  if (Platform.isWindows) return 'add.dll';
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

final int Function(int, int) _addFunc = _dylib
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'add',
    );

/// Returns `a + b`, computed by the plugin's native library rather than in
/// Dart.
int add(int a, int b) => _addFunc(a, b);
