/// The `attach` command — connects to an already-running Flutter app.
///
/// Skips build and launch. Connects directly to a running app's VM service URI,
/// then enters the same interactive session as `run` — and, since it shares
/// [SessionHost], [ReloadPipeline] and [NativePipelineAssembler] with it,
/// genuinely the same one rather than a second implementation of it. What is
/// left here is only what is true of attach and not of run: connecting instead
/// of launching, the VM service as the sole log source, and an app that is not
/// ours to stop.
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'app_log_sink.dart';
import 'bazel.dart';
import 'device.dart';
import 'hot_reload/source_watcher.dart';
import 'logging.dart';
import 'native_pipeline_assembler.dart';
import 'reload_pipeline.dart';
import 'run_command.dart';
import 'run_plan.dart';
import 'session.dart';
import 'session_host.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'vm_service_logs.dart';

class AttachCommand {
  static final parser = ArgParser()
    ..addMultiOption(
      'debug-url',
      help: 'VM service URL of a running app (repeatable for multi-attach).',
    )
    ..addOption(
      'target',
      abbr: 't',
      help: 'Bazel target (for toolchain resolution).',
      mandatory: true,
    )
    ..addFlag(
      'machine',
      defaultsTo: false,
      help: 'Enable machine-readable JSON protocol.',
    )
    ..addFlag(
      'watch',
      defaultsTo: true,
      help:
          'Watch filesystem for changes and auto-reload. '
          'Defaults to on in terminal mode, off in machine mode.',
    )
    ..addFlag(
      'devtools',
      defaultsTo: true,
      help: 'Launch DevTools for each connection.',
    )
    // No --dart-define: the app reports the defines it was compiled with, and
    // the pipeline builds its dev config with those. A flag here could only
    // repeat them, or contradict the binary that is running.
    ..addMultiOption(
      'build-arg',
      help:
          'Additional argument for bazel build, matching the ones the run '
          'used. A build arg is not recorded in the app, so it cannot be '
          'recovered from the running process; omitting one that changes the '
          'configuration is reported by name rather than guessed at.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      defaultsTo: false,
      help: 'Enable verbose debug logging.',
    )
    ..addFlag(
      'http-control-channel',
      defaultsTo: true,
      help:
          'Expose an HTTP control channel for external command dispatch '
          '(screenshots, app.* driving). On by default; disable with '
          '--no-http-control-channel. The bound URI and auth token are '
          'printed at startup.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show help for this command.',
    );

  final ArgResults _results;

  AttachCommand(this._results);

