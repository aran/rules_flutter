/// Everything it takes to get an edit into a running app, as one object.
///
/// The `app.hotReload` / `app.restart` handlers close over this object and are
/// registered before any of its fields exists — a client can send a command
/// the moment the protocol starts listening, which is long before there is a
/// compiler to answer with. [ready] is what makes that safe: a command queues
/// on the gate instead of racing setup into a null.
///
/// One object because it is one thing. A pipeline is a compiler
/// ([frontendServer]) pointed at an [entrypoint], a view of the source tree
/// ([workspaceView], [resolver]) and a record of what of it is live
/// ([appliedVersions]), a way to apply the result ([orchestrator] on native,
/// [strategy] everywhere), and the rebuilds that have to happen first
/// ([refreshGenerated], [rebuildAssets], [relaunchIfNativeLibsChanged]). Naming
/// it is what lets `attach` have one too.
///
/// Assembled once per run, by whichever assembler fits the platform, and
/// assigned field by field as each piece becomes available. Fields are nullable
/// because a pipeline that failed to assemble is a real state — the handlers
/// answer out of [ready], and these nulls are what they say.
library;

import 'dart:async';

import 'frontend_server.dart';
import 'hot_reload/app_instance.dart';
import 'hot_reload/applied_versions.dart';
import 'hot_reload/asset_bundle.dart';
import 'hot_reload/package_uri_resolver.dart';
import 'hot_reload/readiness_gate.dart';
import 'hot_reload/reload_orchestrator.dart';
import 'hot_reload/workspace.dart';
import 'command_report.dart';
import 'logging.dart';
import 'outcome_renderer.dart';
import 'reload_strategy.dart';
import 'session.dart';
import 'session_host.dart';

final _logger = Logger('dev_tool.reload_pipeline');

class ReloadPipeline {
  /// The sessions this pipeline applies to, and the appId targeting rules.
  final SessionHost host;

  /// Bridges the gap between the `app.started` protocol event (emitted from the
  /// launch loop) and this pipeline being wired (assembled after it).
  /// [hotReload] and [restart] await it, so a client firing on `app.started`
  /// queues instead of racing the setup into an orchestrator-null error.
  final ReadinessGate ready = ReadinessGate();

  /// A per-file record of what is currently live in the running app.
  final AppliedVersions appliedVersions = AppliedVersions();

  /// The persistent incremental compiler. Null until assembly reaches it, and
  /// nulled again if assembly fails, which is what makes the handlers' `No
  /// frontend server available` true rather than merely likely.
  FrontendServer? frontendServer;

  /// What the compiler is pointed at: the build-authoritative `package:` URI on
  /// native, `org-dartlang-app:/web_entrypoint.dart` on web.
  String entrypoint = '';

  /// Maps live source paths to `package:` URIs, for snapshot keying and the
  /// filesystem watcher. Built from the build-emitted sourcePackages.
  PackageUriResolver? resolver;

  /// The source tree as the compiler sees it, snapshot by snapshot.
  Workspace? workspaceView;

  /// Native's apply path: a bounded RPC budget per app, compiler commit and
  /// rollback, and a report of what was actually recompiled. Null on web DDC,
  /// which goes through [strategy] directly.
  ReloadOrchestrator? orchestrator;

  /// How a compiled increment reaches the device. Named rather than defaulted:
  /// a native default would send web reloads looking for a VM service the
  /// browser does not have, and report its absence as the failure.
  ReloadStrategy? strategy;

  /// Regenerates a codegen app's sources via bazel before a recompile. Null for
  /// apps with no generated sources, which is what keeps a Dart-only edit off
  /// the bazel path entirely.
  Future<bool> Function()? refreshGenerated;

  /// Tracks the built `flutter_assets` tree so an edit to a PNG or a font
  /// reaches the running app the way an edit to a `.dart` file does.
  AssetTracker? assetTracker;

  /// Rebuilds the bundle [assetTracker] watches. Distinct from
  /// [refreshGenerated], which exists only for codegen apps and rebuilds for a
  /// different reason; this one runs for every app, but only once the asset
  /// sources on disk have actually moved.
  Future<bool> Function()? rebuildAssets;

