/// Verifies the Android APK produced by flutter_android_app has the
/// expected structure: classes.dex, native libs, flutter_assets, and manifest.
///
/// APK is a zip file — we extract it to a temp dir and verify contents.
import 'dart:io';

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

  // Extract to temp directory (APK is a zip).
  final tmpDir = Directory.systemTemp.createTempSync('android_apk_test');
  try {
    final result =
        Process.runSync('unzip', ['-q', apkPath, '-d', tmpDir.path]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to extract APK: ${result.stderr}');
      exit(1);
    }

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

    // --- Structural checks ---

    check(
      'classes.dex exists',
      '${tmpDir.path}/classes.dex',
    );
    check(
      'libapp.so exists (arm64-v8a)',
      '${tmpDir.path}/lib/arm64-v8a/libapp.so',
    );
    check(
      'libflutter.so exists (arm64-v8a)',
      '${tmpDir.path}/lib/arm64-v8a/libflutter.so',
    );
    check(
      'flutter_assets directory exists',
      '${tmpDir.path}/assets/flutter_assets',
    );
    check(
      'AssetManifest.bin exists',
      '${tmpDir.path}/assets/flutter_assets/AssetManifest.bin',
    );
    check(
      'FontManifest.json exists',
      '${tmpDir.path}/assets/flutter_assets/FontManifest.json',
    );
    check(
      'AndroidManifest.xml exists (binary format)',
      '${tmpDir.path}/AndroidManifest.xml',
    );

    // --- Binary format check ---
    // Verify libapp.so format. When built with
    //   --platforms=@rules_flutter//flutter/platforms:android_arm64
    // it must be ELF. Without --platforms it will be Mach-O (host format).
    // The REQUIRE_ELF env var controls whether Mach-O is a hard failure.
    final libappPath = '${tmpDir.path}/lib/arm64-v8a/libapp.so';
    if (File(libappPath).existsSync()) {
      final bytes = File(libappPath).readAsBytesSync();
      if (bytes.length >= 4) {
        final isElf = bytes[0] == 0x7f &&
            bytes[1] == 0x45 && // 'E'
            bytes[2] == 0x4c && // 'L'
            bytes[3] == 0x46; // 'F'
        final isMachO = bytes[0] == 0xcf &&
            bytes[1] == 0xfa &&
            bytes[2] == 0xed &&
            bytes[3] == 0xfe;
        final requireElf =
            Platform.environment['REQUIRE_ELF']?.toLowerCase() == 'true';
        if (isElf) {
          print('OK: libapp.so is ELF format (correct for Android)');
        } else if (isMachO) {
          if (requireElf) {
            stderr.writeln(
                'FAIL: libapp.so is Mach-O format (macOS) — built without --platforms=android_arm64?');
            failed = true;
          } else {
            print(
                'WARN: libapp.so is Mach-O format (host) — build with --platforms=android_arm64 for device');
          }
        } else {
          stderr.writeln(
              'FAIL: libapp.so has unknown format (magic: ${bytes.sublist(0, 4)})');
          failed = true;
        }
      }
    }

    if (failed) {
      stderr.writeln('\nAPK contents:');
      _listRecursive(tmpDir.path, '');
      exit(1);
    }

    print('\nAll Android APK verification checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

void _listRecursive(String path, String indent) {
  final dir = Directory(path);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync()) {
    final name = entity.path.split('/').last;
    stderr.writeln('$indent$name');
    if (entity is Directory) {
      _listRecursive(entity.path, '$indent  ');
    }
  }
}
