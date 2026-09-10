/// Verifies a Flutter Linux bundle launches and creates a GTK window.
///
/// Usage: dart run verify_linux_app.dart <path/to/bundle_dir> <expected_title>
///
/// Requires: Xvfb, xdotool, scrot (apt install xvfb xdotool scrot)
///
/// Verification:
/// 1. Starts Xvfb if no DISPLAY is set
/// 2. Launches the runner executable
/// 3. Polls for a window *whose title matches* `expected_title` (up to 30s)
/// 4. Verifies that window has non-zero size
/// 5. Polls screenshots until one is no longer a uniform blank frame
/// 6. Kills the app
///
/// Pass criteria: the app's own window appears with non-zero dimensions and
/// paints something.
///
/// The title match is load-bearing, not cosmetic. `xdotool search --name ''`
/// also matches the Xvfb *root* window, which exists from the moment the
/// display starts, so selecting the first result reports success even when the
/// runner never came up and screenshots the empty root.
library;

import 'dart:convert';
import 'dart:io';

Process? _xvfbProcess;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'Usage: dart run verify_linux_app.dart <bundle_dir> <expected_title>',
    );
    exit(1);
  }

  final bundlePath = args[0];
  final expectedTitle = args[1];

  if (!Directory(bundlePath).existsSync()) {
    stderr.writeln('Bundle directory not found: $bundlePath');
    exit(1);
  }

  final appName = Uri.parse(bundlePath).pathSegments.last;
  final binaryPath = '$bundlePath/$appName';

  if (!File(binaryPath).existsSync()) {
    stderr.writeln('Runner binary not found: $binaryPath');
    exit(1);
  }

  // Ensure we have a display (start Xvfb if needed).
  final display = await _ensureDisplay();
  final env = Map<String, String>.from(Platform.environment);
  env['DISPLAY'] = display;
  // Software rendering, for hosts with no GPU (e.g. GCP VMs).
  //
  // Both variables are needed. `LIBGL_ALWAYS_SOFTWARE` steers GLX; Flutter's
  // GTK embedder renders through **EGL**, which ignores it and tries DRI3 —
  // failing on Xvfb with "DRI3 error: Could not get DRI3 device" and then
  // painting nothing at all, while still creating a window. `GALLIUM_DRIVER`
  // is what points EGL at llvmpipe.
  env['LIBGL_ALWAYS_SOFTWARE'] = '1';
  env['GALLIUM_DRIVER'] = 'llvmpipe';

  print('Using DISPLAY=$display');

  // Baseline: what an empty display compresses to. Everything after launch is
  // compared against this rather than against a magic byte count.
  final blankDisplaySize = await _takeScreenshot(
    '${Directory.systemTemp.path}/blank_display.png',
    env,
  );
  print('Blank display capture: $blankDisplaySize bytes');

  // Make the runner executable.
  await Process.run('chmod', ['+x', binaryPath]);

  // Launch the app.
  print('Launching $appName from $bundlePath ...');
  final appProcess = await Process.start(
    binaryPath,
    [],
    workingDirectory: bundlePath,
    environment: env,
  );

  final stdoutLines = <String>[];
  final stderrLines = <String>[];
  appProcess.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        stdoutLines.add(line);
        print('[stdout] $line');
      });
  appProcess.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        stderrLines.add(line);
        print('[stderr] $line');
      });

  // Poll for the app's own window via xdotool.
  print('Waiting for a window titled "$expectedTitle" (up to 30s) ...');
  final windowId = await _pollForWindow(
    const Duration(seconds: 30),
    env,
    expectedTitle,
  );

  if (windowId == null) {
    stderr.writeln(
      'FAIL: no window titled "$expectedTitle" after 30s. '
      'The runner may have failed to start — check [stderr] above.',
    );
    appProcess.kill();
    _cleanup();
    _printResult(
      windowAppeared: false,
      windowSize: null,
      titleMatch: null,
      screenshotPath: null,
      passed: false,
    );
    exit(1);
  }
  print('Window found: $windowId');

  // Get window geometry.
  final geometry = await _getWindowGeometry(windowId, env);
  print('Window geometry: $geometry');

  // xdotool --shell format: WINDOW=...\nX=...\nY=...\nWIDTH=...\nHEIGHT=...
  final widthMatch = RegExp(r'WIDTH=(\d+)').firstMatch(geometry);
  final heightMatch = RegExp(r'HEIGHT=(\d+)').firstMatch(geometry);
  final width = int.tryParse(widthMatch?.group(1) ?? '') ?? 0;
  final height = int.tryParse(heightMatch?.group(1) ?? '') ?? 0;
  final hasNonZeroSize = width > 100 && height > 100;

  // Check window title.
  final windowTitle = await _getWindowTitle(windowId, env);
  print('Window title: $windowTitle');
  final titleMatch =
      windowTitle != null &&
      windowTitle.toLowerCase().contains(expectedTitle.toLowerCase());

  // Wait for the app to paint. Under llvmpipe the first frame lands seconds
  // after the window is mapped, so a fixed delay is a coin flip; poll instead
  // until the capture is materially bigger than the blank display measured
  // before launch. A uniform frame compresses to a fraction of a painted one.
  final screenshotPath =
      '${Directory.systemTemp.path}/${appName}_screenshot.png';
  print('Waiting for the first painted frame (up to 60s) ...');
  final screenshotSize = await _pollForPaintedFrame(
    const Duration(seconds: 60),
    screenshotPath,
    blankDisplaySize,
    env,
  );
  final painted = screenshotSize > blankDisplaySize * 3 ~/ 2;
  if (screenshotSize > 0) {
    print(
      'Screenshot: $screenshotPath ($screenshotSize bytes, '
      'blank display was $blankDisplaySize bytes)',
    );
  } else {
    print('Screenshot: unavailable (scrot may not be installed)');
  }
  if (!painted) {
    print(
      'Screenshot is indistinguishable from the blank display — the app '
      'window exists but nothing was drawn into it.',
    );
  }

  // Kill the app.
  appProcess.kill();
  await appProcess.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      appProcess.kill(ProcessSignal.sigkill);
      return -1;
    },
  );

  _cleanup();

  // Report results.
  final passed = hasNonZeroSize && titleMatch && painted;
  print('');
  print('=== Results ===');
  print('Window appeared: yes');
  print(
    'Window size: ${width}x$height (${hasNonZeroSize ? "OK" : "TOO SMALL - FAIL"})',
  );
  print('Window title contains "$expectedTitle": ${titleMatch ? "yes" : "no"}');
  print('Painted a frame: ${painted ? "yes" : "no"}');
  if (screenshotSize > 0) {
    print('Screenshot: $screenshotPath ($screenshotSize bytes)');
  }

  _printResult(
    windowAppeared: true,
    windowSize: '${width}x$height',
    titleMatch: titleMatch,
    screenshotPath: screenshotSize > 0 ? screenshotPath : null,
    passed: passed,
  );

  print('');
  print(passed ? 'PASS' : 'FAIL');
  exit(passed ? 0 : 1);
}

