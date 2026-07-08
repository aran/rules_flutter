/// Runtime verification: installs the plugin_example APK on an Android
/// emulator/device, launches the activity, and asserts that the app reaches
/// RESUMED state, stays alive, and that the plugins actually resolved —
/// the `plugin_example_results` log line must report a real Android
/// documents path from path_provider (which is jnigen-based as of
/// path_provider_android 2.3 and exercises package:jni's libdartjni.so and
/// Java support classes end to end).
///
/// This test requires a running Android emulator and is tagged "manual"
/// to skip during normal `bazel test //...` runs.
/// Run explicitly: `bazel test :verify_android_app_test --test_tag_filters=`
import 'dart:io';

const _packageName = 'com.example.plugin_example';
const _timeout = Duration(seconds: 30);
const _resultsTimeout = Duration(seconds: 60);
const _stabilityWindow = Duration(seconds: 10);

Future<void> main() async {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final apkPath = '$testSrcDir/$testWorkspace/plugin_android.apk';
  if (!File(apkPath).existsSync()) {
    stderr.writeln('APK not found at $apkPath');
    exit(1);
  }

  final adbCheck = Process.runSync('which', ['adb']);
  if (adbCheck.exitCode != 0) {
    stderr.writeln('adb not found in PATH');
    exit(1);
  }

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

  print('Installing APK...');
  final install = Process.runSync('adb', ['install', '-r', apkPath]);
  if (install.exitCode != 0) {
    stderr.writeln('Failed to install APK: ${install.stderr}');
    exit(1);
  }
  print('APK installed successfully');

  // record_android's library manifest declares RECORD_AUDIO; `pm grant`
  // rejects permissions an app does not declare, so a successful grant
  // proves the plugin's manifest merged into the APK. Granting up front
  // also makes the app's hasPermission probe deterministic (has=true).
  print('Granting RECORD_AUDIO (proves record_android manifest merge)...');
  final grant = Process.runSync('adb', [
    'shell',
    'pm',
    'grant',
    _packageName,
    'android.permission.RECORD_AUDIO',
  ]);
  final grantOutput = '${grant.stdout}${grant.stderr}'.trim();
  if (grant.exitCode != 0 || grantOutput.isNotEmpty) {
    stderr.writeln('FAIL: pm grant RECORD_AUDIO failed — record_android\'s '
        'manifest did not merge into the APK: $grantOutput');
    exit(1);
  }
  print('RECORD_AUDIO granted');

  // Clear log buffers so crash and results checks only see this run.
  Process.runSync('adb', ['logcat', '-b', 'crash', '-c']);
  Process.runSync('adb', ['logcat', '-c']);

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

  // Wait for activity to reach RESUMED state, failing fast on a crash.
  print('Waiting for RESUMED state (up to ${_timeout.inSeconds}s)...');
  final deadline = DateTime.now().add(_timeout);
  var resumed = false;
  while (DateTime.now().isBefore(deadline)) {
    if (_failOnCrash()) {
      _cleanup();
      exit(1);
    }
    final dumpsys = Process.runSync(
        'adb', ['shell', 'dumpsys', 'activity', 'activities']);
    final output = dumpsys.stdout.toString();
    // Matches both `mResumedActivity`/`ResumedActivity:` (older releases)
    // and `topResumedActivity=` (API 29+).
    if (output
        .split('\n')
        .any((l) => l.contains('ResumedActivity') && l.contains(_packageName))) {
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

  // Wait for the app's single-line plugin results summary in logcat. This is
  // the dispositive plugin check: it only appears after every plugin call in
  // lib/main.dart resolved. UnsatisfiedLinkError on libdartjni.so aborts
  // plugin registration before any of them can respond.
  print('Waiting for plugin_example_results (up to '
      '${_resultsTimeout.inSeconds}s)...');
  String? resultsLine;
  final resultsDeadline = DateTime.now().add(_resultsTimeout);
  while (DateTime.now().isBefore(resultsDeadline)) {
    if (_failOnCrash()) {
      _cleanup();
      exit(1);
    }
    final log = Process.runSync('adb', ['logcat', '-d']).stdout.toString();
    final match = log
        .split('\n')
        .where((l) => l.contains('plugin_example_results'))
        .toList();
    if (match.isNotEmpty) {
      resultsLine = match.last;
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }

  if (resultsLine == null) {
    stderr.writeln('FAIL: plugin_example_results line never appeared in '
        'logcat — plugins did not resolve');
    _dumpRegistrationErrors();
    _cleanup();
    exit(1);
  }
  print('Results: $resultsLine');

  var resultsOk = true;
  void expectResult(String description, bool condition) {
    if (condition) {
      print('OK: $description');
    } else {
      stderr.writeln('FAIL: $description — got: $resultsLine');
      resultsOk = false;
    }
  }

  // path_provider (jnigen: package:jni + libdartjni.so end to end).
  expectResult('documentsPath is a real Android app-data path',
      resultsLine.contains('documentsPath=/data/user/0/$_packageName/'));
  expectResult('tempPath is a real Android cache path',
      resultsLine.contains('tempPath=/data/user/0/$_packageName/cache'));
  // package_info_plus and the hand-written greeting plugin registered too.
  expectResult('greeting resolved',
      resultsLine.contains('greeting=Hello from GreetingPlugin!'));
  expectResult(
      'appName resolved', resultsLine.contains('appName=plugin_example'));
  // url_launcher registered and its MethodChannel responded. `denied` is
  // the correct Android answer here: canLaunchUrl is subject to package
  // visibility, and the app declares no <queries> for https VIEW intents
  // (flutter create output, which plugin_example ships untouched, doesn't
  // include one).
  expectResult('url_launcher channel responded (package visibility denies)',
      resultsLine.contains('launchOk=launch denied'));
  expectResult('audio_session resolved',
      resultsLine.contains('audioSession=audio ok'));
  // record_android registered, its resources compiled, and its
  // MethodChannel responded with the permission granted above.
  expectResult('record_android channel responded with granted permission',
      resultsLine.contains('recordHasPermission=has=true'));
  expectResult('no plugin returned an error', !resultsLine.contains('error:'));

  if (!resultsOk) {
    _cleanup();
    exit(1);
  }

  // Verify the app stays resumed with no crash for the full stability
  // window, polling so a crash fails fast with its log attached.
  print('Verifying stability (${_stabilityWindow.inSeconds}s)...');
  final stabilityDeadline = DateTime.now().add(_stabilityWindow);
  var stillResumed = true;
  while (DateTime.now().isBefore(stabilityDeadline)) {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (_failOnCrash()) {
      _cleanup();
      exit(1);
    }
    final dumpsys = Process.runSync(
        'adb', ['shell', 'dumpsys', 'activity', 'activities']);
    stillResumed = dumpsys.stdout
        .toString()
        .split('\n')
        .any((l) => l.contains('ResumedActivity') && l.contains(_packageName));
    if (!stillResumed) break;
  }

  // Capture a screenshot for visual verification.
  print('Capturing screenshot...');
  Process.runSync(
      'adb', ['shell', 'screencap', '-p', '/sdcard/plugin_test.png']);
  final screenshotDir =
      Directory.systemTemp.createTempSync('plugin_android_screenshot');
  final localScreenshot = '${screenshotDir.path}/screenshot.png';
  Process.runSync('adb', ['pull', '/sdcard/plugin_test.png', localScreenshot]);
  Process.runSync('adb', ['shell', 'rm', '/sdcard/plugin_test.png']);
  if (File(localScreenshot).existsSync()) {
    print('Screenshot saved to $localScreenshot');
  }

  _cleanup();

  print('');
  print('=== Results ===');
  print('Activity resumed: yes');
  print('Plugin results verified: yes');
  print('Still resumed after ${_stabilityWindow.inSeconds}s: $stillResumed');

  if (!stillResumed) {
    stderr.writeln('FAIL: Activity crashed or was stopped');
    exit(1);
  }

  print('PASS');
}

/// Returns true (after printing the log) if the crash buffer contains an
/// entry for the app.
bool _failOnCrash() {
  final crashLog =
      Process.runSync('adb', ['logcat', '-b', 'crash', '-d']).stdout.toString();
  if (crashLog.contains(_packageName)) {
    stderr.writeln('FAIL: app crashed:\n$crashLog');
    return true;
  }
  return false;
}

/// Dumps plugin-registration failures (e.g. UnsatisfiedLinkError from a
/// missing native library) to aid diagnosis when the results line is absent.
void _dumpRegistrationErrors() {
  final log = Process.runSync('adb', ['logcat', '-d']).stdout.toString();
  final interesting = log
      .split('\n')
      .where((l) =>
          l.contains('GeneratedPluginsRegister') ||
          l.contains('UnsatisfiedLinkError') ||
          l.contains('flutter'))
      .take(200)
      .join('\n');
  stderr.writeln('--- relevant logcat ---\n$interesting');
}

void _cleanup() {
  Process.runSync('adb', ['shell', 'am', 'force-stop', _packageName]);
}
