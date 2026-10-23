import 'dart:convert';

import 'package:test/test.dart';

import '../sha256.dart';

// The digests below are FIPS 180-4 vectors (empty, "abc", one million "a"s)
// plus padding-boundary inputs of 55, 56, and 64 "a"s: 55 bytes pad into one
// block, 56 and 64 spill into two. Each was computed independently with
// `python3 -c "import hashlib; ..."` and recorded here, so any drift in the
// implementation fails this test.
const Map<String, String> _expectedHex = {
  'empty': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  'abc': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  'a55': '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318',
  'a56': 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a',
  'a64': 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb',
  'a1M': 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
};

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('sha256 known vectors', () {
    test('empty input', () {
      expect(sha256Hex([]), _expectedHex['empty']);
      expect(_hex(sha256([])), _expectedHex['empty']);
    });
    test('"abc"', () {
      final input = utf8.encode('abc');
      expect(sha256Hex(input), _expectedHex['abc']);
      expect(_hex(sha256(input)), _expectedHex['abc']);
    });
    test('55-byte input pads into one block', () {
      expect(sha256Hex(List.filled(55, 0x61)), _expectedHex['a55']);
    });
    test('56-byte input spills into two blocks', () {
      expect(sha256Hex(List.filled(56, 0x61)), _expectedHex['a56']);
    });
    test('64-byte input spills into two blocks', () {
      expect(sha256Hex(List.filled(64, 0x61)), _expectedHex['a64']);
    });
    test('one million "a"s', () {
      final digest = sha256(List.filled(1000000, 0x61));
      expect(digest, hasLength(32));
      expect(_hex(digest), _expectedHex['a1M']);
    });
  });
}
