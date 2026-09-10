/// Lifecycle gate between "the app process started" and "the reload
/// pipeline is wired".
///
/// `RunCommand.execute()` emits the `app.started` protocol event from inside
/// the per-device launch loop, but the shared `frontend_server` +
/// `ReloadOrchestrator` are constructed *after* that loop. A machine-protocol
/// client (IDE/agent) that fires `app.hotReload` on `app.started` would
/// otherwise race the setup and hit the orchestrator-null error branch.
///
/// `ReadinessGate` makes that race impossible: the `app.hotReload` /
/// `app.restart` handlers `await` [whenReady] before touching the
/// orchestrator. Setup signals one outcome per attempt — [signalReady] when
/// the orchestrator exists, [signalUnavailable] when setup failed for good, or
/// [signalRetryable] when it failed on something a later state change can cure.
/// [whenReady] completes for all three so a waiting handler never hangs; it
/// then inspects [isReady] / [isRetryable] / [unavailableReason] to decide what
/// to return.
///
/// First signal of an attempt wins; later signals are ignored. Only a
/// retryable settlement can be followed by another attempt, and only through
/// [reopen] — which is what keeps "unavailable" meaning what it says.
import 'dart:async';

class ReadinessGate {
  Completer<void> _completer = Completer<void>();
  bool _ready = false;
  bool _retryable = false;
  String? _unavailableReason;

  /// Completes (normally, never with an error) once setup has reached a
  /// terminal state — ready, unavailable, or retryable.
  Future<void> get whenReady => _completer.future;

  /// True once [signalReady] has fired (and neither other signal had already
  /// won).
  bool get isReady => _ready;

  /// The reason hot reload is unavailable, if [signalUnavailable] or
  /// [signalRetryable] won.
  String? get unavailableReason => _unavailableReason;

  /// Whether any signal has fired for the current attempt.
  bool get isSettled => _completer.isCompleted;

  /// Whether this attempt failed on something another attempt could get past.
  ///
  /// Settled, not pending: a request arriving now is answered immediately with
  /// [unavailableReason] rather than waiting out a signal that is not coming —
  /// and a caller's own "nothing settled the gate" backstop leaves it alone,
  /// which is what stops it overwriting this with a generic refusal.
  bool get isRetryable => _retryable;

  /// Mark the reload pipeline ready. Idempotent; ignored if already settled.
  void signalReady() {
    if (_completer.isCompleted) return;
    _ready = true;
    _completer.complete();
  }

  /// Mark the reload pipeline permanently unavailable for this run, with a
  /// human-readable [reason] handlers can surface. Idempotent; ignored if
  /// already settled.
  void signalUnavailable(String reason) {
    if (_completer.isCompleted) return;
    _unavailableReason = reason;
    _completer.complete();
  }

  /// Settle this attempt as failed, but not for the run: [reason] describes a
  /// state a later change on disk can cure, and the next reload request runs
  /// another attempt. Idempotent; ignored if already settled.
  void signalRetryable(String reason) {
    if (_completer.isCompleted) return;
    _unavailableReason = reason;
    _retryable = true;
    _completer.complete();
  }

  /// Begin another attempt, so requests queue on it the way they queued on the
  /// first one.
  ///
  /// Only legal from a retryable settlement. Reopening a *ready* gate would
  /// take a working pipeline away from the requests already queued behind it,
  /// and reopening an unavailable one would contradict the word.
  void reopen() {
    if (!_retryable) {
      throw StateError(
        'Only a retryable gate can be reopened; this one is '
        '${_ready
            ? 'ready'
            : isSettled
            ? 'unavailable'
            : 'still settling'}.',
      );
    }
    _completer = Completer<void>();
    _retryable = false;
    _unavailableReason = null;
  }
}
