/// Verifies that `//glass_plugin`'s own AndroidManifest.xml is merged into
/// the app's: the boot receiver it declares and the permission it asks for
/// are in the APK. A plugin that re-arms alarms after a reboot works only
/// if they are.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log.
// ignore_for_file: avoid_print

import 'dart:io';

const _expected = [
  'com.example.glass_plugin.GlassBootReceiver',
  'android.intent.action.BOOT_COMPLETED',
  'android.permission.RECEIVE_BOOT_COMPLETED',
];

void main() {
  final base =
      '${Platform.environment['TEST_SRCDIR']}/'
      '${Platform.environment['TEST_WORKSPACE']}';
  final apk = '$base/glass_app/glass_android.apk';
  final tmp = Directory.systemTemp.createTempSync('glass_apk_');
  try {
    final unzip = Process.runSync('unzip', [
      '-q',
      apk,
      'AndroidManifest.xml',
      '-d',
      tmp.path,
    ]);
    if (unzip.exitCode != 0) {
      stderr.writeln('FAIL: could not extract $apk: ${unzip.stderr}');
      exit(1);
    }
    final manifest = File('${tmp.path}/AndroidManifest.xml').readAsBytesSync();
    var failed = false;
    for (final name in _expected) {
      // Binary XML stores its strings as UTF-16.
      if (_contains(manifest, _utf16(name))) {
        print('OK: merged manifest names $name');
      } else {
        stderr.writeln('FAIL: merged manifest lacks $name');
        failed = true;
      }
    }
    if (failed) exit(1);
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

List<int> _utf16(String s) => [
  for (final unit in s.codeUnits) ...[unit & 0xff, unit >> 8],
];

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
