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
import 'bazel.dart';
import 'chrome_profile.dart';
import 'command_failure.dart';
import 'command_runner.dart';
import 'dev_tool_exception.dart';
import 'http_control_channel.dart';
import 'logging.dart';
import 'machine_protocol.dart';
import 'reload_pipeline.dart';
import 'session.dart';
import 'tooling_daemon.dart';
import 'shutdown_signals.dart';
import 'teardown.dart';
import 'tool_services.dart';

class SessionHost {
  /// Every app this command is driving, in launch (or connect) order.
  ///
  /// Appended to as sessions come up, so a handler that runs mid-startup sees
  /// what exists so far rather than waiting for all of it.
  final List<DeviceSession> sessions = <DeviceSession>[];

  /// Serialized dispatch for every transport (stdin protocol, HTTP channel,
  /// keyboard, file watcher).
  late final CommandRunner commandRunner = CommandRunner(
    // A shutdown answers what is queued or running at once rather than after
    // it: see `CommandRunner`'s library comment.
    stopping: teardown.started,
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

  /// The `reloadSources` and `hotRestart` services every VM service client of
  /// this run registers, routed to this run's `app.hotReload` and
  /// `app.restart`. See [ToolServices].
  ///
  /// Handed to a client only by a run that can reload: one with hot reload
  /// off registers nothing, so DevTools hides buttons that could only fail.
  late final ToolServices toolServices = ToolServices(
    commands: commandRunner,
    report: (action, result, {required method}) => reportReloadCommand(
      action,
      result,
      sessionReportLog(protocol),
      method: method,
      announce: (params) => announceReloadResult(protocol, params),
    ),
  );

  /// The Dart Tooling Daemon this run registers its apps with, once the
  /// command knows the toolchain's `dart`. Null for a run that serves no VM
  /// service, and until then. See [RunToolingDaemon].
  RunToolingDaemon? toolingDaemon;

  /// Owns everything created after `app.started`. See [Teardown].
  final Teardown teardown = Teardown();

  /// Every bazel command this run starts, from the first `bazel info` to a
  /// rebuild on reload. Closed by [teardown], so however the run is stopped,
  /// a bazel command it started does not go on without it. See [Bazel].
  final Bazel bazel;

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

  SessionHost({required bool isMachine, required Logger logger, Bazel? bazel})
    : _isMachine = isMachine,
      _logger = logger,
      bazel = bazel ?? Bazel() {
    // The first thing registered, so the last thing disposed: everything else
    // a run owns was built on what bazel produced, and none of it waits on
    // bazel to come down. Registered here rather than by whoever first runs
    // bazel, because that is `RunPlan.resolve`, before any of the run exists.
    unawaited(teardown.add(this.bazel.close));
  }

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

  /// End the run once every app in [sessions] has ended for good, whatever
  /// the run is doing at that moment.
  ///
  /// The session loop ends on the same thing, but a run reaches it only after
  /// its setup, and setup goes on past the launch: the hot-reload pipeline is
  /// a bazel build and a compile of its own, minutes long on a cold cache. An
  /// app closed (or finished) in that window leaves that work nothing to
  /// serve, so the teardown runs then: it stops the bazel commands in flight,
  /// which is what ends the setup step waiting on them, and the run exits as
  /// the session loop would have. A crash ends the run through [fail] anyway.
  ///
  /// Called once the launches are done, so that [sessions] is every app the
  /// run has. Ending the run earlier, while another device's launch is still
  /// to come, would take that one down with it.
  void endWhenEveryAppHasEnded() {
    if (sessions.isEmpty) return;
    unawaited(
      Future.wait([for (final s in sessions) s.terminated]).then((_) async {
        if (teardown.hasRun) return;
        _logger.info({
          'message': 'all_apps_ended',
          'text': sessions.length == 1
              ? 'The app has ended; stopping the run.'
              : 'Every app has ended; stopping the run.',
        });
        try {
          await performCleanup();
        } catch (e) {
          _logger.warning({
            'message': 'cleanup_failed',
            'text': 'Warning: cleanup after the apps ended failed: $e',
            'error': '$e',
          });
        }
      }),
    );
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
  /// `app.restart` follows upstream's `flutter run --machine` contract: a
  /// missing `fullRestart` means `false`, a hot reload, so a client written
  /// for `flutter run` does not lose state. `fullRestart: true` is the restart.
  /// `app.hotReload` stays as the explicit form of the same reload.
  void registerReloadCommands(ReloadPipeline pipeline) {
    commandRunner.register(
      'app.hotReload',
      pipeline.hotReload,
      longRunning: true,
    );
    commandRunner.register(
      'app.restart',
      restartCommand(restart: pipeline.restart, hotReload: pipeline.hotReload),
      longRunning: true,
    );
  }

  /// The `app.restart` handler: [restart] when `fullRestart` is `true`,
  /// [hotReload] otherwise.
  ///
  /// Upstream's `app.restart` also takes `pause`, `reason` and `debounce`.
  /// `reason` only labels the restart in upstream's analytics and `debounce`
  /// merges requests that arrive within 50 ms of each other; this tool's
  /// command runner already runs one reload or restart at a time, so both are
  /// accepted and have no effect. `pause: true` asks for the isolate to be left
  /// paused after the reload, which this tool does not do, so it is refused
  /// rather than ignored: a client that asked for it would otherwise believe
  /// it got it.
  static CommandHandler restartCommand({
    required CommandHandler restart,
    required CommandHandler hotReload,
  }) {
    return (params) async {
      final fullRestart = _boolParam(params, 'fullRestart');
      if (_boolParam(params, 'pause')) {
        throw const CommandFailure.badRequest(
          "'pause: true' is not supported: flutter_bazel does not leave the "
          'isolate paused after a reload or restart.',
        );
      }
      return fullRestart ? restart(params) : hotReload(params);
    };
  }

  static bool _boolParam(Map<String, dynamic> params, String name) {
    final value = params[name];
    if (value != null && value is! bool) {
      throw CommandFailure.badRequest(
        "Invalid '$name': $value; expected a bool",
      );
    }
    return value as bool? ?? false;
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
    }, control: true);
    // Both are control commands: they run beside a reload rather than behind
    // it. A reload held for a cold startup or a rebuild can take minutes, and
    // a client ending the run is owed its answer now, not when that work it no
    // longer wants has finished. Stopping the last app ends the run the same
    // way, through [endWhenEveryAppHasEnded].
    commandRunner.register('daemon.shutdown', (_) async {
      await performCleanup();
      return {'message': 'shutdown'};
    }, control: true);
  }

