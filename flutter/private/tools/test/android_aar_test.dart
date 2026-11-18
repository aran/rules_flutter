import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../android_aar.dart';
import '../zip_archive.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('android_aar_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String file(String name, String contents) {
    final f = File('${tmp.path}/$name')..parent.createSync(recursive: true);
    f.writeAsStringSync(contents);
    return f.path;
  }

  String jar(String name, Map<String, String> entries) {
    final f = File('${tmp.path}/$name');
    f.writeAsBytesSync(
      writeZip([
        for (final MapEntry(:key, :value) in entries.entries)
          ZipEntry(key, utf8.encode(value)),
      ]),
    );
    return f.path;
  }

  Map<String, String> unzip(List<int> bytes) => {
    for (final e in readZip(Uint8List.fromList(bytes)))
      e.name: utf8.decode(e.bytes),
  };

  group('zip', () {
    test('reads back what it writes, stored and deflated', () {
      final big = 'a' * 10000;
      final bytes = writeZip([
        ZipEntry('small', [1]),
        ZipEntry('dir/big.txt', utf8.encode(big)),
      ]);
      final entries = readZip(bytes);
      expect(entries.map((e) => e.name), ['small', 'dir/big.txt']);
      expect(entries.first.bytes, [1]);
      expect(utf8.decode(entries.last.bytes), big);
      // Deflated: far smaller than what it holds.
      expect(bytes.length, lessThan(1000));
    });

    test('writes the same bytes every time', () {
      List<int> once() => writeZip([ZipEntry('a', utf8.encode('x'))]);
      expect(once(), once());
    });

    test('refuses two entries with one name', () {
      expect(
        () => writeZip([ZipEntry('a', []), ZipEntry('a', [])]),
        throwsArgumentError,
      );
    });

    test('crc32 is zip\'s', () {
      expect(crc32(utf8.encode('123456789')), 0xcbf43926);
    });
  });

  group('mergeJars', () {
    test('holds the classes of every jar', () {
      final merged = unzip(
        mergeJars([
          jar('a.jar', {'META-INF/MANIFEST.MF': 'a', 'x/A.class': 'A'}),
          jar('b.jar', {'META-INF/MANIFEST.MF': 'b', 'x/B.class': 'B'}),
        ]),
      );
      expect(merged, {
        'META-INF/MANIFEST.MF': 'a',
        'x/A.class': 'A',
        'x/B.class': 'B',
      });
    });

    test('fails for one class in two jars', () {
      expect(
        () => mergeJars([
          jar('a.jar', {'x/A.class': 'one'}),
          jar('b.jar', {'x/A.class': 'two'}),
        ]),
        throwsA(
          isA<AarException>().having(
            (e) => e.message,
            'message',
            contains('x/A.class is in both'),
          ),
        ),
      );
    });
  });

  group('aarEntries', () {
    test('lays an AAR out as Gradle does', () {
      file('arm/flutter_assets/AssetManifest.bin', 'm');
      file('x86/flutter_assets/AssetManifest.bin', 'm');
      final spec = parseArgs([
        '--output', '${tmp.path}/out.aar', //
        '--manifest', file('AndroidManifest.xml', '<manifest/>'),
        '--classes', jar('c.jar', {'io/flutter/plugins/R.class': 'r'}),
        '--proguard', file('a.pro', '-keep class A'),
        '--proguard', file('b.pro', '-keep class B\n'),
        '--entry', 'res/drawable/ic.xml', file('ic.xml', '<vector/>'),
        '--flutter-assets', 'armeabi-v7a', '${tmp.path}/arm/flutter_assets',
        '--flutter-assets', 'x86_64', '${tmp.path}/x86/flutter_assets',
        '--jni', 'x86_64', file('x86/libapp.so', 'elf'),
      ]);
      final entries = aarEntries(spec);
      expect(entries.map((e) => e.name), [
        'AndroidManifest.xml',
        'classes.jar',
        'R.txt',
        'proguard.txt',
        'assets/flutter_assets/AssetManifest.bin',
        'jni/x86_64/libapp.so',
        'res/drawable/ic.xml',
      ]);
      final byName = {for (final e in entries) e.name: e.bytes};
      expect(
        utf8.decode(byName['proguard.txt']!),
        '-keep class A\n-keep class B\n',
      );
      expect(byName['R.txt'], isEmpty);
      expect(unzip(byName['classes.jar']!).keys, [
        'io/flutter/plugins/R.class',
      ]);
    });

    test('fails when the ABIs\' flutter_assets differ', () {
      file('arm/flutter_assets/NOTICES.Z', 'one');
      file('x86/flutter_assets/NOTICES.Z', 'two');
      expect(
        () => sameFlutterAssets([
          ('armeabi-v7a', '${tmp.path}/arm/flutter_assets'),
          ('x86_64', '${tmp.path}/x86/flutter_assets'),
        ]),
        throwsA(
          isA<AarException>().having(
            (e) => e.message,
            'message',
            contains(
              'flutter_assets/NOTICES.Z differs between the '
              'armeabi-v7a and x86_64 builds',
            ),
          ),
        ),
      );
    });

    test(
      'takes the first ABI\'s kernel, which differs in its build record',
      () {
        file('arm/flutter_assets/kernel_blob.bin', 'arm');
        file('x86/flutter_assets/kernel_blob.bin', 'x86');
        final assets = sameFlutterAssets([
          ('arm64-v8a', '${tmp.path}/arm/flutter_assets'),
          ('x86_64', '${tmp.path}/x86/flutter_assets'),
        ]);
        expect(assets['kernel_blob.bin']!.readAsStringSync(), 'arm');
      },
    );

    group('the native-assets manifest', () {
      String manifest(String target) => jsonEncode({
        'format-version': [1, 0, 0],
        'native-assets': {
          target: {
            'package:count_a/count_a': ['absolute', 'libcounter.so'],
          },
        },
      });

      test('names the code assets of every ABI the AAR has libraries for', () {
        file(
          'arm64/flutter_assets/NativeAssetsManifest.json',
          manifest('android_arm64'),
        );
        file(
          'arm/flutter_assets/NativeAssetsManifest.json',
          manifest('android_arm'),
        );
        file(
          'x86/flutter_assets/NativeAssetsManifest.json',
          manifest('android_x64'),
        );
        final spec = parseArgs([
          '--output', '${tmp.path}/out.aar', //
          '--manifest', file('AndroidManifest.xml', '<manifest/>'),
          // The configuration that compiles Java, whose ABI is not one of
          // the AAR's.
          '--flutter-assets', 'arm64-v8a', '${tmp.path}/arm64/flutter_assets',
          '--flutter-assets', 'armeabi-v7a', '${tmp.path}/arm/flutter_assets',
          '--flutter-assets', 'x86_64', '${tmp.path}/x86/flutter_assets',
          '--jni', 'armeabi-v7a', file('arm/libapp.so', 'elf'),
          '--jni', 'x86_64', file('x86/libapp.so', 'elf'),
        ]);
        final byName = {for (final e in aarEntries(spec)) e.name: e.bytes};
        final merged = jsonDecode(
          utf8.decode(
            byName['assets/flutter_assets/NativeAssetsManifest.json']!,
          ),
        ) as Map<String, Object?>;
        expect(merged['format-version'], [1, 0, 0]);
        expect(
          (merged['native-assets']! as Map<String, Object?>).keys,
          ['android_arm', 'android_x64'],
        );
      });

      test('fails when two builds name one target', () {
        file(
          'a/flutter_assets/NativeAssetsManifest.json',
          manifest('android_arm'),
        );
        file(
          'b/flutter_assets/NativeAssetsManifest.json',
          manifest('android_arm'),
        );
        expect(
          () => mergedNativeAssetsManifest(
            [
              ('armeabi-v7a', '${tmp.path}/a/flutter_assets'),
              ('x86_64', '${tmp.path}/b/flutter_assets'),
            ],
            {'armeabi-v7a', 'x86_64'},
          ),
          throwsA(
            isA<AarException>().having(
              (e) => e.message,
              'message',
              contains('code assets for android_arm'),
            ),
          ),
        );
      });
    });

    test('fails when one ABI has a file the other lacks', () {
      file('arm/flutter_assets/a', 'a');
      Directory('${tmp.path}/x86/flutter_assets').createSync(recursive: true);
      expect(
        () => sameFlutterAssets([
          ('armeabi-v7a', '${tmp.path}/arm/flutter_assets'),
          ('x86_64', '${tmp.path}/x86/flutter_assets'),
        ]),
        throwsA(
          isA<AarException>().having(
            (e) => e.message,
            'message',
            contains(
              'flutter_assets/a is in the armeabi-v7a build and not in the '
              'x86_64 build',
            ),
          ),
        ),
      );
    });

    test('reads its arguments from a params file', () {
      final params = file('params', '--output\nout.aar\n--manifest\nm.xml\n');
      expect(expandParams(['@$params']), [
        '--output',
        'out.aar',
        '--manifest',
        'm.xml',
      ]);
    });
  });
}
