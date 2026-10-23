import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modular_greeter/greeter.dart';

void main() {
  testWidgets('greets the modular name', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Text(greet('modular')),
      ),
    );
    expect(find.text('Hello, modular!'), findsOneWidget);
  });
}
