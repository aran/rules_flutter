import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_linux/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:linux_greeting_plugin/linux_greeting_plugin.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'increments counter, decodes asset image, and calls Linux C++ plugin',
    (tester) async {
      await tester.pumpWidget(const CounterApp());
      await tester.pumpAndSettle();

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

      final greeting = await const LinuxGreetingPlugin().getGreeting();
      expect(greeting, 'Hello from Linux C++ plugin!');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey<String>('plugin_greeting')))
            .data,
        'Hello from Linux C++ plugin!',
      );
    },
  );
}
