/// A package binding a native counter under its own asset id, with a
/// standalone library of its own. `//:shared_library_asset_test` serves the id
/// from a library it shares with a second id instead.
@DefaultAsset('package:shared_counter/shared_counter')
library;

import 'dart:ffi';

/// Bumps the counter through this package's asset id, returning the count.
@Native<Int32 Function()>(symbol: 'counter_bump')
external int bumpThroughPackage();
