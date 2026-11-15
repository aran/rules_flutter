import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import '../swatch.dart';

/// An orange swatch against the blue golden, which passes only because this
/// directory's `flutter_test_config.dart` installs a comparator that tolerates
/// the difference: the golden service ran the config.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a config comparator tolerates a differing swatch', (
    tester,
  ) async {
    await tester.pumpWidget(swatch(const Color(0xFFFF9800)));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey('swatch')),
      matchesGoldenFile(goldenPath),
    );
  });
}
