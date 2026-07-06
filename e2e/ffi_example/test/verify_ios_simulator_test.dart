/// Runtime verification on an iOS simulator: installs the app, launches it,
/// and asserts both native-library mechanisms actually worked at runtime.
/// This is a *behavioral* check covering:
///
///  * Native Assets: `add()` binds via `@Native` — the pass depends on the
///    kernel-embedded --native-assets mapping resolving the asset id to the
///    embedded, signed `add.framework/add`.
///  * native_deps: `mul()` raw-opens the conventional framework partial path
///    `mul.framework/mul`, proving the loose-library pipeline bundles where
///    the loader expects.
///
/// Tagged "manual" (like the Android runtime test) because it needs a usable
/// iOS simulator. Run explicitly:
///   bazel test :verify_ios_simulator_test --test_tag_filters=
///
/// Pass criteria: after launch the app writes
/// `ffi_example_result add(3,4)=7 mul(3,4)=12` to `tmp/ffi_result.txt` in its
/// sandbox — written in main() only if both calls succeeded via the bundled
/// native libraries. The test reads the file back through
/// `simctl get_app_container` (a deterministic signal that doesn't depend on
/// scraping iOS log output).
import 'dart:convert';
import 'dart:io';

const _bundleId = 'com.example.ffi';
const _marker = 'ffi_example_result add(3,4)=7 mul(3,4)=12';
const _resultFile = 'tmp/ffi_result.txt';
const _timeout = Duration(seconds: 60);

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final ipaPath = '$testSrcDir/$testWorkspace/ffi_ios.ipa';
  if (!File(ipaPath).existsSync()) {
    stderr.writeln('iOS app not found at $ipaPath');
    exit(1);
  }

  if (Process.runSync('xcrun', ['--find', 'simctl']).exitCode != 0) {
    stderr.writeln('xcrun simctl not available');
    exit(1);
  }

  // Extract Payload/<app>.app from the .ipa.
  final tmp = Directory.systemTemp.createTempSync('ffi_ios_sim');
  final unzip = Process.runSync('unzip', ['-q', ipaPath, '-d', tmp.path]);
  if (unzip.exitCode != 0) {
    stderr.writeln('Failed to unzip ipa: ${unzip.stderr}');
    exit(1);
  }
  final payload = Directory('${tmp.path}/Payload');
  final appDir = payload
      .listSync()
      .whereType<Directory>()
      .firstWhere((d) => d.path.endsWith('.app'));
  print('App: ${appDir.path}');

  final udid = _ensureBootedSimulator();
  print('Simulator: $udid');

  // Uninstall first so a stale result file from a previous run can't be read.
  Process.runSync('xcrun', ['simctl', 'uninstall', udid, _bundleId]);

  print('Installing app...');
  final install =
      Process.runSync('xcrun', ['simctl', 'install', udid, appDir.path]);
  if (install.exitCode != 0) {
    stderr.writeln('Install failed: ${install.stderr}');
    exit(1);
  }

  print('Launching $_bundleId ...');
  final launch = Process.runSync(
    'xcrun',
    ['simctl', 'launch', '--terminate-running-process', udid, _bundleId],
  );
  if (launch.exitCode != 0) {
    stderr.writeln('Launch failed: ${launch.stderr}');
    exit(1);
  }

  // Poll the app sandbox for the result file the app writes in main().
  print('Waiting up to ${_timeout.inSeconds}s for $_resultFile ...');
  final deadline = DateTime.now().add(_timeout);
  String? contents;
  while (DateTime.now().isBefore(deadline)) {
    final container = Process.runSync(
        'xcrun', ['simctl', 'get_app_container', udid, _bundleId, 'data']);
    if (container.exitCode == 0) {
      final path = '${container.stdout.toString().trim()}/$_resultFile';
      final f = File(path);
      if (f.existsSync()) {
        contents = f.readAsStringSync().trim();
        break;
      }
    }
    sleep(const Duration(seconds: 1));
  }

  Process.runSync('xcrun', ['simctl', 'terminate', udid, _bundleId]);

  if (contents == null) {
    stderr.writeln('FAIL: app never wrote $_resultFile — it likely crashed '
        'before main() completed (native library failed to load?).');
    exit(1);
  }
  print('App recorded: "$contents"');
  if (contents != _marker) {
    stderr.writeln('FAIL: expected "$_marker" but got "$contents".');
    exit(1);
  }
  print('PASS: @Native asset bind (add) and raw framework open (mul) '
      'both worked at runtime.');
}

/// Returns the UDID of a booted simulator, booting an available iPhone if none
/// is currently booted.
String _ensureBootedSimulator() {
  final booted = _devices('booted');
  if (booted.isNotEmpty) return booted.first;

  final available = _devices('available');
  if (available.isEmpty) {
    stderr.writeln('No available iPhone simulator to boot');
    exit(1);
  }
  final udid = available.first;
  print('Booting simulator $udid ...');
  final boot = Process.runSync('xcrun', ['simctl', 'boot', udid]);
  // Exit code 149 == "already booted"; anything else non-zero is fatal.
  if (boot.exitCode != 0 && !boot.stderr.toString().contains('Booted')) {
    if (boot.exitCode != 149) {
      stderr.writeln('Failed to boot simulator: ${boot.stderr}');
      exit(1);
    }
  }
  Process.runSync('xcrun', ['simctl', 'bootstatus', udid]);
  return udid;
}

/// UDIDs from `simctl list devices <filter> -j`, iPhones only, in list order.
List<String> _devices(String filter) {
  final res =
      Process.runSync('xcrun', ['simctl', 'list', 'devices', filter, '-j']);
  if (res.exitCode != 0) return [];
  final json = jsonDecode(res.stdout.toString()) as Map<String, dynamic>;
  final byRuntime = json['devices'] as Map<String, dynamic>;
  final udids = <String>[];
  for (final entry in byRuntime.entries) {
    if (!entry.key.toLowerCase().contains('ios')) continue;
    for (final dev in entry.value as List<dynamic>) {
      final d = dev as Map<String, dynamic>;
      final name = (d['name'] ?? '').toString();
      if (!name.contains('iPhone')) continue;
      udids.add(d['udid'].toString());
    }
  }
  return udids;
}
