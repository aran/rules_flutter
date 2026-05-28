/// Verifies a Flutter Windows bundle launches and creates a window.
///
/// Usage: dart run verify_windows_app.dart <path/to/bundle_dir> [expected_title]
///
/// Must be run on a Windows machine (native or VM with RDP).
///
/// Verification:
/// 1. Launches the .exe from the bundle directory
/// 2. Polls for window existence via PowerShell (up to 30s)
/// 3. Verifies window has non-zero size
/// 4. Checks window title matches expected title (if provided)
/// 5. Kills the app
///
/// Pass criteria: window appears with non-zero dimensions.
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
        'Usage: dart run verify_windows_app.dart <bundle_dir> [expected_title]');
    exit(1);
  }

  final bundlePath = args[0];
  final expectedTitle = args.length > 1 ? args[1] : null;

  if (!Directory(bundlePath).existsSync()) {
    stderr.writeln('Bundle directory not found: $bundlePath');
    exit(1);
  }

  final appName = Uri.parse(bundlePath).pathSegments.last;
  final exePath = '$bundlePath\\$appName.exe';

  if (!File(exePath).existsSync()) {
    stderr.writeln('Runner exe not found: $exePath');
    exit(1);
  }

  // Launch the app.
  print('Launching $appName from $bundlePath ...');
  final appProcess = await Process.start(
    exePath,
    [],
    workingDirectory: bundlePath,
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

  // Poll for window to appear.
  print('Waiting for window (up to 30s) ...');
  final windowInfo = await _pollForWindow(
    const Duration(seconds: 30),
    appProcess.pid,
  );

  if (windowInfo == null) {
    stderr.writeln('FAIL: No window found after 30s');
    appProcess.kill();
    _printResult(
      windowAppeared: false,
      windowSize: null,
      titleMatch: null,
      passed: false,
    );
    exit(1);
  }
  print('Window found: ${windowInfo['title']}');

  // Give Flutter time to render.
  await Future<void>.delayed(const Duration(seconds: 3));

  // Re-query for size after rendering.
  final sizeInfo = await _getWindowSize(appProcess.pid);
  final width = sizeInfo?['width'] ?? 0;
  final height = sizeInfo?['height'] ?? 0;
  final hasNonZeroSize = width > 100 && height > 100;
  print('Window size: ${width}x$height');

  // Check window title.
  bool? titleMatch;
  final windowTitle = windowInfo['title'] as String?;
  if (expectedTitle != null && windowTitle != null) {
    titleMatch =
        windowTitle.toLowerCase().contains(expectedTitle.toLowerCase());
  }

  // Kill the app.
  appProcess.kill();
  await appProcess.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      // Force kill via taskkill.
      Process.runSync('taskkill', ['/F', '/PID', '${appProcess.pid}']);
      return -1;
    },
  );

  // Report results.
  print('');
  print('=== Results ===');
  print('Window appeared: yes');
  print('Window title: $windowTitle');
  print(
      'Window size: ${width}x$height (${hasNonZeroSize ? "OK" : "TOO SMALL - FAIL"})');
  if (expectedTitle != null) {
    print(
        'Window title contains "$expectedTitle": ${titleMatch == true ? "yes" : "no"}');
  }

  _printResult(
    windowAppeared: true,
    windowSize: '${width}x$height',
    titleMatch: titleMatch,
    passed: hasNonZeroSize,
  );

  print('');
  print(hasNonZeroSize ? 'PASS' : 'FAIL');
  exit(hasNonZeroSize ? 0 : 1);
}

/// Polls for a visible window owned by the given process.
Future<Map<String, dynamic>?> _pollForWindow(
    Duration timeout, int pid) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      '''
        Get-Process -Id $pid -ErrorAction SilentlyContinue |
          Where-Object { \$_.MainWindowHandle -ne 0 } |
          Select-Object -First 1 |
          ForEach-Object {
            Write-Output ("{0}|{1}" -f \$_.MainWindowTitle, \$_.MainWindowHandle)
          }
      ''',
    ]);
    final output = result.stdout.toString().trim();
    if (output.isNotEmpty && output.contains('|')) {
      final parts = output.split('|');
      return {
        'title': parts[0],
        'handle': parts[1],
      };
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return null;
}

/// Gets window dimensions for a process.
Future<Map<String, int>?> _getWindowSize(int pid) async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    '''
      Add-Type @"
        using System;
        using System.Runtime.InteropServices;
        public class Win32 {
          [DllImport("user32.dll")]
          public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
          [StructLayout(LayoutKind.Sequential)]
          public struct RECT {
            public int Left, Top, Right, Bottom;
          }
        }
"@
      \$proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
      if (\$proc -and \$proc.MainWindowHandle -ne 0) {
        \$rect = New-Object Win32+RECT
        [Win32]::GetWindowRect(\$proc.MainWindowHandle, [ref]\$rect) | Out-Null
        Write-Output ("{0}|{1}" -f (\$rect.Right - \$rect.Left), (\$rect.Bottom - \$rect.Top))
      }
    ''',
  ]);
  final output = result.stdout.toString().trim();
  if (output.isNotEmpty && output.contains('|')) {
    final parts = output.split('|');
    return {
      'width': int.tryParse(parts[0]) ?? 0,
      'height': int.tryParse(parts[1]) ?? 0,
    };
  }
  return null;
}

void _printResult({
  required bool windowAppeared,
  required String? windowSize,
  required bool? titleMatch,
  required bool passed,
}) {
  final result = {
    'window_appeared': windowAppeared,
    'window_size': windowSize,
    'title_match': titleMatch,
    'passed': passed,
  };
  print('');
  print('--- JSON ---');
  print(jsonEncode(result));
  print('--- END JSON ---');
}
