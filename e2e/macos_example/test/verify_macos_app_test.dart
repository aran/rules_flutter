/// Runtime verification: launches the macOS .app, checks window dimensions, and
/// checks that both bundled native libraries loaded.
///
/// This test requires a GUI environment and accessibility permissions, so it
/// uses `tags = ["manual"]` to skip during normal `bazel test //...` runs.
/// Run explicitly: `bazel test :verify_macos_app_test --test_tag_filters=`
///
/// Everything is addressed by the PID this test launched, never by the bundle
/// name: a leftover instance — one an earlier run failed to reap, or a copy
/// launched by hand — would otherwise answer for the bundle under test, and
/// the run would pass without the freshly built binary drawing anything.
/// Launching `Contents/MacOS/<exe>` directly rather than through `open` is
/// part of that: LaunchServices activates an already-running instance of the
/// same bundle id instead of starting ours.
///
/// Pass criteria:
/// - App launches without crashing
/// - Window appears within 30s
/// - Window width > 100 AND height > 100
/// - The app prints `macos_example_native sum=7 difference=3`: `add` from
///   `libadd.dylib` (built at its package root) and `sub` from `libsub.dylib`
///   (built in a subdirectory of its package) both loaded and answered. A
///   window alone does not show this — a library that fails to load throws in
///   `main()` before `runApp`, and the runner still opens its window at full
///   size.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _nativeMarker = 'macos_example_native';
const _expectedNative = '$_nativeMarker sum=7 difference=3';

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
    final unzip = Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }

    await _assertWindowEnumerationWorks();

    const bundleName = 'Flutter App';
    final appPath = '${tmpDir.path}/$bundleName.app';
    final executable = '$appPath/Contents/MacOS/$bundleName';

    print('Launching $executable ...');
    final process = await Process.start(executable, const []);
    final pid = process.pid;
    print('PID: $pid');

    // Drain both streams for the life of the process — an undrained pipe can
    // block the app on a write — and keep them for the failure report.
    final output = StringBuffer();
    final nativeLine = Completer<String>();
    for (final stream in [process.stdout, process.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
        line,
      ) {
        output.writeln(line);
        if (!nativeLine.isCompleted && line.contains(_nativeMarker)) {
          nativeLine.complete(line);
        }
      });
    }

    // A crash exits before any window can appear; report that rather than
    // spending 30s waiting for a window from a process that is already gone.
    var exitCode = -1;
    var exited = false;
    unawaited(
      process.exitCode.then((code) {
        exited = true;
        exitCode = code;
      }),
    );

    // Poll for window to appear (up to 30s).
    print('Waiting for window (up to 30s) ...');
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var windowFound = false;
    while (DateTime.now().isBefore(deadline)) {
      if (exited) {
        stderr.writeln(
          'FAIL: process $pid exited with code $exitCode before '
          'showing a window',
        );
        exit(1);
      }
      final count = await _windowCount(pid);
      if (count > 0) {
        windowFound = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    if (!windowFound) {
      stderr.writeln('FAIL: No window found for PID $pid after 30s');
      await _quitApp(pid);
      exit(1);
    }
    print('Window found.');

    // Give Flutter a moment to render.
    await Future<void>.delayed(const Duration(seconds: 3));

    // Check window size.
    final sizeScript =
        'tell application "System Events" to tell (first '
        'process whose unix id is $pid) to get size of window 1';
    final sizeResult = await Process.run('osascript', ['-e', sizeScript]);
    final sizeStr = sizeResult.stdout.toString().trim();
    print('Window size: $sizeStr');

    final parts = sizeStr
        .split(',')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .toList();
    final width = parts.isNotEmpty ? parts[0] : 0;
    final height = parts.length > 1 ? parts[1] : 0;

    final processAlive = !exited;
    print('Process alive: $processAlive');

    // `main()` prints this before `runApp`, so it normally arrived before the
    // first frame. Bounded because an app whose library failed to load never
    // reaches the print, and the wait has to end for that to be reported.
    final native = await nativeLine.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => '',
    );

    await _quitApp(pid);

    // Evaluate results.
    final sizeOk = width > 100 && height > 100;
    print('');
    print('=== Results ===');
    print('Window appeared: yes');
    print(
      'Window size: ${width}x$height '
      '(${sizeOk ? "OK" : "FAIL — too small"})',
    );
    print('Process alive: $processAlive');
    print('Native libraries: ${native.isEmpty ? "no report" : native}');

    if (!native.contains(_expectedNative)) {
      stderr
        ..writeln(
          'FAIL: expected the app to print "$_expectedNative" — a bundled '
          'native library did not load or did not answer',
        )
        ..writeln('--- app output ---')
        ..write(output);
      exit(1);
    }
    if (!sizeOk) {
      stderr.writeln(
        'FAIL: Window size ${width}x$height is too small '
        '(expected > 100x100)',
      );
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

/// Fails the run if System Events cannot enumerate windows at all.
///
/// It reports success and a count of zero in two very different situations:
/// the process genuinely has no window, and the accessibility path is wedged —
/// after which *every* process on the machine reports zero, Finder included.
/// Without this probe the second case is indistinguishable from a Flutter app
/// that came up blank, and the test spends 30 seconds before blaming the app.
/// A desktop with a window server running always has some windowed process, so
/// a total of zero is the harness failing, not an answer.
Future<void> _assertWindowEnumerationWorks() async {
  const script =
      'tell application "System Events"\n'
      '  set total to 0\n'
      '  repeat with p in (processes whose background only is false)\n'
      '    set total to total + (count of windows of p)\n'
      '  end repeat\n'
      '  return total\n'
      'end tell';
  final result = await Process.run('osascript', ['-e', script]).timeout(
    const Duration(seconds: 20),
    onTimeout: () => ProcessResult(0, 1, '', 'System Events did not respond'),
  );
  final total = result.exitCode == 0
      ? int.tryParse(result.stdout.toString().trim()) ?? 0
      : 0;
  if (total > 0) return;

  stderr.writeln(
    'FAIL: System Events reports no windows for any process, so '
    'it cannot answer for ours either.',
  );
  if (result.exitCode != 0) {
    stderr.writeln('osascript: ${result.stderr.toString().trim()}');
  }
  stderr.writeln(
    'This is a harness failure, not an app failure. Grant '
    'accessibility access to the test runner in System Settings > Privacy & '
    'Security > Accessibility, then `killall "System Events"` and re-run.',
  );
  exit(1);
}

/// Windows belonging to [pid], or 0 when the process has none.
///
/// A nonzero exit from osascript is not "no windows" — it is "the question was
/// not answered", most often because the accessibility grant for window
/// enumeration is missing or System Events is wedged. Reporting 0 there turns
/// a broken harness into a 30-second wait ending in a verdict about the app,
/// so the error is surfaced instead.
Future<int> _windowCount(int pid) async {
  final script =
      'tell application "System Events" to get (count of windows '
      'of (first process whose unix id is $pid))';
  final result = await Process.run('osascript', ['-e', script]);
  if (result.exitCode != 0) {
    final message = result.stderr.toString().trim();
    // The process may not have registered with the window server yet; that
    // shows up as "can't get process" and is a legitimate not-yet.
    if (message.contains('-1719') || message.contains('Can’t get')) return 0;
    stderr
      ..writeln('FAIL: cannot query windows via System Events: $message')
      ..writeln(
        'Grant accessibility access to the test runner, or restart '
        'System Events, and re-run. This is a harness failure, not an app '
        'failure.',
      );
    exit(1);
  }
  return int.tryParse(result.stdout.toString().trim()) ?? 0;
}

Future<void> _quitApp(int pid) async {
  Process.killPid(pid);
  await Future<void>.delayed(const Duration(seconds: 2));
  Process.killPid(pid, ProcessSignal.sigkill);
}
