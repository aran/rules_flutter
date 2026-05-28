/// Minimal Flutter test for build verification.
///
/// Verifies that dart:ui types are available at compilation time.
/// Avoids calling FFI-bound constructors since flutter_test runs on the
/// plain Dart VM without the Flutter engine shared library.
import 'dart:ui' show Color, Rect, Offset;

void main() {
  // Verify dart:ui types resolve and non-native constructors work.
  const color = Color(0xFF00FF00);
  const rect = Rect.fromLTWH(0, 0, 100, 100);
  const offset = Offset(10, 20);

  assert(color.value == 0xFF00FF00);
  assert(rect.width == 100);
  assert(offset.dx == 10);

  // ignore: avoid_print
  print('Flutter test passed: dart:ui types available');
}
