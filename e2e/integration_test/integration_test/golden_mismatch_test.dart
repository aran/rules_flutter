import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'swatch.dart';

/// A swatch that does not match the golden committed for this platform: the
/// same swatch in another colour. It runs only under the red twins, which check
/// that a golden that does not match fails its target, names the golden, and
/// leaves the pictures of the failure.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an orange swatch matches the blue golden', (tester) async {
    await tester.pumpWidget(swatch(const Color(0xFFFF9800)));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey('swatch')),
      matchesGoldenFile(goldenPath),
    );
  });
}
