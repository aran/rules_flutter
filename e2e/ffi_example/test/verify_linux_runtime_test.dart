/// Runtime verification on Linux: launches the bundled runner binary and
/// asserts both native-library mechanisms actually worked at runtime.
/// This is a *behavioral* check covering:
///
///  * Native Assets: `add()` binds via `@Native` — the pass depends on the
///    kernel-embedded --native-assets mapping resolving the asset id to the
///    bundled `lib/libadd.so`.
///  * native_deps: `mul()` raw-opens `libmul.so` by filename, proving the
///    loose-library pipeline bundles where the loader expects.
///
/// The runner is launched with TMPDIR pointed at a directory this test
/// controls, so the marker the app writes in main() lands somewhere we can
/// poll deterministically. Tagged "manual"/"exclusive" because the engine
/// needs an X display — on a headless box run under Xvfb with software GL:
///   xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 \
///     bazel test :verify_linux_runtime_test --test_tag_filters= \
///       --strategy=TestRunner=standalone \
///       --test_env=DISPLAY --test_env=LIBGL_ALWAYS_SOFTWARE
///
/// Pass criteria: the app writes
/// `ffi_example_result add(3,4)=7 mul(3,4)=12` to `$TMPDIR/ffi_result.txt`.
import 'dart:io';

const _marker = 'ffi_example_result add(3,4)=7 mul(3,4)=12';
// Software rendering on a GPU-less VM is slow to first frame; main() runs
// well before that, but boot the whole engine generously.
const _timeout = Duration(seconds: 60);

Future<void> main() async {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final binary = '$testSrcDir/$testWorkspace/ffi_linux/ffi_linux';
  if (!File(binary).existsSync()) {
    stderr.writeln('Runner binary not found at $binary');
    exit(1);
  }

  final markerDir = Directory.systemTemp.createTempSync('ffi_linux_runtime');
  final markerFile = File('${markerDir.path}/ffi_result.txt');
  Process? app;
  try {
    print('Launching $binary ...');
    app = await Process.start(
      binary,
      const [],
      environment: {...Platform.environment, 'TMPDIR': markerDir.path},
    );
    // Surface engine/loader errors in the test log.
    app.stdout.listen(stdout.add);
    app.stderr.listen(stderr.add);

    print('Waiting up to ${_timeout.inSeconds}s for ${markerFile.path} ...');
    final deadline = DateTime.now().add(_timeout);
    String? contents;
    while (DateTime.now().isBefore(deadline)) {
      if (markerFile.existsSync()) {
        contents = markerFile.readAsStringSync().trim();
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    if (contents == null) {
      stderr.writeln('FAIL: app never wrote ${markerFile.path} — it likely '
          'crashed before main() completed (native library failed to load?).');
      exit(1);
    }
    print('App recorded: "$contents"');
    if (contents != _marker) {
      stderr.writeln('FAIL: expected "$_marker" but got "$contents".');
      exit(1);
    }
    print('PASS: @Native asset bind (add) and raw filename open (mul) '
        'both worked at runtime.');
  } finally {
    app?.kill();
    markerDir.deleteSync(recursive: true);
  }
}
