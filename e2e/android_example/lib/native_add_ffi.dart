/// FFI binding for the native `add` function from `libadd.so`, which
/// `flutter_application.native_deps` compiles for the target Android ABI and
/// `flutter_android_bundle` packages into the APK's `lib/<abi>/`.
library;

import 'dart:ffi' as ffi;

final int Function(int, int) _addFn = ffi.DynamicLibrary.open('libadd.so')
    .lookupFunction<
      ffi.Int32 Function(ffi.Int32, ffi.Int32),
      int Function(int, int)
    >('add');

/// Returns `a + b`, computed by `libadd.so` inside the APK.
int nativeAdd(int a, int b) => _addFn(a, b);
