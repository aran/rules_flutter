/// JSON-RPC machine protocol for IDE integration.
///
/// When the dev tool is invoked with `--machine`, it speaks the same
/// protocol as `flutter run --machine` over stdin/stdout. This enables
/// VS Code, IntelliJ, and other IDEs to control the dev tool.
///
/// Events (tool → IDE):
///   daemon.connected   — daemon is ready (version info)
///   app.start          — app is launching
///   app.debugPort      — VM service URI available
///   app.started        — app is running and ready for interaction
///   app.log            — log output from the app
///   app.progress       — build/reload progress updates
///   app.stop           — app has stopped
///
/// Commands (IDE → tool):
///   app.restart            — hot restart
///   app.stop               — stop the app
///   app.callServiceExtension — forward to VM service
///   daemon.shutdown        — shut down the dev tool
///   daemon.getSupportedPlatforms — list supported platforms
///   device.getDevices      — return connected devices
///   device.enable          — enable device events
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'command_runner.dart';

/// Machine-readable JSON protocol handler.
class MachineProtocol {
  final bool enabled;
  final IOSink _output;
  final Stream<String>? _inputLines;
  final CommandRunner? _commandRunner;
  int _nextId = 0;

  MachineProtocol({
    required this.enabled,
    CommandRunner? commandRunner,
    IOSink? output,
    Stream<String>? inputLines,
  })  : _commandRunner = commandRunner,
        _output = output ?? stdout,
        _inputLines = inputLines;

  /// Start listening for commands on stdin.
  ///
  /// Also emits `daemon.connected` to signal readiness.
  void startListening() {
    if (!enabled) return;

    // Emit daemon.connected on startup.
    sendEvent('daemon.connected', {
      'version': '0.1.0',
      'pid': pid,
    });

    final lines = _inputLines ??
        stdin.transform(utf8.decoder).transform(const LineSplitter());
    lines.listen(
      (line) async {
        try {
          final decoded = json.decode(line);
          // The Flutter machine protocol wraps commands in [...] arrays.
          final request = (decoded is List ? decoded.first : decoded)
              as Map<String, dynamic>;
          final method = request['method'] as String?;
          final id = request['id'];
          final params =
              (request['params'] as Map<String, dynamic>?) ?? {};

          final runner = _commandRunner;
          if (method != null &&
              runner != null &&
              runner.hasCommand(method)) {
            try {
              final result = await runner.run(method, params);
              _sendResponse(id, result);
            } catch (e) {
              // Report handler exceptions as JSON-RPC errors.
              _sendError(id, -32603, 'Internal error: $e');
            }
          } else {
            _sendError(id, -32601, 'Method not found: $method');
          }
        } catch (e) {
          // Report malformed input as parse error.
          _sendError(null, -32700, 'Parse error: $e');
        }
      },
    );
  }

  /// Send an event to the IDE.
  void sendEvent(String event, [Map<String, dynamic>? params]) {
    if (!enabled) return;
    _send({
      'event': event,
      if (params != null) 'params': params,
    });
  }

  /// Send app.start event.
  void appStart(String appId, String deviceName) {
    sendEvent('app.start', {
      'appId': appId,
      'deviceId': deviceName,
      'directory': Directory.current.path,
      'supportsRestart': true,
      'launchMode': 'run',
    });
  }

  /// Send app.debugPort event.
  void appDebugPort(String appId, Uri wsUri, Uri? baseUri) {
    sendEvent('app.debugPort', {
      'appId': appId,
      'wsUri': wsUri.toString(),
      if (baseUri != null) 'baseUri': baseUri.toString(),
    });
  }

  /// Send app.started event.
  void appStarted(String appId) {
    sendEvent('app.started', {'appId': appId});
  }

  /// Send app.log event.
  void appLog(String appId, String log, {bool error = false}) {
    sendEvent('app.log', {
      'appId': appId,
      'log': log,
      'error': error,
    });
  }

  /// Send app.progress event with paired start/finish IDs.
  ///
  /// Use [progressId] to pair start and finish events. If null, a new ID is
  /// generated (for backward compatibility).
  void appProgress(String appId, String message,
      {bool finished = false, String? progressId}) {
    final id = progressId ?? 'progress_${_nextId++}';
    sendEvent('app.progress', {
      'appId': appId,
      'id': id,
      'message': message,
      'finished': finished,
    });
  }

  /// Send app.stop event.
  void appStop(String appId) {
    sendEvent('app.stop', {'appId': appId});
  }

  void _sendResponse(dynamic id, Map<String, dynamic> result) {
    _send({'id': id, 'result': result});
  }

  void _sendError(dynamic id, int code, String message) {
    _send({
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  void _send(Map<String, dynamic> message) {
    _output.writeln('[${json.encode(message)}]');
  }
}
