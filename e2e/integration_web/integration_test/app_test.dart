import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:integration_web/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'increments counter to 3 and decodes bundled asset image',
    (tester) async {
      await tester.pumpWidget(const CounterApp());

      expect(find.text('0'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('app_logo')), findsOneWidget);

      final incrementButton = find.byKey(
        const ValueKey<String>('increment_button'),
      );
      for (var i = 0; i < 3; i++) {
        await tester.tap(incrementButton);
        await tester.pump();
      }

      expect(find.text('3'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey<String>('counter_text')))
            .data,
        '3',
      );

      final assetBytes = await rootBundle.load('assets/logo.png');
      final codec = await ui.instantiateImageCodec(
        assetBytes.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThan(0));
      expect(frame.image.height, greaterThan(0));
      frame.image.dispose();
      codec.dispose();
    },
  );
}
