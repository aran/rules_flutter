/// The `run` command — builds and launches a Flutter app with hot reload.
///
/// What is left here is the sequence, and only the sequence. Each step is an
/// object of its own:
///
///   [RunPlan]                  what the invocation resolves to, and the build
///   [SessionHost]              sessions, dispatch, protocol, teardown, HTTP
///   [ReloadPipeline]           what it takes to get an edit into the app
///   [WebPipelineAssembler]     the DDC dev loop, before Chrome launches
///   [SourceWatcher]            edits, from before the first launch
///   [DeviceLauncher]           one device: launch, DDS, VM client, session
///   [WasmPipelineAssembler]    the rebuild-and-reload loop, after launch
///   [NativePipelineAssembler]  the native compiler and orchestrator, after launch
///   `runInteractiveSession`    the loop that reads them all
///
/// The order is the load-bearing part: the watcher must start before the launch
/// loop, DWDS's connection listener must be attached before Chrome exists,
/// WASM's handlers must be registered after the generic ones, and the native
/// pipeline can only be built once there is a VM service to point it at.
/// `attach` reuses everything from [SessionHost] down.
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'dev_tool_exception.dart';
import 'device.dart';
import 'hot_reload/source_watcher.dart';
import 'logging.dart';
import 'machine_protocol.dart';
import 'device_launcher.dart';
import 'native_pipeline_assembler.dart';
import 'reload_pipeline.dart';
import 'run_plan.dart';
import 'web_mode.dart';
import 'web_options.dart';
import 'session.dart';
import 'session_host.dart';
import 'temp_dir.dart';
import 'web_pipeline_assembler.dart';

export 'dev_tool_exception.dart' show DevToolException;

