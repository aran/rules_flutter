import 'dart:convert';

import 'package:test/test.dart';

import '../sha256.dart';
import '../zlib_raw_trees.dart';

// The six digests below are the sha256 of the deleted literal tables from
// `zlib_raw_tables.dart` (zlib 1.3.2 `trees.h`, as spelled out before
// `_trStaticInit` replaced them). Derivation: serialize each literal with
// `_digestInts`/`_digestPairs`, hash with `sha256Hex`, and record the hex.
// The digests were computed from the literals before deletion by hashing
// `list.join(',')` for int tables and `code:len` pairs joined by commas for
// the static trees; the helpers below use exactly that serialization, so any
// drift in the computed tables fails this test. No table values appear here.
const Map<String, String> _expectedDigests = {
  'lengthCode':
      '7d7d9b994e906d2a65ba7e7c04d8ee8d1bfd89b617aaac311f579924fce99249',
  'distCode':
      '02c2c443b640f18fa5d311da4dfd34caae25921442750f25b7a7a784fb89adf6',
  'baseLength':
      'c8ed8fde7584626098f6e526a5aef271c967b5a5a30b8c4855ffc4eb67e79b02',
  'baseDist':
      'cb6862cd82eaaa71fa887dc828dedd2d814cb02db1ca39884f2f279fa1621f56',
  'staticLtree':
      'e5c0bce076c3069db5bd4c35375ccecb611a78df65ac183b1b54da5ba5005cda',
  'staticDtree':
      '6e04fd444bf0ace89671d90a8257349541e25b38ebf847198243bfa241251abb',
};

String _digestInts(List<int> table) => sha256Hex(utf8.encode(table.join(',')));

String _digestPairs(List<(int, int)> table) => sha256Hex(
  utf8.encode(table.map((pair) => '${pair.$1}:${pair.$2}').join(',')),
);

void main() {
  group('tr_static_init identity', () {
    test('length code map matches trees.h', () {
      expect(_digestInts(zlibLengthCode), _expectedDigests['lengthCode']);
    });
    test('distance code map matches trees.h', () {
      expect(_digestInts(zlibDistCode), _expectedDigests['distCode']);
    });
    test('length bases match trees.h', () {
      expect(_digestInts(zlibBaseLength), _expectedDigests['baseLength']);
    });
    test('distance bases match trees.h', () {
      expect(_digestInts(zlibBaseDist), _expectedDigests['baseDist']);
    });
    test('static literal tree matches trees.h', () {
      expect(_digestPairs(zlibStaticLtree), _expectedDigests['staticLtree']);
    });
    test('static distance tree matches trees.h', () {
      expect(_digestPairs(zlibStaticDtree), _expectedDigests['staticDtree']);
    });
  });
}
