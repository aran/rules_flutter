// The kernel `unused_inputs_list` must keep every dependency shape `:a`
// exercises: the adopted `part of` file, the re-exported library, and the
// folded constant. If a list ever wrongly skipped one of those compiles, the
// linked test dill would keep the stale value and these expectations would
// fail after an incremental rebuild.
import 'package:flutter_test/flutter_test.dart';
import 'package:unused_a/adopt.dart';

void main() {
  test('adopted part value flows through', () {
    expect(adoptValue(), 7);
  });

  test('re-exported library resolves', () {
    expect(cValue(), 3);
  });

  test('folded constant matches', () {
    expect(foldedAgain, 43);
  });
}
