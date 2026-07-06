/// Verifies the Linux bundle has the expected structure,
/// including the native shared library with the correct filename.
import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final bundlePath = '$testSrcDir/$testWorkspace/ffi_linux';
  final bundle = Directory(bundlePath);
  if (!bundle.existsSync()) {
    stderr.writeln('Bundle not found at $bundlePath');
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

  check('Runner binary', '$bundlePath/ffi_linux', nonEmpty: true);
  check('libflutter_linux_gtk.so', '$bundlePath/lib/libflutter_linux_gtk.so', nonEmpty: true);
  check('flutter_assets', '$bundlePath/data/flutter_assets');
  check('AssetManifest.bin', '$bundlePath/data/flutter_assets/AssetManifest.bin');
  check('FontManifest.json', '$bundlePath/data/flutter_assets/FontManifest.json');
  check('NOTICES.Z', '$bundlePath/data/flutter_assets/NOTICES.Z');
  check('icudtl.dat', '$bundlePath/data/icudtl.dat', nonEmpty: true);
  check('Native-asset lib libadd.so', '$bundlePath/lib/libadd.so', nonEmpty: true);
  check('native_deps lib libmul.so', '$bundlePath/lib/libmul.so', nonEmpty: true);

  // Check for either AOT or debug artifact.
  final hasAot = File('$bundlePath/lib/libapp.so').existsSync();
  final hasKernelBlob = File('$bundlePath/data/flutter_assets/kernel_blob.bin').existsSync();
  if (hasAot) {
    check('AOT snapshot', '$bundlePath/lib/libapp.so', nonEmpty: true);
  } else if (hasKernelBlob) {
    check('Kernel blob (debug)', '$bundlePath/data/flutter_assets/kernel_blob.bin', nonEmpty: true);
  } else {
    stderr.writeln('FAIL: Neither lib/libapp.so nor data/flutter_assets/kernel_blob.bin found');
    failed = true;
  }

  if (failed) {
    _listDir(Directory(bundlePath), '');
    exit(1);
  }

  print('All Linux bundle verification checks passed.');
}

void _listDir(Directory dir, String indent) {
  for (final entity in dir.listSync()..sort((a, b) => a.path.compareTo(b.path))) {
    final name = entity.path.split('/').last;
    if (entity is Directory) {
      stderr.writeln('$indent$name/');
      _listDir(entity, '$indent  ');
    } else {
      stderr.writeln('$indent$name');
    }
  }
}
