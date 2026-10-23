import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../apk_overlay.dart';
import '../xtool_pack.dart'
    show ZipEntry, encodeDeterministicZip, readZipRawEntries;

// A 50-byte text whose level-9 sizes straddle the aapt2 tenth line: C zlib
// reports 46 bytes (46 + 46 ~/ 10 == 50, so the reference deflates it) while
// Dart's own level 9 reports 48 (48 + 48 ~/ 10 > 50, stored). Any estimator
// other than the ported level 9 gets this entry's method wrong.
const String _estimatorTrap =
    'boundary method compression entry engine zip entry';

// Same bytes as the hello_world e2e fixture: 36 bytes raw, 35 deflated at
// level 9, so the reference stores it (35 + 35 ~/ 10 > 36) while a
// deflate-when-smaller rule would deflate it.
const String _marginalSmall = 'too close to the boundary to shrink\n';

void main() {
  group('aaptDeflates tenth line', () {
    test('stores entries whose deflated form saves nothing', () {
      expect(aaptDeflates(compressedSize: 100, rawSize: 100), isFalse);
      expect(aaptDeflates(compressedSize: 101, rawSize: 100), isFalse);
      expect(aaptDeflates(compressedSize: 2, rawSize: 0), isFalse);
    });

    test('stores savings of one or a few bytes', () {
      expect(aaptDeflates(compressedSize: 99, rawSize: 100), isFalse);
      expect(aaptDeflates(compressedSize: 95, rawSize: 100), isFalse);
      expect(aaptDeflates(compressedSize: 35, rawSize: 36), isFalse);
    });

    test('deflates exactly when a tenth of itself is saved', () {
      expect(aaptDeflates(compressedSize: 100, rawSize: 110), isTrue);
      expect(aaptDeflates(compressedSize: 100, rawSize: 111), isTrue);
      expect(aaptDeflates(compressedSize: 90, rawSize: 99), isTrue);
      expect(aaptDeflates(compressedSize: 100, rawSize: 109), isFalse);
      expect(aaptDeflates(compressedSize: 90, rawSize: 98), isFalse);
    });
  });

  group('aaptDeflatedSize level-9 probe', () {
    test('matches C zlib on the estimator-trap vector', () {
      final data = Uint8List.fromList(utf8.encode(_estimatorTrap));
      expect(data.length, 50);
      expect(aaptDeflatedSize(data), 46);
      expect(aaptDeflates(compressedSize: 46, rawSize: 50), isTrue);
    });

    test('matches C zlib on the marginal e2e vectors', () {
      final small = Uint8List.fromList(utf8.encode(_marginalSmall));
      expect(small.length, 36);
      expect(aaptDeflatedSize(small), 35);
      expect(aaptDeflates(compressedSize: 35, rawSize: 36), isFalse);
    });
  });

  group('spliceApkOverlay entry methods', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('apk_overlay_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    Map<String, int> spliceMethods({
      required Map<String, Uint8List> assets,
      required List<ZipEntry> jarEntries,
    }) {
      final basePath = '${tempDir.path}/base.apk';
      File(basePath).writeAsBytesSync(
        encodeDeterministicZip([
          ZipEntry(
            path: 'AndroidManifest.xml',
            data: Uint8List.fromList([1]),
          ),
        ]),
      );
      final jarPath = '${tempDir.path}/native_libs.jar';
      File(jarPath).writeAsBytesSync(encodeDeterministicZip(jarEntries));
      final assetsDir = Directory('${tempDir.path}/flutter_assets')
        ..createSync();
      for (final entry in assets.entries) {
        File('${assetsDir.path}/${entry.key}').writeAsBytesSync(entry.value);
      }
      final outPath = '${tempDir.path}/out.apk';
      spliceApkOverlay(
        baseApkPath: basePath,
        nativeLibsJarPath: jarPath,
        flutterAssetsDirPath: assetsDir.path,
        outputApkPath: outPath,
      );
      return {
        for (final e in readZipRawEntries(File(outPath).readAsBytesSync()))
          e.path: e.method,
      };
    }

    test('stores marginally compressible assets the reference stores', () {
      final methods = spliceMethods(
        assets: {
          'marginal_small.txt': Uint8List.fromList(utf8.encode(_marginalSmall)),
          'plain.txt': Uint8List.fromList(List<int>.filled(1000, 7)),
          'logo.png': Uint8List.fromList(List<int>.filled(10000, 7)),
        },
        jarEntries: [
          ZipEntry(
            path: 'lib/arm64-v8a/libapp.so',
            data: Uint8List.fromList([0x7f, 0x45, 0x4c, 0x46, 1, 2, 3]),
            storeOnly: true,
          ),
        ],
      );
      expect(
        methods['assets/flutter_assets/marginal_small.txt'],
        0,
        reason: '35 bytes saved of 36 stay stored under the tenth line',
      );
      expect(methods['assets/flutter_assets/plain.txt'], 8);
      expect(methods['assets/flutter_assets/logo.png'], 0);
      expect(methods['lib/arm64-v8a/libapp.so'], 0);
    });

    test('deflates the estimator-trap vector the reference deflates', () {
      final methods = spliceMethods(
        assets: {
          'trap.txt': Uint8List.fromList(utf8.encode(_estimatorTrap)),
        },
        jarEntries: const [],
      );
      expect(
        methods['assets/flutter_assets/trap.txt'],
        8,
        reason: '46 + 46 ~/ 10 == 50 clears the tenth line',
      );
    });
  });

  group('aaptDecisionSize fast path', () {
    test('fast decisions match the exact port over the fuzz corpus', () {
      var checked = 0;
      for (final data in _decisionCorpus()) {
        final fastSize = ZLibEncoder(raw: true).convert(data).length;
        final fast = aaptDeflates(
          compressedSize: aaptDecisionSize(data, fastSize),
          rawSize: data.length,
        );
        final exact = aaptDeflates(
          compressedSize: aaptDeflatedSize(data),
          rawSize: data.length,
        );
        expect(
          fast,
          exact,
          reason:
              'raw=${data.length} fastSize=$fastSize '
              'exact=${aaptDeflatedSize(data)}',
        );
        checked++;
      }
      expect(checked, greaterThan(200));
    });
  });
}

