/// VM service client for hot reload.
///
/// Connects to a running Flutter app's VM service to push
/// incremental .dill deltas for hot reload/restart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'hot_reload/asset_bundle.dart' show touchesFonts;
import 'hot_reload/flutter_error_report.dart';
import 'logging.dart';
import 'running_code.dart';

final _logger = Logger('dev_tool.vm_service');

/// Signature for connecting to a VM service (allows test injection).
typedef VmServiceConnector = Future<VmService> Function(String wsUri);

/// What an apply — a reload, a restart, an asset push — did to the app.
///
/// Three outcomes rather than a bool, because two of them are failures that
/// differ in the one way that matters to anything recording what the app is
/// running: [VerdictAppErrored] means the code **is** live and the app is
/// unhappy about it, while [VerdictRefused] means nothing landed at all.
/// Collapsing the two makes the compiler discard code the VM is already
/// running, leaving its accepted baseline describing a program no app has.
sealed class ApplyVerdict {
  const ApplyVerdict();
}

/// The VM took the code and the app rendered the next frame without error.
class VerdictApplied extends ApplyVerdict {
  const VerdictApplied();
}

/// Nothing landed: the VM rejected the kernel, the upload failed, or the
/// delivery threw before it could finish.
///
/// [reason] is this client's own account of what stopped it — never the app's,
/// because an app error observed while a refused apply was in flight belongs
/// to whatever the app was already doing, not to code it never ran.
///
/// A plain string, not a [FlutterErrorReport]: that type's other fields (the
/// framework's rendering, its error count) only an app can fill in, and a
/// refusal has no app to fill them.
///
/// Required, so the layer above never has to invent a reason for a refusal
/// that carried none.
class VerdictRefused extends ApplyVerdict {
  final String reason;
  const VerdictRefused(this.reason);
}

/// The code is live, and what came next failed.
///
/// Either the app reported a framework error on the frame that followed, or
/// the rebuild step that only runs *because* the code landed threw. Both leave
/// the VM executing the new kernel, which is the only thing the layer above
/// records, so both are this verdict rather than a [VerdictRefused].
///
/// [error] is the app's own report when it sent one, kept whole.
class VerdictAppErrored extends ApplyVerdict {
  final FlutterErrorReport error;
  const VerdictAppErrored(this.error);
}

/// What [VmServiceClient.waitUntilPausedAtStart] managed to observe.
///
/// Three states rather than a bool because "the isolate is running" and "the
/// isolate never answered" lead somewhere different: the first is a launch
/// switch the target ignored, worth reporting as fact, and the second is a
/// question that went unanswered, which no message may state as fact.
enum StartPausedState {
  /// Read the isolate and found it holding at `PauseStart`.
  pausedAtStart,

  /// Read the isolate, within the deadline, and it was never at `PauseStart`.
  running,

  /// Never read the isolate at all — no connection, no main isolate, or every
  /// poll in the window failed.
  unknown,
}

/// A framework service extension the app never registered.
///
/// Distinct from an [RPCError] carrying `-32601`, which says only that the
/// call did not land: this says the app was given [waited] to bring the
/// extension up and did not, so the absence is the app's and not a race with
/// its startup.
class ServiceExtensionUnavailable implements Exception {
  /// The extension that never appeared, e.g. `ext.flutter.evict`.
  final String method;

  /// How long the app was given to register it.
  final Duration waited;

  ServiceExtensionUnavailable(this.method, this.waited);

  @override
  String toString() =>
      '$method is not registered: the app did not bring it up within '
      '${waited.inSeconds}s';
}

/// The JSON-RPC code a VM service returns for a method it does not have.
///
/// Named locally the way `build_info.dart` names `-32602`:
/// `package:vm_service` exposes the wire codes only as literals.
const int _rpcMethodNotFound = -32601;

/// How often [VmServiceClient.waitForFirstFrame] re-asks
/// `ext.flutter.didSendFirstFrameEvent`.
///
/// The framework registers the extension a beat after the isolate starts
/// answering, so the first ask is expected to miss. Bounded by the caller's own
/// timeout, so this only decides how promptly a painted app is noticed.
const Duration _firstFramePollInterval = Duration(milliseconds: 300);

/// Client for the Dart VM service protocol.
///
/// Connects to a running Flutter app and provides hot reload and restart.
/// Uploads incremental dills through the VM's in-memory devFS, which works for
/// both local and remote (iOS device) VMs.
class VmServiceClient {
  final VmServiceConnector _connector;
  VmService? _service;

  /// The live `package:vm_service` connection, or null before [connect] (or
  /// after [disconnect]).
  ///
  /// Exposed so callers can subscribe to streams this client doesn't wrap —
  /// notably `Stdout`/`Stderr` for app output forwarding in attach mode, where
  /// the VM service is the only available log source.
  VmService? get service => _service;
  String? _mainIsolateId;

  /// Subscription to the VM's `Isolate` stream. Replaced on every [connect],
  /// since each one brings a new [VmService] and its streams with it.
  StreamSubscription<Event>? _isolateEvents;

  /// Service extensions the current main isolate has registered.
  ///
  /// Fed by `ServiceExtensionAdded` on the `Isolate` stream and seeded from
  /// `getIsolate` for whatever was registered before this client was listening.
  /// Emptied whenever the main isolate changes — an extension belongs to the
  /// isolate that registered it.
  final Set<String> _extensionRpcs = {};

  /// Newly-registered extension names, for [waitForServiceExtension].
  ///
  /// A stream rather than a completer per name so that an isolate rotation
  /// mid-wait needs no special handling: the waiter simply goes on waiting, and
  /// what it is waiting for is now the new isolate's registration.
  final StreamController<String> _extensionAdded =
      StreamController<String>.broadcast();

  /// How long [waitForServiceExtension] waits by default.
  ///
  /// Long enough to cover a browser starting a DDC-compiled app from cold, and
  /// short enough that an app which is never going to register says so instead
  /// of leaving the caller wondering.
  Duration serviceExtensionTimeout = const Duration(seconds: 30);

  /// The HTTP address of the VM service (for devFS file uploads).
  Uri? _httpAddress;

  /// Name of the devFS created on the VM.
  static const _devFSName = 'flutter_bazel';

  /// Base URI of the devFS as returned by the VM.
  Uri? _devFSBaseUri;

  /// Absolute path to the app's `flutter_assets` directory, required by the
  /// engine's `_flutter.runInView` (hot restart re-runs main from a fresh
  /// isolate and re-specifies the asset bundle). Set by the run command from
  /// the build outputs before the first restart.
  String? assetDirectory;

  /// How long the whole [connect] sequence gets before it is declared hung.
  ///
  /// Not one deadline per step: a dial that never answers, a `getVM` that never
  /// returns and a `_createDevFS` that never lands all cost the caller the same
  /// thing, and the caller's question is only ever "am I connected yet".
  ///
  /// This is the bound the *rest* of the client rests on. Every method reaches
  /// the VM through [_withReconnect], which re-runs [connect] whenever the
  /// previous connection was dropped — so an untimed connect is an untimed
  /// `app.getText`, an untimed asset push, and an untimed anything else, all of
  /// them inside `CommandRunner`'s single command permit.
  final Duration connectTimeout;

  /// Monotonic id of the current [connect] attempt.
  ///
  /// A dial cannot be cancelled, so a [connect] that exceeds [connectTimeout]
  /// leaves its own sequence running. The attempt it started carries this id
  /// and re-checks it once the socket is up; a mismatch means the caller has
  /// already been told the connect failed, and the connection is closed instead
  /// of published.
  int _connectAttempt = 0;

  /// Whether the connection this client keeps remaking is one with a devFS.
  ///
  /// Recorded from [connect] so a re-dial rebuilds the same connection rather
  /// than a differently-shaped one. Web connects without a devFS — DWDS's proxy
  /// has no filesystem and answers `_createDevFS` with `-32601` — and a
  /// reconnect that asked for one anyway would report that predictable refusal
  /// as a warning about the run's reload being broken.
  bool _wantsDevFS = true;

  /// Whether the last thing to close this connection was us.
  ///
  /// Set by [disconnect] and [forceDisconnect] before either touches the
  /// socket, cleared by [connect]. It exists because the difference between a
  /// hang-up we chose and an app that died cannot be recovered from anything
  /// else by the time [_watchForClose] runs: the `onDone` listener runs *after*
  /// `disconnect` has returned, so the service is already null and the attempt
  /// counter has already moved — exactly what a superseded connection looks
  /// like.
  ///
  /// One consequence, taken deliberately: between a [forceDisconnect] and the
  /// next [connect] there is no connection to watch, so an app that dies in
  /// that window is not noticed until something asks the VM for something. The
  /// alternative — reading our own hang-up as a death — would end a run that
  /// merely reset a wedged socket.
  bool _hungUp = false;

  /// Set once the owner has finished with this client for good — see [retire].
  ///
  /// Distinct from [_hungUp], which every close sets and the next [connect]
  /// clears: a [forceDisconnect] mid-run drops a wedged socket precisely so
  /// the next command can dial a fresh one. This one is the run ending, and it
  /// never clears.
  bool _retired = false;

  /// The re-dial in flight, or null. One at a time, shared by everyone who
  /// wants it: a dropped socket is noticed twice — by [_watchForClose] and by
  /// whatever RPC was in flight — and two connects racing to publish leave the
  /// loser's caller holding a connection that was replaced out from under it.
  Future<void>? _reconnecting;

  final Completer<void> _gone = Completer<void>();

