/// What a reload, restart or asset delivery actually did.
///
/// One value, whatever triggered the command and whoever is going to read it.
/// `toWire` in `outcome_renderer.dart` is the one thing that turns it into
/// words; the terminal line is composed from that map by
/// `reportReloadCommand`, not from this value a second time.
library;

import 'hot_reload/app_instance.dart';
import 'hot_reload/reload_orchestrator.dart';
import 'relaunch_outcome.dart';
import 'reload_strategy.dart';
import 'running_code.dart';

export 'relaunch_outcome.dart';
export 'running_code.dart';

/// What happened to the asset bundle.
class AssetOutcome {
  /// Archive paths whose bytes changed. The set, not its size — which asset
  /// changed is the question anyone debugging a stale image asks first.
  final Set<String> changed;

  /// How delivery to the running app(s) went. Null when there was nothing to
  /// deliver, or when the caller asked for a rebuild without delivery.
  final StrategyOutcome? delivery;

  /// Set when the bundle could not be rebuilt at all, which stops the command
  /// before delivery is even attempted.
  final String? rebuildFailed;

  /// True when a source moved, the rebuild ran, and the tree it produced was
  /// byte-identical to the one the app already has.
  ///
  /// Distinct from [none], which means no source moved and no build was run.
  /// They have different suspects: this one is what a Bazel action cache
  /// serving a stale tree looks like from here, while the other points at the
  /// tracker.
  final bool rebuiltIdentical;

  const AssetOutcome({
    this.changed = const {},
    this.delivery,
    this.rebuildFailed,
    this.rebuiltIdentical = false,
  });

  static const none = AssetOutcome();

  bool get isEmpty => changed.isEmpty && rebuildFailed == null;

  /// The reason assets are not live, or null when they are.
  String? get problem {
    if (rebuildFailed != null) return rebuildFailed;
    final d = delivery;
    if (d != null && !d.isSuccess) return d.message;
    return null;
  }
}

class CommandReport {
  /// `Hot reload` or `Restart`. Named by the caller because the same machinery
  /// serves both and the word is the only difference in most renderings.
  final String verb;

  /// What the Dart half achieved. Null when the pipeline never ran one —
  /// an asset-only edit, or a refusal recorded in [unavailable].
  final ReloadOutcome? outcome;

  final AssetOutcome assets;

  /// What the web apply achieved, for the DDC path, which reports through
  /// [StrategyOutcome] rather than the orchestrator's [ReloadOutcome]. The two
  /// converge when web joins the orchestrator; until then a report carries
  /// whichever its path produced.
  final StrategyOutcome? strategy;

  /// Why the command could not run at all: no frontend server, no strategy,
  /// the pipeline still starting up, or a request naming an app that does not
  /// exist or has no reload connection. Distinct from a command that ran and
  /// failed, and reported as an error either way.
  ///
  /// The run's own incapacity and the caller's bad request sit here together
  /// on purpose. They differ in whose mistake it was — which the sentence
  /// says — and not in either thing this type exists to answer: both failed,
  /// and both stopped before a compiler or a device was touched, so both can
  /// promise the app is running exactly what it was. A second refusal channel
  /// would split that shared guarantee across two shapes a client has to
  /// learn.
  final String? unavailable;

  /// A build the command had to run before it could compile anything, and
  /// which failed.
  ///
  /// Two commands have one. A codegen app's `refreshGenerated` regenerates its
  /// `*.g.dart` through bazel, and a reload that cannot regenerate them would
  /// compile against stale output. A restart's relauncher rebuilds the launch
  /// target before comparing its native libraries, and a rebuild that failed
  /// leaves nothing to compare and nothing to relaunch into.
  ///
  /// Its own field because neither of the two it would otherwise borrow is
  /// true. It is not [unavailable]: the build was attempted, and a client that
  /// reads a refusal as "this run cannot reload" would retire a session over a
  /// transient compile error in a generator. And it is not
  /// [AssetOutcome.rebuildFailed], which renders as 'Asset rebuild failed' and
  /// would send someone debugging a broken generator to look at their images.
  ///
  /// [runningCode] answers [RunningCode.unchanged] here, and has earned it:
  /// both rebuilds run before any compile and before any process is replaced,
  /// so a command that stops on one has delivered no code.
  ///
  /// "No code" rather than "touched no device", because the relauncher's
  /// rebuild runs *after* the asset refresh, which may already have delivered
  /// a new bundle to an app this restart leaves running. [runningCode] is a
  /// claim about the Dart program and reads neither [assets] nor the delivery
  /// under it, so that is not a contradiction — but the renderer returns on
  /// this field outright, so an asset diff that reached an app alongside it is
  /// not mentioned in the reply.
  final String? sourceRebuildFailed;

  /// Set when the command replaced the app's process instead of restarting its
  /// isolate, because the rebuilt bundle's native libraries differ from the
  /// ones the running process had already `dlopen`ed.
  ///
  /// Its own field because neither of the halves below describes it. [outcome]
  /// is what a compiler and an apply achieved, and a relaunch runs no compiler
  /// at all — borrowing `ReloadApplied` would put an empty `filesRecompiled`
  /// on the wire and claim a recompile that never happened. [strategy] is an
  /// apply to a count of devices, which is not what replacing a process is
  /// either.
  ///
  /// [runningCode] answers [RunningCode.updated] from it, and this is the one
  /// arm that cannot be wrong about it: the process is new and it launched
  /// from the bundle the rebuild had just produced.
  final Relaunched? relaunch;

