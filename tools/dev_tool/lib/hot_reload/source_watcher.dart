/// Filesystem watcher feeding the reload pipeline.
///
/// Wraps `package:watcher`'s `DirectoryWatcher` with a debounce window so
/// editor saves that touch many files in quick succession produce one
/// `SourceChange` event rather than a flurry. `SourceChange.paths` are
/// absolute filesystem paths; consumers convert to frontend-server URIs
/// via `Workspace.toFrontendServerUri`.
///
/// `SourceWatcher` is stateless w.r.t. reload semantics — it doesn't
/// track what's been compiled or applied. That's `AppliedVersions`'s job.
import 'dart:async';

import 'package:watcher/watcher.dart';

class SourceChange {
  /// Absolute filesystem paths of files that changed within the debounce
  /// window. Always non-empty.
  final Set<String> paths;
  const SourceChange(this.paths);
}

/// Why a watcher stopped being able to see edits.
///
/// [error] is null when the underlying stream simply ended — package:watcher's
/// macOS implementation closes itself permanently after a post-ready end, which
/// is not an error it raises but is just as fatal to a `--watch` run.
class WatcherFailure {
  final String reason;
  final Object? error;
  final StackTrace? stackTrace;

  const WatcherFailure(this.reason, {this.error, this.stackTrace});

  @override
  String toString() => error == null ? reason : '$reason: $error';
}

/// Whether a changed path is worth waking the reload pipeline for.
///
/// Consulted on every filesystem event, so it must stay cheap and must not
/// touch the disk.
typedef PathFilter = bool Function(String path);

/// The filter every run starts with: Dart sources only.
///
/// A run learns more as it goes — which directories feed the asset bundle, for
/// one — so the filter is a function rather than a fixed extension list, and
/// the caller passes one that consults live state.
bool isDartSource(String path) => path.endsWith('.dart');

class SourceWatcher {
  /// Filesystem root being watched.
  final String root;

  /// Window during which back-to-back file events are coalesced into one
  /// `SourceChange`. Defaults to 200ms — enough to absorb an editor save
  /// touching multiple files but short enough that the user doesn't
  /// notice.
  final Duration debounce;

  /// Single-subscription on purpose, so a change that lands before the session
  /// loop subscribes is buffered and delivered rather than dropped.
  ///
  /// [start] is called before the app launches — the whole point being that a
  /// run is watching by the time it says it started — and the consumer only
  /// attaches once the reload pipeline is wired, which on native is after the
  /// compiler's initial compile. A broadcast controller would throw everything
  /// in that window away.
  final StreamController<SourceChange> _changes =
      StreamController<SourceChange>();
  StreamSubscription<WatchEvent>? _sub;
  Timer? _debounceTimer;
  final Set<String> _pending = {};
  DirectoryWatcher? _watcher;

  /// Factory for the underlying `DirectoryWatcher`. Tests can inject a
  /// double here; production passes `DirectoryWatcher.new` indirectly.
  final DirectoryWatcher Function(String root) _newWatcher;

  /// Which changed paths reach [changes]. Defaults to [isDartSource].
  final PathFilter _accepts;

  SourceWatcher({
    required this.root,
    this.debounce = const Duration(milliseconds: 200),
    DirectoryWatcher Function(String root)? watcherFactory,
    PathFilter? accepts,
  }) : _newWatcher = watcherFactory ?? DirectoryWatcher.new,
       _accepts = accepts ?? isDartSource;

  /// Stream of debounced source-change events.
  Stream<SourceChange> get changes => _changes.stream;

  final Completer<WatcherFailure> _failed = Completer<WatcherFailure>();

  /// Completes when this watcher can no longer see edits.
  ///
  /// Deliberately not delivered through [changes]. That stream is
  /// single-subscription and is only attached once the reload pipeline is
  /// wired, so an error placed there would sit unobserved on exactly the runs
  /// that never got a pipeline. A run has to be able to learn its watcher died
  /// whatever else went wrong.
  ///
  /// Never completes for a watcher shut down through [stop] — that is the run
  /// ending, not the watcher failing under it.
  Future<WatcherFailure> get failed => _failed.future;

  /// Begin watching. Returns once the underlying watcher is ready.
  Future<void> start() async {
    _watcher = _newWatcher(root);
    _sub = _watcher!.events.listen(
      _onEvent,
      onError: (Object e, StackTrace st) => _die(
        WatcherFailure(
          'the filesystem watcher on $root reported an error and has stopped '
          'watching',
          error: e,
          stackTrace: st,
        ),
      ),
      onDone: () => _die(
        WatcherFailure(
          'the filesystem watcher on $root closed its event stream and has '
          'stopped watching',
        ),
      ),
    );
    await _watcher!.ready;
  }

  /// Record the death and make sure nothing half-seen escapes as an edit.
  ///
  /// The pending window is dropped rather than flushed: package:watcher emits
  /// a REMOVE for every file it knew about before closing, so flushing would
  /// hand the pipeline one enormous change that no user made, and then go
  /// quiet.
  void _die(WatcherFailure failure) {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pending.clear();
    if (!_failed.isCompleted) _failed.complete(failure);
  }

  void _onEvent(WatchEvent event) {
    // Order matters: `bazel-bin` holds copies of both sources and assets, and
    // a build writing into it must never look like a user edit — that is a
    // reload loop, since the reload is what wrote them.
    if (event.path.contains('bazel-')) return;
    if (!_accepts(event.path)) return;
    _pending.add(event.path);
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _flush);
  }

  void _flush() {
    if (_pending.isEmpty) return;
    final out = SourceChange(_pending.toSet());
    _pending.clear();
    _changes.add(out);
  }

  /// Stop watching. Cancels any pending debounce; closes the events
  /// stream. Safe to call more than once.
  Future<void> stop() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    await _sub?.cancel();
    _sub = null;
    // Not awaited. `close()` on a single-subscription controller completes only
    // once the stream is done being consumed, so on a run where nobody ever
    // subscribed it never completes at all — and that run is reachable, since
    // the consumer attaches only after the reload pipeline is wired and a
    // failed assembly never gets there. Teardown must not hang waiting for a
    // consumer that is not coming.
    if (!_changes.isClosed) unawaited(_changes.close());
  }
}
