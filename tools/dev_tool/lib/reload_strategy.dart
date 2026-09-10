/// Strategy for applying compilation results to running devices.
///
/// Abstracts the difference between VM service-based hot reload (native),
/// DWDS VM service-based reload (web DDC), and CDP page reload (web WASM).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart' as vm;

import 'cdp_console.dart';
import 'frontend_server.dart';
import 'hot_reload/asset_bundle.dart' show touchesFonts;
import 'logging.dart';
import 'session.dart';
import 'vm_service_client.dart';
import 'web_module_server.dart';

final _logger = Logger('dev_tool.reload');

/// `kIsolateCannotReload`. DWDS raises it when no browser client is attached.
const int _rpcIsolateCannotReload = 109;

/// `kServerError`. Reached by the same "no client" condition on the Chrome
/// path, which fails with a `StateError` that `package:vm_service` re-encodes
/// rather than preserving code 109. Upstream accepts both for this reason
/// (`resident_web_runner.dart:544-546`).
const int _rpcServerError = -32000;

/// Said while no browser has connected *yet* — the startup window, before the
/// page arrives. Not a failure, and the promise it makes is kept: the modules
/// are served, so the first client to connect loads them.
const String _noClientYetMessage =
    'no browser client connected yet — the recompiled '
    'code will load when one does';

/// Said when the browser that WAS connected has gone: the tab closed, or the
/// page navigated somewhere else.
///
/// Promises nothing, deliberately. After a tab close, reopening the app URL
/// does not reconnect and the app does not come back, so nothing this session
/// can do will deliver that code.
/// Why a reopened page fails to connect is a separate open question; until it
/// is answered, this must not imply a recovery that does not happen.
const String _clientGoneMessage =
    'the browser page this session was driving is gone — closed, or navigated '
    'away — so there is nothing left to deliver the recompiled code to';

/// What applying compiled output to the running app(s) achieved.
///
/// Sits below `ReloadOutcome` in `hot_reload/reload_orchestrator.dart`, which
/// describes a whole compile-and-apply cycle; this describes only the apply.
/// The two converge once web joins the orchestrator via `AppInstance`.
///
/// A bool cannot tell "every app took it" apart from "no app could take it",
/// and both reduce to `true` under `[].every(...)`. Reporting the second as
/// success is worse than reporting a failure: the user is told their edit is
/// live when nothing received it.
sealed class StrategyOutcome {
  const StrategyOutcome();

  /// Whether the edit is actually running now.
  bool get isSuccess => this is StrategyApplied;

  /// One line explaining a non-success, for the terminal and the protocol.
  String get message;
}

/// The edit reached [deviceCount] running app(s).
final class StrategyApplied extends StrategyOutcome {
  final int deviceCount;

  const StrategyApplied(this.deviceCount);

  @override
  String get message => 'applied to $deviceCount device(s)';
}

/// Nothing could take the edit, so nothing changed.
///
/// Distinct from rejection: no app was ever reached. A session with no VM
/// service connection, or a compilation mode with no reload mechanism at all,
/// lands here.
final class StrategyUnsupported extends StrategyOutcome {
  @override
  final String message;

  const StrategyUnsupported(this.message);
}

/// The apply threw, so the strategy never formed a verdict at all.
///
/// Its own outcome rather than a [StrategyRejected] for the reason [timedOut]
/// is kept apart from [refused] below: a rejection says an app answered no,
/// which is a fact about the app, while a throw says the attempt fell over and
/// nothing answered anything.
///
/// Not a compile failure either: the compiler has already answered with a dill
/// and been told to accept it.
///
/// The message deliberately claims nothing about what the app is now running.
/// Every escape reachable today happens before anything is delivered — all
/// three strategies call `WebModuleServer.updateModules` outside their own try
/// — but escapes from mid-delivery exist too (`DwdsReloadStrategy.applyRestart`
/// catches only `TimeoutException` and `RPCError`), and one message covers
/// both. Saying "the app state is unknown" would also contradict the sentence
/// `reportReloadCommand` appends to every error it prints.
final class StrategyThrew extends StrategyOutcome {
  /// The tool's own exception, not the app's — nothing here came back from a
  /// running app.
  final Object error;