  /// For apps bundling loose native libraries: rebuilds and, when the rebuilt
  /// bundle's libraries differ from the running process's, relaunches the
  /// process — a hot restart cannot replace a dlopened image. Null for apps
  /// with no loose native libraries.
  ///
  /// A [RelaunchOutcome] rather than a response map: what it decided and how
  /// the decision is worded are two jobs, and only [restart] can do the second
  /// one, because only it holds the asset diff that belongs in the same reply.
  Future<RelaunchOutcome> Function()? relaunchIfNativeLibsChanged;

  /// Why the browser page has never been given a program, or null once it has.
  ///
  /// Web only, and the counterpart of `SessionReloader.baselineFailure` on
  /// native — with one difference that decides what it is for. On native a
  /// failed first compile leaves an app *running the build it launched with*,
  /// so a later hot reload has a program to inject into. On web there is no
  /// such program: Chrome opens the module server before anything has compiled,
  /// and what the page loads is the first compile's own output. A first compile
  /// that failed therefore leaves nothing on the page at all.
  ///
  /// So while this is set, an increment has nothing to be an increment *of*.
  /// [hotReload] answers by running [restart] instead, which compiles the whole
  /// program and loads it — and the compile verb matters as much as the
  /// completeness: a `recompile` after a rejected first `compile` answers with a
  /// delta, and a delta merged as a first compile leaves the module server
  /// serving a fraction of a program while believing it holds all of one.
  ///
  /// Cleared by the restart that succeeds, which is the moment the page has a
  /// program.
  String? webBaselineFailure;

  /// Another go at assembling this pipeline, set when the last attempt failed
  /// on something a later state change can cure — today, a `bazel build` of
  /// the app that did not compile. Null when assembly succeeded, has not been
  /// tried, or failed for good.
  ///
  /// Nothing calls this on a timer. The next reload request is what calls it,
  /// which is the same event that drives every compile: the user saved the fix,
  /// and the reload that save owes is the one that builds again.
  Future<void> Function()? reassemble;

  /// Whether this pipeline still owes an assembly attempt — one armed and
  /// waiting for a request, or one running right now.
  ///
  /// Read by the file watcher, which otherwise has no reason to wake a pipeline
  /// it cannot map paths for — see `session.dart`.
  ///
  /// The in-flight half is not a detail. An attempt clears [reassemble] as it
  /// starts and re-arms it only if it fails, and a build takes seconds: the
  /// save that fixes the code usually lands *inside* one. Without this the
  /// watcher would drop exactly that edit, the attempt would finish with the
  /// broken tree it read, and nothing would ever ask again.
  bool get awaitingAssembly => reassemble != null || _attemptInFlight;

  /// Serializes assembly attempts, so two requests arriving together produce
  /// two builds one after another rather than two at once.
  Future<void> _attempts = Future<void>.value();
  bool _attemptInFlight = false;

  ReloadPipeline({required this.host});

  /// Whether this run can hot reload at all.
  ///
  /// Native answers through [orchestrator] — which owns one compiler per app,
  /// so there is no single frontend server to point at — and web DDC through
  /// [frontendServer]. Asked rather than inferred from either field, because
  /// "is there a compiler" is not one question once the native side has
  /// several.
  bool get hasReloadPath => orchestrator != null || frontendServer != null;

  /// Whether [path] feeds the asset bundle.
  ///
  /// Asked per event rather than captured: the tracker is built late (it needs
  /// the build outputs) and re-learns which directories feed the bundle after
  /// every rebuild, so a directory that starts holding assets mid-run starts
  /// being watched without restarting anything.
  bool watchesAsset(String path) => assetTracker?.watches(path) ?? false;

