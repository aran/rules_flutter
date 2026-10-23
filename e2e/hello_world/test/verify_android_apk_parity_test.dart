/// APK parity between the post-link overlay pipeline and the classic
/// `android_binary` pipeline for the same app.
///
/// `:hello_world_android` (Tier 1 `flutter_android_app`) links resources and
/// dex without the Flutter payload, then injects `lib/<abi>/*.so` and
/// `assets/flutter_assets/` after linking and finishes with the stock
/// zipalign/apksigner steps. `:hello_world_android_reference` assembles the
/// same sources the old way — one `android_binary` whose dex chain sees the
/// native-libs `java_import` and whose assets carry the flutter_assets tree.
/// Both are signed with the debug key under the default `v1_v2` method.
///
/// The test first runs `apksigner verify` and `zipalign -c -P 16 4` over the
/// overlay APK, then compares the two archives entry by entry: identical
/// names, identical methods (stored vs deflated), identical CRCs.
///
/// One principled exception: `META-INF/` v1/v2 signature files (`MANIFEST.MF`,
/// `CERT.SF`, `CERT.RSA`) digest the entries in archive order, and the order
/// legitimately differs — the overlay appends the payload after the base
/// entries while the classic pipeline interleaves everything. Those entries
/// are compared by name and method only.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifacts to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

class _Entry {
  _Entry(this.name, this.method, this.crc);
  final String name;
  final int method;
  final int crc;
}

List<_Entry> _readCentral(String apkPath) {
  final bytes = File(apkPath).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    stderr.writeln('FAIL: $apkPath has no End of Central Directory');
    exit(1);
  }
  final count = bd.getUint16(eocd + 8, Endian.little);
  var pos = bd.getUint32(eocd + 16, Endian.little);
  final entries = <_Entry>[];
  for (var i = 0; i < count; i++) {
    if (bd.getUint32(pos, Endian.little) != 0x02014b50) {
      stderr.writeln('FAIL: $apkPath central directory is corrupt');
      exit(1);
    }
    final method = bd.getUint16(pos + 10, Endian.little);
    final crc = bd.getUint32(pos + 16, Endian.little);
    final nameLen = bd.getUint16(pos + 28, Endian.little);
    final extraLen = bd.getUint16(pos + 30, Endian.little);
    final commentLen = bd.getUint16(pos + 32, Endian.little);
    final name = String.fromCharCodes(
      bytes.sublist(pos + 46, pos + 46 + nameLen),
    );
    entries.add(_Entry(name, method, crc));
    pos += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

void _runOrFail(String tool, List<String> args, String what) {
  print('\$ $tool ${args.join(' ')}');
  final result = Process.runSync(tool, args);
  final output = '${result.stdout}${result.stderr}'.trim();
  if (output.isNotEmpty) print(output);
  if (result.exitCode != 0) {
    stderr.writeln('FAIL: $what exited ${result.exitCode}');
    exit(1);
  }
  print('OK: $what');
}

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final base = '$testSrcDir/$testWorkspace';

  final overlayApk = '$base/hello_world_android.apk';
  final referenceApk = '$base/hello_world_android_reference.apk';
  for (final apk in [overlayApk, referenceApk]) {
    if (!File(apk).existsSync()) {
      stderr.writeln('APK not found at $apk');
      exit(1);
    }
  }
  final zipalignRel = Platform.environment['ZIPALIGN'];
  final apksignerRel = Platform.environment['APKSIGNER'];
  if (zipalignRel == null || apksignerRel == null) {
    stderr.writeln('Missing ZIPALIGN or APKSIGNER env vars');
    exit(1);
  }
  final zipalign = '$testSrcDir/$zipalignRel';
  final apksigner = '$testSrcDir/$apksignerRel';
  for (final tool in [zipalign, apksigner]) {
    if (!File(tool).existsSync()) {
      stderr.writeln('Tool not found at $tool');
      exit(1);
    }
  }

  // Signature and alignment first: these are the overlay's own promises.
  _runOrFail(apksigner, ['verify', overlayApk], 'apksigner verify overlay APK');
  _runOrFail(zipalign, [
    '-c',
    '-P',
    '16',
    '4',
    overlayApk,
  ], 'zipalign -c -P 16 4 overlay APK');

  final overlay = {for (final e in _readCentral(overlayApk)) e.name: e};
  final reference = {for (final e in _readCentral(referenceApk)) e.name: e};

  var failed = false;
  void check(String description, bool condition, String detail) {
    if (condition) {
      print('OK: $description');
    } else {
      stderr.writeln('FAIL: $description — $detail');
      failed = true;
    }
  }

  final overlayNames = overlay.keys.toSet();
  final referenceNames = reference.keys.toSet();
  check(
    'same entry names',
    overlayNames.difference(referenceNames).isEmpty &&
        referenceNames.difference(overlayNames).isEmpty,
    'overlay-only: ${overlayNames.difference(referenceNames)}; '
        'reference-only: ${referenceNames.difference(overlayNames)}',
  );

  var compared = 0;
  var metaInfSkipped = 0;
  for (final name in overlayNames.intersection(referenceNames)) {
    final o = overlay[name]!;
    final r = reference[name]!;
    final isSignature = name.startsWith('META-INF/');
    check(
      '$name same method',
      o.method == r.method,
      'overlay method ${o.method}, reference method ${r.method}',
    );
    if (isSignature) {
      metaInfSkipped++;
      continue;
    }
    check(
      '$name same CRC',
      o.crc == r.crc,
      'overlay CRC ${o.crc.toRadixString(16)}, '
          'reference CRC ${r.crc.toRadixString(16)}',
    );
    compared++;
  }

  // The payload must be there and stored: page-alignment needs method 0.
  const payloadSo = 'lib/arm64-v8a/libapp.so';
  check(
    '$payloadSo present and stored in overlay APK',
    overlay[payloadSo]?.method == 0,
    'got ${overlay[payloadSo]?.method}',
  );
  check(
    'flutter_assets present in overlay APK',
    overlayNames.any((n) => n.startsWith('assets/flutter_assets/')),
    'no assets/flutter_assets/ entries',
  );

  print('');
  print(
    'Compared $compared entries fully, '
    '$metaInfSkipped META-INF signature entries by name+method.',
  );
  if (failed) exit(1);
  print('PASS');
}
