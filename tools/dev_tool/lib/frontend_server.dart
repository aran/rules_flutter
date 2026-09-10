/// Persistent frontend_server wrapper for incremental compilation.
///
/// Starts a long-running frontend_server process that accepts
/// compile/recompile/accept/reject requests over stdin/stdout.
/// This enables fast incremental recompilation for hot reload.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pool/pool.dart';

import 'compiler_config.dart';
import 'logging.dart';
import 'temp_dir.dart';

final _logger = Logger('dev_tool.frontend_server');

/// Wraps a persistent frontend_server process for incremental compilation.
/// Signature for starting a process (allows test injection).
typedef ProcessFactory =
    Future<Process> Function(String executable, List<String> arguments);

class FrontendServer {
  final String _dartaotruntimePath;
  final String _frontendServerPath;
  final CompilerConfig _config;
  final String _packageConfig;
  final ProcessFactory _processFactory;

  Process? _process;

  /// True from the moment [shutdown] begins.
  ///
  /// What makes a compile requested during the teardown answer "there is no
  /// compiler any more" instead of throwing or hanging. The window it covers —
  /// `app.stop` arriving while the initial compile is still in flight — is the
  /// same one [shutdown] detaches `_process` for; this is the half that owes
  /// the caller an answer rather than silence.
  bool _closing = false;

  /// Set when a request was abandoned and the compiler terminated for it.
  bool _timedOut = false;

  /// How long any single request waits for the compiler to answer.
  ///
  /// `CommandRunner` documents this class as I/O "bounded at its own boundary"
  /// and rests its `Pool(1)` deadlock-freedom argument on that. Without this
  /// bound a request whose answer never comes waits forever holding the permit,
  /// and every later command queues behind it.
  ///
  /// It is deliberately NOT a deadline on acquiring the pool — that stays
  /// unbounded, because a queue that abandons work to escape its own contention
  /// is a worse failure than a slow one. This bounds the I/O instead.
  ///
  /// Generous on purpose: a cold incremental compile of a large app is seconds,
  /// not minutes, so this fires only when something is genuinely wrong.
  final Duration _responseTimeout;

  /// Serializes every request that speaks the stdin/stdout protocol.
  ///
  /// There are two independent callers. The reload path asks for compiles
  /// through `CommandRunner`'s own `Pool(1)`; the debugger asks for expression
  /// compiles through DWDS, on DWDS's schedule, and nothing outside this class
  /// coordinates the two. The protocol is a single stream of `result <key>` /
  /// `<key> …` exchanges with no request id in it, so two in flight at once
  /// hands one request the other's answer.
  ///
  /// Upstream reaches the same conclusion with a queue
  /// (`ResidentCompiler._controller`, drained one request at a time) covering
  /// recompile, expression compiles and reject alike. `accept` stays outside:
  /// it is a fire-and-forget write, and holding the permit across
  /// compile→accept would let a debugger evaluation block a reload's verdict.
  final _requests = Pool(1);

  int _boundaryKey = 0;
  Completer<CompileResult>? _pendingResult;

  /// What the in-flight request is, so its completion is interpreted as that
  /// kind of thing. See [_awaitingVerdict].
  _RequestKind? _pendingKind;

  final StringBuffer _diagnosticsBuffer = StringBuffer();

  /// Line buffer for partial stdout chunks.
  String _lineBuffer = '';

  FrontendServer({
    required String dartaotruntimePath,
    required String frontendServerPath,
    required CompilerConfig config,
    required String packageConfig,
    ProcessFactory? processFactory,
    Duration responseTimeout = const Duration(minutes: 2),
  }) : _responseTimeout = responseTimeout,
       _dartaotruntimePath = dartaotruntimePath,
       _frontendServerPath = frontendServerPath,
       _config = config,
       _packageConfig = packageConfig,
       _processFactory = processFactory ?? Process.start;

  late final String _outputDillPath;

  /// Where [_outputDillPath] lives, removed by [shutdown].
  ///
  /// The compiler writes `app.dill` here and rewrites it on every incremental
  /// recompile, so it belongs to the server and goes when the server does.
  Directory? _outputDir;

