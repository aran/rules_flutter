/// Verifies the Windows bundle has the expected structure, including both
/// native shared libraries next to the runner exe (that is where the loader —
/// and the native-assets manifest's bare-basename entries — expect them).
import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final bundlePath = '$testSrcDir/$testWorkspace/ffi_windows';
  if (!Directory(bundlePath).existsSync()) {
    stderr.writeln('Bundle directory not found at $bundlePath');
    exit(1);
  }

  var failed = false;

  void check(String description, String path, {bool nonEmpty = false}) {
    final file = File(path);
    final isDir = FileSystemEntity.isDirectorySync(path);
    final exists = isDir || file.existsSync();
    if (!exists) {
      stderr.writeln('FAIL: $description — not found: $path');
      failed = true;
    } else if (nonEmpty && !isDir && file.lengthSync() == 0) {
      stderr.writeln('FAIL: $description — file is empty: $path');
      failed = true;
    } else {
      print('OK: $description');
    }
  }

  check('Runner binary', '$bundlePath/ffi_windows.exe', nonEmpty: true);
  check('flutter_windows.dll', '$bundlePath/flutter_windows.dll',
      nonEmpty: true);
  check('Native-asset lib add.dll', '$bundlePath/add.dll', nonEmpty: true);
  check('native_deps lib mul.dll', '$bundlePath/mul.dll', nonEmpty: true);
  check('flutter_assets', '$bundlePath/data/flutter_assets');
  check('icudtl.dat', '$bundlePath/data/icudtl.dat', nonEmpty: true);

  if (failed) {
    stderr.writeln('Bundle contains:');
    for (final entity in Directory(bundlePath).listSync(recursive: true)) {
      stderr.writeln('  ${entity.path.substring(bundlePath.length + 1)}');
    }
    exit(1);
  }
  print('All Windows bundle verification checks passed.');
}
