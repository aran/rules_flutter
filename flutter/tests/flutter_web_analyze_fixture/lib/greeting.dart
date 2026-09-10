/// The fixture package's own `lib/`, reached from both entrypoints below as
/// `package:flutter_web_analyze_fixture/greeting.dart`.
///
/// That import is the point. A `flutter_web_bundle`'s `srcs` are its package's
/// library sources, so the analyzer has to be told the package exists — see the
/// `DartAnalyzableInfo` in `flutter_web_application.bzl`. Given the
/// package-less closure instead, this file is staged but unnamed, and the
/// imports below fail as `uri_does_not_exist`.
library;

import 'dart:ui';

/// Uses `dart:ui`, which resolves only through `package:sky_engine`'s
/// `lib/_embedder.yaml`. `flutter_web_bundle` puts that package in the analysis
/// closure itself, so no BUILD file has to name it.
Size grow(Size s, double by) => Size(s.width + by, s.height + by);