/// Deterministic hostile corpus for the fast-path parity check: every size
/// from empty to 100 KB across fills, random alphabets, periods, text and
/// sparse patterns, seeded so the run is reproducible.
Iterable<Uint8List> _decisionCorpus() sync* {
  const sizes = [
    0,
    1,
    2,
    3,
    4,
    5,
    7,
    8,
    9,
    15,
    16,
    17,
    19,
    23,
    24,
    25,
    31,
    32,
    33,
    36,
    50,
    56,
    57,
    60,
    63,
    64,
    65,
    100,
    127,
    128,
    129,
    150,
    200,
    220,
    242,
    255,
    256,
    257,
    300,
    512,
    1000,
    1024,
    2048,
    4095,
    4096,
    4097,
    5000,
    8192,
    16384,
    32768,
    65536,
    100000,
  ];
  final text = utf8.encode('boundary method compression entry engine ');
  for (final size in sizes) {
    final random = Random(0xA47A9 + size);
    final patterns = <Uint8List>[
      Uint8List(size),
      Uint8List.fromList(List<int>.filled(size, 0xFF)),
      Uint8List.fromList(
        List<int>.generate(size, (_) => random.nextInt(256)),
      ),
      Uint8List.fromList(
        List<int>.generate(size, (_) => random.nextInt(16)),
      ),
      Uint8List.fromList(
        List<int>.generate(size, (_) => random.nextInt(4)),
      ),
      Uint8List.fromList(
        List<int>.generate(size, (i) => text[i % text.length]),
      ),
      Uint8List.fromList(
        List<int>.generate(size, (i) => i % 251),
      ),
      Uint8List.fromList(
        List<int>.generate(
          size,
          (i) => i % 32 == 0 ? random.nextInt(256) : 0,
        ),
      ),
    ];
    // Keep the big end of the corpus cheap: two patterns past 32 KB.
    yield* (size > 32768 ? patterns.sublist(2, 4) : patterns);
  }
}
