/// The control plane a dev-loop command runs on, independent of how the app
/// got there.
///
/// `run` builds and launches an app; `attach` finds one already running. What
/// happens either side of that difference is the same thing: a list of
/// sessions, a [CommandRunner] the transports dispatch through, a
/// [MachineProtocol], a [Teardown] that owns everything created after
/// `app.started`, and an [HttpControlChannel].
///
/// What is deliberately NOT here: anything about compiling or applying code.
/// That is [ReloadPipeline]'s, and the split is what lets attach share the
/// reload path without inheriting run's build and launch.
library;

import 'dart:async';
import 'dart:io';

import 'agent_command.dart';
import 'command_failure.dart';
import 'command_runner.dart';
import 'dev_tool_exception.dart';
import 'http_control_channel.dart';
import 'logging.dart';
import 'machine_protocol.dart';
import 'reload_pipeline.dart';
import 'session.dart';
import 'shutdown_signals.dart';
import 'teardown.dart';

class SessionHost {
  /// Every app this command is driving, in launch (or connect) order.
  ///
  /// Appended to as sessions come up, so a handler that runs mid-startup sees
  /// what exists so far rather than waiting for all of it.
  final List<DeviceSession> sessions = <DeviceSession>[];

  /// Serialized dispatch for every transport (stdin protocol, HTTP channel,
  /// keyboard, file watcher).
  late final CommandRunner commandRunner = CommandRunner(
    // Same lazy-read trick as onProgress below: `protocol` is built from this
    // object, so it can only be reached when the callback actually fires.
    onCommandsChanged: () => protocol.commandsChanged(),
    // Reads `protocol` when a command actually runs, not while this field is
    // being initialised, so the two can refer to each other.
    onProgress: (method, params, id, {required finished}) =>
        protocol.appProgress(
          // Passed through as null when the command named no app. See
          // [MachineProtocol.appProgress]: an `?? ''` here would turn
          // "addressed to every app" into an id no app has.
          params['appId'] as String?,
          method,
          progressId: id,
          finished: finished,
        ),
  );

  /// The machine protocol. A no-op outside `--machine` mode, so callers never
  /// branch on whether it is enabled.
  late final MachineProtocol protocol = MachineProtocol(
    enabled: _isMachine,
    commandRunner: commandRunner,
  );

  /// Owns everything created after `app.started`. See [Teardown].
  final Teardown teardown = Teardown();

  /// Completed by [performCleanup]; what ends the interactive session loop.
  final Completer<void> shutdownRequested = Completer<void>();

  /// The HTTP control channel, once [startHttpChannel] has bound it.
  HttpControlChannel? httpChannel;

  /// One subscription per signal this run can be stopped with, once
  /// [listenForShutdownSignals] has installed them.
  ///
  /// Held here because they are a *transport* — the third one, after stdin and
  /// the HTTP channel — and a transport nobody owns is a transport nobody
  /// closes. An uncancelled `ProcessSignal.watch()` keeps the Dart VM alive
  /// after `main` returns, exactly as an uncancelled stdin listener does
  /// (`MachineProtocol.stopListening`), so leaving these to the garbage
  /// collector leaves `flutter_bazel run` unable to end: `daemon.shutdown` is
  /// answered, everything the run owns is released, and the process sits there
  /// until it is killed.
  final List<StreamSubscription<ProcessSignal>> _signalSubscriptions = [];

  /// A failure found after the run went live, rethrown by the command once its
  /// transports are closed. See [fail].
  DevToolException? deferredFailure;

  final bool _isMachine;
  final Logger _logger;

  SessionHost({required bool isMachine, required Logger logger})
    : _isMachine = isMachine,
      _logger = logger;

  /// Look up a session by appId. Returns null if not found.
  DeviceSession? findSession(String? appId) {
    if (appId == null) return null;
    for (final s in sessions) {
      if (s.appId == appId) return s;
    }
    return null;
  }

  /// The sessions a command targets: one when `appId` names it, else all.
  List<DeviceSession> targetSessions(Map<String, dynamic> params) {
    final appId = params['appId'] as String?;
    if (appId == null) return sessions;
    final session = findSession(appId);
    return session == null ? const [] : [session];
  }

  /// Gracefully tear down everything the command owns, then signal the session
  /// loop to end.
  ///
  /// Deliberately does NOT stop the HTTP control channel: this runs inside
  /// `app.stop` / `daemon.shutdown` command handlers, and when the command
  /// arrived over HTTP the response has not been written yet. The channel is
  /// closed by [closeTransports] after the session loop returns — by which
  /// point the response has flushed. In attach the shutdown signal is also the
  /// only way the loop ends at all: an attached app's pseudo-process never
  /// exits, so there is no process exit to fall out of.
  ///
  /// Each session hands [teardown] its own disposer the moment it exists, so
  /// what gets cleaned up does not depend on how far setup got. Walking
  /// [sessions] here instead would tear down only what had been appended by the
  /// time it ran, and a `daemon.shutdown` answering `app.started` arrives
  /// before the append — stopping nothing, leaving the app running and its VM
  /// service socket keeping the tool alive.
  ///
  /// The signal is given even when a disposer throws. It is what ends the
  /// session loop, so losing it to a failed teardown leaves a run that cannot
  /// be stopped by anything short of a signal — including by the
  /// `daemon.shutdown` that just answered with a 500.
  Future<void> performCleanup() async {
    try {
      await teardown.run();
    } finally {
      if (!shutdownRequested.isCompleted) shutdownRequested.complete();
    }
  }

