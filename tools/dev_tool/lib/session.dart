/// Per-device session state and shared interactive session loop.
///
/// A [DeviceSession] holds the runtime state for one device: the launched
/// app instance, VM service client, and optional DevTools URL. The shared
/// [runInteractiveSession] function drives the file watcher, keyboard
/// loop, and hot reload across all active sessions.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dds/dds.dart';

import 'command_report.dart';
import 'command_runner.dart';
import 'device.dart';
import 'frontend_server.dart';
import 'hot_reload/package_uri_resolver.dart';
import 'hot_reload/readiness_gate.dart';
import 'hot_reload/source_watcher.dart';
import 'logging.dart';
import 'machine_protocol.dart';
import 'reload_strategy.dart';
import 'teardown.dart';
import 'vm_service_client.dart';

final _logger = Logger('dev_tool.session');

/// Runtime state for a single device in a multi-device run.
class DeviceSession {
  final Device device;

  /// The app process this session currently owns.
  ///
  /// Not fixed for the life of the session: a restart that finds changed
  /// native libraries relaunches the process (see [relaunch]), replacing the
  /// instance and its VM service connection.
  AppInstance get appInstance => _appInstance;
  AppInstance _appInstance;

  VmServiceClient? vmClient;
  final String appId;
  String? devToolsUrl;
  Process? devToolsProcess;

  /// The Dart Development Service **we** started on the app's raw VM service.
  /// Our [vmClient] and DevTools both connect through it (DDS multiplexes), so
  /// they do not evict each other.
  ///
  /// Always null on web. A DDS does exist there, but DWDS owns it: the session
  /// only ever receives what DWDS hands over on a debug connection — the VM
  /// service URI [vmClient] dials, and [devToolsUrl]. Code that needs "the DDS
  /// this session's DevTools comes from" must therefore handle null, not
  /// assume debug-ready implies a DDS of our own.
  ///
  /// Mutable because a session can be re-wired: a native relaunch and a web
  /// page reload both replace the debug connection.
  DartDevelopmentService? dds;

  final Completer<void> _debugReady = Completer<void>();

  /// Completes once this session has a working debug connection.
  ///
  /// Native devices are debug-ready the moment the session exists — [vmClient]
  /// and [dds] are both populated by then. Web is not: DWDS only hands over a
  /// debug connection when the browser connects, which is after the session is
  /// constructed and `app.started` has been emitted, and what it hands over is
  /// a [vmClient] and a [devToolsUrl] rather than a [dds]. Consumers that need
  /// the VM service — DevTools, chiefly — wait on this instead of sampling the
  /// fields once and finding them null on web.
  Future<void> get debugReady => _debugReady.future;

  /// Idempotent: a web hot restart re-runs the connect path.
  void markDebugReady() {
    if (!_debugReady.isCompleted) _debugReady.complete();
  }

  /// Whether an `ext.rules_flutter.*` command issued now will land.
  ///
  /// Deliberately not [debugReady], which answers a different question and is
  /// answered earlier. A debug connection existing means the VM service dialed
  /// and replied; it says nothing about whether the app has built a widget
  /// tree. Between those two facts a command has nothing to act on: it either
  /// finds no widget and reports a timeout that reads like a broken app, or —
  /// on a physical device — is not answered at all.
  ///
  /// On a physical iPhone the VM service answers `getVersion` shortly after
  /// `app.started` and then answers *nothing* — no VM call, no isolate
  /// extension, not on a freshly opened socket — until `Flutter.FirstFrame`
  /// arrives about a minute later, after which every call takes tens of
  /// milliseconds. On Android the same gap is around ten seconds and shows up
  /// as a first `app.waitFor` answering `timed out waiting for type AppBar`
  /// for an app that was simply not built yet.
  ///
  /// This is what the README promises: "a command issued in that window waits
  /// it out rather than failing".
  ///
  /// [debugReady] stays where it is because DevTools waits on it, and DevTools
  /// has no reason to sit out the app's first minute.
  final ReadinessGate drivable = ReadinessGate();

  /// Completed by [stopWaitingForFirstFrame].
  final Completer<void> _stopDrivableWait = Completer<void>();

  /// Give up on the first frame, because the run is ending.
  ///
  /// The wait below sits on a timer sized in minutes for a physical device, and
  /// a pending timer keeps the Dart process alive: without this, `app.stop` and
  /// `daemon.shutdown` are answered and the tool stays up until the budget
  /// expires. Registered in the same teardown that stops everything else the
  /// run owns.
  void stopWaitingForFirstFrame() {
    if (!_stopDrivableWait.isCompleted) _stopDrivableWait.complete();
  }