  const StrategyThrew(this.error);

  @override
  String get message => 'the reload strategy threw ($error)';
}

/// An app was reached and did not end up running the edit.
final class StrategyRejected extends StrategyOutcome {
  @override
  final String message;

  /// App ids that were reached and refused. Empty when the refusal was not
  /// per-device — a browser declining the new sources, a CDP error — where
  /// there is no device list to name.
  final List<String> refused;

  /// App ids that were reached and took it. A partial failure is a real state:
  /// some apps are running the edit and some are not, and which is which is
  /// the first thing anyone asks.
  final List<String> applied;

  /// App ids that never answered inside the per-device budget.
  ///
  /// Kept apart from [refused] on purpose. "Refused" says the app answered no,
  /// which is a fact about the app; a timeout says nothing came back at all and
  /// what the app is running is unknown. Folding the two would report a
  /// definite answer nobody received — the same class of lie as
  /// `[].every(...)` reporting success, and the reason `ApplyTimedOut` is its
  /// own type rather than an `ApplyFailed`.
  final List<String> timedOut;

  const StrategyRejected(this.message)
    : refused = const [],
      applied = const [],
      timedOut = const [];

  /// The per-device failure, which composes its own sentence from the lists
  /// rather than being handed one.
  StrategyRejected.devices({
    required this.refused,
    required this.applied,
    this.timedOut = const [],
  }) : message = _devicesMessage(refused, applied, timedOut);

  /// One clause per kind of failure, counted against every device that was
  /// reached — including the ones that answered, and the ones that did not.
  static String _devicesMessage(
    List<String> refused,
    List<String> applied,
    List<String> timedOut,
  ) {
    final total = refused.length + applied.length + timedOut.length;
    return [
      if (refused.isNotEmpty)
        '${refused.length} of $total device(s) refused it',
      if (timedOut.isNotEmpty)
        '${timedOut.length} of $total device(s) did not answer in time, so '
            'what they are running is unknown',
    ].join('; ');
  }
}

/// How to apply compiled output to running devices.
abstract interface class ReloadStrategy {
  /// Apply incremental changes (hot reload).
  Future<StrategyOutcome> applyReload(
    CompileResult result,
    List<DeviceSession> sessions,
  );

  /// Apply full restart.
  Future<StrategyOutcome> applyRestart(
    CompileResult result,
    List<DeviceSession> sessions,
  );

  /// Make the running app(s) show the rebuilt asset bundle.
  ///
  /// [changed] is the set of archive paths — bundle-relative and
  /// `/`-separated, the form the engine keys assets by — whose bytes differ
  /// from what the apps have cached. Never empty; the caller does not ask when
  /// nothing changed.
  ///
  /// Separate from [applyReload] because assets and Dart code travel by
  /// different routes on every platform, and an asset-only edit must not be
  /// made to look like a code reload. On a strategy that navigates the page,
  /// both routes happen to converge — that is a fact about that strategy, not
  /// about the pipeline.
  Future<StrategyOutcome> applyAssets(
    Set<String> changed,
    List<DeviceSession> sessions,
  );
}

/// Reload strategy for native platforms via Dart VM service.
///
/// Uploads the compiled dill to each device's devFS and triggers
/// `reloadSources` + `reassemble` (reload) or `hotRestart` (restart).
class VmServiceReloadStrategy implements ReloadStrategy {
  /// How long one device gets to answer before its connection is declared hung.
  ///
  /// The same budget and the same reason as `VmServiceAppInstance.rpcTimeout`,
  /// and not covered by `VmServiceClient.connectTimeout`: the calls that carry
  /// an apply — `ext.flutter.evict`, `ext.flutter.reassemble`,
  /// `_flutter.runInView` — are executed *by* the app's isolate. An app sitting
  /// on a breakpoint leaves them unanswered on a socket that is perfectly
  /// healthy, so nothing is disposed, nothing reconnects and no exception ever
  /// arrives. Only wall-clock time notices.
  final Duration rpcTimeout;

