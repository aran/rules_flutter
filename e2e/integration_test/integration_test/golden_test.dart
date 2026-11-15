import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'swatch.dart';

/// A swatch that matches the golden committed for this platform.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the swatch matches its golden', (tester) async {
    await tester.pumpWidget(swatch(const Color(0xFF2196F3)));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey('swatch')),
      matchesGoldenFile(goldenPath),
    );
  });
}