  /// Whether there is still a compiler process behind this to talk to.
  ///
  /// False once it has exited on its own, once it has been terminated for not
  /// answering, or once [shutdown] has let go of it. The distinction a caller
  /// needs it for is between a compile that FAILED — the source was wrong, ask
  /// again when it is not — and a compiler that is GONE, which no later
  /// request can recover.
  bool get isRunning => _process != null && !_closing && !_timedOut;

  /// Start the persistent frontend_server process.
  Future<void> start() async {
    final tempDir = _outputDir = await createTempDir('flutter_fs_');
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
    // Per line, not per chunk: a prefix written once per pipe fragment gives a
    // message split across two reads one prefix and a stray fragment on its own
    // line.
    final diagnostics = SubprocessOutput(
      source: 'frontend_server',
      stream: 'stderr',
      textPrefix: '[frontend_server] ',
    );
    _process!.stderr
        .transform(utf8.decoder)
        .listen(diagnostics.write, onDone: diagnostics.close);

    // Listen for unexpected process death to avoid hanging completers.
    _process!.exitCode.then((code) {
      _completeWithError(
        'Frontend server exited unexpectedly (exit code $code)',
      );
      _process = null;
    });
  }

  /// Complete the pending request with an error, if any.
  ///
  /// A reject counts. It is the one exchange the compiler answers, so a
  /// process that dies mid-reject leaves it waiting on an acknowledgement that
  /// cannot arrive — for the full response timeout, holding [_requests]'s only
  /// permit, with every queued reload stalled behind it. The compiler is
  /// already gone; there is nothing left to wait for.
  void _completeWithError(String message) {
    final completer = _pendingResult;
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        CompileResult(
          dillPath: '',
          success: false,
          diagnostics: message,
        ),
      );
    }
    _pendingResult = null;
    _pendingKind = null;

    final rejecting = _pendingReject;
    _pendingReject = null;
    _rejectBoundaryKey = null;
    if (rejecting != null && !rejecting.isCompleted) rejecting.complete();
  }

  /// Refuse to start a request while one is still in flight.
  ///
  /// Completing the superseded request with "cancelled" and carrying on would
  /// leave the compiler untold, so its answer still arrives — against the NEW
  /// request's completer, handing back a dill for a compile nobody asked for.
  ///
  /// Every production compile is serialized by `CommandRunner`'s `Pool(1)`,
  /// and each app owns its own server, so a second in-flight request is a bug
  /// in the caller rather than a state to recover from.
  void _requireIdle(String request) {
    if (_pendingResult != null) {
      throw StateError(
        'A compile is already in flight; cannot start a $request. Requests '
        'to one FrontendServer must be serialized.',
      );
    }
  }

  /// What a compile request answers once the server is on its way out.
  ///
  /// A result, not a throw and not a hang: the caller asked for a compile and
  /// is owed an answer, the answer is "there is no compiler any more", and
  /// leaving `_pendingResult` uncompleted would wedge it instead.
  static CompileResult get _shuttingDown => CompileResult(
    dillPath: '',
    success: false,
    diagnostics:
        'The frontend server is shutting down; nothing was '
        'compiled.',
  );

  /// What a request answers once the compiler has been terminated for going
  /// unanswered. Truthful about why, rather than "never started".
  static CompileResult get _timedOutResult => CompileResult(
    dillPath: '',
    success: false,
    diagnostics:
        'The compiler stopped answering and was terminated. '
        'Restart the run to get hot reload back.',
  );

  /// Compile the given entrypoint for the first time.
  Future<CompileResult> compile(String entrypoint) =>
      _requests.withResource(() async {
        // Shutting-down is checked first: it also nulls `_process`, and "there
        // is no compiler any more" is the true answer there, not "never
        // started".
        if (_closing) return _shuttingDown;
        if (_timedOut) return _timedOutResult;
        if (_process == null) throw StateError('Frontend server not started');

        _beginRequest('compile', _RequestKind.compile);

        _writeln('compile $entrypoint');

        return _awaitResponse('compile');
      });

  /// Compile [expression] to JavaScript against the running program, for the
  /// debugger's expression evaluation.
  ///
  /// The arguments are DWDS's, passed through: the library and script the
  /// expression is written against, where in them it sits, the JS modules and
  /// frame values in scope, and the module it will be evaluated in.
  ///
  /// A different verb from [compile] on the same connection — `JSON_INPUT`
  /// followed by one line of JSON, which is how the frontend server takes a
  /// request with structure. The answer comes back through the same
  /// `result <key>` handshake, so it shares [_handleOutput]; what it does not
  /// share is the accept/reject verdict, because no expression compile changes
  /// the program the compiler is holding.
  Future<CompileResult> compileExpressionToJs({
    required String libraryUri,
    required String scriptUri,
    required int line,
    required int column,
    required Map<String, String> jsModules,
    required Map<String, String> jsFrameValues,
    required String moduleName,
    required String expression,
  }) => _requests.withResource(() async {
    if (_closing) return _shuttingDown;
    if (_timedOut) return _timedOutResult;
    if (_process == null) throw StateError('Frontend server not started');

    _beginRequest('expression compile', _RequestKind.expression);

    _writeln('JSON_INPUT');
    _writeln(
      json.encode({
        'type': 'COMPILE_EXPRESSION_JS',
        'data': {
          'expression': expression,
          'libraryUri': libraryUri,
          'scriptUri': scriptUri,
          'line': line,
          'column': column,
          'jsModules': jsModules,
          'jsFrameValues': jsFrameValues,
          'moduleName': moduleName,
        },
      }),
    );

    return _awaitResponse('expression compile');
  });

  /// Arm the protocol state for a request of [kind].
  ///
  /// [_resultBoundaryKey] is cleared as well as the line buffer. A previous
  /// exchange that timed out can still deliver its `result <key>` line
  /// afterwards, and a key left over from it makes this request's own `result`
  /// line look like the stray echo the parser skips — after which nothing
  /// matches and the request waits out its whole timeout for a completion that
  /// already went past.
  void _beginRequest(String what, _RequestKind kind) {
    _requireIdle(what);
    _pendingResult = Completer<CompileResult>();
    _pendingKind = kind;
    _lineBuffer = '';
    _resultBoundaryKey = null;
  }

  /// Incrementally recompile after source changes.
  ///
  /// [invalidated] is the list of file URIs that changed.
  /// Returns the path to the incremental delta .dill.
  ///
  /// [resetFirst] throws the incremental state away before recompiling, so
  /// what comes back is the whole program rather than a delta — the shape a
  /// hot restart needs. It is written inside this request's own turn on
  /// [_requests] rather than from a method of its own, because `reset` gets no
  /// answer: sent outside the queue it could land between another request's
  /// lines, and the compiler would apply it to a compile nobody asked to
  /// discard.
  ///
  /// The alternative — a second `compile` — is wrong for a reason that is not
  /// visible from the protocol: **the `compile` verb's error count is
  /// cumulative.** A `compile` that reported one error, followed by a fix on
  /// disk and a second `compile`, reports one error again — with no
  /// diagnostics, and with the corrected code in the dill it just wrote. Reject
  /// the first and the second `compile` reports *two*. Only a `recompile`
  /// clears that list, which is why upstream sends exactly one `compile` per
  /// server and drives every restart through `reset` + `recompile`
  /// (`flutter_tools`' `devfs.dart`).
  Future<CompileResult> recompile(
    String entrypoint,
    List<String> invalidated, {
    bool resetFirst = false,
  }) => _requests.withResource(() async {
    // Shutting-down is checked first: it also nulls `_process`, and "there
    // is no compiler any more" is the true answer there, not "never
    // started".
    if (_closing) return _shuttingDown;
    if (_timedOut) return _timedOutResult;
    if (_process == null) throw StateError('Frontend server not started');

    _beginRequest('recompile', _RequestKind.compile);
    _boundaryKey++;
    final key = 'boundary_$_boundaryKey';

    final buffer = StringBuffer();
    if (resetFirst) buffer.writeln('reset');
    buffer.write('recompile $entrypoint $key\n');
    for (final uri in invalidated) {
      buffer.writeln(uri);
    }
    buffer.writeln(key);
    _write(buffer.toString());

    return _awaitResponse('recompile');
  });

  /// Wait for the in-flight request's result, bounded.
  ///
  /// A compiler that stops answering would otherwise hold the command pool
  /// forever; answering with a failure keeps the session usable and says why.
  Future<CompileResult> _awaitResponse(String what) {
    final pending = _pendingResult!;
    return pending.future.timeout(
      _responseTimeout,
      onTimeout: () {
        if (identical(_pendingResult, pending)) _pendingResult = null;
        _pendingKind = null;
        _resultBoundaryKey = null;
        _awaitingVerdict = false;
        // The pipe's future content is now unknowable: this request's answer may
        // still arrive and would land on whatever completer exists then. The
        // only guard that holds is making the emitter stop existing — the same
        // conclusion `shutdown` reached about writing to a doomed pipe.
        _timedOut = true;
        _process?.kill();
        _logger.severe({
          'message': 'frontend_server_timeout',
          'text':
              'The compiler did not answer a $what within '
              '${_responseTimeout.inMinutes} minutes.',
        });
        return CompileResult(
          dillPath: '',
          success: false,
          diagnostics:
              'The compiler did not answer a $what within '
              '${_responseTimeout.inMinutes} minutes.',
        );
      },
    );
  }

  /// Accept the last compilation result.
  ///
  /// Silent on the wire — the protocol answers nothing — and skipped entirely
  /// when no compile is awaiting a verdict, because an unowed verdict is a
  /// message the server has no state to interpret.
  void accept() {
    if (!_awaitingVerdict) return;
    _awaitingVerdict = false;
    _writeln('accept');
  }

  /// Reject the last compilation result, and wait for the server to say it did.
  ///
  /// Unlike `accept`, `reject` ANSWERS: `result <key>` followed by the key on
  /// its own line. Reading it is not optional. Left in the pipe, those two
  /// lines are still there when the next `recompile` begins — the first is
  /// taken for that compile's boundary key and the second leaves it set
  /// forever, after which no result line ever matches again and every later
  /// compile waits for a completion that cannot arrive.
  ///
  /// `package:frontend_server_client` states the same contract: "The result of
  /// this call must be awaited before a new compile can be done."
  Future<void> reject() => _requests.withResource(_reject);

  Future<void> _reject() async {
    if (!_awaitingVerdict) return;
    _awaitingVerdict = false;
    if (_closing || _process == null) return;

    final done = _pendingReject = Completer<void>();
    _writeln('reject');
    await done.future.timeout(
      _responseTimeout,
      onTimeout: () {
        _pendingReject = null;
        // The stream is now of unknown shape, so the key cannot be trusted
        // either. Clearing it is what keeps one lost response from becoming a
        // permanently unusable compiler.
        _resultBoundaryKey = null;
        _logger.severe({
          'message': 'frontend_server_reject_timeout',
          'text':
              'The compiler did not acknowledge a rejected compile within '
              '${_responseTimeout.inSeconds}s. The next reload will recompile '
              'from the last accepted state.',
        });
      },
    );
  }

  /// Shut down the frontend_server process.
  Future<void> shutdown() async {
    _closing = true;
    // Detached before the `quit` and before anything is awaited, so no
    // concurrent [accept] can find a sink to write to. Catching that write is
    // not enough: a `Socket`'s failure surfaces from inside the sink's own
    // delivery, where it is reported to the zone rather than thrown back to the
    // caller, so [_write]'s guards never see it and the run dies with exit 255.
    // The only guard that holds is not writing.
    final process = _process;
    _process = null;
    _quit(process);
    await process?.exitCode;
    // After the exit, never before: the compiler holds `app.dill` open.
    final outputDir = _outputDir;
    _outputDir = null;
    if (outputDir != null) await deleteTempDir(outputDir);
  }

  /// Ask [process] to exit. The one write that is allowed to reach a pipe the
  /// rest of the class has already let go of.
  void _quit(Process? process) {
    try {
      process?.stdin.writeln('quit');
    } on StateError {
      // Already closed; the exit we are about to await is the real answer.
    } on IOException {
      // Same.
    }
  }

  /// Write a line to the process stdin, guarding against a dead process.
  void _writeln(String line) => _write('$line\n');

  /// Write to the compiler's stdin, tolerating a pipe that is already gone.
  ///
  /// Two ways it can be gone, and they are not the same event. During
  /// [shutdown] it is expected and silent. Otherwise the compiler died on its
  /// own, and that is worth saying: every later reload will fail, and without
  /// this the first symptom is an unhandled IOException that kills the run.
  void _write(String text) {
    try {
      _process?.stdin.write(text);
    } on StateError catch (e) {
      _reportWriteFailed(e);
    } on IOException catch (e) {
      _reportWriteFailed(e);
    }
  }

  void _reportWriteFailed(Object error) {
    if (_closing) return;
    _logger.severe({
      'message': 'frontend_server_gone',
      'text':
          'The compiler process is no longer accepting input ($error). '
          'Hot reload and hot restart cannot work for the rest of this run; '
          'restart it to get them back.',
      'error': '$error',
    });
  }

  /// Boundary key from the last `result` line (stdout protocol state).
  String? _resultBoundaryKey;

  /// Whether the server is holding a compile that has not been accepted or
  /// rejected. Only then does a verdict mean anything.
  bool _awaitingVerdict = false;

  /// Completes when a rejected compile has been acknowledged.
  Completer<void>? _pendingReject;

  /// Key from the `result <key>` line of a reject acknowledgement, kept apart
  /// from [_resultBoundaryKey] so the two protocol exchanges cannot be
  /// confused for one another.
  String? _rejectBoundaryKey;

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

      // A reject acknowledgement is consumed first and on its own keys, so it
      // can never be mistaken for a compile result.
      if (_pendingReject != null) {
        if (_rejectBoundaryKey == null) {
          if (line.startsWith('result ')) {
            _rejectBoundaryKey = line.substring('result '.length);
          }
          continue;
        }
        if (line.trim() == _rejectBoundaryKey) {
          _rejectBoundaryKey = null;
          final done = _pendingReject;
          _pendingReject = null;
          if (done != null && !done.isCompleted) done.complete();
        }
        continue;
      }

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
          final outputPath = spaceIdx > 0 ? rest.substring(0, spaceIdx) : rest;
          final errorCount = spaceIdx > 0
              ? int.tryParse(rest.substring(spaceIdx + 1)) ?? 0
              : 0;

          _pendingResult?.complete(
            CompileResult(
              dillPath: errorCount > 0 ? '' : outputPath,
              outputPath: outputPath,
              success: errorCount == 0,
              diagnostics: _diagnosticsBuffer.toString(),
              errorCount: errorCount,
            ),
          );
        }
        _pendingResult = null;
        // Only a compile leaves the compiler holding something to accept or
        // reject. An expression compile does not change the program, and
        // arming the verdict for one would make the next `accept()` send an
        // unowed verdict the server has no state to interpret — and, worse,
        // would let an expression compile that landed between a compile and
        // its verdict swallow that verdict.
        if (_pendingKind == _RequestKind.compile) _awaitingVerdict = true;
        _pendingKind = null;
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

/// Which protocol exchange is in flight. The two differ in one way that
/// matters: only a compile leaves a result to accept or reject.
enum _RequestKind { compile, expression }

/// Result of a compilation request.
class CompileResult {
  /// The compiler's output artifact, or empty when the compile failed.
  ///
  /// Blank on failure because every reload caller treats a path here as
  /// something it can hand to a device.
  final String dillPath;

  /// The compiler's output artifact whether or not it failed.
  ///
  /// An expression compile writes its answer to this file either way: on
  /// success the compiled JavaScript, on failure the error the debugger shows
  /// in place of a value. [dillPath] cannot carry that, and losing it would
  /// turn a reportable error into a blank result.
  final String outputPath;

  final bool success;
  final String diagnostics;

  /// How many errors the frontend server reported.
  ///
  /// The protocol states this on the result line. "Compilation failed" and
  /// "compilation failed with 37 errors" are different things to report, and
  /// the second is what the frontend server actually said.
  final int errorCount;

  CompileResult({
    required this.dillPath,
    required this.success,
    String? outputPath,
    this.diagnostics = '',
    this.errorCount = 0,
  }) : outputPath = outputPath ?? dillPath;
}