  Future<void> execute() async {
    final debugUrls = _results['debug-url'] as List<String>;
    final target = _results['target'] as String;
    final userBuildArgs = _results['build-arg'] as List<String>;
    final isMachine = _results['machine'] as bool;
    final devToolsEnabled = _results['devtools'] as bool;
    final httpChannelEnabled = _results['http-control-channel'] as bool;

    if (debugUrls.isEmpty) {
      throw DevToolException('At least one --debug-url is required.');
    }

    // The app attach connects to was built by someone else, at a time this
    // command cannot know. Command start is the earliest defensible cutoff:
    // edits between the app's real build and here are indistinguishable from
    // the source it was built from, which is a property of attaching to a
    // process rather than launching one. See [AppliedVersions.seedFromBuild].
    final builtBefore = DateTime.now();

    // Resolve workspace once. Used both for inner `bazel` spawns
    // (workingDirectory) and for the interactive session below.
    final workspace = await findWorkspaceRoot();

    final logger = Logger('dev_tool.attach');

    // The same control plane `run` builds: sessions, dispatch, the machine
    // protocol, teardown and the HTTP channel.
    final host = SessionHost(isMachine: isMachine, logger: logger);
    // An attached run owns a resident compiler and a VM service connection;
    // its loop ends only on a shutdown request, so a signal is the usual way
    // it is stopped. See SessionHost.listenForShutdownSignals.
    host.listenForShutdownSignals();
    final sessions = host.sessions;
    final protocol = host.protocol;
    final commandRunner = host.commandRunner;
    final teardown = host.teardown;

    final logForwarders = <VmServiceLogForwarder>[];

    // The same pipeline `run` assembles. Handed to the handlers before any of
    // it exists, because a client can send a command the moment the protocol
    // starts listening; the pipeline's readiness gate is what makes that a
    // queue rather than a null.
    final pipeline = ReloadPipeline(host: host);
    host.registerReloadCommands(pipeline);
    host.registerLifecycleCommands();
    // Both unconditional on attach, for the same reason: attach connects to a
    // VM service and fails when it cannot, so an attach that gets this far has
    // the one thing a `run` has to check for. The pipeline it assembles reads
    // the build-info record and hard-fails the run when the app lacks it.
    host.registerAgentCommands();
    host.registerBuildInfo();

    // Watching starts here, before anything connects and before `app.started`
    // is emitted, for the same reason it does in `run`: a watcher created once
    // the session loop is already going misses every edit made while the run
    // was still wiring itself up, silently. `await start()` returns when the
    // watcher is actually live.
    //
    // `accepts` consults the pipeline per event, exactly as run's does. Without
    // it the default is `isDartSource` alone, so the asset tracking the shared
    // pipeline provides would only ever fire on an explicit `app.hotReload` —
    // never on someone editing a PNG.
    //
    // Gated exactly as `run` gates its own, through the one helper, and for
    // the reason recorded there: in machine mode a client is driving the
    // reloads, and a watcher underneath reloads a second time for the same
    // edit.
    SourceWatcher? sourceWatcher;
    if (RunPlan.watchEnabledFor(_results, isMachine: isMachine)) {
      sourceWatcher = SourceWatcher(
        root: workspace,
        accepts: (path) => isDartSource(path) || pipeline.watchesAsset(path),
      );
      await sourceWatcher.start();
      // A dead watcher does not end the run — an explicit `app.hotReload`
      // still works — but it silently ends `--watch`, so it has to be said.
      // package:watcher closes itself permanently on a post-ready end or any
      // error.
      unawaited(
        sourceWatcher.failed.then((failure) {
          logger.severe({
            'message': 'watcher_failed',
            'text':
                '${failure.reason}. Edits on disk will no longer trigger a '
                'reload; use app.hotReload explicitly, or restart the run to '
                'resume watching.',
            'error': failure.error?.toString() ?? '',
          });
        }),
      );
    }

    protocol.startListening();

    // Connect to each running app.
    for (var i = 0; i < debugUrls.length; i++) {
      final uri = Uri.parse(debugUrls[i]);
      final appId = 'attach_$i';
      final deviceName = 'attached:${uri.host}:${uri.port}';

      // Attach always builds a frontend server and connects a VM service, so
      // a restart is what this mode is for.
      // No `mode`: this app was started by someone else, so its build mode is
      // its own fact rather than this run's, and a guess here is a wrong value
      // a client cannot detect.
      protocol.appStart(
        appId,
        deviceName,
        supportsRestart: true,
        directory: workspace,
        launchMode: 'attach',
      );
      logger.info({
        'message': 'connecting',
        'text': 'Connecting to $uri...',
        'uri': uri.toString(),
      });

      final vmClient = VmServiceClient();
      try {
        await vmClient.connect(uri);
        // Registered on connect, not once the session is in `sessions`: this
        // socket is the one thing attach owns that outlives everything else,
        // because the app itself is not ours to stop.
        await teardown.add(() async {
          protocol.appStop(appId);
          // Retired rather than disconnected, because this is the run ending:
          // a plain close leaves the client dialable, and an RPC in flight —
          // the first-frame poll — re-dials on its way back and leaves a
          // socket that keeps this process alive after the shutdown was
          // answered. See [VmServiceClient.retire].
          await vmClient.retire();
        });
        logger.info({
          'message': 'vm_service_connected',
          'text': 'Connected to VM service at $uri.',
          'uri': uri.toString(),
        });
      } catch (e) {
        throw DevToolException('Could not connect to $uri: $e');
      }

      protocol.appDebugPort(
        appId,
        uri.replace(
          scheme: uri.scheme == 'https' ? 'wss' : 'ws',
          path: '${uri.path}ws',
        ),
        uri,
      );
      protocol.appStarted(appId);

      final appInstance = _AttachedAppInstance(uri, vmClient.gone);
      // Said once, here, because this is the only place it is news. A `run`
      // that ends this way has the process exit to explain itself; an attach
      // has nothing but the connection, so an exit with no explanation is
      // indistinguishable from the tool giving up on its own.
      unawaited(
        vmClient.gone.then(
          (_) => logger.info({
            'message': 'attached_app_gone',
            'text':
                'The app at $uri is gone: its VM service closed and a '
                're-dial did not come back. Ending the attach session.',
            'uri': uri.toString(),
          }),
        ),
      );

      // The dev tool didn't spawn this app, so there are no pipes to read and
      // no logcat to tail — the VM service is the only log source. That also
      // makes it safe: on a device the tool launched itself, subscribing here
      // would double every line already coming from the process.
      final service = vmClient.service;
      if (service != null) {
        try {
          logForwarders.add(
            await forwardVmServiceLogs(service, appInstance.logs),
          );
        } catch (e) {
          logger.warning({
            'message': 'log_forwarding_failed',
            'text':
                'Could not forward app output from $uri ($e). The session '
                'continues; app logs will not appear.',
            'uri': uri.toString(),
            'error': '$e',
          });
        }
      }
      appInstance.logs.lines.listen(
        appLogSinkFor(
          protocol: protocol,
          appId: appId,
          deviceName: deviceName,
          multiDevice: debugUrls.length > 1,
        ),
      );

      final session = DeviceSession(
        device: _AttachedPseudoDevice(deviceName),
        appInstance: appInstance,
        vmClient: vmClient,
        appId: appId,
      );
      sessions.add(session);

      // Attach has no launch to wait on, but it still has this one: the app it
      // attached to may be mid-start. Usually already settled by the latched
      // `didSendFirstFrameRasterizedEvent` on the first ask, since an app that
      // has been running a while has long since painted.
      unawaited(session.waitUntilDrivable(protocol));
      // DevTools is launched later, by the session loop; killing it belongs to
      // this disposer, as it does in `run`.
      await teardown.add(() async {
        // Both things this session started that outlive a command: the DevTools
        // process, and the first-frame wait, whose timer would otherwise hold
        // the tool up after `daemon.shutdown` was answered.
        session.stopWaitingForFirstFrame();
        session.devToolsProcess?.kill();
      });
    }

    // Resolved before assembly so the interactive session below can serve
    // DevTools from the toolchain's Dart, not whatever is on PATH.
    final toolchain = await resolveToolchainPaths(target, workspace: workspace);

    // Assemble the reload pipeline exactly as `run` does on native, with no
    // launch context: attach did not start these processes, so there is nothing
    // of ours to relaunch and no transitioned configuration to reproduce.
    //
    // The pseudo-device carries this, the same way `run` passes the device it
    // launched on: `Device.createCompilerConfig`'s base implementation produces
    // the native config attach needs, and `createReloadStrategy` the
    // VmServiceReloadStrategy. Going through here is what gives attach the
    // orchestrator's per-app RPC budget and commit/rollback, `refreshGenerated`
    // for codegen apps, and asset tracking.
    await NativePipelineAssembler(
      workspace: workspace,
      toolchain: toolchain,
      target: target,
      configDevice: sessions.first.device,
      userBuildArgs: userBuildArgs,
      host: host,
      pipeline: pipeline,
      logger: logger,
      builtBefore: builtBefore,
    ).assemble();

    // The assembler has two early returns that settle nothing — a device with
    // no compiler config, and no app to apply a reload to. Neither is reachable
    // from attach today (the base `createCompilerConfig` is never null, and a
    // failed connect throws before we get here), but `run` carries the same
    // backstop for the same reason, and without it an unreachable path becoming
    // reachable costs every `app.hotReload` a 90-second wait before it answers
    // "still starting up".
    if (!pipeline.ready.isSettled) {
      pipeline.ready.signalUnavailable(
        'Hot reload is not available for this session.',
      );
    }

    // After assembly, for the reason `run` starts it there: a driver reads this
    // channel appearing as "the run is ready", and an edit that lands before
    // the pipeline seeds its applied state is an edit the first reload cannot
    // see.
    if (httpChannelEnabled) await host.startHttpChannel();

    try {
      // A shutdown that arrived while the pipeline was being assembled is not
      // a failure to report: the session was asked to end before it could
      // exist, and its teardown has already run. Without this the run answers
      // `daemon.shutdown` with a success message and then exits 1, because the
      // torn-down VM service made the assembly it interrupted look broken.
      if (teardown.hasRun) return;
      // The app went away while the pipeline was being assembled. That is the
      // same fact the session loop below ends on when it happens a moment
      // later — and ends on with an exit status of 0, because an app this
      // command did not launch going away is the session being over, not the
      // command failing. Reporting it as a failure here would let the timing of
      // a death the user cannot see decide the exit status.
      //
      // Nothing is said here. It was already said, by the `attached_app_gone`
      // report hung off `vmClient.gone` above, which fires whenever this is
      // true.
      //
      // The same client the assembler reads (see [NativePipelineAssembler],
      // which settles the gate off exactly this): the death that explains an
      // interrupted assembly is the death of the app it was reading.
      if (sessions.first.vmClient?.isGone ?? false) return;
      if (!pipeline.hasReloadPath) {
        throw DevToolException(
          'Cannot start interactive session without a reload pipeline.',
        );
      }
      await runInteractiveSession(
        sessions: sessions,
        frontendServer: pipeline.frontendServer,
        protocol: protocol,
        watcher: sourceWatcher,
        commandRunner: commandRunner,
        devToolsEnabled: devToolsEnabled,
        dartExecutable: toolchain.dart,
        // Attach exists to connect a VM service and stand a compiler up.
        hotReloadUnavailable: null,
        // Per event, not captured — see the same call in `run_command.dart`:
        // attach's pipeline can assemble late for exactly the same reason.
        resolver: () => pipeline.resolver,
        awaitingAssembly: () => pipeline.awaitingAssembly,
        isAsset: pipeline.watchesAsset,
        shutdownSignal: host.shutdownRequested.future,
      );
    } finally {
      // The VM services outlive this command — the apps were started
      // externally and keep running — so their stream subscriptions are ours
      // to cancel. Done here rather than in performCleanup because an
      // exception out of the session loop skips that path entirely.
      for (final forwarder in logForwarders) {
        await forwarder.dispose();
      }
      await sourceWatcher?.stop();
      // Everything the command owns, however the loop ended. Quitting from the
      // keyboard runs no `app.stop`, so without this the compilers — one per
      // attached app — outlive the command, and their stdio pipes keep this
      // process alive long after it has nothing left to do.
      await host.teardown.run();
      await host.closeTransports();
    }
  }
}