class RunCommand {
  static final parser = ArgParser()
    ..addOption(
      'target',
      abbr: 't',
      help: 'Bazel target to build and run.',
      mandatory: true,
    )
    ..addOption('config', abbr: 'c', help: 'Bazel config to use.')
    ..addMultiOption(
      'build-arg',
      help: 'Additional arguments to pass to bazel build.',
    )
    ..addMultiOption(
      'dart-define',
      splitCommas: false,
      help:
          'Dart environment define (KEY=VALUE) forwarded to the build '
          'as --@rules_flutter//flutter:extra_dart_defines and replayed '
          'on hot reload/restart recompiles. Repeat for multiple defines.',
    )
    ..addMultiOption(
      'device',
      abbr: 'd',
      help:
          'Device to run on (macos, linux, windows, ios-simulator, '
          'ios-simulator:<udid>, ios, ios:<udid>, chrome, or Android serial). '
          'Repeat for multi-device.',
    )
    ..addFlag(
      'hot',
      defaultsTo: true,
      help: 'Enable hot reload (requires debug build).',
    )
    ..addFlag(
      'profile',
      defaultsTo: false,
      help: 'Run in profile mode (AOT, unstripped, profiling enabled).',
    )
    ..addOption('route', help: 'Initial route to push on app start.')
    ..addFlag(
      'start-paused',
      defaultsTo: false,
      negatable: false,
      help:
          'Hold the app at the start of main() so a debugger can attach '
          'before any app code runs. Nothing that needs a running framework '
          'answers until something resumes it: no first frame, no '
          'screenshots, and no app.* commands. DevTools (or any VM service '
          'client) is what resumes it.',
    )
    ..addFlag(
      'trace-startup',
      defaultsTo: false,
      help: 'Trace application startup, then save to a timeline file.',
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
      help: 'Launch DevTools for each connected device.',
    )
    ..addFlag(
      'wasm',
      defaultsTo: false,
      help:
          'Run web app in WASM mode (no hot reload, uses bazel rebuild + page reload).',
    )
    ..addOption(
      'web-port',
      help:
          'The host port to serve a web app from. Defaults to any free '
          'port. A port that cannot be bound is an error naming it — '
          'nothing else is chosen for you.',
    )
    ..addOption(
      'web-hostname',
      help:
          'The address the web dev server binds. Defaults to localhost; '
          '"any" binds every interface, over both IPv4 and IPv6, which puts '
          'the app and its sources on every network this host is attached '
          'to.',
    )
    ..addOption(
      'web-tls-cert-path',
      help:
          'Certificate chain to serve the web app over HTTPS. Requires '
          '--web-tls-cert-key-path.',
    )
    ..addOption(
      'web-tls-cert-key-path',
      help: 'Private key for --web-tls-cert-path.',
    )
    ..addMultiOption(
      'web-header',
      splitCommas: false,
      help:
          'NAME=VALUE header added to every web dev server response. '
          'Repeat for multiple headers. A header the response itself sets '
          '(content-type, say) wins over this.',
    )
    // No `defaultsTo`: the default really is mode-dependent (on with --wasm,
    // off elsewhere), and declaring one here would make `--help` print
    // "(defaults to on)" for every run while the code did something else.
    // Null is the honest "not asked for".
    ..addFlag(
      'cross-origin-isolation',
      defaultsTo: null,
      help:
          'Add the Cross-Origin-Opener-Policy and '
          'Cross-Origin-Embedder-Policy headers, which make '
          'SharedArrayBuffer available. On by default only with --wasm, '
          'whose skwasm renderer needs it for multi-threading; turning it '
          'off there costs the app its render threads. Off elsewhere '
          'because an isolated page cannot load a cross-origin subresource '
          'that carries no CORP header, and cannot be embedded in an '
          'iframe.',
    )
    ..addOption(
      'web-launch-url',
      help:
          'The URL the browser opens. Defaults to the dev server\'s own '
          'base URL; a path or fragment on that URL selects a starting '
          'route. It has to address this run\'s server — nothing else is '
          'proxied.',
    )
    ..addMultiOption(
      'web-browser-flag',
      splitCommas: false,
      help:
          'Additional switch passed to the browser at startup, after the '
          'ones this tool sets. Repeat for several. Switches this tool owns '
          '(--user-data-dir, --remote-debugging-port, --headless) are '
          'refused, because a browser resolves a duplicate switch by '
          'position rather than by intent.',
    )
    ..addOption(
      'web-viewport',
      help:
          'Lay the app out at this viewport, whatever size the browser '
          'window is: WIDTHxHEIGHT in CSS pixels, optionally @ a device '
          'pixel ratio — 393x660, or 393x660@3. Applied over the DevTools '
          'Protocol once the page is up, because a browser window cannot be '
          'asked for a phone-sized viewport: --window-size is clamped and '
          'loses the window chrome off the height.',
    )
    ..addFlag(
      'web-run-headless',
      defaultsTo: false,
      negatable: false,
      help:
          'Run the browser with no visible window. Screenshots and the '
          'app console still work. The sandbox stays on: pass '
          '--web-browser-flag=--no-sandbox if your environment really '
          'needs that.',
    )
    ..addOption(
      'web-browser-debug-port',
      help:
          'The Chrome DevTools Protocol port the browser should take. '
          'Defaults to any free port. Either way the launch waits for the '
          'browser to announce the port it took, and a browser that '
          'announces a different one is an error.',
    )
    ..addFlag(
      'web-enable-expression-evaluation',
      defaultsTo: true,
      help:
          'Let the debugger compile and evaluate Dart expressions against '
          'the running web app — what a watch window or an evaluate box '
          'needs. Only the DDC dev loop can: it is the only web run with a '
          'resident compiler holding the running program\'s state.',
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
      'allow-no-vm-service',
      defaultsTo: false,
      negatable: false,
      help:
          'Keep the session running even when no VM service connection '
          'could be established. Without this flag that is a fatal error, '
          'because hot reload, DevTools, and agent control all depend on '
          'the VM service. On a native device that means no connection to '
          'the app\'s own VM service; on Chrome it means no DWDS, which is '
          'what serves the VM service there — the run then falls back to '
          'serving the last build statically.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show help for this command.',
    );

  final ArgResults _results;

  RunCommand(this._results);

  /// This run's machine protocol, once [_execute] has built it.
  ///
  /// Held on the command so [execute] can still reach it while unwinding.
  /// Null until startup gets that far, and a no-op outside `--machine` mode.
  MachineProtocol? _protocol;

