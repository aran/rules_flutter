/// Per-device session state and shared interactive session loop.
///
/// A [DeviceSession] holds the runtime state for one device: the launched
/// app instance, VM service client, and optional DevTools URL. The shared
/// [runInteractiveSession] function drives the file watcher, keyboard
/// loop, and hot reload across all active sessions.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:watcher/watcher.dart';

import 'command_runner.dart';
import 'device.dart';
import 'frontend_server.dart';
import 'hot_reload/package_uri_resolver.dart';
import 'machine_protocol.dart';
import 'reload_strategy.dart';
import 'vm_service_client.dart';

/// Runtime state for a single device in a multi-device run.
class DeviceSession {
  final Device device;

  /// Mutable: a restart that finds changed native libraries relaunches the
  /// process, replacing the instance and its VM service connection.
  AppInstance appInstance;
  VmServiceClient? vmClient;
  final String appId;
  String? devToolsUrl;
  Process? devToolsProcess;

  DeviceSession({
    required this.device,
    required this.appInstance,
    required this.vmClient,
    required this.appId,
  });
}

/// Result of a compile + reload/restart operation.
class ReloadResult {
  /// Whether the compile step succeeded.
  final bool compileSuccess;

  /// Whether all devices were successfully reloaded/restarted.
  final bool deviceSuccess;

  final String diagnostics;
  final int elapsedMs;

  /// Overall success: both compile and device steps succeeded.
  bool get success => compileSuccess && deviceSuccess;