Future<String> _ensureDisplay() async {
  final display = Platform.environment['DISPLAY'];
  if (display != null && display.isNotEmpty) {
    return display;
  }

  // Kill any existing Xvfb on :99 and start fresh.
  const xvfbDisplay = ':99';
  print('No DISPLAY set, starting Xvfb on $xvfbDisplay ...');
  await Process.run('pkill', ['-f', 'Xvfb $xvfbDisplay']);
  await Process.run('rm', ['-f', '/tmp/.X99-lock']);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  _xvfbProcess = await Process.start(
    'Xvfb',
    [xvfbDisplay, '-screen', '0', '1280x720x24'],
  );
  // Give Xvfb time to start.
  await Future<void>.delayed(const Duration(seconds: 1));
  return xvfbDisplay;
}

void _cleanup() {
  if (_xvfbProcess != null) {
    _xvfbProcess!.kill();
    _xvfbProcess = null;
  }
}

Future<String?> _pollForWindow(
  Duration timeout,
  Map<String, String> env,
  String expectedTitle,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final result = await Process.run(
      'xdotool',
      ['search', '--onlyvisible', '--name', expectedTitle],
      environment: env,
    );
    if (result.exitCode == 0) {
      final ids = result.stdout.toString().trim().split('\n');
      for (final id in ids) {
        if (id.trim().isNotEmpty) return id.trim();
      }
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return null;
}

Future<String> _getWindowGeometry(
  String windowId,
  Map<String, String> env,
) async {
  final result = await Process.run(
    'xdotool',
    ['getwindowgeometry', '--shell', windowId],
    environment: env,
  );
  return result.stdout.toString().trim();
}

Future<String?> _getWindowTitle(
  String windowId,
  Map<String, String> env,
) async {
  final result = await Process.run(
    'xdotool',
    ['getwindowname', windowId],
    environment: env,
  );
  if (result.exitCode != 0) return null;
  return result.stdout.toString().trim();
}

/// Captures until the frame is materially bigger than the blank baseline.
///
/// Returns the last capture's size, so the caller can report what it saw even
/// when nothing was ever drawn.
Future<int> _pollForPaintedFrame(
  Duration timeout,
  String outputPath,
  int blankDisplaySize,
  Map<String, String> env,
) async {
  final deadline = DateTime.now().add(timeout);
  var size = 0;
  while (DateTime.now().isBefore(deadline)) {
    size = await _takeScreenshot(outputPath, env);
    if (size > blankDisplaySize * 3 ~/ 2) return size;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return size;
}

Future<int> _takeScreenshot(String outputPath, Map<String, String> env) async {
  // `--overwrite`: without it scrot refuses to replace an existing capture,
  // which silently freezes the polled frame at whatever was there first.
  final result = await Process.run(
    'scrot',
    ['--overwrite', outputPath],
    environment: env,
  );
  final file = File(outputPath);
  if (result.exitCode == 0 && file.existsSync()) {
    return file.lengthSync();
  }
  stderr.writeln(
    'scrot failed (exit ${result.exitCode}): '
    '${result.stderr.toString().trim()}',
  );
  return 0;
}

void _printResult({
  required bool windowAppeared,
  required String? windowSize,
  required bool? titleMatch,
  required String? screenshotPath,
  required bool passed,
}) {
  final result = {
    'window_appeared': windowAppeared,
    'window_size': windowSize,
    'title_match': titleMatch,
    'screenshot_path': screenshotPath,
    'passed': passed,
  };
  print('');
  print('--- JSON ---');
  print(jsonEncode(result));
  print('--- END JSON ---');
}
