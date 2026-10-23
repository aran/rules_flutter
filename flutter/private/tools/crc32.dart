/// IEEE 802.3 CRC-32 over bytes, with no package dependencies.
///
/// Both the Mach-O post-processing and the deterministic ZIP writer checksum
/// payloads with it; the table lives here so the two tools share one copy.
library;

import 'dart:typed_data';

final Uint32List _crc32Table = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      if ((c & 1) != 0) {
        c = 0xEDB88320 ^ (c >>> 1);
      } else {
        c = c >>> 1;
      }
    }
    table[i] = c;
  }
  return table;
}();

/// Feeds [bytes] (or its first [length] bytes) into the running CRC [c].
int crc32Update(int c, List<int> bytes, [int? length]) {
  final end = length ?? bytes.length;
  for (var i = 0; i < end; i++) {
    c = _crc32Table[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  }
  return c;
}

/// The IEEE 802.3 CRC-32 checksum of [bytes].
int crc32(List<int> bytes) {
  final c = crc32Update(0xFFFFFFFF, bytes);
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
