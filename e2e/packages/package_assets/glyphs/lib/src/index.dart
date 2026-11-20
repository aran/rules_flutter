/// The JSON the link hook writes for the glyphs an app uses. Pure Dart, so the
/// hook can import it from the package's own `lib/`.
library;

import 'dart:convert';

/// The index of [names], sorted.
String glyphIndex(Set<String> names) => jsonEncode(names.toList()..sort());
