/// The launch bundle's bazel build, run at most once per command.
///
/// One `app.restart` has two steps that need the bundle rebuilt: the asset
/// refresh, which rebuilds when an asset source has moved, and the native-libs
/// check, which rebuilds before it can compare the bundle against the running
/// process. They are the same build of the same target, and bazel is not free
/// even when every action in it is a cache hit — a second invocation is a server
/// round trip, the workspace lock, and the `cquery` that lists the outputs, on
/// the interactive path between a keypress and a running app.
///
/// "Per command" is exact rather than approximate: `CommandRunner` serializes
/// every command through a `Pool(1)`, so at most one is in flight and the
/// sequence number [ReloadPipeline.command] carries is the only one a build can
/// belong to. A later command always rebuilds — the tree has moved on, which is
/// why there is a later command.
library;

class BundleRebuild {
  final Future<bool> Function() _build;

  /// The command a build would belong to, read at call time rather than passed
  /// in: both callers are several layers from the handler that knows it.
  final int Function() _command;

  /// The command [_result] was built for, and what that build answered. Failure
  /// is cached as readily as success: a build that failed for this tree fails
  /// the same way a second time, and the caller that asked first has already
  /// reported it.
  int _builtFor = -1;
  bool _result = false;

  BundleRebuild(this._build, this._command);

  Future<bool> run() async {
    final command = _command();
    if (command == _builtFor) return _result;
    _result = await _build();
    _builtFor = command;
    return _result;
  }
}
