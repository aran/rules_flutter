/// Verifies Dart environment defines reach the compiled test:
/// - the target's `defines` attr,
/// - the `--@rules_dart//dart:extra_dart_defines` flag (set for this test
///   by `extra_dart_defines_test` in BUILD.bazel),
/// - flag-beats-attr precedence on a key collision.
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('defines attr reaches String.fromEnvironment', () {
    expect(const String.fromEnvironment('E2E_ATTR'), 'from_attr');
  });

  test('extra_dart_defines flag reaches String.fromEnvironment', () {
    expect(const String.fromEnvironment('E2E_FLAG'), 'from_flag');
  });

  test('flag wins over attr on key collision', () {
    expect(const String.fromEnvironment('E2E_WINNER'), 'flag');
  });
}
