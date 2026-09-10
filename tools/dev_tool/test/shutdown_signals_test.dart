/// What a `kill` does to a run.
///
/// Dart's default disposition for a shutdown signal terminates the VM, so the
/// `finally` that calls `teardown.run()` never executes: a browser the tool
/// launched reparents to launchd with its helper processes and keeps its
/// `--user-data-dir` temp profile on disk, and on Android the app stays
/// installed and running on the device.
///
/// That matters more than an ordinary leak: a stale profile belongs to a
/// browser a `--user-data-dir` scan can still find, so an orphaned window can
/// serve a screenshot that makes a broken run look fine (`device.dart`).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/shutdown_signals.dart';
import 'package:test/test.dart';

void main() {
  group('which signals are watched', () {
    test('SIGINT everywhere, SIGTERM everywhere but Windows', () {
      // `ProcessSignal.sigterm.watch()` throws `SignalException: Listening for
      // signal SIGTERM is not supported` on Windows, and this repo runs
      // Windows CI. SIGINT is supported there and is what Ctrl-C sends.
      expect(shutdownSignalsFor(isWindows: false), [
        ProcessSignal.sigint,
        ProcessSignal.sigterm,
      ]);
      expect(shutdownSignalsFor(isWindows: true), [ProcessSignal.sigint]);
    });
  });

  group('the first signal', () {
    test('runs the same shutdown a daemon.shutdown runs, then exits', () async {
      final order = <String>[];
      final signals = StreamController<ProcessSignal>();
      final exited = Completer<int>();
      ShutdownSignalHandler(
        onShutdown: () async {
          order.add('shutdown');
        },
        exitProcess: (code) {
          order.add('exit $code');
          if (!exited.isCompleted) exited.complete(code);
        },
      ).listen(signals.stream);

      signals.add(ProcessSignal.sigterm);
      expect(await exited.future, 143); // 128 + SIGTERM
      // Shutdown first, exit second: exiting before the browser and the app
      // are let go is exactly the leak this handler exists to prevent.
      expect(order, ['shutdown', 'exit 143']);
    });

    test('reports SIGINT as 130', () async {
      final exited = Completer<int>();
      final signals = StreamController<ProcessSignal>();
      ShutdownSignalHandler(
        onShutdown: () async {},
        exitProcess: (code) {
          if (!exited.isCompleted) exited.complete(code);
        },
      ).listen(signals.stream);

      signals.add(ProcessSignal.sigint);
      expect(await exited.future, 130);
    });
  });

  group('a second signal', () {
    test('does not wait for a shutdown that is still going', () async {
      // Someone pressing Ctrl-C twice is saying "now". The graceful path is
      // bounded, so it does finish — but a bound is still seconds of a wedged
      // `adb` or a frozen browser, and the second press must not queue behind
      // it. Escalation on a repeated explicit request, which is not the same
      // thing as retrying around a failure.
      final releaseShutdown = Completer<void>();
      final signals = StreamController<ProcessSignal>();
      final exitCodes = <int>[];
      var shutdownRuns = 0;
      ShutdownSignalHandler(
        onShutdown: () async {
          shutdownRuns++;
          await releaseShutdown.future;
        },
        exitProcess: exitCodes.add,
      ).listen(signals.stream);

      signals.add(ProcessSignal.sigint);
      await Future<void>.delayed(Duration.zero);
      expect(exitCodes, isEmpty, reason: 'first shutdown still running');

      signals.add(ProcessSignal.sigint);
      await Future<void>.delayed(Duration.zero);
      expect(exitCodes, [130], reason: 'second signal exits immediately');

      // And the graceful shutdown is not started a second time — running the
      // teardown concurrently with itself is how a half-disposed resource gets
      // disposed twice.
      releaseShutdown.complete();
      await Future<void>.delayed(Duration.zero);
      expect(shutdownRuns, 1);
    });
  });

  group('a shutdown that throws', () {
    test('still exits rather than leaving the process wedged', () async {
      // The signal has already been given: whatever the teardown makes of
      // itself, the caller asked for this process to end, and an error on the
      // way out must not turn that into a hang.
      final exited = Completer<int>();
      final signals = StreamController<ProcessSignal>();
      ShutdownSignalHandler(
        onShutdown: () async => throw StateError('adb went away'),
        exitProcess: (code) {
          if (!exited.isCompleted) exited.complete(code);
        },
      ).listen(signals.stream);

      signals.add(ProcessSignal.sigterm);
      expect(await exited.future, 143);
    });
  });
}
