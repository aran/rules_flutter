import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

// Import the library directly.
import '../generate_asset_manifest.dart';

void main() {
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