/// A pseudo-device for attach mode — doesn't launch or stop anything.
class _AttachedPseudoDevice extends Device {
  final String _name;
  _AttachedPseudoDevice(this._name);

  @override
  String get name => _name;

  /// Attach cannot know what OS the app is on — it was handed a VM service URI
  /// and nothing else — so the host is the only signal there is, and a locally
  /// running desktop app is what `attach` is overwhelmingly used for.
  ///
  /// Stated here rather than inherited: `Device`'s default is `false`, and the
  /// pipeline pushes this onto every session's VM client when it wires the
  /// asset directory. Inheriting the default would tell a Windows host's client
  /// to send POSIX-shaped paths to `_flutter.setAssetBundlePath`.
  @override
  bool get usesWindowsPaths => Platform.isWindows;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnsupportedError('Attach mode does not launch apps');

  @override
  Future<void> stop(AppInstance instance) async {
    // The app was started externally, so there is nothing to kill — but the
    // log stream is ours and its subscribers need to complete.
    await instance.logs.close();
  }
}

/// The app attach found, standing in for one this tool launched.
class _AttachedAppInstance extends AppInstance {
  _AttachedAppInstance(Uri vmServiceUri, Future<void> gone)
    : super(process: _ExternalAppProcess(gone), vmServiceUri: vmServiceUri);
}

/// An app this tool did not start, in the shape of the one it did.
///
/// Every field here is a fiction except the one that matters. There is no
/// handle to an app someone else launched: no pipes to read, no pid to signal,
/// and no exit status to reap — [pid] and [kill] say so by answering nothing.
///
/// [exitCode] is the exception, and it is not a fiction. The session's whole
/// question of this object is "is the app still there", and attach has an
/// answer to that: [VmServiceClient.gone], the VM service closing and not
/// coming back. Wiring it here is what makes an attached app's death an
/// observation the session already knows how to act on; without it a detached
/// `attach` whose app died would wait forever.
///
/// The *value* is the one thing that cannot be recovered: a process this tool
/// never reaped has a status only its parent could read. No caller reads it —
/// the completion is the entire signal — so it is zero rather than an invented
/// failure.
class _ExternalAppProcess implements Process {
  final Future<void> _gone;
  _ExternalAppProcess(this._gone);

  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => throw UnsupportedError('No stdin for attached process');
  @override
  int get pid => -1;
  @override
  Future<int> get exitCode => _gone.then((_) => 0);
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}