  VmServiceReloadStrategy({this.rpcTimeout = const Duration(seconds: 30)});

  /// The sessions that can actually be reloaded.
  ///
  /// Sessions without a VM service connection are not failures, but they are
  /// not successes either — they cannot receive anything. Separating them here
  /// is what stops an all-unreachable run reporting success.
  static List<DeviceSession> _reachable(List<DeviceSession> sessions) => [
    for (final s in sessions)
      if (s.vmClient != null) s,
  ]; // no client, no reload

  /// What one device did with an apply.
  ///
  /// [refused] covers an app that took the kernel and then threw as well as one
  /// that rejected it: this path keeps no per-app compiler baseline, so the
  /// distinction has nothing to change here, and the user is told about the
  /// error either way. [timedOut] is not one of those — it is the absence of an
  /// answer.
  ///
  /// The single place every verb gets its bound. One helper rather than three
  /// `.timeout` calls: a bound only some verbs have is the same hole in a
  /// smaller form.
  Future<_DeviceResult> _bounded(
    DeviceSession session,
    Future<ApplyVerdict> Function(VmServiceClient) apply,
  ) async {
    final client = session.vmClient!;
    final inner = apply(client);
    try {
      final verdict = await inner.timeout(rpcTimeout);
      return verdict is VerdictApplied
          ? _DeviceResult.applied
          : _DeviceResult.refused;
    } on TimeoutException {
      // Says in code what the deadline already decided: this RPC's answer, if
      // one ever comes, belongs to nobody. (`timeout` keeps a listener on the
      // source, so a late error was never going to surface as an unhandled one
      // — matching `VmServiceAppInstance.applyKernel` is the point.)
      inner.ignore();
      // The tool owns this connection, not the VM: dropping it leaves the app
      // running and untouched, and it is what lets the *next* command
      // reconnect instead of queueing behind a socket nothing is coming back
      // on. The reconnect rebuilds the devFS, which resets the engine's asset
      // directory with it.
      await client.forceDisconnect();
      return _DeviceResult.timedOut;
    }
  }

  /// [results] is in the same order as [reachable], so which app did what is
  /// known here and kept rather than counted.
  static StrategyOutcome _outcome(
    List<_DeviceResult> results,
    List<DeviceSession> reachable,
  ) {
    if (reachable.isEmpty) {
      return const StrategyUnsupported(
        'no device has a VM service connection — nothing received the edit',
      );
    }
    final refused = <String>[];
    final applied = <String>[];
    final timedOut = <String>[];
    for (var i = 0; i < reachable.length; i++) {
      final into = switch (results[i]) {
        _DeviceResult.applied => applied,
        _DeviceResult.refused => refused,
        _DeviceResult.timedOut => timedOut,
      };
      into.add(reachable[i].appId);
    }
    if (refused.isNotEmpty || timedOut.isNotEmpty) {
      return StrategyRejected.devices(
        refused: refused,
        applied: applied,
        timedOut: timedOut,
      );
    }
    return StrategyApplied(reachable.length);
  }

  /// Run [apply] on every reachable session, each under its own [rpcTimeout].
  Future<StrategyOutcome> _applyToAll(
    List<DeviceSession> sessions,
    Future<ApplyVerdict> Function(VmServiceClient) apply,
  ) async {
    final reachable = _reachable(sessions);
    final results = await Future.wait([
      for (final s in reachable) _bounded(s, apply),
    ]);
    return _outcome(results, reachable);
  }

  @override
  Future<StrategyOutcome> applyReload(
    CompileResult result,
    List<DeviceSession> sessions,
  ) => _applyToAll(sessions, (c) => c.hotReload(result.dillPath));

  @override
  Future<StrategyOutcome> applyRestart(
    CompileResult result,
    List<DeviceSession> sessions,
  ) => _applyToAll(sessions, (c) => c.hotRestart(result.dillPath));

