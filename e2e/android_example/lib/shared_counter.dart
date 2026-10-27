/// The shared native counter via FFI on platforms with `dart:ffi`; a stub
/// elsewhere (web).
library;

export 'shared_counter_stub.dart'
    if (dart.library.ffi) 'shared_counter_ffi.dart';
