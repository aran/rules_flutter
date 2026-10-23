/// Asserts the hand-compiled custom test kernel is reproducible.
///
/// `:widget_custom_kernel` (see `custom_test_kernel.bzl`) compiles its suite
/// by hand over the public `//flutter:utils.bzl` helpers instead of going
/// through `flutter_test`. The resulting dill must carry no absolute host
/// path: every source URI has to be a stable `org-dartlang-app:///` or
/// `package:` URI, the way the stock `flutter_test` kernel names them. A
/// kernel that keys a library by the sandbox's `file://` exec path changes
/// its bytes on every build, on every machine and in every output base —
/// which defeats remote caching and leaks host paths into the artifact.
///
/// Backed by a data file (the custom kernel, copied into the test's runfiles
/// via `data = [":widget_custom_kernel"]`). The test is intentionally
/// hermetic: no `bazel build` from inside the test, no host Flutter SDK. The
/// dill's bytes alone are what prove the custom pipeline is reproducible.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  late String dillText;

  setUpAll(() {
    // The data dep `:widget_custom_kernel` produces the custom test kernel
    // `widget_custom_kernel.dill`, staged in the test's runfiles. Resolve it
    // via the runfiles library rather than guessing paths: that works under
    // both the Unix symlink tree and the Windows manifest.
    final path = Runfiles.create().rlocation(
      '_main/widget_custom_kernel.dill',
    );
    final dill = File(path);
    if (!dill.existsSync()) {
      throw StateError(
        'widget_custom_kernel.dill not found at runfiles path: $path',
      );
    }
    // The dill is binary, but its embedded library URIs are plain ASCII, so
    // decoding byte-for-byte (Latin-1 maps every byte) exposes them to a
    // substring search without ever parsing the kernel format.
    dillText = latin1.decode(dill.readAsBytesSync());
  });

  test('custom kernel embeds no sandbox execroot path', () {
    final hits = 'execroot'.allMatches(dillText).length;
    expect(
      hits,
      equals(0),
      reason:
          'widget_custom_kernel.dill holds $hits URIs under a sandbox '
          'execroot: the custom pipeline keys libraries by absolute host '
          'path instead of stable app-scheme URIs',
    );
  });

  test('custom kernel names libraries under the stable schemes', () {
    // Match on a boolean, not on the 50 MB decoded dill: on failure `contains`
    // would print the whole artifact into the test log.
    expect(
      dillText.contains('org-dartlang-app:///'),
      isTrue,
      reason:
          'widget_custom_kernel.dill names no library under '
          'org-dartlang-app:///: the custom pipeline does not compile '
          'through the stable multi-root scheme the stock rules use',
    );
  });
}
