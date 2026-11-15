import 'package:custom_engine/main.dart' as app;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The web render check (docs/TESTING.md, section 5) over an app built against
/// the stand-in checkout's web SDK.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app draws its screen from the framework', (tester) async {
    app.main();
    await tester.pumpAndSettle();
    expect(find.text('Custom engine'), findsOneWidget);
  });

  testWidgets('the build described the selected SDK to the program', (
    tester,
  ) async {
    // The stand-in checkout is not a git repository: no framework revision.
    expect(FlutterVersion.version, '3.50.0');
    expect(FlutterVersion.frameworkRevision, isEmpty);
    expect(FlutterVersion.engineRevision, '371f77202a');
  });
}
