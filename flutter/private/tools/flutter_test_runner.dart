/// Bazel-side driver for `flutter_test` rule.
///
/// Spawns `flutter_tester` with the kernel `.dill` produced by the rule, hosts
/// a localhost WebSocket harness, and drives the per-test
/// `package:test_api/backend.dart` `RemoteListener` protocol. Reports per-test
/// pass/fail to stdout and exits non-zero on the first failure (or on
/// flutter_tester crash).
///
/// Wire protocol (mirrors `package:test`'s `flutter_platform.dart`):
///   - WebSocket transport carries JSON-encoded `[id, data]` lists, plus
///     `[id]` for channel-close. id 0 is the default channel.
///   - We send `{type: 'initial', metadata, platform, ...}` on id 0.
///   - Bootstrap responds `{type: 'success', root: <groupTree>}` on id 0;
///     each test in the tree carries a `channel` id (bootstrap-created).
///   - To run a test, we allocate our own outputId and send
///     `{command: 'run', channel: outputId}` on `testChannel + 1`. Bootstrap
///     replies with `state-change`/`error`/`message`/`complete` events on
///     `outputId + 1`, which we deliver back to our test handler.
///   - When the suite is exhausted we send `{type: 'close'}` on id 0.
///
/// Coverage: when `bazel coverage` sets `COVERAGE_OUTPUT_FILE`, the spawn
/// switches to `--vm-service-port=0 --start-paused`. The runner pulls the
/// Observatory URI from flutter_tester's stdout, connects via the VM service
/// JSON-RPC, resumes isolates, then collects source reports and writes LCOV.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) async {
  final r = Runfiles.create();

  final testerKey = Platform.environment['FLUTTER_TEST_TESTER'];
  final icuKey = Platform.environment['FLUTTER_TEST_ICU'];
  final dillKey = Platform.environment['FLUTTER_TEST_DILL'];
  final assetsKey = Platform.environment['FLUTTER_TEST_ASSETS'];
  if (testerKey == null || icuKey == null || dillKey == null) {
    stderr.writeln(
      'flutter_test runner: FLUTTER_TEST_TESTER, FLUTTER_TEST_ICU, and '
      'FLUTTER_TEST_DILL must be set.',
    );
    exit(64);
  }

  final tester = r.rlocation(testerKey);
  final icu = r.rlocation(icuKey);
  final dill = r.rlocation(dillKey);
  final assetsDir = assetsKey == null ? null : r.rlocation(assetsKey);
  final testPath = Platform.environment['FLUTTER_TEST_PATH'] ?? 'test.dart';
  final coverageOutput = Platform.environment['COVERAGE_OUTPUT_FILE'];

  exitCode = await _runOnce(
    tester: tester,
    icu: icu,
    dill: dill,
    assetsDir: assetsDir,
    testPath: testPath,
    coverageOutput: coverageOutput,
  );
}

Future<int> _runOnce({
  required String tester,
  required String icu,
  required String dill,
  required String? assetsDir,
  required String testPath,
  required String? coverageOutput,
}) async {
  final harness = await _Harness.bind();
  try {
    return await harness.run(
      tester: tester,
      icu: icu,
      dill: dill,
      assetsDir: assetsDir,
      testPath: testPath,
      coverageOutput: coverageOutput,
    );
  } finally {
    await harness.dispose();
  }
}

/// Harness state: server, tester process, WebSocket, channel demux.
class _Harness {
  _Harness._(this._server);

  final HttpServer _server;
  Process? _process;
  WebSocket? _ws;
  bool _socketClosed = false;

  /// Per-channel inbound dispatchers, keyed by inputId.
  final Map<int, void Function(Object?)> _inbound = {};

  /// Pending test completers indexed by their reply-channel inputId. When the
  /// socket closes mid-suite, we surface that as a failure on every
  /// outstanding test so we can't hang waiting on a `complete` event that
  /// will never arrive.
  final Map<int, Completer<void>> _pendingTests = {};

  /// MultiChannel-compatible counter for our locally-allocated channels.
  /// `package:stream_channel`'s MultiChannel allocates outputId = nextId,
  /// inputId = nextId+1, then increments by 2.
  int _nextId = 1;

