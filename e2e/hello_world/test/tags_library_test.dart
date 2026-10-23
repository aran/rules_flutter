// Library-level `@Tags` under `flutter_test`, as `flutter test` resolves it.
//
// `tags_library_test` in BUILD.bazel runs this suite with
// `exclude_tags = ["golden"]`. The `@Tags` below is the entrypoint's own
// annotation, so `package:test` reports it on the suite's root group and every
// case inherits it: the whole suite prunes to empty, and an empty suite passes.
// The case fails if it runs anyway, so a green run proves the root-group
// inheritance happened.
//
// Only the entrypoint's own annotation counts: a `@Tags` on an *imported*
// file is invisible here, exactly as under `flutter test` (each suite file's
// annotations become that suite's root metadata, and this file is the suite).
@Tags(['golden'])
library;

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pruned through its library tag', () {
    fail('ran despite exclude_tags = ["golden"]');
  });
}
