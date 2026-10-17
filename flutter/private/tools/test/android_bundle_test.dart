import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../android_bundle.dart';

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

          expect(File(outJar).readAsStringSync(), 'JAR_BYTES');
          expect(File(fakeZipperLog).readAsLinesSync(), [
            'cC',
            outJar,
            'lib/arm64-v8a/libapp.so=${libApp.path}',
            'lib/arm64-v8a/libplugin.so=${libPlugin.path}',
          ]);
        },
        testOn: '!windows',
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
  });
}
