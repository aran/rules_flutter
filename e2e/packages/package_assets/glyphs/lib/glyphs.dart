/// Named glyphs an app draws. Which ones it uses is decided at link time.
library;

import 'package:meta/meta.dart' show RecordUse;

/// A glyph, named the way the icon set names it.
///
/// Construct it with `const`: the package's link hook reads each constant's
/// [name] from the compiler's recorded uses to decide which glyphs to ship,
/// and refuses any `Glyph` built at run time, whose name it cannot know.
@RecordUse()
final class Glyph {
  /// Creates the glyph called [name].
  const Glyph(this.name);

  /// The glyph's name in the icon set.
  final String name;

  @override
  String toString() => 'Glyph($name)';
}
