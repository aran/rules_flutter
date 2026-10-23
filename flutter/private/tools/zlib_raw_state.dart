/// Sliding-window and symbol state for the raw-deflate compressor.
///
/// This is a line-by-line port of the `deflate_state` structure plus the
/// window-management routines (`lm_init`, `slide_hash`, `fill_window`) from
/// zlib 1.3.2 (`deflate.c`, `deflate.h`), fixed at compression level 9 with
/// the default memory level (8) and default strategy. Only the level-9
/// steady state is ported: there is no zlib/gzip wrapper, no checksum, and
/// no streaming — the whole input is resident, so `avail_in` exhaustion
/// means end of input.
///
/// Field and function names follow the C originals (converted to lower
/// camel case) so the port can be checked against the C source directly.
library;

import 'dart:typed_data';

/// Minimum match length (`MIN_MATCH` in `zutil.h`).
const int zlibMinMatch = 3;

/// Maximum match length (`MAX_MATCH` in `zutil.h`).
const int zlibMaxMatch = 258;

/// Minimum lookahead (`MIN_LOOKAHEAD` in `deflate.h`).
const int zlibMinLookahead = zlibMaxMatch + zlibMinMatch + 1;

/// LZ77 window size for window bits 15 (`w_size`).
const int zlibWindowSize = 32768;

/// Actual window allocation: twice the window size (`window_size`).
const int zlibWindowAllocation = 2 * zlibWindowSize;

/// Maximum match distance (`MAX_DIST`): `w_size - MIN_LOOKAHEAD`.
const int zlibMaxDist = zlibWindowSize - zlibMinLookahead;

/// Hash table size for memory level 8 (`hash_size`).
const int zlibHashSize = 32768;

/// Hash mask (`hash_mask`).
const int zlibHashMask = zlibHashSize - 1;

/// Hash shift for memory level 8 (`hash_shift`).
const int zlibHashShift = 5;

/// Nil hash-chain head (`NIL` in `deflate.c`).
const int zlibNil = 0;

/// Level-9 chain search limit (`configuration_table[9].max_chain`).
const int zlibMaxChainLength = 4096;

/// Level-9 good-match threshold (`configuration_table[9].good_length`).
const int zlibGoodMatch = 32;

/// Level-9 lazy-match limit (`configuration_table[9].max_lazy`).
const int zlibMaxLazyMatch = 258;

/// Level-9 nice-match stop (`configuration_table[9].nice_length`).
const int zlibNiceMatch = 258;

/// Symbol buffer size for memory level 8 (`lit_bufsize`).
const int zlibLitBufsize = 16384;

/// Symbol buffer flush threshold (`sym_end`): `(lit_bufsize - 1) * 3`.
const int zlibSymEnd = (zlibLitBufsize - 1) * 3;

/// Guard bytes zeroed past fresh input (`WIN_INIT` in `deflate.h`).
const int zlibWinInit = zlibMaxMatch;

/// A single Huffman tree: parallel `freq`/`len`/`code`/`dad` arrays.
///
/// This mirrors one `ct_data` array plus its `tree_desc.max_code`.
class ZlibRawTree {
  /// Frequency (or, after code generation, bit-string) per code.
  final List<int> freq;

  /// Bit length per code.
  final List<int> len;

  /// Huffman code per code.
  final List<int> code;

  /// Father node per code while the tree is being built.
  final List<int> dad;

  /// Largest code with non-zero frequency.
  int maxCode = -1;

  /// Creates a tree with room for [size] codes, all zeroed.
  ZlibRawTree(int size)
    : freq = List<int>.filled(size, 0),
      len = List<int>.filled(size, 0),
      code = List<int>.filled(size, 0),
      dad = List<int>.filled(size, 0);
}

/// Compressor state: a port of zlib 1.3.2's `deflate_state`.
class ZlibRawState {
  /// The input being compressed.
  final Uint8List input;

  /// Next unread input position (`strm->next_in` offset).
  int nextIn = 0;

  /// Unread input bytes remaining (`strm->avail_in`).
  int availIn;

  /// Sliding window, zero-initialised (`window`, `window_size` bytes).
  final Uint8List window = Uint8List(zlibWindowAllocation);

  /// Links to older strings with the same hash (`prev`, `w_size` entries).
  final Uint16List prev = Uint16List(zlibWindowSize);

  /// Heads of the hash chains (`head`, `hash_size` entries).
  final Uint16List head = Uint16List(zlibHashSize);

  /// Running hash key for the string at `strstart` (`ins_h`).
  int insH = 0;