  /// Block until the pipeline has finished wiring (or definitively failed).
  ///
  /// Returns an error map to short-circuit the handler when hot reload is
  /// unavailable, or null when it is safe to proceed. This is what closes the
  /// `app.started`-before-orchestrator race.
  ///
  /// Through [CommandReport.unavailable] — whose whole purpose is this refusal
  /// — rather than a hand-built `{'error': …}`. A bare map carries neither the
  /// verdict nor [CommandReport.runningCode], and this is the arm where the
  /// latter is both most certain and most worth saying: the command stopped
  /// before anything was delivered, so the app is definitely still running
  /// what it was.
  ///
  /// [verb] is carried but not rendered on this arm: both renderers answer a
  /// refusal with its reason alone, because the reason is a whole sentence and
  /// the reader already knows which command they sent. It is passed anyway so
  /// the report is well-formed rather than carrying a placeholder — if the
  /// refusal arm ever grows a composed sentence, the word it needs is there.
  Future<Map<String, dynamic>?> _awaitReady(String verb) async {
    await ready.whenReady.timeout(
      const Duration(seconds: 90),
      onTimeout: () {},
    );
    // An attempt in flight holds the gate open, and waiting for *it* is a
    // different thing from waiting out the clock above: something is running,
    // it will settle, and a `bazel build` taking its time is not evidence that
    // anything is wrong. The bound above stays for the case it was written
    // for — a run mode that settles the gate never at all.
    if (!ready.isSettled) await _attempts;
    // A gate settled retryable is a verdict on the last attempt, not on the
    // run. This request is the event that makes the next one.
    if (ready.isRetryable) await _assembleAgain();
    if (!ready.isReady) {
      return toWire(
        CommandReport(
          verb: verb,
          unavailable:
              ready.unavailableReason ?? 'Hot reload is still starting up.',
        ),
      );
    }
    return null;
  }

  /// Run one more assembly attempt for this request, behind whatever attempt is
  /// already running.
  ///
  /// The re-check is at *acquisition*, not before the queue. Builds take
  /// seconds and saves take
  /// milliseconds, so this order is ordinary: a save that is still broken
  /// starts attempt one, the user saves the fix while it is building, and the
  /// reload that fix owes queues behind it. Reporting attempt one's verdict to
  /// it would report a build of a tree that did not contain the fix — and
  /// nothing would ever try again, because the event that would have driven the
  /// next attempt has just been spent on the wrong answer.
  ///
  /// Not a retry loop: one attempt per request, and every request is a user
  /// event — a save, an `r`, an `app.hotReload`. Nothing here schedules itself.
  Future<void> _assembleAgain() async {
    final previous = _attempts;
    // Completed in the `finally` and never with an error, so one attempt's
    // failure cannot poison the queue behind it.
    final mine = Completer<void>();
    _attempts = mine.future;
    try {
      await previous;
      if (!ready.isRetryable) return;
      final retry = reassemble;
      if (retry == null) return;
      ready.reopen();
      _attemptInFlight = true;
      try {
        await retry();
      } finally {
        _attemptInFlight = false;
      }
    } catch (e) {
      // Assembly is documented never to throw. If one ever does, the gate it
      // reopened would otherwise never settle, and every later request would
      // wait out the full timeout above before answering "still starting up".
      // The cause travels into the reason rather than being dropped.
      ready.signalUnavailable(
        'Reassembling the hot-reload pipeline failed unexpectedly: $e',
      );
    } finally {
      mine.complete();
    }
  }

