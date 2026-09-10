/// A `flutter_web_bundle` `main` that lives *inside* its package's `lib/`, the
/// ordinary shape for a web app (`flutter_web_app` defaults to
/// `lib/main.dart`).
///
/// It is reachable as `package:flutter_web_analyze_fixture/main.dart`, so the
/// rule routes it to `package_srcs`. Analysis cannot tell the two lists apart —
/// both stage by `short_path` — so what this file guards is that the entrypoint
/// reaches the analyzer at all, whichever list it lands in.
library;

import 'dart:ui';

import 'package:flutter_web_analyze_fixture/greeting.dart';

void main() {
  final grown = grow(const Size(1, 2), 3);
  assert(grown.width == 4, 'grow() should add to width');
}
