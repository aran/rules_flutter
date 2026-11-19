import 'dart:async';

import 'package:flutter_bazel_dev_tool/teardown.dart';
import 'package:test/test.dart';

void main() {
  group('Teardown', () {
    test('disposes in reverse registration order', () async {
      final order = <String>[];
      final teardown = Teardown();
      await teardown.add(() async => order.add('first'));
      await teardown.add(() async => order.add('second'));
      await teardown.add(() async => order.add('third'));

      await teardown.run();

      expect(order, [
        'third',
        'second',
        'first',
      ], reason: 'resources come down the way they went up');
    });

    // `app.started` is emitted before the frontend server is created, so a
    // client that answers it with `daemon.shutdown` reaches teardown
    // mid-setup, and the resources set up behind it are registered late.
    test('disposes a resource registered after it has already run', () async {
      final teardown = Teardown();
      var disposed = false;

      await teardown.run();
      await teardown.add(() async => disposed = true);

      expect(
        disposed,
        isTrue,
        reason: 'a resource created after shutdown must not outlive it',
      );
    });

    // What a waiting command listens to: it has to fire as the teardown
    // begins, because the shutdown that began it may be waiting on that
    // command, and the run's own future would fire only after both.
    test('says it has started before anything is disposed', () async {
      final teardown = Teardown();
      final release = Completer<void>();
      await teardown.add(() => release.future);
      var started = false;
      unawaited(teardown.started.then((_) => started = true));

      final running = teardown.run();
      await Future<void>.delayed(Duration.zero);
      expect(started, isTrue);
      release.complete();
      await running;
    });

    test('reports whether it has run', () async {
      final teardown = Teardown();
      expect(teardown.hasRun, isFalse);
      await teardown.run();
      expect(teardown.hasRun, isTrue);
    });

    test('running twice does not dispose anything twice', () async {
      var disposals = 0;
      final teardown = Teardown();
      await teardown.add(() async => disposals++);

      await teardown.run();
      await teardown.run();

      expect(disposals, 1);
    });

    // A run is torn down from more than one place: a failure or the apps
    // ending starts it, and the command's own `finally` runs it again on the
    // way out. The second must not return while the first is still releasing
    // things, or the process exits with a bazel command or an app half
    // stopped.
    test('a second run waits for the one in progress to finish', () async {
      final release = Completer<void>();
      final teardown = Teardown();
      await teardown.add(() => release.future);

      final first = teardown.run();
      var secondDone = false;
      final second = teardown.run().then((_) => secondDone = true);
      await pumpEventQueue();
      expect(secondDone, isFalse, reason: 'the first is still disposing');

      release.complete();
      await Future.wait([first, second]);
      expect(secondDone, isTrue);
    });

    // A caller that gets no exception reads that as "everything was
    // released", whichever caller it is.
    test('a second run shares the first one\'s failure', () async {
      final teardown = Teardown();
      await teardown.add(() async => throw StateError('adb went away'));

      final first = expectLater(teardown.run(), throwsStateError);
      await expectLater(teardown.run(), throwsStateError);
      await first;
    });

    test('awaits each disposer before starting the next', () async {
      final order = <String>[];
      final teardown = Teardown();
      await teardown.add(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('slow');
      });
      await teardown.add(() async => order.add('fast'));

      await teardown.run();

      expect(order, [
        'fast',
        'slow',
      ], reason: 'a disposer that takes time still finishes before the next');
    });

    // The list is cleared up front, so a disposer that throws must not carry
    // the ones registered before it away with it — the app, the browser and
    // the compiler behind a failing step still have to be released.
    test('a disposer that throws does not take the rest with it', () async {
      final disposed = <String>[];
      final teardown = Teardown();
      await teardown.add(() async => disposed.add('first'));
      await teardown.add(() async => throw StateError('adb went away'));
      await teardown.add(() async => disposed.add('third'));

      await expectLater(teardown.run(), throwsStateError);

      // Reverse registration order, and the one behind the throw still ran.
      expect(disposed, ['third', 'first']);
    });

    // Bounding a teardown is not the same decision as tolerating a broken one:
    // a caller that gets no exception reads that as "everything was released".
    test('the first failure is the one that propagates', () async {
      final teardown = Teardown();
      await teardown.add(() async => throw StateError('registered first'));
      await teardown.add(() async => throw StateError('registered last'));

      // Disposal is reverse order, so the last registered throws first.
      await expectLater(
        teardown.run(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'registered last',
          ),
        ),
      );
    });

    test('an empty teardown runs cleanly', () async {
      await Teardown().run();
    });
  });
}
