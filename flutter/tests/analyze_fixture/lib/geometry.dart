/// Flutter code, analyzed by rules_dart's `dart_analyze` aspect.
///
/// `dart:ui` resolves only through `package:sky_engine`'s `lib/_embedder.yaml`,
/// which `flutter_library` adds to the analyzer's closure itself. Without it
/// every reference below is undefined.
library;

import 'dart:ui';

Size doubled(Size s) => Size(s.width * 2, s.height * 2);

Offset midpoint(Rect r) => r.center;