  /// Allocates a virtual channel pair for our side. Returns (outputId, inputId).
  ({int outputId, int inputId}) _allocChannel() {
    final out = _nextId;
    final inp = _nextId + 1;
    _nextId += 2;
    return (outputId: out, inputId: inp);
  }

  void _send(int outputId, Object? data) {
    if (_socketClosed) return;
    _ws!.add(json.encode([outputId, data]));
  }

  static Future<_Harness> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _Harness._(server);
  }

  Future<void> dispose() async {
    try {
      await _ws?.close();
    } catch (_) {}
    try {
      _process?.kill(ProcessSignal.sigkill);
    } catch (_) {}
    try {
      await _server.close(force: true);
    } catch (_) {}
  }

  Future<int> run({
    required String tester,
    required String icu,
    required String dill,
    required String? assetsDir,
    required String testPath,
    required String? coverageOutput,
  }) async {
    final enableVmService = coverageOutput != null;
    final command = <String>[
      tester,
      if (enableVmService) ...[
        '--vm-service-port=0',
        '--start-paused',
      ] else
        '--disable-vm-service',
      '--icu-data-file-path=$icu',
      '--enable-checked-mode',
      '--verify-entry-points',
      '--enable-software-rendering',
      '--skia-deterministic-rendering',
      '--enable-dart-profiling',
      '--non-interactive',
      '--use-test-fonts',
      '--disable-asset-fonts',
      if (assetsDir != null) '--flutter-assets-dir=$assetsDir',
      dill,
    ];

    _process = await Process.start(
      command.first,
      command.sublist(1),
      environment: {
        'FLUTTER_TEST': 'true',
        'FLUTTER_TEST_HARNESS_PORT': '${_server.port}',
      },
    );

    // Capture flutter_tester output so engine errors are visible. In coverage
    // mode we also need to scan stdout for the VM service URI.
    final vmServiceUriCompleter = Completer<Uri>();
    final vmServicePattern = RegExp(
      r'(?:Observatory|The Dart VM service is) (?:listening on|listening on) (http\S+)',
    );

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderr.writeln('[flutter_tester] $line');
      if (enableVmService && !vmServiceUriCompleter.isCompleted) {
        final m = vmServicePattern.firstMatch(line);
        if (m != null) {
          vmServiceUriCompleter.complete(Uri.parse(m.group(1)!));
        }
      }
    });
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      stderr.writeln('[flutter_tester] $line');
    });

    // Wait for the bootstrap to dial back. If flutter_tester crashes before
    // connecting, surface that as the failure rather than blocking forever.
    final firstReq = await _firstRequestOrTesterExit();
    if (firstReq == null) {
      final ec = await _process!.exitCode;
      stderr.writeln(
        'flutter_test: flutter_tester exited with code $ec before connecting '
        'to the harness.',
      );
      return ec == 0 ? 1 : ec;
    }

    _ws = await WebSocketTransformer.upgrade(firstReq);

    // Default channel handler — receives the suite tree plus print/error
    // events. We resolve `suiteReady` once the bootstrap finishes registering
    // tests (or surfaces a load failure).
    final suiteReady = Completer<Map<String, dynamic>?>();
    _inbound[0] = (data) {
      final msg = (data as Map).cast<String, dynamic>();
      switch (msg['type']) {
        case 'success':
          if (!suiteReady.isCompleted) {
            suiteReady.complete((msg['root'] as Map).cast<String, dynamic>());
          }
        case 'loadException':
          stderr.writeln('flutter_test: load failure — ${msg['message']}');
          if (!suiteReady.isCompleted) suiteReady.complete(null);
        case 'error':
          final err = (msg['error'] as Map).cast<String, dynamic>();
          stderr.writeln(
            'flutter_test: top-level error — ${err['message']}\n'
            '${err['stackChain']}',
          );
          if (!suiteReady.isCompleted) suiteReady.complete(null);
        case 'print':
          stdout.writeln(msg['line']);
      }
    };

    _ws!.listen(_onSocketMessage, onDone: () {
      _socketClosed = true;
      if (!suiteReady.isCompleted) suiteReady.complete(null);
      for (final c in _pendingTests.values) {
        if (!c.isCompleted) c.complete();
      }
      _pendingTests.clear();
    });

    // Send the initial suite handshake.
    _send(0, _initialMessage(testPath));

    // If we're collecting coverage, wait for the VM service to come up and
    // resume the paused isolate so the suite handshake can complete.
    String? vmServiceCoverageError;
    Uri? coverageVmServiceUri;
    if (enableVmService) {
      try {
        coverageVmServiceUri = await vmServiceUriCompleter.future
            .timeout(const Duration(seconds: 30));
        await _resumeIsolatesViaVmService(coverageVmServiceUri);
      } catch (e) {
        vmServiceCoverageError = 'failed to bring up VM service: $e';
      }
    }

    final root = await suiteReady.future
        .timeout(const Duration(minutes: 5), onTimeout: () => null);

    final results = _Results();
    if (root != null) {
      await _runGroup(root, results, const <String>[]);
    } else {
      results.recordError('suite did not load');
    }

    // Collect coverage before tearing the tester down — the isolate must still
    // be alive when we fetch source reports.
    if (enableVmService && coverageVmServiceUri != null) {
      try {
        final lcov = await _collectCoverage(coverageVmServiceUri);
        await File(coverageOutput!).writeAsString(lcov);
      } catch (e) {
        vmServiceCoverageError ??= 'failed to collect coverage: $e';
      }
    }
    if (vmServiceCoverageError != null) {
      stderr.writeln('flutter_test (coverage): $vmServiceCoverageError');
    }

    // Politely shut down: tell RemoteListener to close, then close the
    // WebSocket. The bootstrap's `socket.map(...).pipe(sink)` and
    // `socket.addStream(...)` both terminate on socket close, draining the
    // isolate so flutter_tester exits on its own. Without the explicit
    // close, the bootstrap's main isolate keeps the engine alive and
    // we'd block on the tester-exit timeout for every test run.
    _send(0, {'type': 'close'});
    try {
      await _ws?.close();
    } catch (_) {}

    // `-1` can't double as a "we killed it" sentinel here: on POSIX a
    // signal-killed process reports `-signum`, and SIGHUP is signal 1, so
    // `-1` is a real exit value. Track the timeout kill explicitly instead.
    var killedAfterTimeout = false;
    final testerExit = await _process!.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        killedAfterTimeout = true;
        _process!.kill(ProcessSignal.sigkill);
        return 0;
      },
    );
    if (killedAfterTimeout) {
      stderr.writeln(
        'flutter_test: flutter_tester did not exit within 30s after the '
        'suite finished; killed it.',
      );
    }

    stdout.writeln(results.summary());

    if (results.hasFailure) return 1;
    // A requested coverage run that produced no data is a failure — Bazel
    // would otherwise record a green test with an empty/absent LCOV file.
    if (vmServiceCoverageError != null) return 1;
    if (!killedAfterTimeout && testerExit != 0) {
      stderr.writeln('flutter_test: flutter_tester exited with $testerExit');
      return testerExit;
    }
    return 0;
  }

  Future<HttpRequest?> _firstRequestOrTesterExit() async {
    final reqOrExit = await Future.any([
      _server.first.then<HttpRequest?>((r) => r),
      _process!.exitCode.then<HttpRequest?>((_) => null),
    ]).timeout(const Duration(minutes: 2), onTimeout: () => null);
    return reqOrExit;
  }

  void _onSocketMessage(dynamic raw) {
    final list = json.decode(raw as String) as List;
    final id = (list[0] as num).toInt();
    if (list.length == 1) {
      // Channel closed by remote — drop the handler so we stop dispatching.
      _inbound.remove(id);
      return;
    }
    final handler = _inbound[id];
    if (handler != null) {
      handler(list[1]);
    }
  }

  Future<void> _runGroup(
    Map<String, dynamic> group,
    _Results results,
    List<String> nameStack,
  ) async {
    final groupName = group['name'] as String? ?? '';
    final stack = [
      ...nameStack,
      if (groupName.isNotEmpty) groupName,
    ];

    final setUpAll = group['setUpAll'] as Map?;
    if (setUpAll != null) {
      await _runTest(
        setUpAll.cast<String, dynamic>(),
        results,
        stack,
        fixture: 'setUpAll',
      );
    }

    final entries = group['entries'] as List? ?? const [];
    for (final entry in entries) {
      final m = (entry as Map).cast<String, dynamic>();
      if (m['type'] == 'group') {
        await _runGroup(m, results, stack);
      } else {
        await _runTest(m, results, stack);
      }
    }

    final tearDownAll = group['tearDownAll'] as Map?;
    if (tearDownAll != null) {
      await _runTest(
        tearDownAll.cast<String, dynamic>(),
        results,
        stack,
        fixture: 'tearDownAll',
      );
    }
  }

  Future<void> _runTest(
    Map<String, dynamic> test,
    _Results results,
    List<String> nameStack, {
    String? fixture,
  }) async {
    final testChannelId = (test['channel'] as num).toInt();
    final testName = test['name'] as String? ?? '';
    final fullName = [
      ...nameStack,
      if (testName.isNotEmpty) testName,
    ].join(' ');
    final reportName = fixture != null
        ? (fullName.isEmpty ? '[$fixture]' : '[$fixture] $fullName')
        : fullName;

    final metadata = test['metadata'] as Map?;
    final skipReason = metadata == null ? null : metadata['skipReason'];
    final skipFlag = metadata == null ? false : (metadata['skip'] as bool? ?? false);
    if (fixture == null && skipFlag) {
      results.recordSkipped(reportName, skipReason as String?);
      return;
    }

    if (_socketClosed) {
      results.recordFailure(
        reportName,
        _TestFailureSummary(
          message: 'flutter_tester disconnected before this test ran',
          type: 'TestDeviceException',
          stackChain: '',
        ),
      );
      return;
    }

    final ch = _allocChannel();
    final completer = Completer<void>();
    _pendingTests[ch.inputId] = completer;
    _TestFailureSummary? failure;

    _inbound[ch.inputId] = (data) {
      final msg = (data as Map).cast<String, dynamic>();
      switch (msg['type']) {
        case 'state-change':
          // We rely on the explicit error events for failure tracking; state
          // changes alone don't tell us the difference between "still
          // running" and "failed and continuing".
          break;
        case 'error':
          final err = (msg['error'] as Map).cast<String, dynamic>();
          failure ??= _TestFailureSummary(
            message:
                err['message'] as String? ?? err['toString'] as String? ?? '',
            type: err['type'] as String? ?? 'TestFailure',
            stackChain: err['stackChain'] as String? ?? '',
          );
        case 'message':
          final mtype = msg['message-type'] as String? ?? 'print';
          final text = msg['text'] as String? ?? '';
          if (mtype == 'print') {
            stdout.writeln(text);
          } else {
            stdout.writeln('[$mtype] $text');
          }
        case 'complete':
          if (!completer.isCompleted) completer.complete();
      }
    };

    // Send "run" to the test channel. testChannelId is bootstrap's outputId
    // for the test's virtual channel; per MultiChannel framing we send back
    // on testChannelId+1.
    _send(testChannelId + 1, {'command': 'run', 'channel': ch.outputId});

    // `test_api` enforces the per-test timeout from the metadata we sent
    // (30s), but that's a Timer — a test that spins synchronously without
    // yielding to the event loop never lets it fire. Backstop with a flat
    // ceiling so a wedged test surfaces as a failure here instead of
    // hanging until Bazel's outer test timeout. Kill the tester and treat
    // the socket as gone so the remaining tests bail out fast.
    await completer.future.timeout(const Duration(minutes: 5), onTimeout: () {
      stderr.writeln(
        'flutter_test: test "$reportName" did not finish within 5 minutes; '
        'killing flutter_tester.',
      );
      _socketClosed = true;
      try {
        _process?.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });
    _pendingTests.remove(ch.inputId);
    _inbound.remove(ch.inputId);

    if (_socketClosed && failure == null) {
      failure = _TestFailureSummary(
        message: 'flutter_tester disconnected mid-test (or test timed out)',
        type: 'TestDeviceException',
        stackChain: '',
      );
    }

    if (failure != null) {
      results.recordFailure(reportName, failure!);
    } else if (fixture == null) {
      results.recordSuccess(reportName);
    }
  }

  Map<String, dynamic> _initialMessage(String testPath) {
    return {
      'type': 'initial',
      'metadata': _defaultMetadata(),
      'platform': _suitePlatform(),
      'platformVariables': const <String>[],
      'collectTraces': true,
      'noRetry': true,
      'allowDuplicateTestNames': true,
      'foldTraceExcept': const <String>[],
      'foldTraceOnly': const <String>[],
      'path': testPath,
      'asciiGlyphs': !stdout.supportsAnsiEscapes,
      'ignoreTimeouts': false,
    };
  }

  /// Minimal `Metadata.serialize` payload — all optional flags omitted, an
  /// empty `forTag`, and the default 30s timeout.
  static Map<String, Object?> _defaultMetadata() {
    return {
      'testOn': null,
      'timeout': {'duration': 30 * Duration.microsecondsPerSecond},
      'skip': null,
      'skipReason': null,
      'verboseTrace': null,
      'chainStackTraces': null,
      'retry': null,
      'tags': const <String>[],
      'onPlatform': const <List<Object>>[],
      'forTag': const <String, Object?>{},
      'languageVersionComment': null,
    };
  }

  /// Built-in `Runtime.vm` and `Compiler.kernel` serialize as plain identifiers.
  static Map<String, Object?> _suitePlatform() {
    return {
      'runtime': 'vm',
      'compiler': 'kernel',
      'os': _osIdentifier(),
      'inGoogle': false,
    };
  }

  static String _osIdentifier() {
    if (Platform.isMacOS) return 'mac-os';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'none';
  }
}

