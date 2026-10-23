import 'package:flutter/material.dart';

class WebIconPlugin {
  static const IconData icon = Icons.a;

  static void registerWith(Object? registrar) {
    final keep = <Object?>[icon, registrar];
    if (keep.isEmpty) {
      throw StateError('unreachable');
    }
  }
}
