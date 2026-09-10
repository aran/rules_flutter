// Exercises: a `flutter_test` whose deps carry `package:test_api` and nothing
// else.
//
// The rule accepts `package:flutter_test` *or* `package:test_api` — the
// generated bootstrap needs `RemoteListener`, which `test_api` provides on its
// own — but the golden-file comparator it installs is flutter_test's alone.
// Those are two different predicates, and this target is what proves the second
// one still exists: `goldenFileComparator` and `autoUpdateGoldenFiles` are
// flutter_test members, so a golden block that stopped being gated would fail
// this target's kernel compile on an import it never asked for.
//
// Deliberately asserts nothing about goldens: compiling and passing without
// them is the coverage.
import 'package:test_api/scaffolding.dart';

void main() {
  test('a test_api-only suite bootstraps, compiles, and runs', () {});
}
