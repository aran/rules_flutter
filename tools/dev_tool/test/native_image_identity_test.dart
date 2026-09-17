import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bazel_dev_tool/native_image_identity.dart';
import 'package:test/test.dart';

/// A 64-bit Mach-O with one unrelated load command before `LC_UUID`.
Uint8List machO(List<int> uuid) {
  final bytes = ByteData(32 + 16 + 24);
  bytes.setUint32(0, 0xfeedfacf, Endian.little);
  bytes.setUint32(16, 2, Endian.little); // ncmds
  bytes.setUint32(32, 0x2, Endian.little); // LC_SYMTAB, skipped
  bytes.setUint32(36, 16, Endian.little);
  bytes.setUint32(48, 0x1b, Endian.little); // LC_UUID
  bytes.setUint32(52, 24, Endian.little);
  final out = bytes.buffer.asUint8List();
  out.setRange(56, 72, uuid);
  return out;
}

/// A 64-bit little-endian ELF with one `PT_NOTE` holding an unrelated note and
/// then the GNU build-id.
Uint8List elf64(List<int> id) {
  const phoff = 64;
  const noteAt = phoff + 56;
  final notes = BytesBuilder()
    ..add(_note('XYZ\u0000', 1, [9, 9, 9, 9]))
    ..add(_note('GNU\u0000', 3, id));
  final noteBytes = notes.toBytes();
  final bytes = ByteData(noteAt + noteBytes.length);
  final out = bytes.buffer.asUint8List();
  out.setRange(0, 4, [0x7f, 0x45, 0x4c, 0x46]);
  out[4] = 2; // ELFCLASS64
  out[5] = 1; // little-endian
  bytes.setUint64(0x20, phoff, Endian.little);
  bytes.setUint16(0x36, 56, Endian.little);
  bytes.setUint16(0x38, 1, Endian.little);
  bytes.setUint32(phoff, 4, Endian.little); // PT_NOTE
  bytes.setUint64(phoff + 0x08, noteAt, Endian.little);
  bytes.setUint64(phoff + 0x20, noteBytes.length, Endian.little);
  out.setRange(noteAt, noteAt + noteBytes.length, noteBytes);
  return out;
}

List<int> _note(String name, int type, List<int> desc) {
  List<int> padded(List<int> b) => [
    ...b,
    ...List.filled((4 - b.length % 4) % 4, 0),
  ];
  final header = ByteData(12)
    ..setUint32(0, name.length, Endian.little)
    ..setUint32(4, desc.length, Endian.little)
    ..setUint32(8, type, Endian.little);
  return [
    ...header.buffer.asUint8List(),
    ...padded(name.codeUnits),
    ...padded(desc),
  ];
}

void main() {
  test('a Mach-O is identified by its LC_UUID', () {
    expect(
      nativeImageIdentity(machO(List.generate(16, (i) => i))),
      'uuid:000102030405060708090a0b0c0d0e0f',
    );
  });

  test('an ELF is identified by its GNU build-id note', () {
    expect(
      nativeImageIdentity(elf64([0xde, 0xad, 0xbe, 0xef, 1])),
      'build-id:deadbeef01',
    );
  });

  test('an image with no identity, or no image at all, has none', () {
    final noUuid = machO(List.filled(16, 0));
    ByteData.sublistView(noUuid).setUint32(48, 0x19, Endian.little);
    expect(nativeImageIdentity(noUuid), isNull);
    expect(
      nativeImageIdentity(Uint8List.fromList('#!/bin/sh'.codeUnits)),
      isNull,
    );
    expect(nativeImageIdentity(Uint8List(0)), isNull);
  });

  group('a bundled file', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nii_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('is read out of a bundle directory', () async {
      final app = Directory('${tmp.path}/a.app/Contents/Frameworks')
        ..createSync(recursive: true);
      File(
        '${app.path}/libx.dylib',
      ).writeAsBytesSync(machO(List.filled(16, 7)));
      expect(
        nativeImageIdentity(
          await readBundledFile(
            '${tmp.path}/a.app',
            'Contents/Frameworks/libx.dylib',
          ),
        ),
        'uuid:${'07' * 16}',
      );
    });

    // An APK stores libraries uncompressed and an .ipa deflates them; both
    // are read.
    for (final (compression, flag) in [('stored', '-0'), ('deflated', '-9')]) {
      test('is read out of a $compression zip entry', () async {
        final lib = Directory('${tmp.path}/z/lib/arm64-v8a')
          ..createSync(recursive: true);
        // Repetitive enough that deflate really compresses it.
        final image = elf64(List.filled(20, 0xab));
        final padded = Uint8List.fromList([...image, ...List.filled(4096, 0)]);
        File('${lib.path}/libx.so').writeAsBytesSync(padded);
        File('${lib.path}/other.txt').writeAsStringSync('first');
        final r = await Process.run('zip', [
          '-q',
          flag,
          '-r',
          '${tmp.path}/app.apk',
          'lib',
        ], workingDirectory: '${tmp.path}/z');
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final bytes = await readBundledFile(
          '${tmp.path}/app.apk',
          'lib/arm64-v8a/libx.so',
        );
        expect(bytes, padded);
        expect(nativeImageIdentity(bytes), 'build-id:${'ab' * 20}');
      });
    }

    test('names a missing zip entry', () async {
      File('${tmp.path}/a.txt').writeAsStringSync('x');
      await Process.run('zip', [
        '-q',
        '${tmp.path}/app.ipa',
        'a.txt',
      ], workingDirectory: tmp.path);
      await expectLater(
        readBundledFile('${tmp.path}/app.ipa', 'Payload/x.app/x'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('has no entry Payload/x.app/x'),
          ),
        ),
      );
    });
  });
}
