/// Runtime verification on Windows: launches the bundled runner exe and
/// asserts all three native-library mechanisms actually worked at runtime.
/// This is a *behavioral* check covering:
///
///  * Native Assets: `add()` binds via `@Native` — the pass depends on the
///    kernel-embedded --native-assets mapping resolving the asset id to the
///    bundled `add.dll` next to the exe.
///  * native_deps: `mul()` raw-opens `mul.dll` by filename, proving the
///    loose-library pipeline bundles where the loader expects.
///  * curated code asset: sqlite3's `@Native` bindings resolve against
///    the bundled sqlite3.dll, which nothing in this workspace names —
///    the app depends on drift, and the registry attaches the library to
///    package:sqlite3.
///  * a code asset that links another: `chain_top.dll` calls into
///    `chain_base.dll` beside it, next to the exe.
///
/// The runner is launched with TMP/TEMP pointed at a directory this test
/// controls, so the marker the app writes in main() lands somewhere we can
/// poll deterministically. Tagged "manual"/"exclusive" because the engine
/// creates a window and a D3D surface — run on a box with a (virtual)
/// display adapter:
///   bazel test :verify_windows_runtime_test --test_tag_filters= \
///     --strategy=TestRunner=standalone
///
/// Pass criteria: the app writes
/// `ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO shared=2
/// negate(5)=-5 kept(20)=21 chain(1)=202` to `%TMP%\ffi_result.txt`.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/marker_run.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

const _marker =
    'ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO shared=2 '
    'negate(5)=-5 kept(20)=21 chain(1)=202';
const _timeout = Duration(seconds: 60);

Future<void> main() async {
  final binary = requireRunfile(
    'ffi_windows/ffi_windows.exe',
    what: 'Runner binary',
  );

  final markerDir = Directory.systemTemp.createTempSync('ffi_windows_runtime');
  try {
    await runUntilMarker(
      binary: binary,
      markerFile: File('${markerDir.path}\\ffi_result.txt'),
      expected: _marker,
      timeout: _timeout,
      environment: {'TMP': markerDir.path, 'TEMP': markerDir.path},
      forwardOutput: true,
    );
    stdout.writeln(
      'PASS: @Native asset bind (add), raw filename open (mul), '
      'the curated sqlite3 code asset and the prebuilt one (negate) all '
      'worked at runtime.',
    );
  } finally {
    // After the app has exited, which `runUntilMarker` waits for.
    markerDir.deleteSync(recursive: true);
  }
}
