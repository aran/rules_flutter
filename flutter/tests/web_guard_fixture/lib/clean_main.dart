import 'dart:ui';

import 'helper.dart';

void main() {
  final grown = grow(const Size(1, 2), 3);
  assert(grown == 5, 'grow() should add to the area');
}
