/// One native counter bound under two packages' asset ids, which the app
/// serves from one combined library (`//:counter`).
library;

import 'dart:ffi';

@Native<Int32 Function()>(
  assetId: 'package:count_a/count_a',
  symbol: 'counter_bump',
)
external int _bumpThroughA();

@Native<Int32 Function()>(
  assetId: 'package:count_b/count_b',
  symbol: 'counter_bump',
)
external int _bumpThroughB();

/// The count after one bump through each id: 2 when both ids reached one
/// loaded image of the library, 1 when each got a copy of its own.
int sharedCount() {
  _bumpThroughA();
  return _bumpThroughB();
}