class _TestFailureSummary {
  _TestFailureSummary({
    required this.message,
    required this.type,
    required this.stackChain,
  });

  final String message;
  final String type;
  final String stackChain;

  @override
  String toString() {
    final buf = StringBuffer()
      ..writeln('$type: $message')
      ..write(stackChain);
    return buf.toString();
  }
}

class _Results {
  int passed = 0;
  int failed = 0;
  int skipped = 0;
  bool _suiteError = false;

  void recordSuccess(String name) {
    passed++;
    stdout.writeln('  PASS  $name');
  }

  void recordFailure(String name, _TestFailureSummary summary) {
    failed++;
    stdout.writeln('  FAIL  $name');
    stdout.writeln(_indent(summary.toString(), '        '));
  }

  void recordSkipped(String name, String? reason) {
    skipped++;
    stdout.writeln(reason == null
        ? '  SKIP  $name'
        : '  SKIP  $name (${reason.trim()})');
  }

  void recordError(String message) {
    _suiteError = true;
    stderr.writeln('flutter_test: $message');
  }

  bool get hasFailure => failed > 0 || _suiteError;

  String summary() {
    final pieces = <String>[
      if (passed > 0) '$passed passed',
      if (failed > 0) '$failed failed',
      if (skipped > 0) '$skipped skipped',
    ];
    final body = pieces.isEmpty ? 'no tests' : pieces.join(', ');
    return '\n$body${_suiteError ? ' (suite error)' : ''}';
  }
}