  /// Settle [drivable], reporting the wait as `app.progress` while it lasts.
  ///
  /// Always settles: ready when the app paints, unavailable with a reason when
  /// it does not, so a command waiting on the gate is never left holding a
  /// signal that is not coming.
  ///
  /// A settlement is for the run. An app that misses this budget has not been
  /// slow, it has failed to start — the budget is minutes, and a healthy start
  /// on the slowest platform here is one — so the answer does not get better
  /// by being asked again, and every command says the same thing rather than
  /// each one spending the budget over.
  ///
  /// Bounded by [Device.applyTimeout] — the same budget that governs a hot
  /// restart there, for the same reason. A restart re-runs `main()`, which is
  /// the work being waited on here, and the platform note on the iOS override
  /// is what both are sized against.
  Future<void> waitUntilDrivable(MachineProtocol protocol) async {
    final client = vmClient;
    if (client == null) {
      // Left unsettled rather than refused, because "no client yet" is the
      // normal web case, not a failure: a browser's VM service is handed over
      // by DWDS seconds after the session exists, and the handover signals
      // this gate itself. Settling it here would refuse every later command on
      // the strength of a field that was always going to be null at this
      // moment — a gate, once settled, stays settled.
      //
      // Native reaching here means the run has no VM service at all
      // (`--allow-no-vm-service`, or a DDS that would not start). Nothing waits
      // on the gate in that case: a command finds `vmClient` null and says so
      // before it ever gets here.
      return;
    }

    const message = 'Waiting for the app to render its first frame';
    final progressId = 'first_frame_$appId';
    protocol.appProgress(appId, message, progressId: progressId);

    // Nothing here may throw: callers start this and walk away, so a throw
    // would leave the gate unsettled and every command waiting on it hanging
    // for good. A failure becomes the gate's reason instead, which is where a
    // refused command reads it from.
    var rendered = false;
    String? failure;
    // Measured, because the wait does not always reach its bound: `until`
    // abandons it when the run ends, and a failed query returns early.
    // Reporting the full `applyTimeout` for either would send a reader looking
    // for a thirty-second hang that had not happened.
    final waited = Stopwatch()..start();
    try {
      rendered = await client.waitForFirstFrame(
        timeout: device.applyTimeout,
        until: _stopDrivableWait.future,
      );
    } catch (e) {
      failure = '$e';
    }
    waited.stop();

    protocol.appProgress(
      appId,
      message,
      progressId: progressId,
      finished: true,
    );

    if (rendered) {
      drivable.signalReady();
      return;
    }

    if (_stopDrivableWait.isCompleted) {
      drivable.signalUnavailable('the run ended before $appId rendered');
      return;
    }

    // Logged as well as gated. The gate's reason reaches a machine-protocol
    // client through the command it refuses, but a terminal run issues no
    // commands and would otherwise show nothing at all for an app that never
    // came up.
    _logger.warning({
      'message': 'first_frame_not_rendered',
      'text':
          'The app on ${device.name} did not render a frame within '
          '${waited.elapsed.inSeconds}s. Commands that drive it are '
          'refused for the rest of this run; start it again once the app '
          'comes up.',
      'device': device.name,
      'appId': appId,
    });
    drivable.signalUnavailable(
      failure != null
          ? 'could not tell whether $appId on ${device.name} has rendered: '
                '$failure'
          : '$appId on ${device.name} had not rendered a frame after '
                '${waited.elapsed.inSeconds}s, so the Flutter framework '
                'is not up and its service extensions are not registered. The '
                'app is either still starting or stuck before its first build.',
    );
  }

  /// How many times this session's app has been launched: 1 for the original
  /// launch, one more for every [relaunch].
  ///
  /// Each [AppInstance] carries its own log buffer, numbered from zero, so a
  /// `/logs` cursor only means anything within one launch. This counter is
  /// what tells a poller its cursor belongs to a process that is gone.
  int get launch => _launch;
  int _launch = 1;

  final Completer<void> _terminated = Completer<void>();

  /// Whether [shutdown] has already run. See there.
  bool _shutDown = false;

  /// True only for the window inside [relaunch] where the outgoing process has
  /// been killed and its replacement has not arrived yet.
  bool _relaunching = false;

  /// Completes when this session's app is gone for good.
  ///
  /// Deliberately not `appInstance.process.exitCode`: [relaunch] kills the
  /// running process on purpose to install a replacement, and that exit does
  /// not end the session. A caller that watches the process directly sees a
  /// relaunch as a dead app and tears the run's transports down — the HTTP
  /// control channel included — while the relaunched app is alive and
  /// answering.
  Future<void> get terminated => _terminated.future;

  DeviceSession({
    required this.device,
    required AppInstance appInstance,
    required this.vmClient,
    required this.appId,
    this.dds,
  }) : _appInstance = appInstance {
    if (vmClient != null && dds != null) markDebugReady();
    _watchForExit(appInstance);
  }

  /// Tear this session down: end DevTools, tell the client the app is going,
  /// let go of the VM service and the DDS, and stop the app itself.
  ///
  /// One method rather than two copies, for the launcher's teardown entry and
  /// the interactive `q` alike, and one deadline on `dds.shutdown()`: DDS
  /// closes its socket to the app's VM service on the way out, and what is on
  /// the far end of that socket is not ours to trust.
  /// Stop this app and release what the session holds for it.
  ///
  /// Idempotent, because it has two callers: an `app.stop` naming this
  /// app, and the run's own teardown, which owns a disposer for every session
  /// it launched and cannot know one of them was already stopped by hand.
  Future<void> shutdown(MachineProtocol protocol) async {
    if (_shutDown) return;
    _shutDown = true;
    stopWaitingForFirstFrame();
    devToolsProcess?.kill();
    protocol.appStop(appId);
    // Retired, not merely disconnected: this session is over, and a client
    // that could still be dialled would be — an RPC in flight when this lands
    // re-dials on its way back and publishes a socket nothing owns. See
    // [VmServiceClient.retire].
    await vmClient?.retire();
    await boundedTeardownStep(
      'the DDS to shut down',
      dds?.shutdown() ?? Future.value(),
      device.teardownBound,
    );
    // Read through the session, not a local: a restart that relaunches the app
    // replaces the instance, and stopping the one a caller saw earlier would
    // leave the live one running.
    await device.stop(appInstance);
  }

