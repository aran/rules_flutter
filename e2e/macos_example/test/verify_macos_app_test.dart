/// Runtime verification: launches the macOS .app and checks window dimensions.
///
/// This test requires a GUI environment and accessibility permissions, so it
/// uses `tags = ["manual"]` to skip during normal `bazel test //...` runs.
/// Run explicitly: `bazel test :verify_macos_app_test --test_tag_filters=`
///
/// Pass criteria:
/// - App launches without crashing
/// - Window appears within 30s
/// - Window width > 100 AND height > 100 (catches the 1x32 sizing bug)
import 'dart:io';

Future<void> main() async {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final zipPath = '$testSrcDir/$testWorkspace/app.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  // Extract to temp directory.
  final tmpDir = Directory.systemTemp.createTempSync('macos_app_test');
  try {
    final unzip =
        Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }

    final appPath = '${tmpDir.path}/Flutter App.app';
    final bundleName = 'Flutter App';

    // Launch the app.
    print('Launching $appPath ...');
    final launch = await Process.run('open', [appPath]);
    if (launch.exitCode != 0) {
      stderr.writeln('Failed to launch app: ${launch.stderr}');
      exit(1);
    }

    // Poll for window to appear (up to 30s).
    print('Waiting for window (up to 30s) ...');
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var windowFound = false;
    while (DateTime.now().isBefore(deadline)) {
      final result = await Process.run('osascript', [
        '-e',
        'tell application "System Events" to get (count of windows of process "$bundleName")',
      ]);
      if (result.exitCode == 0) {
        final count = int.tryParse(result.stdout.toString().trim()) ?? 0;
        if (count > 0) {
          windowFound = true;
          break;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    if (!windowFound) {
      stderr.writeln('FAIL: No window found for $bundleName after 30s');
      await _quitApp(bundleName);
      exit(1);
    }
    print('Window found.');

    // Give Flutter a moment to render.
    await Future<void>.delayed(const Duration(seconds: 3));

    // Check window size.
    final sizeResult = await Process.run('osascript', [
      '-e',
      'tell application "System Events" to tell process "$bundleName" to get size of window 1',
    ]);
    final sizeStr = sizeResult.stdout.toString().trim();
    print('Window size: $sizeStr');

    final parts =
        sizeStr.split(',').map((s) => int.tryParse(s.trim()) ?? 0).toList();
    final width = parts.isNotEmpty ? parts[0] : 0;
    final height = parts.length > 1 ? parts[1] : 0;

    // Verify process is still alive.
    final pgrepResult =
        Process.runSync('pgrep', ['-x', bundleName]);
    final processAlive = pgrepResult.exitCode == 0;
    print('Process alive: $processAlive');

    // Quit the app.
    await _quitApp(bundleName);

    // Evaluate results.
    final sizeOk = width > 100 && height > 100;
    print('');
    print('=== Results ===');
    print('Window appeared: yes');
    print('Window size: ${width}x$height (${sizeOk ? "OK" : "FAIL — too small"})');
    print('Process alive: $processAlive');

    if (!sizeOk) {
      stderr.writeln(
          'FAIL: Window size ${width}x$height is too small (expected > 100x100)');
      exit(1);
    }
    if (!processAlive) {
      stderr.writeln('FAIL: Process crashed before verification completed');
      exit(1);
    }

    print('PASS');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

Future<void> _quitApp(String bundleName) async {
  await Process.run('osascript', [
    '-e',
    'tell application "$bundleName" to quit',
  ]);
  await Future<void>.delayed(const Duration(seconds: 2));
}
