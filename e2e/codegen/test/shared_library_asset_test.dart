// Proves two asset ids named to one library open one image of it under
// `flutter_tester`: the package's own id, which the test moves off the
// package's standalone library, and a second id bound here. Two copies would
// each keep their own count.
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_counter/shared_counter.dart';

@Native<Int32 Function()>(
  assetId: 'package:codegen_e2e/shared_counter',
  symbol: 'counter_bump',
)
external int _bumpThroughTest();

void main() {
  test('both ids move one count', () {
    final before = bumpThroughPackage();
    expect(_bumpThroughTest(), before + 1);
    expect(bumpThroughPackage(), before + 2);
  });
}
