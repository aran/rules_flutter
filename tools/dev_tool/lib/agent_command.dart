/// AI-agent command surface registered on [CommandRunner].
///
/// Exposes `app.*` for an external agent (e.g. Claude Code) to drive a
/// running Flutter app over the dev_tool's HTTP control channel. Most
/// commands proxy to `ext.rules_flutter.*` service extensions the app
/// registers before `main()` — from the engine's plugin-registrant hook on
/// native, and from the dev tool's synthetic entrypoint on web (see
/// `flutter/private/agent_extensions/agent.dart`). `app.dumpWidgetTree`
/// goes to the built-in inspector RPC and works against any debug Flutter
/// app without app-side cooperation.
library;

import 'dart:async';

import 'package:vm_service/vm_service.dart';

import 'command_failure.dart';
import 'command_runner.dart';
import 'session.dart';
import 'vm_service_client.dart';

/// Register the `app.*` AI-agent commands on [cr].
///
/// [dispatchMargin] is how far past the app's own deadline a dispatched call is
/// waited for, and [pauseReadBound] how long the isolate's pause state is
/// waited for; see [_dispatchMargin] and [_pauseReadBound], which are what
/// production passes. A test covering either bound expiring names a small one
/// rather than spending the real one — the same knob
/// `VmServiceClient.serviceExtensionTimeout` exists for.
void setUpAgentCommands(
  CommandRunner cr,
  DeviceSession? Function(String? appId) findSession, {
  Duration dispatchMargin = _dispatchMargin,
  Duration pauseReadBound = _pauseReadBound,
}) {
  cr.register(
    'app.dumpWidgetTree',
    (params) => _call(
      findSession,
      params,
      'ext.flutter.inspector.getRootWidgetTree',
      dispatchMargin: dispatchMargin,
      pauseReadBound: pauseReadBound,
      extraArgs: const {
        'groupName': 'rules_flutter_agent',
        'isSummaryTree': 'false',
        'withPreviews': 'true',
      },
    ),
  );
  // `app.settle` waits for the app to go idle and answers; it is the step every
  // other command here takes internally, exposed because the screenshot
  // endpoints need it as a step of their own and a caller driving the app
  // sometimes needs it between two of theirs.
  cr.register(
    'app.settle',
    (params) => _call(
      findSession,
      params,
      'ext.rules_flutter.settle',
      dispatchMargin: dispatchMargin,
      pauseReadBound: pauseReadBound,
    ),
  );
  for (final method in const [
    'app.tap',
    'app.longPress',
    'app.doubleTap',
    'app.drag',
    'app.scrollIntoView',
    'app.enterText',
    'app.getText',
    'app.getRect',
    'app.waitFor',
    'app.waitForAbsent',
    'app.pageBack',
  ]) {
    final extensionMethod =
        'ext.rules_flutter.${method.substring('app.'.length)}';
    cr.register(
      method,
      (params) => _call(
        findSession,
        params,
        extensionMethod,
        dispatchMargin: dispatchMargin,
        pauseReadBound: pauseReadBound,
      ),
    );
  }
}

/// Offer `app.buildInfo`, which only some runs can answer.
///
/// Separate from [setUpAgentCommands] because it is conditional, not because
/// it is different in kind: `flutter_compile_kernel` bakes the record in as a
/// dart define on `-c dbg` native builds only, so a web run — or a profile run
/// — has no record to answer with. `app.setViewport` is the pattern: register
/// where the thing that makes it answerable is known to exist.
///
/// It must not wait for the Flutter binding. It answers from a compile-time
/// constant, and the caller that needs it most — `flutter_bazel attach`,
/// resolving which build tree backs the app it just connected to — asks before
/// the app has necessarily reached `runApp`.
void registerBuildInfoCommand(
  CommandRunner cr,
  DeviceSession? Function(String? appId) findSession, {
  Duration dispatchMargin = _dispatchMargin,
  Duration pauseReadBound = _pauseReadBound,
}) {
  cr.register(
    'app.buildInfo',
    (params) => _call(
      findSession,
      params,
      'ext.rules_flutter.buildInfo',
      dispatchMargin: dispatchMargin,
      pauseReadBound: pauseReadBound,
      waitForBinding: false,
    ),
  );
}