  /// End the run because of a failure that surfaced after it was already live,
  /// and so could not simply be thrown where it was found.
  ///
  /// The DWDS wiring runs in a `connectedApps` listener, long after the command
  /// has moved on to the session loop; a throw there is an unhandled async
  /// error and the run carries on regardless. Recorded here and rethrown once
  /// the transports are closed, it becomes the process's exit status like any
  /// other [DevToolException]. Only the first failure is kept — the ones that
  /// follow are usually its consequences.
  void fail(DevToolException error) {
    deferredFailure ??= error;
    unawaited(() async {
      try {
        await performCleanup();
      } catch (e) {
        _logger.warning({
          'message': 'cleanup_failed',
          'text': 'Warning: cleanup after a fatal error failed: $e',
          'error': '$e',
        });
      }
    }());
  }

  /// Point `app.hotReload` and `app.restart` at [pipeline].
  ///
  /// The single place either command is registered, for `run` and `attach`
  /// alike.
  ///
  /// `fullRestart: false` is the machine protocol's way of asking for a reload
  /// through the restart command, which is what a `flutter run`-shaped client
  /// sends; it dispatches to [ReloadPipeline.hotReload].
  void registerReloadCommands(ReloadPipeline pipeline) {
    commandRunner.register(
      'app.hotReload',
      pipeline.hotReload,
      longRunning: true,
    );
    commandRunner.register('app.restart', (params) async {
      final fullRestart = params['fullRestart'] as bool? ?? true;
      return fullRestart
          ? pipeline.restart(params)
          : pipeline.hotReload(params);
    }, longRunning: true);
  }

  /// Register the commands that do not depend on a reload pipeline: stopping
  /// the app and shutting the tool down.
  ///
  /// Reload and restart are registered separately, by
  /// [registerReloadCommands], because they need a pipeline this object
  /// deliberately knows nothing about. The `app.*` agent surface is separate
  /// for the reason [registerAgentCommands] gives.
  void registerLifecycleCommands() {
    // Upstream's contract: `app.stop` stops the app it names, and the run
    // outlives it if another app is still going. Ignoring `appId` and tearing
    // the whole run down would lose both apps for a client that named one of
    // two, and answer a tidy "stopped" to a client that named an app this run
    // has never heard of.
    commandRunner.register('app.stop', (params) async {
      final appId = params['appId'] as String?;
      if (appId == null) {
        throw const CommandFailure.badRequest(
          'app.stop needs an appId: it stops one app, and a run can be '
          'driving several. To end the whole run — every app, the browser, '
          'the compiler and this process — send daemon.shutdown.',
        );
      }
      final session = findSession(appId);
      if (session == null) {
        throw CommandFailure.notFound('Unknown appId: $appId');
      }
      await session.shutdown(protocol);
      return {'message': 'stopped', 'appId': appId};
    });
    commandRunner.register('daemon.shutdown', (_) async {
      await performCleanup();
      return {'message': 'shutdown'};
    });
  }

  /// Offer the `app.*` agent surface, for a run whose app carries the
  /// `ext.rules_flutter.*` extensions it proxies to.
  ///
  /// Conditional for the same reason `app.buildInfo` and `app.setViewport`
  /// are: the command list is a statement about this run. Those extensions
  /// need a VM service to be registered against, and on a browser only the DDC
  /// dev loop has one — a `--wasm` or `--profile` web run serves a bundle
  /// built by dart2wasm or dart2js, where `dart:developer`'s `registerExtension`
  /// is a no-op stub and there is no service to reach it through anyway. Such
  /// a run would advertise the whole surface and answer every call with
  /// `no VM service for <appId>` a minute later, which reads as a connection
  /// that failed rather than one that was never going to exist.
  void registerAgentCommands() =>
      setUpAgentCommands(commandRunner, findSession);

  /// Offer `app.buildInfo` for a run whose app actually carries the record.
  ///
  /// Not in [registerLifecycleCommands] because whether it can be answered is
  /// a property of the plan, and that is resolved later. See
  /// [registerBuildInfoCommand].
  void registerBuildInfo() =>
      registerBuildInfoCommand(commandRunner, findSession);

