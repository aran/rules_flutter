// package:integration_test, built from the pinned Flutter source, compiles and
// its binding runs under flutter_tester.
//
// `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` is what every
// integration test calls first; pumping a widget afterwards shows the binding
// drives frames. The property is that the package is usable at all: a Flutter
// SDK package that `flutter pub get` writes into the lock as `source: sdk` is a
// library a test can depend on, not an entry the hub merely lists.

import 'package:flutter_test/flutter_test.dart';
import 'package:hello_world/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the integration binding pumps a widget', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(binding, isA<IntegrationTestWidgetsFlutterBinding>());
    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
  });
}