/// How long a command waits for a session that has no VM service yet.
///
/// Sized for a cold Chrome: launching the browser, loading the page and pulling
/// the DDC modules across all happen after `app.started`. A run that opted out
/// of the VM service entirely (`--allow-no-vm-service`) spends this before
/// saying so.
const _debugConnectTimeout = Duration(seconds: 60);

/// How long a dispatched extension call is waited for *beyond* the deadline
/// the app itself was given.
///
/// The bound strictly exceeds the app's own promised deadline, so it can never
/// fire on an app that is answering as documented. When it fires, the app is
/// not answering.
const _dispatchMargin = Duration(seconds: 30);

/// The app-side deadline assumed when the caller names no `timeoutMs`.
///
/// The largest default any handler applies to itself: `_settle`'s 10s in
/// `agent_extensions/agent.dart`. Callers that ask for longer say so, and
/// [_dispatchBound] adds the margin to whatever they asked for.
const _defaultAppDeadline = Duration(seconds: 10);

/// How long the isolate's pause state is waited for.
///
/// `pausedReason` is one `getIsolate` against a VM the tool is already
/// connected to, served by the VM itself rather than by the app's isolate — so
/// even a paused app answers it promptly. Bounded all the same: it is a read
/// over the same socket the dispatch uses, and a socket that has gone silent
/// does not raise the `RPCError` that `_withReconnect` recovers from. An
/// unbounded read here would wedge the command pool.
const _pauseReadBound = Duration(seconds: 10);

/// The extension whose presence means the Flutter binding exists.
///
/// Registered by `BindingBase.initServiceExtensions`, so it appears exactly
/// when `WidgetsFlutterBinding.ensureInitialized()` runs — which is what every
/// handler in the agent needs and what the inspector RPCs are registered
/// alongside. The agent's own extensions are registered *earlier* than this on
/// web (pre-`bootstrapEngine`, deliberately, so the startup window is covered),
/// so their presence alone does not mean the app can answer: dispatching in
/// between gets `Binding has not yet been initialized` from inside the handler.
const _bindingExtension = 'ext.flutter.reassemble';

/// How long to wait for [params]' dispatch: the deadline the app was given,
/// plus the margin that keeps this bound off a legitimately slow answer.
///
/// `timeoutMs` is the one parameter every handler that can wait reads, and it
/// is passed through to the app untouched — so it is exactly the promise the
/// app made about this call.
Duration _dispatchBound(Map<String, dynamic> params, Duration margin) {
  final asked = int.tryParse('${params['timeoutMs']}');
  return (asked == null ? _defaultAppDeadline : Duration(milliseconds: asked)) +
      margin;
}

/// What the app's isolate looked like when a dispatch gave up on it.
///
/// Three states, kept apart, because they send the reader to three different
/// places: a pause names itself and a debugger resumes it; no pause means the
/// app was running and simply never returned from the handler; and a read that
/// did not answer either says the VM service is the problem, not the app.
Future<String> _pauseNote(VmServiceClient client, Duration bound) async {
  try {
    final reason = await client.pausedReason().timeout(bound);
    return reason == null
        ? 'Its isolate reported no pause, so the app was running and the '
              'handler never returned — a backgrounded app stops producing '
              'frames, and any unbounded wait for one never ends.'
        : 'Its isolate is paused: $reason';
  } on TimeoutException {
    return 'Its isolate\'s pause state could not be read within '
        '${bound.inSeconds}s either, so the VM service connection '
        'is no longer answering.';
  }
}

