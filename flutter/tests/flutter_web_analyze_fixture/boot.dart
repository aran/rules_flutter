/// A `flutter_web_bundle` `main` that lives *outside* its package's `lib/`, at
/// the package root beside `web/`. A release bundle can still express that
/// shape — the generated wrapper imports `main` by relative path — while a
/// `-c dbg` build of it is refused, because the dev loop's synthetic
/// entrypoint can reach the app only by `package:` URI.
///
/// No `package:` URI reaches this file, so no `DartPackageInfo` can name it and
/// the rule routes it to `srcs`.
library;

import 'dart:ui';

import 'package:flutter_web_analyze_fixture/greeting.dart';

void main() {
  final grown = grow(const Size(4, 5), 6);
  assert(grown.height == 11, 'grow() should add to height');
}
