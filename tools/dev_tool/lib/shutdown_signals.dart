/// Ending a run the way a `kill` asks for, instead of abandoning what it owns.
///
/// A run owns processes it did not fork from itself in any recoverable sense:
/// a browser with a temp profile, an app installed and running on a device, a
/// resident compiler. All of that is released by the `finally` in the run and
/// attach commands — and a signal never reaches that `finally`, because Dart's
/// default disposition for SIGINT and SIGTERM terminates the VM outright.
///
/// A `kill -TERM` on the tool ends it instantly and leaves the browser
/// reparented to launchd with its helpers and its `--user-data-dir` still on
/// disk. That leak is not inert — `device.dart` explains why a stale profile is
/// worse than wasted bytes: it belongs to a browser a later run can still find,
/// and an orphaned window can serve a screenshot that makes a broken run look
/// fine.
///
/// Stopping a backgrounded run with a signal is the ordinary way to stop one,
/// so this is the ordinary path, not an exceptional one. It runs exactly what
/// `daemon.shutdown` runs — [SessionHost.performCleanup] — rather than a
/// second teardown of its own, because two shutdown paths become two different
/// shutdown paths.
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

/// The signals a run treats as "stop, and let go of what you hold".
///
/// SIGTERM is what a script or a supervisor sends and what a backgrounded run
/// is stopped with; SIGINT is Ctrl-C. Windows gets only SIGINT:
/// `ProcessSignal.sigterm.watch()` throws there (`SignalException: Listening
/// for signal SIGTERM is not supported`), and this repo runs Windows CI.
List<ProcessSignal> shutdownSignalsFor({required bool isWindows}) => [
  ProcessSignal.sigint,
  if (!isWindows) ProcessSignal.sigterm,
];

/// The exit status a process reports for dying of [signal], by convention
/// `128 + signum` — 130 for SIGINT, 143 for SIGTERM.
///
/// Reported deliberately rather than exiting 0: a run that was killed did not
/// succeed, and a caller that reads the status has to be able to tell the
/// difference between a session that ended and one that was ended.
int exitCodeForSignal(ProcessSignal signal) =>
    signal == ProcessSignal.sigint ? 130 : 143;

/// Turns signals into one graceful shutdown, and a second signal into an
/// immediate exit.
///
/// Split from the process-wide wiring so the policy can be tested without
/// sending real signals to the test runner: [listen] takes any stream, and
/// both effects — shutting down, exiting — are injected.
class ShutdownSignalHandler {
  /// What a first signal runs. In production this is
  /// [SessionHost.performCleanup] followed by closing the transports: the
  /// same work `daemon.shutdown` does.
  final Future<void> Function() _onShutdown;

  /// How the process ends. Injected so a test can observe the status instead
  /// of taking it.
  final void Function(int code) _exitProcess;

  final Logger _logger;

  /// Whether a graceful shutdown is already running. The second signal reads
  /// this and stops waiting.
  bool _shuttingDown = false;

  ShutdownSignalHandler({
    required Future<void> Function() onShutdown,
    required void Function(int code) exitProcess,
    Logger? logger,
  }) : _onShutdown = onShutdown,
       _exitProcess = exitProcess,
       _logger = logger ?? Logger('dev_tool.shutdown');

  /// Act on every signal from [signals] until the process goes.
  StreamSubscription<ProcessSignal> listen(Stream<ProcessSignal> signals) =>
      signals.listen(_handle);

  Future<void> _handle(ProcessSignal signal) async {
    final code = exitCodeForSignal(signal);
    if (_shuttingDown) {
      // Asked twice. The graceful path is bounded and does finish, but a bound
      // is still seconds of a wedged `adb` or an unresponsive browser, and
      // someone signalling again is saying they will not wait them out.
      _logger.warning({
        'message': 'shutdown_forced',
        'text':
            'Second $signal — exiting now without waiting for the rest of '
            'the shutdown. Anything still being released is left as it is.',
        'signal': '$signal',
      });
      _exitProcess(code);
      return;
    }
    _shuttingDown = true;
    _logger.info({
      'message': 'shutdown_signal',
      'text':
          'Received $signal — stopping the app, the browser and the '
          'compiler before exiting. Signal again to exit immediately.',
      'signal': '$signal',
    });
    try {
      await _onShutdown();
    } catch (e, stack) {
      // The exit is not conditional on the shutdown succeeding: the signal has
      // already said this process should end, and an error on the way out must
      // not turn that into a hang. Reported, never swallowed.
      _logger.severe({
        'message': 'shutdown_failed',
        'text':
            'Shutting down after $signal did not complete cleanly: $e. '
            'Exiting anyway; something this run owned may be left behind.',
        'error': '$e',
        'stackTrace': '$stack',
      });
    }
    _exitProcess(code);
  }
}
