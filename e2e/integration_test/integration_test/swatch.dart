import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// The golden of the swatch on this platform. A golden is a function of the
/// platform that rendered it, so each platform keeps its own beside the test:
/// `goldens/macOS/swatch.png`, `goldens/windows/swatch.png`,
/// `goldens/linux/swatch.png`, `goldens/web/swatch.png`.
String get goldenPath =>
    'goldens/${kIsWeb ? 'web' : defaultTargetPlatform.name}/swatch.png';

/// What the swatch tests draw: a flat, text-free square of a fixed logical
/// size, so what is compared depends on no font and no window size.
/// `matchesGoldenFile` captures it at one device pixel per logical pixel, so
/// the same picture is made on a phone, a Retina display and a browser.
Widget swatch(Color color) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: RepaintBoundary(
      child: SizedBox(
        key: const ValueKey('swatch'),
        width: 64,
        height: 64,
        child: ColoredBox(color: color),
      ),
    ),
  ),
);
