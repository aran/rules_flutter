import 'dart:async';

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

    test('run throws ArgumentError for unregistered method', () async {
      expect(
        () => runner.run('nonexistent', {}),
        throwsA(isA<ArgumentError>()),
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

    test('hasCommand returns true for registered, false otherwise', () {
      runner.register('test.cmd', (_) async => {});
      expect(runner.hasCommand('test.cmd'), isTrue);
      expect(runner.hasCommand('test.other'), isFalse);
    });

    test('registeredCommands lists all registered methods', () {
      runner.register('a', (_) async => {});
      runner.register('b', (_) async => {});
      runner.register('c', (_) async => {});
      expect(runner.registeredCommands, unorderedEquals(['a', 'b', 'c']));
    });

    // ---- Bounded-handler contract ----
    //
    // The pool is safe by virtue of "every handler completes." These
    // tests exercise the safety property at the runner level: no matter
    // how a handler ends — return, throw, slow-but-bounded — the pool
    // resource is released and the next command can run. Together with
    // the documentation comment in lib/command_runner.dart, they pin
    // the contract that this layer relies on.

    test('pool resource is released after a handler returns normally — next command runs',
        () async {
      runner.register('first', (_) async => {'ok': true});
      runner.register('second', (_) async => {'ok': true});

      await runner.run('first', {});
      // If 'first' had not released the pool, this would hang.
      final r = await runner
          .run('second', {})
          .timeout(const Duration(seconds: 2));
      expect(r['ok'], isTrue);
    });

    test('pool resource is released after a handler throws — next command runs',
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
    });

    test('a slow-but-bounded handler does not block the queue indefinitely',
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
    });
  });
}
