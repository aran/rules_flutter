/// One app's reload machinery: its own compiler, its own record of what it is
/// running, and the app itself.
///
/// The invariant this class exists to hold: **[applied] mirrors [compiler]'s
/// accepted baseline.** They advance together on an apply the VM took and hold
/// together on one it did not, so the compiler's belief about what the app has
/// is never out of step with the record's — nor with the app's. Note "took",
/// not "succeeded": an app that threw on the frame after a reload is still
/// running the code that was sent it.
///
/// That invariant is why each app needs its own compiler rather than a share
/// of one. A `frontend_server` decides which *dependent* libraries to re-emit
/// by comparing against its own accepted state — a library that inlines a
/// `const` from an edited file is recompiled the first time, and then never
/// again, because the compiler now believes it is current. An app that missed
/// that delta can never ask for it back: its own source bytes never changed,
/// so no per-file version record can flag it. One compiler per app makes the
/// question unaskable — each compiler's baseline *is* its app's program, so a
/// lagging app's next reload re-derives exactly what it lacks.
///
/// There is one state where the invariant is knowingly not yet true, and
/// [baselineFailure] is what names it: a unit whose *first* compile failed.
/// Its [applied] record is still right — it describes the build the app was
/// launched from, which is what the app is running — but its compiler has
/// accepted nothing, so there is no baseline for the record to mirror. The
/// unit is kept anyway, because a first compile is not different in kind from
/// any later one: the source on disk failed to compile, and the next compile
/// of a fixed tree is what settles it. Everything the unit needs to do that
/// is already here.
library;

import 'app_instance.dart';
import 'applied_versions.dart';
import 'compiler.dart';
import 'workspace.dart';

class SessionReloader {
  /// The session's appId — how a request targets this unit.
  final String id;

  /// This app's compiler. Not shared: see the library doc.
  final Compiler compiler;

  /// What this app is running, per file. Seeded from the build's baseline and
  /// advanced only by this unit's own successful applies.
  final AppliedVersions applied;

  /// The live app. Mutable because the native-libs relauncher replaces the
  /// process — and so the connection — while the unit's identity persists.
  AppInstance app;

  /// Whether [app] is a connection anything can be applied to.
  ///
  /// False when a relaunch replaced the process but its VM service never came
  /// back. The unit survives that — its compiler and its record are still the
  /// truth about what this app was running, and a later reconnect restores it —
  /// but [app] is a closed socket, and a request that names it deserves to be
  /// told so rather than watching a kernel fail to apply.
  bool connected = true;

  /// Why this app's first compile failed, or null once its source has
  /// compiled.
  ///
  /// Non-null means the app is running its launch build and nothing this unit
  /// has compiled has ever reached it. That does not stop a reload — the next
  /// one recovers — but it changes what an *empty* reload means. "No change" on
  /// a unit that has never compiled would be a true statement about disk and a
  /// misleading one about the app, so the caller restates this instead.
  ///
  /// Carried per unit rather than on the pipeline: each app has its own
  /// compiler, so each can be in this state on its own.
  String? baselineFailure;

  SessionReloader({
    required this.id,
    required this.compiler,
    required this.applied,
    required this.app,
    this.baselineFailure,
  });

  /// What this app lacks at [snapshot], plus anything the caller [declared].
  ///
  /// Per unit, never unioned across units: each compiler is asked only for
  /// what its own app is missing, and re-derives the dependents itself.
  Set<String> pendingAt(SourceVersions snapshot, {Set<String>? declared}) => {
    ...applied.findChangedFrom(snapshot),
    ...?declared,
  };

  /// Compile what this app needs.
  ///
  /// A restart recompiles the whole program — the committed kernel is being
  /// thrown away regardless — but is still told what changed, because the
  /// compiler underneath takes the reset and the invalidation on one request.
  Future<CompileOutcome> compile({
    required Set<String> invalidated,
    required String entrypoint,
    required ApplyMode mode,
  }) async {
    final outcome = mode == ApplyMode.hotRestart
        ? await compiler.compileFull(
            entrypoint: entrypoint,
            invalidated: invalidated,
          )
        : await compiler.compileIncrement(
            invalidated: invalidated,
            entrypoint: entrypoint,
          );
    // This app's source has compiled, so [baselineFailure] has stopped being
    // true of it. Cleared on the compile rather than on the apply, because
    // what it claims is that the SOURCE never compiled; an apply that fails
    // afterwards is a separate report about a separate thing. Nothing is lost
    // by the earlier clear: a failed apply rolls the compiler back and leaves
    // [applied] untouched, so those files stay pending and the next reload
    // re-offers them rather than reaching the empty-reload arm at all.
    if (outcome is CompileSucceeded) baselineFailure = null;
    return outcome;
  }

  /// Send [dillPath] to the app and settle the bookkeeping in lockstep.
  ///
  /// The only place [applied] advances, and the only place [compiler] commits
  /// — which is what makes the two impossible to separate. What decides the
  /// verdict is whether the code reached the VM, not whether the user got what
  /// they wanted:
  ///
  ///   - refused or timed out: nothing landed, so the compiler rolls back and
  ///     the record holds, and the next reload re-offers the same work against
  ///     the same baseline;
  ///   - [AppliedThenThrew]: the code **is** running — the app threw on the
  ///     frame after it landed — so both advance. Rolling back here would ask
  ///     the compiler to forget what the VM is executing, and every later
  ///     delta would be computed against a program that exists nowhere.
  ///
  /// The failing outcome is returned either way; this is the bookkeeping's
  /// business, not the caller's.
  ///
  /// [invalidated] is what was compiled for this unit; for a restart every
  /// file on disk is now live, so the record is cleared first.
  Future<ApplyOutcome> applyAndSettle(
    String dillPath, {
    required ApplyMode mode,
    required SourceVersions snapshot,
    required Set<String> invalidated,
  }) async {
    final outcome = await app.applyKernel(dillPath, mode: mode);
    // Switched rather than tested, so a new outcome cannot join the pipeline
    // without someone deciding here what the VM ended up holding.
    final landed = switch (outcome) {
      Applied() || AppliedThenThrew() => true,
      ApplyFailed() || ApplyTimedOut() => false,
    };
    if (!landed) {
      await compiler.rollback();
      return outcome;
    }
    await compiler.commit();
    if (mode == ApplyMode.hotRestart) applied.clear();
    applied.markApplied(snapshot, files: invalidated);
    return outcome;
  }

  /// Throw away a compile that will not be applied, restoring the baseline.
  Future<void> discard() => compiler.rollback();

  /// Shut this unit's compiler down.
  Future<void> shutdown() => compiler.shutdown();
}
