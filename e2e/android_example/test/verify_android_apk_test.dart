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
      'libadd.so exists (arm64-v8a, from native_deps)',
      '${tmpDir.path}/lib/arm64-v8a/libadd.so',
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

    // --- Binary format checks ---
    // Every native library in the APK must be an ELF shared object whose
    // machine type matches its ABI directory. Android's linker cannot load
    // anything else (a host-format Mach-O libapp.so crashes at startup with
    // "VM snapshot invalid"), so any other format is a hard failure.
    final libDir = Directory('${tmpDir.path}/lib');
    var checkedLibs = 0;
    if (libDir.existsSync()) {
      for (final abiDir in libDir.listSync().whereType<Directory>()) {
        final abi = abiDir.path.split('/').last;
        final expectedMachine = _elfMachineForAbi[abi];
        if (expectedMachine == null) {
          stderr.writeln('FAIL: unexpected ABI directory lib/$abi');
          failed = true;
          continue;
        }
        for (final lib in abiDir.listSync().whereType<File>()) {
          checkedLibs++;
          final name = 'lib/$abi/${lib.path.split('/').last}';
          final error = _validateElf(lib, expectedMachine);
          if (error != null) {
            stderr.writeln('FAIL: $name — $error');
            failed = true;
          } else {
            print('OK: $name is ELF (machine 0x'
                '${expectedMachine.toRadixString(16)}, correct for $abi)');
          }
        }
      }
    }
    if (checkedLibs == 0) {
      stderr.writeln('FAIL: no native libraries found under lib/');
      failed = true;
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

/// ELF e_machine values by Android ABI directory name.
const _elfMachineForAbi = <String, int>{
  'arm64-v8a': 0xb7, // EM_AARCH64
  'x86_64': 0x3e, // EM_X86_64
};

/// Returns an error message if [file] is not an ELF shared object with the
/// given e_machine, or null if it is valid.
String? _validateElf(File file, int expectedMachine) {
  final bytes = file.readAsBytesSync();
  if (bytes.length < 20) {
    return 'file too small to be an ELF binary (${bytes.length} bytes)';
  }
  final isElf =
      bytes[0] == 0x7f && bytes[1] == 0x45 && bytes[2] == 0x4c && bytes[3] == 0x46;
  if (!isElf) {
    final isMachO =
        bytes[0] == 0xcf && bytes[1] == 0xfa && bytes[2] == 0xed && bytes[3] == 0xfe;
    if (isMachO) {
      return 'Mach-O binary (host format) — the build was not transitioned '
          'to an Android platform';
    }
    return 'not an ELF binary (magic: ${bytes.sublist(0, 4)})';
  }
  // e_machine: 2 bytes little-endian at offset 18.
  final machine = bytes[18] | (bytes[19] << 8);
  if (machine != expectedMachine) {
    return 'ELF machine 0x${machine.toRadixString(16)} does not match '
        'expected 0x${expectedMachine.toRadixString(16)}';
  }
  return null;
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
