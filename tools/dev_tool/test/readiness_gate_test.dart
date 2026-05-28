import 'dart:async';

import 'package:flutter_bazel_dev_tool/hot_reload/readiness_gate.dart';
import 'package:test/test.dart';

void main() {
  group('ReadinessGate', () {
    test('whenReady does not complete before any signal', () async {
      final gate = ReadinessGate();
      var completed = false;
      unawaited(gate.whenReady.then((_) => completed = true));

      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(completed, isFalse);
      expect(gate.isReady, isFalse);
      expect(gate.isSettled, isFalse);
      expect(gate.unavailableReason, isNull);
    });

    test('signalReady completes whenReady and sets isReady', () async {
      final gate = ReadinessGate();
      gate.signalReady();

      await gate.whenReady; // must not hang
      expect(gate.isReady, isTrue);
      expect(gate.isSettled, isTrue);
      expect(gate.unavailableReason, isNull);
    });

    test('signalUnavailable completes whenReady with a reason', () async {
      final gate = ReadinessGate();
      gate.signalUnavailable('No frontend server available');

      await gate.whenReady; // must not hang
      expect(gate.isReady, isFalse);
      expect(gate.isSettled, isTrue);
      expect(gate.unavailableReason, 'No frontend server available');
    });

    test('first signal wins; later signals are ignored', () async {
      final readyFirst = ReadinessGate()
        ..signalReady()
        ..signalUnavailable('too late');
      expect(readyFirst.isReady, isTrue);
      expect(readyFirst.unavailableReason, isNull);

      final unavailableFirst = ReadinessGate()
        ..signalUnavailable('boom')
        ..signalReady();
      expect(unavailableFirst.isReady, isFalse);
      expect(unavailableFirst.unavailableReason, 'boom');
    });

    test(
        'a handler that awaits the gate pends until ready, then proceeds',
        () async {
      // Models performHotReload: arrives on app.started (gate not yet
      // settled), awaits, and only then reads the outcome.
      final gate = ReadinessGate();

      Future<Map<String, dynamic>> handler() async {
        await gate.whenReady;
        if (!gate.isReady) {
          return {'error': gate.unavailableReason ?? 'unavailable'};
        }
        return {'message': 'Hot reload successful'};
      }

      final pending = handler();
      var settled = false;
      unawaited(pending.then((_) => settled = true));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(settled, isFalse, reason: 'handler must wait for setup');

      gate.signalReady();
      expect(await pending, {'message': 'Hot reload successful'});
    });

    test('a handler awaiting an unavailable gate returns the reason',
        () async {
      final gate = ReadinessGate();

      Future<Map<String, dynamic>> handler() async {
        await gate.whenReady;
        if (!gate.isReady) {
          return {'error': gate.unavailableReason ?? 'unavailable'};
        }
        return {'message': 'Hot reload successful'};
      }

      final pending = handler();
      gate.signalUnavailable('No frontend server available');
      expect(await pending, {'error': 'No frontend server available'});
    });
  });
}
