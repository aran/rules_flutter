import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

// Import the library directly.
import '../generate_asset_manifest.dart' as manifest;

void main() {
  group('encodeStandardMessage', () {
    test('encodes null to empty bytes', () {
      final result = manifest.encodeStandardMessage(null);
      expect(result, isEmpty);
    });

    test('encodes bool true to tag 1', () {
      final result = manifest.encodeStandardMessage(true);
      expect(result[0], 1); // _tagTrue
    });

    test('encodes bool false to tag 2', () {
      final result = manifest.encodeStandardMessage(false);
      expect(result[0], 2); // _tagFalse
    });

    test('encodes int32 to tag 3 + 4 bytes', () {
      final result = manifest.encodeStandardMessage(42);
      expect(result[0], 3); // _tagInt32
      expect(result.length, 5); // 1 tag + 4 bytes
      // Decode the int32 value.
      final bd = ByteData.sublistView(result, 1, 5);
      expect(bd.getInt32(0, Endian.host), 42);
    });

    test('encodes string to tag 7 + length + UTF-8 bytes', () {
      final result = manifest.encodeStandardMessage('hello');
      expect(result[0], 7); // _tagString
      expect(result[1], 5); // length of "hello" in UTF-8
      expect(utf8.decode(result.sublist(2)), 'hello');
    });

    test('encodes list to tag 12 + length + elements', () {
      final result = manifest.encodeStandardMessage([true, false]);
      expect(result[0], 12); // _tagList
      expect(result[1], 2); // 2 elements
      expect(result[2], 1); // true
      expect(result[3], 2); // false
    });

    test('encodes map to tag 13 + length + key-value pairs', () {
      final result = manifest.encodeStandardMessage({'a': true});
      expect(result[0], 13); // _tagMap
      expect(result[1], 1); // 1 entry
      // Key: string "a"
      expect(result[2], 7); // _tagString
      expect(result[3], 1); // length 1
      expect(result[4], 0x61); // 'a'
      // Value: true
      expect(result[5], 1); // _tagTrue
    });

    test('encodes nested asset manifest structure', () {
      // Simulate a real asset manifest: Map<String, List<Map<String, Object>>>
      final manifestData = {
        'assets/logo.png': [
          {'asset': 'assets/logo.png'},
          {'asset': 'assets/2.0x/logo.png', 'dpr': 2.0},
        ],
      };
      final result = manifest.encodeStandardMessage(manifestData);
      // Just verify it encodes without error and starts with map tag.
      expect(result[0], 13); // _tagMap
      expect(result.length, greaterThan(10));
    });

    test('writeSize encodes 1-byte, 2-byte, 4-byte sizes', () {
      // 1-byte: size < 254 — encode a short string
      final short = manifest.encodeStandardMessage('hi');
      expect(short[1], 2); // size fits in 1 byte

      // 2-byte: size 254..65535 — encode a long string
      final mediumStr = 'x' * 300;
      final medium = manifest.encodeStandardMessage(mediumStr);
      expect(medium[1], 254); // marker for 2-byte size

      // 4-byte: would need a huge string (65536+), skip for perf.
    });
  });

  group('icon tree shaking', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('asset_manifest_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('ships font families with zero const IconData usage whole', () async {
      final materialFont = File('${tempDir.path}/MaterialIcons-Regular.otf')
        ..writeAsBytesSync(List<int>.filled(1024, 0x4d));
      final robotoFont = File('${tempDir.path}/Roboto-Regular.ttf')
        ..writeAsBytesSync(List<int>.filled(512, 0x52));
      final cupertinoFont = File('${tempDir.path}/CupertinoIcons.ttf')
        ..writeAsBytesSync(List<int>.filled(768, 0x43));

      // Fake const_finder reports only CupertinoIcons usage; MaterialIcons and
      // Roboto have 0 const IconData instances (e.g., used via TextStyle or
      // web-only paths) and must be copied whole without invoking font-subset.
      // Fake const_finder is a shell script (not Dart): it boots in
      // milliseconds and never reads the process working directory, so it is
      // immune to parallel-test cwd churn that would crash a Dart child.
      final fakeConstFinder = File('${tempDir.path}/fake_const_finder.sh')
        ..writeAsStringSync('''#!/bin/sh
printf '%s' '{"constantInstances": [{"fontFamily": "CupertinoIcons", "fontPackage": "cupertino_icons", "codePoint": 62660}], "nonConstantLocations": []}'
''');

      // Fake font-subset writes the stdin code points into the output file so
      // the test can verify which font was subsetted and with which code points.
      await Process.run('chmod', ['+x', fakeConstFinder.path]);
      final fakeFontSubset = File('${tempDir.path}/fake_font_subset.sh')
        ..writeAsStringSync('''#!/bin/sh
out="\$1"
cat > "\$out"
''');
      await Process.run('chmod', ['+x', fakeFontSubset.path]);

      final configFile = File('${tempDir.path}/config.json')
        ..writeAsStringSync(
          json.encode({
            'assets': <String, Object>{},
            'fonts': [
              {
                'family': 'MaterialIcons',
                'fonts': [
                  {'asset': 'fonts/MaterialIcons-Regular.otf'},
                ],
              },
              {
                'family': 'Roboto',
                'fonts': [
                  {'asset': 'fonts/Roboto-Regular.ttf'},
                ],
              },
              {
                'family': 'packages/cupertino_icons/CupertinoIcons',
                'fonts': [
                  {
                    'asset':
                        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
                  },
                ],
              },
            ],
            'copies': {
              'fonts/MaterialIcons-Regular.otf': materialFont.path,
              'fonts/Roboto-Regular.ttf': robotoFont.path,
              'packages/cupertino_icons/assets/CupertinoIcons.ttf':
                  cupertinoFont.path,
            },
            'icon_tree_shaking': {
              // Runs the fake_const_finder.sh shell script directly instead of
              // a Dart program (see the fixture comment above).
              'dart': '/bin/sh',
              'const_finder': fakeConstFinder.path,
              'font_subset': fakeFontSubset.path,
              'kernel_dill': '${tempDir.path}/dummy.dill',
            },
          }),
        );

      final outDir = '${tempDir.path}/out';
      await manifest.main([
        '--config',
        configFile.path,
        '--output-dir',
        outDir,
      ]);

      // MaterialIcons and Roboto had 0 const IconData usages -> shipped whole.
      expect(
        File('$outDir/fonts/MaterialIcons-Regular.otf').readAsBytesSync(),
        equals(materialFont.readAsBytesSync()),
      );
      expect(
        File('$outDir/fonts/Roboto-Regular.ttf').readAsBytesSync(),
        equals(robotoFont.readAsBytesSync()),
      );

      // CupertinoIcons had 1 const IconData usage -> subsetted to 0xf4c4 (62660).
      expect(
        File(
          '$outDir/packages/cupertino_icons/assets/CupertinoIcons.ttf',
        ).readAsStringSync().trim(),
        equals('${0xf4c4}'),
      );
    });

    test(
      'subsets families with suffix names and suffix asset paths independently',
      () async {
        final materialFont = File('${tempDir.path}/MaterialIcons-Regular.otf')
          ..writeAsBytesSync(List<int>.filled(1024, 0x4d));
        final bareIconsFont = File('${tempDir.path}/Icons.otf')
          ..writeAsBytesSync(List<int>.filled(1024, 0x49));
        final pkgIconsFont = File('${tempDir.path}/PkgIcons.otf')
          ..writeAsBytesSync(List<int>.filled(1024, 0x50));

        expect(
          manifest.matchesFontAssetPath('fonts/Icons.otf', 'fonts/Icons.otf'),
          isTrue,
        );
        expect(
          manifest.matchesFontAssetPath(
            'packages/custom_icons/fonts/Icons.otf',
            'fonts/Icons.otf',
          ),
          isFalse,
        );

        // Fake const_finder is a shell script (see the first icon test): it
        // boots in milliseconds and never reads the process working
        // directory, so parallel-test cwd churn cannot crash it.
        final fakeConstFinder = File('${tempDir.path}/fake_const_finder.sh')
          ..writeAsStringSync('''#!/bin/sh
printf '%s' '{"constantInstances": [{"fontFamily": "MaterialIcons", "fontPackage": null, "codePoint": 57617}, {"fontFamily": "Icons", "fontPackage": null, "codePoint": 57890}, {"fontFamily": "Icons", "fontPackage": "custom_icons", "codePoint": 58163}], "nonConstantLocations": []}'
''');
        await Process.run('chmod', ['+x', fakeConstFinder.path]);

        final fakeFontSubset = File('${tempDir.path}/fake_font_subset.sh')
          ..writeAsStringSync('''#!/bin/sh
out="\$1"
cat > "\$out"
''');
        await Process.run('chmod', ['+x', fakeFontSubset.path]);

        final configFile = File('${tempDir.path}/config.json')
          ..writeAsStringSync(
            json.encode({
              'assets': <String, Object>{},
              'fonts': [
                {
                  'family': 'MaterialIcons',
                  'fonts': [
                    {'asset': 'fonts/MaterialIcons-Regular.otf'},
                  ],
                },
                {
                  'family': 'Icons',
                  'fonts': [
                    {'asset': 'fonts/Icons.otf'},
                  ],
                },
                {
                  'family': 'packages/custom_icons/Icons',
                  'fonts': [
                    {'asset': 'packages/custom_icons/fonts/Icons.otf'},
                  ],
                },
              ],
              'copies': {
                'fonts/MaterialIcons-Regular.otf': materialFont.path,
                'fonts/Icons.otf': bareIconsFont.path,
                'packages/custom_icons/fonts/Icons.otf': pkgIconsFont.path,
              },
              'icon_tree_shaking': {
                // Runs the fake_const_finder.sh shell script directly (see the
                // fixture comment above), not a Dart program.
                'dart': '/bin/sh',
                'const_finder': fakeConstFinder.path,
                'font_subset': fakeFontSubset.path,
                'kernel_dill': '${tempDir.path}/dummy.dill',
              },
            }),
          );

        final outDir = '${tempDir.path}/out';
        await manifest.main([
          '--config',
          configFile.path,
          '--output-dir',
          outDir,
        ]);

        expect(
          File('$outDir/fonts/MaterialIcons-Regular.otf')
              .readAsStringSync()
              .trim(),
          equals('${0xe111}'),
        );
        expect(
          File('$outDir/fonts/Icons.otf').readAsStringSync().trim(),
          equals('${0xe222}'),
        );
        expect(
          File('$outDir/packages/custom_icons/fonts/Icons.otf')
              .readAsStringSync()
              .trim(),
          equals('${0xe333}'),
        );
      },
    );

    test(
      'merges code points across multiple kernel_dills for multi-renderer web bundles',
      () async {
        final materialFont = File('${tempDir.path}/MaterialIcons-Regular.otf')
          ..writeAsBytesSync(List<int>.filled(1024, 0x4d));

        // Fake const_finder is a shell script (see the first icon test): it
        // boots in milliseconds and never reads the process working
        // directory, so parallel-test cwd churn cannot crash it. The second
        // argument ($2) is the --kernel-file value.
        final fakeConstFinder = File('${tempDir.path}/fake_const_finder.sh')
          ..writeAsStringSync('''#!/bin/sh
case "\$2" in
*skwasm.dill) printf '%s' '{"constantInstances": [{"fontFamily": "MaterialIcons", "fontPackage": null, "codePoint": 57415}, {"fontFamily": "MaterialIcons", "fontPackage": null, "codePoint": 58727}], "nonConstantLocations": []}' ;;
*) printf '%s' '{"constantInstances": [{"fontFamily": "MaterialIcons", "fontPackage": null, "codePoint": 57415}, {"fontFamily": "MaterialIcons", "fontPackage": null, "codePoint": 57669}], "nonConstantLocations": []}' ;;
esac
''');
        await Process.run('chmod', ['+x', fakeConstFinder.path]);

        final fakeFontSubset = File('${tempDir.path}/fake_font_subset.sh')
          ..writeAsStringSync('''#!/bin/sh
out="\$1"
cat > "\$out"
''');
        await Process.run('chmod', ['+x', fakeFontSubset.path]);

        final configFile = File('${tempDir.path}/config.json')
          ..writeAsStringSync(
            json.encode({
              'assets': <String, Object>{},
              'fonts': [
                {
                  'family': 'MaterialIcons',
                  'fonts': [
                    {'asset': 'fonts/MaterialIcons-Regular.otf'},
                  ],
                },
              ],
              'copies': {'fonts/MaterialIcons-Regular.otf': materialFont.path},
              'icon_tree_shaking': {
                // Runs the fake_const_finder.sh shell script directly (see the
                // fixture comment above), not a Dart program.
                'dart': '/bin/sh',
                'const_finder': fakeConstFinder.path,
                'font_subset': fakeFontSubset.path,
                'kernel_dill': '${tempDir.path}/skwasm.dill',
                'kernel_dills': [
                  '${tempDir.path}/skwasm.dill',
                  '${tempDir.path}/canvaskit.dill',
                ],
              },
            }),
          );

        final outDir = '${tempDir.path}/out';
        await manifest.main([
          '--config',
          configFile.path,
          '--output-dir',
          outDir,
        ]);

        expect(
          File('$outDir/fonts/MaterialIcons-Regular.otf')
              .readAsStringSync()
              .trim(),
          equals('${0xe047} ${0xe145} ${0xe567}'),
        );

        // If any kernel reports nonConstantLocations, tree shaking is disabled.
        expect(
          manifest.mergeConstFinderCodePoints([
            {
              'constantInstances': [
                {
                  'fontFamily': 'MaterialIcons',
                  'fontPackage': null,
                  'codePoint': 0xe047,
                },
              ],
              'nonConstantLocations': <Object>[],
            },
            {
              'constantInstances': <Object>[],
              'nonConstantLocations': [
                {'file': 'main.dart', 'line': 10},
              ],
            },
          ]),
          isNull,
        );
      },
    );
  });
}
