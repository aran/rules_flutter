/// Runtime verification: installs APK on Android emulator, launches the
/// activity, and verifies it reaches RESUMED state without crashing.
///
/// This test requires a running Android emulator and is tagged "manual"
/// to skip during normal `bazel test //...` runs.
/// Run explicitly: `bazel test :verify_android_app_test --test_tag_filters=`
///
/// Pass criteria:
/// - APK installs successfully via adb
/// - Activity starts and reaches RESUMED state within 30s
/// - Activity stays resumed with no crash for 10s — long enough to cover
///   androidx.profileinstaller's startup-initializer write, which runs a few
///   seconds after launch and exercises the profileinstaller dependency
///   chain (concurrent-futures, listenablefuture) at runtime
import 'dart:io';

const _packageName = 'com.example.flutterapp';
const _timeout = Duration(seconds: 30);
const _stabilityWindow = Duration(seconds: 10);

Future<void> main() async {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final apkPath = '$testSrcDir/$testWorkspace/app.apk';
  if (!File(apkPath).existsSync()) {
    stderr.writeln('APK not found at $apkPath');
    exit(1);
  }

  // Check adb is available.
  final adbCheck = Process.runSync('which', ['adb']);
  if (adbCheck.exitCode != 0) {
    stderr.writeln('adb not found in PATH');
    exit(1);
  }

  // Check for connected devices/emulators.
  final devices = Process.runSync('adb', ['devices']);
  final deviceLines = devices.stdout
      .toString()
      .trim()
      .split('\n')
      .where((l) => l.contains('\tdevice'))
      .toList();
  if (deviceLines.isEmpty) {
    stderr.writeln('No Android devices/emulators connected');
    exit(1);
  }
  print('Found ${deviceLines.length} device(s)');

  // Install the APK.
  print('Installing APK...');
  final install = Process.runSync('adb', ['install', '-r', apkPath]);
  if (install.exitCode != 0) {
    stderr.writeln('Failed to install APK: ${install.stderr}');
    exit(1);
  }
  print('APK installed successfully');

  // Clear the crash log buffer so the stability check only sees crashes
  // from this run.
  Process.runSync('adb', ['logcat', '-b', 'crash', '-c']);

  // Resolve the installed package's launcher activity, then launch it.
  final resolve = Process.runSync('adb', [
    'shell',
    'cmd',
    'package',
    'resolve-activity',
    '--brief',
    '-a',
    'android.intent.action.MAIN',
    '-c',
    'android.intent.category.LAUNCHER',
    _packageName,
  ]);
  final component = resolve.stdout
      .toString()
      .trim()
      .split('\n')
      .where((l) => l.startsWith('$_packageName/'))
      .toList();
  if (resolve.exitCode != 0 || component.isEmpty) {
    stderr.writeln('Failed to resolve launcher activity for $_packageName: '
        '${resolve.stdout}${resolve.stderr}');
    exit(1);
  }

  print('Starting activity ${component.single} ...');
  final start = Process.runSync('adb', [
    'shell',
    'am',
    'start',
    '-n',
    component.single,
  ]);
  final startOutput = '${start.stdout}${start.stderr}';
  if (start.exitCode != 0 || startOutput.contains('Error')) {
    stderr.writeln('Failed to start activity: $startOutput');
    exit(1);
  }

  // Wait for activity to reach RESUMED state.
  print('Waiting for RESUMED state (up to ${_timeout.inSeconds}s)...');
  final deadline = DateTime.now().add(_timeout);
  var resumed = false;
  while (DateTime.now().isBefore(deadline)) {
    final dumpsys = Process.runSync(
        'adb', ['shell', 'dumpsys', 'activity', 'activities']);
    final output = dumpsys.stdout.toString();
    // Matches both `mResumedActivity`/`ResumedActivity:` (older releases)
    // and `topResumedActivity=` (API 29+).
    if (output.split('\n').any((l) =>
        l.contains('ResumedActivity') && l.contains(_packageName))) {
      resumed = true;
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  if (!resumed) {
    stderr.writeln('FAIL: Activity did not reach RESUMED state');
    _cleanup();
    exit(1);
  }
  print('Activity is RESUMED');

  // Verify the app stays resumed with no crash for the full stability
  // window, polling so a crash fails fast with its log attached.
  print('Verifying stability (${_stabilityWindow.inSeconds}s)...');
  final stabilityDeadline = DateTime.now().add(_stabilityWindow);
  var stillResumed = true;
  while (DateTime.now().isBefore(stabilityDeadline)) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final crashLog =
        Process.runSync('adb', ['logcat', '-b', 'crash', '-d']).stdout.toString();
    if (crashLog.contains(_packageName)) {
      stderr.writeln('FAIL: app crashed during stability window:\n$crashLog');
      _cleanup();
      exit(1);
    }
    final dumpsys = Process.runSync(
        'adb', ['shell', 'dumpsys', 'activity', 'activities']);
    stillResumed = dumpsys.stdout.toString().split('\n').any((l) =>
        l.contains('ResumedActivity') && l.contains(_packageName));
    if (!stillResumed) break;
  }

  // Capture a screenshot for visual verification.
  print('Capturing screenshot...');
  Process.runSync(
      'adb', ['shell', 'screencap', '-p', '/sdcard/flutter_test.png']);
  final screenshotDir = Directory.systemTemp.createTempSync('android_screenshot');
  final localScreenshot = '${screenshotDir.path}/screenshot.png';
  Process.runSync('adb', ['pull', '/sdcard/flutter_test.png', localScreenshot]);
  Process.runSync('adb', ['shell', 'rm', '/sdcard/flutter_test.png']);
  if (File(localScreenshot).existsSync()) {
    print('Screenshot saved to $localScreenshot');
  }

  // Clean up.
  _cleanup();

  // Report results.
  print('');
  print('=== Results ===');
  print('Activity resumed: yes');
  print('Still resumed after ${_stabilityWindow.inSeconds}s: $stillResumed');

  if (!stillResumed) {
    stderr.writeln('FAIL: Activity crashed or was stopped');
    exit(1);
  }

  print('PASS');
}

void _cleanup() {
  // Force stop the app.
  Process.runSync('adb', ['shell', 'am', 'force-stop', _packageName]);
}
