import 'dart:async';

import 'package:flutter_bazel_dev_tool/command_failure.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
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
}
