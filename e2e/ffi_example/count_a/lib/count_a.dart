/// One of two packages binding the same native counter, each under its own
/// asset id, as two bridges linked into one shared library are.
@DefaultAsset('package:count_a/count_a')
library;

import 'dart:ffi';

/// Bumps the counter through this package's asset id, returning the count.
@Native<Int32 Function()>(symbol: 'counter_bump')
external int bumpThroughA();
