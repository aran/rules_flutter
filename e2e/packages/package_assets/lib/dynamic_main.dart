// A `Glyph` built at run time, which `glyphs`' link hook refuses.

import 'package:glyphs/glyphs.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final name = DateTime.now().isUtc ? 'star' : 'heart';
  runApp(Text('${Glyph(name)}', textDirection: TextDirection.ltr));
}