  /// Completes when the app on the other end of this connection is gone.
  ///
  /// "Gone" is not "the socket closed". A socket closing and reopening is what
  /// a reconnect *is* — a DDS tunnel hiccup, an idle timeout, a restart
  /// rotating the VM — so this waits for the close and then re-dials once,
  /// completing only if the re-dial does not come back. That is the same
  /// tolerance [_withReconnect] grants an RPC that failed on a dropped
  /// connection, extended to an *idle* connection, which is the state a run
  /// with nothing to say sits in.
  ///
  /// A re-dial that comes back but does not *stay* is the other way an app is
  /// gone. [flapLimit] consecutive connections dying inside [flapWindow] is
  /// that app: each dial succeeds, so no dial throws, so without a cap nothing
  /// here would ever complete while the watcher each new connection installs
  /// dials again on its death. Completing on the cap is the honest reading of a
  /// socket that will not stay up, and it is the reason the tolerance above can
  /// stay as generous as it is.
  ///
  /// Deliberately not completed by [disconnect] or [forceDisconnect]: those are
  /// this end hanging up, and say nothing about the app.
  ///
  /// **`attach` is the only consumer, and that asymmetry is the design.** An
  /// attach did not launch the app and cannot stop it, so the connection is the
  /// only evidence it has that the app still exists. A `run` has a process to
  /// reap, and its session ends on that process's exit and on nothing else.
  ///
  /// It is not that a `run` never gets here — it gets here on every ordinary
  /// quit, and ahead of the teardown's own [disconnect]: the app is killed, the
  /// socket closes and the re-dial is refused before the process's `exitCode`
  /// lands. So an event hung off `gone` in a `run` would fire every time a user
  /// closes the app window — which is why the run path reads the exit code
  /// instead, and why a consumer added here later must be one that ordinary
  /// shutdown may trigger.
  ///
  /// Reaching it *without* the app having died is rarer than the [flapLimit]
  /// machinery suggests. The native connection is a loopback socket to the DDS
  /// this tool runs in its own process; it closes when DDS does, which is when
  /// the app's VM service went away, and that is terminal on the first refused
  /// re-dial rather than on the fifth flap. The cap bounds a loop that would
  /// otherwise not end; it is not evidence that anything in ordinary use flaps.
  ///
  /// One-way in both directions once it completes: no path re-dials afterwards.
  ///
  /// A future rather than a stream because it is a one-way fact and the
  /// connection outlives its consumers' construction — a late listener still
  /// gets the answer.
  Future<void> get gone => _gone.future;

  /// Whether this client has already concluded the app is gone.
  ///
  /// The same fact [gone] carries, asked at an instant rather than awaited.
  /// [gone] is the right shape for a caller that is watching for the death; this
  /// is the right shape for one that has just been handed a *failure* and has to
  /// decide what caused it, where awaiting a future that never completes on a
  /// live app is not an option.
  ///
  /// A caller that gets `false` has learned only that no verdict has been
  /// reached yet — a re-dial can still be in flight — so this is evidence for
  /// blaming the app's death, never against it.
  bool get isGone => _gone.isCompleted;

  /// Why the app is gone, in the words the verdict was recorded with. Non-null
  /// exactly when [isGone].
  ///
  /// Exposed so a caller reporting the death can say what ended it rather than
  /// composing a second, vaguer account of a cause this client already knows —
  /// the same reason [_goneMessage] carries it to callers of a dead connection.
  String? get goneReason => _goneReason;

  /// How long [disconnect] waits for the app to acknowledge the devFS it is
  /// being asked to delete.
  ///
  /// That RPC is a question put to the app, and a wedged app does not answer
  /// it — it does not fail either, so there is nothing for a `catch` to catch.
  /// This is the only thing that ends the wait.
  final Duration disconnectTimeout;

  /// How long a connection has to last to count as one that worked.
  ///
  /// A socket that closes long after it was established is a hiccup — a DDS
  /// tunnel resetting, an idle timeout, a device off Wi-Fi for a moment — and
  /// the re-dial that follows recovers it. One that dies within this of being
  /// established never got to be used: the connect sequence it had just
  /// finished (the dial, `getVM`, two `streamListen`s and a devFS) takes
  /// milliseconds, and the tool's own reload round-trip takes longer than this
  /// whole window. Nothing was carried on it.
  ///
  /// Judged against the connection this end can see, not against the app: an
  /// idle `attach` issues no RPC for minutes at a time, so how long the socket
  /// stood is the only evidence there is.
  final Duration flapWindow;

  /// How many connections may die inside [flapWindow], one after another,
  /// before this client stops re-dialling and reports the app gone.
  ///
  /// The bound exists because a re-dial that *succeeds* and then dies feeds the
  /// watcher that provoked it: behind a tunnel that drops every connection this
  /// client would dial without end and without ever reporting anything. The
  /// rate is not the harm — the run never finishing is.
  ///
  /// Five rather than one, which is what a *refused* re-dial already gets (see
  /// [gone]). The two are not the same evidence. Nothing answering the port is
  /// unambiguous; a peer that completes a whole VM-service handshake and only
  /// then hangs up is a tunnel that might be re-establishing, so it is given
  /// room to prove it. What it is not given is forever.
  final int flapLimit;

  /// Reads the current time.
  ///
  /// Injectable for one reason: [flapWindow] is the only judgement this class
  /// makes in wall-clock, and a test cannot make time pass without sleeping.
  /// Everything else here is driven by events a test can post directly.
  final DateTime Function() _now;

  /// Connections that have died inside [flapWindow] with none in between that
  /// outlived it. Reset by a close that came late enough to prove the
  /// connection worked, and by a teardown this end chose.
  int _flaps = 0;

  VmServiceClient({
    VmServiceConnector? connector,
    this.connectTimeout = const Duration(seconds: 30),
    this.disconnectTimeout = const Duration(seconds: 5),
    this.flapWindow = const Duration(seconds: 5),
    this.flapLimit = 5,
    DateTime Function() now = DateTime.now,
  }) : _connector = connector ?? vmServiceConnectUri,
       _now = now;

  /// Connect to the VM service at the given URI, within [connectTimeout].
  ///
  /// Throws [TimeoutException] when the budget runs out, leaving the client
  /// disconnected — which is the honest state, and the one that lets the next
  /// call try again. Callers that can retry (the device launcher, the native
  /// relaunch path) already treat a throwing connect as their retry signal.
  ///
  /// [createDevFS] reflects what the target actually implements. The Dart VM
  /// serves `_createDevFS`, and the native reload path uploads dills through
  /// it. A web app's VM service is DWDS's proxy over the Chrome debugger,
  /// which has no filesystem to write to and answers `-32601 Unknown method`;
  /// web reloads push sources over DWDS instead. Callers say which they are
  /// rather than having a predictable failure reported as a warning.
  Future<void> connect(Uri serviceUri, {bool createDevFS = true}) async {
    if (_retired) throw StateError(_retiredMessage);
    _wantsDevFS = createDevFS;
    _hungUp = false;
    final attempt = ++_connectAttempt;
    final inner = _connect(serviceUri, attempt, createDevFS: createDevFS);
    try {
      await inner.timeout(connectTimeout);
    } on TimeoutException {
      // Abandon [attempt] so a socket that arrives later closes itself, then
      // drop whatever this attempt had already published — past the dial, the
      // sequence is running against a connection this client owns, and leaving
      // it in place would report `isConnected` for a wedged socket.
      _connectAttempt++;
      inner.ignore();
      await forceDisconnect();
      rethrow;
    }
  }

  Future<void> _connect(
    Uri serviceUri,
    int attempt, {
    required bool createDevFS,
  }) async {
    _httpAddress = serviceUri;

    // Convert http(s) URI to ws URI for VM service.
    final wsUri = serviceUri.replace(
      scheme: serviceUri.scheme == 'https' ? 'wss' : 'ws',
      path: '${serviceUri.path}ws',
    );

    final svc = await _connector(wsUri.toString());
    if (attempt != _connectAttempt) {
      // [connect]'s deadline gave up on this dial. Publishing it now would hand
      // the client a connection its caller was told it did not get.
      unawaited(svc.dispose());
      return;
    }
    _service = svc;

    // Find the main isolate.
    final vm = await _service!.getVM();
    String? found;
    for (final isolateRef in vm.isolates ?? <IsolateRef>[]) {
      if (isolateRef.name == 'main') {
        found = isolateRef.id;
        break;
      }
    }
    _setMainIsolate(found ?? _mainIsolateId ?? vm.isolates?.firstOrNull?.id);

    // Register the Extension stream so Flutter.Error / Flutter.Frame
    // events flow; the per-reload verdict listener is attached in
    // _applyAndVerify.
    await _ensureStream(EventStreams.kExtension);

    // And the Isolate stream, which keeps [_mainIsolateId] on the live root
    // isolate. Not every restart runs through this client: the web one is
    // driven by DwdsReloadStrategy over this same connection, and a user
    // reloading the browser page rotates the isolate with no command at all.
    await _ensureStream(EventStreams.kIsolate);
    await _isolateEvents?.cancel();
    _isolateEvents = _service!.onIsolateEvent.listen(_onIsolateEvent);

    if (createDevFS) await _createDevFS();

    // Registered only now, after the handshake. Watching from the moment the
    // socket comes up would leave a watcher behind for a dial that died
    // *during* the handshake, and that watcher would dial again — a failing
    // connect building its own successor without end. Registering here, a
    // handshake that does not finish throws instead, out of [connect], to
    // whoever asked for it: the caller on a first connect, and [_reconnect] on
    // a re-dial, where a throw is exactly what [gone] reads as the app being
    // gone.
    //
    // There is no gap to miss. `onDone` is a future, so a socket that closed
    // while the sequence above was still running has already completed it, and
    // the listener attached here fires at once.
    _watchForClose(svc, attempt, _now());
  }

