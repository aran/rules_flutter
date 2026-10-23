// Tag selection under `flutter_test`, as `flutter test --tags` resolves it.
//
// `tags_test` in BUILD.bazel runs this suite with `exclude_tags = ["golden"]`:
// the untagged case below runs, and every case carrying the golden tag through
// its own `tags:` is pruned before it runs. A pruned case that runs anyway
// fails here, so a green run proves the pruning happened.
//
// (`package:flutter_test`'s `group()` takes no `tags:`, so group-level tags
// only reach the runner through the protocol itself; they are covered in
// `flutter/private/tools/test/bazel_test_protocol_test.dart`. Library-level
// `@Tags` are covered by `tags_library_test.dart` in this directory.)
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs without a tag', () {
    expect(1 + 1, 2);
  });

  test('pruned through its own tag', () {
    fail('ran despite exclude_tags = ["golden"]');
  }, tags: ['golden']);

  group('plain group', () {
    test('pruned inside a plain group', () {
      fail('ran despite exclude_tags = ["golden"]');
    }, tags: ['golden']);
  });
}