  /// Start of the string to insert (`strstart`).
  int strstart = 0;

  /// Start of the matching string (`match_start`).
  int matchStart = 0;

  /// Previous match start (`prev_match`).
  int prevMatch = 0;

  /// Valid bytes ahead in the window (`lookahead`).
  int lookahead = 0;

  /// Length of the best match (`match_length`).
  int matchLength = zlibMinMatch - 1;

  /// Best match length at the previous step (`prev_length`).
  int prevLength = zlibMinMatch - 1;

  /// Whether a previous match is pending (`match_available`).
  int matchAvailable = 0;

  /// Window position at the start of the current block (`block_start`).
  int blockStart = 0;

  /// Bytes at the end of the window left to insert (`insert`).
  int insert = 0;

  /// Match count in the current block (`matches`).
  int matches = 0;

  /// Running index in [symBuf] (`sym_next`).
  int symNext = 0;

  /// Literal/length and distance symbol buffer (`sym_buf`).
  final Uint8List symBuf = Uint8List(zlibSymEnd);

  /// Pending compressed output bytes (`pending_buf`/`pending`).
  final List<int> pending = <int>[];

  /// Bit buffer (`bi_buf`); valid bits are always below bit 16.
  int biBuf = 0;

  /// Number of valid bits in [biBuf] (`bi_valid`).
  int biValid = 0;

  /// Bits used at the last byte boundary (`bi_used`).
  int biUsed = 0;

  /// Bit length of the block with optimal trees (`opt_len`).
  int optLen = 0;

  /// Bit length of the block with static trees (`static_len`).
  int staticLen = 0;

  /// High-water mark of initialised window bytes (`high_water`).
  int highWater = 0;

  /// Whether the hash table was slid since it was cleared (`slid`).
  int slid = 0;

  /// Literal/length tree (`dyn_ltree`, `HEAP_SIZE` entries).
  final ZlibRawTree dynLtree = ZlibRawTree(573);

  /// Distance tree (`dyn_dtree`, `2 * D_CODES + 1` entries).
  final ZlibRawTree dynDtree = ZlibRawTree(61);

  /// Bit-length tree (`bl_tree`, `2 * BL_CODES + 1` entries).
  final ZlibRawTree blTree = ZlibRawTree(39);

  /// Bit-length counts (`bl_count`).
  final List<int> blCount = List<int>.filled(16, 0);

  /// Heap for Huffman tree construction (`heap`).
  final List<int> heap = List<int>.filled(573, 0);

  /// Number of elements in [heap] (`heap_len`).
  int heapLen = 0;

  /// Start of the sorted-nodes area in [heap] (`heap_max`).
  int heapMax = 573;

  /// Subtree depths used as a frequency tie breaker (`depth`).
  final List<int> depth = List<int>.filled(573, 0);

  /// Creates compressor state for [input].
  ZlibRawState(this.input) : availIn = input.length;
}

/// Updates the running hash with one input byte (`UPDATE_HASH`).
int zlibUpdateHash(int hash, int byte) =>
    (((hash) << zlibHashShift) ^ byte) & zlibHashMask;

/// Inserts the string at [str] and returns the previous chain head.
///
/// This is `INSERT_STRING` without `FASTEST`: the hash key is updated with
/// `window[str + MIN_MATCH - 1]`, the old head becomes both the return value
/// and `prev[str & w_mask]`, and `head[ins_h]` becomes `str`.
int zlibInsertString(ZlibRawState s, int str) {
  s.insH = zlibUpdateHash(s.insH, s.window[str + zlibMinMatch - 1]);
  final int matchHead = s.head[s.insH];
  s.prev[str & (zlibWindowSize - 1)] = matchHead;
  s.head[s.insH] = str;
  return matchHead;
}

/// Slides the hash chains down by one window half (`slide_hash`).
void zlibSlideHash(ZlibRawState s) {
  var n = zlibHashSize;
  var p = zlibHashSize;
  do {
    final int m = s.head[--p];
    s.head[p] = m >= zlibWindowSize ? m - zlibWindowSize : 0;
  } while (--n != 0);
  n = zlibWindowSize;
  p = zlibWindowSize;
  do {
    final int m = s.prev[--p];
    s.prev[p] = m >= zlibWindowSize ? m - zlibWindowSize : 0;
  } while (--n != 0);
  s.slid = 1;
}