  /// Notice this connection ending, and decide whether the app ended with it.
  ///
  /// `package:vm_service` completes `onDone` when it disposes, and it disposes
  /// when the WebSocket's input stream closes — so this fires for a dropped
  /// connection without anything having to ask. The only other detector is an
  /// RPC failing with `-32000`, which an idle session never issues, and an
  /// `attach` has no other evidence of its app at all.
  ///
  /// [attempt] identifies the socket this watcher belongs to. A newer connect,
  /// a [disconnect] and a [forceDisconnect] all bump [_connectAttempt] before
  /// the old service is disposed, so a hang-up we chose reads as stale here and
  /// answers nothing — which is what keeps the relauncher's deliberate
  /// disconnect from being reported as the app dying.
  void _watchForClose(VmService service, int attempt, DateTime establishedAt) {
    unawaited(
      service.onDone.then((_) async {
        if (_hungUp) return;
        // Nothing here asks whether the app has already been reported gone.
        // [_reconnect] is the only door to a dial and it refuses once it has, so
        // a second guard here would have no observable effect.
        //
        // Old news: a newer connect has already published a different socket, so
        // this close is the end of a connection nothing is using. It is not a
        // strike against the one that replaced it. A teardown followed by a fresh
        // connect is exactly this — the old socket's `onDone` arrives a turn
        // later, by which time [_hungUp] has been cleared again — and counting it
        // would let a dead connection's flaps push a live one over the limit.
        if (_connectAttempt != attempt) return;

        if (_now().difference(establishedAt) >= flapWindow) {
          // It stood long enough to have been used. Whatever closed it is this
          // connection's own business and says nothing about the ones before.
          _flaps = 0;
        } else if (++_flaps >= flapLimit) {
          _reportGone(_flappingReason());
          // The socket that just died is the one this client is holding, and
          // nothing is going to replace it. Saying otherwise through
          // [isConnected] is the connected-looking corpse this class already
          // takes trouble elsewhere to avoid.
          _service = null;
          return;
        }

        try {
          await _reconnect(attempt);
        } catch (e) {
          // The socket closed and it does not come back. The failure *is* the
          // answer, so it is not rethrown — nothing is awaiting this, and the one
          // thing it has to do is tell whoever asked.
          _reportGone('$e');
        }
      }),
    );
  }

  /// Record that the app is gone, and why.
  ///
  /// The one door to completing [gone], so that every later caller can be told
  /// the same thing this decided — see [_goneMessage]. The reason is kept
  /// rather than discarded because the caller that finds out is usually not the
  /// one that was watching: an in-flight `app.getText` learns about the death
  /// from a `StateError`, and "the app is gone" without the cause sends whoever
  /// reads the log looking for a second failure.
  void _reportGone(String reason) {
    if (_gone.isCompleted) return;
    _goneReason = reason;
    _gone.complete();
  }

  /// Why [gone] completed. Non-null exactly when it has.
  String? _goneReason;

  /// Give up on a connection that will not stay up, loudly.
  ///
  /// Severe, and it names both numbers: an app whose connection cannot stay up
  /// is unusable, and the alternative to saying so is a loop that says nothing
  /// at all while it runs.
  String _flappingReason() {
    final reason =
        'it came up and died within ${flapWindow.inMilliseconds}ms '
        '$flapLimit times running';
    _logger.severe({
      'message': 'vm_service_flapping',
      'text':
          'The connection to the app $reason, so this client has stopped '
          're-dialling and is reporting the app gone. A connection that cannot '
          'stay up long enough to carry one command is an app nothing can '
          'drive; re-dialling it forever would only have kept that quiet.',
      'flaps': _flaps,
      'flapWindowMs': flapWindow.inMilliseconds,
    });
    return reason;
  }

  /// Re-dial the connection [replacing] identifies, at most once at a time.
  ///
  /// Every caller that finds the connection broken asks through here, naming
  /// the connection it found broken. Three answers:
  ///
  /// * a dial is already in flight — join it, because a dropped socket is one
  ///   event seen by several watchers and each dialling its own would leave all
  ///   but the last holding a connection that was replaced under it;
  /// * the connection has already been replaced by a live one — nothing to do,
  ///   and re-dialling would throw away a healthy socket to build a second;
  /// * otherwise dial, and on failure drop the dead service, because a client
  ///   still pointing at a disposed socket reports itself connected.
  ///
  /// Except once the app has been reported [gone]. That is the one answer this
  /// client cannot take back, so every door to a dial is closed behind it —
  /// this one included, because [_withReconnect] comes through here too and an
  /// RPC issued after the report would otherwise start the loop up again on its
  /// own. What the caller gets instead is the report, as an error it can
  /// render: `VmServiceAppInstance` already turns a [StateError] from this
  /// client into a failed apply naming its message.
  Future<void> _reconnect(int replacing) {
    if (_retired) {
      return Future.error(StateError(_retiredMessage));
    }
    if (_gone.isCompleted) {
      return Future.error(StateError(_goneMessage));
    }
    final pending = _reconnecting;
    if (pending != null) return pending;
    if (_service != null && _connectAttempt != replacing) {
      return Future<void>.value();
    }
    late final Future<void> dial;
    dial =
        Future(() async {
          try {
            await connect(_httpAddress!, createDevFS: _wantsDevFS);
          } catch (_) {
            _service = null;
            rethrow;
          }
        }).whenComplete(() {
          if (identical(_reconnecting, dial)) _reconnecting = null;
        });
    return _reconnecting = dial;
  }

  /// What a caller is told when it asks this client to reach an app that has
  /// already been reported [gone].
  ///
  /// Carries the cause, because this is the answer given to a caller that was
  /// not watching when the decision was made — and a bare "gone" would make it
  /// hunt for a reason that had already been established.
  String get _goneMessage => 'the app is gone: $_goneReason';

  /// What a caller is told when it asks a [retire]d client for a connection.
  String get _retiredMessage =>
      'this VM service client was retired when the run tore down, so it will '
      'not dial the app again';

  /// What a caller is told when this client has nothing to make its call on.
  ///
  /// Two states wear the same shape here — one that was never connected, and
  /// one that connected and then gave up — and only the second has a cause
  /// worth carrying. A bare "Not connected to VM service" for both is true and
  /// useless: it sends a reader looking for a connect that failed when what
  /// happened is that this client stopped re-dialling, minutes later, for a
  /// reason it had already established and recorded.
  ///
  /// The guards that reach these callers are the ones outside [_withReconnect]
  /// — `screenshotBytes` and the two extension toggles answer from the null
  /// service directly, so the report [_reconnect] hands to everyone else never
  /// reaches them. This is how it does.
  String get _noConnectionMessage =>
      _gone.isCompleted ? _goneMessage : 'Not connected to VM service';

  /// Ensure the VM is publishing [streamId]. Idempotent across reconnects.
  Future<void> _ensureStream(String streamId) async {
    final svc = _service;
    if (svc == null) return;
    try {
      await svc.streamListen(streamId);
    } on RPCError catch (e) {
      // 103 = kStreamAlreadySubscribed — fine on reconnect.
      if (e.code != 103) rethrow;
    }
  }

  /// Follow the root isolate across a rotation we did not initiate.
  ///
  /// The id is taken from the event itself rather than re-read with `getVM()`,
  /// so it is already updated by the time the restart's own response lands —
  /// events and responses travel in order on the one socket, and DWDS does not
  /// answer `hotRestart` until it has emitted the start
  /// (`dwds_vm_client.dart:439-441`).
  ///
  /// Adoption is deliberately confined to the window where there is nothing to
  /// adopt onto. An app spawning a background isolate (`compute`,
  /// `Isolate.spawn`) emits `IsolateStart` too, and that must not move the
  /// target off main. A rotation always arrives as exit-then-start — DWDS
  /// emits them in that order (`chrome_proxy_service.dart:385` then `:331`),
  /// as does the VM — so the exit is what opens the window.
  void _onIsolateEvent(Event event) {
    final id = event.isolate?.id;
    if (id == null) return;
    switch (event.kind) {
      case EventKind.kIsolateExit:
        if (id == _mainIsolateId) _setMainIsolate(null);
      case EventKind.kIsolateStart:
        if (_mainIsolateId == null) _setMainIsolate(id);
      case EventKind.kServiceExtensionAdded:
        final rpc = event.extensionRPC;
        if (id == _mainIsolateId && rpc != null) _noteExtension(rpc);
    }
  }

  /// Point at [id] as the main isolate, dropping the extension set if it is a
  /// different isolate than before. Registrations do not survive the isolate
  /// that made them, and a set that outlived one would answer
  /// [waitForServiceExtension] with a yes for an extension that is not there.
  void _setMainIsolate(String? id) {
    if (id == _mainIsolateId) return;
    _mainIsolateId = id;
    _extensionRpcs.clear();
  }

  /// Record [rpc] as registered and wake anything waiting for it.
  void _noteExtension(String rpc) {
    if (_extensionRpcs.add(rpc) && !_extensionAdded.isClosed) {
      _extensionAdded.add(rpc);
    }
  }

  /// [waitForServiceExtension], as a precondition rather than a question.
  ///
  /// Every caller that goes on to invoke a framework extension wants the same
  /// thing: the call to land, or a failure that names what was missing. Asking
  /// the boolean and then calling anyway does not give it — a `-32601` from a
  /// framework that has not finished registering reads identically to one from
  /// a framework that will never register it, so a call site can only guess.
  Future<void> requireServiceExtension(
    String method, {
    Duration? timeout,
  }) async {
    if (await waitForServiceExtension(method, timeout: timeout)) return;
    throw ServiceExtensionUnavailable(
      method,
      timeout ?? serviceExtensionTimeout,
    );
  }

