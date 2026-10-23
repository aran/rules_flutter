// Fixture mimicking the real SDK's trimmed sky_engine libraries: the shipped
// sources still name SDK-internal part files the package omits. Here
// `lib/internal/internal.dart` names `patch.dart`, which is deliberately
// absent: the sky_engine repo rule plants a directive-free stub for each such
// file, so every analysis stages a file behind the dangling directive.
// Without the stubs, analysis fails with
// "'patch.dart' is not a declared input".
library dart._internal;

part 'patch.dart';
