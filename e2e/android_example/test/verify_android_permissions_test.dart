/// Verifies the permissions declared by the APK that `flutter_android_app`
/// actually produced — read out of the compiled binary `AndroidManifest.xml`
/// inside the APK, not out of the source manifest.
///
/// This is the regression test for the defect where a networked app works in
/// `-c dbg` and is silently offline in release. `flutter create` writes
/// `android.permission.INTERNET` into `android/app/src/debug/
/// AndroidManifest.xml` and nowhere else, and the debug variant is folded
/// into `-c dbg` APKs only. Android enforces INTERNET at the kernel level
/// (AID_INET group membership), so an APK without it cannot open a socket at
/// all — with no build error and no runtime exception.
///
/// `:app` therefore declares the permission through
/// `flutter_android_app(permissions = [...])`, which applies in every
/// compilation mode. Bazel's default `fastbuild` is *not* `-c dbg`, so the
/// APK this test reads takes the non-debug manifest arm: finding INTERNET in
/// it proves the permission came from `permissions` and not from the debug
/// variant overlay.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'apk_contents.dart';

/// Permissions the APK must declare regardless of compilation mode.
const _requiredPermissions = <String>{'android.permission.INTERNET'};

void main() {
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

  final tmpDir = Directory.systemTemp.createTempSync(
    'android_permissions_test',
  );
  try {
    final unzip = Process.runSync('unzip', [
      '-q',
      apkPath,
      'AndroidManifest.xml',
      '-d',
      tmpDir.path,
    ]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract AndroidManifest.xml: ${unzip.stderr}');
      exit(1);
    }

    final manifest = File('${tmpDir.path}/AndroidManifest.xml');
    final declared = usesPermissions(manifest.readAsBytesSync());

    print(
      'Permissions declared by the APK: '
      '${declared.isEmpty ? '(none)' : declared.join(', ')}',
    );

    final missing = _requiredPermissions.difference(declared);
    if (missing.isNotEmpty) {
      stderr.writeln(
        'FAIL: the APK declares no ${missing.join(', ')}.\n'
        'A release APK whose permission set is missing what the app needs '
        'has no build error and no runtime exception — it just cannot open '
        'a socket. Declare it via flutter_android_app(permissions = [...]), '
        'which applies in every compilation mode.',
      );
      exit(1);
    }

    print('\nAll Android permission checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}