  final Duration? elapsed;

  /// The apps this command addressed, or null when it stopped before it could
  /// resolve any.
  ///
  /// A command that names no appId addresses **every** app. Resolution happens
  /// inside the handler, so this is the earliest point that can say truthfully
  /// which apps a reload actually reached.
  ///
  /// Null rather than empty for "not resolved": a refusal stops before the
  /// orchestrator is consulted, and an empty list would claim it addressed
  /// nothing, which is a different fact.
  final List<String>? appIds;

  const CommandReport({
    required this.verb,
    this.appIds,
    this.outcome,
    this.assets = AssetOutcome.none,
    this.strategy,
    this.unavailable,
    this.sourceRebuildFailed,
    this.relaunch,
    this.elapsed,
  });

  /// Whether the edit is running now.
  ///
  /// Every failure mode answers false here. Success is never inferred from the
  /// absence of an `error` key.
  bool get succeeded {
    if (unavailable != null) return false;
    if (sourceRebuildFailed != null) return false;
    if (assets.rebuildFailed != null) return false;
    if (assets.delivery case final d? when !d.isSuccess) return false;
    if (strategy case final s? when !s.isSuccess) return false;
    return switch (outcome) {
      null || ReloadApplied() || ReloadNoChange() => true,
      ReloadCompileFailed() || ReloadApplyFailed() => false,
    };
  }

  /// What the app is running now — see [RunningCode].
  ///
  /// Reads whichever halves this report carries: the orchestrator's [outcome],
  /// the web path's [strategy], or neither, which is an asset-only edit that
  /// never touched the Dart program.
  RunningCode get runningCode {
    // Refused before anything ran, so there was nothing to deliver.
    if (unavailable != null) return RunningCode.unchanged;
    return _leastCertain([
      // A new process running a freshly built bundle. Certain in a way no
      // apply is: there is no delivery to have half-landed.
      if (relaunch != null) RunningCode.updated,
      if (outcome case final o?) _outcomeCode(o),
      if (strategy case final s?) _strategyCode(s),
    ]);
  }

  /// The answer for a whole run, given one per part of it.
  ///
  /// Not knowing about one app means not knowing about the run: a single
  /// [RunningCode.unknown] beside a certainty is still an unknown. And one half
  /// that landed new code rules the whole run out of [RunningCode.unchanged] —
  /// the state that alone earns "the app keeps running the code it already had".
  ///
  /// Landed new code, not reached an app. An empty-delta apply reaches its app
  /// and still answers [RunningCode.unchanged], which stays true of a restart
  /// that re-ran `main()` on it — see that value's own doc.
  ///
  /// An empty list is [RunningCode.unchanged]: no half ran, so nothing moved.
  static RunningCode _leastCertain(List<RunningCode> states) {
    if (states.contains(RunningCode.unknown)) return RunningCode.unknown;
    if (states.contains(RunningCode.updated)) return RunningCode.updated;
    return RunningCode.unchanged;
  }

  static RunningCode _outcomeCode(ReloadOutcome outcome) => switch (outcome) {
    // The compiler never handed back a delta, so nothing was sent.
    ReloadNoChange() || ReloadCompileFailed() => RunningCode.unchanged,
    // An empty delta changed no code, however much it changed the app: the
    // apply ran, and a restart's apply re-ran `main()` and wiped the state
    // on the way. Which is why this reads no `ApplyMode` and needs none —
    // a reload and a restart deliver the same nothing, and the only thing
    // asked here is what code came out the other side.
    ReloadApplied(:final isEmpty) =>
      isEmpty ? RunningCode.unchanged : RunningCode.updated,
    ReloadApplyFailed(:final perApp) => _leastCertain([
      for (final o in perApp.values) _applyCode(o),
    ]),
  };

  static RunningCode _applyCode(ApplyOutcome outcome) => switch (outcome) {
    Applied() || AppliedThenThrew() => RunningCode.updated,
    // A refusal is now a claim only the steps *before* a delivery can
    // make: every `VmServiceClient` verb answers `VerdictAppErrored` once
    // an app has taken what it sent, including on the replay a dropped
    // connection provokes. So this one is a promise that the old code
    // survived.
    ApplyFailed() => RunningCode.unchanged,
    // A timeout is not. It is nothing coming back at all, from an RPC that
    // may well have landed. See [RunningCode.unknown].
    ApplyTimedOut() => RunningCode.unknown,
  };

  static RunningCode _strategyCode(
    StrategyOutcome outcome,
  ) => switch (outcome) {
    StrategyApplied() => RunningCode.updated,
    // "Nothing could take the edit, so nothing changed ... no app was ever
    // reached" — its own doc.
    StrategyUnsupported() => RunningCode.unchanged,
    // [StrategyThrew] says outright that it claims nothing. [StrategyRejected]
    // is shared between a browser genuinely declining the new sources and
    // `catch` arms that can fire mid-delivery, and the type is what reaches
    // a reader, so it answers for its weakest member.
    StrategyRejected() || StrategyThrew() => RunningCode.unknown,
  };

  /// The apps that did not take the edit, with why. Empty when none failed.
  Map<String, ApplyOutcome> get failedApps => switch (outcome) {
    ReloadApplyFailed(:final perApp) => {
      for (final e in perApp.entries)
        if (e.value is! Applied) e.key: e.value,
    },
    _ => const {},
  };
}
