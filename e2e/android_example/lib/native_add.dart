/// Native `add` via FFI on platforms with `dart:ffi`; a stub elsewhere (web).
library;

export 'native_add_stub.dart' if (dart.library.ffi) 'native_add_ffi.dart';
