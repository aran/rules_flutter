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

class SourceWatcher {
  /// Filesystem root being watched.
  final String root;

  /// Window during which back-to-back file events are coalesced into one
  /// `SourceChange`. Defaults to 200ms — enough to absorb an editor save
  /// touching multiple files but short enough that the user doesn't
  /// notice.
  final Duration debounce;

  final StreamController<SourceChange> _changes =
      StreamController<SourceChange>.broadcast();
  StreamSubscription<WatchEvent>? _sub;
  Timer? _debounceTimer;
  final Set<String> _pending = {};
  DirectoryWatcher? _watcher;

  /// Factory for the underlying `DirectoryWatcher`. Tests can inject a
  /// double here; production passes `DirectoryWatcher.new` indirectly.
  final DirectoryWatcher Function(String root) _newWatcher;

  SourceWatcher({
    required this.root,
    this.debounce = const Duration(milliseconds: 200),
    DirectoryWatcher Function(String root)? watcherFactory,
  }) : _newWatcher = watcherFactory ?? DirectoryWatcher.new;

  /// Stream of debounced source-change events.
  Stream<SourceChange> get changes => _changes.stream;

  /// Begin watching. Returns once the underlying watcher is ready.
  Future<void> start() async {
    _watcher = _newWatcher(root);
    _sub = _watcher!.events.listen(_onEvent);
    await _watcher!.ready;
  }

  void _onEvent(WatchEvent event) {
    if (!event.path.endsWith('.dart')) return;
    if (event.path.contains('bazel-')) return;
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
    if (!_changes.isClosed) await _changes.close();
  }
}
