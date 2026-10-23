/// The Android APK carries exactly the pub assets its platform allows.
///
/// `@deps//:platform_assets` (a `path:` fixture package resolved through
/// `flutter.pub`) declares `assets/any.txt` (unconditional),
/// `assets/android_only.txt` (`platforms: [android]`), `assets/web_only.txt`
/// (`platforms: [web]`), `assets/paid_only.txt` (`flavors: [paid]`) and
/// `assets/union_android.txt` (one entry for `[android]`, one for `[linux]`,
/// so it ships on the union: Android and Linux). The test lists the APK's
/// zip entries and asserts
/// `assets/flutter_assets/packages/platform_assets/assets/` holds `any.txt`,
/// `android_only.txt` and `union_android.txt` but neither `web_only.txt` nor
/// `paid_only.txt`, and that `AssetManifest.bin` agrees.
///
/// The archive is parsed by hand (central directory walk, raw inflate via
/// `dart:io`'s `ZLibCodec` when the manifest entry is deflated): no `unzip`
/// runs here.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifacts to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One zip entry: its name plus where its data lives.
class _Entry {
  _Entry(this.name, this.method, this.compressedSize, this.localOffset);
  final String name;
  final int method;
  final int compressedSize;
  final int localOffset;
}

List<_Entry> _readCentral(String apkPath, Uint8List bytes) {
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
    final compressedSize = bd.getUint32(pos + 20, Endian.little);
    final nameLen = bd.getUint16(pos + 28, Endian.little);
    final extraLen = bd.getUint16(pos + 30, Endian.little);
    final commentLen = bd.getUint16(pos + 32, Endian.little);
    final localOffset = bd.getUint32(pos + 42, Endian.little);
    final name = String.fromCharCodes(
      bytes.sublist(pos + 46, pos + 46 + nameLen),
    );
    entries.add(_Entry(name, method, compressedSize, localOffset));
    pos += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}

/// The raw (decompressed) bytes of [entry].
Uint8List _entryData(Uint8List bytes, _Entry entry) {
  final bd = ByteData.sublistView(bytes);
  final pos = entry.localOffset;
  if (bd.getUint32(pos, Endian.little) != 0x04034b50) {
    stderr.writeln('FAIL: ${entry.name} has no local file header');
    exit(1);
  }
  final nameLen = bd.getUint16(pos + 26, Endian.little);
  final extraLen = bd.getUint16(pos + 28, Endian.little);
  final dataStart = pos + 30 + nameLen + extraLen;
  final raw = bytes.sublist(dataStart, dataStart + entry.compressedSize);
  if (entry.method == 0) {
    return raw;
  }
  if (entry.method == 8) {
    return Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
  }
  stderr.writeln(
    'FAIL: ${entry.name} uses unsupported compression method '
    '${entry.method}',
  );
  exit(1);
}

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final apk = '$testSrcDir/$testWorkspace/hello_world_android.apk';
  if (!File(apk).existsSync()) {
    stderr.writeln('APK not found at $apk');
    exit(1);
  }

  final bytes = File(apk).readAsBytesSync();
  final entries = _readCentral(apk, bytes);
  const prefix = 'assets/flutter_assets/packages/platform_assets/assets/';
  final names = <String>{
    for (final e in entries)
      if (e.name.startsWith(prefix)) e.name.substring(prefix.length),
  };
  print('platform_assets entries in APK: ${names.toList()..sort()}');

  var failed = false;
  void check(String description, bool condition, String detail) {
    if (condition) {
      print('OK: $description');
    } else {
      stderr.writeln('FAIL: $description — $detail');
      failed = true;
    }
  }

  check(
    'unconditional any.txt is in the APK',
    names.contains('any.txt'),
    'missing assets/flutter_assets/$prefix/any.txt',
  );
  check(
    'android_only.txt is in the Android APK',
    names.contains('android_only.txt'),
    'missing assets/flutter_assets/$prefix/android_only.txt',
  );
  check(
    'union_android.txt is in the Android APK',
    names.contains('union_android.txt'),
    'missing assets/flutter_assets/$prefix/union_android.txt: the android '
        'and linux entries must union',
  );
  check(
    'web_only.txt is not in the Android APK',
    !names.contains('web_only.txt'),
    'assets/flutter_assets/$prefix/web_only.txt must stay web-only',
  );
  check(
    'paid_only.txt is not in the Android APK',
    !names.contains('paid_only.txt'),
    'assets/flutter_assets/$prefix/paid_only.txt needs a flavor that '
        'does not exist yet',
  );

  // AssetManifest.bin must agree with the tree: the manifest is
  // StandardMessageCodec bytes, which embed each key as UTF-8 inline, so a
  // substring search over the (possibly inflated) entry decides it.
  final manifestEntry = [for (final e in entries) e].firstWhere(
    (e) => e.name == 'assets/flutter_assets/AssetManifest.bin',
    orElse: () => _Entry('', -1, 0, 0),
  );
  check(
    'AssetManifest.bin is in the APK',
    manifestEntry.method != -1,
    'no assets/flutter_assets/AssetManifest.bin entry',
  );
  if (manifestEntry.method != -1) {
    final manifestText = utf8.decode(
      _entryData(bytes, manifestEntry),
      allowMalformed: true,
    );
    check(
      'AssetManifest lists any.txt',
      manifestText.contains('packages/platform_assets/assets/any.txt'),
      'manifest is missing the unconditional asset',
    );
    check(
      'AssetManifest lists android_only.txt',
      manifestText.contains('packages/platform_assets/assets/android_only.txt'),
      'manifest is missing the android-only asset',
    );
    check(
      'AssetManifest lists union_android.txt',
      manifestText.contains(
        'packages/platform_assets/assets/union_android.txt',
      ),
      'manifest is missing the unioned android/linux asset',
    );
    check(
      'AssetManifest omits web_only.txt',
      !manifestText.contains('packages/platform_assets/assets/web_only.txt'),
      'manifest lists an asset the bundle must not carry',
    );
    check(
      'AssetManifest omits paid_only.txt',
      !manifestText.contains('packages/platform_assets/assets/paid_only.txt'),
      'manifest lists an asset the bundle must not carry',
    );
  }

  if (failed) exit(1);
  print('PASS');
}
