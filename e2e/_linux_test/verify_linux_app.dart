/// Verifies a Flutter Linux bundle launches and creates a GTK window.
///
/// Usage: dart run verify_linux_app.dart <path/to/bundle_dir> [expected_title]
///
/// Requires: Xvfb, xdotool, scrot (apt install xvfb xdotool scrot)
///
/// Verification:
/// 1. Starts Xvfb if no DISPLAY is set
/// 2. Launches the runner executable
/// 3. Polls for window existence via xdotool (up to 30s)
/// 4. Verifies window has non-zero size
/// 5. Checks window title matches expected title (if provided)
/// 6. Attempts screenshot via scrot (best-effort)
/// 7. Kills the app
///
/// Pass criteria: window appears with non-zero dimensions.
library;

import 'dart:convert';
import 'dart:io';

Process? _xvfbProcess;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
        'Usage: dart run verify_linux_app.dart <bundle_dir> [expected_title]');
    exit(1);
  }

  final bundlePath = args[0];
  final expectedTitle = args.length > 1 ? args[1] : null;

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
  // Use software rendering when no GPU is available (e.g. GCP VMs).
  env['LIBGL_ALWAYS_SOFTWARE'] = '1';

  print('Using DISPLAY=$display');

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

  // Poll for window to appear via xdotool.
  print('Waiting for window (up to 30s) ...');
  final windowId = await _pollForWindow(
    const Duration(seconds: 30),
    env,
  );

  if (windowId == null) {
    stderr.writeln('FAIL: No window found after 30s');
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

  // Give Flutter time to render the first frame (software rendering on VMs
  // can be slow).
  await Future<void>.delayed(const Duration(seconds: 10));

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
  String? windowTitle;
  bool? titleMatch;
  if (expectedTitle != null) {
    windowTitle = await _getWindowTitle(windowId, env);
    print('Window title: $windowTitle');
    titleMatch = windowTitle != null &&
        windowTitle.toLowerCase().contains(expectedTitle.toLowerCase());
  }

  // Best-effort screenshot.
  final screenshotPath =
      '${Directory.systemTemp.path}/${appName}_screenshot.png';
  final screenshotSize = await _takeScreenshot(screenshotPath, env);
  if (screenshotSize > 0) {
    print('Screenshot: $screenshotPath ($screenshotSize bytes)');
  } else {
    print('Screenshot: unavailable (scrot may not be installed)');
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
  print('');
  print('=== Results ===');
  print('Window appeared: yes');
  print(
      'Window size: ${width}x$height (${hasNonZeroSize ? "OK" : "TOO SMALL - FAIL"})');
  if (expectedTitle != null) {
    print(
        'Window title contains "$expectedTitle": ${titleMatch == true ? "yes" : "no"}');
  }
  if (screenshotSize > 0) {
    print('Screenshot: $screenshotPath ($screenshotSize bytes)');
  }

  _printResult(
    windowAppeared: true,
    windowSize: '${width}x$height',
    titleMatch: titleMatch,
    screenshotPath: screenshotSize > 0 ? screenshotPath : null,
    passed: hasNonZeroSize,
  );

  print('');
  print(hasNonZeroSize ? 'PASS' : 'FAIL');
  exit(hasNonZeroSize ? 0 : 1);
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

Future<String?> _pollForWindow(Duration timeout, Map<String, String> env) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final result = await Process.run(
      'xdotool',
      ['search', '--onlyvisible', '--name', ''],
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

Future<String> _getWindowGeometry(String windowId, Map<String, String> env) async {
  final result = await Process.run(
    'xdotool',
    ['getwindowgeometry', '--shell', windowId],
    environment: env,
  );
  return result.stdout.toString().trim();
}

Future<String?> _getWindowTitle(String windowId, Map<String, String> env) async {
  final result = await Process.run(
    'xdotool',
    ['getwindowname', windowId],
    environment: env,
  );
  if (result.exitCode != 0) return null;
  return result.stdout.toString().trim();
}

Future<int> _takeScreenshot(String outputPath, Map<String, String> env) async {
  final result = await Process.run(
    'scrot',
    [outputPath],
    environment: env,
  );
  final file = File(outputPath);
  if (result.exitCode == 0 && file.existsSync()) {
    return file.lengthSync();
  }
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
