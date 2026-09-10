import 'dart:async';

import 'package:test/test.dart';

import 'test_lifetime.dart';

void main() {
  group('spawnBoundToTest', () {
    // The real `addTearDown` path. It cannot be asserted from inside the test
    // that registers it — the teardown runs after the body — so the resource is
    // recorded here and the test below reads it back. That split is what makes
    // deleting the registration inside spawnBoundToTest fail a test.
    final disposedForReal = <String>[];

    test(
      'hands the resource back and leaves it alone while the test runs',
      () async {
        final resource = await spawnBoundToTest(
          spawn: () async => 'live-resource',
          dispose: (r) async => disposedForReal.add(r),
        );
        expect(resource, 'live-resource');
        expect(
          disposedForReal,
          isEmpty,
          reason: 'nothing should be disposed while the test is still running',
        );
      },
    );

    test('disposed it on the real test teardown of the test above', () {
      expect(disposedForReal, ['live-resource']);
    });

    test('disposes a spawn that lands after the test already ended', () async {
      final disposed = <String>[];
      final spawnGate = Completer<String>();
      late FutureOr<dynamic> Function() teardown;

      final pending = spawnBoundToTest(
        spawn: () => spawnGate.future,
        dispose: (r) async => disposed.add(r),
        register: (callback) => teardown = callback,
      );

      // The test ends — package:test runs its teardowns — while the spawn is
      // still in flight, so there is nothing yet for the teardown to dispose.
      await teardown();
      expect(disposed, isEmpty);

      // The abandoned frame runs on and spawns anyway — the case a post-spawn
      // registration cannot cover.
      spawnGate.complete('late-resource');
      await expectLater(pending, throwsA(isA<StateError>()));
      expect(disposed, [
        'late-resource',
      ], reason: 'the late spawn must not be left running');
    });

    test(
      'refuses to hand back a resource the test can no longer use',
      () async {
        final spawnGate = Completer<String>();
        late FutureOr<dynamic> Function() teardown;

        final pending = spawnBoundToTest(
          spawn: () => spawnGate.future,
          dispose: (_) async {},
          register: (callback) => teardown = callback,
        );

        await teardown();
        spawnGate.complete('late-resource');
        await expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('the test ended while this was still starting up'),
            ),
          ),
        );
      },
    );

    test('a spawn that fails leaves nothing to dispose', () async {
      final disposed = <String>[];
      late FutureOr<dynamic> Function() teardown;

      await expectLater(
        spawnBoundToTest<String>(
          spawn: () async => throw StateError('spawn failed'),
          dispose: (r) async => disposed.add(r),
          register: (callback) => teardown = callback,
        ),
        throwsA(isA<StateError>()),
      );

      await teardown();
      expect(disposed, isEmpty);
    });
  });
}
