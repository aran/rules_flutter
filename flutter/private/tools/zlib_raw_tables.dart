/// Constant tables for the raw-deflate compressor (`zlib_raw_match.dart`,
/// `zlib_raw_trees.dart`).
///
/// These are the `extra_*bits` and `bl_order` arrays from zlib 1.3.2's
/// `trees.c`. The tables `tr_static_init` derives from them (the
/// `_length_code`/`_dist_code` maps, `base_length`/`base_dist`, and the static
/// literal/distance trees) are computed once by `_trStaticInit` in
/// `zlib_raw_trees.dart` instead of being spelled out here.
library;

/// Extra bits for each length code (`extra_lbits`, 29 entries).
const List<int> zlibExtraLbits = <int>[
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  0,
];

/// Extra bits for each distance code (`extra_dbits`, 30 entries).
const List<int> zlibExtraDbits = <int>[
  0,
  0,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  4,
  4,
  5,
  5,
  6,
  6,
  7,
  7,
  8,
  8,
  9,
  9,
  10,
  10,
  11,
  11,
  12,
  12,
  13,
  13,
];

/// Extra bits for each bit-length code (`extra_blbits`, 19 entries).
const List<int> zlibExtraBlbits = <int>[
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  2,
  3,
  7,
];

/// Bit-length code send order (`bl_order`, 19 entries).
const List<int> zlibBlOrder = <int>[
  16,
  17,
  18,
  0,
  8,
  7,
  9,
  6,
  10,
  5,
  11,
  4,
  12,
  3,
  13,
  2,
  14,
  1,
  15,
];
