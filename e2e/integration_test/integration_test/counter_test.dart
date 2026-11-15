import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:integration_test_example/main.dart' as app;
import 'package:material_ui/material_ui.dart';

/// The two tests a passing integration test is made of: the app's own `main`
/// started in a real window, a tap, and the text it shows.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('counter starts at zero', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('counter increments when tapped', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('increment')));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
  });
}
