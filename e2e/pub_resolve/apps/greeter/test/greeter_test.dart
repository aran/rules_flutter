import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:greeter/main.dart';

void main() {
  testWidgets('the greeting joins an asset, a replaced hosted package and a '
      'path package', (tester) async {
    await tester.pumpWidget(const GreeterApp());

    // The asset is read from disk, which a widget test's fake clock does not
    // wait for: let real time pass until the greeting has been drawn.
    await tester.runAsync(() async {
      while (find.byKey(const ValueKey('greeting')).evaluate().isEmpty) {
        await Future<void>.delayed(Duration.zero);
        await tester.pump();
      }
    });

    expect(
      find.text('Hello from greeting — 1234 (forked intl) — tagline'),
      findsOneWidget,
    );
  });
}
