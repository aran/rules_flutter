/// Structured logging for the dev tool.
///
/// Configurable via environment variables:
/// - `LOG_FORMAT`: `text` (default) or `json`
/// - `LOG_LEVEL`: standard logging levels (ALL, FINEST, FINER, FINE, CONFIG,
///   INFO, WARNING, SEVERE, SHOUT, OFF)
///
/// In text mode, log records are written as human-readable lines to stderr.
/// In JSON mode, log records are written as structured JSON lines to stderr.
/// Stderr is used in both modes because stdout is owned by the machine protocol
/// in `--machine` mode.
///
/// ## Structured log messages
///
/// Pass a `Map<String, dynamic>` as the message to emit structured data:
///
///     logger.info({
///       'message': 'vm_service_connected',
///       'text': 'Connected to VM service at $uri.',
///       'uri': uri.toString(),
///       'device': device.name,
///     });
///
/// In JSON mode, the map fields are merged into the JSON envelope (the `text`
/// key is excluded from JSON output since it's only for human display).
/// In text mode, the `text` value is printed; falls back to `message`.
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

export 'package:logging/logging.dart' show Logger, Level;

bool _isJsonMode = false;

/// Whether JSON logging is active.
bool get isJsonLogging => _isJsonMode;

/// Initialize the logging system.
///
/// Call once at startup before any Logger usage. Reads `LOG_FORMAT` and
/// `LOG_LEVEL` from the process environment.
void initLogging() {
  final format = Platform.environment['LOG_FORMAT']?.toLowerCase() ?? 'text';
  _isJsonMode = format == 'json';

  final levelStr = Platform.environment['LOG_LEVEL']?.toUpperCase();
  Logger.root.level = levelStr != null ? _parseLevel(levelStr) : Level.INFO;

  Logger.root.onRecord.listen((record) {
    if (_isJsonMode) {
      final entry = <String, dynamic>{
        'ts': record.time.toIso8601String(),
        'level': record.level.name,
        'logger': record.loggerName,
      };
      if (record.object is Map) {
        // Structured message — merge fields, exclude 'text' (human-only).
        final data = Map<String, dynamic>.from(record.object as Map);
        data.remove('text');
        entry.addAll(data);
      } else {
        entry['message'] = record.message;
      }
      if (record.error != null) {
        entry['error'] = record.error.toString();
      }
      stderr.writeln(json.encode(entry));
    } else {
      String text;
      if (record.object is Map) {
        final data = record.object as Map;
        text = (data['text'] ?? data['message'] ?? record.message) as String;
      } else {
        text = record.message;
      }
      if (record.level < Level.INFO) {
        stderr.writeln('[verbose] $text');
      } else {
        stderr.writeln(text);
      }
    }
  });
}

Level _parseLevel(String name) {
  for (final level in Level.LEVELS) {
    if (level.name == name) return level;
  }
  return Level.INFO;
}
