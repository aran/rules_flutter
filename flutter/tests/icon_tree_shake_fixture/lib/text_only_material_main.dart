import 'package:flutter/material.dart';

void main() {
  const style = TextStyle(fontFamily: 'MaterialIcons');
  if (style.fontFamily == null) {
    throw StateError('unreachable');
  }
}
