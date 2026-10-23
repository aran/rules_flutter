import 'dart:io';
import 'dart:typed_data';

import 'dart:convert';

import 'package:test/test.dart';

import '../android_bundle.dart';
import '../xtool_pack.dart'
    show
        ZipEntry,
        crc32,
        encodeDeterministicZip,
        readZipEntries,
        readZipRawEntries;

Uint8List _syntheticElf({required int machine, List<int> payload = const []}) {
  final header = Uint8List(20 + payload.length);
  header[0] = 0x7f;
  header[1] = 0x45; // 'E'
  header[2] = 0x4c; // 'L'
  header[3] = 0x46; // 'F'
  header[4] = 2; // ELFCLASS64
  header[5] = 1; // ELFDATA2LSB
  header[6] = 1; // EV_CURRENT
  header[16] = 3; // ET_DYN
  header[18] = machine & 0xff;
  header[19] = (machine >> 8) & 0xff;
  for (var i = 0; i < payload.length; i++) {
    header[20 + i] = payload[i];
  }
  return header;
}

void main() {
  group('android_bundle', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('android_bundle_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    group('empty-jar', () {
      test(
        'writes the exact 22-byte empty ZIP End of Central Directory record',
        () async {
          final outJar = '${tempDir.path}/empty_native_libs.jar';
          await runAndroidBundle(['empty-jar', '--output', outJar]);

          final bytes = File(outJar).readAsBytesSync();
          expect(bytes, equals(emptyJarBytes));
          expect(bytes.length, 22);
          expect(bytes.sublist(0, 4), [0x50, 0x4b, 0x05, 0x06]);
          expect(bytes.sublist(4), everyElement(0));
        },
      );
    });

    group('validateAndroidElf & native-libs-jar', () {
      test('accepts valid arm64-v8a (EM_AARCH64 = 183) and x86_64 (EM_X86_64 = 62) ELF headers', () {
        expect(
          () => validateAndroidElf(
            _syntheticElf(machine: 183),
            path: 'libapp.so',
            wantMachine: 183,
            abi: 'arm64-v8a',
          ),
          returnsNormally,
        );
        expect(
          () => validateAndroidElf(
            _syntheticElf(machine: 62),
            path: 'libapp.so',
            wantMachine: 62,
            abi: 'x86_64',
          ),
          returnsNormally,
        );
      });

      test('rejects non-ELF files with the exact error message', () {
        final machoBytes = <int>[
          0xcf,
          0xfa,
          0xed,
          0xfe,
          ...List<int>.filled(20, 0),
        ];
        expect(
          () => validateAndroidElf(
            machoBytes,
            path: 'libfoo.dylib',
            wantMachine: 183,
            abi: 'arm64-v8a',
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'ERROR: libfoo.dylib is not an ELF binary. Android (arm64-v8a) cannot load it.',
            ),
          ),
        );
      });

      test('rejects truncated files shorter than 20 bytes', () {
        expect(
          () => validateAndroidElf(
            [0x7f, 0x45, 0x4c, 0x46, 1, 2, 3],
            path: 'short.so',
            wantMachine: 183,
            abi: 'arm64-v8a',
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'ERROR: short.so is not an ELF binary. Android (arm64-v8a) cannot load it.',
            ),
          ),
        );
      });

      test('rejects wrong ELF machine with the exact error message', () {
        expect(
          () => validateAndroidElf(
            _syntheticElf(machine: 62),
            path: 'libx64.so',
            wantMachine: 183,
            abi: 'arm64-v8a',
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'ERROR: libx64.so has ELF machine 62; arm64-v8a requires 183.',
            ),
          ),
        );
      });

      test(
        'invokes zipper with cC and entry mappings after ELF validation passes',
        () async {
          final libApp = File('${tempDir.path}/libapp.so')
            ..writeAsBytesSync(_syntheticElf(machine: 183, payload: [1, 2, 3]));
          final libPlugin = File('${tempDir.path}/libplugin.so')
            ..writeAsBytesSync(_syntheticElf(machine: 183, payload: [4, 5, 6]));
          final outJar = '${tempDir.path}/out.jar';
          final fakeZipperLog = '${tempDir.path}/zipper_args.txt';
          final fakeZipper = File('${tempDir.path}/fake_zipper.sh')
            ..writeAsStringSync(
              '#!/bin/sh\n'
              'printf "%s\\n" "\$@" > "$fakeZipperLog"\n'
              'printf "JAR_BYTES" > "\$2"\n',
            );
          await Process.run('chmod', ['+x', fakeZipper.path]);

          await runAndroidBundle([
            'native-libs-jar',
            '--output',
            outJar,
            '--abi',
            'arm64-v8a',
            '--machine',
            '183',
            '--zipper',
            fakeZipper.path,
            'lib/arm64-v8a/libapp.so=${libApp.path}',
            'lib/arm64-v8a/libplugin.so=${libPlugin.path}',
          ]);

          expect(File(outJar).existsSync(), isTrue);
          expect(File(outJar).lengthSync(), greaterThan(0));
          final readEntries = readZipEntries(File(outJar).readAsBytesSync());
          expect(readEntries.map((e) => e.path).toList(), [
            'lib/arm64-v8a/libapp.so',
            'lib/arm64-v8a/libplugin.so',
          ]);
        },
        testOn: '!windows',
      );

      // Libraries over 64 MiB: the jar writer stores `.so` files instead of
      // deflating them, so they pass through the overlay without ever being
      // inflated, at any size below the ZIP32 limits. 65 MiB sits just past
      // the old 64 MiB streaming wall.
      String writeBigElf(String name, {required bool compressible}) {
        const size = 65 * 1024 * 1024;
        final body = Uint8List(size);
        if (compressible) {
          body.fillRange(0, body.length, 7);
        } else {
          // xorshift32: deterministic, and its output defeats deflate.
          var x = 0x12345678;
          for (var i = 0; i < body.length; i++) {
            x ^= (x << 13) & 0xFFFFFFFF;
            x ^= x >> 17;
            x ^= (x << 5) & 0xFFFFFFFF;
            body[i] = x & 0xFF;
          }
        }
        final path = '${tempDir.path}/$name';
        final staged = BytesBuilder(copy: false)
          ..add(_syntheticElf(machine: 183))
          ..add(body);
        File(path).writeAsBytesSync(staged.takeBytes(), flush: true);
        return path;
      }

      Future<String> jarOf(String libPath, String entry) async {
        final jarPath = '${tempDir.path}/big_native_libs.jar';
        await runAndroidBundle([
          'native-libs-jar',
          '--output',
          jarPath,
          '--abi',
          'arm64-v8a',
          '--machine',
          '183',
          '$entry=$libPath',
        ]);
        return jarPath;
      }

      test('stores a compressible native library larger than 64 MiB', () async {
        final libPath = writeBigElf('big_compressible.so', compressible: true);
        final original = File(libPath).readAsBytesSync();
        expect(original.length, greaterThan(64 * 1024 * 1024));

        final jarPath = await jarOf(libPath, 'lib/arm64-v8a/libbig.so');
        final raw = readZipRawEntries(File(jarPath).readAsBytesSync());
        expect(raw.map((e) => e.path), ['lib/arm64-v8a/libbig.so']);
        expect(raw.single.method, 0);
        expect(raw.single.rawData.length, original.length);
        expect(raw.single.crc, crc32(original));

        final inflated = readZipEntries(File(jarPath).readAsBytesSync());
        expect(inflated.single.data, original);
      });

      test(
        'stores an incompressible native library larger than 64 MiB',
        () async {
          final libPath = writeBigElf(
            'big_incompressible.so',
            compressible: false,
          );
          final original = File(libPath).readAsBytesSync();
          expect(original.length, greaterThan(64 * 1024 * 1024));

          final jarPath = await jarOf(libPath, 'lib/arm64-v8a/libbig.so');
          final raw = readZipRawEntries(File(jarPath).readAsBytesSync());
          expect(raw.single.method, 0);
          expect(raw.single.rawData.length, original.length);
          expect(raw.single.crc, crc32(original));

          final inflated = readZipEntries(File(jarPath).readAsBytesSync());
          expect(inflated.single.data, original);
        },
      );
    });

    group('debug-assets', () {
      test('copies flutter_assets dereferencing symlinks and stages kernel and VM snapshots', () async {
        final assetsDir = Directory('${tempDir.path}/flutter_assets')
          ..createSync();
        File('${assetsDir.path}/AssetManifest.bin')
            .writeAsStringSync('manifest');
        final nestedDir = Directory('${assetsDir.path}/packages/pkg')
          ..createSync(recursive: true);
        File('${nestedDir.path}/data.txt').writeAsStringSync('pkg-data');

        // Symlinked file inside flutter_assets to verify cp -RL equivalence.
        final externalTarget = File('${tempDir.path}/external_font.ttf')
          ..writeAsStringSync('font-bytes');
        Link('${assetsDir.path}/linked_font.ttf')
            .createSync(externalTarget.path);

        final kernel = File('${tempDir.path}/app.dill')
          ..writeAsStringSync('kernel-bytes');
        final vmSnap = File('${tempDir.path}/vm_isolate_snapshot.bin')
          ..writeAsStringSync('vm-snap-bytes');
        final isoSnap = File('${tempDir.path}/isolate_snapshot.bin')
          ..writeAsStringSync('iso-snap-bytes');
        final outDir = '${tempDir.path}/debug_flutter_assets';

        await runAndroidBundle([
          'debug-assets',
          '--assets-dir',
          assetsDir.path,
          '--output-dir',
          outDir,
          '--kernel',
          kernel.path,
          '--vm-snapshot',
          vmSnap.path,
          '--isolate-snapshot',
          isoSnap.path,
        ]);

        expect(
          File('$outDir/AssetManifest.bin').readAsStringSync(),
          'manifest',
        );
        expect(
          File('$outDir/packages/pkg/data.txt').readAsStringSync(),
          'pkg-data',
        );
        final copiedFont = File('$outDir/linked_font.ttf');
        expect(copiedFont.existsSync(), isTrue);
        expect(
          FileSystemEntity.isLinkSync('$outDir/linked_font.ttf'),
          isFalse,
        );
        expect(copiedFont.readAsStringSync(), 'font-bytes');
        expect(
          File('$outDir/kernel_blob.bin').readAsStringSync(),
          'kernel-bytes',
        );
        expect(
          File('$outDir/vm_snapshot_data').readAsStringSync(),
          'vm-snap-bytes',
        );
        expect(
          File('$outDir/isolate_snapshot_data').readAsStringSync(),
          'iso-snap-bytes',
        );
      }, testOn: '!windows');
    });

    group('apk-overlay', () {
      // Test-local central directory reader: maps each entry path to its
      // compression method, and reports the central directory offset.
      ({Map<String, int> methods, int cdOffset}) readCentralForTest(
        Uint8List bytes,
      ) {
        final bd = ByteData.sublistView(bytes);
        var eocd = -1;
        for (var i = bytes.length - 22; i >= 0; i--) {
          if (bd.getUint32(i, Endian.little) == 0x06054b50) {
            eocd = i;
            break;
          }
        }
        expect(eocd, isNot(equals(-1)));
        final count = bd.getUint16(eocd + 8, Endian.little);
        final cdOffset = bd.getUint32(eocd + 16, Endian.little);
        final methods = <String, int>{};
        var pos = cdOffset;
        for (var i = 0; i < count; i++) {
          expect(bd.getUint32(pos, Endian.little), 0x02014b50);
          final method = bd.getUint16(pos + 10, Endian.little);
          final nameLen = bd.getUint16(pos + 28, Endian.little);
          final extraLen = bd.getUint16(pos + 30, Endian.little);
          final commentLen = bd.getUint16(pos + 32, Endian.little);
          methods[utf8.decode(bytes.sublist(pos + 46, pos + 46 + nameLen))] =
              method;
          pos += 46 + nameLen + extraLen + commentLen;
        }
        return (methods: methods, cdOffset: cdOffset);
      }

      Future<String> writeBaseApk(List<ZipEntry> entries) async {
        final path = '${tempDir.path}/base_unsigned.apk';
        File(path).writeAsBytesSync(encodeDeterministicZip(entries));
        return path;
      }

      // Builds a minimal zip holding one stored entry with bit 3 (data
      // descriptor) set and zeroed local size fields, the way singlejar
      // emits the merged classes.dex entries of a real unsigned APK.
      Uint8List zipWithDescriptorEntry(String path, Uint8List data) {
        final name = utf8.encode(path);
        final crc = crc32(data);
        final u16 = (BytesBuilder b, int v) =>
            b.add([v & 0xff, (v >> 8) & 0xff]);
        final u32 = (BytesBuilder b, int v) => b.add([
          v & 0xff,
          (v >> 8) & 0xff,
          (v >> 16) & 0xff,
          (v >> 24) & 0xff,
        ]);
        final local = BytesBuilder(copy: false);
        u32(local, 0x04034b50);
        u16(local, 20);
        u16(local, 0x0808);
        u16(local, 0);
        u16(local, 0);
        u16(local, 0x3C21);
        u32(local, 0);
        u32(local, 0);
        u32(local, 0);
        u16(local, name.length);
        u16(local, 0);
        local.add(name);
        local.add(data);
        u32(local, crc);
        u32(local, data.length);
        u32(local, data.length);
        final localBytes = local.takeBytes();
        final central = BytesBuilder(copy: false);
        u32(central, 0x02014b50);
        u16(central, (3 << 8) | 20);
        u16(central, 20);
        u16(central, 0x0808);
        u16(central, 0);
        u16(central, 0);
        u16(central, 0x3C21);
        u32(central, crc);
        u32(central, data.length);
        u32(central, data.length);
        u16(central, name.length);
        u16(central, 0);
        u16(central, 0);
        u16(central, 0);
        u16(central, 0);
        u32(central, 0x81A40000);
        u32(central, 0);
        central.add(name);
        final centralBytes = central.takeBytes();
        final eocd = BytesBuilder(copy: false);
        u32(eocd, 0x06054b50);
        u16(eocd, 0);
        u16(eocd, 0);
        u16(eocd, 1);
        u16(eocd, 1);
        u32(eocd, centralBytes.length);
        u32(eocd, localBytes.length);
        u16(eocd, 0);
        final out = BytesBuilder(copy: false)
          ..add(localBytes)
          ..add(centralBytes)
          ..add(eocd.takeBytes());
        return out.takeBytes();
      }

      Future<String> writeNativeLibsJar() async {
        final libApp = File('${tempDir.path}/libapp.so')
          ..writeAsBytesSync(_syntheticElf(machine: 183, payload: [1, 2, 3]));
        final jarPath = '${tempDir.path}/native_libs.jar';
        await runAndroidBundle([
          'native-libs-jar',
          '--output',
          jarPath,
          '--abi',
          'arm64-v8a',
          '--machine',
          '183',
          'lib/arm64-v8a/libapp.so=${libApp.path}',
        ]);
        return jarPath;
      }

      String writeFlutterAssets() {
        final assetsDir = Directory('${tempDir.path}/flutter_assets')
          ..createSync();
        File('${assetsDir.path}/AssetManifest.json').writeAsStringSync(
          '{"assets": ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}',
        );
        File('${assetsDir.path}/logo.png').writeAsBytesSync(
          // Highly compressible bytes: stored anyway, since aapt2 leaves
          // .png uncompressed by default.
          List<int>.filled(10000, 7),
        );
        return assetsDir.path;
      }

      Map<String, List<int>> entriesByPath(String apkPath) {
        return {
          for (final e in readZipEntries(File(apkPath).readAsBytesSync()))
            e.path: e.data.toList(),
        };
      }

      test(
        'injects stored .so and assets preserving every base byte',
        () async {
          final baseEntries = [
            ZipEntry(
              path: 'AndroidManifest.xml',
              data: Uint8List.fromList([9, 8, 7]),
            ),
            // A bare MANIFEST.MF is normal singlejar output, not a
            // signature: it must pass through untouched.
            ZipEntry(
              path: 'META-INF/MANIFEST.MF',
              data: Uint8List.fromList([77, 79, 84]),
            ),
            ZipEntry(
              path: 'classes.dex',
              data: Uint8List.fromList(List<int>.filled(10000, 7)),
            ),
            ZipEntry(
              path: 'lib/arm64-v8a/libflutter.so',
              data: Uint8List.fromList(List<int>.filled(1000, 3)),
            ),
            ZipEntry(
              path: 'resources.arsc',
              data: Uint8List.fromList([1, 2]),
            ),
          ];
          final basePath = await writeBaseApk(baseEntries);
          final baseBytes = File(basePath).readAsBytesSync();
          final jarPath = await writeNativeLibsJar();
          final assetsPath = writeFlutterAssets();
          final outPath = '${tempDir.path}/overlay_unsigned.apk';

          await runAndroidBundle([
            'apk-overlay',
            '--base',
            basePath,
            '--native-libs-jar',
            jarPath,
            '--flutter-assets',
            assetsPath,
            '--output',
            outPath,
          ]);

          final outBytes = File(outPath).readAsBytesSync();
          final outEntries = entriesByPath(outPath);

          // Every base entry keeps its exact content.
          for (final entry in baseEntries) {
            expect(outEntries[entry.path], equals(entry.data.toList()));
          }
          // Payload entries land at the flutter-tool paths with exact content.
          expect(
            outEntries['lib/arm64-v8a/libapp.so'],
            equals(_syntheticElf(machine: 183, payload: [1, 2, 3]).toList()),
          );
          expect(
            outEntries['assets/flutter_assets/AssetManifest.json'],
            equals(
              utf8.encode(
                '{"assets": ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}',
              ),
            ),
          );
          expect(
            outEntries['assets/flutter_assets/logo.png'],
            equals(List<int>.filled(10000, 7)),
          );

          // Base local file sections are preserved byte-for-byte: the output
          // starts with the base bytes up to the base central directory.
          final baseCentralOffset = readCentralForTest(baseBytes).cdOffset;
          expect(
            outBytes.sublist(0, baseCentralOffset),
            equals(baseBytes.sublist(0, baseCentralOffset)),
          );
        },
      );

      test(
        'stores .so and aapt2 no-compress extensions, deflates the rest',
        () async {
          final basePath = await writeBaseApk([
            ZipEntry(
              path: 'AndroidManifest.xml',
              data: Uint8List.fromList([1]),
            ),
          ]);
          final jarPath = await writeNativeLibsJar();
          final assetsPath = writeFlutterAssets();
          final outPath = '${tempDir.path}/overlay_methods.apk';

          await runAndroidBundle([
            'apk-overlay',
            '--base',
            basePath,
            '--native-libs-jar',
            jarPath,
            '--flutter-assets',
            assetsPath,
            '--output',
            outPath,
          ]);

          final methods = readCentralForTest(File(outPath).readAsBytesSync())
              .methods;
          expect(methods['lib/arm64-v8a/libapp.so'], 0);
          expect(methods['assets/flutter_assets/logo.png'], 0);
          expect(methods['assets/flutter_assets/AssetManifest.json'], 8);
        },
      );

      test(
        'stores user nocompress extensions, matching them case-sensitively',
        () async {
          final assetsDir = Directory('${tempDir.path}/nc_assets')
            ..createSync();
          // Compressible filler: deflated unless a no-compress rule matches.
          final filler = Uint8List.fromList(List<int>.filled(10000, 7));
          File('${assetsDir.path}/data.custom').writeAsBytesSync(filler);
          File('${assetsDir.path}/PHOTO.PNG').writeAsBytesSync(filler);
          File('${assetsDir.path}/photo.webp').writeAsBytesSync(filler);
          final basePath = await writeBaseApk([
            ZipEntry(
              path: 'AndroidManifest.xml',
              data: Uint8List.fromList([1]),
            ),
          ]);
          final jarPath = await writeNativeLibsJar();

          Future<Map<String, int>> spliceMethods(List<String> extraArgs) async {
            final outPath =
                '${tempDir.path}/overlay_nc_${extraArgs.length}.apk';
            await runAndroidBundle([
              'apk-overlay',
              '--base',
              basePath,
              '--native-libs-jar',
              jarPath,
              '--flutter-assets',
              assetsDir.path,
              '--output',
              outPath,
              ...extraArgs,
            ]);
            return readCentralForTest(File(outPath).readAsBytesSync()).methods;
          }

          // Without the flag the custom extension deflates.
          expect(
            (await spliceMethods([]))['assets/flutter_assets/data.custom'],
            8,
          );
          // With it — bare or leading-dot form — the entry is stored.
          for (final flag in ['custom', '.custom']) {
            final methods = await spliceMethods([
              '--nocompress-extensions',
              flag,
            ]);
            expect(
              methods['assets/flutter_assets/data.custom'],
              0,
              reason: 'extension flag "$flag" must store data.custom',
            );
          }
          // Case-sensitive like aapt2: the uppercase PNG matches no rule.
          final methods = await spliceMethods([
            '--nocompress-extensions',
            'custom',
          ]);
          expect(methods['assets/flutter_assets/PHOTO.PNG'], 8);
          // webp is an aapt2 default: stored with no flag at all.
          expect(methods['assets/flutter_assets/photo.webp'], 0);
        },
      );

      test('copies a stored .so larger than 64 MiB as raw bytes', () async {
        // The jar writer stores .so entries; the splice must reuse those raw
        // bytes and their CRC without inflating — the entry never fits a
        // 64 MiB streaming window, and below the ZIP32 limits it must work.
        const size = 65 * 1024 * 1024;
        final body = Uint8List(size)..fillRange(0, size, 7);
        final staged = BytesBuilder(copy: false)
          ..add(_syntheticElf(machine: 183))
          ..add(body);
        final libPath = '${tempDir.path}/huge_libapp.so';
        File(libPath).writeAsBytesSync(staged.takeBytes(), flush: true);
        final original = File(libPath).readAsBytesSync();

        final jarPath = '${tempDir.path}/huge_native_libs.jar';
        await runAndroidBundle([
          'native-libs-jar',
          '--output',
          jarPath,
          '--abi',
          'arm64-v8a',
          '--machine',
          '183',
          'lib/arm64-v8a/libapp.so=$libPath',
        ]);

        final basePath = await writeBaseApk([
          ZipEntry(
            path: 'AndroidManifest.xml',
            data: Uint8List.fromList([1]),
          ),
        ]);
        final emptyAssets = Directory('${tempDir.path}/huge_empty_assets')
          ..createSync();
        final outPath = '${tempDir.path}/overlay_huge.apk';
        await runAndroidBundle([
          'apk-overlay',
          '--base',
          basePath,
          '--native-libs-jar',
          jarPath,
          '--flutter-assets',
          emptyAssets.path,
          '--output',
          outPath,
        ]);

        final outRaw = {
          for (final e in readZipRawEntries(File(outPath).readAsBytesSync()))
            e.path: e,
        };
        final so = outRaw['lib/arm64-v8a/libapp.so']!;
        expect(so.method, 0);
        expect(so.rawData.length, original.length);
        expect(so.rawData, original);
        expect(so.crc, crc32(original));
      });

      test('preserves base entries that use data descriptors', () async {
        // singlejar emits the merged classes.dex with bit 3 set; the splice
        // copies the local-file region (descriptor trailers included)
        // byte-for-byte, so these entries need no special handling.
        final dexData = Uint8List.fromList(List<int>.filled(1000, 5));
        final baseBytes = zipWithDescriptorEntry('classes.dex', dexData);
        final basePath = '${tempDir.path}/base_desc.apk';
        File(basePath).writeAsBytesSync(baseBytes);
        final jarPath = await writeNativeLibsJar();
        final assetsPath = writeFlutterAssets();
        final outPath = '${tempDir.path}/overlay_desc.apk';

        await runAndroidBundle([
          'apk-overlay',
          '--base',
          basePath,
          '--native-libs-jar',
          jarPath,
          '--flutter-assets',
          assetsPath,
          '--output',
          outPath,
        ]);

        final outBytes = File(outPath).readAsBytesSync();
        final baseCd = readCentralForTest(baseBytes).cdOffset;
        expect(
          outBytes.sublist(0, baseCd),
          equals(baseBytes.sublist(0, baseCd)),
        );
        expect(entriesByPath(outPath)['classes.dex'], equals(dexData.toList()));
      });

      test('empty payload reproduces the base APK byte-for-byte', () async {
        final basePath = await writeBaseApk([
          ZipEntry(
            path: 'classes.dex',
            data: Uint8List.fromList(List<int>.filled(1000, 5)),
          ),
          ZipEntry(path: 'resources.arsc', data: Uint8List.fromList([1, 2])),
        ]);
        final emptyJar = '${tempDir.path}/empty.jar';
        await runAndroidBundle(['empty-jar', '--output', emptyJar]);
        final emptyAssets = Directory('${tempDir.path}/empty_assets')
          ..createSync();
        final outPath = '${tempDir.path}/overlay_empty.apk';

        await runAndroidBundle([
          'apk-overlay',
          '--base',
          basePath,
          '--native-libs-jar',
          emptyJar,
          '--flutter-assets',
          emptyAssets.path,
          '--output',
          outPath,
        ]);

        expect(
          File(outPath).readAsBytesSync(),
          equals(File(basePath).readAsBytesSync()),
        );
      });

      test('refuses a payload entry that collides with the base APK', () async {
        final basePath = await writeBaseApk([
          ZipEntry(
            path: 'assets/flutter_assets/AssetManifest.json',
            data: Uint8List.fromList([1]),
          ),
        ]);
        final jarPath = await writeNativeLibsJar();
        final assetsPath = writeFlutterAssets();

        expect(
          runAndroidBundle([
            'apk-overlay',
            '--base',
            basePath,
            '--native-libs-jar',
            jarPath,
            '--flutter-assets',
            assetsPath,
            '--output',
            '${tempDir.path}/should_not_exist.apk',
          ]),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('refuses a base APK that is already signed', () async {
        final basePath = await writeBaseApk([
          ZipEntry(
            path: 'META-INF/CERT.SF',
            data: Uint8List.fromList([1, 2, 3]),
          ),
        ]);
        final jarPath = await writeNativeLibsJar();
        final assetsPath = writeFlutterAssets();

        expect(
          runAndroidBundle([
            'apk-overlay',
            '--base',
            basePath,
            '--native-libs-jar',
            jarPath,
            '--flutter-assets',
            assetsPath,
            '--output',
            '${tempDir.path}/should_not_exist.apk',
          ]),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('refuses a base APK carrying an APK Signing Block', () async {
        // A v2-signed APK need not contain META-INF signature files; the
        // block sits between the local entries and the central directory.
        final clean = encodeDeterministicZip([
          ZipEntry(path: 'classes.dex', data: Uint8List.fromList([1])),
        ]);
        final cdOffset = readCentralForTest(clean).cdOffset;
        final block = BytesBuilder(copy: false);
        void u64(BytesBuilder b, int v) => b.add([
          v & 0xff,
          (v >> 8) & 0xff,
          (v >> 16) & 0xff,
          (v >> 24) & 0xff,
          0,
          0,
          0,
          0,
        ]);
        u64(block, 24);
        block.add(List<int>.filled(8, 0));
        u64(block, 24);
        block.add(utf8.encode('APK Sig Block 42'));
        final blockBytes = block.takeBytes();
        final forged = BytesBuilder(copy: false)
          ..add(Uint8List.sublistView(clean, 0, cdOffset))
          ..add(blockBytes)
          ..add(Uint8List.sublistView(clean, cdOffset));
        final forgedBytes = forged.takeBytes();
        final eocd = ByteData.sublistView(
          forgedBytes,
          forgedBytes.length - 22,
          forgedBytes.length,
        );
        eocd.setUint32(
          12,
          eocd.getUint32(12, Endian.little) + blockBytes.length,
          Endian.little,
        );
        eocd.setUint32(
          16,
          eocd.getUint32(16, Endian.little) + blockBytes.length,
          Endian.little,
        );
        final basePath = '${tempDir.path}/base_v2signed.apk';
        File(basePath).writeAsBytesSync(forgedBytes);
        final jarPath = await writeNativeLibsJar();
        final assetsPath = writeFlutterAssets();

        expect(
          runAndroidBundle([
            'apk-overlay',
            '--base',
            basePath,
            '--native-libs-jar',
            jarPath,
            '--flutter-assets',
            assetsPath,
            '--output',
            '${tempDir.path}/should_not_exist.apk',
          ]),
          throwsA(isA<ArgumentError>()),
        );
      });
    });
  });
}