  /// Wait until the app has registered [method] on its main isolate, returning
  /// whether it did within [timeout].
  ///
  /// There is a real window on web where the answer is no. DWDS rewrites the
  /// bootstrap's `child.main()` into `window.$dartRunMain`
  /// (`dwds/lib/src/handlers/injector.dart:139-164`), so *no* app Dart code
  /// runs until the injected client connects — which is a couple of seconds
  /// after the run reports `app.started`. Until then nothing is registered, the
  /// framework's own `ext.flutter.*` included, and every call answers
  /// `-32601 Unknown method`. A hot restart reopens the same window: DDC's
  /// `hotRestart` resets the SDK's lazy `_extensions` map
  /// (`ddc_runtime/runtime.dart:262`) and the regenerated entrypoint registers
  /// again from scratch.
  ///
  /// Native's window is much narrower but not absent. The engine's pre-main
  /// registrant hook has run by the time an agent command asks, so the seed
  /// answers those on the first call. A caller that runs the instant the VM
  /// service answers can still arrive first and get `-32601`.
  ///
  /// A main isolate is not required up front. Between a rotation's exit and its
  /// start there is none, and that is a moment to wait through rather than an
  /// answer: the start that ends it is what [_onIsolateEvent] adopts, and the
  /// registrations follow on the same stream.
  Future<bool> waitForServiceExtension(
    String method, {
    Duration? timeout,
  }) async {
    if (_service == null) return false;
    if (_extensionRpcs.contains(method)) return true;

    // One budget for the whole question, spent by the seed read first and by
    // the wait with whatever is left. The seed needs a bound of its own: it is
    // a `getIsolate` over the socket, and a socket that has gone quiet without
    // closing raises nothing for [_withReconnect] to catch, so an unbounded
    // read never returns. Every agent command asks this first, and the dev
    // tool's command pool is serialized, so one silent read stalls a whole
    // run's worth of commands.
    final spent = Stopwatch()..start();
    final budget = timeout ?? serviceExtensionTimeout;
    Duration left() {
      final remaining = budget - spent.elapsed;
      return remaining.isNegative ? Duration.zero : remaining;
    }

    // Subscribed before the seed round-trip, so a registration landing during
    // it is caught rather than falling between the two.
    final registered = Completer<void>();
    final sub = _extensionAdded.stream.listen((rpc) {
      if (rpc == method && !registered.isCompleted) registered.complete();
    });
    try {
      // Deliberately outside the `false` below: the two expiries are different
      // answers. The wait expiring means the app never registered the
      // extension, which is a fact about the app. The seed expiring means this
      // client learned nothing at all — the same case the `RPCError` path in
      // [_seedExtensionRpcs] rethrows rather than swallows — and reporting
      // that as "not registered" names the wrong cause.
      try {
        await _seedExtensionRpcs().timeout(left());
      } on TimeoutException {
        // Re-thrown carrying the whole budget rather than the slice that was
        // left of it, because the slice is an implementation detail of how the
        // budget was spent and the caller reports this number to a human.
        throw TimeoutException(
          'reading $_mainIsolateId to learn which extensions it has '
          'registered',
          budget,
        );
      }
      if (_extensionRpcs.contains(method)) return true;
      try {
        await registered.future.timeout(left());
      } on TimeoutException {
        return false;
      }
      return true;
    } finally {
      await sub.cancel();
    }
  }

  /// Read the extensions the main isolate has already registered.
  ///
  /// `ServiceExtensionAdded` is not replayed to a late subscriber, and on the
  /// first connection every registration is in the past — so the event stream
  /// alone would never mention them.
  Future<void> _seedExtensionRpcs() async {
    final id = _mainIsolateId;
    if (id == null) return;
    final Isolate isolate;
    try {
      isolate = await _callService((s) => s.getIsolate(id));
    } on RPCError {
      // A rotation is the one tolerable failure, and the same one the success
      // path below discards a result for: the isolate this asked about is
      // gone, so an error naming it says nothing about the app. The
      // replacement's registrations arrive on the `Isolate` stream, which is
      // what [waitForServiceExtension] is waiting on anyway.
      //
      // Everything else propagates. This read is the *only* source of
      // registrations that already happened — the paragraph above says why —
      // so a swallowed error here leaves [waitForServiceExtension] waiting for
      // an event that fired before it subscribed, and its callers then report
      // the timeout as fact: "the app never registered X", "the app never
      // brought it up". `native_pipeline_assembler.dart` already names the
      // rule this broke: a protocol fault is not a missing record, and
      // claiming the latter names the wrong cause.
      if (_mainIsolateId == id) rethrow;
      return;
    }
    // The isolate may have rotated while this was in flight, in which case what
    // came back describes one that is already gone.
    if (_mainIsolateId != id) return;
    for (final rpc in isolate.extensionRPCs ?? const <String>[]) {
      _noteExtension(rpc);
    }
  }

