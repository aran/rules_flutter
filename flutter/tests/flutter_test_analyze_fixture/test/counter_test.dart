/// A `flutter_test` `main`, analyzed by `:analyze_test`.
///
/// It belongs to no package's `lib/`, so no `DartInfo` can name it and it
/// reaches the analyzer only as `DartAnalyzableInfo.srcs`. Before
/// `flutter_test` provided that, this file — and every test source like it —
/// was analyzed by nothing.
library;

import 'dart:ui';

import 'package:flutter_test_analyze_fixture/counter.dart';

void main() {
  final grown = grow(const Size(1, 2), 3);
  assert(grown.width == 4, 'grow() should add to width');
}
