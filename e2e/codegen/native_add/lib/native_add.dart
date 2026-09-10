/// A package that owns a native code asset, in the shape `pub.from_lock()`
/// generates for a pub package with a curated `//dart/ext` entry: the asset
/// rides `DartPackageInfo.code_assets`, and nothing downstream names it.
///
/// The `@Native` binding carries no asset id, so the VM derives this library's
/// default one — `package:native_add/native_add.dart` — and resolves it through
/// the native-assets mapping the frontend_server embedded in the kernel. That
/// mapping is the only thing under test: a raw `DynamicLibrary.open` would not
/// consult it.
library;

import 'dart:ffi' as ffi;

@ffi.Native<ffi.Int32 Function(ffi.Int32 a, ffi.Int32 b)>(symbol: 'native_add')
external int _nativeAdd(int a, int b);

/// Adds two integers in native code.
int nativeAdd(int a, int b) => _nativeAdd(a, b);
