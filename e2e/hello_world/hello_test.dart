/// Minimal Flutter test for build verification.
///
/// Verifies that dart:ui types are available at compilation time.
/// Avoids calling FFI-bound constructors since flutter_test runs on the
/// plain Dart VM without the Flutter engine shared library.
library;

import 'dart:ui' show Color, Offset, Rect;

void main() {
  // Verify dart:ui types resolve and non-native constructors work.
  const color = Color(0xFF00FF00);
  const rect = Rect.fromLTWH(0, 0, 100, 100);
  const offset = Offset(10, 20);

  assert(color.toARGB32() == 0xFF00FF00, 'Color lost its ARGB value');
  assert(rect.width == 100, 'Rect.fromLTWH computed the wrong width');
  assert(offset.dx == 10, 'Offset lost its dx');

  // The line below is this test's only observable output, so `print` is its
  // reporting channel rather than a stray debugging statement.
  // ignore: avoid_print
  print('Flutter test passed: dart:ui types available');
}
