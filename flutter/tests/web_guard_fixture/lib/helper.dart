import 'dart:ui';

int _area(Size s) => (s.width * s.height).toInt();

int grow(Size s, int by) => _area(s) + by;
