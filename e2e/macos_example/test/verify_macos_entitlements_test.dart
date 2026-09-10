/// Verifies the entitlements blob codesign actually embedded in the bundle
/// `flutter_macos_app` produced — not the entitlements source files.
///
/// This is the regression test for the defect where a networked macOS app
/// works in `-c dbg` and is silently offline in release. `flutter create`
/// writes `com.apple.security.network.server` into
/// `macos/Runner/DebugProfile.entitlements` only, and `Release.entitlements`
/// declares nothing but `com.apple.security.app-sandbox`. The macro selects
/// between the pair by compilation mode, so the release bundle is sandboxed
/// with neither `network.server` nor `network.client` — the sandbox denies
/// the socket with no build error and no runtime exception.
///
/// `:app` therefore declares what it needs through
/// `flutter_macos_app(additional_entitlements = [...])`, which merges into
/// whichever base the mode selected. Bazel's default `fastbuild` is *not*
/// `-c dbg`, so the bundle this test reads carries the **release**
/// entitlements: finding the network keys in it proves the additions
/// survived into the release arm.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

/// Entitlements the signed bundle must carry in every compilation mode:
/// the sandbox the scaffold always declares, plus the two network
/// capabilities the app added for itself.
const _requiredEntitlements = <String>[
  'com.apple.security.app-sandbox',
  'com.apple.security.network.client',
  'com.apple.security.network.server',
];

void main() {
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

  final tmpDir = Directory.systemTemp.createTempSync('macos_entitlements_');
  try {
    final unzip = Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }

    final appPath = '${tmpDir.path}/Flutter App.app';
    if (!Directory(appPath).existsSync()) {
      stderr.writeln('FAIL: .app not found at $appPath');
      exit(1);
    }

    final result = Process.runSync(
      'codesign',
      ['-d', '--entitlements', ':-', appPath],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      stderr
        ..writeln('codesign failed (exit ${result.exitCode}):')
        ..writeln(result.stderr);
      exit(1);
    }

    final blob = result.stdout as String;
    print('--- codesign --entitlements ---');
    print(blob);
    print('--- end ---');

    var failed = false;
    for (final entitlement in _requiredEntitlements) {
      if (blob.contains(entitlement)) {
        print('OK: $entitlement');
      } else {
        stderr.writeln('FAIL: the signed bundle does not declare $entitlement');
        failed = true;
      }
    }

    if (failed) {
      stderr.writeln(
        '\nA sandboxed release bundle that has lost a network '
        'entitlement its debug build had is invisible — no build error, no '
        'runtime exception, just an app with no peers. Declare the '
        'capability via flutter_macos_app(additional_entitlements = [...]), '
        'which applies in every compilation mode.',
      );
      exit(1);
    }

    print('\nAll macOS entitlement checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}
