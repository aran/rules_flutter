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

import 'dev_tool_exception.dart';

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
  Logger.root.level = levelStr != null ? parseLogLevel(levelStr) : Level.INFO;

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

/// A subprocess's own output, forwarded to the tool's stderr.
///
/// The tool's own diagnostics all go through [Logger] and so are parseable in
/// JSON mode. A subprocess's output is not: bazel's build output and the
/// frontend server's stderr would otherwise be written through verbatim, and in
/// JSON mode that passthrough is most of what a consumer sees.
///
/// Making it parseable must not make it unreadable, though, and bazel's output
/// is written for a person: it is what says which target is building and why a
/// build failed. So the same output takes the shape of whoever is reading.
/// Text mode passes each line through verbatim — with [textPrefix] when
/// the source needs naming — and JSON mode wraps each in a record carrying
/// [source] and [stream], next to the tool's own.
///
/// Lines, not chunks: a pipe hands over arbitrary fragments, so partial lines
/// are held until they finish. [close] releases a last line with no newline
/// after it, which is how a subprocess's final word arrives.
class SubprocessOutput {
  /// Which program this is — `bazel`, `frontend_server`.
  final String source;

  /// Which of its streams: `stdout` or `stderr`.
  final String stream;

  /// Prepended to each line in text mode. Empty leaves the output verbatim,
  /// which is what a reader wants from a program whose output they know.
  final String textPrefix;

  final Logger _logger = Logger('dev_tool.subprocess');
  String _partial = '';

  SubprocessOutput({
    required this.source,
    required this.stream,
    this.textPrefix = '',
  });

  /// Forward [chunk], emitting every complete line in it.
  void write(String chunk) {
    final combined = _partial + chunk;
    final lines = combined.split('\n');
    _partial = lines.removeLast();
    for (final line in lines) {
      emitLine(line);
    }
  }

  /// Forward a trailing line that never got its newline.
  void close() {
    if (_partial.isEmpty) return;
    final last = _partial;
    _partial = '';
    emitLine(last);
  }

  /// Where one finished line goes. The single point both modes pass through,
  /// and the seam a test overrides to read the lines instead of the process's
  /// own stderr.
  void emitLine(String line) {
    if (_isJsonMode) {
      _logger.info({
        'message': 'subprocess_output',
        'source': source,
        'stream': stream,
        'line': line,
      });
    } else {
      stderr.writeln('$textPrefix$line');
    }
  }
}

/// The [Level] `LOG_LEVEL` names, or a failure naming the ones that exist.
///
/// A misspelling is an error rather than a fall back to INFO: `LOG_LEVEL=DEBUG`
/// is not one of `package:logging`'s names, and silently asking for nothing
/// looks like a tool that ignores the variable.
Level parseLogLevel(String name) {
  for (final level in Level.LEVELS) {
    if (level.name == name) return level;
  }
  throw DevToolException(
    'LOG_LEVEL=$name is not a log level. Use one of: '
    '${Level.LEVELS.map((l) => l.name).join(', ')}.',
  );
}