  /// Bind the HTTP control channel and print how to reach it.
  Future<void> startHttpChannel() async {
    final channel = httpChannel = HttpControlChannel(
      commandRunner: commandRunner,
      findSession: findSession,
    );
    await channel.start();
    final base = channel.uri;
    final t = channel.token;
    // One list, two renderings: prose hand-written beside the structured
    // fields would mean adding an endpoint edits a string nothing checks.
    final endpoints = [
      {
        'method': 'POST',
        'path': '/command',
        'description': 'execute a machine protocol command',
      },
      {
        'method': 'GET',
        'path': '/commands',
        'description':
            'what this run can be asked to do (it grows during a run)',
      },
      {
        'method': 'GET',
        'path': '/sessions/{appId}/screenshot/flutter',
        'description':
            'Flutter widget tree screenshot (PNG; waits for the app to go '
            'idle first — &settle=false to capture this instant)',
      },
      {
        'method': 'GET',
        'path': '/sessions/{appId}/screenshot/native',
        'description':
            'native OS screenshot (PNG; waits for the app to go idle first — '
            '&settle=false to capture this instant)',
      },
      {
        'method': 'GET',
        'path': '/sessions/{appId}/logs',
        'description':
            'app console output (tails by default; &since=<cursor> to poll)',
      },
    ];
    // Each endpoint carries the URL that actually works, token included, and
    // the prose renders from it. A structured half carrying only `token`
    // invites an `Authorization` header — which this channel answers with
    // `Invalid or missing token`, saying nothing about where it looked — and
    // JSON mode drops the human line that says `?token=`.
    for (final e in endpoints) {
      e['url'] = '$base${e['path']}?token=$t';
    }
    _logger.info({
      'message': 'http_control_channel',
      'text': [
        'HTTP control channel:',
        for (final e in endpoints)
          '  ${e['method']!.padRight(4)} ${e['url']}  — ${e['description']}',
      ].join('\n'),
      'uri': base.toString(),
      'token': t,
      // Named so a client does not have to infer it from the URLs: the token
      // is a query parameter, not a header.
      'tokenParam': 'token',
      'endpoints': endpoints,
    });
  }

  /// Close the command transports, in the order the run's `finally` closed
  /// them: the HTTP channel drains in-flight responses first, then the stdin
  /// protocol stops, and the signal subscriptions go last.
  ///
  /// Last is load-bearing. A signalled shutdown runs this from inside the
  /// signal handler, and the "signalled twice" escape is only live while the
  /// handler is still subscribed — so the subscriptions stay up for all of
  /// [performCleanup] and the HTTP drain, which are the seconds someone
  /// pressing Ctrl-C a second time is refusing to wait through.
  Future<void> closeTransports() async {
    await httpChannel?.stop();
    await protocol.stopListening();
    await _cancelShutdownSignals();
  }

  /// Stop listening for signals, releasing the last thing holding the VM open.
  Future<void> _cancelShutdownSignals() async {
    final subscriptions = List.of(_signalSubscriptions);
    _signalSubscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  /// Release everything this run owns when it is killed, instead of leaving it.
  ///
  /// Dart's default disposition for SIGINT and SIGTERM ends the VM outright,
  /// so the `finally` that both commands tear down in never runs and the
  /// browser, the app on the device and the resident compiler are simply
  /// abandoned — a browser reparented to launchd with its temp profile still
  /// on disk, say. Stopping a backgrounded run
  /// with a signal is the ordinary way to stop one, so it gets the ordinary
  /// shutdown: [performCleanup] and [closeTransports], exactly what
  /// `daemon.shutdown` does.
  ///
  /// Installed by the command right after this host is built, which is before
  /// the plan is resolved or anything is launched. That ordering is what makes
  /// it cover the long window a run is most likely to be killed in — the build
  /// and the install — and [Teardown] is what makes it safe there: a resource
  /// registered after the teardown has run is disposed as it is created rather
  /// than outliving the process.
  ///
  /// The subscriptions are kept by this host and released by
  /// [closeTransports], which every ending goes through. They are not handed
  /// back: a caller holding one is a caller that has to remember to cancel it.
  ///
  /// One [ShutdownSignalHandler] across every signal, so "already shutting
  /// down" is one fact rather than one per signal — a SIGINT after a SIGTERM
  /// is the second signal, not another first one.
  void listenForShutdownSignals({
    List<Stream<ProcessSignal>>? signals,
    void Function(int code)? exitProcess,
  }) {
    final handler = ShutdownSignalHandler(
      onShutdown: () async {
        await performCleanup();
        await closeTransports();
      },
      exitProcess: exitProcess ?? exit,
      logger: _logger,
    );
    for (final stream in signals ?? _processShutdownSignals()) {
      _signalSubscriptions.add(handler.listen(stream));
    }
  }
}

/// Every signal this platform lets a run be stopped with.
///
/// One stream each rather than a merged one: a merge costs a
/// `StreamController` whose inner subscriptions nothing can reach, and those
/// hold the VM open after a run has ended.
List<Stream<ProcessSignal>> _processShutdownSignals() => [
  for (final signal in shutdownSignalsFor(isWindows: Platform.isWindows))
    signal.watch(),
];
