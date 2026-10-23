/// Level-9 match search and driver for the raw-deflate compressor.
///
/// A line-by-line port of zlib 1.3.2 `deflate.c`'s `deflate_slow` and the
/// byte-wise `longest_match` (without `UNALIGNED_OK`, which neither aapt2
/// nor CPython define), fixed at level 9 with the default strategy.
/// `check_match` is `ZLIB_DEBUG`-only and omitted. The driver compresses in one shot: the whole input is resident, so window
/// exhaustion implies `Z_FINISH` and `avail_out` is unbounded.
library;

import 'dart:typed_data';

import 'zlib_raw_state.dart';
import 'zlib_raw_trees.dart';

/// Matches of length 3 are discarded above this distance (`TOO_FAR`).
const int zlibTooFar = 4096;

/// Advances one candidate match eight bytes at a time.
///
/// This is the inner run loop of `longest_match`, split out unchanged so the
/// search stays under the complexity budget. Returns the scan position where
/// the run stops: the first mismatch, or the first position at/past [strend].
int _scanRun(ZlibRawState s, int si, int mi, int strend) {
  while (true) {
    var matched = true;
    for (var k = 0; k < 8; k++) {
      si++;
      mi++;
      if (s.window[si] != s.window[mi]) {
        matched = false;
        break;
      }
    }
    if (!matched) break;
    if (si >= strend) break;
  }
  return si;
}

/// Finds the longest match for the string at `strstart` (`longest_match`).
///
/// Returns the match length capped at the lookahead; the start of the best
/// match is stored in `s.matchStart`. The two-byte-at-a-time path is not
/// ported: `UNALIGNED_OK` is never defined by the reference builds.
int zlibLongestMatch(ZlibRawState s, int curMatch) {
  var chainLength = zlibMaxChainLength;
  final int strstart = s.strstart;
  var bestLen = s.prevLength;
  var niceMatch = zlibNiceMatch;
  final int limit = strstart > zlibMaxDist ? strstart - zlibMaxDist : 0;
  const int wmask = zlibWindowSize - 1;
  final int strend = strstart + zlibMaxMatch;
  var scanEnd1 = s.window[strstart + bestLen - 1];
  var scanEnd = s.window[strstart + bestLen];
  if (s.prevLength >= zlibGoodMatch) chainLength >>= 2;
  if (niceMatch > s.lookahead) niceMatch = s.lookahead;
  var cur = curMatch;
  while (true) {
    if (s.window[cur + bestLen] == scanEnd &&
        s.window[cur + bestLen - 1] == scanEnd1 &&
        s.window[cur] == s.window[strstart] &&
        s.window[cur + 1] == s.window[strstart + 1]) {
      final int si = _scanRun(s, strstart + 2, cur + 2, strend);
      final int len = zlibMaxMatch - (strend - si);
      if (len > bestLen) {
        s.matchStart = cur;
        bestLen = len;
        if (len >= niceMatch) break;
        scanEnd1 = s.window[strstart + bestLen - 1];
        scanEnd = s.window[strstart + bestLen];
      }
    }
    cur = s.prev[cur & wmask];
    if (cur <= limit) break;
    chainLength--;
    if (chainLength == 0) break;
  }
  if (bestLen <= s.lookahead) return bestLen;
  return s.lookahead;
}

/// Flushes the current block without forcing stream exit (`FLUSH_BLOCK`).
///
/// `avail_out` is unbounded in this port, so the `need_more`/`finish_started`
/// exits of the C macro are unreachable and omitted.
void zlibFlushBlock(ZlibRawState s, int last) {
  final int bufStart = s.blockStart >= 0 ? s.blockStart : -1;
  zlibTrFlushBlock(s, bufStart, s.strstart - s.blockStart, last);
  s.blockStart = s.strstart;
}

/// Outputs the previous match and inserts its strings (`deflate_slow` arm).
void zlibEmitPrevMatch(ZlibRawState s) {
  final int maxInsert = s.strstart + s.lookahead - zlibMinMatch;
  final bool bflush = zlibTallyDist(
    s,
    s.strstart - 1 - s.prevMatch,
    s.prevLength - 3,
  );
  s.lookahead -= s.prevLength - 1;
  s.prevLength -= 2;
  do {
    if (++s.strstart <= maxInsert) {
      zlibInsertString(s, s.strstart);
    }
  } while (--s.prevLength != 0);
  s.matchAvailable = 0;
  s.matchLength = zlibMinMatch - 1;
  s.strstart++;
  if (bflush) zlibFlushBlock(s, 0);
}

/// Compresses with the level-9 lazy matcher (`deflate_slow` at `Z_FINISH`).
void zlibDeflateSlow(ZlibRawState s) {
  for (;;) {
    if (s.lookahead < zlibMinLookahead) {
      zlibFillWindow(s);
      if (s.lookahead == 0) break;
    }
    var hashHead = zlibNil;
    if (s.lookahead >= zlibMinMatch) {
      hashHead = zlibInsertString(s, s.strstart);
    }
    s.prevLength = s.matchLength;
    s.prevMatch = s.matchStart;
    s.matchLength = zlibMinMatch - 1;
    if (hashHead != zlibNil &&
        s.prevLength < zlibMaxLazyMatch &&
        s.strstart - hashHead <= zlibMaxDist) {
      s.matchLength = zlibLongestMatch(s, hashHead);
      // A length-3 match past TOO_FAR is discarded. The C condition also
      // fires for the filtered strategy at lengths below 6, but the strategy
      // is pinned to the default here, and `TOO_FAR <= 32767` keeps the
      // distance arm compiled in, so only this arm can fire.
      if (s.matchLength == zlibMinMatch &&
          s.strstart - s.matchStart > zlibTooFar) {
        s.matchLength = zlibMinMatch - 1;
      }
    }
    if (s.prevLength >= zlibMinMatch && s.matchLength <= s.prevLength) {
      zlibEmitPrevMatch(s);
    } else if (s.matchAvailable != 0) {
      if (zlibTallyLit(s, s.window[s.strstart - 1])) {
        zlibFlushBlock(s, 0);
      }
      s.strstart++;
      s.lookahead--;
    } else {
      s.matchAvailable = 1;
      s.strstart++;
      s.lookahead--;
    }
  }
  if (s.matchAvailable != 0) {
    zlibTallyLit(s, s.window[s.strstart - 1]);
    s.matchAvailable = 0;
  }
  s.insert = s.strstart < zlibMinMatch - 1 ? s.strstart : zlibMinMatch - 1;
  zlibFlushBlock(s, 1);
}

/// Compresses [input] with raw level-9 deflate, returning the byte stream.
///
/// This is the size probe the APK overlay uses for its store-vs-deflate
/// decision: the payload bytes stay at the overlay's normal level.
Uint8List zlibRawDeflate9(Uint8List input) {
  final ZlibRawState s = ZlibRawState(input);
  zlibInitState(s);
  zlibDeflateSlow(s);
  return Uint8List.fromList(s.pending);
}