  /// Convert a [ReloadOutcome] from the orchestrator to a machine-protocol
  /// response map. `isEmpty` distinguishes a real reload from one whose
  /// declared files turned out byte-identical to what was already applied.
  /// Bring the running app(s)' assets up to date with the source tree.
  ///
  /// Runs on every reload and restart, but costs almost nothing when no asset
  /// source has moved: [AssetTracker.sourcesAreStale] is a few directory
  /// listings and a pass over the asset bytes — and only a positive answer buys
  /// a `bazel build`. That is what keeps a
  /// Dart-only edit on the instant path.
  ///
  /// `fatal` aborts the caller — the build is broken, and the code half of the
  /// same edit would fail to compile against it anyway. `problem` is an asset
  /// delivery that did not reach every device; it must not stop a Dart edit
  /// going live, but the user has to be told, or they are looking at a
  /// "successful" reload showing the old artwork.
  ///
  /// [deliver] is false when the caller is about to restart. Every strategy
  /// re-reads the whole bundle as part of a restart — native `runInView` takes
  /// the asset directory as an argument, DWDS re-runs `main()`, the CDP paths
  /// navigate — so the rebuild is all that is needed, and evicting individual
  /// assets first would be work the next step throws away.
  Future<AssetOutcome> _refreshAssets(
    List<DeviceSession> targets, {
    required bool deliver,
  }) async {
    const nothingToDo = AssetOutcome.none;
    final tracker = assetTracker;
    final rebuild = rebuildAssets;
    final applyTo = strategy;
    if (tracker == null || rebuild == null || applyTo == null) {
      return nothingToDo;
    }
    if (!tracker.sourcesAreStale) return nothingToDo;

    // Stamped before the build, not after: a source saved while bazel is
    // reading it is not in the tree bazel produces, and committing it as
    // delivered is how that edit is lost. Same guard, same reason, as the
    // tracker's own baseline.
    final rebuiltBefore = DateTime.now();
    if (!await rebuild()) {
      return const AssetOutcome(
        rebuildFailed: 'Asset rebuild (bazel) failed; see build output above.',
      );
    }
    // Committed either way, so the next reload does not re-report what a
    // restart has already delivered. The build is the authority on what
    // actually changed: an edit that leaves the bundle byte-identical reaches
    // here with nothing to do, and the app is left alone.
    final changed = tracker.takeBundleChanges(rebuiltBefore: rebuiltBefore);
    if (changed.isEmpty || !deliver) {
      // Not `nothingToDo`. A source moved, a build ran, and the bundle came
      // back byte-identical — which is legitimate (an edit reverted, a save
      // that changed nothing) and is also exactly what a Bazel action cache
      // serving a stale tree looks like. Reported as the same silence as "no
      // source moved", the two are indistinguishable from outside, and a
      // stale asset in a running app has two suspects and no way to choose.
      return changed.isEmpty
          ? const AssetOutcome(rebuiltIdentical: true)
          : AssetOutcome(changed: changed);
    }

    final outcome = await applyTo.applyAssets(changed, targets);
    return AssetOutcome(changed: changed, delivery: outcome);
  }

  /// The orchestrator apps a request addresses: all of them when it names no
  /// appId, exactly the named one otherwise.
  ///
  /// Returns an error map instead when the name matches no session, or a
  /// session the orchestrator has no app for (its VM service never came up).
  /// A value rather than a throw because a bad appId is the client's mistake,
  /// refused on the wire like any other bad request.
  ///
  /// [verb] names the command being refused, and is passed on to [_refuse] —
  /// which see for what does and does not become words.
  ({List<AppInstance>? targets, Map<String, dynamic>? error}) _resolveTargets(
    ReloadOrchestrator orch,
    Map<String, dynamic> params,
    String verb,
  ) {
    final appId = params['appId'] as String?;
    if (appId == null) return (targets: orch.apps, error: null);
    if (host.findSession(appId) == null) {
      return (targets: null, error: _refuse(verb, 'Unknown appId: $appId'));
    }
    final named = [
      for (final app in orch.apps)
        if (app.id == appId) app,
    ];
    if (named.isEmpty) {
      return (
        targets: null,
        error: _refuse(
          verb,
          'App "$appId" has no reload connection (its VM service '
          'never came up), so it cannot take a hot reload or restart.',
        ),
      );
    }
    return (targets: named, error: null);
  }

  /// A command that never ran, answered as one.
  ///
  /// Through [CommandReport.unavailable] rather than a hand-built
  /// `{'error': …}`, for the reason given on [_awaitReady]: a bare map carries
  /// neither the verdict nor [CommandReport.runningCode], and every refusal
  /// here has the same two things to say — it failed, and the app is still
  /// running exactly what it was, because nothing was compiled and nothing was
  /// sent. That second fact is the one a reader most wants and the one no
  /// message can assert honestly on its own.
  ///
  /// [reason] is passed through verbatim: whether the run has no compiler at
  /// all or the request simply named an app that does not exist is a
  /// distinction the sentence carries, not one the shape does.
  Map<String, dynamic> _refuse(String verb, String reason) =>
      toWire(CommandReport(verb: verb, unavailable: reason));