String _indent(String body, String prefix) {
  return body
      .split('\n')
      .map((l) => l.isEmpty ? l : '$prefix$l')
      .join('\n');
}

// ---------------------------------------------------------------------------
// Coverage support — reuse the same VM service JSON-RPC scaffolding the old
// `dart`-based runner had, but pointed at flutter_tester instead of the Dart
// SDK binary.

Future<void> _resumeIsolatesViaVmService(Uri httpUri) async {
  final ws = await _connectVmServiceWebSocket(httpUri);
  try {
    final rpc = _VmServiceRpc(ws);
    final vm = await rpc.call('getVM');
    final isolates = (vm['isolates'] as List?) ?? const [];
    for (final iso in isolates) {
      final id = (iso as Map)['id'] as String;
      try {
        await rpc.call('resume', {'isolateId': id});
      } catch (_) {
        // Already running or has exited — best-effort.
      }
    }
  } finally {
    await ws.close();
  }
}

Future<String> _collectCoverage(Uri httpUri) async {
  final ws = await _connectVmServiceWebSocket(httpUri);
  try {
    final rpc = _VmServiceRpc(ws);
    final vm = await rpc.call('getVM');
    final isolates = (vm['isolates'] as List?) ?? const [];
    final lines = <String>[];
    for (final iso in isolates) {
      final id = (iso as Map)['id'] as String;
      try {
        final report = await rpc.call('getSourceReport', {
          'isolateId': id,
          'reports': const ['Coverage'],
          'forceCompile': true,
        });
        await _formatLcov(report, lines, rpc, id);
      } catch (_) {
        // Isolate exited before we could collect; nothing actionable.
      }
    }
    return lines.join('\n');
  } finally {
    await ws.close();
  }
}

