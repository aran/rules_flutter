/// Flutter plugin code, analyzed by rules_dart's `dart_analyze` aspect.
///
/// `dart:ui` resolves only through `package:sky_engine`'s `lib/_embedder.yaml`,
/// which `flutter_plugin` adds to the analyzer's closure itself. Without it
/// every reference below is undefined.
library;

import 'dart:ui';

TextRange widened(TextRange r) => TextRange(start: r.start - 1, end: r.end + 1);

Rect caret(Offset at, double height) => Rect.fromLTWH(at.dx, at.dy, 1, height);