  /// Build, launch, and drive the app until the session ends.
  ///
  /// A [DevToolException] leaving here becomes the process's exit status —
  /// `bin/flutter_bazel.dart` prints it and exits. Before it goes, a
  /// `--machine` client is told why: the exception unwinds past the protocol
  /// entirely, so without this the JSON-RPC stream just stops mid-run with no
  /// final event and no reason. `daemon.logMessage` is flutter's own daemon
  /// shape for exactly this — `{level, message, stackTrace?}`.
  Future<void> execute() async {
    try {
      await _execute();
    } on DevToolException catch (e, stack) {
      _protocol?.sendEvent('daemon.logMessage', {
        'level': 'error',
        'message': e.message,
        'stackTrace': stack.toString(),
      });
      rethrow;
    }
  }

  Future<void> _execute() async {
    final logger = Logger('dev_tool.run');
    if (_results['verbose'] as bool) Logger.root.level = Level.FINE;

    // Sessions, dispatch, the machine protocol, teardown and the HTTP channel
    // — everything that is the same whether the app was launched here or found
    // already running. `attach` builds the same object.
    //
    // Built and listening BEFORE anything can fail. Resolving the plan probes
    // the host — adb, simctl, devicectl — and refuses devices that cannot share
    // one build or a mode they cannot run; each of those throws. With the
    // protocol still unbuilt at that point, `execute`'s catch would fire
    // `_protocol?.sendEvent` on a null and a `--machine` client would get zero
    // bytes and a bare exit instead of `daemon.connected` followed by a
    // `daemon.logMessage` naming the reason.
    final host = SessionHost(
      isMachine: _results['machine'] as bool,
      logger: logger,
    );
    _protocol = host.protocol;
    // Installed here, before the plan is resolved or anything is launched, so
    // that a run killed during its build or its install releases what it has
    // already taken. See SessionHost.listenForShutdownSignals.
    host.listenForShutdownSignals();
    final sessions = host.sessions;
    final protocol = host.protocol;
    final commandRunner = host.commandRunner;

    // The browser's session, once the launch loop has built it. The DWDS
    // `connectedApps` listener is attached before Chrome launches (a broadcast
    // stream drops what it emits with no listener), so it can fire before the
    // session list has anything in it.
    final webSession = Completer<DeviceSession>();

    // Everything it takes to get an edit into the running app. Assembled below
    // — by the web block for a DDC run, by the native assembler after launch —
    // and handed to the handlers now, which is what lets them be registered
    // before any of it exists.
    final pipeline = ReloadPipeline(host: host);
    host.registerReloadCommands(pipeline);
    host.registerLifecycleCommands();

    protocol.startListening();

    // Everything this invocation resolves to: devices, compilation mode, bazel
    // flags, workspace, toolchain. The devices come back ready to launch —
    // `--start-paused` and Android's VM-service preflight are launch-time engine
    // arguments, so there is no later moment at which they could be applied.
    final plan = await RunPlan.resolve(_results, logger);
    // The first things the plan settles that the command surface depends on.
    // Only a `-c dbg` native build carries the record `app.buildInfo` reads,
    // and only a run with a VM service can reach the `ext.rules_flutter.*`
    // extensions the `app.*` agent commands proxy to. See
    // RunPlan.carriesBuildInfo and RunPlan.hasAgentSurface.
    if (plan.carriesBuildInfo) host.registerBuildInfo();
    if (plan.hasAgentSurface) {
      host.registerAgentCommands();
    } else {
      // Said once, at the top of the run, rather than left to be discovered
      // one refused command at a time. The absence is structural and known
      // here; what a client gets otherwise is `Unknown command: app.getText`,
      // which is true but does not say that no flag on this invocation would
      // have made it available.
      final absent = _noAgentSurface(plan);
      logger.info({
        'message': 'agent_surface_unavailable',
        'text':
            'This run has no VM service, so the app.* agent commands (tap, '
            'enterText, getText, waitFor, dumpWidgetTree, …) are not offered: '
            '${absent.because} What still works: the app console '
            '(GET /sessions/{appId}/logs), a browser screenshot '
            '(GET /sessions/{appId}/screenshot/native) and app.restart. To '
            'drive the widget tree, run the DDC dev loop instead — the same '
            'target with neither --wasm nor --profile.',
        'reason': absent.reason,
      });
    }
    final target = plan.target;
    final workspace = plan.workspace;
    final toolchain = plan.toolchain;
    final devices = plan.devices;
    final isWebDevice = plan.isWebDevice;

    // Stamped before the build, not after: a source edited while bazel is
    // reading it may or may not be in the result, and the two ways of being
    // wrong are not equal. Unseeding costs a recompile of content the app
    // already has; seeding drops the edit. See [AppliedVersions.seedFromBuild].
    final builtBefore = DateTime.now();
    final build = await plan.buildApp();
    final appFile = build.appFile;
    final outputFiles = build.outputFiles;

    // Start watching before anything launches — including the DDC web assembly
    // below. Assembly stands up the module server, DWDS and the frontend
    // server and waits for the first compile, and an edit saved inside that
    // window fires no watch event at all. Its content still reaches the page —
    // the initial compile reads it if it lands before the snapshot cut, and the
    // next reload re-sends it otherwise — so what is lost is only the trigger.
    // That is the worst shape it could have: you save, nothing happens, nothing
    // says why, and it comes right on the next save for no visible reason.
    //
    // A watcher created inside the session loop is later still: that loop runs
    // after every device has launched and reported `app.started` and — on
    // native — after the compiler's first full compile, and `DirectoryWatcher`
    // reports nothing until its own initial scan completes on top of that.
    //
    // `await start()` is the other half: it returns once the underlying
    // watcher is live, and until then events are simply not reported.
    // Not in profile mode: that session never gets a reload pipeline to hand
    // the changes to, so the watcher would only be a subscription nobody reads.
    SourceWatcher? sourceWatcher;
    if (plan.watchEnabled && plan.hotReloadOff == null) {
      sourceWatcher = SourceWatcher(
        root: workspace,
        // Reads `assetTracker` on each event rather than closing over its
        // value: the tracker is built later (it needs the build outputs), and
        // it re-learns which directories feed the bundle after every rebuild,
        // so a directory that starts holding assets mid-run starts being
        // watched without restarting anything.
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

    // Step 3a: the DDC dev loop — module server, DWDS, web frontend server —
    // all before Chrome launches, so Chrome opens the module server's URL and
    // the browser-connection listener is already attached when it connects.
    WebPipelineAssembler? web;
    if (plan.isDdcWeb) {
      web = WebPipelineAssembler(
        plan: plan,
        host: host,
        pipeline: pipeline,
        webSession: webSession,
        fail: host.fail,
        builtBefore: builtBefore,
      );
      await web.assemble(outputFiles);
    }

    // Step 3b: Launch on each device and create sessions.
    final launcher = DeviceLauncher(plan: plan, host: host, appFile: appFile);
    for (final device in devices) {
      final deviceSession = await launcher.launch(device);
      if (device is WebDevice && !webSession.isCompleted) {
        webSession.complete(deviceSession);
      }
    }

    // `app.setViewport` exists only where it can work. It is registered here,
    // for any web run, rather than always with a handler that refuses on
    // native: there is no capability list in this protocol (`daemon.connected`
    // carries a version and a pid, nothing more), so a command that is present
    // and always fails is not more discoverable than one that is absent — it
    // is only a worse description of the run. On a native run the dispatcher
    // answers `Unknown command: app.setViewport`, which is true.
    //
    // After the launch loop because the CDP port it needs is discovered by
    // launching Chrome.
    if (isWebDevice) {
      final webDevice = plan.devices.first as WebDevice;
      host.commandRunner.register('app.setViewport', (params) async {
        await webDevice.setViewport(parseSetViewportCommand(params));
        return {'succeeded': true};
      });
    }

    // WASM's handlers deliberately shadow the pipeline-backed pair registered
    // above, so this has to come after them — and after the launch loop, since
    // the CDP port it needs is discovered by launching Chrome.
    if (plan.webMode is WasmWebMode) {
      final webDevice = plan.devices.first as WebDevice;
      WasmPipelineAssembler(
        cdpPort: webDevice.cdpPort,
        appUrl: webDevice.appUrl,
        target: plan.target,
        workspace: plan.workspace,
        compilationMode: plan.compilationMode,
        extraArgs: plan.extraArgs,
        host: host,
        pipeline: pipeline,
        logger: logger,
      ).assemble();
    }

    // Started before the pipeline is assembled, because assembly can need the
    // channel to finish: `--start-paused` holds the app before `main()`, and
    // the first thing assembly does is ask the app what build it came from.
    // Brought up afterwards, nothing could deliver the resume — the app waits
    // for a debugger, the resume waits for the channel, and the channel waits
    // for the app. Agent commands arriving in this window answer on their own
    // (`agent_command.dart` knows a paused device has no widget tree), and
    // reload commands wait on `pipeline.ready` rather than racing the seed.
    if (plan.httpChannelEnabled) await host.startHttpChannel();

    // Step 4: For native devices, start shared frontend_server AFTER launch.
    //
    // Assembled by the same object `attach` uses; the only difference is the
    // launch context, which is what arms the native-libs relauncher and makes
    // an asset rebuild reproduce the transitioned configuration the running
    // bundle came from.
    final hasVmClient = sessions.any((s) => s.vmClient != null);
    // `plan.hotReloadOff` rather than `!plan.profileMode`: a derivation of "can
    // this run reload" that forgets `--no-hot` lets `--no-hot -c dbg` build a
    // full compiler and orchestrator that every transport can drive. The flag
    // decides whether the machinery exists, which is what makes every
    // transport's refusal true rather than merely stated.
    if (!isWebDevice && hasVmClient && plan.hotReloadOff == null) {
      await NativePipelineAssembler(
        workspace: workspace,
        toolchain: toolchain,
        target: target,
        configDevice: devices.first,
        userBuildArgs: plan.userBuildArgs,
        host: host,
        pipeline: pipeline,
        logger: logger,
        builtBefore: builtBefore,
        launch: NativeLaunch(appFile: appFile),
      ).assemble();
    }

    // Any setup path that neither wired the pipeline nor recorded a specific
    // failure (profile mode, WASM, no VM client, compiler config absent)
    // settles the gate here so `app.hotReload` / `app.restart` return a
    // clear error instead of waiting on a signal that will never come.
    //
    // A run told not to reload gets the flag's own words instead of the
    // generic line. The two are different questions — "you asked me not to"
    // is not "it was meant to work and did not" — and this is the single
    // place the first one is answered, for the keyboard, the HTTP channel and
    // the machine protocol alike.
    //
    // The reason is handed over bare — no leading subject and no trailing
    // period. Every renderer composes a sentence around it
    // (`reportReloadCommand` writes '$action failed: $error. …'), so a reason
    // that brought its own would double them.
    if (!pipeline.ready.isSettled) {
      pipeline.ready.signalUnavailable(
        plan.hotReloadOff ?? 'Hot reload is not available for this run.',
      );
    }

    // The channel must outlive the session loop: an `app.stop` arriving over
    // HTTP is still flushing its response when the loop ends, so the channel
    // is stopped (gracefully, draining in-flight requests) only on the way
    // out.
    try {
      // Profile mode enters an interactive session (without hot reload).
      // This allows DevTools connection, performance overlay, and key handlers.
      // Not a `return`: leaving `_execute` from inside the try would skip the
      // `deferredFailure` check at the end, so a profile run that recorded a
      // post-launch failure would still exit 0. The failure is found the same
      // way and means the same thing whatever the mode, so the arms are one
      // chain and every one of them reaches the check.
      if (plan.profileMode) {
        if (sessions.isNotEmpty) {
          await runInteractiveSession(
            sessions: sessions,
            frontendServer: pipeline.frontendServer,
            protocol: protocol,
            commandRunner: commandRunner,
            devToolsEnabled: plan.devToolsEnabled,
            dartExecutable: toolchain.dart,
            hotReloadUnavailable: plan.hotReloadOff,
            shutdownSignal: host.shutdownRequested.future,
          );
        }
      }
      // Step 5-6: Watch files and handle keyboard input via shared session
      // loop. What it takes to compile and apply an edit lives in the pipeline
      // the `app.*` commands were registered against; the loop only dispatches.
      //
      // Keyed on what the keyboard can actually drive, not on whether this
      // run can reload. Gating assembly above means `--no-hot -c dbg` has no
      // reload path, and keying on `hasReloadPath` would drop such a run out of
      // the interactive session altogether — losing 'q', the perf overlay, the
      // inspector and DevTools, none of which are about hot reload. A VM
      // service is what those need; 'r' answers from the gate.
      else if (hasVmClient || isWebDevice) {
        await runInteractiveSession(
          sessions: sessions,
          frontendServer: pipeline.frontendServer,
          protocol: protocol,
          commandRunner: commandRunner,
          devToolsEnabled: plan.devToolsEnabled,
          dartExecutable: toolchain.dart,
          hotReloadUnavailable: plan.hotReloadOff,
          watcher: sourceWatcher,
          // Read per event, never captured: a pipeline whose build failed
          // assembles on a later reload, and a resolver captured here would
          // stay null past the recovery — leaving the watcher awake and
          // silently mapping every save to nothing.
          resolver: () => pipeline.resolver,
          awaitingAssembly: () => pipeline.awaitingAssembly,
          isAsset: (path) => pipeline.watchesAsset(path),
          shutdownSignal: host.shutdownRequested.future,
        );
      } else {
        // No hot reload possible — wait for the first device's app to end
        // (`terminated`, so a relaunch is not read as the app exiting).
        if (sessions.isNotEmpty) {
          await sessions.first.terminated;
        }
      }
    } finally {
      await sourceWatcher?.stop();
      // Whatever route the loop ended by — 'q', an app.stop, the app exiting —
      // everything the run owns goes here. Nothing is shut down by hand: there
      // is a compiler per app, and they are registered here as they are built.
      await host.teardown.run();
      await host.closeTransports();
      if (web?.syntheticDirectory case final dir?) await deleteTempDir(dir);
    }

    // A failure found after the run went live (see [SessionHost.fail]) ended
    // the session loop above; this is where it becomes the exit status. Thrown
    // after the transports are closed so the client that asked for the
    // teardown still got its response.
    if (host.deferredFailure case final failure?) throw failure;
  }
}

/// Why a run cannot offer the `app.*` agent surface: [reason] for a machine,
/// [because] as a sentence finishing "…are not offered: ".
///
/// One switch for both, so the tag a client matches on and the sentence a
/// person reads cannot come to describe different runs.
///
/// Only ever asked of a web run — [RunPlan.hasAgentSurface] is true for every
/// native one — and the switch is exhaustive over [WebMode] so a fourth shape
/// cannot be added without answering here.
({String reason, String because}) _noAgentSurface(RunPlan plan) =>
    switch (plan.webMode) {
      WasmWebMode() => (
        reason: 'wasm',
        because:
            'dart2wasm compiles the app to a bundle with no VM service '
            'behind it, and no flag changes that.',
      ),
      StaticWebMode() => (
        reason: 'static_bundle',
        because:
            'this run serves a built bundle (--profile or --no-hot), which '
            'has no VM service.',
      ),
      DdcWebMode() || null => throw StateError(
        'A DDC or native run has the agent surface; nothing should be asking '
        'this of it.',
      ),
    };

/// Categorize build output files by type.
///
/// Returns a map from category name to list of file paths.
Map<String, List<String>> categorizeOutputFiles(List<String> files) {
  final result = <String, List<String>>{};
  for (final f in files) {
    final category = _categorize(f);
    (result[category] ??= []).add(f);
  }
  return result;
}

String _categorize(String path) {
  if (path.endsWith('.app') || FileSystemEntity.isDirectorySync(path)) {
    return 'bundle';
  }
  if (path.endsWith('.apk')) return 'apk';
  if (path.endsWith('.ipa')) return 'ipa';
  if (path.endsWith('.dill')) return 'kernel';
  if (path.endsWith('.so') || path.endsWith('.dylib')) return 'native';
  return 'other';
}
