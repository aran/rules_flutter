import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'zip_fixture.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('zip_fixture_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Lays out [files] (archive-relative path to bytes) under a `tree/`
  /// directory and zips it the way the fixture tests do.
  String makeZip(Map<String, List<int>> files, {bool deflate = true}) {
    final root = Directory('${tmp.path}/tree')..createSync(recursive: true);
    for (final entry in files.entries) {
      final file = File('${root.path}/${entry.key}')
        ..parent.createSync(recursive: true);
      file.writeAsBytesSync(entry.value);
    }
    final out = '${tmp.path}/out.zip';
    writeTestZip(outPath: out, root: tmp, member: 'tree', deflate: deflate);
    return out;
  }

  /// Start of the central directory of [zip], which this helper wrote with no
  /// comment, so the end record is the last 22 bytes.
  int centralStart(Uint8List zip) =>
      ByteData.sublistView(zip).getUint32(zip.length - 22 + 16, Endian.little);

  /// Start of the central record for the single file under `tree/`: past the
  /// end record scan, then past the `tree/` directory record (46 + 5 bytes).
  int fileCentral(Uint8List zip) => centralStart(zip) + 46 + 'tree/'.length;

  /// A copy of the zip at [path] with [patch] applied to its raw bytes, for
  /// corrupting or hand-crafting single fields.
  String rezip(String path, String name, void Function(Uint8List) patch) {
    final bytes = Uint8List.fromList(File(path).readAsBytesSync());
    patch(bytes);
    final out = '${tmp.path}/$name';
    File(out).writeAsBytesSync(bytes);
    return out;
  }

  test(
    'stored entries round-trip with names, contents and directories',
    () async {
      Directory('${tmp.path}/tree/empty').createSync(recursive: true);
      final zip = makeZip({
        'a.txt': 'hello'.codeUnits,
        'dir/b.bin': List.generate(256, (i) => i),
      }, deflate: false);
      final out = Directory('${tmp.path}/out')..createSync();
      await extractZip(zipPath: zip, destDir: out);
      expect(File('${out.path}/tree/a.txt').readAsStringSync(), 'hello');
      expect(
        File('${out.path}/tree/dir/b.bin').readAsBytesSync(),
        List.generate(256, (i) => i),
      );
      expect(Directory('${out.path}/tree/empty').existsSync(), isTrue);
    },
  );

  test('a deflated entry round-trips', () async {
    final content = List.filled(8192, 0xab);
    final zip = makeZip({'big.bin': content});
    final raw = File(zip).readAsBytesSync();
    final view = ByteData.sublistView(raw);
    final methods = <int>[];
    var at = 0;
    while (view.getUint32(at, Endian.little) == 0x04034b50) {
      methods.add(view.getUint16(at + 8, Endian.little));
      at +=
          30 +
          view.getUint16(at + 26, Endian.little) +
          view.getUint16(at + 28, Endian.little) +
          view.getUint32(at + 18, Endian.little);
    }
    expect(
      methods,
      contains(8),
      reason: 'the repetitive fixture must actually exercise inflate',
    );
    final out = Directory('${tmp.path}/out')..createSync();
    await extractZip(zipPath: zip, destDir: out);
    expect(File('${out.path}/tree/big.bin').readAsBytesSync(), content);
  });

  test(
    'an entry whose CRC does not match is refused, writing nothing',
    () async {
      final zip = makeZip({'a.txt': 'hello world'.codeUnits}, deflate: false);
      // First payload byte of the file entry: past the `tree/` directory
      // record (30 + 5 bytes), then its 30-byte local header and name.
      const entryName = 'tree/a.txt';
      final bad = rezip(zip, 'bad.zip', (bytes) {
        bytes[35 + 30 + entryName.length] ^= 0xFF;
      });
      final out = Directory('${tmp.path}/out');
      await expectLater(
        extractZip(zipPath: bad, destDir: out),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('CRC mismatch'),
          ),
        ),
      );
      expect(out.existsSync(), isFalse);
    },
  );

  test('an unknown compression method is refused', () async {
    final zip = makeZip({
      'a.txt': [1, 2, 3],
    }, deflate: false);
    final bad = rezip(zip, 'bad.zip', (bytes) {
      final view = ByteData.sublistView(bytes);
      // File entry: past the `tree/` directory record (35 bytes).
      view.setUint16(35 + 8, 99, Endian.little);
      view.setUint16(fileCentral(bytes) + 10, 99, Endian.little);
    });
    await expectLater(
      extractZip(
        zipPath: bad,
        destDir: Directory('${tmp.path}/out'),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('method 99'),
        ),
      ),
    );
  });

  test('a data descriptor is refused', () async {
    final zip = makeZip({
      'a.txt': [1, 2, 3],
    }, deflate: false);
    final bad = rezip(zip, 'bad.zip', (bytes) {
      final view = ByteData.sublistView(bytes);
      const localFlags = 35 + 6;
      view.setUint16(
        localFlags,
        view.getUint16(localFlags, Endian.little) | 0x08,
        Endian.little,
      );
      final central = fileCentral(bytes);
      view.setUint16(
        central + 8,
        view.getUint16(central + 8, Endian.little) | 0x08,
        Endian.little,
      );
    });
    await expectLater(
      extractZip(
        zipPath: bad,
        destDir: Directory('${tmp.path}/out'),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('data descriptor'),
        ),
      ),
    );
  });

  test('an archived executable mode is restored', () async {
    final zip = makeZip({'run.sh': '#!/bin/sh\n'.codeUnits}, deflate: false);
    final exec = rezip(zip, 'exec.zip', (bytes) {
      ByteData.sublistView(
        bytes,
      ).setUint32(fileCentral(bytes) + 38, (0x81ED << 16), Endian.little);
    });
    final out = Directory('${tmp.path}/out')..createSync();
    await extractZip(zipPath: exec, destDir: out);
    expect(
      FileStat.statSync('${out.path}/tree/run.sh').mode & 0x100,
      isNot(0),
      reason: 'the owner-execute bit must survive the round trip',
    );
  });

  test('a symlink entry is restored as a link', () async {
    final zip = makeZip({'link': 'real.txt'.codeUnits}, deflate: false);
    final linked = rezip(zip, 'linked.zip', (bytes) {
      ByteData.sublistView(
        bytes,
      ).setUint32(fileCentral(bytes) + 38, (0xA1FF << 16), Endian.little);
    });
    final out = Directory('${tmp.path}/out')..createSync();
    await extractZip(zipPath: linked, destDir: out);
    expect(
      FileSystemEntity.typeSync(
        '${out.path}/tree/link',
        followLinks: false,
      ),
      FileSystemEntityType.link,
    );
    expect(Link('${out.path}/tree/link').targetSync(), 'real.txt');
  });

  test('a parent path is refused', () async {
    const name = 'tree/dir/f.txt';
    // A same-length escape keeps every header aligned.
    const evil = '../../../../x.';
    assert(evil.length == name.length);
    final zip = makeZip({
      'dir/f.txt': [1],
    }, deflate: false);
    final bad = rezip(zip, 'bad.zip', (bytes) {
      bytes.setRange(35 + 30, 35 + 30 + name.length, evil.codeUnits);
      final central = fileCentral(bytes);
      bytes.setRange(
        central + 46,
        central + 46 + name.length,
        evil.codeUnits,
      );
    });
    await expectLater(
      extractZip(
        zipPath: bad,
        destDir: Directory('${tmp.path}/out'),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('..'),
        ),
      ),
    );
  });
}
