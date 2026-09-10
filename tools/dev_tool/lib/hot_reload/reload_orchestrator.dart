/// The composer of the reload pipeline.
///
/// `ReloadOrchestrator` is the only place that knows the full sequence:
/// regenerate → snapshot disk → ask each target what it lacks → compile per
/// target → apply per target → settle that target's baseline. It does not own
/// concurrency discipline of its own — `CommandRunner.Pool(1)` ensures at most
/// one reload runs at a time. The pipeline itself is bounded because every
/// step (compile, applyKernel) is bounded by construction.
///
/// What is shared and what is not is the design. One filesystem, so one
/// [workspace] and **one snapshot per command**, handed to every target: two
/// targets of the same reload must agree on what disk said, or a file written
/// mid-command lands in one app and not the other with nothing to show for it.
/// One [refreshGenerated] per command for the same reason — it rewrites the
/// tree, so it must finish before the snapshot and must not run once per
/// target. Everything downstream of that is per-target, in a [SessionReloader]:
/// its own compiler, its own record, its own commit. See that class for why a
/// shared compiler cannot serve independently-targeted apps.
import 'dart:async';

import 'app_instance.dart';
import 'compiler.dart';
import 'session_reloader.dart';
import 'workspace.dart';

/// Outcome of a reload or restart request.
sealed class ReloadOutcome {
  const ReloadOutcome();
}

/// The compile and apply both succeeded.
///
/// [filesRecompiled] is the union, across the targets that needed work, of
/// what each was sent. [isEmpty] is true when every one of those files was
/// byte-identical (per `Version`) to what the target already had — i.e. the
/// caller declared files that turned out clean. Distinguishable from
/// [ReloadNoChange], which is returned only when no target had anything to
/// recompile in the first place.
class ReloadApplied extends ReloadOutcome {
  final Set<String> filesRecompiled;
  final bool isEmpty;

  /// The apps that actually received a kernel. A target already current is not
  /// listed: it was left alone because it had nothing to receive.
  final List<AppInstance> apps;
  const ReloadApplied({
    required this.filesRecompiled,
    required this.isEmpty,
    required this.apps,
  });
}

/// No work was scheduled — no target had any FS change or caller-declared
/// invalidation outstanding. Every targeted app is already up to date.
class ReloadNoChange extends ReloadOutcome {
  const ReloadNoChange();
}

/// Compile failed. Every target's pending compile was rolled back; no applied
/// versions are advanced.
class ReloadCompileFailed extends ReloadOutcome {
  final String diagnostics;
  const ReloadCompileFailed(this.diagnostics);
}

/// Compile succeeded but at least one device did not end up healthy.
///
/// Per target, and by what the VM ended up holding rather than by who is
/// happy: the ones that took the kernel kept it and advanced their own
/// baseline — an [AppliedThenThrew] app is running it, however loudly it
/// objects — while the ones that refused or timed out rolled theirs back. A
/// partial failure discards no device's work.
class ReloadApplyFailed extends ReloadOutcome {
  final Map<String, ApplyOutcome> perApp;
  const ReloadApplyFailed(this.perApp);
}

class ReloadOrchestrator {
  final Workspace workspace;

  /// One unit per app this orchestrator can drive.
  final List<SessionReloader> units;

  final String entrypoint;

  /// Optional pre-reload step that rebuilds the app's bazel-generated sources
  /// (codegen) so the compilers see fresh outputs. Returns false on build
  /// failure. Null for apps with no generated sources — then the pipeline runs
  /// no bazel build (today's instant path). Runs once per command, before the
  /// snapshot, so a refreshed generated file is picked up by the normal diff.
  final Future<bool> Function()? refreshGenerated;

  ReloadOrchestrator({
    required this.workspace,
    required this.units,
    required this.entrypoint,
    this.refreshGenerated,
  });

  /// Every app this orchestrator can drive right now.
  ///
  /// Excludes units whose connection is gone: an unaddressed command reaches
  /// the rest, and one that names a disconnected app is refused with the
  /// reason by the caller rather than failing to apply a kernel to it.
  List<AppInstance> get apps => [
    for (final u in units)
      if (u.connected) u.app,
  ];

  /// Point the units at the processes that are live after a relaunch.
  ///
  /// [live] is every app that came back with a working connection. A unit named
  /// there is swapped onto its replacement; a unit absent from it kept its
  /// process but lost its VM service, and is marked disconnected rather than
  /// dropped — its compiler and its record are still the truth about what that
  /// app was running, and they would have to be invented again if it returned.
  ///
  /// Records and compilers are deliberately untouched: a replacement runs
  /// freshly built code, so a record left as it was can only under-claim what
  /// the process has, and under-claiming costs one redundant re-send on the
  /// next reload rather than a dropped edit.
  void syncLiveApps(List<AppInstance> live) {
    final byId = {for (final a in live) a.id: a};
    for (final unit in units) {
      final replacement = byId[unit.id];
      unit.connected = replacement != null;
      if (replacement != null) unit.app = replacement;
    }
  }

