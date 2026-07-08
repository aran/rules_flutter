/// The `run` command — builds and launches a Flutter app with hot reload.
///
/// Architecture:
///   1. Build the initial app via `bazel build -c dbg`
///   2. Launch the app on each target device
///   3. Connect to VM service per device
///   4. Start ONE persistent frontend_server for incremental compilation
///   5. Watch source files for changes (shared across devices)
///   6. On change: recompile once → hot reload ALL devices
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dds/dds.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service_io.dart' as vm;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart'
    show ChromeConnection;

import 'agent_command.dart';
import 'bazel.dart';
import 'command_runner.dart';
import 'compiler_config.dart';
import 'device.dart';
import 'frontend_server.dart';
import 'hot_reload/app_instance.dart' as hr;
import 'hot_reload/applied_versions.dart';
import 'hot_reload/compiler.dart' as hot_reload;
import 'hot_reload/package_uri_resolver.dart';
import 'hot_reload/readiness_gate.dart';
import 'hot_reload/reload_orchestrator.dart';
import 'hot_reload/workspace.dart';
import 'http_control_channel.dart';
import 'logging.dart';
import 'machine_protocol.dart';
import 'native_libs_fingerprint.dart';
import 'reload_strategy.dart';
import 'session.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'web_bootstrap.dart';
import 'web_module_server.dart';

/// Exception thrown by dev tool commands to indicate failure with an exit code.
///
/// Replaces direct `exit()` calls so callers can catch and handle gracefully.
class DevToolException implements Exception {
  final String message;
  final int exitCode;

  DevToolException(this.message, {this.exitCode = 1});

  @override
  String toString() => message;
}

class RunCommand {
  static final parser = ArgParser()
    ..addOption('target',
        abbr: 't', help: 'Bazel target to build and run.', mandatory: true)
    ..addOption('config', abbr: 'c', help: 'Bazel config to use.')
    ..addMultiOption('build-arg',
        help: 'Additional arguments to pass to bazel build.')
    ..addMultiOption('dart-define',
        splitCommas: false,
        help: 'Dart environment define (KEY=VALUE) forwarded to the build '
            'as --@rules_flutter//flutter:extra_dart_defines and replayed '
            'on hot reload/restart recompiles. Repeat for multiple defines.')
    ..addMultiOption('device',
        abbr: 'd',
        help: 'Device to run on (macos, linux, windows, ios-simulator, '
            'ios-simulator:<udid>, ios, ios:<udid>, chrome, or Android serial). '
            'Repeat for multi-device.')
    ..addFlag('hot',
        defaultsTo: true, help: 'Enable hot reload (requires debug build).')
    ..addFlag('profile',
        defaultsTo: false,
        help: 'Run in profile mode (AOT, unstripped, profiling enabled).')
    ..addOption('route', help: 'Initial route to push on app start.')
    ..addFlag('trace-startup',
        defaultsTo: false,
        help: 'Trace application startup, then save to a timeline file.')
    ..addFlag('machine',
        defaultsTo: false, help: 'Enable machine-readable JSON protocol.')
    ..addFlag('watch',
        defaultsTo: true,
        help: 'Watch filesystem for changes and auto-reload. '
            'Defaults to on in terminal mode, off in machine mode.')
    ..addFlag('devtools',
        defaultsTo: true, help: 'Launch DevTools for each connected device.')
    ..addFlag('wasm',
        defaultsTo: false,
        help:
            'Run web app in WASM mode (no hot reload, uses bazel rebuild + page reload).')
    ..addFlag('verbose',
        abbr: 'v', defaultsTo: false, help: 'Enable verbose debug logging.')
    ..addFlag('http-control-channel',
        defaultsTo: true,
        help: 'Expose an HTTP control channel for external command dispatch '
            '(screenshots, app.* driving). On by default; disable with '
            '--no-http-control-channel. The bound URI and auth token are '
            'printed at startup.')
    ..addFlag('allow-no-vm-service',
        defaultsTo: false,
        negatable: false,
        help: 'Keep the session running even when no VM service connection '
            'could be established on a native device. Without this flag '
            'that is a fatal error, because hot reload, DevTools, and '
            'agent control all depend on the VM service.')
    ..addFlag('help',
        abbr: 'h', negatable: false, help: 'Show help for this command.');

  final ArgResults _results;

  RunCommand(this._results);

