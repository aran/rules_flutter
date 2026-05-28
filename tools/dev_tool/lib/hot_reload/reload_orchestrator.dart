/// The composer of the reload pipeline.
///
/// `ReloadOrchestrator` is the only place that knows the full sequence:
/// snapshot disk → diff against applied → compile → apply per device →
/// commit & advance applied versions. It does not own concurrency
/// discipline of its own — `CommandRunner.Pool(1)` ensures at most one
/// reload runs at a time. The pipeline itself is bounded because every
/// step (compile, applyKernel) is bounded by construction.
import 'dart:async';

import 'app_instance.dart';
import 'applied_versions.dart';
import 'compiler.dart';
import 'workspace.dart';

/// Outcome of a reload or restart request.
sealed class ReloadOutcome {
  const ReloadOutcome();
}

/// The compile and apply both succeeded.
///
/// [filesRecompiled] is the union of FS-detected changes and caller-declared
/// invalidations. [isEmpty] is true when all of those files were
/// byte-identical (per `Version`) to what was already applied — i.e. the
/// caller declared files that turned out clean. Distinguishable from
/// [ReloadNoChange], which is returned only when there was nothing to
/// recompile in the first place.
class ReloadApplied extends ReloadOutcome {
  final Set<String> filesRecompiled;
  final bool isEmpty;
  final List<AppInstance> apps;
  const ReloadApplied({
    required this.filesRecompiled,
    required this.isEmpty,
    required this.apps,
  });
}

/// No work was scheduled — there were no FS changes and no caller-declared
/// invalidations. The running app is already up to date with disk.
class ReloadNoChange extends ReloadOutcome {
  const ReloadNoChange();
}

/// Compile failed. `Compiler.rollback()` was called; applied versions are
/// not advanced.
class ReloadCompileFailed extends ReloadOutcome {
  final String diagnostics;
  const ReloadCompileFailed(this.diagnostics);
}

/// Compile succeeded but at least one device failed to apply (or timed out).
/// `Compiler.rollback()` was called; applied versions are not advanced.
class ReloadApplyFailed extends ReloadOutcome {
  final Map<String, ApplyOutcome> perApp;
  const ReloadApplyFailed(this.perApp);
}

class ReloadOrchestrator {
  final Workspace workspace;
  final AppliedVersions applied;
  final Compiler compiler;
  final List<AppInstance> apps;
  final String entrypoint;

  ReloadOrchestrator({
    required this.workspace,
    required this.applied,
    required this.compiler,
    required this.apps,
    required this.entrypoint,
  });

  /// Bring the running apps up to current source state.
  ///
  /// [declared] is the caller's authoritative set of changed URIs (an
  /// agent or IDE that knows about edits the FS may not yet show).
  /// Declared files are recompiled even if their disk version equals
  /// what's applied — but the response distinguishes that case via
  /// `ReloadApplied.isEmpty = true`.
  Future<ReloadOutcome> reload({Set<String>? declared}) =>
      _runPipeline(declared: declared, mode: ApplyMode.hotReload);

  /// Full restart — clears applied versions, full compile, hotRestart on
  /// every app. Subsequent `reload()` will see every disk file as changed.
  Future<ReloadOutcome> restart() =>
      _runPipeline(declared: null, mode: ApplyMode.hotRestart);

  Future<ReloadOutcome> _runPipeline({
    required Set<String>? declared,
    required ApplyMode mode,
  }) async {
    final snap = workspace.snapshot();

    final Set<String> invalidated;
    final CompileOutcome compileOutcome;

    if (mode == ApplyMode.hotRestart) {
      // Hot restart recompiles from scratch and treats every disk file as
      // newly applied. We don't consult `findChangedFrom` because the
      // committed kernel is being thrown out anyway.
      invalidated = snap.fileUris.toSet();
      compileOutcome = await compiler.compileFull(entrypoint: entrypoint);
    } else {
      final fsChanged = applied.findChangedFrom(snap);
      invalidated = {...fsChanged, ...?declared};

      if (invalidated.isEmpty) {
        return const ReloadNoChange();
      }

      compileOutcome = await compiler.compileIncrement(
        invalidated: invalidated,
        entrypoint: entrypoint,
      );
    }

    switch (compileOutcome) {
      case CompileFailed(:final diagnostics):
        await compiler.rollback();
        return ReloadCompileFailed(diagnostics);
      case CompileSucceeded(:final dillPath):
        // Compute isEmpty *before* markApplied, comparing snapshot versions
        // against the still-old applied versions.
        final isEmpty = invalidated.every(
          (f) => snap.versionOf(f) == applied.versionOf(f),
        );

        final results = await Future.wait([
          for (final a in apps) a.applyKernel(dillPath, mode: mode),
        ]);
        final perApp = <String, ApplyOutcome>{
          for (var i = 0; i < apps.length; i++) apps[i].id: results[i],
        };
        final allOk = results.every((r) => r is Applied);

        if (!allOk) {
          await compiler.rollback();
          return ReloadApplyFailed(perApp);
        }

        await compiler.commit();
        if (mode == ApplyMode.hotRestart) {
          applied.clear();
        }
        applied.markApplied(snap, files: invalidated);

        return ReloadApplied(
          filesRecompiled: invalidated,
          isEmpty: isEmpty,
          apps: apps,
        );
    }
  }
}
