/// Runtime verification on macOS: launches the bundled .app's binary and
/// asserts both native-library mechanisms actually worked at runtime.
/// This is a *behavioral* check covering:
///
///  * Native Assets: `add()` binds via `@Native` — the pass depends on the
///    kernel-embedded --native-assets mapping resolving the asset id to the
///    bundled loose `libadd.dylib` in Contents/Frameworks.
///  * native_deps: `mul()` raw-opens `libmul.dylib` by filename, proving the
///    loose-library pipeline bundles where the loader expects.
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
/// `ffi_example_result add(3,4)=7 mul(3,4)=12` to `$TMPDIR/ffi_result.txt`.
import 'dart:io';

const _marker = 'ffi_example_result add(3,4)=7 mul(3,4)=12';
const _timeout = Duration(seconds: 30);

Future<void> main() async {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final zipPath = '$testSrcDir/$testWorkspace/ffi_macos.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('ffi_macos_runtime');
  Process? app;
  try {
    final unzip = Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }

    final binary = '${tmpDir.path}/ffi_macos.app/Contents/MacOS/ffi_macos';
    final markerDir = Directory('${tmpDir.path}/marker')..createSync();
    final markerFile = File('${markerDir.path}/ffi_result.txt');

    print('Launching $binary ...');
    app = await Process.start(
      binary,
      const [],
      environment: {...Platform.environment, 'TMPDIR': markerDir.path},
    );

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
    tmpDir.deleteSync(recursive: true);
  }
}
