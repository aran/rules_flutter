/// Verifies the permissions declared by the APK that `flutter_android_app`
/// actually produced — read out of the compiled binary `AndroidManifest.xml`
/// inside the APK, not out of the source manifest.
///
/// This is the regression test for the defect where a networked app works in
/// `-c dbg` and is silently offline in release. `flutter create` writes
/// `android.permission.INTERNET` into `android/app/src/debug/
/// AndroidManifest.xml` and nowhere else, and the debug variant is folded
/// into `-c dbg` APKs only. Android enforces INTERNET at the kernel level
/// (AID_INET group membership), so an APK without it cannot open a socket at
/// all — with no build error and no runtime exception.
///
/// `:app` therefore declares the permission through
/// `flutter_android_app(permissions = [...])`, which applies in every
/// compilation mode. Bazel's default `fastbuild` is *not* `-c dbg`, so the
/// APK this test reads takes the non-debug manifest arm: finding INTERNET in
/// it proves the permission came from `permissions` and not from the debug
/// variant overlay.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Permissions the APK must declare regardless of compilation mode.
const _requiredPermissions = <String>{
  'android.permission.INTERNET',
};

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final apkPath = '$testSrcDir/$testWorkspace/app.apk';
  if (!File(apkPath).existsSync()) {
    stderr.writeln('APK not found at $apkPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync(
    'android_permissions_test',
  );
  try {
    final unzip = Process.runSync(
      'unzip',
      ['-q', apkPath, 'AndroidManifest.xml', '-d', tmpDir.path],
    );
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract AndroidManifest.xml: ${unzip.stderr}');
      exit(1);
    }

    final manifest = File('${tmpDir.path}/AndroidManifest.xml');
    final declared = usesPermissions(manifest.readAsBytesSync());

    print(
      'Permissions declared by the APK: '
      '${declared.isEmpty ? '(none)' : declared.join(', ')}',
    );

    final missing = _requiredPermissions.difference(declared);
    if (missing.isNotEmpty) {
      stderr.writeln(
        'FAIL: the APK declares no ${missing.join(', ')}.\n'
        'A release APK whose permission set is missing what the app needs '
        'has no build error and no runtime exception — it just cannot open '
        'a socket. Declare it via flutter_android_app(permissions = [...]), '
        'which applies in every compilation mode.',
      );
      exit(1);
    }

    print('\nAll Android permission checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

// -- Binary XML (AXML) reader -------------------------------------------------
//
// Android compiles AndroidManifest.xml into the resource-chunk format
// documented by AOSP's ResourceTypes.h. Only what this test needs is
// implemented: the string pool, and START_ELEMENT chunks with their
// attributes. Anything unexpected is a hard error rather than a silent
// empty result, so a manifest this reader cannot account for can never be
// mistaken for one that declares no permissions.

const _chunkStringPool = 0x0001;
const _chunkXmlStartElement = 0x0102;
const _typeString = 0x03;

/// The `android:name` values of every `<uses-permission>` /
/// `<uses-permission-sdk-23>` element in a compiled [manifest].
Set<String> usesPermissions(Uint8List manifest) {
  final data = ByteData.sublistView(manifest);
  if (manifest.length < 8) {
    throw const FormatException('AndroidManifest.xml is too short to be AXML');
  }

  List<String>? pool;
  final permissions = <String>{};

  // Walk top-level chunks after the 8-byte file header.
  var offset = data.getUint16(2, Endian.little);
  while (offset + 8 <= manifest.length) {
    final type = data.getUint16(offset, Endian.little);
    final headerSize = data.getUint16(offset + 2, Endian.little);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    if (chunkSize < 8 || offset + chunkSize > manifest.length) {
      throw FormatException(
        'AXML chunk at $offset declares an out-of-range size $chunkSize',
      );
    }

    if (type == _chunkStringPool) {
      pool = _readStringPool(data, manifest, offset);
    } else if (type == _chunkXmlStartElement) {
      if (pool == null) {
        throw const FormatException(
          'AXML START_ELEMENT appears before the string pool',
        );
      }
      final element = _readStartElement(data, offset, headerSize, pool);
      if (element.name == 'uses-permission' ||
          element.name == 'uses-permission-sdk-23') {
        final name = element.attributes['name'];
        if (name == null) {
          throw FormatException(
            'AXML <${element.name}> has no android:name attribute',
          );
        }
        permissions.add(name);
      }
    }

    offset += chunkSize;
  }

  if (pool == null) {
    throw const FormatException('AndroidManifest.xml has no AXML string pool');
  }
  return permissions;
}

class _Element {
  _Element(this.name, this.attributes);

  final String name;
  final Map<String, String> attributes;
}

_Element _readStartElement(
  ByteData data,
  int offset,
  int headerSize,
  List<String> pool,
) {
  String stringAt(int index) =>
      index == 0xFFFFFFFF || index >= pool.length ? '' : pool[index];

  final body = offset + headerSize;
  final nameIndex = data.getUint32(body + 4, Endian.little);
  final attributeStart = data.getUint16(body + 8, Endian.little);
  final attributeSize = data.getUint16(body + 10, Endian.little);
  final attributeCount = data.getUint16(body + 12, Endian.little);

  final attributes = <String, String>{};
  for (var i = 0; i < attributeCount; i++) {
    final at = body + attributeStart + i * attributeSize;
    final attrName = stringAt(data.getUint32(at + 4, Endian.little));
    final rawValue = data.getUint32(at + 8, Endian.little);
    final dataType = data.getUint8(at + 15);
    final typedData = data.getUint32(at + 16, Endian.little);
    if (rawValue != 0xFFFFFFFF) {
      attributes[attrName] = stringAt(rawValue);
    } else if (dataType == _typeString) {
      attributes[attrName] = stringAt(typedData);
    }
  }

  return _Element(stringAt(nameIndex), attributes);
}

List<String> _readStringPool(ByteData data, Uint8List bytes, int offset) {
  final stringCount = data.getUint32(offset + 8, Endian.little);
  final flags = data.getUint32(offset + 16, Endian.little);
  final stringsStart = data.getUint32(offset + 20, Endian.little);
  final isUtf8 = (flags & 0x100) != 0;

  final strings = <String>[];
  for (var i = 0; i < stringCount; i++) {
    final entryOffset = data.getUint32(offset + 28 + i * 4, Endian.little);
    var at = offset + stringsStart + entryOffset;
    if (isUtf8) {
      // Two length prefixes (UTF-16 length, then byte length), each 1 or 2
      // bytes: a leading high bit means the value spans two bytes.
      at = _skipUtf8Length(data, at);
      final (byteLength, contentAt) = _readUtf8Length(data, at);
      strings.add(
        utf8.decode(
          bytes.sublist(contentAt, contentAt + byteLength),
          allowMalformed: true,
        ),
      );
    } else {
      var length = data.getUint16(at, Endian.little);
      at += 2;
      if ((length & 0x8000) != 0) {
        length = ((length & 0x7FFF) << 16) | data.getUint16(at, Endian.little);
        at += 2;
      }
      final units = <int>[
        for (var c = 0; c < length; c++)
          data.getUint16(at + c * 2, Endian.little),
      ];
      strings.add(String.fromCharCodes(units));
    }
  }
  return strings;
}

int _skipUtf8Length(ByteData data, int at) =>
    (data.getUint8(at) & 0x80) != 0 ? at + 2 : at + 1;

(int, int) _readUtf8Length(ByteData data, int at) {
  final first = data.getUint8(at);
  if ((first & 0x80) != 0) {
    return (((first & 0x7F) << 8) | data.getUint8(at + 1), at + 2);
  }
  return (first, at + 1);
}
