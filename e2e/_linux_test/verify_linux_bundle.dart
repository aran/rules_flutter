/// Verifies a Flutter Linux bundle has the expected directory structure.
///
/// Usage: dart run verify_linux_bundle.dart <path/to/bundle_dir> [native_lib1.so ...]
///
/// Structure expected:
///   <app_name>/
///     <app_name>                  ← runner executable
///     lib/
///       libflutter_linux_gtk.so   ← Flutter engine
///       libapp.so                 ← AOT (release) — or absent in debug
///     data/
///       flutter_assets/
///         AssetManifest.bin
///         FontManifest.json
///         NOTICES.Z
///         kernel_blob.bin          ← debug only
///       icudtl.dat
library;

import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run verify_linux_bundle.dart <bundle_dir> [native_lib.so ...]',
    );
    exit(1);
  }

  final bundlePath = args[0];
  final expectedNativeLibs = args.skip(1).toList();
  final bundle = Directory(bundlePath);

  if (!bundle.existsSync()) {
    stderr.writeln('Bundle directory not found: $bundlePath');
    exit(1);
  }

  // Derive app name from the bundle directory name.
  final appName = Uri.parse(bundlePath).pathSegments.last;

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
  check('Runner binary', '$bundlePath/$appName', nonEmpty: true);

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
    check('AOT snapshot (release)', '$bundlePath/lib/libapp.so', nonEmpty: true);
  } else if (hasKernelBlob) {
    check('Kernel blob (debug)', '$bundlePath/data/flutter_assets/kernel_blob.bin', nonEmpty: true);
  } else {
    stderr.writeln('FAIL: Neither lib/libapp.so nor data/flutter_assets/kernel_blob.bin found');
    failed = true;
  }

  // Flutter assets.
  check('flutter_assets directory', '$bundlePath/data/flutter_assets');
  check('AssetManifest.bin', '$bundlePath/data/flutter_assets/AssetManifest.bin');
  check('FontManifest.json', '$bundlePath/data/flutter_assets/FontManifest.json');
  check('NOTICES.Z', '$bundlePath/data/flutter_assets/NOTICES.Z');

  // ICU data.
  check('icudtl.dat', '$bundlePath/data/icudtl.dat', nonEmpty: true);

  // Native plugin shared libraries.
  for (final lib in expectedNativeLibs) {
    check('Native lib $lib', '$bundlePath/lib/$lib', nonEmpty: true);
  }

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