/// Copies [length] input bytes into the window (`read_buf` without adler).
///
/// The raw stream (`wrap == 0`) never updates a checksum, so only the copy
/// and the input cursor move are ported.
void zlibReadWindow(ZlibRawState s, int offset, int length) {
  var len = s.availIn;
  if (len > length) len = length;
  if (len == 0) return;
  s.availIn -= len;
  s.window.setRange(offset, offset + len, s.input, s.nextIn);
  s.nextIn += len;
}

/// Moves the second window half down when the window fills (`fill_window` arm).
///
/// Split out unchanged so the fill loop stays under the complexity budget.
/// Returns the updated free-space count after the slide.
int _slideWindow(ZlibRawState s, int more) {
  if (s.strstart < zlibWindowSize + zlibMaxDist) return more;
  final int copyCount = zlibWindowSize - more;
  final Uint8List moved = s.window.sublist(
    zlibWindowSize,
    zlibWindowSize + copyCount,
  );
  s.window.setRange(0, copyCount, moved);
  s.matchStart -= zlibWindowSize;
  s.strstart -= zlibWindowSize;
  s.blockStart -= zlibWindowSize;
  if (s.insert > s.strstart) s.insert = s.strstart;
  zlibSlideHash(s);
  return more + zlibWindowSize;
}

/// Fills the window while lookahead is insufficient (`fill_window`).
///
/// The 16-bit `more` fixups are omitted: Dart integers are 64-bit. The
/// `high_water` zeroing is replicated verbatim; on the zero-initialised
/// [ZlibRawState.window] it is a no-op that documents the invariant the
/// longest-match search relies on.
void zlibFillWindow(ZlibRawState s) {
  do {
    var more = zlibWindowAllocation - s.lookahead - s.strstart;
    more = _slideWindow(s, more);
    if (s.availIn == 0) break;

    final int readAt = s.strstart + s.lookahead;
    final int before = s.availIn;
    zlibReadWindow(s, readAt, more);
    s.lookahead += before - s.availIn;

    if (s.lookahead + s.insert >= zlibMinMatch) {
      var str = s.strstart - s.insert;
      s.insH = s.window[str];
      s.insH = zlibUpdateHash(s.insH, s.window[str + 1]);
      while (s.insert != 0) {
        s.insH = zlibUpdateHash(s.insH, s.window[str + zlibMinMatch - 1]);
        s.prev[str & (zlibWindowSize - 1)] = s.head[s.insH];
        s.head[s.insH] = str;
        str++;
        s.insert--;
        if (s.lookahead + s.insert < zlibMinMatch) break;
      }
    }
  } while (s.lookahead < zlibMinLookahead && s.availIn != 0);

  if (s.highWater < zlibWindowAllocation) {
    final int curr = s.strstart + s.lookahead;
    if (s.highWater < curr) {
      var init = zlibWindowAllocation - curr;
      if (init > zlibWinInit) init = zlibWinInit;
      s.window.fillRange(curr, curr + init, 0);
      s.highWater = curr + init;
    } else if (s.highWater < curr + zlibWinInit) {
      var init = curr + zlibWinInit - s.highWater;
      if (init > zlibWindowAllocation - s.highWater) {
        init = zlibWindowAllocation - s.highWater;
      }
      s.window.fillRange(s.highWater, s.highWater + init, 0);
      s.highWater += init;
    }
  }
}

/// Resets the per-block tree frequencies (`init_block`).
void zlibInitBlock(ZlibRawState s) {
  s.dynLtree.freq.fillRange(0, s.dynLtree.freq.length, 0);
  s.dynDtree.freq.fillRange(0, s.dynDtree.freq.length, 0);
  s.blTree.freq.fillRange(0, s.blTree.freq.length, 0);
  s.dynLtree.freq[256] = 1;
  s.optLen = 0;
  s.staticLen = 0;
  s.symNext = 0;
  s.matches = 0;
}

/// Initialises the compressor (`lm_init` plus the `_tr_init` essentials).
///
/// The static Huffman tables are compile-time constants
/// (`zlib_raw_tables.dart`), so `tr_static_init` needs no port; the tree
/// descriptors only select which constant table each dynamic tree uses.
void zlibInitState(ZlibRawState s) {
  s.head.fillRange(0, s.head.length, 0);
  s.slid = 0;
  s.strstart = 0;
  s.blockStart = 0;
  s.lookahead = 0;
  s.insert = 0;
  s.matchLength = zlibMinMatch - 1;
  s.prevLength = zlibMinMatch - 1;
  s.matchAvailable = 0;
  s.insH = 0;
  s.biBuf = 0;
  s.biValid = 0;
  s.biUsed = 0;
  s.highWater = 0;
  zlibInitBlock(s);
}