  ReloadResult({
    required this.compileSuccess,
    this.deviceSuccess = true,
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
/// If no [reloadStrategy] is provided, falls back to [VmServiceReloadStrategy].
Future<ReloadResult> recompileAndReload({
  required FrontendServer frontendServer,
  required String entrypoint,
  required List<String> invalidatedFiles,
  required List<DeviceSession> sessions,
  ReloadStrategy? reloadStrategy,
}) async {
  final strategy = reloadStrategy ?? VmServiceReloadStrategy();
  final stopwatch = Stopwatch()..start();
  try {
    final result =
        await frontendServer.recompile(entrypoint, invalidatedFiles);
    if (!result.success) {
      frontendServer.reject();
      stopwatch.stop();
      return ReloadResult(
        compileSuccess: false,
        diagnostics: result.diagnostics,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    }
    frontendServer.accept();
    final allOk = await strategy.applyReload(result, sessions);
    stopwatch.stop();
    return ReloadResult(
      compileSuccess: true,
      deviceSuccess: allOk,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  } catch (e) {
    stopwatch.stop();
    return ReloadResult(
      compileSuccess: false,
      diagnostics: e.toString(),
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }
}

/// Full recompile and hot restart all devices.
///
/// Calls [FrontendServer.compile] to rebuild from scratch, then applies
/// the result via [reloadStrategy].
///
/// If no [reloadStrategy] is provided, falls back to [VmServiceReloadStrategy].
Future<ReloadResult> recompileAndRestart({
  required FrontendServer frontendServer,
  required String entrypoint,
  required List<DeviceSession> sessions,
  ReloadStrategy? reloadStrategy,
}) async {
  final strategy = reloadStrategy ?? VmServiceReloadStrategy();
  final stopwatch = Stopwatch()..start();
  try {
    final result = await frontendServer.compile(entrypoint);
    if (!result.success) {
      stopwatch.stop();
      return ReloadResult(
        compileSuccess: false,
        diagnostics: result.diagnostics,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    }
    frontendServer.accept();
    final allOk = await strategy.applyRestart(result, sessions);
    stopwatch.stop();
    return ReloadResult(
      compileSuccess: true,
      deviceSuccess: allOk,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  } catch (e) {
    stopwatch.stop();
    return ReloadResult(
      compileSuccess: false,
      diagnostics: e.toString(),
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }
}

/// Signature for reading keyboard input (allows test injection).
typedef KeyboardReader = Stream<List<int>> Function();

/// Run the shared interactive session loop for one or more device sessions.
///
/// Handles file watching, keyboard input, and broadcasting hot reload/restart
/// across all sessions. Returns when the user quits or all sessions end.
///
/// When [hotReloadEnabled] is false (e.g. profile mode), file watching and
/// hot reload ('r') are disabled but DevTools, perf overlay, inspector, and
/// quit still work.
Future<void> runInteractiveSession({
  required List<DeviceSession> sessions,
  required FrontendServer? frontendServer,
  required String entrypoint,
  required String workspace,
  required MachineProtocol protocol,
  CommandRunner? commandRunner,
  required bool devToolsEnabled,
  bool hotReloadEnabled = true,
  bool watchEnabled = true,
  ReloadStrategy? reloadStrategy,
  PackageUriResolver? resolver,
  void Function(String message)? log,
  KeyboardReader? keyboardReader,
  void Function(bool echoMode)? setEchoMode,
  void Function(bool lineMode)? setLineMode,
  Future<void> Function(String url)? openBrowser,
}) async {
  log ??= (msg) => stdout.writeln(msg);

  // Launch DevTools for each session with a VM client.
  if (devToolsEnabled) {
    for (final session in sessions) {
      if (session.vmClient != null && session.appInstance.vmServiceUri != null) {
        try {
          final devtools = await _launchDevTools(session.appInstance.vmServiceUri!);
          session.devToolsProcess = devtools.process;
          if (devtools.url != null) {
            session.devToolsUrl = devtools.url;
            log('DevTools at ${devtools.url} (${session.device.name})');
            if (openBrowser != null) {
              await openBrowser(devtools.url!);
            } else {
              await _openInBrowser(devtools.url!);
            }
          }
        } catch (e) {
          // Non-fatal: DevTools is optional.
          stderr.writeln('Warning: Could not launch DevTools for ${session.device.name}: $e');
        }
      }
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
    if (hotReloadEnabled) {
      if (watchEnabled) {
        log('Watching for file changes. Press "r" hot reload, "R" restart, "p" perf overlay, "i" inspector, "q" quit.');
      } else {
        log('Press "r" hot reload, "R" restart, "p" perf overlay, "i" inspector, "q" quit.');
      }
    } else {
      log('Press "p" perf overlay, "i" inspector, "q" quit.');
    }
  }

  // Start file watcher (only if watching is enabled, hot reload is enabled,
  // and frontend server is available).
  StreamSubscription<WatchEvent>? watcherSubscription;
  Timer? debounce;
  if (watchEnabled && hotReloadEnabled && frontendServer != null) {
    final watchResult = _watchAndReload(
      workspace: workspace,
      frontendServer: frontendServer,
      sessions: sessions,
      entrypoint: entrypoint,
      resolver: resolver,
      commandRunner: commandRunner,
      reloadStrategy: reloadStrategy,
    );
    watcherSubscription = watchResult.subscription;
    debounce = watchResult.debounce;
  }

  // In machine mode, stdin is consumed by MachineProtocol — skip the
  // keyboard loop and wait for sessions to end via machine commands.
  if (protocol.enabled) {
    // Wait until all device processes exit or the process is killed.
    final exitFutures = sessions
        .map((s) => s.appInstance.process.exitCode)
        .toList();
    if (exitFutures.isNotEmpty) {
      await Future.any(exitFutures);
    }
    debounce?.cancel();
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

  await for (final input in inputStream) {
    final char = String.fromCharCode(input.first);
    switch (char) {
      case 'r':
        if (hotReloadEnabled) {
          if (commandRunner != null && commandRunner.hasCommand('app.hotReload')) {
            await commandRunner.run('app.hotReload', {});
          } else if (frontendServer != null) {
            await _performHotReloadAll(
              frontendServer: frontendServer,
              sessions: sessions,
              entrypoint: entrypoint,
              invalidated: [entrypoint],
              reloadStrategy: reloadStrategy,
            );
          }
        }
      case 'R':
        if (hotReloadEnabled) {
          if (commandRunner != null && commandRunner.hasCommand('app.restart')) {
            stdout.writeln('Performing hot restart...');
            await commandRunner.run('app.restart', {});
          } else if (frontendServer != null) {
            stdout.writeln('Performing hot restart...');
            final result = await recompileAndRestart(
              frontendServer: frontendServer,
              entrypoint: entrypoint,
              sessions: sessions,
              reloadStrategy: reloadStrategy,
            );
            if (!result.compileSuccess) {
              stderr.writeln('Compilation failed.');
              if (result.diagnostics.isNotEmpty) {
                stderr.write(result.diagnostics);
              }
            } else if (!result.deviceSuccess) {
              stderr.writeln('Hot restart failed on some devices.');
            } else {
              stdout.writeln('Hot restart done in ${result.elapsedMs}ms.');
            }
          }
        }
      case 'p':
        for (final session in sessions) {
          if (session.vmClient != null) {
            final enabled = await session.vmClient!.togglePerformanceOverlay();
            stdout.writeln('Performance overlay ${enabled ? "enabled" : "disabled"} (${session.device.name}).');
          }
        }
      case 'i':
        for (final session in sessions) {
          if (session.vmClient != null) {
            final enabled = await session.vmClient!.toggleWidgetInspector();
            stdout.writeln('Widget inspector ${enabled ? "enabled" : "disabled"} (${session.device.name}).');
          }
        }
      case 'q':
        // Cancel debounce timer before cancelling watcher.
        debounce?.cancel();
        await watcherSubscription?.cancel();
        for (final session in sessions) {
          session.devToolsProcess?.kill();
          protocol.appStop(session.appId);
          await session.vmClient?.disconnect();
          await session.device.stop(session.appInstance);
        }
        if (frontendServer != null) {
          await frontendServer.shutdown();
        }
        return;
    }
  }
}

/// Result from _watchAndReload containing the subscription and debounce timer
/// so they can be properly cancelled.
({StreamSubscription<WatchEvent> subscription, Timer? debounce}) _watchAndReload({
  required String workspace,
  required FrontendServer frontendServer,
  required List<DeviceSession> sessions,
  required String entrypoint,
  PackageUriResolver? resolver,
  CommandRunner? commandRunner,
  ReloadStrategy? reloadStrategy,
}) {
  final watcher = DirectoryWatcher(workspace);
  Timer? debounce;
  final changedFiles = <String>{};

  final subscription = watcher.events.listen((event) {
    if (!event.path.endsWith('.dart')) return;
    if (event.path.contains('bazel-')) return;

    changedFiles.add(event.path);

    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 200), () async {
      final files = changedFiles.toList();
      changedFiles.clear();

      // Map each changed source path to the `package:` URI the frontend_server
      // keys it by, via the authoritative build-emitted resolver. A path that
      // belongs to no first-party source package (e.g. a tool script) resolves
      // to null and is skipped — never invalidated with a bogus file:// URI.
      final invalidated = [
        for (final f in files)
          if (resolver?.toPackageUri(f) case final uri?) uri,
      ];
      if (invalidated.isEmpty) return;

      if (commandRunner != null && commandRunner.hasCommand('app.hotReload')) {
        await commandRunner.run('app.hotReload', {
          'invalidatedFiles': invalidated,
        });
      } else {
        await _performHotReloadAll(
          frontendServer: frontendServer,
          sessions: sessions,
          entrypoint: entrypoint,
          invalidated: invalidated,
          reloadStrategy: reloadStrategy,
        );
      }
    });
  });

  return (subscription: subscription, debounce: debounce);
}

/// Terminal-mode wrapper around [recompileAndReload] that prints status to
/// stdout/stderr.
Future<void> _performHotReloadAll({
  required FrontendServer frontendServer,
  required List<DeviceSession> sessions,
  required String entrypoint,
  required List<String> invalidated,
  ReloadStrategy? reloadStrategy,
}) async {
  stdout.writeln('Recompiling...');
  final result = await recompileAndReload(
    frontendServer: frontendServer,
    entrypoint: entrypoint,
    invalidatedFiles: invalidated,
    sessions: sessions,
    reloadStrategy: reloadStrategy,
  );
  if (!result.compileSuccess) {
    stderr.writeln('Compilation failed.');
    if (result.diagnostics.isNotEmpty) {
      stderr.write(result.diagnostics);
    }
  } else if (!result.deviceSuccess) {
    stderr.writeln('Hot reload failed on some devices. Try hot restart (R).');
  } else {
    stdout.writeln('Hot reload done in ${result.elapsedMs}ms.');
  }
}

/// Launch dart devtools and return the process and serving URL.
Future<({Process process, String? url})> _launchDevTools(Uri vmServiceUri) async {
  final process = await Process.start(
    'dart',
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
    final match = RegExp(r'Serving DevTools at (http\S+)').firstMatch(line);
    if (match != null && !completer.isCompleted) {
      timeout?.cancel();
      completer.complete(match.group(1));
    }
  });

  final url = await completer.future;
  return (process: process, url: url);
}

/// Open a URL in the default browser.
Future<void> _openInBrowser(String url) async {
  if (Platform.isMacOS) {
    await Process.run('open', [url]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [url]);
  } else if (Platform.isWindows) {
    await Process.run('cmd', ['/c', 'start', url]);
  }
}

