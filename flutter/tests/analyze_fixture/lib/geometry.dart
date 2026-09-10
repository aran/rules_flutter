/// Flutter code, analyzed by `dart_analyze_test`.
///
/// `dart:ui` resolves only because `@flutter_sky_engine//:sky_engine` is on
/// this library's `deps` and carries `lib/_embedder.yaml` as a `resources`
/// member. Drop that dep and every reference below becomes undefined.
library;

import 'dart:ui';

Size doubled(Size s) => Size(s.width * 2, s.height * 2);

Offset midpoint(Rect r) => r.center;
