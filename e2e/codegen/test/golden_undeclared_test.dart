// Exercises: a golden that exists in the source tree but is not a declared
// input of the test.
//
// `goldens/stand_in.png` sits right there next to this file, and
// `golden_test.dart` reads it happily — because that target lists it in
// `data`. This one does not, so under the sandbox the PNG is simply not in
// runfiles and the comparison fails as "non-existent file".
//
// That is the property worth a test of its own. It is what stops a golden from
// being read behind Bazel's back: a comparison whose inputs are all declared
// is one whose cached "pass" still means something, and one that reached
// outside the action graph would go stale silently on a disk-cache hit. It
// also means the fix for this failure is a BUILD edit — `data =
// glob(["test/goldens/**"])` — not a change to the test.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the golden really is absent from runfiles, and not merely absent', () {
    // Without this the suite could pass vacuously. "Not declared" and "deleted
    // from the source tree" produce the identical "non-existent file" error, so
    // if `stand_in.png` were ever renamed away, the assertion below would keep
    // passing while testing nothing.
    //
    // Between the two targets the discriminator is pinned to declaredness
    // alone: `golden_test` asserts the file IS in its runfiles, having globbed
    // it into `data`, and this asserts it is NOT in ours. Only the BUILD
    // attribute differs.
    final basedir = (goldenFileComparator as LocalFileComparator).basedir;
    expect(
      File.fromUri(basedir.resolve('goldens/stand_in.png')).existsSync(),
      isFalse,
      reason: 'this target declares no `data`, so runfiles must not hold it',
    );
  });

  testWidgets('an undeclared golden is invisible to the test, however real it '
      'looks in the source tree', (tester) async {
    await tester.pumpWidget(
      const Center(
        child: SizedBox(
          width: 64,
          height: 64,
          child: ColoredBox(color: Color(0xFF2196F3)),
        ),
      ),
    );

    await expectLater(
      expectLater(
        find.byType(ColoredBox),
        matchesGoldenFile('goldens/stand_in.png'),
      ),
      throwsA(
        isA<TestFailure>().having(
          (e) => e.message,
          'message',
          contains('non-existent file'),
        ),
      ),
    );
  });
}
