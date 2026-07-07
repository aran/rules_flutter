/// The `attach` command — connects to an already-running Flutter app.
///
/// Skips build and launch. Connects directly to a running app's VM service
/// URI, then enters the same interactive session (hot reload, DevTools, etc.)
/// as `run`.
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'bazel.dart';
import 'command_runner.dart';
import 'compiler_config.dart';
import 'device.dart';
import 'frontend_server.dart';
import 'http_control_channel.dart';
import 'logging.dart';
import 'machine_protocol.dart';
import 'run_command.dart';
import 'session.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';

class AttachCommand {
  static final parser = ArgParser()
    ..addMultiOption('debug-url',
        help: 'VM service URL of a running app (repeatable for multi-attach).')
    ..addOption('target',
        abbr: 't',
        help: 'Bazel target (for toolchain resolution).',
        mandatory: true)
    ..addFlag('machine',
        defaultsTo: false, help: 'Enable machine-readable JSON protocol.')
    ..addFlag('devtools',
        defaultsTo: true, help: 'Launch DevTools for each connection.')
    ..addMultiOption('dart-define',
        splitCommas: false,
        help: 'Dart environment define (KEY=VALUE) the running app was built '
            'with. Forwarded to the dev-config build so reload recompiles '
            'reproduce the app\'s configuration. Repeat for multiple defines.')
    ..addFlag('verbose', abbr: 'v', defaultsTo: false, help: 'Enable verbose debug logging.')
    ..addFlag('http-control-channel',
        defaultsTo: true,
        help: 'Expose an HTTP control channel for external command dispatch '
            '(screenshots, app.* driving). On by default; disable with '
            '--no-http-control-channel. The bound URI and auth token are '
            'printed at startup.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help for this command.');

  final ArgResults _results;

  AttachCommand(this._results);

  Future<void> execute() async {
    final debugUrls = _results['debug-url'] as List<String>;
    final target = _results['target'] as String;
    // Attach builds the flutter_application itself to obtain the dev config;
    // the flags reproduce the running app's build configuration so that
    // build resolves the same dev config (incl. its dartDefines).
    final defineFlags =
        dartDefineFlags(_results['dart-define'] as List<String>);
    final isMachine = _results['machine'] as bool;
    final devToolsEnabled = _results['devtools'] as bool;
    final httpChannelEnabled = _results['http-control-channel'] as bool;

    if (debugUrls.isEmpty) {
      throw DevToolException('At least one --debug-url is required.');
    }

    // Resolve workspace once. Used both for inner `bazel` spawns
    // (workingDirectory) and for the interactive session below.
    final workspace = await findWorkspaceRoot();

    final sessions = <DeviceSession>[];
    FrontendServer? frontendServer;
    HttpControlChannel? httpChannel;

    final commandRunner = CommandRunner();
    final protocol = MachineProtocol(
      enabled: isMachine,
      commandRunner: commandRunner,
    );

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
    /// — by which point the response has flushed. The shutdown signal is also
    /// what ends the session loop at all here: attach mode's pseudo-process
    /// never exits, so the loop cannot end via a device process exit.
    Future<void> performCleanup() async {
      for (final session in sessions) {
        protocol.appStop(session.appId);
        await session.vmClient?.disconnect();
      }
      await frontendServer?.shutdown();
      if (!shutdownRequested.isCompleted) shutdownRequested.complete();
    }

    commandRunner.register('app.stop', (_) async {
      await performCleanup();
      return {'message': 'stopped'};
    });
    commandRunner.register('daemon.shutdown', (_) async {
      await performCleanup();
      return {'message': 'shutdown'};
    });

    protocol.startListening();

    final logger = Logger('dev_tool.attach');

    // Connect to each running app.
    for (var i = 0; i < debugUrls.length; i++) {
      final uri = Uri.parse(debugUrls[i]);
      final appId = 'attach_$i';
      final deviceName = 'attached:${uri.host}:${uri.port}';

      protocol.appStart(appId, deviceName);
      logger.info({
        'message': 'connecting',
        'text': 'Connecting to $uri...',
        'uri': uri.toString(),
      });

      final vmClient = VmServiceClient();
      try {
        await vmClient.connect(uri);
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
            path: '${uri.path}ws'),
        uri,
      );
      protocol.appStarted(appId);

      sessions.add(DeviceSession(
        device: _AttachedPseudoDevice(deviceName),
        appInstance: _AttachedAppInstance(uri),
        vmClient: vmClient,
        appId: appId,
      ));
    }