  /// Assets go the same way kernels do: into the device's own devFS. No
  /// platform is special here — an APK, a phone, and a sandboxed macOS app all
  /// have a VM whose filesystem they can read, and that is the only thing this
  /// needs.
  @override
  Future<StrategyOutcome> applyAssets(
    Set<String> changed,
    List<DeviceSession> sessions,
  ) => _applyToAll(sessions, (c) => c.reloadAssets(changed));
}

/// What a single device did with one apply. See
/// [VmServiceReloadStrategy._bounded].
enum _DeviceResult { applied, refused, timedOut }

/// Reload strategy for web DDC via DWDS VM service protocol.
///
/// Uses DWDS's VM service for both operations, so neither navigates the page.
///
/// Flow for hot reload:
///   1. Update module server with new DDC output
///   2. DWDS VM service `reloadSources` → `$dartReloadModifiedModules` in browser
///   3. `ext.flutter.reassemble` → widget rebuild with preserved state
///
/// Flow for hot restart:
///   1. Update module server with new DDC output
///   2. DWDS's `hotRestart` service → `$dartHotRestartDwds` in the browser,
///      which swaps the new modules in and starts a fresh isolate
///
/// The page survives both. That is what separates this from
/// [WasmReloadStrategy], which navigates — upstream reserves `Page.reload` for
/// non-debug builds too (`resident_web_runner.dart:612-617`).
///
/// With one exception, and it is not a softening of that rule: a page that has
/// never been served a program has nothing to swap. See [loadFirstProgram].
class DwdsReloadStrategy implements ReloadStrategy {
  final WebModuleServer moduleServer;

  /// Navigate the page, so it fetches the program for the first time.
  ///
  /// Called whenever no browser has ever connected to this session — the
  /// window that exists because a failed *first* compile does not end the run,
  /// and Chrome is launched into it anyway. Upstream has no such window: a
  /// failed first compile returns before its browser is ever launched
  /// (`resident_web_runner.dart:334-339`, launch at :367).
  ///
  /// A navigation is the only thing that makes a page ask for the program;
  /// nothing else in this class can substitute for it. DWDS's `hotRestart`
  /// against a page in that window answers "Successful hot restart" and does
  /// nothing at all — `reloaded_sources.json` is empty by design on a first
  /// compile — while the page stays blank.
  ///
  /// Injected rather than reached for: the strategy is built before Chrome
  /// exists, so there is no debugging port to hold yet, and a callback keeps
  /// the branch testable without a browser.
  final Future<void> Function() loadFirstProgram;

  /// How long to wait for a `hotRestart` before giving up on it.
  ///
  /// Purely a hang-guard: DWDS awaits its new isolate's `IsolateStart` with no
  /// timeout of its own (`dwds_vm_client.dart:530`), so a page that never
  /// reports one would wedge the session for good. Not a latency budget — a
  /// restart that takes this long has gone wrong.
  final Duration restartTimeout;

  /// The DWDS VM service instance, or null before a browser has connected.
  ///
  /// (Re-)attached via [attachVmService] on every browser connection: a
  /// genuine page navigation (the user hitting reload, a crash) replaces the
  /// page's isolate and VM service, so the prior connection dies.
  vm.VmService? get vmService => _vmService;
  vm.VmService? _vmService;

  /// The main isolate ID from the DWDS VM service.
  String? _isolateId;

  /// Service name → the method name to actually call, as announced by
  /// `ServiceRegistered` events. See [_hotRestartMethod].
  final Map<String, String> _registeredServices = {};

  StreamSubscription<vm.Event>? _serviceSub;

  DwdsReloadStrategy({
    required this.moduleServer,
    required this.loadFirstProgram,
    this.restartTimeout = const Duration(seconds: 60),
  });

