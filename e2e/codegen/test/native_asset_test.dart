// Proves a Dart Native Asset binds under `flutter_tester`.
//
// The manifest the frontend_server embeds into the test's kernel is written at
// build time and cannot be rewritten later, so it has to name a path that
// resolves where the test actually runs — Bazel's runfiles tree, not an
// application bundle. If that path is wrong, this fails at the first call with
// "couldn't resolve native function", which is exactly the failure mode the
// unreplaced-hook check exists to prevent elsewhere.
import 'package:flutter_test/flutter_test.dart';
import 'package:native_add/native_add.dart';

void main() {
  test('a code asset owned by a dependency binds through the manifest', () {
    expect(nativeAdd(3, 4), 7);
  });

  test('the binding is the native one, not a Dart fallback', () {
    // Values chosen to overflow a signed 32-bit add the way the C does, so a
    // hypothetical Dart reimplementation would disagree.
    expect(nativeAdd(2147483647, 1), -2147483648);
  });
}
