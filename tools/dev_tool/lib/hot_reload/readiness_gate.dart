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
/// orchestrator. Setup signals exactly one terminal outcome — [signalReady]
/// when the orchestrator exists, or [signalUnavailable] when setup
/// definitively failed (or the run mode never builds a native orchestrator,
/// e.g. web DDC / WASM / profile). [whenReady] completes for *both* outcomes
/// so a waiting handler never hangs; it then inspects [isReady] /
/// [unavailableReason] to decide what to return.
///
/// First signal wins; later signals are ignored. This models the single
/// terminal result of one setup attempt.
import 'dart:async';

class ReadinessGate {
  final Completer<void> _completer = Completer<void>();
  bool _ready = false;
  String? _unavailableReason;

  /// Completes (normally, never with an error) once setup has reached a
  /// terminal state — ready or unavailable.
  Future<void> get whenReady => _completer.future;

  /// True once [signalReady] has fired (and [signalUnavailable] had not
  /// already won).
  bool get isReady => _ready;

  /// The reason hot reload is unavailable, if [signalUnavailable] won.
  String? get unavailableReason => _unavailableReason;

  /// Whether either terminal signal has fired.
  bool get isSettled => _completer.isCompleted;

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
}
