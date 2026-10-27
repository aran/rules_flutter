/// The second package binding the native counter; see `package:count_a`.
@DefaultAsset('package:count_b/count_b')
library;

import 'dart:ffi';

/// Bumps the counter through this package's asset id, returning the count.
@Native<Int32 Function()>(symbol: 'counter_bump')
external int bumpThroughB();
