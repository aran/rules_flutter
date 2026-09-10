/// The contract [FakeVmService] stands in for, asserted against *both* the real
/// `package:vm_service` client and the fake.
///
/// Every test here runs twice over the same closure, because an assertion only
/// about the fake proves what the fake does — which may be a shape no real
/// connection produces.
///
/// The real client is cheap to run for real: `VmService` takes an arbitrary
/// `Stream<String>` and a write callback, so an in-memory controller *is* a
/// genuine instance — no socket, no VM, no I/O. There is no reason to assert
/// this contract against anything less.
///
/// Deliberately narrow: only the connection-lifecycle behaviour the fake claims
/// to reproduce. It is not a re-test of `package:vm_service`.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

/// One live connection, plus the two ways it can end.
///
/// The ways of ending are bound to the instance rather than passed the service
/// afterwards, because a socket hang-up is only expressible from the side that
/// owns the input stream — which, for the real client, is whoever constructed
/// it.
class _Connection {
  final VmService service;

  /// End it the way a caller ends it.
  final Future<void> Function() dispose;

  /// End it the way the *socket* ends it: the peer hangs up, nobody asked.
  final Future<void> Function() hangUp;

  _Connection(this.service, {required this.dispose, required this.hangUp});
}

/// How one implementation is built, so the assertions below can be written once.
class _Subject {
  final String label;
  final _Connection Function() connect;

  _Subject(this.label, this.connect);
}

/// Issue an RPC and report how it refused: synchronously, or by a future.
///
/// The distinction is the contract. `VmService._call` is an ordinary
/// `Future`-returning method rather than an `async` one, and every endpoint is
/// `Future<X> foo() => _call('foo')`, so on a disposed connection the throw
/// leaves the call itself — it never becomes a value to await. Code written
/// against that (`try`/`catch` around an un-awaited call) behaves differently
/// from code handed a rejected future, so a fake that only rejects is a fake
/// that cannot fail a test the wire fails.
({Object? sync, bool returnedFuture}) _refusal(VmService service) {
  Future<VM>? pending;
  try {
    pending = service.getVM();
  } catch (e) {
    return (sync: e, returnedFuture: false);
  }
  // Never leave the rejection unhandled: this test must fail on its own
  // assertion, not be taken down by a stray asynchronous error.
  pending.then<void>((_) {}, onError: (Object _) {});
  return (sync: null, returnedFuture: true);
}

void main() {
  final subjects = [
    // A real client over an in-memory stream. Nothing answers it, which is all
    // these cases need: they are about a connection ending, not about RPCs.
    _Subject('real VmService', () {
      final inbound = StreamController<String>();
      final service = VmService(inbound.stream, (_) {});
      return _Connection(
        service,
        dispose: () => service.dispose(),
        // The constructor wires the input stream's `onDone` straight to
        // `dispose()`, so closing the stream is precisely a dropped socket.
        hangUp: () async {
          await inbound.close();
          await service.onDone;
        },
      );
    }),
    _Subject('FakeVmService', () {
      final fake = FakeVmService();
      return _Connection(
        fake,
        dispose: () => fake.dispose(),
        hangUp: () async => fake.simulateDisposed(),
      );
    }),
  ];

  for (final subject in subjects) {
    group(subject.label, () {
      test('refuses an RPC after dispose, synchronously', () async {
        final connection = subject.connect();
        await connection.dispose();

        final refusal = _refusal(connection.service);
        expect(
          refusal.returnedFuture,
          isFalse,
          reason:
              'a disposed connection throws out of the call itself; '
              'returning a future to reject is a shape the wire cannot '
              'produce',
        );
        expect(refusal.sync, isA<RPCError>());
        final error = refusal.sync! as RPCError;
        // -32000 (kServerError), not the -32010 kConnectionDisposed the same
        // enum defines: that constant exists but nothing raises it here, and
        // `VmServiceClient._isConnectionDisposed` keys on -32000.
        expect(error.code, -32000);
        expect(error.message, contains('Service connection disposed'));
      });

      test('refuses an RPC after the socket hangs up, the same way', () async {
        final connection = subject.connect();
        await connection.hangUp();

        final refusal = _refusal(connection.service);
        expect(refusal.returnedFuture, isFalse);
        expect((refusal.sync! as RPCError).code, -32000);
      });

      test(
        'completes onDone exactly once, and tolerates a second dispose',
        () async {
          final connection = subject.connect();
          var dones = 0;
          unawaited(connection.service.onDone.then((_) => dones++));

          await connection.dispose();
          await connection.dispose();
          await pumpEventQueue();

          expect(dones, 1);
        },
      );

      // `onDone` is reachable only from the end of `dispose()`, and a closed
      // input stream gets there by *calling* `dispose()` — so neither way of
      // ending a connection can complete it in the turn it stops answering
      // RPCs. A double that completes it inline is not merely early: it hands
      // the close to a listener while the state that listener reads is still
      // the state of a live connection.
      for (final ending in ['dispose', 'hang-up']) {
        test('a $ending does not complete onDone in the same turn', () async {
          final connection = subject.connect();
          var done = false;
          unawaited(connection.service.onDone.then((_) => done = true));

          // Started, not awaited: the question is what an observer sees in the
          // turn immediately after the connection ends.
          unawaited(
            ending == 'dispose' ? connection.dispose() : connection.hangUp(),
          );
          await null;

          expect(
            done,
            isFalse,
            reason:
                'the connection has only just ended; `onDone` reaching '
                'its listener this soon is a turn the wire never has',
          );
          // And it is a delay, not an absence.
          await connection.service.onDone.timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              fail('`onDone` never completed at all');
            },
          );
          expect(done, isTrue);
        });
      }

      test('a connection that has not ended answers every RPC', () async {
        // The negative case, so the cases above cannot pass by refusing always.
        final connection = subject.connect();
        var done = false;
        unawaited(connection.service.onDone.then((_) => done = true));
        await pumpEventQueue();

        expect(done, isFalse);
        // A live connection does not refuse: the call is made and simply waits
        // for an answer that, here, nobody sends.
        expect(_refusal(connection.service).returnedFuture, isTrue);
        await connection.dispose();
      });
    });
  }
}
