/// `sub`, reached the way a bridge generator's bindings reach their library:
/// through `@Native` and an asset id, with the library delivered as a code
/// asset on this package rather than named by the app.
@DefaultAsset('package:sub_asset/sub')
library;

import 'dart:ffi';

/// Call the native `sub` function.
@Native<Int32 Function(Int32, Int32)>()
external int sub(int a, int b);