    // Build the flutter_application target directly to materialize its
    // DefaultInfo — the hot-reload `_dev_config.json` + dev
    // `package_config.json`. The platform wrapper (e.g. `:app`) consumes the
    // flutter_application via providers, not files, so building the wrapper
    // alone never produces them. Same sequence as RunCommand's native path.
    String? packageConfigPath;
    DevConfig? devConfig;
    try {
      final devAppLabel = await bazelCqueryFlutterAppLabel(target,
          workspace: workspace, compilationMode: 'dbg', extraArgs: defineFlags);
      if (devAppLabel == null) {
        throw StateError('No flutter_application found in deps of $target.');
      }
      final flutterAppOutputs = (await bazelBuild(devAppLabel,
              workspace: workspace,
              compilationMode: 'dbg',
              extraArgs: defineFlags))
          .outputFiles;
      final devConfigPath = findDevConfig(flutterAppOutputs);
      if (devConfigPath != null) {
        devConfig = parseDevConfig(devConfigPath);
      }
      packageConfigPath = (devConfig?.devPackageConfig.isNotEmpty ?? false)
          ? devConfig!.devPackageConfig
          : discoverPackageConfig(flutterAppOutputs);
    } catch (e) {
      logger.fine({
        'message': 'build_for_config_failed',
        'text': 'Could not build target for package_config discovery: $e',
      });
    }

    // Resolve toolchain and start frontend server.
    try {
      final toolchain =
          await resolveToolchainPaths(target, workspace: workspace);
      if (packageConfigPath == null || packageConfigPath.isEmpty) {
        throw StateError(
            'Could not find package_config.json in build outputs for $target.');
      }
      frontendServer = FrontendServer(
        dartaotruntimePath: toolchain.dartaotruntime,
        frontendServerPath: toolchain.frontendServer,
        config: NativeCompilerConfig(
          patchedSdkRoot: toolchain.patchedSdkRoot,
          fileSystemRoots: devConfig?.filesystemRoots ?? const [],
          fileSystemScheme: devConfig?.filesystemScheme ?? '',
          dartDefines: devConfig?.dartDefines ?? const [],
        ),
        packageConfig: packageConfigPath,
      );
      await frontendServer.start();
      logger.info({
        'message': 'frontend_server_ready',
        'text': 'Frontend server ready.',
      });
    } catch (e) {
      stderr.writeln('Warning: Could not start frontend server: $e');
      stderr.writeln('Hot reload will not be available.');
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

    // The entrypoint is the build-authoritative package: URI from the dev
    // config. (Attach does not yet rebuild generated sources on change — that
    // lives in the `run` orchestrator path.)
    final entrypoint = devConfig?.appEntrypoint ?? '';

    try {
      if (frontendServer != null) {
        await runInteractiveSession(
          sessions: sessions,
          frontendServer: frontendServer,
          entrypoint: entrypoint,
          workspace: workspace,
          protocol: protocol,
          commandRunner: commandRunner,
          devToolsEnabled: devToolsEnabled,
          shutdownSignal: shutdownRequested.future,
        );
      } else {
        throw DevToolException(
            'Cannot start interactive session without frontend server.');
      }
    } finally {
      await httpChannel?.stop();
      await protocol.stopListening();
    }
  }
}

/// A pseudo-device for attach mode — doesn't launch or stop anything.
class _AttachedPseudoDevice extends Device {
  final String _name;
  _AttachedPseudoDevice(this._name);

  @override
  String get name => _name;

  @override
  Future<AppInstance> launch(String appPath) =>
      throw UnsupportedError('Attach mode does not launch apps');

  @override
  Future<void> stop(AppInstance instance) async {
    // Nothing to stop — the app was started externally.
  }
}

/// A fake AppInstance for attach mode.
class _AttachedAppInstance extends AppInstance {
  _AttachedAppInstance(Uri vmServiceUri)
      : super(process: _NoOpProcess(), vmServiceUri: vmServiceUri);
}

/// A no-op process for attach mode.
class _NoOpProcess implements Process {
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => throw UnsupportedError('No stdin for attached process');
  @override
  int get pid => -1;
  @override
  Future<int> get exitCode => Completer<int>().future; // Never completes.
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}
