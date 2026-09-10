/// What a run owns, and the one place that lets it go.
///
/// Setup and shutdown race. `app.started` is emitted from inside the launch
/// loop, but several things a run owns are created *after* it — the frontend
/// server most of all — so a client that answers `app.started` with
/// `daemon.shutdown` reaches teardown while setup is still going. Teardown
/// written as `await frontendServer?.shutdown()` then reads a variable that has
/// not been assigned yet, finds null, and does nothing; the compiler subprocess
/// starts a moment later with no owner and its stdio pipes keep the Dart VM
/// alive for good. It reproduces every time the shutdown arrives with no
/// settle delay in front of it.
///
/// [Teardown] closes that window by inverting who remembers: a resource
/// registers its own disposer as soon as it exists, and one registered after
/// [run] has already happened is disposed immediately instead of outliving the
/// session. Disposal is in reverse registration order — the way the resources
/// were built up — and happens exactly once.
import 'dart:async';

import 'package:logging/logging.dart';

final _logger = Logger('dev_tool.teardown');

/// Await [step] for at most [bound], reporting rather than hanging on expiry.
///
/// Shutdown talks to peers this process does not control — a browser, an app's
/// VM service, a third-party service's own shutdown — and any of them can stop
/// answering. An unbounded await on one is a `flutter_bazel` that never
/// returns, so every such wait goes through here and the chain always reaches
/// the end.
///
/// Only [TimeoutException] is handled. A step that fails for its own reasons
/// still propagates: bounding a teardown is not the same decision as
/// tolerating a broken one.
///
/// On expiry the step is **abandoned, not cancelled** — Dart cannot cancel a
/// future, so whatever it holds stays held until the process exits. That is a
/// real leak, and reporting it is the point: the run is ending, so the leak is
/// reclaimed at exit, but the peer on the other side may be left in a state
/// nobody cleaned up, and a user chasing that needs to know it happened.
Future<void> boundedTeardownStep(
  String what,
  Future<void> step,
  Duration bound,
) async {
  try {
    await step.timeout(bound);
  } on TimeoutException {
    _logger.warning({
      'message': 'teardown_step_timed_out',
      'text':
          'Gave up waiting for $what after ${bound.inMilliseconds}ms and '
          'moved on, so the rest of the shutdown could finish. Whatever it '
          'was holding is released when this process exits.',
      'step': what,
      'timeoutMs': bound.inMilliseconds,
    });
  }
}

class Teardown {
  final List<Future<void> Function()> _disposers = [];
  bool _hasRun = false;

  /// Whether [run] has already happened.
  bool get hasRun => _hasRun;

  /// Take ownership of [dispose], or run it now if teardown is already past.
  ///
  /// Register as soon as the resource exists, not where it is convenient: the
  /// gap between creating something and registering it is exactly the window
  /// this exists to close.
  Future<void> add(Future<void> Function() dispose) async {
    if (_hasRun) return dispose();
    _disposers.add(dispose);
  }

  /// Dispose everything registered, most recent first. Idempotent.
  ///
  /// Every disposer runs, even after one throws. The list is cleared before
  /// the loop — a disposer registered during the teardown has to be disposed
  /// as it is created, not appended to a list being iterated — so a throw part
  /// way through would otherwise abandon every disposer still pending,
  /// silently and permanently, leaving the app, the browser and the compiler
  /// behind a failing step unreleased.
  ///
  /// The first failure still propagates once the rest have run. Bounding a
  /// teardown is not the same decision as tolerating a broken one, and a
  /// caller that gets no exception is entitled to read that as "everything was
  /// released". The ones after it are reported here, because that is the only
  /// place they can be.
  Future<void> run() async {
    _hasRun = true;
    final pending = _disposers.reversed.toList();
    _disposers.clear();
    Object? firstError;
    StackTrace? firstStack;
    for (final dispose in pending) {
      try {
        await dispose();
      } catch (error, stack) {
        if (firstError == null) {
          firstError = error;
          firstStack = stack;
        } else {
          _logger.severe({
            'message': 'teardown_step_failed',
            'text':
                'A later teardown step also failed: $error. The first failure '
                'is the one this shutdown reports.',
            'error': '$error',
            'stackTrace': '$stack',
          });
        }
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStack!);
    }
  }
}