  /// The unit driving [app], which must be one of [units].
  SessionReloader unitFor(AppInstance app) {
    for (final u in units) {
      if (u.app.id == app.id) return u;
    }
    throw StateError(
      'App "${app.id}" is not one this orchestrator was built for '
      '(${units.map((u) => u.id).join(', ')}).',
    );
  }

  /// Bring [targets] up to current source state.
  ///
  /// [targets] is which of [apps] the request addressed — all of them for an
  /// unaddressed command, exactly one when the request named an appId. The
  /// caller resolves the name; an instance this orchestrator does not know is
  /// its bug, and throws.
  ///
  /// [declared] is the caller's authoritative set of changed URIs (an agent or
  /// IDE that knows about edits the FS may not yet show). Declared files are
  /// recompiled even if their disk version equals what's applied — but the
  /// response distinguishes that case via `ReloadApplied.isEmpty = true`.
  Future<ReloadOutcome> reload({
    Set<String>? declared,
    required List<AppInstance> targets,
  }) => _runPipeline(
    declared: declared,
    mode: ApplyMode.hotReload,
    targets: targets,
  );

  /// Full restart of [targets] — full compile, hotRestart, and each target's
  /// applied record reset to the full disk snapshot. Untargeted apps keep their
  /// records and their compilers, so their next `reload()` still delivers what
  /// they missed, dependent libraries included.
  Future<ReloadOutcome> restart({required List<AppInstance> targets}) =>
      _runPipeline(
        declared: null,
        mode: ApplyMode.hotRestart,
        targets: targets,
      );

  Future<ReloadOutcome> _runPipeline({
    required Set<String>? declared,
    required ApplyMode mode,
    required List<AppInstance> targets,
  }) async {
    if (targets.isEmpty) {
      throw StateError('A reload needs at least one target app.');
    }
    // Resolved before any work, so an unknown target fails loudly rather than
    // after a compile has already run.
    final targetUnits = [for (final t in targets) unitFor(t)];

    // Refresh bazel-generated sources (codegen) BEFORE snapshotting, so a
    // regenerated file's new version is captured by the diff below and its
    // library is invalidated. Once per command, never once per target.
    if (refreshGenerated != null) {
      final ok = await refreshGenerated!();
      if (!ok) {
        return const ReloadCompileFailed(
          'Generated source rebuild (bazel) failed; see build output above.',
        );
      }
    }

    // One snapshot, shared by every target: what disk said at this instant.
    final snap = workspace.snapshot();
    final isRestart = mode == ApplyMode.hotRestart;

    // What each target lacks, judged against its own record. Deliberately not
    // unioned across targets — each compiler is asked only for its own app's
    // gap and derives the dependent libraries itself.
    final work = <SessionReloader, Set<String>>{
      for (final u in targetUnits)
        u: isRestart
            // A restart recompiles from scratch and treats every disk file as
            // newly applied; the committed kernel is being thrown out anyway.
            ? snap.fileUris.toSet()
            : u.pendingAt(snap, declared: declared),
    };

    final working = [
      for (final u in targetUnits)
        if (isRestart || work[u]!.isNotEmpty) u,
    ];
    if (working.isEmpty) {
      // "No change" is true of disk and false of the app, whenever a targeted
      // app has never had a compile succeed: it is running its launch build,
      // the working tree still does not compile, and there is nothing pending
      // to compile again. Answering "already up to date" there tells the user
      // the one thing that would stop them looking for the error. Restated
      // from the unit rather than re-derived, so the words are the compiler's
      // own.
      for (final unit in targetUnits) {
        final failure = unit.baselineFailure;
        if (failure != null) return ReloadCompileFailed(failure);
      }
      return const ReloadNoChange();
    }

    // Judged before anything is applied, against the still-old records.
    final isEmpty = working.every(
      (u) => work[u]!.every((f) => snap.versionOf(f) == u.applied.versionOf(f)),
    );

    final compiled = await Future.wait([
      for (final u in working)
        u.compile(invalidated: work[u]!, entrypoint: entrypoint, mode: mode),
    ]);

    // Every target compiles the same disk, so a failure is a property of the
    // source and they agree in practice — but the rule is atomic regardless:
    // nothing is applied anywhere, and every pending compile is discarded.
    final failure = compiled.whereType<CompileFailed>().firstOrNull;
    if (failure != null) {
      await Future.wait([for (final u in working) u.discard()]);
      return ReloadCompileFailed(failure.diagnostics);
    }

    final results = await Future.wait([
      for (var i = 0; i < working.length; i++)
        working[i].applyAndSettle(
          (compiled[i] as CompileSucceeded).dillPath,
          mode: mode,
          snapshot: snap,
          invalidated: work[working[i]]!,
        ),
    ]);

    final perApp = <String, ApplyOutcome>{
      for (var i = 0; i < working.length; i++) working[i].id: results[i],
    };
    if (!results.every((r) => r is Applied)) {
      return ReloadApplyFailed(perApp);
    }

    return ReloadApplied(
      filesRecompiled: {for (final u in working) ...work[u]!},
      isEmpty: isEmpty,
      apps: [for (final u in working) u.app],
    );
  }
}