  void _watchForExit(AppInstance instance) {
    unawaited(
      instance.process.exitCode.then((_) {
        // Ignore the exit of a process this session no longer owns, and the
        // exit of the one currently being replaced.
        if (_relaunching || !identical(instance, _appInstance)) return;
        _markTerminated();
      }),
    );
  }

  void _markTerminated() {
    if (!_terminated.isCompleted) _terminated.complete();
  }

  /// Replace the running app process with a freshly launched one.
  ///
  /// [launchReplacement] owns the entire swap — stopping the outgoing process
  /// and starting its replacement — because the window between the two is
  /// exactly what must not read as the session ending. If it throws, the
  /// session really is over: the old process is gone and nothing replaced it,
  /// so [terminated] completes.
  Future<void> relaunch(
    Future<AppInstance> Function() launchReplacement,
  ) async {
    _relaunching = true;
    try {
      _appInstance = await launchReplacement();
      _launch++;
      _watchForExit(_appInstance);
    } catch (_) {
      _markTerminated();
      rethrow;
    } finally {
      _relaunching = false;
    }
  }
}

/// Result of a compile + reload/restart operation.
class ReloadResult {
  /// Whether the compile step succeeded.
  final bool compileSuccess;

  /// What applying the compiled output achieved. Null when the compile failed
  /// and nothing was applied.
  final StrategyOutcome? outcome;

  final String diagnostics;
  final int elapsedMs;

  /// Whether every device that could take the edit took it.
  ///
  /// A run where no device could take it is not a success: `outcome` is
  /// [StrategyUnsupported] and nothing is live.
  bool get deviceSuccess => outcome?.isSuccess ?? false;

  /// Overall success: both compile and device steps succeeded.
  bool get success => compileSuccess && deviceSuccess;

  ReloadResult({
    required this.compileSuccess,
    this.outcome,
    this.diagnostics = '',
    required this.elapsedMs,
  });
}

/// Incrementally recompile and hot reload all devices.
///
/// Calls [FrontendServer.recompile] with the given [invalidatedFiles], then
/// applies the result via [reloadStrategy]. On compile failure, calls [reject]
/// so the frontend server stays in a clean state.
///
/// [reloadStrategy] is required, and deliberately has no default. A fallback to
/// [VmServiceReloadStrategy] — the *native* strategy — would send a web session
/// whose DWDS setup had failed looking for a VM service connection the browser
/// never has, and blame the VM service for the absence. Which strategy applies
/// is a fact about the platform, known only to the caller.
Future<ReloadResult> recompileAndReload({
  required FrontendServer frontendServer,
  required String entrypoint,
  required List<String> invalidatedFiles,
  required List<DeviceSession> sessions,
  required ReloadStrategy reloadStrategy,
}) => _compileAndApply(
  frontendServer: frontendServer,
  compile: () => frontendServer.recompile(entrypoint, invalidatedFiles),
  apply: (result) => reloadStrategy.applyReload(result, sessions),
);

/// Full recompile and hot restart all devices.
///
/// `reset` + `recompile`, never a second `compile` — the same pairing
/// `FrontendServerCompiler.compileFull` uses for a native restart, and the one
/// `flutter_tools` drives every restart through (`devfs.dart`). The reset is
/// what makes the answer a whole program instead of a delta.
///
/// The verb matters because **the `compile` verb's error count is cumulative**
/// and only `recompile` clears it: a restart of a broken tree answers with the
/// compiler's diagnostics, and a second `compile` — of a tree that has been
/// *fixed* on disk — answers "Compilation failed" with no diagnostics at all,
/// with every later restart in that session owed the same phantom. See
/// [FrontendServer.recompile].
///
/// [invalidatedFiles] does not decide what is compiled — a reset re-reads the
/// tree regardless — but the compiler takes the reset and the invalidation on
/// one request, and it keeps per-file state that has to be told the same thing
/// an incremental compile would tell it.
///
/// [reloadStrategy] is required for the same reason as in
/// [recompileAndReload]: there is no strategy that is right by default.
Future<ReloadResult> recompileAndRestart({
  required FrontendServer frontendServer,
  required String entrypoint,
  required List<String> invalidatedFiles,
  required List<DeviceSession> sessions,
  required ReloadStrategy reloadStrategy,
}) => _compileAndApply(
  frontendServer: frontendServer,
  compile: () =>
      frontendServer.recompile(entrypoint, invalidatedFiles, resetFirst: true),
  apply: (result) => reloadStrategy.applyRestart(result, sessions),
);