  /// Attach (or replace) the DWDS VM service after a browser (re)connection.
  ///
  /// Disposes any prior connection (dead after a navigation), clears the cached
  /// isolate id so the next reload re-discovers the new page's isolate, and
  /// re-subscribes to the `Service` stream to learn this connection's service
  /// names — registrations do not survive the connection that made them.
  Future<void> attachVmService(vm.VmService service) async {
    await _serviceSub?.cancel();
    unawaited(_vmService?.dispose());
    _vmService = service;
    _isolateId = null;
    _registeredServices.clear();
    // Listen before subscribing: DDS replays every existing registration when
    // a client subscribes to the stream (dds `stream_manager.dart:252-269`),
    // and those replayed events would otherwise land before we were looking.
    _serviceSub = service.onServiceEvent.listen(_onServiceEvent);
    await service.streamListen(vm.EventStreams.kService);
  }

  void _onServiceEvent(vm.Event event) {
    final service = event.service;
    if (service == null) return;
    switch (event.kind) {
      case vm.EventKind.kServiceRegistered:
        if (event.method case final method?) {
          _registeredServices[service] = method;
        }
      case vm.EventKind.kServiceUnregistered:
        _registeredServices.remove(service);
    }
  }

  /// The method name for DWDS's hot restart.
  ///
  /// DWDS registers it as a *client-provided* service named `hotRestart`
  /// (`dwds_vm_client.dart:333`). With DWDS owning the DDS, DDS exposes it to
  /// other clients under that client's namespace — `s0.hotRestart` — so the
  /// bare name gets `kMethodNotFound`. The registered name is therefore read
  /// off a `ServiceRegistered` event rather than assumed.
  ///
  /// The bare name is the correct name when nothing was registered: that is a
  /// DWDS with no DDS in front of it, not a degraded state.
  String get _hotRestartMethod =>
      _registeredServices['hotRestart'] ?? 'hotRestart';

  /// Discover the main isolate ID from the VM service.
  /// The client for the page this strategy drives, or null before a browser
  /// has connected.
  ///
  /// Reached through [sessions] rather than held as a field, the way
  /// [VmServiceReloadStrategy] already reaches its clients: the assembler
  /// hands this strategy the raw service extracted from that same client
  /// (`web_pipeline_assembler.dart`), so a second handle here would be the
  /// same connection under two names.
  VmServiceClient? _clientFor(List<DeviceSession> sessions) {
    for (final session in sessions) {
      final client = session.vmClient;
      if (client != null) return client;
    }
    return null;
  }

  Future<String?> _getIsolateId() async {
    if (_isolateId != null) return _isolateId;
    if (vmService == null) return null;
    final vmInfo = await vmService!.getVM();
    if (vmInfo.isolates != null && vmInfo.isolates!.isNotEmpty) {
      _isolateId = vmInfo.isolates!.first.id;
    }
    return _isolateId;
  }

