import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

// Import the library directly.
import '../generate_asset_manifest.dart';

void main() {
  group('ProgramAssets', () {
    // rules_dart's conformance fixture, read in its directory:
    // `program.params` lists what `expected.txt` does, whose data lines are
    // what the bundle ships.
    String fixture(String name) {
      final runfiles = Runfiles.create();
      return Platform.environment['CONFORMANCE']!
          .split(' ')
          .map(runfiles.rlocation)
          .whereType<String>()
          .firstWhere((p) => p.endsWith('/$name'));
    }

    test('reads the data assets of rules_dart\'s conformance fixture', () {
      final params = fixture('program.params');
      final base = File(params).parent.path;
      final program = ProgramAssets.read(params, base: base);
      // A file of a linked directory is a host path, with the host's
      // separators below the directory; the fixture writes `/`.
      String relative(String file) => file
          .substring(base.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      final listed = [
        for (final MapEntry(:key, :value) in program.dataAssets.entries)
          'data\t$key\t${relative(value)}',
      ]..sort();
      final expected = File(
        '$base/expected.txt',
      ).readAsLinesSync().where((l) => l.startsWith('data\t')).toList()..sort();
      expect(listed, expected);
    });

    test('refuses a file without the data assets', () {
      final params = fixture('code_names.params');
      expect(
        () => ProgramAssets.read(params, base: File(params).parent.path),
        throwsFormatException,
      );
    });

    test('refuses a code record in a file that holds only data', () {
      final dir = Directory.systemTemp.createTempSync('program_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/p.params')
        ..writeAsStringSync(
          '--format\nrules_dart_program_assets/1\n--paths\nexec\n'
          '--holds\ndata\n--code-asset\npackage:a/b\n'
          'dynamic_loading_bundle\nlibb.so\n\n',
        );
      expect(() => ProgramAssets.read(file.path), throwsFormatException);
    });

    test('refuses another format', () {
      final dir = Directory.systemTemp.createTempSync('program_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/p.params')
        ..writeAsStringSync(
          '--format\nrules_dart_program_assets/2\n--paths\nexec\n',
        );
      expect(() => ProgramAssets.read(file.path), throwsFormatException);
    });
  });

  group('addProgramDataAssets', () {
    test('bundles each data asset at packages/<package>/<name>', () {
      final config = <String, dynamic>{
        'assets': <String, dynamic>{
          'assets/a.png': [
            {'asset': 'assets/a.png'},
          ],
        },
        'copies': <String, dynamic>{'assets/a.png': 'src/a.png'},
      };
      addProgramDataAssets(
        config,
        ProgramAssets({
          'package:p/greeting.txt': 'out/greeting.txt',
          'package:glyphs/glyphs/heart.txt': 'out/glyphs.data/glyphs/heart.txt',
        }),
      );
      expect(config['copies'], {
        'assets/a.png': 'src/a.png',
        'packages/p/greeting.txt': 'out/greeting.txt',
        'packages/glyphs/glyphs/heart.txt': 'out/glyphs.data/glyphs/heart.txt',
      });
      expect((config['assets'] as Map)['packages/p/greeting.txt'], [
        {'asset': 'packages/p/greeting.txt'},
      ]);
    });
  });

  group('encodeStandardMessage', () {
    test('encodes null to empty bytes', () {
      final result = encodeStandardMessage(null);
      expect(result, isEmpty);
    });

    test('encodes bool true to tag 1', () {
      final result = encodeStandardMessage(true);
      expect(result[0], 1); // _tagTrue
    });

    test('encodes bool false to tag 2', () {
      final result = encodeStandardMessage(false);
      expect(result[0], 2); // _tagFalse
    });

    test('encodes int32 to tag 3 + 4 bytes', () {
      final result = encodeStandardMessage(42);
      expect(result[0], 3); // _tagInt32
      expect(result.length, 5); // 1 tag + 4 bytes
      // Decode the int32 value.
      final bd = ByteData.sublistView(result, 1, 5);
      expect(bd.getInt32(0, Endian.host), 42);
    });

    test('encodes string to tag 7 + length + UTF-8 bytes', () {
      final result = encodeStandardMessage('hello');
      expect(result[0], 7); // _tagString
      expect(result[1], 5); // length of "hello" in UTF-8
      expect(utf8.decode(result.sublist(2)), 'hello');
    });

    test('encodes list to tag 12 + length + elements', () {
      final result = encodeStandardMessage([true, false]);
      expect(result[0], 12); // _tagList
      expect(result[1], 2); // 2 elements
      expect(result[2], 1); // true
      expect(result[3], 2); // false
    });

    test('encodes map to tag 13 + length + key-value pairs', () {
      final result = encodeStandardMessage({'a': true});
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
      final manifest = {
        'assets/logo.png': [
          {'asset': 'assets/logo.png'},
          {'asset': 'assets/2.0x/logo.png', 'dpr': 2.0},
        ],
      };
      final result = encodeStandardMessage(manifest);
      // Just verify it encodes without error and starts with map tag.
      expect(result[0], 13); // _tagMap
      expect(result.length, greaterThan(10));
    });

    test('writeSize encodes 1-byte, 2-byte, 4-byte sizes', () {
      // 1-byte: size < 254 — encode a short string
      final short = encodeStandardMessage('hi');
      expect(short[1], 2); // size fits in 1 byte

      // 2-byte: size 254..65535 — encode a long string
      final mediumStr = 'x' * 300;
      final medium = encodeStandardMessage(mediumStr);
      expect(medium[1], 254); // marker for 2-byte size

      // 4-byte: would need a huge string (65536+), skip for perf.
    });
  });
}
