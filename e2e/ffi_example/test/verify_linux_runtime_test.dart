/// Runtime verification on Linux: launches the bundled runner binary and
/// asserts all three native-library mechanisms actually worked at runtime.
/// This is a *behavioral* check covering:
///
///  * Native Assets: `add()` binds via `@Native` — the pass depends on the
///    kernel-embedded --native-assets mapping resolving the asset id to the
///    bundled `lib/libadd.so`.
///  * native_deps: `mul()` raw-opens `libmul.so` by filename, proving the
///    loose-library pipeline bundles where the loader expects.
///  * curated code asset: sqlite3's `@Native` bindings resolve against
///    the bundled libsqlite3.so, which nothing in this workspace names —
///    the app depends on drift, and the registry attaches the library to
///    package:sqlite3.
///  * a code asset that links another: `lib/libchain_top.so` calls into
///    `lib/libchain_base.so` beside it, by the `$ORIGIN` runpath the bundle
///    gave it.
///
/// The runner is launched with TMPDIR pointed at a directory this test
/// controls, so the marker the app writes in main() lands somewhere we can
/// poll deterministically. Tagged "manual"/"exclusive" because the engine
/// needs an X display — on a headless box run under Xvfb with software GL:
///   xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 \
///     bazel test :verify_linux_runtime_test --test_tag_filters= \
///       --strategy=TestRunner=standalone \
///       --test_env=DISPLAY --test_env=XAUTHORITY \
///       --test_env=LIBGL_ALWAYS_SOFTWARE
/// (XAUTHORITY must pass through or GTK fails with "Authorization required".)
///
/// Pass criteria: the app writes
/// `ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO shared=2
/// negate(5)=-5 kept(20)=21 chain(1)=202` to `$TMPDIR/ffi_result.txt`.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/marker_run.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

const _marker =
    'ffi_example_result add(3,4)=7 mul(3,4)=12 sqlite=HELLO shared=2 '
    'negate(5)=-5 kept(20)=21 chain(1)=202';
// Software rendering on a GPU-less VM is slow to first frame; main() runs
// well before that, but boot the whole engine generously.
const _timeout = Duration(seconds: 60);

Future<void> main() async {
  final binary = requireRunfile('ffi_linux/ffi_linux', what: 'Runner binary');

  final markerDir = Directory.systemTemp.createTempSync('ffi_linux_runtime');
  try {
    await runUntilMarker(
      binary: binary,
      markerFile: File('${markerDir.path}/ffi_result.txt'),
      expected: _marker,
      timeout: _timeout,
      environment: {'TMPDIR': markerDir.path},
      // Surface engine/loader errors in the test log.
      forwardOutput: true,
    );
    stdout.writeln(
      'PASS: @Native asset bind (add), raw filename open (mul), '
      'the curated sqlite3 code asset and the prebuilt one (negate) all '
      'worked at runtime.',
    );
  } finally {
    markerDir.deleteSync(recursive: true);
  }
}
