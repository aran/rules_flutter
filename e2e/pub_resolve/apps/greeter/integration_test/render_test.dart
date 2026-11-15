import 'package:flutter_test/flutter_test.dart';
import 'package:greeter/main.dart' as app;
import 'package:integration_test/integration_test.dart';

/// The render check of docs/TESTING.md § 5, run in headless Chrome by
/// `:render_test`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app draws the greeting its path packages make', (
    tester,
  ) async {
    app.main();
    await tester.pumpAndSettle();

    expect(
      find.text('Hello from greeting — 1234 (forked intl) — tagline'),
      findsOneWidget,
    );
  });
}
