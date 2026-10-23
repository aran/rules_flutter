/// Verifies the macOS .app bundle has the expected structure,
/// including the native dylib with the correct filename.
///
/// rules_apple outputs a .zip — we extract it to a temp dir and verify.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final zipPath = '$testSrcDir/$testWorkspace/ffi_plugin_macos.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  // Extract to temp directory.
  final tmpDir = Directory.systemTemp.createTempSync('macos_bundle_test');
  try {
    final result = Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${result.stderr}');
      exit(1);
    }

    final bundlePath = '${tmpDir.path}/ffi_plugin_macos.app';
    var failed = false;

    void check(String description, String path) {
      final exists =
          FileSystemEntity.isDirectorySync(path) || File(path).existsSync();
      if (!exists) {
        stderr.writeln('FAIL: $description — not found: $path');
        failed = true;
      } else {
        print('OK: $description');
      }
    }

    void checkSymlink(String description, String path, String expectedTarget) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.link) {
        stderr.writeln(
          'FAIL: $description — expected symlink at $path, got $type',
        );
        failed = true;
        return;
      }
      final actualTarget = Link(path).targetSync();
      if (actualTarget != expectedTarget) {
        stderr.writeln(
          'FAIL: $description — expected symlink $path -> $expectedTarget, '
          'got $actualTarget',
        );
        failed = true;
      } else {
        print('OK: $description');
      }
    }

    check(
      'Native dylib libmultiply.dylib exists',
      '$bundlePath/Contents/Frameworks/libmultiply.dylib',
    );
    final appFw = '$bundlePath/Contents/Frameworks/App.framework';
    check(
      'App.framework exists',
      appFw,
    );
    check(
      'App.framework/Versions/A/App exists',
      '$appFw/Versions/A/App',
    );
    check(
      'App.framework/Versions/A/Resources/Info.plist exists',
      '$appFw/Versions/A/Resources/Info.plist',
    );
    checkSymlink(
      'App.framework/Versions/Current symlink',
      '$appFw/Versions/Current',
      'A',
    );
    checkSymlink(
      'App.framework/App symlink',
      '$appFw/App',
      'Versions/Current/App',
    );
    checkSymlink(
      'App.framework/Resources symlink',
      '$appFw/Resources',
      'Versions/Current/Resources',
    );
    final appFwPlist = File('$appFw/Versions/A/Resources/Info.plist');
    final fmwkPattern = RegExp(
      r'<key>CFBundlePackageType</key>\s*<string>FMWK</string>',
    );
    if (appFwPlist.existsSync() &&
        !fmwkPattern.hasMatch(appFwPlist.readAsStringSync())) {
      stderr.writeln(
        'FAIL: App.framework Info.plist missing CFBundlePackageType = FMWK',
      );
      failed = true;
    }
    check(
      'FlutterMacOS.framework exists',
      '$bundlePath/Contents/Frameworks/FlutterMacOS.framework',
    );
    check(
      'Runner binary exists',
      '$bundlePath/Contents/MacOS/ffi_plugin_macos',
    );
    check(
      'Info.plist exists',
      '$bundlePath/Contents/Info.plist',
    );

    if (failed) {
      final fwDir = Directory('$bundlePath/Contents/Frameworks');
      if (fwDir.existsSync()) {
        stderr.writeln('Contents/Frameworks contains:');
        for (final entity in fwDir.listSync()) {
          stderr.writeln('  ${entity.path.split('/').last}');
        }
      }
      exit(1);
    }

    print('All macOS bundle verification checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}
