import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_bazel_dev_tool/command_failure.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:test/test.dart';

void main() {
  group('CommandRunner', () {
    late CommandRunner runner;

    setUp(() {
      runner = CommandRunner();
    });

    test('run executes registered handler', () async {
      runner.register('test.echo', (params) async {
        return {'echo': params['msg']};
      });

      final result = await runner.run('test.echo', {'msg': 'hello'});
      expect(result, {'echo': 'hello'});
    });

    test('run refuses an unregistered method', () async {
      expect(
        () => runner.run('nonexistent', {}),
        throwsA(
          isA<CommandFailure>().having(
            (e) => e.kind,
            'kind',
            CommandFailureKind.notFound,
          ),
        ),
      );
    });

    test('run propagates handler exceptions', () async {
      runner.register('test.fail', (_) async {
        throw StateError('boom');
      });

      expect(
        () => runner.run('test.fail', {}),
        throwsA(isA<StateError>()),
      );
    });

    test('concurrent calls execute sequentially', () async {
      final order = <int>[];
      final completer1 = Completer<void>();

      runner.register('test.slow', (_) async {
        order.add(1);
        await completer1.future;
        order.add(2);
        return {'done': true};
      });

      // Start first call — it will block on completer1.
      final future1 = runner.run('test.slow', {});
      // Give it a microtask to enter the handler.
      await Future<void>.delayed(Duration.zero);

      // Start second call — it should be queued behind first.
      runner.register('test.fast', (_) async {
        order.add(3);
        return {'done': true};
      });
      final future2 = runner.run('test.fast', {});

      // Release the first call.
      completer1.complete();
      await future1;
      await future2;

      // Second call must not start until first finishes.
      expect(order, [1, 2, 3]);
    });

    /// What a client is told it can call.
    ///
    /// The command set is not fixed when a client connects: it grows through
    /// the run — the reload and lifecycle commands, then the agent surface
    /// once the VM service is up, then `app.setViewport` once Chrome is
    /// launched — so a list captured at connect time describes almost nothing.
    /// That is why this is readable at any moment and announced when it moves.
    group('describe', () {
      test('names every registered command and which ones are slow', () {
        runner
          ..register('app.getText', (_) async => {})
          ..register('app.hotReload', (_) async => {}, longRunning: true);
        expect(runner.describe(), [
          // Sorted, so a client diffing two listings sees real changes rather
          // than registration order.
          {'name': 'app.getText', 'longRunning': false},
          {'name': 'app.hotReload', 'longRunning': true},
        ]);
      });

      test('is empty before anything is registered', () {
        expect(runner.describe(), isEmpty);
      });
    });

    group('change notification', () {
      test(
        'coalesces a burst of registrations into one announcement',
        () async {
          // `registerAgentCommands` registers eleven commands in a loop; an
          // event each would be eleven events describing one moment.
          var announcements = 0;
          final r = CommandRunner(onCommandsChanged: () => announcements++);
          for (final name in ['a', 'b', 'c']) {
            r.register(name, (_) async => {});
          }
          expect(announcements, 0, reason: 'not yet — same turn');
          await Future<void>.delayed(Duration.zero);
          expect(announcements, 1);
        },
      );

      test(
        'announces again when a later registration adds a command',
        () async {
          var announcements = 0;
          final r = CommandRunner(onCommandsChanged: () => announcements++);
          r.register('a', (_) async => {});
          await Future<void>.delayed(Duration.zero);
          expect(announcements, 1);
          r.register('b', (_) async => {});
          await Future<void>.delayed(Duration.zero);
          expect(announcements, 2);
        },
      );

      test(
        'stays quiet when a handler is replaced but the surface is not',
        () async {
          // The WASM assembler deliberately shadows `app.restart` and
          // `app.hotReload` with its own handlers after launch. The client's
          // view is unchanged, so saying so would be noise.
          var announcements = 0;
          final r = CommandRunner(onCommandsChanged: () => announcements++);
          r.register('app.restart', (_) async => {}, longRunning: true);
          await Future<void>.delayed(Duration.zero);
          expect(announcements, 1);
          r.register(
            'app.restart',
            (_) async => {'different': true},
            longRunning: true,
          );
          await Future<void>.delayed(Duration.zero);
          expect(announcements, 1, reason: 'same names, same flags');
        },
      );

      test(
        'announces when a replacement changes how long it may take',
        () async {
          // Same name, but a client choosing a timeout needs to know.
          var announcements = 0;
          final r = CommandRunner(onCommandsChanged: () => announcements++);
          r.register('app.restart', (_) async => {});
          await Future<void>.delayed(Duration.zero);
          r.register('app.restart', (_) async => {}, longRunning: true);
          await Future<void>.delayed(Duration.zero);
          expect(announcements, 2);
        },
      );
    });

    test('hasCommand returns true for registered, false otherwise', () {
      runner.register('test.cmd', (_) async => {});
      expect(runner.hasCommand('test.cmd'), isTrue);
      expect(runner.hasCommand('test.other'), isFalse);
    });

    // ---- Bounded-handler contract ----
    //
    // The pool is safe by virtue of "every handler completes." These
    // tests exercise the safety property at the runner level: no matter
    // how a handler ends — return, throw, slow-but-bounded — the pool
    // resource is released and the next command can run. Together with
    // the documentation comment in lib/command_runner.dart, they pin
    // the contract that this layer relies on.

    test(
      'pool resource is released after a handler returns normally — next command runs',
      () async {
        runner.register('first', (_) async => {'ok': true});
        runner.register('second', (_) async => {'ok': true});

        await runner.run('first', {});
        // If 'first' had not released the pool, this would hang.
        final r = await runner
            .run('second', {})
            .timeout(const Duration(seconds: 2));
        expect(r['ok'], isTrue);
      },
    );

    test(
      'pool resource is released after a handler throws — next command runs',
      () async {
        runner.register('failing', (_) async {
          throw StateError('intentional');
        });
        runner.register('next', (_) async => {'ok': true});

        await expectLater(
          runner.run('failing', {}),
          throwsA(isA<StateError>()),
        );
        // If the throwing handler hadn't released the pool, this would hang.
        final r = await runner
            .run('next', {})
            .timeout(const Duration(seconds: 2));
        expect(r['ok'], isTrue);
      },
    );

    test(
      'a slow-but-bounded handler does not block the queue indefinitely',
      () async {
        runner.register('slow', (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return {'ok': true};
        });
        runner.register('fast', (_) async => {'ok': true});

        final f1 = runner.run('slow', {});
        final f2 = runner.run('fast', {});

        await f1.timeout(const Duration(seconds: 2));
        await f2.timeout(const Duration(seconds: 2));
      },
    );
  });

  /// A command that communicates only when it finishes leaves one that never
  /// finishes indistinguishable from one that was never received — no
  /// acknowledgement, no partial state, nothing to bisect. These make the
  /// received-but-unfinished state real.
  group('long-running commands announce themselves', () {
    test('reports start before finish, paired by id', () async {
      final events = <String>[];
      final runner = CommandRunner(
        onProgress: (method, params, id, {required finished}) =>
            events.add('$method/$id/${finished ? 'end' : 'start'}'),
      );
      runner.register(
        'app.hotReload',
        (_) async => {'message': 'ok'},
        longRunning: true,
      );

      await runner.run('app.hotReload', {});

      expect(events, hasLength(2));
      expect(events[0], endsWith('/start'));
      expect(events[1], endsWith('/end'));
      final startId = events[0].split('/')[1];
      final endId = events[1].split('/')[1];
      expect(startId, endId, reason: 'the pair has to be correlatable');
    });

    test('a command that never finishes still announced its start', () async {
      // The handler blocks forever. With the transport emitting nothing at all,
      // a hang and a dropped request look alike.
      final events = <String>[];
      final runner = CommandRunner(
        onProgress: (method, params, id, {required finished}) =>
            events.add(finished ? 'end' : 'start'),
      );
      runner.register(
        'app.restart',
        (_) => Completer<Map<String, dynamic>>().future,
        longRunning: true,
      );

      unawaited(runner.run('app.restart', {}));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, ['start']);
    });

    test('a command queued behind a blocked one is announced too', () async {
      // Announced before the pool is requested. A command stuck in the queue
      // has also not started, and that is the state worth seeing — otherwise
      // app.stop appears to vanish while a restart holds the pool.
      final events = <String>[];
      final runner = CommandRunner(
        onProgress: (method, params, id, {required finished}) =>
            events.add('$method/${finished ? 'end' : 'start'}'),
      );
      runner.register(
        'app.restart',
        (_) => Completer<Map<String, dynamic>>().future,
        longRunning: true,
      );
      runner.register('app.hotReload', (_) async => {}, longRunning: true);

      unawaited(runner.run('app.restart', {}));
      unawaited(runner.run('app.hotReload', {}));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, ['app.restart/start', 'app.hotReload/start']);
    });

    test('short commands stay quiet', () async {
      final events = <String>[];
      final runner = CommandRunner(
        onProgress: (method, params, id, {required finished}) =>
            events.add(method),
      );
      runner.register('app.getText', (_) async => {'text': 'hi'});

      await runner.run('app.getText', {});

      expect(
        events,
        isEmpty,
        reason: 'an event per widget query would be noise, not signal',
      );
    });

    test('a handler that throws still reports its end', () async {
      final events = <String>[];
      final runner = CommandRunner(
        onProgress: (method, params, id, {required finished}) =>
            events.add(finished ? 'end' : 'start'),
      );
      runner.register(
        'app.restart',
        (_) async => throw StateError('nope'),
        longRunning: true,
      );

      await expectLater(runner.run('app.restart', {}), throwsStateError);
      expect(
        events,
        ['start', 'end'],
        reason: 'an unfinished command must not be left looking unfinished',
      );
    });
  });

  group('queue lines', () {
    late List<Map<String, dynamic>> lines;

    setUp(() {
      lines = [];
      final sub = Logger.root.onRecord.listen((r) {
        final o = r.object;
        if (o is Map && o['phase'] == 'queue') {
          lines.add(Map<String, dynamic>.from(o));
        }
      });
      addTearDown(sub.cancel);
    });

    test('a long command says when it got the queue', () async {
      final runner = CommandRunner();
      runner.register('app.hotReload', (_) async => {}, longRunning: true);

      await runner.run('app.hotReload', {});

      expect(lines.single['event'], 'finished');
      expect(
        lines.single['text'],
        matches(r'^app\.hotReload: queue acquired after \d+ms$'),
      );
    });

    test('a command behind a busy one says it is waiting, and for what, '
        'then says it got the queue', () async {
      final runner = CommandRunner();
      final release = Completer<void>();
      runner.register('app.restart', (_) async {
        await release.future;
        return {};
      }, longRunning: true);
      runner.register('app.hotReload', (_) async => {}, longRunning: true);

      final first = runner.run('app.restart', {});
      await pumpEventQueue();
      final second = runner.run('app.hotReload', {});
      await pumpEventQueue();

      final waiting = lines.where((l) => l['event'] == 'waiting').single;
      expect(waiting['text'], contains('app.hotReload is waiting'));
      expect(waiting['text'], contains('app.restart'));
      expect(
        lines.where(
          (l) =>
              l['event'] == 'finished' &&
              '${l['text']}'.startsWith('app.hotReload'),
        ),
        isEmpty,
        reason: 'it has not got the queue yet',
      );

      release.complete();
      await first;
      await second;
      expect(
        lines.last['text'],
        matches(r'^app\.hotReload: queue acquired after \d+ms$'),
      );
    });

    test('a short command is not reported', () async {
      final runner = CommandRunner();
      runner.register('app.getText', (_) async => {});

      await runner.run('app.getText', {});

      expect(lines, isEmpty);
    });
  });

  // A reload held for a cold startup or a rebuild runs for minutes, and a
  // client ending the run is owed its answer now. Each case runs on a fake
  // clock with work that takes ten minutes, so "at once" is checked as no time
  // passing at all rather than as a deadline a slow machine could miss.
  group('ending the run', () {
    const tenMinutes = Duration(minutes: 10);
    final isShuttingDown = throwsA(
      isA<CommandFailure>().having(
        (e) => e.kind,
        'kind',
        CommandFailureKind.shuttingDown,
      ),
    );

    test('a control command runs beside one holding the queue', () {
      fakeAsync((async) {
        final runner = CommandRunner();
        runner.register('app.hotReload', (_) async {
          await Future<void>.delayed(tenMinutes);
          return {'reloaded': true};
        }, longRunning: true);
        runner.register(
          'daemon.shutdown',
          (_) async => {'message': 'shutdown'},
          control: true,
        );

        unawaited(runner.run('app.hotReload', {}));
        Map<String, dynamic>? answer;
        runner.run('daemon.shutdown', {}).then((a) => answer = a);
        async.flushMicrotasks();

        expect(answer, {'message': 'shutdown'});
        async.elapse(tenMinutes);
      });
    });

    test('what runs and what waits are both answered when the run ends', () {
      fakeAsync((async) {
        final stopping = Completer<void>();
        final runner = CommandRunner(stopping: stopping.future);
        var queuedRan = false;
        runner.register('app.hotReload', (_) async {
          await Future<void>.delayed(tenMinutes);
          return {'reloaded': true};
        }, longRunning: true);
        runner.register('app.getText', (_) async {
          queuedRan = true;
          return {'text': 'x'};
        });

        Object? running;
        Object? queued;
        runner.run('app.hotReload', {}).catchError((Object e) {
          running = e;
          return <String, dynamic>{};
        });
        runner.run('app.getText', {}).catchError((Object e) {
          queued = e;
          return <String, dynamic>{};
        });
        async.elapse(const Duration(minutes: 1));
        expect(running, isNull);
        expect(queued, isNull);

        stopping.complete();
        async.flushMicrotasks();
        expect(
          running,
          isA<CommandFailure>()
              .having((e) => e.kind, 'kind', CommandFailureKind.shuttingDown)
              .having((e) => e.message, 'message', contains('abandoned')),
        );
        expect(
          queued,
          isA<CommandFailure>()
              .having((e) => e.kind, 'kind', CommandFailureKind.shuttingDown)
              .having((e) => e.message, 'message', contains('not run')),
        );

        // The abandoned reload finishing later neither runs what was queued
        // nor surfaces as an unhandled error.
        async.elapse(tenMinutes);
        expect(queuedRan, isFalse);
      });
    });

    // A run that lasts all day sends thousands of commands, and the run's end
    // is one future they all wait on. A wait that left its listener there would
    // keep every command's closure alive until then.
    test('a finished command leaves nothing waiting on the run ending', () {
      fakeAsync((async) {
        final stopping = Completer<void>();
        final runner = CommandRunner(stopping: stopping.future);
        runner.register('app.getText', (_) async => {'text': 'x'});
        runner.register(
          'app.hotReload',
          (_) async => throw StateError('failed'),
        );

        for (var i = 0; i < 100; i++) {
          runner.run('app.getText', {});
          runner
              .run('app.hotReload', {})
              .catchError(
                (Object _) => <String, dynamic>{},
              );
        }
        expect(runner.pendingStopWaits, greaterThan(0));
        async.flushMicrotasks();

        expect(runner.pendingStopWaits, 0);
      });
    });

    test('an abandoned command that fails later is not an unhandled error', () {
      fakeAsync((async) {
        final stopping = Completer<void>();
        final runner = CommandRunner(stopping: stopping.future);
        runner.register('app.restart', (_) async {
          await Future<void>.delayed(tenMinutes);
          throw StateError('the compiler went away under it');
        });

        expect(runner.run('app.restart', {}), isShuttingDown);
        async.flushMicrotasks();
        stopping.complete();
        async.flushMicrotasks();
        // fake_async rethrows an uncaught error here if the abandoned
        // handler's failure was left unhandled.
        async.elapse(tenMinutes);
      });
    });

    test('a command sent after the run started to end is not started', () {
      fakeAsync((async) {
        final stopping = Completer<void>()..complete();
        final runner = CommandRunner(stopping: stopping.future);
        var ran = false;
        runner.register('app.hotReload', (_) async {
          ran = true;
          return {};
        });
        async.flushMicrotasks();

        expect(runner.run('app.hotReload', {}), isShuttingDown);
        async.flushMicrotasks();
        expect(ran, isFalse);
      });
    });

    test('a control command still runs once the run is ending', () {
      fakeAsync((async) {
        final stopping = Completer<void>()..complete();
        final runner = CommandRunner(stopping: stopping.future);
        runner.register(
          'daemon.shutdown',
          (_) async => {'message': 'shutdown'},
          control: true,
        );
        async.flushMicrotasks();

        Map<String, dynamic>? answer;
        runner.run('daemon.shutdown', {}).then((a) => answer = a);
        async.flushMicrotasks();
        expect(answer, {'message': 'shutdown'});
      });
    });
  });
}