  @override
  Future<StrategyOutcome> applyReload(
    CompileResult result,
    List<DeviceSession> sessions,
  ) async {
    // A page that has never held a program has nothing to inject into, and an
    // incremental compile has not produced one — so merging this result would
    // leave the server holding a fraction of a program and calling it the
    // first compile, after which every later reload builds on the lie.
    //
    // Unreachable through `ReloadPipeline.hotReload`, which routes a session
    // with no baseline to its restart arm precisely so the compile is a full
    // one. That routing is the fix; this is the guard that says so if it is
    // ever bypassed, rather than degrading quietly.
    if (!moduleServer.holdsProgram) {
      return const StrategyUnsupported(
        'the page has never loaded a program, so there is nothing to hot '
        'reload into — this needs a restart, which compiles the whole '
        'program and loads it',
      );
    }

    // Update modules — DDC writes incremental output to the same files.
    // A delta: only the recompiled modules are in it, and everything else the
    // page is running has to survive the merge.
    moduleServer.updateModules(result.dillPath, full: false);

    if (vmService == null) {
      // Not delegated to applyRestart for a CDP page reload: restart is a DWDS
      // call that needs the same connection, so the delegation would only
      // recurse into this check.
      return const StrategyUnsupported(_noClientYetMessage);
    }

    try {
      final isolateId = await _getIsolateId();
      if (isolateId == null) {
        return const StrategyUnsupported('no isolate found in the browser');
      }

      // Trigger DWDS hot reload: reloadSources → $dartReloadModifiedModules.
      final report = await vmService!.reloadSources(isolateId);
      if (report.success != true) {
        return const StrategyRejected('the browser refused the new sources');
      }

      // Trigger Flutter widget rebuild to pick up the new code. On the modern
      // DDC hot-reload path the `$dartReloadModifiedModules` invoked by
      // reloadSources above already rebuilds the tree, so this is the second
      // of two rather than the only one.
      try {
        await _clientFor(sessions)?.requireServiceExtension(
          'ext.flutter.reassemble',
        );
        await vmService!.callServiceExtension(
          'ext.flutter.reassemble',
          isolateId: isolateId,
        );
      } catch (e) {
        _warnReassembleFailed(e);
      }

      // Nothing here verifies what the page does after the apply. Native's
      // `VmServiceClient._applyAndVerify` subscribes to the Extension stream
      // before applying and waits for the first of `Flutter.Error` (live, and
      // the app is broken) or the next `Flutter.Frame` (rendered clean), so a
      // reload that lands and then throws still reports success here while the
      // page shows a red screen.
      //
      // The obvious port would be worse than the hole. DWDS does carry the
      // stream — `postEvent` reaches it through the injected client's
      // `$emitDebugEvent`, and `Flutter.Frame` is posted by the framework in
      // any non-release build — but `Flutter.Error` is not:
      // `WidgetInspectorService.isStructuredErrorsEnabled` reads
      // `flutter.inspector.structuredErrors` with `defaultValue: !kIsWeb`
      // (widget_inspector.dart), so on web the framework posts none by
      // default. A frame still renders — of `ErrorWidget` — so waiting for the
      // same two events would return a confident success for exactly the case
      // this is meant to catch. Enabling
      // `ext.flutter.inspector.structuredErrors` over the DWDS VM service once
      // the browser connects would change that, and reroutes the page's error
      // presentation with it.
      return const StrategyApplied(1);
    } catch (e) {
      return StrategyRejected('DWDS hot reload failed: $e');
    }
  }

  @override
  Future<StrategyOutcome> applyRestart(
    CompileResult result,
    List<DeviceSession> sessions,
  ) async {
    // Whether a page has ever reached this session's program — NOT whether
    // the server holds one. The two differ for exactly as long as a
    // navigation takes, and a navigation can fail: a closed tab is enough,
    // since the page target is matched by URL. Discriminating on the server's
    // state would make every restart after a failed navigation believe the
    // page already had a program, take the DWDS path and never navigate again,
    // leaving the session blank for good.
    //
    // `_vmService` is the page's own signal — set only by [attachVmService]
    // on a browser connection, and never cleared — which is upstream's
    // discriminator too (`_connectionResult == null`,
    // `resident_web_runner.dart:516`). It is a sound proxy for "the page has
    // a program" only because [WebModuleServer] withholds the boot chain
    // until it holds one: no boot chain, no injected DWDS client, no
    // connection. Both halves have to stay true together.
    //
    // The merge runs first either way, and must: the navigation below is what
    // makes the page fetch, so the program has to be on the server before it.
    final needsFirstLoad = _vmService == null;
    // Full: a restart drives the compiler with `reset` + `recompile`, so this
    // dill carries the whole program rather than a delta against what the
    // page is running.
    moduleServer.updateModules(result.dillPath, full: true);

    if (needsFirstLoad) {
      // Not a hot restart, and reported as one it would be a lie the page
      // contradicts — see [loadFirstProgram]. The
      // navigation drops the connection DWDS has; the assembler's
      // `connectedApps` listener re-wires the VM service, the session and the
      // log forwarder on the reconnection, which is what it already does for a
      // user pressing reload.
      try {
        await loadFirstProgram();
      } catch (e) {
        return StrategyRejected(
          'the page had no program yet and could not be loaded: $e',
        );
      }
      // Stale by construction: the isolate this named belongs to the page that
      // has just been navigated away from.
      _isolateId = null;
      return const StrategyApplied(1);
    }

    // Non-null by construction: `needsFirstLoad` above returned when it was
    // not, and [attachVmService] never puts it back. A page that connected
    // and then vanished still reads as connected here and takes this path —
    // that gap is tracked separately, and closing it needs the connection's
    // lifetime, not another null check.
    final service = _vmService!;

    try {
      await service.callMethod(_hotRestartMethod).timeout(restartTimeout);
    } on TimeoutException {
      return StrategyRejected(
        'the browser did not report a restarted isolate '
        'within ${restartTimeout.inSeconds}s',
      );
    } on vm.RPCError catch (e) {
      if (e.code == _rpcIsolateCannotReload || e.code == _rpcServerError) {
        // Reached only with a VM service in hand, so a browser did connect
        // once — DWDS is saying it has no client now, not that none ever came.
        return const StrategyUnsupported(_clientGoneMessage);
      }
      return StrategyRejected(e.message);
    }

    // Load-bearing. DWDS swapped the code into the live page, so there is no
    // navigation, no browser reconnect, and no attachVmService call — the only
    // other place this is cleared. Left set, it names the isolate DWDS just
    // replaced and the next hot reload calls reloadSources on a dead one.
    _isolateId = null;
    return const StrategyApplied(1);
  }