Future<WebSocket> _connectVmServiceWebSocket(Uri httpUri) {
  final wsUri = httpUri.replace(
    scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    path: '${httpUri.path}ws',
  );
  return WebSocket.connect(wsUri.toString());
}

class _VmServiceRpc {
  _VmServiceRpc(this._ws) {
    _sub = _ws.listen(_onMessage);
  }

  final WebSocket _ws;
  late final StreamSubscription<dynamic> _sub;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  int _id = 1;

  void _onMessage(dynamic raw) {
    final m = json.decode(raw as String) as Map<String, dynamic>;
    final id = m['id']?.toString();
    if (id != null && _pending.containsKey(id)) {
      _pending[id]!.complete(m);
    }
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    final id = '${_id++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _ws.add(json.encode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    }));
    return c.future.then((response) {
      _pending.remove(id);
      if (response.containsKey('error')) {
        throw StateError('VM service error on $method: ${response['error']}');
      }
      return response['result'] as Map<String, dynamic>;
    });
  }

  Future<void> close() async {
    await _sub.cancel();
  }
}

Map<int, int> _buildTokenToLineMap(List<dynamic> tokenPosTable) {
  final map = <int, int>{};
  for (final entry in tokenPosTable) {
    final row = entry as List;
    if (row.isEmpty) continue;
    final line = row[0] as int;
    for (var i = 1; i < row.length; i += 2) {
      map[row[i] as int] = line;
    }
  }
  return map;
}

