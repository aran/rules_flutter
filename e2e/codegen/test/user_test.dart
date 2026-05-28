/// Regression test for the flutter_test colocate gap.
///
/// `lib/user.dart` declares `part 'user.g.dart';`. The generated part is
/// produced by `:user_json` (a `dart_codegen` target) and lives in `bazel-out`.
/// This test imports the package by its `package:` URI — the same shape every
/// real test uses — so the kernel compile must resolve `package:codegen_e2e/
/// user.dart`'s `part` against a directory that contains both the hand-written
/// source and the generated `.g.dart` sibling. That only works if flutter_test
/// runs `colocate_packages` to assemble the split package into one tree-artifact
/// directory and rewrites the package's `rootUri` to point at it.
import 'package:flutter_test/flutter_test.dart';

import 'package:codegen_e2e/user.dart';

void main() {
  test('User.toJson() (generated extension in user.g.dart) is callable', () {
    final json = User('Alice', 30).toJson();
    expect(json, {'name': 'Alice', 'age': 30});
  });
}