  /// Restart the app: a full recompile and a fresh `main()`.
  Future<Map<String, dynamic>> restart(Map<String, dynamic> params) async {
    final notReady = await _awaitReady('Restart');
    if (notReady != null) return notReady;

    // Native: orchestrator-based restart.
    final orch = orchestrator;
    if (orch != null) {
      final resolved = _resolveTargets(orch, params, 'Restart');
      if (resolved.error != null) return resolved.error!;
      final targets = resolved.targets!;
      // What the reply reports it addressed. Read from the resolved targets
      // rather than from `params`, so it says what the command actually
      // reached: an unaddressed command names every app, and the set of apps
      // is not fixed for the life of a run.
      final addressed = [for (final t in targets) t.id];
      // Rebuild the asset bundle before the restart re-reads it. The
      // restarting apps need no delivery — `runInView` is handed the asset
      // directory and rebuilds the engine's asset manager from it, fonts
      // included. An app this restart leaves running is different: the
      // rebuild has already changed the tree under it, its cache is stale
      // either way, and the diff is committed below — so it is told what to
      // evict now, or it would show the old artwork until its own restart.
      final targetIds = {for (final t in targets) t.id};
      final orchestrated = {for (final app in orch.apps) app.id};
      final untargeted = [
        for (final s in host.sessions)
          if (orchestrated.contains(s.appId) && !targetIds.contains(s.appId)) s,
      ];
      final assets = await _refreshAssets(
        untargeted,
        deliver: untargeted.isNotEmpty,
      );
      if (assets.rebuildFailed != null) {
        return toWire(
          CommandReport(verb: 'Restart', appIds: addressed, assets: assets),
        );
      }
      // Native libraries cannot be hot-restarted (the process keeps its
      // dlopened images) — rebuild first and relaunch if they changed. The
      // relauncher replaces every process that dlopened the stale libraries,
      // targeted or not: the bundle is one shared tree, and a process left on
      // unloaded old machine code would crash, not hot-reload.
      final relaunch = relaunchIfNativeLibsChanged;
      if (relaunch != null) {
        switch (await relaunch()) {
          // The rebuild that had to happen before anything could be compiled,
          // and it did not. Reported the way the codegen rebuild's failure is,
          // and for the same reason: not `unavailable`, which says this run
          // cannot reload at all and would have a driver retire the session
          // over a build error it can fix and retry.
          case RelaunchBuildFailed(:final reason):
            return toWire(
              CommandReport(
                verb: 'Restart',
                appIds: addressed,
                assets: assets,
                sourceRebuildFailed: reason,
              ),
            );
          // The process was replaced, so there is no isolate restart left to
          // do — this IS the restart's answer.
          case Relaunched relaunched:
            return toWire(
              CommandReport(
                verb: 'Restart',
                appIds: addressed,
                assets: assets,
                relaunch: relaunched,
              ),
            );
          // The libraries are unchanged; fall through to the isolate restart,
          // the fast path this whole check exists to protect.
          case RelaunchNotNeeded():
            break;
        }
      }
      return toWire(
        CommandReport(
          verb: 'Restart',
          appIds: addressed,
          outcome: await orch.restart(targets: targets),
          assets: assets,
        ),
      );
    }

    // Web DDC.
    //
    // Not a legacy path awaiting the orchestrator. The orchestrator's unit
    // commits or rolls
    // back a compiler baseline against what one app accepted; on web the
    // generation is merged into the served module tree before the browser has
    // said anything (`DwdsReloadStrategy` calls `updateModules` first, and
    // DWDS then reconciles by digest), so a rollback would leave the compiler
    // describing a program the server is no longer serving. Web's apply is
    // the strategy, and this is where it belongs.
    final fs = frontendServer;
    if (fs == null || entrypoint.isEmpty) {
      return _refuse('Restart', 'No frontend server available');
    }
    final applyTo = strategy;
    if (applyTo == null) {
      return _refuse('Restart', 'No reload strategy for this session.');
    }
    final targets = host.targetSessions(params);
    if (targets.isEmpty && params.containsKey('appId')) {
      return _refuse('Restart', 'Unknown appId: ${params['appId']}');
    }
    // See the native arm: reported from what was resolved, not from params.
    final addressed = [for (final s in targets) s.appId];
    // Codegen apps: regenerate before the restart's full recompile.
    if (refreshGenerated != null && !(await refreshGenerated!())) {
      return toWire(
        CommandReport(
          verb: 'Restart',
          appIds: addressed,
          sourceRebuildFailed: 'Generated source rebuild (bazel) failed.',
        ),
      );
    }
    // Same as native: rebuild the bundle, let the restart re-fetch it.
    final assets = await _refreshAssets(targets, deliver: false);
    if (assets.rebuildFailed != null) {
      // 'Restart', because that is the command that failed. Reported as a hot
      // reload, the one line the user gets names an operation they did not run.
      return toWire(
        CommandReport(verb: 'Restart', appIds: addressed, assets: assets),
      );
    }
    // Cut before the recompile, not after it, and after the two rebuilds
    // above so a regenerated file is in it. What the restart makes live is
    // what the compiler reads, and it reads it over the whole of the compile;
    // a snapshot taken afterwards records the *post-edit* version of a file
    // edited while that was happening, and the compile may well have missed
    // it. Recorded as live, it is then dropped — the next reload finds no
    // change. Read beforehand, the worst case is re-sending a file the
    // compile did pick up. Native's orchestrator snapshots before compiling
    // for the same reason.
    final preCompile = workspaceView?.snapshot();
    // What the restart's `reset` + `recompile` is told changed. It does not
    // decide what is compiled — the reset re-reads the whole tree — but the
    // compiler takes both on one request and keeps per-file state, so it is
    // owed the same list an incremental compile would give it. Derived from the
    // same snapshot the success path commits, so the two cannot disagree about
    // which version of a file this restart is about.
    final invalidated = preCompile == null
        ? const <String>[]
        : appliedVersions.findChangedFrom(preCompile).toList();
    final result = await recompileAndRestart(
      frontendServer: fs,
      entrypoint: entrypoint,
      invalidatedFiles: invalidated,
      sessions: targets,
      reloadStrategy: applyTo,
    );
    if (result.success && preCompile != null) {
      // After a restart, every file the compile read is live.
      appliedVersions.clear();
      appliedVersions.markApplied(
        preCompile,
        files: preCompile.fileUris.toSet(),
      );
    }
    if (result.success) {
      // The page has a program now, so the reason it had none has stopped being
      // true. Cleared on the whole result rather than on the compile alone: a
      // compile that nothing could load leaves the page exactly as empty as it
      // was, and the next reload still has no increment to make.
      webBaselineFailure = null;
    }
    // The same rendering as every other reload response, and as web's own hot
    // reload below.
    return toWire(
      CommandReport(
        verb: 'Restart',
        appIds: addressed,
        outcome: result.compileSuccess
            ? null
            : ReloadCompileFailed(result.diagnostics),
        strategy: result.outcome,
        assets: assets,
        elapsed: Duration(milliseconds: result.elapsedMs),
      ),
    );
  }

