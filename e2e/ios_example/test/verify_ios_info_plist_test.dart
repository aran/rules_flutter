/// Verifies the `Info.plist` inside the built `.ipa` — specifically that an
/// app's own iOS 14+ Local Network Privacy keys coexist with the Dart VM
/// service keys rules_flutter adds to non-release builds.
///
/// `flutter_ios_app` adds `NSBonjourServices` and
/// `NSLocalNetworkUsageDescription` to every non-release build so the engine
/// can advertise the VM service over mDNS. Those keys are (correctly) absent
/// from `-c opt`: they exist for the debugger, not for the app. An app that
/// needs Local Network Privacy for *itself* must declare the keys in
/// `ios/Runner/Info.plist`, where they survive into release — and this
/// example does.
///
/// rules_apple's plisttool hard-fails when two plists declare one key with
/// different values, so the VM service keys are merged into the app's own
/// plist — the app's values win and the Bonjour service lists are unioned —
/// rather than passed beside it. This test asserts that on the real artifact.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

/// The Bonjour service this example declares for itself.
const _appService = '_rulesflutterexample._tcp';

/// The service the Flutter engine advertises the Dart VM service under.
const _vmService = '_dartVmService._tcp';

/// The opening words of this example's own usage description, which must win
/// over rules_flutter's ("Allow Flutter tools to find and connect…").
const _appUsageDescriptionPrefix = 'The example browses the local network';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final ipaPath = '$testSrcDir/$testWorkspace/app.ipa';
  if (!File(ipaPath).existsSync()) {
    stderr.writeln('IPA not found at $ipaPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('ios_info_plist_');
  try {
    final unzip = Process.runSync('unzip', ['-q', ipaPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract IPA: ${unzip.stderr}');
      exit(1);
    }

    final plistPath = '${tmpDir.path}/Payload/app.app/Info.plist';
    if (!File(plistPath).existsSync()) {
      stderr.writeln('FAIL: Info.plist not found at $plistPath');
      exit(1);
    }

    // The bundled plist is in Apple's binary format; plutil renders it.
    final converted = Process.runSync(
      'plutil',
      ['-convert', 'xml1', '-o', '-', plistPath],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (converted.exitCode != 0) {
      stderr
        ..writeln('plutil failed (exit ${converted.exitCode}):')
        ..writeln(converted.stderr);
      exit(1);
    }
    final plist = converted.stdout as String;

    var failed = false;

    void check(String description, {required bool condition}) {
      if (condition) {
        print('OK: $description');
      } else {
        stderr.writeln('FAIL: $description');
        failed = true;
      }
    }

    check(
      "the app's own Bonjour service survives the merge ($_appService)",
      condition: plist.contains(_appService),
    );
    check(
      'the Dart VM service is unioned in, not substituted for it ($_vmService)',
      condition: plist.contains(_vmService),
    );
    check(
      "the app's own NSLocalNetworkUsageDescription wins over rules_flutter's",
      condition: plist.contains(_appUsageDescriptionPrefix),
    );
    check(
      "rules_flutter's VM-service description did not overwrite the app's",
      condition: !plist.contains('Allow Flutter tools to find and connect'),
    );

    if (failed) {
      stderr
        ..writeln('\n--- Info.plist ---')
        ..writeln(plist);
      exit(1);
    }

    print('\nAll iOS Info.plist checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}
