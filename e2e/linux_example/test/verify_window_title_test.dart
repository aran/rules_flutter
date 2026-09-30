/// Verifies the built-in runner was compiled with the `window_title` its
/// BUILD target names: the title is a string literal in the runner binary.
library;

import 'dart:convert';
import 'dart:io';

const _title = 'Linux Example';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final runner = File(
    '$testSrcDir/$testWorkspace/app_bazel_runner/app_bazel_runner',
  );
  if (!runner.existsSync()) {
    stderr.writeln('Runner binary not found at ${runner.path}');
    exit(1);
  }

  final needle = [...utf8.encode(_title), 0];
  if (!_contains(runner.readAsBytesSync(), needle)) {
    stderr.writeln('FAIL: runner binary has no "$_title" string');
    exit(1);
  }
  stdout.writeln('OK: runner binary carries the window title "$_title"');
}

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