  Future<void> execute() async {
    final target = _results['target'] as String;
    final config = _results['config'] as String?;
    // --dart-define flags ride along on EVERY bazel invocation this run
    // makes (initial build, dev-config build, codegen refreshes, cquery) so
    // they all share one configuration — otherwise outputs would resolve in
    // a configuration that never got the defines.
    final defineFlags =
        dartDefineFlags(_results['dart-define'] as List<String>);
    final extraArgs = [
      ...(_results['build-arg'] as List<String>),
      ...defineFlags,
    ];
    final deviceIds = _results['device'] as List<String>;
    final hotReloadEnabled = _results['hot'] as bool;
    final profileMode = _results['profile'] as bool;
    final initialRoute = _results['route'] as String?;
    final traceStartup = _results['trace-startup'] as bool;
    final isMachine = _results['machine'] as bool;
    final watchEnabled = _results.wasParsed('watch')
        ? _results['watch'] as bool
        : !isMachine; // terminal: watch by default, machine: don't
    final wasmMode = _results['wasm'] as bool;
    final devToolsEnabled = _results['devtools'] as bool;
    final verbose = _results['verbose'] as bool;
    final httpChannelEnabled = _results['http-control-channel'] as bool;
    final allowNoVmService = _results['allow-no-vm-service'] as bool;

    // Resolve the workspace root once. Every callsite below (web module
    // server setup, native frontend server startup, profile/normal
    // interactive sessions, machine-protocol hot reload) used to call
    // findWorkspaceRoot independently and silently fall back to '.'; the
    // local capture both fixes that and avoids 2-3 redundant `bazel info`
    // spawns per `flutter_bazel run`.
    final workspace = await findWorkspaceRoot();

    // Shared state for cleanup.
    final sessions = <DeviceSession>[];
    FrontendServer? frontendServer;
    HttpControlChannel? httpChannel;
    ReloadStrategy? reloadStrategy;
    // Cached after frontend server setup; used by machine protocol handlers.
    String? _resolvedEntrypoint;
    // For codegen apps: rebuilds generated sources via bazel before a reload.
    // The native path injects this into the orchestrator; the web path invokes
    // it in performHotReload before recompiling. Null for non-codegen apps.
    Future<bool> Function()? refreshGenerated;
    // For apps bundling loose native libraries (native_deps): rebuilds the
    // app and, when the rebuilt bundle's native libraries differ from the
    // running process's, relaunches the process — a hot restart cannot
    // replace a dlopened library. Returns null when no relaunch was needed
    // (the normal isolate restart proceeds); otherwise the restart result.
    // Null for apps with no loose native libraries (instant-restart path).
    Future<Map<String, dynamic>?> Function()? relaunchIfNativeLibsChanged;

    // Hot-reload state. `appliedVersions` is a per-file record of "what's
    // currently live in the running app." `workspaceView` is set after the
    // frontend server starts (entrypoint is known). On native we additionally
    // construct a `ReloadOrchestrator`; web DDC keeps the legacy
    // `recompileAndReload` path (still consults `appliedVersions` for change
    // detection).
    final appliedVersions = AppliedVersions();
    Workspace? workspaceView;
    // Maps live source paths → package: URIs for snapshot keying and the
    // filesystem watcher. Built from the build-emitted sourcePackages.
    PackageUriResolver? reloadResolver;
    ReloadOrchestrator? orchestrator;
    // Bridges the gap between the `app.started` protocol event (emitted in
    // the per-device launch loop) and the reload pipeline being wired
    // (constructed after the loop). `app.hotReload` / `app.restart` await
    // this so a client firing on `app.started` queues instead of racing the
    // setup into the orchestrator-null error branch.
    final hotReloadReady = ReadinessGate();

    // Set up centralized command dispatch.
    final commandRunner = CommandRunner();

    final protocol = MachineProtocol(
      enabled: isMachine,
      commandRunner: commandRunner,
    );

    /// Look up a session by appId. Returns null if not found.
    DeviceSession? findSession(String? appId) {
      if (appId == null) return null;
      for (final s in sessions) {
        if (s.appId == appId) return s;
      }
      return null;
    }

    final shutdownRequested = Completer<void>();

    /// Gracefully tear down sessions and the frontend server, then signal
    /// the session loop to end.
    ///
    /// Deliberately does NOT stop the HTTP control channel: this runs inside
    /// `app.stop` / `daemon.shutdown` command handlers, and when the command
    /// arrived over HTTP the response has not been written yet. The channel
    /// is closed on the way out of [execute], after the session loop returns
    /// — by which point the response has flushed.
    Future<void> performCleanup() async {
      for (final session in sessions) {
        session.devToolsProcess?.kill();
        protocol.appStop(session.appId);
        await session.vmClient?.disconnect();
        await session.dds?.shutdown();
        await session.device.stop(session.appInstance);
      }
      await frontendServer?.shutdown();
      if (!shutdownRequested.isCompleted) shutdownRequested.complete();
    }

    /// Convert a [ReloadResult] to a machine protocol response map.
    Map<String, dynamic> _reloadResultToMap(ReloadResult result, String verb) {
      if (!result.compileSuccess) {
        return {
          'message': 'Compilation failed',
          if (result.diagnostics.isNotEmpty) 'error': result.diagnostics,
        };
      }
      if (!result.deviceSuccess) {
        return {'message': '$verb failed on some devices'};
      }
      return {'message': '$verb successful'};
    }

    /// Get the list of sessions targeted by a command.
    /// If appId is provided, targets only that session. Otherwise all sessions.
    List<DeviceSession> targetSessions(Map<String, dynamic> params) {
      final appId = params['appId'] as String?;
      if (appId != null) {
        final session = findSession(appId);
        if (session == null) return [];
        return [session];
      }
      return sessions;
    }

    /// Convert a [ReloadOutcome] from the orchestrator to a machine-protocol
    /// response map. `isEmpty` distinguishes a real reload from one whose
    /// declared files turned out byte-identical to what was already applied.
    Map<String, dynamic> _orchOutcomeToMap(ReloadOutcome outcome, String verb) {
      return switch (outcome) {
        ReloadApplied(:final filesRecompiled, :final isEmpty) => {
            'message': '$verb successful',
            'filesRecompiled': filesRecompiled.toList()..sort(),
            'isEmpty': isEmpty,
          },
        ReloadNoChange() => {
            'message': '$verb successful (no changes detected)',
          },
        ReloadCompileFailed(:final diagnostics) => {
            'message': 'Compilation failed',
            if (diagnostics.isNotEmpty) 'error': diagnostics,
          },
        ReloadApplyFailed(:final perApp) => {
            'message': '$verb failed on some devices',
            'perApp': {
              for (final entry in perApp.entries)
                entry.key: switch (entry.value) {
                  hr.ApplyFailed(:final reason) => reason,
                  hr.ApplyTimedOut() => 'timed out',
                  hr.Applied() => 'ok',
                },
            },
            if (perApp.values
                .whereType<hr.ApplyFailed>()
                .map((f) => f.reason)
                .firstOrNull
                case final String reason)
              'error': reason,
          },
      };
    }

    /// Block until the reload pipeline has finished wiring (or definitively
    /// failed). Returns an error map to short-circuit the handler when hot
    /// reload is unavailable, or null when it's safe to proceed. This is
    /// what closes the `app.started`-before-orchestrator race.
    Future<Map<String, dynamic>?> awaitReloadReady() async {
      await hotReloadReady.whenReady.timeout(
        const Duration(seconds: 90),
        onTimeout: () {},
      );
      if (!hotReloadReady.isReady) {
        return {
          'error': hotReloadReady.unavailableReason ??
              'Hot reload is still starting up.'
        };
      }
      return null;
    }

    Future<Map<String, dynamic>> performRestart(
        Map<String, dynamic> params) async {
      final notReady = await awaitReloadReady();
      if (notReady != null) return notReady;

      // Native: orchestrator-based restart.
      final orch = orchestrator;
      if (orch != null) {
        // Native libraries cannot be hot-restarted (the process keeps its
        // dlopened images) — rebuild first and relaunch if they changed.
        final relaunch = relaunchIfNativeLibsChanged;
        if (relaunch != null) {
          final relaunched = await relaunch();
          if (relaunched != null) return relaunched;
        }
        final outcome = await orch.restart();
        return _orchOutcomeToMap(outcome, 'Restart');
      }

      // Web DDC: legacy recompileAndRestart.
      final fs = frontendServer;
      final entrypoint = _resolvedEntrypoint;
      if (fs == null || entrypoint == null) {
        return {'error': 'No frontend server available'};
      }
      final targets = targetSessions(params);
      if (targets.isEmpty && params.containsKey('appId')) {
        return {'error': 'Unknown appId: ${params['appId']}'};
      }
      // Codegen apps: regenerate before the restart's full recompile.
      if (refreshGenerated != null && !(await refreshGenerated())) {
        return {'error': 'Generated source rebuild (bazel) failed.'};
      }
      final result = await recompileAndRestart(
        frontendServer: fs,
        entrypoint: entrypoint,
        sessions: targets,
        reloadStrategy: reloadStrategy,
      );
      if (result.success && workspaceView != null) {
        // After a restart, every disk file is now live.
        final snap = workspaceView.snapshot();
        appliedVersions.clear();
        appliedVersions.markApplied(snap, files: snap.fileUris.toSet());
      }
      return _reloadResultToMap(result, 'Restart');
    }

    Future<Map<String, dynamic>> performHotReload(
        Map<String, dynamic> params) async {
      final notReady = await awaitReloadReady();
      if (notReady != null) return notReady;

      final declared = (params['invalidatedFiles'] as List?)
              ?.cast<String>()
              .toSet() ??
          <String>{};

      // Native: orchestrator-based reload (includes per-AppInstance RPC budget).
      final orch = orchestrator;
      if (orch != null) {
        final outcome = await orch.reload(declared: declared);
        return _orchOutcomeToMap(outcome, 'Hot reload');
      }

      // Web DDC: legacy recompileAndReload + AppliedVersions for change
      // detection. We no longer rely on a global `_lastCompileTime`; every
      // file's last-applied version is tracked individually.
      final fs = frontendServer;
      final entrypoint = _resolvedEntrypoint;
      final ws = workspaceView;
      if (fs == null || entrypoint == null || ws == null) {
        return {'error': 'No frontend server available'};
      }
      final targets = targetSessions(params);
      if (targets.isEmpty && params.containsKey('appId')) {
        return {'error': 'Unknown appId: ${params['appId']}'};
      }

      // Codegen apps: rebuild generated sources via bazel before snapshotting,
      // so a regenerated `.g.dart` is detected as changed and recompiled.
      if (refreshGenerated != null && !(await refreshGenerated())) {
        return {'error': 'Generated source rebuild (bazel) failed.'};
      }

      final snap = ws.snapshot();
      final fsChanged = appliedVersions.findChangedFrom(snap);
      final invalidated = {...fsChanged, ...declared};
      if (invalidated.isEmpty) {
        return {'message': 'Hot reload successful (no changes detected)'};
      }

      final result = await recompileAndReload(
        frontendServer: fs,
        entrypoint: entrypoint,
        invalidatedFiles: invalidated.toList(),
        sessions: targets,
        reloadStrategy: reloadStrategy,
      );
      if (result.success) {
        appliedVersions.markApplied(snap, files: invalidated);
      }
      return _reloadResultToMap(result, 'Hot reload');
    }

    commandRunner.register('app.restart', (params) async {
      final fullRestart = params['fullRestart'] as bool? ?? true;
      if (!fullRestart) {
        return performHotReload(params);
      }
      return performRestart(params);
    });
    commandRunner.register('app.stop', (_) async {
      await performCleanup();
      return {'message': 'stopped'};
    });
    commandRunner.register('daemon.shutdown', (_) async {
      await performCleanup();
      return {'message': 'shutdown'};
    });
    commandRunner.register('app.hotReload', (params) async {
      return performHotReload(params);
    });
    setUpAgentCommands(commandRunner, findSession);

    protocol.startListening();

    final logger = Logger('dev_tool.run');
    if (verbose) Logger.root.level = Level.FINE;

    // Step 1: Resolve devices FIRST — they dictate platform build flags.
    final devices = resolveDevices(deviceIds);
    logger.fine({
      'message': 'resolved_devices',
      'text': 'Resolved devices: ${devices.map((d) => d.name).toList()}',
      'devices': devices.map((d) => d.name).toList(),
    });

    // Validate: all devices must agree on platform build args.
    final distinctBuildArgs = devices.map((d) => d.buildArgs.join(' ')).toSet();
    if (distinctBuildArgs.length > 1) {
      final details = devices
          .where((d) => d.buildArgs.isNotEmpty)
          .map((d) => '  ${d.name}: ${d.buildArgs.join(' ')}')
          .join('\n');
      throw DevToolException(
          'Cannot build for multiple platforms in one invocation.\n$details');
    }

    // Step 2: Build with device platform flags.
    String? compilationMode;
    if (profileMode) {
      compilationMode = 'opt';
    } else if (hotReloadEnabled) {
      compilationMode = 'dbg';
    } else {
      compilationMode = config;
    }

    // Debug (JIT) launches await the app's Dart VM service. On Android that
    // service can only bind if the APK holds android.permission.INTERNET —
    // enforcement is kernel-level (AID_INET group) and applies even to
    // 127.0.0.1 — so tell Android devices to preflight the installed package.
    // --allow-no-vm-service opts out of requiring a VM service, so it also
    // skips the preflight (mirroring the post-launch no-VM-service abort).
    if (compilationMode == 'dbg' && !allowNoVmService) {
      for (final device in devices.whereType<AndroidDevice>()) {
        device.expectsVmService = true;
      }
    }

    final allExtraArgs = [
      ...extraArgs,
      ...devices.first.buildArgs,
    ];

    final modeName = profileMode ? 'profile' : (compilationMode ?? 'default');
    logger.fine({
      'message': 'compilation_config',
      'text': 'Compilation mode: $compilationMode, extra args: $allExtraArgs',
      'compilationMode': compilationMode,
      'extraArgs': allExtraArgs,
    });
    logger.info({
      'message': 'building',
      'text': 'Building $target ($modeName mode)...',
      'target': target,
      'mode': modeName,
    });

    final result = await bazelBuild(target,
        workspace: workspace,
        compilationMode: compilationMode,
        extraArgs: allExtraArgs);
    if (!result.success) {
      throw DevToolException('Build failed with exit code ${result.exitCode}',
          exitCode: result.exitCode);
    }

    // Step 3: The built artifact is the primary cquery output for the target.
    if (result.outputFiles.isEmpty) {
      throw DevToolException(
          'Build succeeded but cquery returned no output files for $target.');
    }
    final appFile = devices.first.pickArtifact(result.outputFiles);
    logger.fine({
      'message': 'build_outputs',
      'text': 'Launch artifact: $appFile',
      'outputs': result.outputFiles,
    });

    // Step 3a: For web dev mode, set up module server + frontend server
    // BEFORE launching Chrome, so Chrome opens the module server URL.
    //
    // DDC mode flow:
    //   1. Find _dev_config.json + DDC files in build outputs
    //   2. Generate synthetic web_entrypoint.dart with bootstrapEngine() + plugin registrant
    //   3. Start WebModuleServer with DWDS integration
    //   4. Write first-upload bootstrap files to module server
    //   5. Start frontend_server with --target=dartdevc + filesystem roots
    //   6. Compile org-dartlang-app:/web_entrypoint.dart → update module server
    //   7. Launch Chrome → DWDS connects via injected client
    //
    // WASM mode flow:
    //   1. Serve static files from Bazel build output
    //   2. Launch Chrome → hot restart = re-run bazel build + CDP page reload
    WebModuleServer? webModuleServer;
    final isWebDevice = devices.first is WebDevice;
    if (isWebDevice && !profileMode && hotReloadEnabled && !wasmMode) {
      try {
        // Find dev config in build outputs (emitted by flutter_web_bundle in -c dbg).
        final devConfigPath = findDevConfig(result.outputFiles);
        if (devConfigPath == null) {
          throw DevToolException('No _dev_config.json found in build outputs.\n'
              'Ensure you are building with -c dbg (debug mode).');
        }

        logger.fine({
          'message': 'parsing_dev_config',
          'text': 'Parsing dev config from $devConfigPath...',
          'path': devConfigPath,
        });
        final devConfig = parseDevConfig(devConfigPath);

        // Build web toolchain paths and find web output dir from build outputs.
        final webToolchain = buildWebToolchainFromOutputs(
          result.outputFiles,
          devConfig,
        );
        final webOutputDir = findWebOutputDir(result.outputFiles);

        // Find package_config from build outputs.
        final packageConfig = discoverPackageConfig(result.outputFiles);
        if (packageConfig == null || packageConfig.isEmpty) {
          throw DevToolException(
              'No package_config.json found in build outputs.\n'
              'Ensure the target produces package_config (build with -c dbg).');
        }

        // Generate synthetic web_entrypoint.dart with bootstrapEngine() + plugin registrant.
        final syntheticDir =
            await Directory.systemTemp.createTemp('flutter_ddc_');
        final syntheticMain =
            File(p.join(syntheticDir.path, 'web_entrypoint.dart'));

        // Check for plugin registrant in the build output.
        String? pluginRegistrant;
        for (final f in result.outputFiles) {
          if (f.endsWith('_web_plugin_registrant.dart') ||
              f.endsWith('generated_plugin_registrant.dart')) {
            pluginRegistrant = f;
            break;
          }
        }

        syntheticMain.writeAsStringSync(
          generateSyntheticMainDart(
            appEntrypoint: devConfig.appEntrypoint,
            pluginRegistrantEntrypoint: pluginRegistrant != null
                ? 'package:${packageNameFromEntrypoint(devConfig.appEntrypoint)}/generated_plugin_registrant.dart'
                : null,
          ),
        );

        _resolvedEntrypoint = 'org-dartlang-app:/web_entrypoint.dart';

        // Create the module server with workspace root and package config
        // for DWDS source resolution.
        webModuleServer = WebModuleServer(
          webToolchain: webToolchain,
          buildOutputDir: webOutputDir,
          entrypointFilename: 'web_entrypoint.dart',
          engineRevision: devConfig.engineRevision,
          workspaceRoot: workspace,
          packageConfigPath: packageConfig,
        );

        // Write first-upload bootstrap files to in-memory server.
        webModuleServer.writeFile(
            'manifest.json', '{"info":"manifest not generated in run mode."}');
        webModuleServer.writeFile('flutter_service_worker.js',
            '// Service worker not loaded in run mode.');

        // Start HTTP server first (without DWDS) to get the server URI.
        final serverUri = await webModuleServer.start();

        // Now init DWDS with the server URI for reloadedSourcesUri.
        // Chrome hasn't launched yet — the connection callback is lazy.
        final webDevice = devices.first as WebDevice;
        await webModuleServer.initDwds(
          chromeConnection: () async {
            final cdpPort = webDevice.cdpPort;
            if (cdpPort == null) {
              throw StateError('Chrome CDP port not yet discovered');
            }
            return ChromeConnection('localhost', cdpPort);
          },
          serverUri: serverUri,
        );

        // Set up frontend server with web compiler config + filesystem roots.
        // For a source-assembled (codegen) app, add the dev multi-root dirs
        // (live source + generated bazel-out) so package: URIs resolve to live
        // edits + regenerated parts, and use the dev package_config (scheme
        // rootUri) instead of the build one (frozen .pkgsrcs). devConfig roots
        // are empty for non-codegen apps → behavior unchanged.
        final webPackageConfig = devConfig.devPackageConfig.isNotEmpty
            ? devConfig.devPackageConfig
            : packageConfig;
        final compilerConfig = WebCompilerConfig(
          webToolchain: webToolchain,
          fileSystemRoots: [
            syntheticDir.path,
            workspace,
            ...devConfig.filesystemRoots,
          ],
          dartDefines: devConfig.dartDefines,
        );
        frontendServer = FrontendServer(
          dartaotruntimePath: devConfig.dartaotruntime,
          frontendServerPath: devConfig.frontendServer,
          config: compilerConfig,
          packageConfig: webPackageConfig,
        );
        await frontendServer.start();

        // Compile the synthetic entrypoint.
        final initialResult =
            await frontendServer.compile(_resolvedEntrypoint);
        if (initialResult.success) {
          frontendServer.accept();
          webModuleServer.updateModules(initialResult.dillPath);
          // Seed AppliedVersions so the next reload only sees post-startup
          // edits as changed (not every file as "newly applied"). The resolver
          // keys every source file (app + deps) by its `package:` URI — which is
          // how the frontend_server keys those libraries (the synthetic web
          // entrypoint imports them via `package:` through the dev
          // package_config), so an invalidation actually hits them.
          reloadResolver = PackageUriResolver(
            workspaceRoot: workspace,
            sourcePackages: devConfig.sourcePackages,
          );
          workspaceView = Workspace(
            resolver: reloadResolver,
            generatedFiles: devConfig.generatedFileUris,
          );
          final initialSnap = workspaceView.snapshot();
          appliedVersions.markApplied(initialSnap,
              files: initialSnap.fileUris.toSet());
          // Codegen apps: rebuild generated sources via bazel before each web
          // reload (regenerates `.g.dart`, keeps the execroot forest intact).
          if (devConfig.generatedSourceUris.isNotEmpty) {
            refreshGenerated = () async {
              final r = await bazelBuild(target,
                  workspace: workspace,
                  compilationMode: 'dbg',
                  extraArgs: [...devices.first.buildArgs, ...defineFlags]);
              return r.success;
            };
          }
          hotReloadReady.signalReady();
          logger.info({
            'message': 'frontend_server_ready',
            'text':
                'DDC frontend server ready. Module server at ${webModuleServer.uri}',
          });
        } else {
          throw DevToolException(
              'Initial DDC compile failed.\n${initialResult.diagnostics}');
        }

        // Set module server on WebDevice before launch.
        webDevice.setModuleServer(webModuleServer);
      } catch (e) {
        stderr.writeln('Warning: Could not start DDC dev server: $e');
        stderr.writeln('Falling back to static file serving (no hot restart).');
        await webModuleServer?.stop();
        webModuleServer = null;
        frontendServer = null;
        hotReloadReady.signalUnavailable(
            'DDC dev server failed; hot reload unavailable: $e');
      }
    }

    // Step 3b: Launch on each device and create sessions.
    for (final device in devices) {
      final appId =
          '${target}_${device.name}'.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      protocol.appStart(appId, device.name);
      logger.info({
        'message': 'launching',
        'text': 'Launching on ${device.name}...',
        'device': device.name,
      });

      final AppInstance appInstance;
      try {
        appInstance = await device.launch(appFile);
      } on StateError catch (e) {
        throw DevToolException('Launch failed on ${device.name}: ${e.message}');
      }

      // Connect to VM service (native devices only; web has no VM service).
      //
      // We OWN DDS: start a Dart Development Service on the app's raw VM
      // service and route both our vmClient and DevTools through it. DDS
      // multiplexes clients, so DevTools no longer evicts our connection —
      // the bug that previously forced `--no-devtools` for screenshots.
      VmServiceClient? vmClient;
      DartDevelopmentService? dds;
      String? vmFailureReason;
      if (appInstance.vmServiceUri != null) {
        final rawUri = appInstance.vmServiceUri!;
        try {
          dds = await DartDevelopmentService.startDartDevelopmentService(
            rawUri,
            ipv6: rawUri.host.contains(':'),
          );
        } catch (e) {
          vmFailureReason = 'DDS failed to start on $rawUri: $e';
          stderr.writeln(
              'Warning: Could not start DDS on ${device.name}: $e. '
              'Hot reload, DevTools, and agent control will be unavailable.');
        }

        if (dds != null) {
          final serviceUri = dds.uri!;
          logger.info({
            'message': 'vm_service',
            'text': 'VM service (via DDS) at $serviceUri (${device.name})',
            'uri': serviceUri.toString(),
            'device': device.name,
          });
          protocol.appDebugPort(
            appId,
            serviceUri.replace(
                scheme: serviceUri.scheme == 'https' ? 'wss' : 'ws',
                path: '${serviceUri.path}ws'),
            serviceUri,
          );
          for (var attempt = 0; attempt < 5; attempt++) {
            vmClient = VmServiceClient();
            try {
              await vmClient.connect(serviceUri);
              logger.info({
                'message': 'vm_service_connected',
                'text': 'Connected to VM service (${device.name}).',
                'device': device.name,
              });
              break;
            } catch (e) {
              if (attempt < 4) {
                logger.fine({
                  'message': 'vm_service_retry',
                  'text':
                      'VM service connect attempt ${attempt + 1} failed: $e',
                  'attempt': attempt + 1,
                  'error': '$e',
                });
                await Future<void>.delayed(const Duration(seconds: 1));
              } else {
                vmFailureReason =
                    'could not connect to the VM service at $serviceUri '
                    'after 5 attempts: $e';
                stderr.writeln(
                    'Warning: Could not connect to VM service on ${device.name}: $e');
                vmClient = null;
              }
            }
          }
        }
      } else if (!isWebDevice) {
        vmFailureReason = 'no VM service URI was discovered at launch';
        stderr.writeln(
            'Warning: VM service URI not found on ${device.name}. Hot reload will not be available.');
      }

      // A native session without a vmClient has no hot reload, no DevTools,
      // and no agent control — it is broken, not merely degraded. Abort by
      // default; --allow-no-vm-service opts into continuing anyway. Release
      // and profile builds where no VM service URI was ever discovered are
      // exempt (there may legitimately be none to connect to); a debug build
      // must always produce one.
      if (vmClient == null &&
          !isWebDevice &&
          (appInstance.vmServiceUri != null || compilationMode == 'dbg')) {
        if (allowNoVmService) {
          stderr.writeln(
              'Continuing without a VM service connection on ${device.name} '
              '(--allow-no-vm-service).');
        } else {
          try {
            await device.stop(appInstance);
          } catch (e) {
            stderr.writeln(
                'Warning: failed to stop app on ${device.name} during '
                'abort: $e');
          }
          throw DevToolException(
              'No VM service connection on ${device.name}: '
              '${vmFailureReason ?? 'unknown failure'}. '
              'Hot reload, DevTools, and agent control would all be '
              'unavailable. Pass --allow-no-vm-service to run anyway.');
        }
      }

      // Push initial route if specified.
      if (initialRoute != null && vmClient != null) {
        try {
          await vmClient.callServiceExtension(
            'ext.flutter.pushRoute',
            args: {'route': initialRoute},
          );
        } catch (e) {
          stderr.writeln('Warning: Could not push route on ${device.name}: $e');
        }
      }

      // Trace startup if requested.
      if (traceStartup && vmClient != null) {
        try {
          await vmClient.callServiceExtension(
            'ext.flutter.traceAlloc',
            args: {'enabled': 'true'},
          );
        } catch (e) {
          stderr.writeln(
              'Warning: Could not enable startup tracing on ${device.name}: $e');
        }
      }

      protocol.appStarted(appId);
      sessions.add(DeviceSession(
        device: device,
        appInstance: appInstance,
        vmClient: vmClient,
        appId: appId,
        dds: dds,
      ));
    }

    // For web DDC: now that Chrome is launched, set up DWDS connection + reload strategy.
    if (isWebDevice && webModuleServer != null && !wasmMode) {
      if (webModuleServer.connectedApps != null) {
        // Set up the VM service on EVERY browser connection — not just the
        // first. A web hot restart is a CDP page reload, which tears down the
        // page's isolate and VM service; re-attaching on each (re)connection
        // lets the next hot reload use the live connection instead of a dead
        // one. Matches Flutter's resident_web_runner, which re-attaches per
        // connection.
        final webDevice = devices.first as WebDevice;
        final dwdsReload = DwdsReloadStrategy(
          moduleServer: webModuleServer,
          cdpPort: webDevice.cdpPort,
          appUrl: webModuleServer.uri.toString(),
        );
        reloadStrategy = dwdsReload;

        webModuleServer.connectedApps!.listen((appConnection) async {
          logger.info({
            'message': 'dwds_connected',
            'text':
                'DWDS: Browser connected (app: ${appConnection.request.appId})',
          });
          try {
            final debugConnection =
                await webModuleServer!.debugConnection(appConnection);
            final dwdsUri = Uri.parse(debugConnection.uri);
            final wsUri = dwdsUri.replace(
              scheme: dwdsUri.scheme == 'https' ? 'wss' : 'ws',
              path: '${dwdsUri.path}ws',
            );
            dwdsReload
                .attachVmService(await vm.vmServiceConnectUri(wsUri.toString()));
            logger.info({
              'message': 'dwds_vm_service',
              'text': 'DWDS VM service ready — hot reload enabled.',
            });
          } catch (e) {
            logger.fine({
              'message': 'dwds_vm_service_error',
              'text': 'Could not connect DWDS VM service: $e',
            });
          }
          // Tell the browser to run main() — sends RunRequest via SSE. Must
          // happen after debug setup so DWDS can set breakpoints.
          appConnection.runMain();
        });
      }
    }

    // For web WASM: set up bazel rebuild + CDP page reload strategy.
    if (isWebDevice && wasmMode) {
      final webDevice = devices.first as WebDevice;
      if (webDevice.cdpPort != null) {
        reloadStrategy = WasmReloadStrategy(
          cdpPort: webDevice.cdpPort!,
          appUrl: webDevice.appUrl,
          rebuild: () async {
            logger.info({
              'message': 'wasm_rebuild',
              'text': 'Rebuilding $target (WASM)...',
            });
            final rebuildResult = await bazelBuild(target,
                workspace: workspace,
                compilationMode: compilationMode,
                extraArgs: allExtraArgs);
            return rebuildResult.success;
          },
        );

        // Register WASM-specific restart handler that bypasses frontend server.
        commandRunner.register('app.restart', (params) async {
          stdout.writeln('Performing WASM hot restart...');
          final stopwatch = Stopwatch()..start();
          final strategy = reloadStrategy as WasmReloadStrategy;
          // Dummy CompileResult — WASM doesn't use frontend server.
          final dummyResult = CompileResult(
            dillPath: '',
            success: true,
          );
          final ok = await strategy.applyRestart(dummyResult, sessions);
          stopwatch.stop();
          if (ok) {
            return {
              'message':
                  'Restart successful (${stopwatch.elapsedMilliseconds}ms)'
            };
          }
          return {'message': 'WASM restart failed'};
        });

        commandRunner.register('app.hotReload', (params) async {
          return {
            'message': 'Hot reload not supported in WASM mode. Use restart (R).'
          };
        });
      }
    }

    // Step 4: For native devices, start shared frontend_server AFTER launch.
    final hasVmClient = sessions.any((s) => s.vmClient != null);
    if (!isWebDevice && hasVmClient && !profileMode) {
      try {
        if (frontendServer == null) {
          logger.fine({
            'message': 'resolving_toolchain',
            'text': 'Resolving toolchain paths for $target...',
            'target': target,
          });
          final toolchain =
              await resolveToolchainPaths(target, workspace: workspace);
          // Build the flutter_application target directly to materialize its
          // DefaultInfo — the hot-reload `_dev_config.json` + dev
          // `package_config.json`. The platform wrapper (`:app_macos`) consumes
          // the flutter_application via providers, not files, so building it
          // alone never produces these. Using the app target's own outputs also
          // keeps the dev config's config-specific paths self-consistent.
          final devAppLabel = await bazelCqueryFlutterAppLabel(
            target,
            workspace: workspace,
            compilationMode: 'dbg',
            extraArgs: [...devices.first.buildArgs, ...defineFlags],
          );
          if (devAppLabel == null) {
            throw DevToolException(
                'No flutter_application found in deps of $target.');
          }
          final flutterAppOutputs = (await bazelBuild(
            devAppLabel,
            workspace: workspace,
            compilationMode: 'dbg',
            extraArgs: [...devices.first.buildArgs, ...defineFlags],
          ))
              .outputFiles;
          // The build tells us the entrypoint + hot-reload layout via
          // _dev_config.json; we never infer them from package_config rootUri
          // shapes.
          final devConfigPath = findDevConfig(flutterAppOutputs);
          if (devConfigPath == null) {
            throw DevToolException(
                'No _dev_config.json in flutter_application outputs '
                '(build with -c dbg).\nOutputs: $flutterAppOutputs');
          }
          final devConfig = parseDevConfig(devConfigPath);
          // The dev package_config points a source-assembled app package at the
          // live source + generated roots via filesystemScheme; for non-codegen
          // apps it equals the build config.
          final packageConfig = devConfig.devPackageConfig.isNotEmpty
              ? devConfig.devPackageConfig
              : discoverPackageConfig(flutterAppOutputs);
          if (packageConfig == null || packageConfig.isEmpty) {
            throw DevToolException(
                'Could not find a package_config.json in flutter_application '
                'outputs.\nflutter_application outputs: $flutterAppOutputs');
          }

          final compilerConfig = devices.first.createCompilerConfig(
            toolchain,
            fileSystemRoots: devConfig.filesystemRoots,
            fileSystemScheme: devConfig.filesystemScheme,
            dartDefines: devConfig.dartDefines,
            dartPluginRegistrantUri: devConfig.dartPluginRegistrant.isEmpty
                ? ''
                : Uri.file(devConfig.dartPluginRegistrant).toString(),
          );

          if (compilerConfig != null) {
            frontendServer = FrontendServer(
              dartaotruntimePath: toolchain.dartaotruntime,
              frontendServerPath: toolchain.frontendServer,
              config: compilerConfig,
              packageConfig: packageConfig,
            );
            await frontendServer.start();
            _resolvedEntrypoint = devConfig.appEntrypoint;
            final initialResult =
                await frontendServer.compile(_resolvedEntrypoint);
            if (initialResult.success) {
              frontendServer.accept();
              // Seed the per-file applied state and construct the
              // orchestrator. Native devices apply via per-AppInstance
              // VmServiceClient with a bounded RPC budget.
              reloadResolver = PackageUriResolver(
                workspaceRoot: workspace,
                sourcePackages: devConfig.sourcePackages,
              );
              workspaceView = Workspace(
                resolver: reloadResolver,
                generatedFiles: devConfig.generatedFileUris,
              );
              final initialSnap = workspaceView.snapshot();
              appliedVersions.markApplied(initialSnap,
                  files: initialSnap.fileUris.toSet());

              // Hot restart (runInView) re-runs main() in a fresh isolate and
              // must re-specify the asset bundle; give each VM client the app's
              // flutter_assets dir from the build outputs.
              final assetsDir = flutterAppOutputs.firstWhere(
                (f) => f.endsWith('flutter_assets'),
                orElse: () => '',
              );
              if (assetsDir.isNotEmpty) {
                for (final s in sessions) {
                  s.vmClient?.assetDirectory = assetsDir;
                }
              }

              final apps = <hr.AppInstance>[
                for (final s in sessions)
                  if (s.vmClient != null)
                    hr.VmServiceAppInstance(id: s.appId, client: s.vmClient!),
              ];
              if (apps.isNotEmpty) {
                // For codegen apps, rebuild the flutter_application via bazel
                // before each reload/restart so edits to codegen inputs are
                // regenerated. We rebuild the whole app target (not just the
                // narrow codegen target) on purpose: a narrow build rebuilds the
                // execroot symlink forest to ONLY its own inputs, pruning the
                // flutter SDK that the frontend_server reads via --filesystem-root
                // — which then breaks the next full compile (hot restart). The
                // app target's input set keeps everything materialized, and it's
                // a cache hit when nothing changed. Null for non-codegen apps →
                // no bazel build on edit (today's instant path).
                if (devConfig.generatedSourceUris.isNotEmpty) {
                  refreshGenerated = () async {
                    final r = await bazelBuild(devAppLabel,
                        workspace: workspace,
                        compilationMode: 'dbg',
                        extraArgs: [
                          ...devices.first.buildArgs,
                          ...defineFlags,
                        ]);
                    return r.success;
                  };
                }
                orchestrator = ReloadOrchestrator(
                  workspace: workspaceView,
                  applied: appliedVersions,
                  compiler: hot_reload.FrontendServerCompiler(frontendServer),
                  apps: apps,
                  entrypoint: _resolvedEntrypoint,
                  refreshGenerated: refreshGenerated,
                );

                // A hot restart cannot replace dlopened native libraries.
                // Record the launched bundle's loose-native-lib fingerprint;
                // app.restart rebuilds and, when the fingerprint changed,
                // relaunches the process instead of restarting the isolate.
                // Apps with no loose native libraries skip all of this and
                // keep the instant restart path.
                var liveNativeLibsFp = await nativeLibsFingerprint(appFile);
                if (liveNativeLibsFp.isNotEmpty) {
                  relaunchIfNativeLibsChanged = () async {
                    // Rebuild the launch target (not devAppLabel: the dev
                    // outputs don't include the bundle the process runs).
                    final r = await bazelBuild(target,
                        workspace: workspace,
                        compilationMode: compilationMode,
                        extraArgs: allExtraArgs);
                    if (!r.success) {
                      return {
                        'error':
                            'bazel build failed during restart; see build output.'
                      };
                    }
                    final fp = await nativeLibsFingerprint(appFile);
                    if (fingerprintsEqual(fp, liveNativeLibsFp)) return null;
                    final changed = changedLibs(liveNativeLibsFp, fp);
                    logger.info({
                      'message': 'native_libs_changed',
                      'text':
                          'Native libraries changed (${changed.join(', ')}); relaunching.',
                      'libs': changed,
                    });
                    for (final s in sessions) {
                      if (s.appInstance.vmServiceUri == null) continue;
                      await s.vmClient?.disconnect();
                      await s.device.stop(s.appInstance);
                      final inst = await s.device.launch(appFile);
                      VmServiceClient? client;
                      if (inst.vmServiceUri != null) {
                        for (var attempt = 0; attempt < 5; attempt++) {
                          client = VmServiceClient();
                          try {
                            await client.connect(inst.vmServiceUri!);
                            break;
                          } catch (_) {
                            client = null;
                            if (attempt < 4) {
                              await Future<void>.delayed(
                                  const Duration(seconds: 1));
                            }
                          }
                        }
                      }
                      s.appInstance = inst;
                      s.vmClient = client;
                      if (client != null && inst.vmServiceUri != null) {
                        final uri = inst.vmServiceUri!;
                        protocol.appDebugPort(
                          s.appId,
                          uri.replace(
                              scheme: uri.scheme == 'https' ? 'wss' : 'ws',
                              path: '${uri.path}ws'),
                          uri,
                        );
                        if (assetsDir.isNotEmpty) {
                          client.assetDirectory = assetsDir;
                        }
                      }
                      protocol.appStarted(s.appId);
                    }
                    orchestrator?.apps
                      ?..clear()
                      ..addAll([
                        for (final s in sessions)
                          if (s.vmClient != null)
                            hr.VmServiceAppInstance(
                                id: s.appId, client: s.vmClient!),
                      ]);
                    // The relaunched process runs the freshly built kernel:
                    // every disk file is now live.
                    final snap = workspaceView!.snapshot();
                    appliedVersions.clear();
                    appliedVersions.markApplied(snap,
                        files: snap.fileUris.toSet());
                    liveNativeLibsFp = fp;
                    return {
                      'message':
                          'Restart relaunched the app: native libraries changed (${changed.join(', ')}).',
                      'relaunched': true,
                      'nativeLibsChanged': changed,
                    };
                  };
                }
                hotReloadReady.signalReady();
              }
              logger.info({
                'message': 'frontend_server_ready',
                'text': 'Frontend server ready for incremental compilation.',
              });
            } else {
              stderr.writeln(
                  'Warning: Initial compile failed. Hot reload may not work.');
              if (initialResult.diagnostics.isNotEmpty) {
                stderr.write(initialResult.diagnostics);
              }
              hotReloadReady.signalUnavailable(
                  'Initial compile failed; hot reload is unavailable.');
            }

            reloadStrategy = devices.first.createReloadStrategy();
          }
        }
      } catch (e) {
        stderr.writeln('Warning: Could not start frontend server: $e');
        stderr.writeln('Hot reload will not be available.');
        frontendServer = null;
        hotReloadReady.signalUnavailable(
            'Could not start frontend server: $e');
      }
    }

    // Any setup path that neither wired the pipeline nor recorded a specific
    // failure (profile mode, WASM, no VM client, compiler config absent)
    // settles the gate here so `app.hotReload` / `app.restart` return a
    // clear error instead of waiting on a signal that will never come.
    if (!hotReloadReady.isSettled) {
      hotReloadReady
          .signalUnavailable('Hot reload is not available for this run.');
    }

    // Start HTTP control channel if enabled.
    if (httpChannelEnabled) {
      httpChannel = HttpControlChannel(
        commandRunner: commandRunner,
        findSession: findSession,
      );
      await httpChannel.start();
      final base = httpChannel.uri;
      final t = httpChannel.token;
      logger.info({
        'message': 'http_control_channel',
        'text': 'HTTP control channel:\n'
            '  POST $base/command?token=$t  — execute a machine protocol command\n'
            '  GET  $base/sessions/{appId}/screenshot/flutter?token=$t  — Flutter widget tree screenshot (PNG)\n'
            '  GET  $base/sessions/{appId}/screenshot/native?token=$t  — native OS screenshot (PNG)',
        'uri': base.toString(),
        'token': t,
      });
    }

    // The channel must outlive the session loop: an `app.stop` arriving over
    // HTTP is still flushing its response when the loop ends, so the channel
    // is stopped (gracefully, draining in-flight requests) only on the way
    // out.
    try {
      // Profile mode enters an interactive session (without hot reload).
      // This allows DevTools connection, performance overlay, and key handlers.
      if (profileMode) {
        if (sessions.isNotEmpty) {
          await runInteractiveSession(
            sessions: sessions,
            frontendServer: frontendServer,
            // Profile mode has no hot reload, so the entrypoint is unused.
            entrypoint: _resolvedEntrypoint ?? '',
            workspace: workspace,
            protocol: protocol,
            commandRunner: commandRunner,
            devToolsEnabled: devToolsEnabled,
            hotReloadEnabled: false,
            watchEnabled: false,
            shutdownSignal: shutdownRequested.future,
          );
        }
        return;
      }

      // Step 5-6: Watch files and handle keyboard input via shared session
      // loop. _resolvedEntrypoint is set by the native frontend-server block
      // (from the dev config) or the web block; the fallback below covers the
      // no-hot-reload case where the entrypoint is unused.
      _resolvedEntrypoint ??= '';

      if (frontendServer != null || isWebDevice) {
        await runInteractiveSession(
          sessions: sessions,
          frontendServer: frontendServer,
          entrypoint: _resolvedEntrypoint,
          workspace: workspace,
          protocol: protocol,
          commandRunner: commandRunner,
          devToolsEnabled: devToolsEnabled && !profileMode,
          watchEnabled: watchEnabled,
          reloadStrategy: reloadStrategy,
          resolver: reloadResolver,
          shutdownSignal: shutdownRequested.future,
        );
      } else {
        // No hot reload possible — wait for first device to exit.
        if (sessions.isNotEmpty) {
          await sessions.first.appInstance.process.exitCode;
        }
      }
    } finally {
      await httpChannel?.stop();
      await protocol.stopListening();
    }
  }

}

/// The package name from a `package:<name>/...` entrypoint URI, or null.
String? packageNameFromEntrypoint(String entrypoint) {
  const prefix = 'package:';
  if (!entrypoint.startsWith(prefix)) return null;
  final rest = entrypoint.substring(prefix.length);
  final slash = rest.indexOf('/');
  return slash > 0 ? rest.substring(0, slash) : null;
}

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

