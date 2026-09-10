/// What the native-library check decided, before anyone puts it into words.
///
/// Its own library, and a sealed type rather than a nullable map, because the
/// relauncher has three answers and a map could only carry them by convention:
/// null for "carry on with the isolate restart", a map with an `error` key for
/// a failed rebuild, and any other map for a replaced process. Nothing could
/// check which of the three a caller had, so an arm would be free to answer in
/// a shape that omitted the verdict fields every other reply carries.
///
/// A sealed type makes the three cases exhaustive at the call site, and leaves
/// the words to `outcome_renderer.dart`, which is where every other reply's
/// words already come from.
library;

sealed class RelaunchOutcome {
  const RelaunchOutcome();
}

/// The rebuilt bundle's native libraries match the running process's, so the
/// process can stay. The caller goes on to the ordinary isolate restart — the
/// fast path the whole check exists to protect.
final class RelaunchNotNeeded extends RelaunchOutcome {
  const RelaunchNotNeeded();
}

/// The rebuild failed, so there is nothing to compare against and nothing to
/// relaunch into.
///
/// Reported by the caller as [CommandReport.sourceRebuildFailed]: this build
/// runs before any process is replaced and before any isolate is restarted, so
/// a command that stops here has touched no device and the app is provably
/// still running exactly what it was.
final class RelaunchBuildFailed extends RelaunchOutcome {
  final String reason;

  const RelaunchBuildFailed(this.reason);
}

/// The libraries moved, so every process that had `dlopen`ed the old ones was
/// replaced.
///
/// Carries facts, not sentences. It is the payload [CommandReport.relaunch]
/// holds, so the renderers compose the one line and the one map from it the
/// same way they do for every other outcome.
final class Relaunched extends RelaunchOutcome {
  /// The libraries whose bytes differ from the running process's — the reason
  /// a relaunch was needed, and the first thing anyone asks.
  final List<String> changedLibs;

  /// Whether every replacement rendered a first frame, i.e. can take an `app.*`
  /// command now. Reported rather than assumed: a caller that gets false knows
  /// to wait instead of reading a `Method not found` as a broken agent surface.
  final bool ready;

  /// The launch counter of each relaunched app, by appId. Each launch buffers
  /// its output from zero, so a `/logs` cursor only means anything within one
  /// launch; a driver compares this with the `launch` in its last page to know
  /// the cursor it holds is stale.
  final Map<String, int> launches;

  const Relaunched({
    required this.changedLibs,
    required this.ready,
    required this.launches,
  });
}
