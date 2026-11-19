/// Runtime verification on macOS: launches the bundled .app's binary and
/// asserts all three native-library mechanisms actually worked at runtime.
/// This is a *behavioral* check covering:
///
///  * Native Assets: `add()` binds via `@Native` — the pass depends on the
///    kernel-embedded --native-assets mapping resolving the asset id to the
///    bundled loose `libadd.dylib` in Contents/Frameworks.
///  * native_deps: `mul()` raw-opens `libmul.dylib` by filename, proving the
///    loose-library pipeline bundles where the loader expects.
///  * curated code asset: sqlite3's `@Native` bindings resolve against
///    the bundled libsqlite3.dylib, which nothing in this workspace names —
///    the app depends on drift, and the registry attaches the library to
///    package:sqlite3.
///  * one library for two ids: the app serves `package:count_a` and
///    `package:count_b` from one `libcounter.dylib`, and a count bumped through
///    each reads 2 only if both reached one loaded image of it.
///
/// The binary is launched directly (not via `open`) with TMPDIR pointed at a
/// directory this test controls, so the marker the app writes in main() lands
/// somewhere we can poll deterministically. Tagged "manual"/"exclusive" (like
/// macos_example's verify_macos_app_test) because the engine needs a GUI
/// session. Run explicitly:
///   bazel test :verify_macos_runtime_test --test_tag_filters= \
///     --strategy=TestRunner=standalone
///
/// Pass criteria: the app writes
/// `ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO shared=2
/// negate(5)=-5 kept(20)=21 chain(1)=202` to `$TMPDIR/ffi_result.txt`.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/archive.dart';
import 'package:rules_flutter_e2e_testing/marker_run.dart';

const _marker =
    'ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO shared=2 '
    'negate(5)=-5 kept(20)=21 chain(1)=202';
const _timeout = Duration(seconds: 30);

Future<void> main() async {
  final bundle = ExtractedArchive.fromRunfiles(
    'ffi_macos.zip',
    prefix: 'ffi_macos_runtime',
  );
  try {
    final markerDir = Directory('${bundle.path}/marker')..createSync();
    await runUntilMarker(
      binary: '${bundle.path}/ffi_macos.app/Contents/MacOS/ffi_macos',
      markerFile: File('${markerDir.path}/ffi_result.txt'),
      expected: _marker,
      timeout: _timeout,
      environment: {'TMPDIR': markerDir.path},
    );
    stdout.writeln(
      'PASS: @Native asset bind (add), raw filename open (mul), '
      'the curated sqlite3 code asset and the prebuilt one (negate) all '
      'worked at runtime.',
    );
  } finally {
    bundle.dispose();
  }
}
