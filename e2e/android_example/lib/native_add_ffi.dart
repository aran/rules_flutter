/// FFI binding for the native `add` function from `libadd.so`, which
/// `flutter_application.native_deps` compiles for the target Android ABI and
/// `flutter_android_bundle` packages into the APK's `lib/<abi>/`.
library;

import 'dart:ffi' as ffi;

typedef _AddNative = ffi.Int32 Function(ffi.Int32 a, ffi.Int32 b);
typedef _AddDart = int Function(int a, int b);

final _addFn = ffi.DynamicLibrary.open('libadd.so')
    .lookupFunction<_AddNative, _AddDart>('add');

int nativeAdd(int a, int b) => _addFn(a, b);