  @override
  Future<StrategyOutcome> applyAssets(
    Set<String> changed,
    List<DeviceSession> sessions,
  ) async {
    // Nothing to deliver: the module server reads `assets/` off the build tree
    // on every request, so the new bytes are already on the wire. All that is
    // left is convincing the page to ask again — the framework caches every
    // asset it has loaded, and images twice over in the image cache.
    if (vmService == null) {
      return const StrategyUnsupported(_noClientYetMessage);
    }
    // A page with no program has no framework to hold a cache, so there is
    // nothing to evict and nothing that could be showing the old bytes. Said
    // rather than attempted: DWDS answers for an isolate here whether or not
    // any Dart ran in it, so the eviction below would report a success about a
    // page that is not displaying anything at all.
    if (!moduleServer.holdsProgram) {
      return const StrategyUnsupported(
        'the page has never loaded a program, so it is not showing these '
        'assets — it will fetch them when it loads',
      );
    }

    // A font family the engine has already registered is not re-read by
    // dropping the framework's copy of the bytes, and the web engine has no
    // equivalent of `_flutter.reloadAssetFonts` to ask it to. A restart
    // re-runs the binding's font registration, which does.
    if (touchesFonts(changed)) {
      return const StrategyUnsupported(
        'the web engine registers fonts once at startup and has no reload '
        'hook — hot restart (R) to pick up the new fonts',
      );
    }

    try {
      final isolateId = await _getIsolateId();
      if (isolateId == null) {
        return const StrategyUnsupported('no isolate found in the browser');
      }
      final client = _clientFor(sessions);
      await client?.requireServiceExtension('ext.flutter.evict');
      for (final archivePath in changed) {
        await vmService!.callServiceExtension(
          'ext.flutter.evict',
          isolateId: isolateId,
          args: {'value': archivePath},
        );
      }
      // Evicting only empties caches. Something has to rebuild for the widgets
      // holding the old bytes to ask for them again.
      await client?.requireServiceExtension('ext.flutter.reassemble');
      await vmService!.callServiceExtension(
        'ext.flutter.reassemble',
        isolateId: isolateId,
      );
      return const StrategyApplied(1);
    } on ServiceExtensionUnavailable catch (e) {
      // Said plainly rather than reported as success: the files are served,
      // but this page is still painting from its caches.
      return StrategyUnsupported(
        '$e — hot restart (R) to reload assets',
      );
    } on vm.RPCError catch (e) {
      return StrategyRejected(
        'evicting the changed assets failed: ${e.message}',
      );
    } catch (e) {
      return StrategyRejected('evicting the changed assets failed: $e');
    }
  }
}

