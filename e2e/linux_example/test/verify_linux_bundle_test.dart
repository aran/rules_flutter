/// Verifies the Linux bundle produced by flutter_linux_app has the expected
/// directory structure.
///
/// Runs as a Bazel dart_test with the bundle as data dependency.
library;

import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final bundlePath = '$testSrcDir/$testWorkspace/app';
  final bundle = Directory(bundlePath);

  if (!bundle.existsSync()) {
    stderr.writeln('Bundle directory not found at $bundlePath');
    stderr.writeln('Looking for bundle...');
    _listTree(Directory('$testSrcDir/$testWorkspace'), '');
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
      final size = !isDir ? ' (${file.lengthSync()} bytes)' : '';
      print('OK: $description$size');
    }
  }

  // Runner executable.
  check('Runner binary', '$bundlePath/app', nonEmpty: true);

  // Engine library.
  check(
    'libflutter_linux_gtk.so',
    '$bundlePath/lib/libflutter_linux_gtk.so',
    nonEmpty: true,
  );

  // In release mode libapp.so exists; in debug mode data/flutter_assets/kernel_blob.bin exists.
  final hasAotLib = File('$bundlePath/lib/libapp.so').existsSync();
  final hasKernelBlob = File('$bundlePath/data/flutter_assets/kernel_blob.bin').existsSync();
  if (hasAotLib) {
    check('AOT snapshot (release)', '$bundlePath/lib/libapp.so',
        nonEmpty: true);
  } else if (hasKernelBlob) {
    check('Kernel blob (debug)', '$bundlePath/data/flutter_assets/kernel_blob.bin', nonEmpty: true);
  } else {
    stderr.writeln('FAIL: Neither lib/libapp.so nor data/flutter_assets/kernel_blob.bin found');
    failed = true;
  }

  // Flutter assets.
  check('flutter_assets directory', '$bundlePath/data/flutter_assets');
  check(
      'AssetManifest.bin', '$bundlePath/data/flutter_assets/AssetManifest.bin');
  check(
      'FontManifest.json', '$bundlePath/data/flutter_assets/FontManifest.json');
  check('NOTICES.Z', '$bundlePath/data/flutter_assets/NOTICES.Z');

  // ICU data.
  check('icudtl.dat', '$bundlePath/data/icudtl.dat', nonEmpty: true);

  if (failed) {
    stderr.writeln('');
    stderr.writeln('Actual bundle contents:');
    _listTree(bundle, '');
    exit(1);
  }

  print('');
  print('All Linux bundle verification checks passed.');
}

void _listTree(Directory dir, String indent) {
  if (!dir.existsSync()) return;
  final entries = dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    final name = entry.path.split('/').last;
    if (entry is Directory) {
      stderr.writeln('$indent$name/');
      _listTree(entry, '$indent  ');
    } else if (entry is File) {
      stderr.writeln('$indent$name (${entry.lengthSync()} bytes)');
    }
  }
}
