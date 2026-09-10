// Exercises: the golden-file comparator `flutter_test` installs into its
// generated bootstrap.
//
// No golden here is a rendered image, deliberately. Font rasterisation and
// antialiasing differ between operating systems, so a committed PNG that this
// host's rendering matches is a machine-specific artifact that CI would fail
// on — that is upstream's limitation, not Bazel's. What is asserted instead is
// the machinery: that a real comparator is installed and correctly rooted,
// that it can tell "declared but different" from "not declared at all", that
// its pass path passes, and that its diffs land somewhere a developer can
// still read after the sandbox is gone.
//
// The paired negative lives in `golden_undeclared_test.dart`: the same PNG, on
// disk at the same path, with no `data` entry.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Text-free and fixed-size, so what it renders depends on no font and no
/// window geometry. The point is never the pixels — only that there are some.
Widget get _subject => const Center(
  child: SizedBox(
    width: 64,
    height: 64,
    child: ColoredBox(color: Color(0xFF2196F3)),
  ),
);

/// The 1×1 stand-in. See `goldens/README.md`: it exists to be found and to not
/// match.
const _standIn = 'goldens/stand_in.png';

void main() {
  test('the rule installs a real comparator, rooted at the test file', () {
    // Flutter's fallback `TrivialComparator` — the sentinel meaning "no tool
    // bootstrapped this test", whose `compare()` returns true without reading
    // anything — is not a `LocalFileComparator`, so this single assertion is
    // what proves a real comparator was installed.
    expect(goldenFileComparator, isA<LocalFileComparator>());

    // Upstream's convention, which the Bazel wiring has to reproduce: goldens
    // are relative to the *directory of the test file*. Here that is the
    // runfiles copy of `e2e/codegen/test/`.
    final basedir = (goldenFileComparator as LocalFileComparator).basedir;
    expect(basedir.path, endsWith('/test/'));
    expect(File.fromUri(basedir.resolve(_standIn)).existsSync(), isTrue);

    // Update mode is off unless `--update-goldens` was passed under
    // `bazel run`; a test action has no source tree to write back to.
    expect(autoUpdateGoldenFiles, isFalse);
  });

  testWidgets('a golden that is not a declared input fails, and does not '
      'silently skip', (tester) async {
    await tester.pumpWidget(_subject);

    // This must be the "non-existent file" failure upstream raises, since
    // nothing declares `goldens/absent.png` anywhere.
    //
    // A missing golden and a mismatched one arrive by different routes, which
    // is why this test and the next assert differently. `getGoldenBytes` calls
    // `fail()`, so the `TestFailure` travels out through the matcher's own
    // future and can be caught by wrapping `expectLater`. A mismatch instead
    // throws a `FlutterError` from inside guarded async work, which reaches
    // the binding rather than the future — see below. Both are upstream's
    // behaviour, unchanged here.
    await expectLater(
      expectLater(
        find.byType(ColoredBox),
        matchesGoldenFile('goldens/absent.png'),
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

  testWidgets('a declared golden is read and compared, and its diffs land '
      'where Bazel archives them', (tester) async {
    await tester.pumpWidget(_subject);

    // The discriminator against `golden_undeclared_test.dart`: same PNG, same
    // path, but declared in `data` here. "Pixel test failed" means the
    // comparator found and decoded it; "non-existent file" would mean it never
    // arrived in runfiles.
    //
    // `expectLater` itself completes normally: the mismatch is a `FlutterError`
    // thrown from `compare()` inside async matcher work, so it is reported to
    // the binding and collected with `takeException` — the standard way to
    // assert on an expected framework error.
    await expectLater(find.byType(ColoredBox), matchesGoldenFile(_standIn));
    final error = tester.takeException();
    expect(error, isA<FlutterError>());

    final message = error.toString();
    expect(message, contains('Pixel test failed'));
    expect(message, isNot(contains('non-existent file')));

    // Upstream names `<basedir>/failures` in the hint, which under Bazel is a
    // sandbox directory that no longer exists when the developer reads the
    // log. The comparator names the archived location instead.
    expect(message, contains('bazel-testlogs'));

    // And the bytes really are written, into the directory Bazel archives to
    // that location. Asserted as "non-empty" rather than a file count: a
    // size mismatch yields two diff images and a same-size mismatch four, and
    // which one this is depends on the stand-in's dimensions.
    final outputs = Platform.environment['TEST_UNDECLARED_OUTPUTS_DIR'];
    expect(outputs, isNotNull, reason: 'set by bazel test');
    final failures = Directory('$outputs/failures');
    expect(failures.existsSync(), isTrue);
    expect(failures.listSync(), isNotEmpty);
  });

  test('the comparator passes when the bytes match', () async {
    // The pass path, without claiming any rendering matches a committed PNG:
    // the golden is compared against its own bytes, so equality is true by
    // construction on every host. Without this, a comparator that failed
    // *everything* would still satisfy the two mismatch assertions above.
    final comparator = goldenFileComparator as LocalFileComparator;
    final golden = Uri.parse(_standIn);
    final bytes = await File.fromUri(
      comparator.basedir.resolveUri(golden),
    ).readAsBytes();

    expect(await comparator.compare(bytes, golden), isTrue);
  });
}