  /// Hot reload: recompile what changed and inject it into the live isolate.
  Future<Map<String, dynamic>> hotReload(Map<String, dynamic> params) async {
    final notReady = await _awaitReady('Hot reload');
    if (notReady != null) return notReady;

    final declared =
        (params['invalidatedFiles'] as List?)?.cast<String>().toSet() ??
        <String>{};

    // Native: orchestrator-based reload (includes per-AppInstance RPC budget).
    final orch = orchestrator;
    if (orch != null) {
      final resolved = _resolveTargets(orch, params, 'Hot reload');
      if (resolved.error != null) return resolved.error!;
      final targets = resolved.targets!;
      // See `restart` above: reported from the resolved set, not from params.
      final addressed = [for (final t in targets) t.id];
      // Assets go to every session even when the Dart half is targeted: the
      // bundle is one shared tree and the rebuild has already changed it
      // under every app, so an eviction withheld from an untargeted app would
      // not preserve its old artwork — it would strand its cache stale
      // forever, because the diff below is committed once.
      final assets = await _refreshAssets(host.sessions, deliver: true);
      if (assets.rebuildFailed != null) {
        return toWire(
          CommandReport(verb: 'Hot reload', appIds: addressed, assets: assets),
        );
      }
      final outcome = await orch.reload(declared: declared, targets: targets);
      return toWire(
        CommandReport(
          verb: 'Hot reload',
          appIds: addressed,
          outcome: outcome,
          assets: assets,
        ),
      );
    }

    // Web DDC: recompileAndReload + AppliedVersions for change detection.
    // Not a global `_lastCompileTime`; every file's last-applied version is
    // tracked individually. See `restart` above for why this is web's path
    // rather than a stop on the way to the orchestrator.
    final fs = frontendServer;
    final ws = workspaceView;
    if (fs == null || entrypoint.isEmpty || ws == null) {
      return _refuse('Hot reload', 'No frontend server available');
    }
    final applyTo = strategy;
    if (applyTo == null) {
      return _refuse('Hot reload', 'No reload strategy for this session.');
    }
    final targets = host.targetSessions(params);
    if (targets.isEmpty && params.containsKey('appId')) {
      return _refuse('Hot reload', 'Unknown appId: ${params['appId']}');
    }
    // See the native arm: reported from what was resolved, not from params.
    final addressed = [for (final s in targets) s.appId];

    // A page that was never given a program has no increment to take. Answered
    // by doing the thing that would work rather than by refusing: under
    // `--watch` the save that fixes the code IS this request, so a refusal
    // would leave the user with a blank browser and an instruction to press a
    // key. See [webBaselineFailure] for why an increment is not merely
    // insufficient here but actively wrong — the compile verb differs, and a
    // delta merged as a first compile is unrecoverable.
    //
    // Ahead of the rebuilds below because [restart] runs its own, and running
    // them twice for one request would rebuild the tree the user is still
    // editing.
    if (webBaselineFailure != null) {
      // Said, not silently substituted. The answer comes back with the verb
      // `Restart`, and a client that asked for a hot reload is owed the reason
      // it got one — `--machine` drops `text`, so the reason is a field.
      _logger.info({
        'message': 'reload_promoted_to_restart',
        'text':
            'The browser page has never loaded a program, so there is '
            'nothing to hot reload into. Running a restart instead, which '
            'compiles the whole program and loads it.\n$webBaselineFailure',
        'reason': webBaselineFailure,
      });
      return restart(params);
    }

    // Codegen apps: rebuild generated sources via bazel before snapshotting, so
    // a regenerated `.g.dart` is detected as changed and recompiled.
    if (refreshGenerated != null && !(await refreshGenerated!())) {
      return toWire(
        CommandReport(
          verb: 'Hot reload',
          appIds: addressed,
          sourceRebuildFailed: 'Generated source rebuild (bazel) failed.',
        ),
      );
    }

    final assets = await _refreshAssets(targets, deliver: true);
    if (assets.rebuildFailed != null) {
      return toWire(
        CommandReport(verb: 'Hot reload', appIds: addressed, assets: assets),
      );
    }

    final snap = ws.snapshot();
    final fsChanged = appliedVersions.findChangedFrom(snap);
    final invalidated = {...fsChanged, ...declared};
    if (invalidated.isEmpty) {
      // Not "nothing happened": an asset-only edit lands here with the new
      // bundle already delivered, and reporting no changes would be wrong.
      return toWire(
        CommandReport(
          verb: 'Hot reload',
          appIds: addressed,
          outcome: const ReloadNoChange(),
          assets: assets,
        ),
      );
    }

    final result = await recompileAndReload(
      frontendServer: fs,
      entrypoint: entrypoint,
      invalidatedFiles: invalidated.toList(),
      sessions: targets,
      reloadStrategy: applyTo,
    );
    if (result.success) {
      appliedVersions.markApplied(snap, files: invalidated);
    }
    return toWire(
      CommandReport(
        verb: 'Hot reload',
        appIds: addressed,
        outcome: result.compileSuccess
            ? null
            : ReloadCompileFailed(result.diagnostics),
        strategy: result.outcome,
        assets: assets,
        elapsed: Duration(milliseconds: result.elapsedMs),
      ),
    );
  }
}
