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
      },
    );

    test('a handler awaiting an unavailable gate returns the reason', () async {
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

  group('ReadinessGate retryable', () {
    test('settles like any other verdict, so nothing waits on it', () async {
      // Settled, deliberately. A request arriving while the pipeline owes a
      // build is answered now, with a reason — not left on a signal that is
      // only coming if someone else asks for it. It is also what keeps a
      // caller's "nothing settled the gate" backstop from overwriting this
      // with a generic refusal.
      final gate = ReadinessGate()..signalRetryable('the build failed');

      await gate.whenReady; // must not hang
      expect(gate.isSettled, isTrue);
      expect(gate.isRetryable, isTrue);
      expect(gate.isReady, isFalse);
      expect(gate.unavailableReason, 'the build failed');
    });

    test('reopen makes requests queue on the new attempt', () async {
      final gate = ReadinessGate()..signalRetryable('the build failed');
      gate.reopen();

      expect(gate.isSettled, isFalse);
      expect(gate.isRetryable, isFalse);
      expect(
        gate.unavailableReason,
        isNull,
        reason:
            'the previous attempt is over; its reason is not this '
            "attempt's answer",
      );

      var settled = false;
      unawaited(gate.whenReady.then((_) => settled = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(settled, isFalse);

      gate.signalReady();
      await gate.whenReady;
      expect(gate.isReady, isTrue);
    });

    test('a second retryable failure can be reopened again', () async {
      final gate = ReadinessGate()..signalRetryable('first');
      gate.reopen();
      gate.signalRetryable('second');

      expect(gate.unavailableReason, 'second');
      expect(() => gate.reopen(), returnsNormally);
    });

    test('a ready or unavailable gate cannot be reopened', () {
      // Reopening a ready gate would take a working pipeline away from the
      // requests already queued behind it; reopening an unavailable one would
      // contradict the word. Both are bugs, and both are loud.
      expect(
        () => (ReadinessGate()..signalReady()).reopen(),
        throwsA(isA<StateError>()),
      );
      expect(
        () => (ReadinessGate()..signalUnavailable('gone')).reopen(),
        throwsA(isA<StateError>()),
      );
      expect(() => ReadinessGate().reopen(), throwsA(isA<StateError>()));
    });

    test('a retryable gate still refuses the request that found it', () async {
      // The request that arrives on a retryable gate is what triggers the next
      // attempt, but it is not owed a success — if that attempt fails too, the
      // reason it carries is the answer.
      final gate = ReadinessGate()..signalRetryable('the build failed');
      await gate.whenReady;
      expect(gate.isReady, isFalse);
      expect(gate.unavailableReason, 'the build failed');
    });
  });
}