Future<void> _formatLcov(
  Map<String, dynamic> report,
  List<String> lines,
  _VmServiceRpc rpc,
  String isolateId,
) async {
  final scripts = (report['scripts'] as List?) ?? const [];
  final ranges = (report['ranges'] as List?) ?? const [];

  final scriptInfo = <int, ({String id, String uri})>{};
  for (var i = 0; i < scripts.length; i++) {
    final s = (scripts[i] as Map).cast<String, dynamic>();
    scriptInfo[i] = (id: s['id'] as String, uri: s['uri'] as String);
  }

  final perScript = <int, ({List<int> hits, List<int> misses})>{};
  for (final range in ranges) {
    final scriptIndex = (range as Map)['scriptIndex'] as int?;
    if (scriptIndex == null) continue;
    final info = scriptInfo[scriptIndex];
    if (info == null) continue;
    if (info.uri.startsWith('dart:')) continue;
    final coverage = (range['coverage'] as Map?)?.cast<String, dynamic>();
    if (coverage == null) continue;
    final entry = perScript.putIfAbsent(
      scriptIndex,
      () => (hits: <int>[], misses: <int>[]),
    );
    entry.hits.addAll((coverage['hits'] as List?)?.cast<int>() ?? const []);
    entry.misses.addAll((coverage['misses'] as List?)?.cast<int>() ?? const []);
  }

  for (final entry in perScript.entries) {
    final info = scriptInfo[entry.key]!;
    final tokens = entry.value;

    Map<int, int> tokenToLine;
    try {
      final script = await rpc.call('getObject', {
        'isolateId': isolateId,
        'objectId': info.id,
      });
      final table = script['tokenPosTable'] as List?;
      if (table == null) continue;
      tokenToLine = _buildTokenToLineMap(table);
    } catch (_) {
      continue;
    }

    final lineHits = <int, int>{};
    for (final t in tokens.hits) {
      final line = tokenToLine[t];
      if (line != null) lineHits[line] = (lineHits[line] ?? 0) + 1;
    }
    for (final t in tokens.misses) {
      final line = tokenToLine[t];
      if (line != null) lineHits.putIfAbsent(line, () => 0);
    }

    if (lineHits.isEmpty) continue;

    var path = info.uri;
    if (path.startsWith('file://')) path = Uri.parse(path).toFilePath();

    lines.add('SF:$path');
    final sorted = lineHits.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final lh in sorted) {
      lines.add('DA:${lh.key},${lh.value}');
    }
    lines.add('end_of_record');
  }
}
