/// The fixture package's own `lib/`, reached from the test below as
/// `package:flutter_test_analyze_fixture/counter.dart`.
///
/// That import is the point. A `flutter_test`'s `srcs` are its package's
/// library sources, so the analyzer has to be told the package exists — see
/// the `DartAnalyzableInfo` in `flutter_test.bzl`. Given the package-less
/// closure instead, this file is staged but unnamed, and the import below
/// fails as `uri_does_not_exist`.
library;

import 'dart:ui';

/// Uses `dart:ui`, which resolves only through `package:sky_engine`'s
/// `lib/_embedder.yaml`. `flutter_test` puts that package in the analysis
/// closure itself, so no BUILD file has to name it.
Size grow(Size s, double by) => Size(s.width + by, s.height + by);
