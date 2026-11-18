/// `chain_top`, from a code asset whose library links another code asset's.
@DefaultAsset('package:chain_asset/top')
library;

import 'dart:ffi';

/// `chain_base(a) * 2`, called through the library `chain_top` links.
@Native<Int32 Function(Int32)>(symbol: 'chain_top')
external int chainTop(int a);