  /// Offer the `app.*` agent surface, for a run whose app carries the
  /// `ext.rules_flutter.*` extensions it proxies to.
  ///
  /// Conditional for the same reason `app.buildInfo` and `app.setViewport`
  /// are: the command list is a statement about this run. Native and the DDC
  /// dev loop reach the extensions over a VM service, and a debug web bundle
  /// (`--wasm`, a debug `--no-hot`) over a bridge the page installs, driven
  /// through the DevTools protocol. A profile or release bundle compiles the
  /// extensions out, and would otherwise advertise the whole surface and
  /// answer every call with a failure that reads as a connection problem
  /// rather than as a build that never had them.
  void registerAgentCommands() =>
      setUpAgentCommands(commandRunner, findSession);

  /// Offer `app.pressKey` on its own, for a web run with no agent surface (a
  /// non-debug bundle).
  ///
  /// The one `app.*` command such a run can answer: its keys go to the
  /// browser over the DevTools protocol, which needs nothing from the app.
  /// With no agent extensions in the app there is nothing to ask whether it
  /// has gone idle afterwards, so it answers without waiting and says so.
  void registerPressKey() =>
      registerPressKeyCommand(commandRunner, findSession, canSettle: false);

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
            '&settle=false to capture this instant; &screen=<id or name> on a '
            'device with several screens)',
      },
      {
        'method': 'GET',
        'path': '/sessions/{appId}/screens',
        'description':
            'the device\'s screens, and which one the app is on (JSON)',
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
    _endpoints = endpoints;
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
    // The common order, not an edge case: this channel binds after the app is
    // up, so by now there is a session and its id is the only thing standing
    // between a reader and the URLs just printed.
    for (final session in sessions) {
      _announceSession(session.appId);
    }
  }

  /// The endpoints the channel's record printed, `{appId}` templates
  /// included, once [startHttpChannel] has bound it.
  List<Map<String, String>> _endpoints = const [];

  /// Say which session the endpoints' `{appId}` stands for.
  ///
  /// The banner can only print templates — it renders one list for every
  /// session a run has — and a reader who cannot resolve `{appId}` cannot use
  /// a single one of the per-session endpoints. The id is built from the
  /// target and the device's name, which for a phone is `iOS (<UDID>)`, so it
  /// is not something to guess at: one run's was
  /// `___app_ios_device_iOS__00008101_001C512E14D2001E_`.
  ///
  /// Called from both ends of a race that has no fixed order: a device launch
  /// announces its own session, and [startHttpChannel] announces the ones
  /// already running when it binds. Whichever happens second is the one that
  /// prints, because the other found its counterpart missing and returned.
  ///
  /// Said under `--machine` too. `app.started` carries the id on stdout, but
  /// the URLs are on stderr, and a client reading the channel off stderr — a
  /// coding agent with the run's output in two files — would otherwise have to
  /// join the two streams to fill in a template. The record carries every
  /// per-session endpoint with the id already in its URL.
  void announceSession(String appId) {
    if (httpChannel == null) return;
    _announceSession(appId);
  }

  void _announceSession(String appId) {
    final channel = httpChannel!;
    final endpoints = [
      for (final e in _endpoints)
        if (e['path']!.contains('{appId}'))
          {
            'method': e['method']!,
            'path': e['path']!.replaceFirst('{appId}', appId),
            'url': e['url']!.replaceFirst('{appId}', appId),
          },
    ];
    _logger.info({
      'message': 'session_ready',
      'text':
          'Session $appId is up — that is the {appId} above, e.g.\n'
          '  ${channel.uri}/sessions/$appId/logs?token=${channel.token}',
      'appId': appId,
      'uri': channel.uri.toString(),
      'token': channel.token,
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
      exitProcess: exitProcess ?? exitReleasingBrowsers,
      logger: _logger,
    );
    for (final stream in signals ?? _processShutdownSignals()) {
      _signalSubscriptions.add(handler.listen(stream));
    }
  }
}

/// Exit now, ending any browser this process started first.
///
/// The exit a second signal asks for does not wait for the orderly shutdown,
/// and a browser left running by a tool that has gone is an orphan: nothing
/// is left to stop it or to delete its profile.
Never exitReleasingBrowsers(int code) {
  ChromeProfile.releaseAllNow();
  exit(code);
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
