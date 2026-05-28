/// Compares file trees between flutter build and bazel build outputs.
///
/// Usage: dart run compare_artifacts.dart <flutter_dir> <bazel_dir>
///
/// Reports:
/// - Files present in both builds (with size comparison)
/// - Files only in flutter build
/// - Files only in bazel build
library;

import 'dart:io';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('Usage: dart run compare_artifacts.dart <flutter_dir> <bazel_dir>');
    exit(1);
  }

  final flutterDir = Directory(args[0]);
  final bazelDir = Directory(args[1]);

  if (!flutterDir.existsSync()) {
    stderr.writeln('Flutter directory not found: ${args[0]}');
    exit(1);
  }
  if (!bazelDir.existsSync()) {
    stderr.writeln('Bazel directory not found: ${args[1]}');
    exit(1);
  }

  final flutterFiles = _listFiles(flutterDir);
  final bazelFiles = _listFiles(bazelDir);

  final flutterKeys = flutterFiles.keys.toSet();
  final bazelKeys = bazelFiles.keys.toSet();

  final inBoth = flutterKeys.intersection(bazelKeys);
  final onlyFlutter = flutterKeys.difference(bazelKeys);
  final onlyBazel = bazelKeys.difference(flutterKeys);

  // Files in both.
  print('=== Files in BOTH builds (${inBoth.length}) ===');
  final sortedBoth = inBoth.toList()..sort();
  for (final f in sortedBoth) {
    final fSize = flutterFiles[f]!;
    final bSize = bazelFiles[f]!;
    final diff = bSize - fSize;
    final diffStr = diff == 0
        ? 'same'
        : '${diff > 0 ? '+' : ''}$diff bytes (${_percent(fSize, bSize)})';
    print('  $f  flutter=${_humanSize(fSize)}  bazel=${_humanSize(bSize)}  $diffStr');
  }

  // Only in flutter.
  print('');
  print('=== Files ONLY in flutter build (${onlyFlutter.length}) ===');
  final sortedFlutter = onlyFlutter.toList()..sort();
  for (final f in sortedFlutter) {
    print('  $f  ${_humanSize(flutterFiles[f]!)}');
  }

  // Only in bazel.
  print('');
  print('=== Files ONLY in bazel build (${onlyBazel.length}) ===');
  final sortedBazel = onlyBazel.toList()..sort();
  for (final f in sortedBazel) {
    print('  $f  ${_humanSize(bazelFiles[f]!)}');
  }

  // Summary.
  print('');
  print('=== Summary ===');
  print('Flutter: ${flutterKeys.length} files');
  print('Bazel:   ${bazelKeys.length} files');
  print('Common:  ${inBoth.length} files');
  print('Only in flutter: ${onlyFlutter.length}');
  print('Only in bazel:   ${onlyBazel.length}');

  // Size comparison for common files.
  var sameCount = 0;
  var smallerCount = 0;
  var largerCount = 0;
  for (final f in inBoth) {
    final diff = bazelFiles[f]! - flutterFiles[f]!;
    if (diff == 0) {
      sameCount++;
    } else if (diff < 0) {
      smallerCount++;
    } else {
      largerCount++;
    }
  }
  print('Size comparison (common files): $sameCount same, '
      '$smallerCount bazel smaller, $largerCount bazel larger');
}

/// Lists all files recursively, returning relative path → size.
Map<String, int> _listFiles(Directory dir) {
  final result = <String, int>{};
  final prefix = dir.path.endsWith('/') ? dir.path : '${dir.path}/';

  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File) {
      final relativePath = entity.path.substring(prefix.length);
      // Skip .DS_Store and other macOS metadata.
      if (relativePath.contains('.DS_Store')) continue;
      if (relativePath.contains('__MACOSX')) continue;
      result[relativePath] = entity.lengthSync();
    }
  }

  return result;
}

String _humanSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
}

String _percent(int a, int b) {
  if (a == 0) return 'N/A';
  final pct = ((b - a) / a * 100).toStringAsFixed(1);
  return '${pct}%';
}