  /// Apply a kernel and verify the running app did not break.
  ///
  /// Determinism: a Flutter build failure is reported via
  /// `FlutterError.reportError` → a `Flutter.Error` extension event
  /// *during* `drawFrame`'s build phase, strictly before that same frame's
  /// `Flutter.Frame` timing event — and both travel on the single
  /// in-order VM-service `Extension` stream. So we subscribe *before*
  /// [apply] mutates the app, then, once the kernel is applied, await the
  /// first terminal event:
  ///   - `Flutter.Error` → the reload took but the app is now broken;
  ///   - the next `Flutter.Frame` → the rebuilt frame rendered cleanly.
  /// The verdict comes from awaiting the stream directly, so it never
  /// depends on cross-future microtask ordering. The timeout is only a
  /// degenerate-case safety net (no frame and no error ever arrive), never
  /// the success path.
  ///
  /// The two failures are returned as different values, not as one false: a
  /// [VerdictAppErrored] app is running the code it was just sent, and the
  /// caller's bookkeeping turns on that.
  ///
  /// Two callbacks rather than one, because the boundary between them *is* the
  /// difference between those two verdicts. [deliver] is everything up to and
  /// including the call that puts the code in the VM; it answers the reason it
  /// was refused, or null once the VM has it. [afterDelivery] is what only
  /// makes sense once the VM does have it — the rebuild, a restart's remaining
  /// views, an asset push's evictions — so anything it throws is a failure of
  /// an *applied* reload, never a refusal. It names its own step, because a log
  /// that calls all three "the rebuild" sends the reader to the wrong place.
  ///
  /// Running both under one `try` would make a `reassemble` that threw come
  /// back as [VerdictRefused], and the compiler would then roll its baseline
  /// back to a program the VM had already stopped running, computing the next
  /// delta against that fiction.
  ///
  /// [codeAfterDelivery] is what the app's Dart code is once [deliver] has
  /// completed: [RunningCode.updated] for the verbs that send a kernel, and
  /// [RunningCode.unchanged] for an asset push, which delivers bytes the app
  /// reads and never a line of Dart.
  ///
  /// The whole sequence still runs under [_withReconnect], so a connection
  /// disposed anywhere in it is re-dialled and the apply replayed. That replay
  /// is the reason for the one piece of state outside the closure: it can put
  /// the code in the VM on one attempt and fail on the next, and a socket
  /// closing does not take a kernel back out of a VM. Once anything has been
  /// delivered, no later attempt may answer [VerdictRefused].
  Future<ApplyVerdict> _applyAndVerify(
    Future<String?> Function() deliver, {
    required RunningCode codeAfterDelivery,
    ({String step, Future<void> Function() run})? afterDelivery,
  }) async {
    var delivered = false;
    try {
      return await _withReconnect(() async {
        var applied = false;
        FlutterErrorReport? capturedError;
        final settled = Completer<void>();
        void settle() {
          if (!settled.isCompleted) settled.complete();
        }

        // Subscribe before deliver() so no event between reloadSources and the
        // rebuilt frame can be missed.
        final sub = _service!.onExtensionEvent.listen((e) {
          if (e.extensionKind == 'Flutter.Error') {
            capturedError ??= _flutterError(e);
            if (applied) settle();
          } else if (e.extensionKind == 'Flutter.Frame' && applied) {
            settle();
          }
        });
        try {
          final refusal = await deliver();
          if (refusal != null) {
            if (delivered)
              return _deliveredThenLost(refusal, codeAfterDelivery);
            return VerdictRefused(refusal);
          }
          applied = true;
          delivered = true;
          if (afterDelivery != null) {
            try {
              await afterDelivery.run();
            } catch (e, stack) {
              // A dropped connection is this end's transport failing, not the
              // app's code. Hand it back to [_withReconnect], whose replay
              // rebuilds the connection and re-runs the apply on it; anything
              // else is the app, and stops here.
              if (e is RPCError && _isConnectionDisposed(e)) rethrow;
              return _afterDeliveryFailed(
                step: afterDelivery.step,
                error: e,
                stack: stack,
                reported: capturedError,
                codeAfterDelivery: codeAfterDelivery,
              );
            }
          }
          // An error may have been reported during reassemble, before
          // `applied` was set; honor it now.
          if (capturedError != null) settle();
          await settled.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () {},
          );
          final reported = capturedError;
          if (reported != null) return VerdictAppErrored(reported);
          return const VerdictApplied();
        } finally {
          await sub.cancel();
        }
      });
    } catch (e, stack) {
      // Nothing delivered: the caller's own `catch` answers, and its "the app
      // keeps running the code it already had" is true because of this line.
      if (!delivered) rethrow;
      return _deliveredThenLost('$e', codeAfterDelivery, stack);
    }
  }

  /// The verdict for a post-delivery step that threw.
  ///
  /// [VerdictAppErrored], not [VerdictRefused]: the app took what was delivered
  /// before this ran, so it has it whatever happened next. Nothing is waited
  /// for afterwards — the step that would have produced the next frame is the
  /// thing that just failed, so the frame is not coming.
  ///
  /// [reported] wins when the app sent one. It is the app's own account of the
  /// same moment, structured, with the framework's rendering and error count;
  /// the exception is only the account this end has when the app offered none.
  ApplyVerdict _afterDeliveryFailed({
    required String step,
    required Object error,
    required StackTrace stack,
    required FlutterErrorReport? reported,
    required RunningCode codeAfterDelivery,
  }) {
    _logger.severe({
      'message': 'apply_after_delivery_failed',
      'text':
          'The app has what this apply delivered, and $step then failed: '
          '$error. This is a broken app, not an apply that did not '
          'happen.\n$stack',
      'runningCode': codeAfterDelivery.name,
      'error': '$error',
      'stack': '$stack',
    });
    return VerdictAppErrored(
      reported ??
          FlutterErrorReport({
            'description':
                'the app took what this apply delivered, then $step '
                'failed: $error',
          }),
    );
  }

  /// The verdict for an apply whose replay failed after its first attempt had
  /// already delivered.
  ///
  /// [_withReconnect] replays a whole apply on a fresh connection when the old
  /// one is disposed mid-sequence; that is what recovers a DDS hiccup during a
  /// reload. What it cannot do is un-deliver what the first attempt delivered.
  /// So when the second attempt fails too — by throwing, or by refusing a
  /// delivery it can no longer perform, which is what a fresh devFS refusing
  /// the upload looks like — the answer is not a refusal. The app has the code,
  /// and telling the compiler otherwise leaves its baseline describing a
  /// program no app is running.
  ///
  /// Not [VerdictApplied] either: the steps that make the app *show* what
  /// landed may never have run, and there is no connection left to ask.
  ApplyVerdict _deliveredThenLost(
    String detail,
    RunningCode codeAfterDelivery, [
    StackTrace? stack,
  ]) {
    _logger.severe({
      'message': 'apply_lost_after_delivery',
      'text':
          'The app had already taken what this apply delivered when the '
          'connection to it failed, and the replay on a fresh connection did '
          'not get through either: $detail. What landed stays landed, so this '
          'is a connection to recover rather than an apply to redo.'
          '${stack == null ? '' : '\n$stack'}',
      'runningCode': codeAfterDelivery.name,
      'error': detail,
      if (stack != null) 'stack': '$stack',
    });
    return VerdictAppErrored(
      FlutterErrorReport({
        'description':
            'the connection to the app failed after this apply had '
            'already landed, and did not come back: $detail',
      }),
    );
  }

  /// The whole `Flutter.Error` payload.
  ///
  /// Nothing is chosen here. The framework sends a DiagnosticsNode tree and
  /// its own rendering of it; picking one field at arrival is what put a
  /// terminal-formatted dump inside JSON responses. The edges decide what to
  /// show.
  FlutterErrorReport _flutterError(Event e) =>
      FlutterErrorReport(e.extensionData?.data ?? const {});

  /// Create an in-memory filesystem on the VM for uploading dills.
  Future<void> _createDevFS() async {
    if (_service == null) return;
    // A new devFS is a new directory, so whatever the engine was told about
    // the old one no longer names anything.
    _assetDirectorySent = false;
    try {
      final response = await _service!.callServiceExtension(
        '_createDevFS',
        args: {'fsName': _devFSName},
      );
      final uri = response.json?['uri'] as String?;
      if (uri != null) _devFSBaseUri = Uri.parse(uri);
    } catch (e) {
      // 1001 = kFileSystemAlreadyExists — delete and recreate.
      if (e is RPCError && e.code == 1001) {
        try {
          await _service!.callServiceExtension(
            '_deleteDevFS',
            args: {'fsName': _devFSName},
          );
          final response = await _service!.callServiceExtension(
            '_createDevFS',
            args: {'fsName': _devFSName},
          );
          final uri = response.json?['uri'] as String?;
          if (uri != null) _devFSBaseUri = Uri.parse(uri);
        } catch (e2) {
          _warnDevFSUnavailable(e2);
        }
      } else {
        _warnDevFSUnavailable(e);
      }
    }
  }

  /// Report a devFS the VM refused to create.
  ///
  /// Fatal to every reload, every restart and every asset push for the rest of
  /// the run: [_uploadToDevFS] can only answer null without one, and the kernel
  /// then has nowhere to go that the app can read.
  void _warnDevFSUnavailable(Object error) {
    _logger.warning({
      'message': 'devfs_unavailable',
      'text':
          'Could not create the devFS on the VM: $error. There is nowhere '
          'to put a new kernel where the app can read it, so hot reload will '
          'fail until the connection is remade.',
      'error': '$error',
    });
  }

  /// Upload a file to the VM's devFS via HTTP PUT.
  ///
  /// Returns the devFS URI that can be passed to reloadSources.
  Future<Uri?> _uploadToDevFS(String localPath, String devFSPath) async {
    if (_devFSBaseUri == null || _httpAddress == null) return null;

    final file = File(localPath);
    if (!file.existsSync()) return null;

    final client = HttpClient();
    try {
      final request = await client.putUrl(_httpAddress!);
      request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
      request.headers.add('dev_fs_name', _devFSName);
      request.headers.add(
        'dev_fs_uri_b64',
        base64.encode(utf8.encode(devFSPath)),
      );
      final bytes = await file.readAsBytes();
      request.add(gzip.encode(bytes));
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == HttpStatus.ok) {
        return _devFSBaseUri!.resolve(devFSPath);
      }
      _warnDevFSUploadFailed(
        devFSPath,
        'HTTP ${response.statusCode} ${body.trim()}',
      );
      return null;
    } catch (e) {
      _warnDevFSUploadFailed(devFSPath, '$e');
      return null;
    } finally {
      client.close();
    }
  }

  /// Report a kernel or an asset the VM would not accept into its devFS.
  ///
  /// The detail belongs here rather than in the refusal the caller returns:
  /// this names which file and which HTTP step failed, where the refusal only
  /// has to say that the delivery did not happen.
  void _warnDevFSUploadFailed(String devFSPath, String detail) {
    _logger.warning({
      'message': 'devfs_upload_failed',
      'text':
          'Could not upload $devFSPath to the VM devFS: $detail. The '
          'delivery it was part of stops here rather than carrying on without '
          'it.',
      'path': devFSPath,
      'error': detail,
    });
  }

  /// Perform a hot reload by loading the given .dill file.
  ///
  /// Uploads the dill to the VM's devFS, then calls reloadSources
  /// with the devFS URI. This works for all platforms including
  /// physical iOS devices.
  Future<ApplyVerdict> hotReload(String dillPath) async {
    if (_httpAddress == null) {
      throw StateError(_noConnectionMessage);
    }

    try {
      return await _applyAndVerify(
        () async {
          // Upload the dill to the VM's in-memory devFS.
          const entryPath = 'main.dart.incremental.dill';
          final devFSUri = await _uploadToDevFS(dillPath, entryPath);
          if (devFSUri == null) return _devFSUploadRefusal;
          final result = await _service!.reloadSources(
            _mainIsolateId!,
            rootLibUri: devFSUri.toString(),
          );
          return result.success! ? null : 'the VM rejected the new kernel';
        },
        codeAfterDelivery: RunningCode.updated,
        // Everything above puts the code in the VM; this makes the app show
        // it. A failure here is a broken app running the new code, so it must
        // not come back as a refusal — see [_applyAndVerify].
        afterDelivery: (
          step: 'the rebuild that follows it',
          run: () async {
            await requireServiceExtension('ext.flutter.reassemble');
            await _service!.callServiceExtension(
              'ext.flutter.reassemble',
              isolateId: _mainIsolateId,
            );
          },
        ),
      );
    } catch (e, stack) {
      // Only the delivery half reaches here, so the app is running what it
      // was. With the stack: the interesting failures are unchecked nulls and
      // RPC shape mismatches, and "Null check operator used on a null value"
      // alone names neither the call nor the field.
      _logger.severe({
        'message': 'hot_reload_failed',
        'text':
            'Hot reload failed while delivering the new code, so the app '
            'keeps running the code it already had: $e\n$stack',
        'runningCode': RunningCode.unchanged.name,
        'error': '$e',
        'stack': '$stack',
      });
      return VerdictRefused('$e');
    }
  }

  /// Why a reload or a restart stops when the kernel could not be put into the
  /// devFS.
  ///
  /// The devFS *is* the delivery, and it is the only mechanism that reaches
  /// every target the tool supports: a phone, a simulator and a sandboxed
  /// macOS app all have a VM whose own filesystem they can read, and not one
  /// of them can read a path on this machine. Sending a `file://` URI instead
  /// when the upload fails produces a reload that cannot work anywhere but this
  /// machine, reported as whatever the VM makes of a path that is not there
  /// rather than as the upload failure it is. [_uploadToDevFS] has already
  /// logged which step failed.
  static const _devFSUploadRefusal =
      'the new kernel could not be uploaded to the app\'s devFS';

  /// Where uploaded assets live inside the devFS.
  ///
  /// A subdirectory rather than the devFS root, because the root also holds
  /// the kernel files [hotReload] and [hotRestart] upload, and the engine is
  /// about to be told to treat this directory as an asset bundle.
  static const _devFSAssetsDir = 'flutter_assets';

  /// Whether the engine has already been pointed at the devFS asset directory.
  ///
  /// One `setAssetBundlePath` per devFS is enough — the directory does not
  /// move — and each call rebuilds the engine's asset manager. Reset whenever
  /// the devFS is (re-)created, since the path it names goes with it.
  bool _assetDirectorySent = false;

  /// Whether paths on the target VM's filesystem are Windows-shaped. Set by
  /// the caller from the device; see `Device.usesWindowsPaths`.
  bool devicePathsAreWindows = Platform.isWindows;

  /// Make the running app show the rebuilt asset bundle.
  ///
  /// [changed] is the set of archive paths — bundle-relative, `/`-separated —
  /// whose bytes differ from what the app has cached. Each is read out of
  /// [assetDirectory], uploaded into the VM's devFS, and then evicted from the
  /// framework's bundle cache (and, for images, the image cache) so the next
  /// read comes from the new copy.
  ///
  /// The upload is what makes this work at all. The obvious cheaper move — tell
  /// the engine to read the build tree directly — fails on the platforms that
  /// matter: an APK's assets are not on this machine, a phone cannot see
  /// `bazel-out`, and a `flutter create` macOS app is sandboxed, so even a
  /// local engine is refused the directory ("Could not update asset
  /// directory"). A devFS lives inside the VM's own filesystem, which every
  /// one of them can read.
  ///
  /// Only the changed assets are uploaded. The engine keeps the app's original
  /// bundle behind the devFS directory as a fallback resolver
  /// (`RunConfiguration::InferFromSettings` builds it with
  /// `is_valid_after_asset_manager_change`), so everything not uploaded still
  /// resolves to what shipped. The corollary is that a *deleted* asset keeps
  /// resolving to the shipped copy until the next relaunch — devFS has no
  /// delete, and upstream has the same gap.
  Future<ApplyVerdict> reloadAssets(Set<String> changed) async {
    if (_httpAddress == null) {
      throw StateError(_noConnectionMessage);
    }
    final assetsDir = assetDirectory;
    if (assetsDir == null || assetsDir.isEmpty) {
      throw StateError('reloadAssets needs assetDirectory to be set');
    }

    // Set by the delivery below and read by the step after it — see
    // [hotRestart] for why these are not `late final`.
    var views = const <({String id, String? isolateId})>[];
    try {
      return await _applyAndVerify(
        () async {
          views = await _listViews();
          if (views.isEmpty) return 'the app has no Flutter view to deliver to';

          // Upload first: `setAssetBundlePath` opens the directory, so it has
          // to exist, and the first upload is what creates it.
          for (final archivePath in changed) {
            final local = p.joinAll([assetsDir, ...p.url.split(archivePath)]);
            // Absent means deleted from the bundle. Nothing to send; the evict
            // below still drops the app's cached copy.
            if (!File(local).existsSync()) continue;
            final uploaded = await _uploadToDevFS(
              local,
              '$_devFSAssetsDir/$archivePath',
            );
            if (uploaded == null) {
              // Reported by _uploadToDevFS. Failing here rather than carrying
              // on is the point: the upload *is* the delivery, so continuing
              // would evict the app's good copy and leave nothing in its place.
              return '$archivePath could not be uploaded to the app\'s devFS';
            }
          }
          return null;
        },
        // An asset push moves bytes, never Dart. Whatever happens from here on,
        // the app is running exactly the code it was.
        codeAfterDelivery: RunningCode.unchanged,
        // The bytes are in the devFS; this is what makes the app read them.
        // Failing partway leaves an app that may already be showing some of
        // them, which is why it cannot come back as a refusal.
        afterDelivery: (
          step: 'making the app re-read the changed assets',
          run: () async {
            if (!_assetDirectorySent) {
              final devFSAssets = _devFSBaseUri!
                  .resolve('$_devFSAssetsDir/')
                  .toFilePath(windows: devicePathsAreWindows);
              for (final view in views) {
                await _service!.callMethod(
                  '_flutter.setAssetBundlePath',
                  isolateId: view.isolateId,
                  args: {'viewId': view.id, 'assetDirectory': devFSAssets},
                );
              }
              _assetDirectorySent = true;
            }

            await requireServiceExtension('ext.flutter.evict');
            for (final archivePath in changed) {
              await _service!.callServiceExtension(
                'ext.flutter.evict',
                isolateId: _mainIsolateId,
                args: {'value': archivePath},
              );
            }

            // Evicting a font file drops the framework's copy of the bytes but
            // not the engine's registered font families, which are what text
            // actually renders from. Only the engine can rebuild those.
            if (touchesFonts(changed)) {
              await _service!.callMethod(
                '_flutter.reloadAssetFonts',
                isolateId: views.first.isolateId,
                args: {'viewId': views.first.id},
              );
            }

            await requireServiceExtension('ext.flutter.reassemble');
            await _service!.callServiceExtension(
              'ext.flutter.reassemble',
              isolateId: _mainIsolateId,
            );
          },
        ),
      );
    } catch (e, stack) {
      // Only the upload half reaches here. What the app is showing is not this
      // log's to say — the engine reads a devFS it has already been pointed at
      // on its next read, whether or not anything was evicted — so it reports
      // the step that did not run rather than a screen it cannot see.
      _logger.severe({
        'message': 'asset_reload_failed',
        'text':
            'Reloading assets failed while delivering them, so the '
            'evictions that make the app re-read its assets never ran: '
            '$e\n$stack',
        'runningCode': RunningCode.unchanged.name,
        'error': '$e',
        'stack': '$stack',
      });
      return VerdictRefused('$e');
    }
  }

  /// Why the main isolate cannot run Dart right now, or null when it can.
  ///
  /// Every `ext.*` call the tool makes is executed *by* the isolate, so one
  /// that is paused answers nothing and the request simply never returns.
  /// Under `--start-paused` that lasts until a human resumes it, and the first
  /// `app.*` command would take the HTTP control channel down with it — a
  /// driver waiting on a response that cannot arrive.
  ///
  /// Cheap enough to ask before every agent command: one `getIsolate` against
  /// a VM the tool is already connected to.
  Future<String?> pausedReason() async {
    if (_service == null || _mainIsolateId == null) return null;
    final Isolate isolate;
    try {
      isolate = await _callService((s) => s.getIsolate(_mainIsolateId!));
    } catch (_) {
      // Not answerable, so not an answer. Let the caller's own call fail with
      // whatever the real problem is rather than inventing a pause.
      return null;
    }
    return switch (isolate.pauseEvent?.kind) {
      EventKind.kPauseStart =>
        'the app is paused at the start of main() (--start-paused); resume it '
            'from a debugger first',
      EventKind.kPauseBreakpoint =>
        'the app is stopped at a breakpoint; resume it from your debugger '
            'first',
      EventKind.kPauseException =>
        'the app is stopped at an unhandled exception; resume it from your '
            'debugger first',
      EventKind.kPauseExit => 'the app\'s main isolate has exited',
      EventKind.kPauseInterrupted =>
        'the app is paused; resume it from your debugger first',
      _ => null,
    };
  }

  /// Wait until the main isolate reports it is holding at the start of
  /// `main()`, or [timeout] passes.
  ///
  /// A poll rather than a `Debug`-stream subscription because `PauseStart` is
  /// a *state*, not an event we can be sure to be listening for: the isolate
  /// reaches it while the launch is still discovering the VM service URI and
  /// dialling DDS, so the event is long gone by the time anyone could
  /// subscribe. The state is still there to read.
  ///
  /// Returns [StartPausedState.running] when the isolate is running instead —
  /// which is what an engine that ignored the launch switch looks like, and
  /// worth telling the user about rather than leaving them at a debugger
  /// waiting for an app that already ran.
  ///
  /// [StartPausedState.unknown] is the third state, and it exists because the
  /// poll can end without ever having read the isolate. In-deadline RPC
  /// failures really are the expected settling state, so they keep the poll
  /// going; but a run where *every* attempt failed has observed nothing, and
  /// folding that into `running` would have the launcher report the isolate as
  /// running on the strength of an RPC that never answered.
  Future<StartPausedState> waitUntilPausedAtStart({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_service == null || _mainIsolateId == null) {
      return StartPausedState.unknown;
    }
    final deadline = DateTime.now().add(timeout);
    var everRead = false;
    while (true) {
      try {
        final isolate = await _callService(
          (s) => s.getIsolate(_mainIsolateId!),
        );
        everRead = true;
        if (isolate.pauseEvent?.kind == EventKind.kPauseStart) {
          return StartPausedState.pausedAtStart;
        }
      } catch (_) {
        // A connection still settling; the deadline below is the bound, and
        // `everRead` is what keeps a poll that only ever failed from being
        // reported as an isolate seen running.
      }
      if (!DateTime.now().isBefore(deadline)) {
        return everRead ? StartPausedState.running : StartPausedState.unknown;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Wait until the Flutter framework has rendered its first frame.
  ///
  /// Returns whether it did, within [timeout]. The answer doubles as "is this
  /// app drivable yet": a first frame means the framework is up and the app's
  /// extensions — the `ext.rules_flutter.*` agent surface among them — are
  /// registered.
  ///
  /// Two sources, raced, because neither answers for the other's case:
  ///
  ///   * `didSendFirstFrameEvent` is a latched query, so it is the only one
  ///     that can report a frame built before anyone was listening — an
  ///     attach, or a re-dial onto a running app.
  ///   * `Flutter.FirstFrame` is pushed, so it is the only one that arrives
  ///     while the VM is answering no requests at all. That is not a corner: a
  ///     physical iPhone can answer nothing at all — not this query, not
  ///     `getVersion` — for a minute after `app.started`, because a debug app
  ///     there JITs through the debugger, trapping on every executable page it
  ///     allocates (see `IOSDevice.applyTimeout`).
  ///
  /// This is why the wait is not a bare poll. Against a VM in that state a poll
  /// is one call that never returns, and a loop built on it cannot honour its
  /// own deadline.
  ///
  /// Built and sent, not rasterized. `didSendFirstFrameRasterizedEvent` is the
  /// neighbouring flag and the wrong question: it reports the *engine* putting
  /// pixels on a display, so it stays false indefinitely on a device that is
  /// not showing them. An app whose framework is up is drivable whether or not
  /// anyone is looking at it, and this is the flag that says so.
  ///
  /// [until], when given, ends the wait early with false: the caller has
  /// stopped needing an answer, and the budget above may be minutes. A run
  /// tearing down passes it, because the timer this would otherwise sit on
  /// keeps the process alive long after the thing it was waiting for stopped
  /// mattering.
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
    Future<void>? until,
  }) async {
    final service = _service;
    final isolateId = _mainIsolateId;
    if (service == null || isolateId == null) return false;

    final rendered = Completer<bool>();
    void answer(bool value) {
      if (!rendered.isCompleted) rendered.complete(value);
    }

    // Subscribed before the query is asked, so a frame drawn between the two
    // is caught by one or the other rather than falling between them.
    final frames = service.onExtensionEvent.listen((e) {
      if (e.extensionKind == 'Flutter.FirstFrame' ||
          e.extensionKind == 'Flutter.FirstFrameRasterized') {
        answer(true);
      }
    });

    // Asked repeatedly, because on web it is the only one of the two that can
    // answer at all. `Flutter.FirstFrame` is posted from the framework's
    // frame-*timings* callback, and the web engine hands timings over only from
    // inside `submitTimings` — while rasterizing a frame. An app that paints
    // its startup frames and then sits still never rasterizes again, so the
    // batch holding the first frame's timing is never flushed and the event is
    // never posted until something makes the app draw again.
    //
    // The query does not depend on any of that. The framework clears
    // `_needToReportFirstFrame` at the end of `drawFrame`, before the timings
    // callback exists, so `enabled: true` means "a frame was built and sent to
    // the engine" — the thing being waited for. Asking it once is not enough:
    // on web the first ask lands in the window where the framework has not
    // registered it yet and answers `-32601`, and a wait that stopped there
    // would fall through to an event that is not coming.
    Object? queryFailure;
    // Read by the poll loop as its own stop signal. `rendered.isCompleted`
    // alone is not one: the loop can still be inside an in-flight call when the
    // wait returns, and would then write `queryFailure` that nothing will ever
    // read again.
    var settled = false;

    Future<void> pollForFirstFrame() async {
      while (!settled && !rendered.isCompleted) {
        try {
          final resp = await _callService(
            (s) => s.callServiceExtension(
              'ext.flutter.didSendFirstFrameEvent',
              isolateId: isolateId,
            ),
          );
          // A false is the boot sequence working: the framework is up and has
          // not painted yet, so ask again.
          if (resp.json?['enabled'] == 'true') {
            answer(true);
            return;
          }
        } catch (e) {
          if (settled) return;
          // `-32601` is the framework not having registered the extension yet,
          // which is the boot sequence working; ask again.
          if (e is! RPCError || e.code != _rpcMethodNotFound) {
            // Everything else is kept rather than dropped, and kept rather than
            // answered: the event may still arrive and is the better outcome,
            // but if nothing does, this is why — and a caller reading "had not
            // rendered" needs the real fault instead. Caught as `Object`
            // because this runs unawaited: anything escaping here is an
            // unhandled async error that takes the run with it.
            queryFailure = e;
            return;
          }
        }
        if (settled || rendered.isCompleted) return;
        await Future<void>.delayed(_firstFramePollInterval);
      }
    }

    unawaited(pollForFirstFrame());

    final abandon = until?.then((_) => answer(false));

    try {
      final painted = await rendered.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      final failure = queryFailure;
      if (!painted && failure != null) throw failure;
      return painted;
    } finally {
      // Settled explicitly, because `timeout` completes the future it returns
      // and leaves this one pending for good. The poll loop reads it to know
      // it is finished, so without this it re-arms its timer forever and the
      // process never exits.
      settled = true;
      answer(false);
      await frames.cancel();
      abandon?.ignore();
    }
  }

  /// Capture a Flutter widget tree screenshot as raw PNG bytes.
  ///
  /// Uses the `_flutter.screenshot` VM service extension. Waits for the
  /// first frame to be rasterized before capturing.
  Future<List<int>> screenshotBytes() async {
    if (_service == null || _mainIsolateId == null) {
      throw StateError(_noConnectionMessage);
    }

    await waitForFirstFrame();

    final response = await _callService(
      (s) => s.callServiceExtension(
        '_flutter.screenshot',
        isolateId: _mainIsolateId,
      ),
    );

    final data = response.json?['screenshot'] as String?;
    if (data == null) {
      throw StateError('_flutter.screenshot returned no data');
    }

    return base64.decode(data);
  }

  /// Capture a screenshot and save to [outputPath].
  Future<void> screenshot(String outputPath) async {
    final bytes = await screenshotBytes();
    await File(outputPath).writeAsBytes(bytes);
  }

  /// Perform a hot restart — re-run `main()` in a fresh isolate.
  ///
  /// Unlike [hotReload] (which swaps code into the running isolate via
  /// `reloadSources`, so `main()` does NOT re-execute), this uses the Flutter
  /// engine's `_flutter.runInView` to spawn a new root isolate that runs
  /// `main()` from the new kernel — matching `flutter run`'s capital-R restart.
  /// Framework + app state is reset and `main()`-level changes take effect.
  ///
  /// One `runInView` per Flutter view, and a multi-window app has several. The
  /// first one is the delivery: after it the app is running the new `main()`,
  /// however the rest of the loop goes, so the views that follow are
  /// [_applyAndVerify]'s post-delivery half. Restarting them all under one
  /// `catch` would make a second view failing come back as a refusal — the
  /// verdict meaning nothing landed — while the first runs the new code.
  Future<ApplyVerdict> hotRestart(String dillPath) async {
    if (_httpAddress == null) {
      throw StateError(_noConnectionMessage);
    }

    // Set by the delivery below and read by the step after it. Plain fields
    // rather than `late final` because [_applyAndVerify] may replay the whole
    // sequence on a fresh connection, which assigns them a second time.
    var views = const <({String id, String? isolateId})>[];
    var mainUri = '';
    try {
      final verdict = await _applyAndVerify(
        () async {
          // Upload the full kernel to devFS as the new main.
          const entryPath = 'main.dart.dill';
          final devFSUri = await _uploadToDevFS(dillPath, entryPath);
          if (devFSUri == null) return _devFSUploadRefusal;
          mainUri = devFSUri.toString();

          views = await _listViews();
          if (views.isEmpty) return 'the app has no Flutter view to restart';
          await _restartView(views.first, mainUri);
          return null;
        },
        codeAfterDelivery: RunningCode.updated,
        afterDelivery: (
          step: 'restarting the app\'s remaining views',
          run: () async {
            for (final view in views.skip(1)) {
              await _restartView(view, mainUri);
            }
          },
        ),
      );
      // runInView rotates the root isolate; re-resolve so subsequent
      // reloads/screenshots target the new live isolate.
      await _refreshMainIsolate();
      return verdict;
    } catch (e, stack) {
      // Only the delivery half reaches here: the loop's later views answer
      // through [_applyAndVerify], and [_refreshMainIsolate] swallows its own
      // failures. So no view had taken the new kernel when this ran.
      _logger.severe({
        'message': 'hot_restart_failed',
        'text':
            'Hot restart failed before any view could take the new kernel, '
            'so the app was not restarted and keeps running the code it '
            'already had: $e\n$stack',
        'runningCode': RunningCode.unchanged.name,
        'error': '$e',
        'stack': '$stack',
      });
      return VerdictRefused('$e');
    }
  }

  /// Run [mainUri] in [view], from a fresh root isolate.
  ///
  /// The engine's runInView interacts with non-thread-safe dart APIs on the UI
  /// thread, so a paused isolate would block it — resume first.
  Future<void> _restartView(
    ({String id, String? isolateId}) view,
    String mainUri,
  ) async {
    final isolateId = view.isolateId;
    if (isolateId != null) await _resumeIfPaused(isolateId);
    await _service!.callMethod(
      '_flutter.runInView',
      args: {
        'viewId': view.id,
        'mainScript': mainUri,
        'assetDirectory': assetDirectory ?? '',
      },
    );
  }

  /// The Flutter views (`_flutter.listViews`) with their UI isolate ids.
  Future<List<({String id, String? isolateId})>> _listViews() async {
    final resp = await _callService((s) => s.callMethod('_flutter.listViews'));
    final views = (resp.json?['views'] as List?) ?? const [];
    return [
      for (final v in views)
        if ((v as Map)['type'] == 'FlutterView')
          (
            id: v['id'] as String,
            isolateId: (v['isolate'] as Map?)?['id'] as String?,
          ),
    ];
  }

  /// Resume [isolateId] if it is paused (e.g. PauseStart), so runInView can run.
  ///
  /// Failures are logged rather than raised, and rather than dropped. Not
  /// raised because an isolate that rotated out between [_listViews] and here
  /// is gone rather than stuck, and `runInView` is about to supply the view
  /// with a fresh one — turning that into a failed restart would be inventing
  /// one. Not dropped because the other failure this can hide is a resume that
  /// was needed and did not happen, and its symptom lands somewhere that never
  /// names it: the `runInView` on the next line touches non-thread-safe dart
  /// APIs on the UI thread, so a still-paused isolate blocks it, and the
  /// restart hangs with nothing said about the resume that failed first.
  Future<void> _resumeIfPaused(String isolateId) async {
    try {
      final isolate = await _service!.getIsolate(isolateId);
      final kind = isolate.pauseEvent?.kind;
      if (kind != null && kind.startsWith('Pause')) {
        await _service!.resume(isolateId);
      }
    } catch (e, stack) {
      _logger.warning({
        'message': 'resume_before_restart_failed',
        'text':
            'Could not resume isolate $isolateId before restarting its '
            'view: $e. If the isolate was paused and is still paused, the '
            'restart that follows will not return.',
        'isolateId': isolateId,
        'error': '$e',
        'stack': '$stack',
      });
    }
  }

  /// Re-resolve [_mainIsolateId] after a restart rotated the root isolate.
  ///
  /// The barrier for the rotation we *initiate*: `_flutter.runInView` may
  /// answer before the `IsolateStart` reaches [_onIsolateEvent], and the
  /// caller's next RPC comes straight after. Awaiting this makes the new id
  /// certain rather than merely imminent. Unsolicited rotations have no such
  /// point to hang a barrier on, which is what the stream is for.
  Future<void> _refreshMainIsolate() async {
    try {
      final vm = await _callService((s) => s.getVM());
      final isolates = vm.isolates ?? const <IsolateRef>[];
      for (final ref in isolates) {
        if (ref.name == 'main') {
          _setMainIsolate(ref.id);
          return;
        }
      }
      _setMainIsolate(isolates.firstOrNull?.id ?? _mainIsolateId);
    } catch (e, stack) {
      // Logged, not raised: the `Isolate` stream adopts rotations too, so this
      // barrier failing leaves the id merely unconfirmed rather than certainly
      // stale, and the restart that called it has already succeeded.
      //
      // Worth saying out loud all the same, because the state it fails to
      // leave behind is not a degraded one. A client still holding a rotated
      // isolate's id gets `Sentinel(Collected)` / `Unrecognized isolateId`
      // from every later RPC, indefinitely — so if the stream does not cover
      // for this, every symptom that follows points at the app.
      _logger.warning({
        'message': 'main_isolate_refresh_failed',
        'text':
            'Could not re-read the main isolate after a restart: $e. The '
            'isolate stream is the remaining route to the new id; until one '
            'arrives, calls may name an isolate that no longer exists.',
        'error': '$e',
        'stack': '$stack',
      });
    }
  }

  /// Call a service extension on the main isolate and return the parsed
  /// JSON response. Callers that don't need the payload simply discard it.
  Future<Map<String, dynamic>?> callServiceExtension(
    String method, {
    Map<String, String>? args,
  }) async {
    if (_service == null || _mainIsolateId == null) {
      throw StateError(_noConnectionMessage);
    }
    final response = await _callService(
      (s) => s.callServiceExtension(
        method,
        isolateId: _mainIsolateId,
        args: args,
      ),
    );
    return response.json;
  }

  /// Toggle the performance overlay.
  Future<bool> togglePerformanceOverlay() async =>
      _toggleExtension('ext.flutter.showPerformanceOverlay');

  /// Toggle the widget inspector.
  Future<bool> toggleWidgetInspector() async =>
      _toggleExtension('ext.flutter.inspector.show');

  Future<bool> _toggleExtension(String method) async {
    if (_service == null || _mainIsolateId == null) {
      throw StateError(_noConnectionMessage);
    }
    try {
      final current = await _callService(
        (s) => s.callServiceExtension(
          method,
          isolateId: _mainIsolateId,
        ),
      );
      final enabled = current.json?['enabled'] == 'true';
      await _callService(
        (s) => s.callServiceExtension(
          method,
          isolateId: _mainIsolateId,
          args: {'enabled': (!enabled).toString()},
        ),
      );
      return !enabled;
    } catch (e) {
      _logger.warning({
        'message': 'toggle_extension_failed',
        'text':
            'Could not toggle $method: $e. Whatever it controls is left as '
            'it was.',
        'extension': method,
        'error': '$e',
      });
      return false;
    }
  }

  /// Run a VM-service operation, transparently reconnecting and replaying
  /// it once if the underlying connection has been disposed.
  ///
  /// `package:vm_service` auto-disposes its `VmService` when the underlying
  /// WebSocket closes (idle timeout, hot restart rotating the VM, DDS
  /// tunnel hiccup). The HTTP transport on the same URI typically stays
  /// alive, so re-running [connect] — which rebuilds `_mainIsolateId` and
  /// the devFS — recovers without consumer involvement.
  ///
  /// [operation] must be self-contained: on a disposed-connection error the
  /// *entire* closure is re-invoked against a freshly-built `VmService` and
  /// devFS. That atomic replay is what makes the multi-step `hotReload` /
  /// `hotRestart` sequences (devFS upload → `reloadSources` → reassemble)
  /// safe — the retry re-uploads to the fresh devFS rather than reloading
  /// against a half-built one. The reconnect is never mid-sequence.
  ///
  /// The re-dial goes through [_reconnect] rather than straight to [connect]
  /// because it is not the only one: [_watchForClose] sees the same dropped
  /// socket this catch does. Naming the connection the operation ran on is what
  /// lets a reconnect that already happened be recognised as one, instead of a
  /// healthy socket being discarded to dial for a second.
  Future<T> _withReconnect<T>(Future<T> Function() operation) async {
    if (_httpAddress == null) {
      throw StateError(_noConnectionMessage);
    }
    if (_service == null) {
      await _reconnect(_connectAttempt);
    }
    final attempt = _connectAttempt;
    try {
      return await operation();
    } on RPCError catch (e) {
      if (!_isConnectionDisposed(e)) rethrow;
      await _reconnect(attempt);
      return await operation();
    }
  }

  /// Run a single VM-service RPC with transparent reconnect (see
  /// [_withReconnect]). The degenerate single-step case.
  Future<T> _callService<T>(Future<T> Function(VmService) rpc) =>
      _withReconnect(() => rpc(_service!));

  /// Whether [e] indicates the WebSocket transport has been closed and
  /// `package:vm_service` has auto-disposed its [VmService]. Subsequent
  /// RPCs surface as `RPCError(-32000, "Service connection disposed")`.
  bool _isConnectionDisposed(RPCError e) =>
      e.code == -32000 && e.message.contains('Service connection disposed');

  /// Forget the run of short-lived connections counted so far.
  ///
  /// Called from the two teardowns and from nowhere else — emphatically not
  /// from [connect], which every re-dial goes through, and which would
  /// therefore reset the count on its way to the very close that increments it,
  /// leaving [flapLimit] unreachable. A teardown is the one place a caller says
  /// it is starting over: the relauncher resetting a wedged socket, the apply
  /// timeout dropping one nothing is coming back on.
  void _forgetFlaps() => _flaps = 0;

  /// Disconnect from the VM service.
  ///
  /// Records the hang-up first, so the dispose below reads as a socket this
  /// end closed rather than one the app took away with it — see [_hungUp].
  ///
  /// The connect attempt moves on for a second reason: a re-dial can be in
  /// flight when a teardown arrives, and a dial that lands afterwards would
  /// otherwise publish itself into a client that has been shut down. That
  /// socket is never closed by anyone, and an open socket is what keeps the
  /// process alive after the run has ended.
  Future<void> disconnect() async {
    _hungUp = true;
    _connectAttempt++;
    _forgetFlaps();
    if (_devFSBaseUri != null && _service != null) {
      try {
        await _service!
            .callServiceExtension('_deleteDevFS', args: {'fsName': _devFSName})
            // Bounded because this is a question put to the app, and an app
            // that has stopped answering never fails the call — it just never
            // returns, which the `catch` below cannot see. Reported from
            // inside `onTimeout` for the same reason: letting a
            // TimeoutException fall into that catch would file an expired
            // bound alongside ordinary RPC errors and silence it.
            .then<void>((_) {})
            .timeout(
              disconnectTimeout,
              onTimeout: () {
                _logger.warning({
                  'message': 'devfs_delete_timed_out',
                  'text':
                      'The app did not acknowledge deleting its devFS '
                      '($_devFSName) within '
                      '${disconnectTimeout.inMilliseconds}ms, so the rest of the '
                      'shutdown went ahead without it. The devFS goes with the app '
                      'when it exits; nothing is left behind on this machine.',
                  'fsName': _devFSName,
                  'timeoutMs': disconnectTimeout.inMilliseconds,
                });
              },
            );
      } catch (e, stack) {
        // Caught, and caught broadly, for a reason this teardown cannot do
        // without: everything below closes something, and an error escaping
        // here would skip all of it — including the `dispose()` that closes
        // the socket, which is what keeps this process alive after the run has
        // ended (see this method's own doc). So the shutdown goes on.
        //
        // But it says what it dropped. The devFS goes with the app when it
        // exits, so failing to delete one costs nothing on this machine; the
        // error is still the only evidence of *why* the app would not take a
        // routine RPC.
        _logger.warning({
          'message': 'devfs_delete_failed',
          'text':
              'Deleting the app\'s devFS ($_devFSName) failed: $e. The '
              'rest of the shutdown went ahead. The devFS goes with the app '
              'when it exits; nothing is left behind on this machine.',
          'fsName': _devFSName,
          'error': '$e',
          'stack': '$stack',
        });
      }
    }
    await _isolateEvents?.cancel();
    _isolateEvents = null;
    await _service?.dispose();
    _service = null;
    _setMainIsolate(null);
    _devFSBaseUri = null;
  }

  /// Hang up for good: [disconnect], and close every door to a re-dial.
  ///
  /// What a teardown calls, and the only thing that makes a close final. The
  /// ordinary closes are not: [disconnect] and [forceDisconnect] both drop a
  /// socket the *run* still wants back — the relauncher swapping a process, a
  /// wedged apply reset so the next command can dial — so [_reconnect] has to
  /// stay open to them, and every consumer that reaches the VM goes through it.
  ///
  /// Without this, an RPC still in flight when teardown lands — the first-frame
  /// poll, which runs unawaited — comes back to a client with no service, dials
  /// a replacement, and publishes a WebSocket nothing owns and nothing will
  /// ever close. A live socket keeps the Dart VM's event loop running, so the
  /// process stays up having reported a clean shutdown.
  ///
  /// A consumer that asks afterwards gets a [StateError] naming this, the way
  /// one asking after the app was reported [gone] does; `VmServiceAppInstance`
  /// already renders that as a failed apply rather than letting it escape.
  Future<void> retire() async {
    _retired = true;
    await disconnect();
  }

  /// Aggressively close the connection without trying to clean up devFS.
  ///
  /// Used when the connection is hung — calling `_deleteDevFS` over a
  /// wedged WebSocket would itself hang. Just dispose the underlying
  /// VmService (closes the WebSocket) and null out our state. The next
  /// call requiring a connection should reconnect via [connect].
  ///
  /// Records the hang-up, and moves the attempt on, for the same two reasons
  /// [disconnect] does.
  Future<void> forceDisconnect() async {
    _hungUp = true;
    _connectAttempt++;
    _forgetFlaps();
    // Both broad and both logged, for [disconnect]'s reason: this is the
    // teardown reached *because* the connection is already wedged, so a throw
    // is unremarkable — but it is the only account of what the wedged socket
    // did when asked to close, and the caller has no other way to see it.
    try {
      await _isolateEvents?.cancel();
    } catch (e, stack) {
      _logger.warning({
        'message': 'isolate_stream_cancel_failed',
        'text':
            'Cancelling the isolate event subscription during a forced '
            'disconnect failed: $e. The disconnect continued.',
        'error': '$e',
        'stack': '$stack',
      });
    }
    _isolateEvents = null;
    try {
      await _service?.dispose();
    } catch (e, stack) {
      _logger.warning({
        'message': 'vm_service_dispose_failed',
        'text':
            'Disposing the VM service connection during a forced '
            'disconnect failed: $e. The connection is dropped regardless; if '
            'the socket outlived this, it is what holds the process open.',
        'error': '$e',
        'stack': '$stack',
      });
    }
    _service = null;
    _setMainIsolate(null);
    _devFSBaseUri = null;
  }

  /// Whether a connection is published — which is not quite "usable".
  ///
  /// True from the moment the socket is up, which is *before* the handshake
  /// that follows it (`getVM`, two `streamListen`s, a devFS). A [connect] that
  /// throws partway through that sequence leaves the service published, so this
  /// reads true for a client whose connect its caller was told had failed: a
  /// service disposed under the client's first `getVM` throws
  /// `RPCError(-32000)` out of [connect] and leaves this `true`.
  /// A dial that never completed is the other case and is clean — nothing was
  /// published, so this stays false.
  ///
  /// Left as it is because that window belongs to the caller, not to a
  /// background repair. A throwing [connect] is the retry signal — it is
  /// documented as one on [connect], and both real callers act on it: `attach`
  /// turns it into a `DevToolException` and stops, and the device launcher
  /// builds a *fresh* client for each of its five attempts. Neither reads this
  /// getter, and nothing else in the tool does either: every production
  /// reference is a comment, and the only callers are tests reading internal
  /// state through it.
  ///
  /// So do not reach for it as a guard. The state it reports has no bearing on
  /// whether the next RPC will work — a connection can be lost between the two
  /// — and the calls that must answer for a missing one do it from their own
  /// guards, which carry the reason ([_noConnectionMessage]).
  bool get isConnected => _service != null;
}