/// Compile, then apply — as two phases that fail separately.
///
/// One body for both verbs: they differ only in which compile they ask for and
/// which apply they run. A single `try` spanning the whole command would report
/// whichever half threw as `compileSuccess: false`, so a strategy that fell
/// over would read as "Compilation failed" — a claim about source the compiler
/// had just accepted, sending the user to look at the one place that was fine.
///
/// The phases own different failures. [compile] failing — with errors, or by
/// throwing — is a compile failure and reaches no device. Everything after
/// `accept()` is delivery: a throw there becomes a [StrategyThrew] outcome, so
/// the report names the half that actually broke. `accept()` and `reject()`
/// stay in the compile phase because nothing has touched an app when they run;
/// they are the compiler's own state.
Future<ReloadResult> _compileAndApply({
  required FrontendServer frontendServer,
  required Future<CompileResult> Function() compile,
  required Future<StrategyOutcome> Function(CompileResult) apply,
}) async {
  final stopwatch = Stopwatch()..start();
  ReloadResult compileFailed(String diagnostics) {
    stopwatch.stop();
    return ReloadResult(
      compileSuccess: false,
      diagnostics: diagnostics,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }

  final CompileResult compiled;
  try {
    final result = await compile();
    if (!result.success) {
      // A completed compile owes a verdict whether or not it succeeded, and a
      // full compile no less than an incremental one — the compiler sets its
      // awaiting-verdict state from the result line either way. Returning
      // without one leaves it holding a delta nobody refused. Awaited because
      // reject is the one verdict the compiler answers, and the answer has to
      // be read before the next compile writes over it.
      await frontendServer.reject();
      return compileFailed(result.diagnostics);
    }
    frontendServer.accept();
    compiled = result;
  } catch (e) {
    return compileFailed(e.toString());
  }

  StrategyOutcome outcome;
  try {
    outcome = await apply(compiled);
  } catch (e) {
    outcome = StrategyThrew(e);
  }
  stopwatch.stop();
  return ReloadResult(
    compileSuccess: true,
    outcome: outcome,
    elapsedMs: stopwatch.elapsedMilliseconds,
  );
}

/// Report the result of a reload **nobody requested** — a keypress, or an edit
/// the watcher picked up.
///
/// The HTTP control channel hands this map back to its caller; the interactive
/// session has no caller to hand it to, so it reports here instead. Pressing
/// "r" would otherwise print nothing whether the edit went live, was refused,
/// or reached no device at all, and a silent success and a silent failure are
/// indistinguishable.
///
/// Two audiences, as everywhere else in this codebase: [log] gets a sentence,
/// and [announce] gets the map. A requested reload answers its caller with
/// that same map in a JSON-RPC response; one that nobody requested has no
/// response to travel in, so it travels as an event instead. Without it a
/// client watching the protocol could only parse English — and could not tell
/// a reload that failed from a watcher that had died, since both are silence.
///
/// [method] is the command this is the outcome of (`app.hotReload`,
/// `app.restart`) — the same name a client would have invoked to ask for it,
/// which is what makes the event and the response two shapes of one thing.
void reportReloadCommand(
  String action,
  Map<String, dynamic> result,
  void Function(String message) log, {
  required String method,
  required void Function(Map<String, dynamic> params) announce,
}) {
  // Before the success/failure split, and never inside one arm: a failure is
  // when a client needs this most, and an event that only fired on success
  // would be indistinguishable from no reload at all.
  announce({'method': method, 'result': result});

  if (result['error'] case final error?) {
    _logger.severe({
      'message': 'reload_command_failed',
      'text': '$action failed: $error.${_keptItsOldCode(result)}',
      'action': action,
      'error': '$error',
    });
    return;
  }
  final message = result['message'] ?? '$action complete';
  // `isEmpty` is a verdict on the Dart half alone, and the suffix exists to
  // explain a bare "successful" that would otherwise look like something
  // happened. When `toWire` has already finished the sentence with an asset
  // clause, it has explained itself — and appending this anyway would produce
  // "2 asset(s) reloaded (no changes)", which contradicts the half-sentence
  // in front of it. Gated on `assetsChanged`, which `toWire` sets for both
  // arms that add a clause (a count, or 0 for a rebuild that came back
  // identical) and omits entirely when it adds none — so this asks the map
  // whether a clause is there rather than reading the prose for one.
  if (result['isEmpty'] == true && !result.containsKey('assetsChanged')) {
    log('$message (no changes)');
    return;
  }
  final files = result['filesRecompiled'];
  if (files is List && files.isNotEmpty) {
    log('$message (${files.length} file(s))');
    return;
  }
  log('$message');
}

/// The reassurance, for the failures that have earned it, and nothing at all
/// for the rest.
///
/// Asserted after every failure alike, it would tell a native apply that timed
/// out both that what it is running is unknown and that it kept its old code
/// (see [RunningCode.unknown]), and would tell an `ApplyFailed` the same with
/// the new code already in the VM. The map carries which of the three it is, so
/// the claim is made only where it is true.
///
/// A map without the key says nothing — the honest reading of a result that
/// never answered the question. Silence costs a reader the reassurance; the
/// alternative default costs them the truth.
String _keptItsOldCode(Map<String, dynamic> result) =>
    result['runningCode'] == RunningCode.unchanged.name
    ? ' The app keeps running the code it already had.'
    : '';

/// Signature for reading keyboard input (allows test injection).
typedef KeyboardReader = Stream<List<int>> Function();

/// Run the shared interactive session loop for one or more device sessions.
///
/// Handles file watching, keyboard input, and broadcasting hot reload/restart
/// across all sessions. Returns when the user quits or all sessions end.
///
/// When [hotReloadUnavailable] is non-null, hot reload ('r') and the [watcher]
/// that drives it are inert, but DevTools, perf overlay, inspector, and quit
/// still work.
Future<void> runInteractiveSession({
  required List<DeviceSession> sessions,
  required FrontendServer? frontendServer,
  required MachineProtocol protocol,

  /// The dispatcher every transport shares. Required, and the keyboard
  /// dispatches through it unconditionally: both reload commands are
  /// registered before this loop can be reached, so a runner without them is
  /// not a state to degrade gracefully into — [CommandRunner.run] throwing
  /// 'Unknown command' is the honest answer to a broken invariant, and a
  /// keypress is where such a throw is actually visible. The watcher below
  /// still asks first, for the reason given there: the same throw inside a
  /// stream listener is an unhandled async error nobody sees.
  required CommandRunner commandRunner,
  required bool devToolsEnabled,

  /// Dart binary from the Flutter toolchain, used to serve DevTools. Required
  /// even when [devToolsEnabled] is false so the caller resolves it once,
  /// rather than each launch site re-deriving it.
  required String dartExecutable,

  /// Why this run will not hot reload, or null when it intends to.
  ///
  /// What the banner is written from, and nothing else — the keys dispatch
  /// unconditionally and the readiness gate answers them, so this is not a
  /// second place the question is decided. Both this and the gate's reason
  /// come from the one `RunPlan.hotReloadOff`.
  ///
  /// Required, and deliberately without a default: a call site that cannot omit
  /// it cannot forget it. Left defaulted, `--no-hot` reaches the watcher and the
  /// protocol's `supportsRestart` and stops there, because the run's main call
  /// site simply omits this and takes `true`.
  ///
  /// A reason rather than a bool so the banner can say why the keys are gone.
  /// Their absence is only informative to someone who knew to expect them.
  required String? hotReloadUnavailable,

  /// A filesystem watcher the caller has already started, or null when this
  /// run does not watch.
  ///
  /// Started by the caller and not here on purpose. A watcher created at this
  /// point — after the app has launched and, on native, after the compiler's
  /// first full compile — reports nothing until its initial scan finishes, so
  /// every edit made in that window is dropped with no reload and no message.
  /// Starting it before launch makes `app.started` mean what a client assumes
  /// it means: edit now and the run will see it.
  SourceWatcher? watcher,

  /// The live resolver, asked per event rather than captured.
  ///
  /// It is built during assembly, which runs after this loop's caller has
  /// already wired the watcher, and it can arrive *later still* — a pipeline
  /// whose build failed assembles on a subsequent reload. A captured value
  /// would stay null in that case, so every save after the recovery maps to no
  /// package and the watcher goes on silently doing nothing.
  PackageUriResolver? Function()? resolver,

  /// Whether the pipeline still owes an assembly attempt.
  ///
  /// The one case where a watched Dart file is worth a reload request even
  /// though it maps to nothing: with no [resolver] yet, every path resolves to
  /// null, including the path of the file whose fix is what the pending attempt
  /// is waiting for. Asked rather than assumed from a null resolver, so the
  /// runs that will never assemble — a device with no compiler, an app that
  /// died — do not answer every save with a refusal.
  bool Function()? awaitingAssembly,

  /// Whether a watched path feeds the asset bundle rather than the Dart
  /// program.
  ///
  /// Needed because the two are told apart by different authorities: a `.dart`
  /// file only matters if [resolver] maps it to a package the app compiles,
  /// while an asset matters because the last build put it in the bundle.
  /// Without this an asset-only edit reaches the reload handler, resolves to
  /// no package URI, and is dropped one line before the pipeline that would
  /// have delivered it.
  PathFilter? isAsset,
  void Function(String message)? log,
  KeyboardReader? keyboardReader,
  void Function(bool echoMode)? setEchoMode,
  void Function(bool lineMode)? setLineMode,
  Future<void>? shutdownSignal,
}) async {
  // In `--machine` mode stdout IS the JSON-RPC stream, so a human-facing line
  // written there lands in the middle of what an editor is parsing. The
  log ??= protocol.enabled
      // `report` as well as `text`: the JSON log format strips `text` as
      // human-only, which would otherwise leave every one of these records in
      // machine mode with no payload at all — a line that says only that
      // something was reported.
      ? (msg) => _logger.info({
          'message': 'session_report',
          'text': msg,
          'report': msg,
        })
      : (msg) => stdout.writeln(msg);

  // The machine-readable half of the same report. A no-op outside `--machine`
  // mode, like every other event — the terminal reader has [log].
  void announce(Map<String, dynamic> params) =>
      protocol.sendEvent('app.reloadResult', params);

  // Launch DevTools once each session can serve it. Native is ready
  // immediately; web resolves when the browser connects, so this is wired as a
  // continuation rather than a check — waiting here would block the terminal
  // until a page loads, and checking now would always miss web.
  if (devToolsEnabled) {
    final logDevTools = log;
    for (final session in sessions) {
      unawaited(
        session.debugReady.then((_) async {
          try {
            // Web arrives with a URL already: DWDS runs the DDS that serves
            // DevTools, and hands it over on the debug connection. Native owns
            // its DDS but not a DevTools server, so it spawns one and points it
            // at the DDS endpoint — never at the raw VM service, because DDS
            // multiplexing is what stops DevTools evicting our own vmClient.
            var url = session.devToolsUrl;
            if (url == null) {
              // Not `session.dds!`: being debug-ready does not imply a DDS of
              // our own. Web never has one — DWDS owns it and hands over a URL
              // — so the null check throws `Null check operator used on a null
              // value`, which the catch below prints as the reason DevTools
              // could not launch.
              final dds = session.dds;
              if (dds == null) {
                throw StateError(
                  'No DevTools URL and no Dart Development Service on '
                  '${session.device.name}, so there is nothing to serve '
                  'DevTools from. On web the debug connection carries the '
                  'URL; this one did not.',
                );
              }
              final devtools = await _launchDevTools(dartExecutable, dds.uri!);
              session.devToolsProcess = devtools.process;
              if (devtools.serverUrl == null) return;
              url = devToolsConnectUri(
                devtools.serverUrl!,
                dds.wsUri!,
              ).toString();
              session.devToolsUrl = url;
            }

            // Both renderings of one fact: the line a terminal user reads,
            // and upstream's `app.devTools` event, which is the only way a
            // `--machine` client is told the URL at all.
            logDevTools('DevTools at $url (${session.device.name})');
            protocol.appDevTools(session.appId, url);
          } catch (e) {
            // Non-fatal: DevTools is optional.
            _logger.warning({
              'message': 'devtools_launch_failed',
              'text':
                  'Could not launch DevTools for ${session.device.name}: $e. '
                  'The run continues without an inspector, timeline, or memory '
                  'view for this device.',
              'device': session.device.name,
              'error': '$e',
            });
          }
        }),
      );
    }
  }

  // The single-key shortcuts below are only wired up for an interactive
  // terminal. In `--machine` mode stdin is the JSON-RPC command channel (see
  // the `protocol.enabled` early-return after the watcher), so a keystroke like
  // "q" is parsed as JSON and fails with a -32700 parse error rather than
  // quitting. Worse, `log` writes to stdout — which the machine protocol owns —
  // so the banner would also corrupt the protocol stream. Suppress it entirely
  // in machine mode; the consumer drives the session via app.* commands.
  if (!protocol.enabled) {
    if (hotReloadUnavailable == null) {
      if (watcher != null) {
        log(
          'Watching for file changes. Press "r" hot reload, "R" restart, "p" perf overlay, "i" inspector, "q" quit.',
        );
      } else {
        log(
          'Press "r" hot reload, "R" restart, "p" perf overlay, "i" inspector, "q" quit.',
        );
      }
    } else {
      // Names the reason rather than quietly listing a shorter menu. The
      // absence of "r" is only informative to someone who knew to expect it.
      log(
        'Hot reload is off for this run: $hotReloadUnavailable. '
        'Press "p" perf overlay, "i" inspector, "q" quit.',
      );
    }
  }

  // Attach the reload handler to the already-running watcher. Anything it
  // recorded while the run was still wiring itself up arrives now.
  StreamSubscription<SourceChange>? watcherSubscription;
  // Gated on the reload command, not on a frontend server: native has one
  // compiler per app and no single server to check, and the command is what
  // the handler actually dispatches through.
  if (watcher != null &&
      hotReloadUnavailable == null &&
      commandRunner.hasCommand('app.hotReload')) {
    watcherSubscription = _watchAndReload(
      watcher: watcher,
      resolver: resolver ?? () => null,
      awaitingAssembly: awaitingAssembly ?? () => false,
      isAsset: isAsset,
      commandRunner: commandRunner,
      log: log,
      announce: announce,
    );
  }

  // What ends this run, whichever transport is driving it: a session's app
  // gone for good, or a teardown asked for over a transport (`app.stop`,
  // `daemon.shutdown`). The explicit signal lets the caller regain control to
  // close its transports AFTER the command that requested the teardown has
  // sent its response.
  //
  // Both signals are real on every mode. Attach's app is not a process this
  // tool holds, so its "gone" is the VM service closing and not coming back —
  // reported through the same `terminated` (see `_ExternalAppProcess`).
  //
  // `DeviceSession.terminated`, not `appInstance.process.exitCode`: the latter
  // is sampled once, so a restart that relaunches the process (its native
  // libraries changed) resolves it with the exit of the process it had just
  // deliberately replaced. The run would then close its transports — the HTTP
  // control channel included — leaving a driver with a healthy relaunched app
  // it could no longer talk to.
  //
  // One list for both branches below, rather than a derivation per branch.
  //
  // Every session, not the first: `app.stop` stops one app, so a run driving
  // two devices outlives the first of them ending — whether it was stopped or
  // died. A single-device run is unchanged, its one app being both the first
  // and the last.
  final exitSignals = <Future<void>>[
    if (sessions.isNotEmpty)
      Future.wait([for (final s in sessions) s.terminated]),
    if (shutdownSignal != null) shutdownSignal,
  ];
  final exited = exitSignals.isEmpty ? null : Future.any(exitSignals);

  // In machine mode, stdin is consumed by MachineProtocol — skip the
  // keyboard loop and wait for sessions to end via machine commands.
  if (protocol.enabled) {
    if (exited != null) await exited;
    await watcherSubscription?.cancel();
    return;
  }

  // Keyboard loop (interactive terminal mode only).
  bool terminalConfigured = false;
  if (setEchoMode != null) {
    setEchoMode(false);
    terminalConfigured = true;
  } else if (stdin.hasTerminal) {
    try {
      stdin.echoMode = false;
      terminalConfigured = true;
    } on StdinException {
      // Not a real terminal (e.g. backgrounded process).
    }
  }
  if (setLineMode != null) {
    setLineMode(false);
  } else if (terminalConfigured) {
    stdin.lineMode = false;
  }

  final inputStream = keyboardReader != null ? keyboardReader() : stdin;

  // Race each key read against [exited] — the same thing `--machine` waits on
  // above. A teardown requested over a transport ends the loop like 'q' does,
  // instead of leaving a stopped session waiting on the keyboard; and the app
  // being gone for good ends it whether or not anyone is at the keyboard.
  final keys = StreamIterator<List<int>>(inputStream);
  var keyboardOpen = true;
  while (true) {
    if (!keyboardOpen) {
      // Nothing else to read. Wait out the run on the signals alone — the
      // loop's return is what closes the transports, so returning here would
      // take the advertised HTTP control channel down under a live app.
      await exited!;
      break;
    }
    final wake = await Future.any<_Wake>([
      keys.moveNext().then((has) => has ? _Wake.key : _Wake.keyboardClosed),
      if (exited != null) exited.then((_) => _Wake.exit),
    ]);
    if (wake == _Wake.exit) break;
    if (wake == _Wake.keyboardClosed) {
      // stdin reaching EOF means there is no keyboard — not that the run is
      // over. A terminal losing its pty is the rarer half of this; the common
      // one is a script, a CI job or an agent starting the tool with stdin at
      // /dev/null, which reaches EOF at once. Ending the loop there would take
      // the run's transports with it: the channel's URL has just been printed,
      // and its port would already be dead with nothing said. Advertised
      // lifetime and actual lifetime have to be the same lifetime.
      //
      // With nothing left that could ever end the run — no app to exit, no
      // transport to be told — there is also nothing left to control, so the
      // loop returns and lets the caller tear down.
      keyboardOpen = false;
      if (exited == null) break;
      final ways = <String>[
        if (sessions.isNotEmpty) 'the app exiting',
        if (shutdownSignal != null) 'an `app.stop` on a control transport',
      ];
      log(
        'stdin closed, so the keys above no longer do anything. The run '
        'continues, and everything it advertised — the HTTP control channel '
        'included — stays up. It ends on ${ways.join(' or ')}.',
      );
      continue;
    }
    final input = keys.current;
    final char = String.fromCharCode(input.first);
    switch (char) {
      // Both keys are pure dispatch, with no private fallback behind them: the
      // commands are always registered before this loop exists, and a fallback
      // would only diverge — invalidating the entrypoint alone where the
      // pipeline diffs a snapshot of the whole workspace, with nothing able to
      // execute it and notice. A run with no way to reload still answers here,
      // through the pipeline's readiness gate.
      //
      // Unconditional, including on a run that cannot reload: a keypress that
      // produces nothing at all cannot be told from one the terminal never
      // received. Refusing here instead would put a second answer to "can this
      // run reload" beside the readiness gate's, and they can only drift; the
      // gate already holds the reason, and it is the same reason the HTTP
      // channel and the machine protocol get.
      case 'r':
        reportReloadCommand(
          'Hot reload',
          await commandRunner.run('app.hotReload', {}),
          log,
          method: 'app.hotReload',
          announce: announce,
        );
      case 'R':
        // Presentation, like the banner, so it is gated the way the banner is:
        // announcing a restart and then refusing it reads worse than saying
        // nothing. Through `log` rather than `stdout` so it is the same stream
        // as the answer that follows.
        if (hotReloadUnavailable == null) log('Performing hot restart...');
        reportReloadCommand(
          'Hot restart',
          await commandRunner.run('app.restart', {}),
          log,
          method: 'app.restart',
          announce: announce,
        );
      case 'p':
        await _reportToggle(
          sessions,
          log,
          'Performance overlay',
          (client) => client.togglePerformanceOverlay(),
        );
      case 'i':
        await _reportToggle(
          sessions,
          log,
          'Widget inspector',
          (client) => client.toggleWidgetInspector(),
        );
      case 'q':
        await watcherSubscription?.cancel();
        for (final session in sessions) {
          await session.shutdown(protocol);
        }
        if (frontendServer != null) {
          await frontendServer.shutdown();
        }
        await keys.cancel();
        return;
    }
  }
  // The run is over — the app is gone, or a teardown was signalled and the
  // sessions were torn down by whoever signalled it. Just release local
  // resources.
  await watcherSubscription?.cancel();
  await keys.cancel();
}

/// Why the keyboard loop woke up.
///
/// Three outcomes, not the two a `bool` carries: a key, the run ending, and
/// the keyboard going away.
enum _Wake { key, keyboardClosed, exit }

/// Subscribe [watcher] to the reload pipeline.
///
/// The watcher is started by the caller, before the app launches, so that a
/// run is already listening by the time it reports `app.started`; this only
/// attaches the handler, which cannot exist until the pipeline it drives does.
/// [SourceWatcher.changes] buffers whatever landed in between.
StreamSubscription<SourceChange> _watchAndReload({
  required SourceWatcher watcher,
  required PackageUriResolver? Function() resolver,
  required bool Function() awaitingAssembly,
  PathFilter? isAsset,

  /// The dispatcher a watched edit reloads through. Non-null and holding
  /// `app.hotReload`: both callers register the pair before anything can
  /// watch, and the handler is the only path to the per-app compilers.
  required CommandRunner commandRunner,
  required void Function(String message) log,

  /// Where the outcome of a watched edit's reload goes for a machine reader.
  /// This is the only path that reaches it in `--machine` mode — the keyboard
  /// loop is unreachable there (see the early return above) — so an IDE's
  /// whole view of watch-driven reloads is what this emits.
  required void Function(Map<String, dynamic> params) announce,
}) {
  return watcher.changes.listen((change) async {
    // Map each changed source path to the `package:` URI the frontend_server
    // keys it by, via the authoritative build-emitted resolver. A path that
    // belongs to no first-party source package (e.g. a tool script) resolves
    // to null and is skipped — never invalidated with a bogus file:// URI.
    final map = resolver();
    final invalidated = [
      for (final f in change.paths)
        if (map?.toPackageUri(f) case final uri?) uri,
    ];
    // An asset carries no package URI and never will, so an empty
    // `invalidated` does not mean there is nothing to do. The reload command
    // rebuilds the bundle and delivers it; the Dart half is simply a no-op.
    final assetsChanged = change.paths.any((f) => isAsset?.call(f) ?? false);
    // Nor does it when there is no resolver yet, which is the state a pipeline
    // whose build failed sits in: the file that would cure it maps to nothing,
    // because what would have mapped it is what the failed build was supposed
    // to produce. Dropping the edit here is what would leave the fix unseen —
    // the reload derives its own work from the disk snapshot once the pipeline
    // exists, so an empty `invalidatedFiles` costs nothing.
    if (invalidated.isEmpty && !assetsChanged && !awaitingAssembly()) return;

    reportReloadCommand(
      'Hot reload',
      await commandRunner.run('app.hotReload', {
        'invalidatedFiles': invalidated,
      }),
      log,
      method: 'app.hotReload',
      announce: announce,
    );
  });
}

/// The DevTools server root announced by `dart devtools`, or null for a line
/// that is not that announcement.
///
/// The announcement ends a sentence — `Serving DevTools at
/// http://127.0.0.1:9100.` — so the match is anchored to end of line and the
/// period is left outside the capture. Including it produces a URL that
/// `Uri.parse` rejects with `FormatException: Invalid port`.
String? parseDevToolsUrl(String line) =>
    RegExp(r'Serving DevTools at (http\S+?)\.?\s*$').firstMatch(line)?.group(1);

/// Flip [label] on every session, and say what happened on each.
///
/// The `p` and `i` keys are the only ones whose work is a bare VM-service call,
/// and [VmServiceClient] refuses one it has no live connection for by throwing
/// a `StateError`. Nothing between that throw and `main` catches one — the run
/// loop awaits it bare, `RunCommand.execute` catches only `DevToolException` —
/// so an unguarded keypress ends the whole run with a stack trace: a `p`
/// against a client with no service takes `runInteractiveSession` down with
/// it.
///
/// That is the wrong end for a toggle. A run whose VM service has gone still
/// serves its app's console output on every native device (which is read from
/// the process's own pipes, not the VM service), still answers
/// `screenshot/native`, still watches sources, and still shuts itself down on
/// `q` — so a decoration it cannot draw is a line to print, not a run to end.
///
/// Caught around the call rather than guarded before it. There is no guard that
/// would be honest: `isConnected` is true for a client whose handshake threw,
/// and a client that answers the first RPC can still lose the socket before the
/// second. What the user is told is the client's own reason, so a connection
/// that has given up naming why says it here too.
///
/// A session with no VM client at all — `--allow-no-vm-service` — is told the
/// same way rather than skipped: a keypress that does nothing cannot be told
/// from one the terminal never received.
Future<void> _reportToggle(
  List<DeviceSession> sessions,
  void Function(String) log,
  String label,
  Future<bool> Function(VmServiceClient) toggle,
) async {
  for (final session in sessions) {
    final client = session.vmClient;
    final where = session.device.name;
    if (client == null) {
      log('$label is unavailable on $where: this run has no VM service.');
      continue;
    }
    try {
      final enabled = await toggle(client);
      log('$label ${enabled ? "enabled" : "disabled"} ($where).');
    } catch (e) {
      log('Could not toggle the ${label.toLowerCase()} on $where: $e');
    }
  }
}

/// The URL that opens DevTools already attached to [vmServiceWsUri].
///
/// `dart devtools` announces only its own server root; opening that lands on
/// the "Connect to a Running App" form with nothing connected. DevTools reads
/// the target VM service from the `uri` query parameter, which is the same
/// shape DDS itself hands out (`…/devtools/?uri=ws://…/ws`).
///
/// Must be the **ws** URI: DevTools dials it as a WebSocket.
Uri devToolsConnectUri(String serverUrl, Uri vmServiceWsUri) =>
    Uri.parse(serverUrl).replace(
      queryParameters: {'uri': vmServiceWsUri.toString()},
    );

/// Start `dart devtools` and return the process plus its announced server root.
///
/// [dartExecutable] is the Dart binary from the Flutter toolchain. Resolving it
/// rather than spawning a bare `dart` keeps the DevTools we launch tied to the
/// SDK the app was built with, and fails loudly when the toolchain is missing
/// instead of picking up whatever happens to be on `PATH`.
Future<({Process process, String? serverUrl})> _launchDevTools(
  String dartExecutable,
  Uri vmServiceUri,
) async {
  final process = await Process.start(
    dartExecutable,
    ['devtools', '--no-launch-browser', '--vm-uri=$vmServiceUri'],
  );

  final completer = Completer<String?>();
  Timer? timeout;

  timeout = Timer(const Duration(seconds: 15), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  process.stdout
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter())
      .listen((line) {
        final url = parseDevToolsUrl(line);
        if (url != null && !completer.isCompleted) {
          timeout?.cancel();
          completer.complete(url);
        }
      });

  final serverUrl = await completer.future;
  return (process: process, serverUrl: serverUrl);
}
