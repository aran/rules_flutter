/// Persistent frontend_server wrapper for incremental compilation.
///
/// Starts a long-running frontend_server process that accepts
/// compile/recompile/accept/reject requests over stdin/stdout.
/// This enables fast incremental recompilation for hot reload.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'compiler_config.dart';

/// Wraps a persistent frontend_server process for incremental compilation.
/// Signature for starting a process (allows test injection).
typedef ProcessFactory = Future<Process> Function(
    String executable, List<String> arguments);

class FrontendServer {
  final String _dartaotruntimePath;
  final String _frontendServerPath;
  final CompilerConfig _config;
  final String _packageConfig;
  final ProcessFactory _processFactory;

  Process? _process;
  int _boundaryKey = 0;
  Completer<CompileResult>? _pendingResult;
  final StringBuffer _diagnosticsBuffer = StringBuffer();
  /// Line buffer for partial stdout chunks.
  String _lineBuffer = '';

  FrontendServer({
    required String dartaotruntimePath,
    required String frontendServerPath,
    required CompilerConfig config,
    required String packageConfig,
    ProcessFactory? processFactory,
  })  : _dartaotruntimePath = dartaotruntimePath,
        _frontendServerPath = frontendServerPath,
        _config = config,
        _packageConfig = packageConfig,
        _processFactory = processFactory ?? Process.start;

  late final String _outputDillPath;

  /// Start the persistent frontend_server process.
  Future<void> start() async {
    final tempDir = await Directory.systemTemp.createTemp('flutter_fs_');
    _outputDillPath = '${tempDir.path}/app.dill';

    _process = await _processFactory(_dartaotruntimePath, [
      _frontendServerPath,
      '--sdk-root=${_config.sdkRoot}/',
      '--incremental',
      '--target=${_config.targetFlag}',
      '--packages=$_packageConfig',
      '--output-dill=$_outputDillPath',
      ..._config.extraFlags,
    ]);

    _process!.stdout.transform(utf8.decoder).listen(_handleOutput);
    _process!.stderr.transform(utf8.decoder).listen(
      (data) => stderr.write('[frontend_server] $data'),
    );

    // Listen for unexpected process death to avoid hanging completers.
    _process!.exitCode.then((code) {
      _completeWithError(
        'Frontend server exited unexpectedly (exit code $code)',
      );
      _process = null;
    });
  }

  /// Complete the pending result with an error, if any.
  void _completeWithError(String message) {
    final completer = _pendingResult;
    if (completer != null && !completer.isCompleted) {
      completer.complete(CompileResult(
        dillPath: '',
        success: false,
        diagnostics: message,
      ));
    }
    _pendingResult = null;
  }

  /// Cancel a pending compile if one is in-flight before starting a new one.
  void _cancelPending() {
    final completer = _pendingResult;
    if (completer != null && !completer.isCompleted) {
      completer.complete(CompileResult(
        dillPath: '',
        success: false,
        diagnostics: 'Cancelled by new compile request',
      ));
    }
    _pendingResult = null;
  }

  /// Compile the given entrypoint for the first time.
  Future<CompileResult> compile(String entrypoint) async {
    if (_process == null) throw StateError('Frontend server not started');

    _cancelPending();
    _pendingResult = Completer<CompileResult>();
    _lineBuffer = '';

    _writeln('compile $entrypoint');

    return _pendingResult!.future;
  }

  /// Incrementally recompile after source changes.
  ///
  /// [invalidated] is the list of file URIs that changed.
  /// Returns the path to the incremental delta .dill.
  Future<CompileResult> recompile(
    String entrypoint,
    List<String> invalidated,
  ) async {
    if (_process == null) throw StateError('Frontend server not started');

    _cancelPending();
    _pendingResult = Completer<CompileResult>();
    _lineBuffer = '';
    _boundaryKey++;
    final key = 'boundary_$_boundaryKey';

    final buffer = StringBuffer('recompile $entrypoint $key\n');
    for (final uri in invalidated) {
      buffer.writeln(uri);
    }
    buffer.writeln(key);
    try {
      _process?.stdin.write(buffer.toString());
    } on StateError {
      // Process already exited; stdin is closed.
    }

    return _pendingResult!.future;
  }

  /// Accept the last compilation result.
  void accept() {
    _writeln('accept');
  }

  /// Reject the last compilation result.
  void reject() {
    _writeln('reject');
  }

  /// Shut down the frontend_server process.
  Future<void> shutdown() async {
    _writeln('quit');
    await _process?.exitCode;
    _process = null;
  }

  /// Write a line to the process stdin, guarding against a dead process.
  void _writeln(String line) {
    try {
      _process?.stdin.writeln(line);
    } on StateError {
      // Process already exited; stdin is closed.
    }
  }

  /// Boundary key from the last `result` line (stdout protocol state).
  String? _resultBoundaryKey;

  /// Handles frontend_server stdout protocol.
  ///
  /// Protocol:
  ///   1. `result <boundary_key>` — marks start of output
  ///   2. `+file:///...` — source dependencies (optional)
  ///   3. `<boundary_key> <output_dill_path> <error_count>` — completion
  void _handleOutput(String data) {
    _lineBuffer += data;

    while (true) {
      final newlineIndex = _lineBuffer.indexOf('\n');
      if (newlineIndex < 0) break;
      final line = _lineBuffer.substring(0, newlineIndex);
      _lineBuffer = _lineBuffer.substring(newlineIndex + 1);

      // `result <boundary_key>` — store the key.
      if (_resultBoundaryKey == null && line.startsWith('result ')) {
        _resultBoundaryKey = line.substring('result '.length);
        continue;
      }

      // `<boundary_key> <output_path> <error_count>` — completion.
      // The key also appears alone on a line before the `+file:///` dependency
      // list — skip that echo and wait for the line with the dill path.
      if (_resultBoundaryKey != null && line.startsWith(_resultBoundaryKey!)) {
        final rest = line.substring(_resultBoundaryKey!.length).trim();

        if (rest.isEmpty) {
          // Key echo line — not yet complete, keep waiting.
          continue;
        }

        _resultBoundaryKey = null;
        {
          final spaceIdx = rest.lastIndexOf(' ');
          final dillPath = spaceIdx > 0 ? rest.substring(0, spaceIdx) : rest;
          final errorCount = spaceIdx > 0
              ? int.tryParse(rest.substring(spaceIdx + 1)) ?? 0
              : 0;

          _pendingResult?.complete(CompileResult(
            dillPath: errorCount > 0 ? '' : dillPath,
            success: errorCount == 0,
            diagnostics: _diagnosticsBuffer.toString(),
          ));
        }
        _pendingResult = null;
        _diagnosticsBuffer.clear();
        continue;
      }

      // Collect non-protocol lines as diagnostics (skip dependency lines).
      if (line.isNotEmpty && !line.startsWith('+')) {
        _diagnosticsBuffer.writeln(line);
      }
    }
  }
}

/// Result of a compilation request.
class CompileResult {
  final String dillPath;
  final bool success;
  final String diagnostics;

  CompileResult({
    required this.dillPath,
    required this.success,
    this.diagnostics = '',
  });
}
