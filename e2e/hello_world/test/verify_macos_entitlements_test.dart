/// Verifies the entitlements blob applied at codesign time on the macOS
/// bundle produced by `:hello_world_macos` (which uses the Tier-1
/// `flutter_macos_app` macro).
///
/// `flutter create --platforms=macos .` always emits
/// `macos/Runner/{DebugProfile,Release}.entitlements`. Both files declare
/// the App Sandbox capability (`com.apple.security.app-sandbox`). The
/// macro auto-discovers the conventional pair and forwards them to
/// `macos_application(entitlements = ...)`, so codesign embeds the
/// merged plist into the bundle and macOS treats the app as sandboxed
/// at runtime — meaning `getApplicationDocumentsDirectory()` returns
/// `~/Library/Containers/<bundle-id>/Data/Documents/` instead of
/// `~/Documents/`, matching `flutter build macos`.
///
/// This test reads `codesign -d --entitlements -` and asserts the
/// sandbox key is present.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final zipPath = '$testSrcDir/$testWorkspace/hello_world_macos.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  final tmpDir =
      Directory.systemTemp.createTempSync('hello_world_macos_entitlements_');
  try {
    final unzip = Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }

    final appPath = '${tmpDir.path}/Hello World.app';
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
      stderr.writeln('codesign failed (exit ${result.exitCode}):');
      stderr.writeln(result.stderr);
      exit(1);
    }

    final entitlementsBlob = result.stdout as String;
    print('--- codesign --entitlements --- ');
    print(entitlementsBlob);
    print('--- end ---');

    if (!entitlementsBlob.contains('com.apple.security.app-sandbox')) {
      stderr.writeln('FAIL: expected entitlements blob to declare '
          'com.apple.security.app-sandbox. Got:');
      stderr.writeln(entitlementsBlob.isEmpty
          ? '<empty>'
          : entitlementsBlob);
      exit(1);
    }

    print('PASS — sandbox entitlement present.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}