/// Resolve the session, invoke [extensionMethod], strip framework noise
/// from the response, and return the agent payload. The extension itself
/// validates required params; callers pass everything-but-`appId` through
/// untouched (plus any [extraArgs] for inspector RPCs).
///
/// [waitForBinding] is true for every handler that touches the widget tree:
/// those run against the Flutter binding, and dispatching before it exists
/// returns `Binding has not yet been initialized` from inside the handler.
/// Set it false only for an extension that answers without the binding —
/// `ext.rules_flutter.buildInfo` reads a compile-time constant — where
/// waiting would trade an available answer for a needless stall.
Future<Map<String, dynamic>> _call(
  DeviceSession? Function(String?) findSession,
  Map<String, dynamic> params,
  String extensionMethod, {
  required Duration dispatchMargin,
  required Duration pauseReadBound,
  Map<String, String> extraArgs = const {},
  bool waitForBinding = true,
}) async {
  final session = findSession(params['appId'] as String?);
  if (session == null) {
    throw CommandFailure.notFound('unknown appId: ${params['appId']}');
  }
  var vm = session.vmClient;
  if (vm == null) {
    // Only web ever gets here. A native session owns its VM service from the
    // moment it exists; a browser's is handed over by DWDS when the page
    // connects, which is after `app.started` — so an agent acting on that event
    // finds the field null through no fault of its own. `debugReady` is the
    // session's own signal for exactly this, and waiting on it is what the run
    // is already doing to decide where to point DevTools.
    await session.debugReady.timeout(_debugConnectTimeout, onTimeout: () {});
    vm = session.vmClient;
  }
  if (vm == null) {
    throw CommandFailure.failed('no VM service for ${session.appId}');
  }
  final client = vm;

  /// The pause that will stop this command from ever being answered, if any.
  ///
  /// Asked rather than discovered by waiting: the extension runs *on* the
  /// app's isolate, so a paused one never answers and the request hangs for as
  /// long as the pause lasts, taking the whole HTTP control channel with it.
  Future<CommandFailure?> pauseError() async => switch (await client
      .pausedReason()
      .timeout(pauseReadBound, onTimeout: () => null)) {
    final reason? => CommandFailure.failed(
      '$extensionMethod cannot run: $reason',
    ),
    _ => null,
  };

  // A run that was started paused is answered without waiting, because nothing
  // is going to change until a human resumes it — including the first frame
  // the branch below waits for, which is why these are alternatives rather
  // than one after the other.
  if (session.device.startPaused) {
    if (await pauseError() case final error?) throw error;
  } else {
    // Otherwise the app is on its way to a first frame, and until it arrives
    // there is nothing here to act on: no widget tree, and on a physical
    // device a VM service that answers nothing at all for a minute or more
    // after `app.started`, during which the reads below expire and report a
    // quiet socket for an app that is merely still starting. See
    // [DeviceSession.drivable].
    //
    // Unbounded on purpose. The gate always settles, and the budget that
    // settles it belongs to the device rather than to this call: a wait capped
    // here would abandon an iPhone that was starting exactly as fast as iPhones
    // start.
    await session.drivable.whenReady;
    if (!session.drivable.isReady) {
      throw CommandFailure.failed(session.drivable.unavailableReason!);
    }
  }

  // `PauseStart` means two different things on web, and only one of them was
  // just ruled out. DWDS reports the isolate as paused-at-start from the moment
  // it exists until it releases `main()` — which it withholds until its
  // injected client connects (`injector.dart:139-164`), seconds after
  // `app.started`. That window is not a pause to report, it is a startup to
  // wait out, and until it closes nothing is registered: not the agent surface,
  // not the framework's own `ext.flutter.*`. A hot restart reopens it.
  //
  // Both are waited for. The binding is what the handlers run against, and the
  // named extension is what answers the call; on web those arrive in that order
  // with app code in between, on native they are already there together.
  for (final rpc in {
    extensionMethod,
    if (waitForBinding) _bindingExtension,
  }) {
    // Two different failures, kept apart. `false` is the app answering that it
    // has not registered the extension. A throw is the question not getting
    // through — the seed read this waits on propagates one now rather than
    // reporting a timeout — and saying "the app never brought it up" on the
    // strength of an RPC that failed names the wrong cause. Both become a
    // [CommandFailure], which is the one way this surface says no.
    try {
      if (await client.waitForServiceExtension(rpc)) continue;
      throw CommandFailure.failed(
        '$rpc is not registered. The app never brought it up — if '
        'the run is --start-paused, resume it from a debugger first.',
      );
    } on RPCError catch (e) {
      throw CommandFailure.failed(
        'could not tell whether $rpc is registered: '
        '${e.details ?? e.message}',
      );
    } on TimeoutException catch (e) {
      // The read that answers this question expiring, which is not the same as
      // the app never registering — that one comes back as `false` above. A
      // socket that has gone quiet without closing is what gets here.
      throw CommandFailure.failed(
        'could not tell whether $rpc is registered: the VM service '
        'did not answer within ${e.duration?.inSeconds}s',
      );
    }
  }

  // Read again now the app is up: a breakpoint or an unhandled exception can
  // have stopped it since, and those hang the dispatch just the same.
  if (await pauseError() case final error?) throw error;
  final args = <String, String>{
    for (final entry in params.entries)
      if (entry.key != 'appId' && entry.value != null)
        entry.key: entry.value.toString(),
    ...extraArgs,
  };
  final Map<String, dynamic>? json;
  final bound = _dispatchBound(params, dispatchMargin);
  try {
    json = await client
        .callServiceExtension(extensionMethod, args: args)
        .timeout(bound);
  } on TimeoutException {
    // The handler runs *on* the app's isolate, so anything that stops that
    // isolate answering stops this call returning, and the check above cannot
    // rule all of it out: a breakpoint or an unhandled exception can land in
    // the gap between that read and this dispatch, and an app the OS has
    // backgrounded is not paused at all — it runs, with frames off, so
    // anything waiting for one waits. Unbounded, one such command would hold
    // the pool's only slot and every command after it would queue for the life
    // of the run, with no error and no output.
    //
    // `CommandRunner`'s contract asks for the bound to be here, at the I/O's
    // own boundary, rather than at the dispatch layer — a deadline there would
    // hide which operation was unbounded. Re-checking the pause harder would
    // only narrow the window; this closes it, and names what it found.
    //
    // The RPC's future is left orphaned: `package:vm_service` offers no
    // cancellation, and there is nothing to clean up — it completes into a
    // `Completer` nobody reads, or never completes at all.
    throw CommandFailure.failed(
      '$extensionMethod did not answer within '
      '${bound.inSeconds}s. ${await _pauseNote(client, pauseReadBound)}',
    );
  } on RPCError catch (e) {
    // The app refusing is an answer, not a fault. Every `_err` in
    // `agent_extensions/agent.dart` — "no widget matching ... found", "timed
    // out waiting for ..." — is a `ServiceExtensionResponse.error`, which
    // crosses the VM service as a JSON-RPC error and so arrives here as a
    // throw. It is a refusal like any other and travels as one.
    //
    // `details` is where the VM puts the handler's own text; `message` is
    // generic to the JSON-RPC code ("Invalid params" for every `_err`), so it
    // is the fallback rather than the answer.
    //
    // A disposed connection that outlived `_withReconnect`'s replay comes back
    // this way too. It still reads as a failure rather than as a widget that
    // was found, which is the property that matters.
    throw CommandFailure.failed(e.details ?? e.message);
  }
  if (json == null) {
    throw CommandFailure.failed('$extensionMethod returned no payload');
  }
  // The Dart VM service appends `type` and `method` to every extension
  // response. Strip them so the AI sees only the agent's own fields and
  // gets a consistent shape across agent extensions and inspector RPCs.
  return Map<String, dynamic>.from(json)
    ..remove('type')
    ..remove('method');
}
