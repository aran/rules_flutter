/// Verifies the plugin overlays' generated `BuildConfig.java` stubs hold
/// valid Java text.
///
/// The audio_session and jni overlays ship their `BuildConfig.java` stubs as
/// heredoc `cat` genrules, which `flutter_pub_package` rewrites to
/// `write_file`. A rewrite that re-escapes the already-encoded heredoc body
/// emits literal backslashes (`\"com...\"`), and javac rejects the stub.
/// This test builds each overlay's `_build_config_src` output (a plain
/// `write_file`, so no Android toolchain is needed) and checks the bytes:
/// no backslash anywhere, and `LIBRARY_PACKAGE_NAME` equal to the file's
/// own `package` line, which itself equals the plugin's namespace.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifacts to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

/// Overlay BuildConfig outputs by file suffix, with the expected namespace.
const _expectedPackages = <String, String>{
  'com/ryanheise/audio_session/BuildConfig.java': 'com.ryanheise.audio_session',
  'com/github/dart_lang/jni/BuildConfig.java': 'com.github.dart_lang.jni',
};

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  var failed = false;
  for (final entry in _expectedPackages.entries) {
    if (!_verifyBuildConfig(testSrcDir, entry.key, entry.value)) {
      failed = true;
    }
  }
  if (failed) exit(1);
  print('All overlay BuildConfig.java stubs hold valid Java text.');
}

/// Checks one generated stub; returns false on any mismatch.
bool _verifyBuildConfig(String runfiles, String suffix, String package) {
  final path = _findRunfile(runfiles, suffix);
  if (path == null) {
    stderr.writeln('FAIL: $suffix not found under $runfiles');
    return false;
  }
  final content = File(path).readAsStringSync();
  if (content.contains(r'\')) {
    stderr.writeln(
      'FAIL: $suffix holds a backslash; '
      'the overlay heredoc was double-escaped',
    );
    return false;
  }
  final packageLine = RegExp(
    r'^package\s+([\w.]+);',
    multiLine: true,
  ).firstMatch(content);
  final libraryName = RegExp(r'LIBRARY_PACKAGE_NAME\s*=\s*"([^"]+)"')
      .firstMatch(content);
  if (packageLine == null || libraryName == null) {
    stderr.writeln('FAIL: $suffix names no package or library name');
    return false;
  }
  if (packageLine.group(1) != package || libraryName.group(1) != package) {
    stderr.writeln(
      'FAIL: $suffix declares ${packageLine.group(1)} / '
      '${libraryName.group(1)}; want $package',
    );
    return false;
  }
  print('OK: $suffix declares $package with no escapes');
  return true;
}

/// Locates a runfile by path suffix with a bounded breadth-first walk.
///
/// The spoke repos carry no apparent name in this workspace, so their
/// runfiles directory name is not pinned here; the walk finds the file
/// under whatever layout the test runner uses.
String? _findRunfile(String runfiles, String suffix) {
  var queue = <String>[runfiles];
  final seen = <String>{runfiles};
  for (var depth = 0; queue.isNotEmpty && depth < 12; depth++) {
    final next = <String>[];
    for (final dir in queue) {
      for (final entity in Directory(dir).listSync(followLinks: false)) {
        if (entity is File) {
          if (entity.path.endsWith(suffix)) return entity.path;
        } else if (entity is Link) {
          // Runfiles trees link external-repo files and directories in;
          // without following the link, neither matches.
          final target = entity.resolveSymbolicLinksSync();
          if (target.endsWith(suffix) && FileSystemEntity.isFileSync(target)) {
            return target;
          }
          if (FileSystemEntity.isDirectorySync(target) && seen.add(target)) {
            next.add(target);
          }
        } else if (entity is Directory) {
          if (seen.add(entity.path)) next.add(entity.path);
        }
      }
    }
    queue = next;
  }
  return null;
}