/// Report a `ext.flutter.reassemble` the page would not run.
///
/// The new modules are already loaded, so this is not a lost edit — only a
/// tree that may not have rebuilt to show it yet.
void _warnReassembleFailed(Object error) => _logger.warning({
  'message': 'reassemble_failed',
  'text':
      'The browser loaded the new modules but would not rebuild its '
      'widget tree (ext.flutter.reassemble failed: $error). The page may '
      'keep showing the old UI until something else rebuilds it.',
  'error': '$error',
});

/// Reload strategy for WASM web via bazel rebuild + CDP Page.reload.
///
/// WASM has no frontend server and no DWDS — hot restart means:
///   1. Re-run `bazel build` to recompile the WASM binary
///   2. CDP `Page.reload` to pick up the new files
class WasmReloadStrategy implements ReloadStrategy {
  final int cdpPort;
  final String? appUrl;

  /// Callback to rebuild via bazel. Returns true on success.
  final Future<bool> Function() rebuild;

  WasmReloadStrategy({
    required this.cdpPort,
    required this.rebuild,
    this.appUrl,
  });

  @override
  Future<StrategyOutcome> applyReload(
    CompileResult result,
    List<DeviceSession> sessions,
  ) async {
    // dart2wasm has no incremental reload, so this is a rebuild and a page
    // reload. It gets the edit running, but state is lost — reporting it as a
    // hot reload would misdescribe what the user just got.
    final restarted = await applyRestart(result, sessions);
    if (restarted.isSuccess) {
      return const StrategyUnsupported(
        'WASM has no hot reload — rebuilt and reloaded the page instead',
      );
    }
    return restarted;
  }

  @override
  Future<StrategyOutcome> applyRestart(
    CompileResult result,
    List<DeviceSession> sessions,
  ) => _rebuildAndReload();

  /// Assets ride along with everything else: the rebuild refreshes the served
  /// bundle and the navigation re-fetches it, so this is a restart under
  /// another name. Shared with [applyRestart] rather than delegating through
  /// it — there is no [CompileResult] to hand over, and inventing one to
  /// satisfy a parameter nothing reads would be a lie in the type.
  @override
  Future<StrategyOutcome> applyAssets(
    Set<String> changed,
    List<DeviceSession> sessions,
  ) => _rebuildAndReload();

  Future<StrategyOutcome> _rebuildAndReload() async {
    try {
      final buildOk = await rebuild();
      if (!buildOk) {
        return const StrategyRejected('the WASM rebuild failed');
      }
      await cdpPageReload(cdpPort, appUrl: appUrl);
      return const StrategyApplied(1);
    } catch (e) {
      return StrategyRejected('WASM hot restart failed: $e');
    }
  }
}

/// Send Page.reload via Chrome DevTools Protocol.
///
/// The target is chosen by [resolveCdpPageTarget] — the same picker the console
/// forwarder uses. It throws a single StateError naming the port and app URL:
/// "no targets at all" and "the chosen target has no debugger URL" mean the
/// same thing to the caller, which reports them identically as a rejected
/// reload.
Future<void> cdpPageReload(int cdpPort, {String? appUrl}) async {
  final ws = await WebSocket.connect(
    await resolveCdpPageTarget(cdpPort, appUrl: appUrl),
  );
  final responseCompleter = Completer<Map<String, dynamic>>();

  ws.listen((data) {
    final msg = json.decode(data as String) as Map<String, dynamic>;
    if (msg['id'] == 1 && !responseCompleter.isCompleted) {
      responseCompleter.complete(msg);
    }
  });

  ws.add(
    json.encode({
      'id': 1,
      'method': 'Page.reload',
      'params': {'ignoreCache': true},
    }),
  );

  try {
    await responseCompleter.future.timeout(const Duration(seconds: 10));
  } finally {
    await ws.close();
  }
}
