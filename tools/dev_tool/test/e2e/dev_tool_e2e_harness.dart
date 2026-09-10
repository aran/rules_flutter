/// Reusable harness for dev tool e2e tests.
///
/// Spawns the dev tool as a subprocess and provides helpers for
/// interacting with it via stdin/stdout/stderr and the machine protocol.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart' show TestFailure;

import '../test_lifetime.dart';

// Re-exported because a test that spawns something of its own — the attach
// tests launch the .app directly — needs the same binding the harness uses,
// and the harness is the one import every e2e file already has.
export '../test_lifetime.dart' show spawnBoundToTest;

/// Parsed HTTP control channel info from machine protocol output.
class HttpControlInfo {
  final Uri uri;
  final String token;
  HttpControlInfo({required this.uri, required this.token});
}

/// How far a request to the HTTP control channel got before it stopped.
///
/// This is the receipt signal the HTTP path has, and it is not the one the
/// machine protocol has. There, `app.progress` proves a command was received —
/// but the dev tool emits that only for the commands registered as
/// long-running, which is `app.hotReload` and `app.restart` and nothing else;
/// the whole agent surface this channel carries is silent until it answers.
///
/// HTTP answers the same question by itself. The channel writes a status, a
/// body and a close in one go once its handler returns, so a response header
/// arriving *is* the handler having returned, and a connection that was
/// accepted is the request having been delivered. Where a request stopped
/// therefore separates the three failures that matter: it never reached the
/// tool, it reached it and the handler never came back, or it was answered and
/// the answer was cut off.
enum _RequestPhase { connecting, awaitingHeader, readingBody }

/// A complete answer from the HTTP control channel.
class _ControlReply {
  final int statusCode;
  final List<int> bytes;

  /// Response headers, lower-cased. The screenshot endpoints say whether the
  /// app was idle when they captured (`x-settled`), which the PNG body has
  /// nowhere to carry.
  final Map<String, String> headers;

  _ControlReply(this.statusCode, this.bytes, {this.headers = const {}});

  /// The body as text. Decoded leniently because this is what failures are
  /// reported with: a truncated or binary body must not throw a
  /// [FormatException] out of the diagnostic itself.
  String get body => const Utf8Decoder(allowMalformed: true).convert(bytes);
}

/// Resolves the absolute path to the dev tool entrypoint.
///
/// Assumes tests are run from the `tools/dev_tool/` directory.
String get devToolBin {
  return p.join(Directory.current.path, 'bin', 'flutter_bazel.dart');
}

/// Resolves the absolute path to an e2e workspace.
String e2eWorkspace(String name) {
  return p.normalize(p.join(Directory.current.path, '..', '..', 'e2e', name));
}

/// The repo root, from a test process whose cwd is `tools/dev_tool/`.
String get _repoRoot => p.normalize(p.join(Directory.current.path, '..', '..'));

/// Resolves the absolute path to the bazel-built dev_tool binary.
///
/// This is the binary users get: the AOT `dart_binary`
/// `//tools/dev_tool:flutter_bazel` (`compile_mode = "exe"`). Everything the
/// shipped tool does that `dart run` cannot — resolving bundled helpers out of
/// its runfiles tree (the screenshot tools), running with `RUNFILES_SOURCE_REPO`
/// compiled in — only exists on this path, so it is what the e2e suite drives
/// by default.
///
/// Throws a [StateError] when the binary isn't present. Callers should reach
/// it through [ensureBuiltDevTool], which builds it first.
String get bazelBuiltDevTool {
  // `.exe` on Windows: `compile_mode = "exe"` emits a native executable, and
  // Bazel gives it the platform's extension. Without this the suite reports
  // "not found ... Run: bazel build" on Windows immediately *after* a
  // successful build, which reads as a build failure and is not one.
  final name = Platform.isWindows ? 'flutter_bazel.exe' : 'flutter_bazel';
  final path = p.join(_repoRoot, 'bazel-bin', 'tools', 'dev_tool', name);
  if (!File(path).existsSync()) {
    throw StateError(
      'Bazel-built dev_tool not found at $path. '
      'Run: bazel build //tools/dev_tool:flutter_bazel',
    );
  }
  return path;
}

/// Memoized build of the shipped binary, one per test process.
///
/// `dart test` gives each test *file* its own VM, so this is per file. Every
/// run after the first in a process is a warm Bazel no-op; sharing one future
/// is what keeps a file that starts ten sessions from paying ten analyses.
Future<String>? _devToolBuild;

/// Build `//tools/dev_tool:flutter_bazel` and return its path.
///
/// The e2e tests are plain `dart test` — outside Bazel, with no runfiles of
/// their own — so the only way to reach the shipped binary is to shell out and
/// build it. That happens here rather than in a caller's setup so no test file
/// can forget, and so a stale binary from an older commit can never be what a
/// suite silently measured.
///
/// A failed build throws with the label, the exit code and Bazel's own output.
/// There is deliberately no fall back to `dart run`: a suite that quietly
/// changed which binary it was testing is exactly the hole this closes.
Future<String> ensureBuiltDevTool() => _devToolBuild ??= _buildDevTool();

Future<String> _buildDevTool() async {
  const label = '//tools/dev_tool:flutter_bazel';
  final result = await Process.run(
    'bazel',
    ['build', label],
    workingDirectory: _repoRoot,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Failed to build the shipped dev tool.\n'
      '  cd $_repoRoot && bazel build $label\n'
      '  exit code: ${result.exitCode}\n'
      '${result.stdout}${result.stderr}',
    );
  }
  return bazelBuiltDevTool;
}

/// A running dev tool process with helpers for machine protocol interaction.
class DevToolProcess {
  final Process process;
  final List<Map<String, dynamic>> events = [];
  final List<String> stderrLines = [];

  /// Stdout lines that were not machine-protocol envelopes. Must stay empty in
  /// `--machine` mode; see the listener in the constructor.
  final List<String> nonProtocolStdoutLines = [];
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController.broadcast();
  final StreamController<String> _stderrController =
      StreamController.broadcast();
  late final StreamSubscription _stdoutSub;
  late final StreamSubscription _stderrSub;

  /// Id [dispose]'s `daemon.shutdown` carries. Deliberately far from the small ids
  /// tests hand-pick, so its response can never be mistaken for one of theirs.
  static const _stopCommandId = 999000;

  /// Whether the process has exited. Read by [dispose] so it neither writes to
  /// a closed stdin nor waits on a run that is already over.
  bool _exited = false;

  DevToolProcess(this.process) {
    unawaited(process.exitCode.then((_) => _exited = true));
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          // Machine protocol wraps each message in [...].
          //
          // Anything on this stream that isn't an envelope is corruption an IDE
          // would choke on, so it is recorded rather than silently skipped.
          //
          // A prefix is tolerated but still recorded. When the tool is launched
          // via `dart run` (rather than the compiled binary), the Dart SDK can
          // print "Running build hooks..." with no trailing newline, so the first
          // envelope arrives glued to it. Discarding the whole line loses
          // `daemon.connected` — the event every machine-protocol test waits for
          // first — which reads as an unexplained timeout.
          final start = line.indexOf('[{');
          if (start >= 0 && line.endsWith('}]')) {
            if (start > 0) nonProtocolStdoutLines.add(line.substring(0, start));
            try {
              final list = json.decode(line.substring(start)) as List;
              for (final item in list) {
                final msg = item as Map<String, dynamic>;
                events.add(msg);
                _eventController.add(msg);
              }
            } catch (_) {
              nonProtocolStdoutLines.add(line);
            }
          } else if (line.isNotEmpty) {
            nonProtocolStdoutLines.add(line);
          }
        });
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderrLines.add(line);
          _stderrController.add(line);
        });
  }

  /// The first value from [source], failing as soon as the run dies.
  ///
  /// A bare timeout cannot tell a dev tool that never started from one that
  /// started and stayed quiet — both sit out the full bound and report `Future
  /// not completed`, while the reason is in this process's own stdout,
  /// recorded in [nonProtocolStdoutLines] and read by nobody. Racing
  /// [process.exitCode] makes the first case an immediate failure quoting what
  /// the tool actually said. [what] names the thing being waited for; [seen]
  /// supplies what *was* seen, for the timeout case where the run is alive and
  /// simply never produced it.
  ///
  /// Both endings quote the same two tails, because the reader's question is
  /// the same either way: what was this process doing instead? `Timed out
  /// after 60s waiting for a response to daemon.shutdown` on its own is a true
  /// statement that starts an investigation from zero.
  Future<T> _awaitFrom<T>(
    Stream<T> source, {
    required String what,
    required Duration timeout,
    String Function()? seen,
  }) {
    final died = process.exitCode.then<T>(
      (code) => throw StateError(
        'The dev tool exited (code $code) while waiting for $what.\n'
        '${_lastLines('stderr', stderrLines)}'
        '${_lastLines('stdout (non-protocol)', nonProtocolStdoutLines)}',
      ),
    );

    return Future.any([source.first, died]).timeout(
      timeout,
      onTimeout: () => throw StateError(
        'Timed out after ${timeout.inSeconds}s waiting for $what.\n'
        '${seen == null ? '' : '${seen()}\n'}'
        '${_lastLines('stderr', stderrLines)}'
        '${_lastLines('stdout (non-protocol)', nonProtocolStdoutLines)}',
      ),
    );
  }

  static String _lastLines(String label, List<String> lines) => lines.isEmpty
      ? ''
      : '  $label (last ${lines.length.clamp(0, 20)} of ${lines.length}):\n'
            '${lines.reversed.take(20).toList().reversed.map((l) => '    $l').join('\n')}\n';

  /// Send a machine protocol command and wait for the response.
  ///
  /// [timeout] is named the way every other wait here names it, and bounds the
  /// same thing they do: a tool that is alive and silent. A tool that *dies*
  /// mid-command fails immediately whatever the bound — see [_awaitFrom].
  Future<Map<String, dynamic>> sendCommand(
    int id,
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 60),
  }) {
    final request = <String, dynamic>{
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    // Snapshotted before the write, so the timeout reports what arrived *in
    // reply to this command* rather than everything the run has ever said.
    final sentAt = events.length;
    process.stdin.writeln(json.encode(request));

    return _awaitFrom(
      _eventController.stream.where((msg) => msg['id'] == id),
      what: 'a response to $method (id $id)',
      timeout: timeout,
      seen: () => _trafficSince(sentAt),
    );
  }

  /// One line naming the protocol messages recorded after index [from], by
  /// kind and count.
  ///
  /// Counted rather than listed. A command that hangs has usually seen hundreds
  /// of `app.log` lines by the time its bound expires, and truncating a list to
  /// fit would drop the one message that answers the question: `app.progress`.
  /// The tool emits that *before* it takes the command pool
  /// ([CommandRunner.run]), so its presence proves the command was received,
  /// and its `finished` flag says whether the handler ever returned. Those are
  /// three different bugs — never delivered, queued behind something else, or
  /// running and stuck — and none of them are recoverable from a bare timeout.
  ///
  /// Shared with the HTTP waits, where it answers a different question. Only
  /// `app.hotReload` and `app.restart` are registered long-running, so nothing
  /// an HTTP caller sends announces *itself* here — but the command runner
  /// serializes everything through one slot, so a reload that started and never
  /// finished is exactly why some later `app.getText` is still waiting.
  String _trafficSince(int from) {
    final since = events.skip(from);
    final counts = <String, int>{};
    for (final msg in since) {
      counts.update(_kindOf(msg), (n) => n + 1, ifAbsent: () => 1);
    }
    if (counts.isEmpty) {
      return 'Nothing at all arrived on the protocol stream after the '
          'request was sent.';
    }
    return 'Saw ${since.length} message(s) since the request was sent: '
        '${counts.entries.map((e) => '${e.value} ${e.key}').join(', ')}.';
  }

  /// The kind [_trafficSince] groups a protocol message under.
  static String _kindOf(Map<String, dynamic> msg) {
    final event = msg['event'];
    if (event == null) return 'response to id ${msg['id']}';
    if (event != 'app.progress') return '$event';
    // `message` carries the method: the dev tool reports a long-running
    // command's progress by name (`SessionHost`'s `onProgress`).
    final params = msg['params'] as Map?;
    return 'app.progress[${params?['message']}] '
        '${params?['finished'] == true ? 'finished' : 'started'}';
  }

  /// Wait for an event with the given name.
  Future<Map<String, dynamic>> waitForEvent(
    String eventName, {
    Duration timeout = const Duration(seconds: 120),
  }) {
    // Check already-received events first.
    for (final e in events) {
      if (e['event'] == eventName) return Future.value(e);
    }
    return _awaitFrom(
      _eventController.stream.where((msg) => msg['event'] == eventName),
      what: 'the $eventName event',
      timeout: timeout,
      seen: () =>
          'Saw ${events.length} event(s): '
          '${events.map((e) => e['event'] ?? 'id ${e['id']}').join(', ')}',
    );
  }

  /// Wait for an [eventName] event, no earlier than [after] in [events], whose
  /// `params` satisfy [test].
  ///
  /// [waitForEvent] matches on the name alone and replays everything already
  /// seen, which is exactly wrong for a run that reloads more than once: the
  /// second wait returns the *first* reload's event and the test goes green
  /// without the thing it was waiting for having happened at all. A caller
  /// reads [events].length before the edit it is about to make and passes it
  /// as [after], so only what happens next can satisfy the wait.
  ///
  /// [what] names the thing being waited for, for the timeout message.
  Future<Map<String, dynamic>> waitForEventWhere(
    String eventName, {
    required bool Function(Map<String, dynamic> params) test,
    required String what,
    int after = 0,
    Duration timeout = const Duration(seconds: 120),
  }) {
    bool matches(Map<String, dynamic> msg) =>
        msg['event'] == eventName &&
        test((msg['params'] as Map?)?.cast<String, dynamic>() ?? {});

    // Synchronous, with no `await` before the subscribe below, so an event
    // cannot land in between and be missed by both halves.
    for (final e in events.skip(after)) {
      if (matches(e)) return Future.value(e);
    }
    return _awaitFrom(
      _eventController.stream.where(matches),
      what: what,
      timeout: timeout,
      seen: () {
        final since = events.skip(after).where((e) => e['event'] == eventName);
        return 'Saw ${since.length} $eventName event(s) since: '
            '${since.map(json.encode).join(' | ')}';
      },
    );
  }

  /// Every `app.log` line seen so far.
  List<String> get appLogLines => [
    for (final e in events)
      if (e['event'] == 'app.log') e['params']?['log'] as String? ?? '',
  ];

  /// Wait for an `app.log` event whose text contains [needle].
  ///
  /// App output is only visible in machine mode as `app.log` — raw text on
  /// stdout would corrupt the JSON-RPC stream, and [DevToolProcess] discards
  /// non-`[{…}]` lines for exactly that reason. So this is the assertion that
  /// actually proves the dev tool forwards a running app's output.
  Future<String> waitForAppLog(
    Pattern needle, {
    Duration timeout = const Duration(seconds: 120),
  }) {
    bool matches(String log) => log.contains(needle);

    for (final log in appLogLines) {
      if (matches(log)) return Future.value(log);
    }
    return _awaitFrom(
      _eventController.stream
          .where((msg) => msg['event'] == 'app.log')
          .map((msg) => msg['params']?['log'] as String? ?? '')
          .where(matches),
      what: 'an app.log line matching "$needle"',
      timeout: timeout,
      seen: () =>
          'Saw ${appLogLines.length} app.log line(s): '
          '${appLogLines.take(20).join(" | ")}',
    );
  }

  /// Wait for a stderr line containing [needle].
  ///
  /// The dev tool's diagnostics all go to stderr (stdout belongs to the
  /// machine protocol), so this is how a test asserts on what a *user* would
  /// have read — including the message a run ends with. Waiting beats reading
  /// [stderrLines] after `exitCode`: the pipe can still be draining then.
  Future<String> waitForStderr(
    Pattern needle, {
    Duration timeout = const Duration(seconds: 120),
  }) {
    bool matches(String line) => line.contains(needle);

    for (final line in stderrLines) {
      if (matches(line)) return Future.value(line);
    }
    // No `seen`: what this wait would report is the stderr tail every timeout
    // now carries.
    return _awaitFrom(
      _stderrController.stream.where(matches),
      what: 'a stderr line matching "$needle"',
      timeout: timeout,
    );
  }

  /// The bound every request to the HTTP control channel carries.
  ///
  /// Sized above the slowest answer the dev tool can still legitimately
  /// produce, because every bound the tool applies to itself ends in a
  /// *response* that says more than a timeout here ever could. A session whose
  /// VM service has not arrived yet is waited on for 60s
  /// (`agent_command.dart`'s `_debugConnectTimeout`), each of the two service
  /// extensions checked after that allows 30s, and the app-side handlers take a
  /// `timeoutMs` this suite passes up to 30s: 150s of answering, worst case.
  /// Preempting any of those would trade a precise refusal for a bare timeout.
  ///
  /// It still leaves most of the 5-minute e2e budget (`dart_test.yaml`) for the
  /// failure to be reported in, which matters more here than in most places: a
  /// `package:test` timeout abandons the body rather than cancelling it, so a
  /// wait that outlives it takes the test's own cleanup with it.
  static const _controlChannelTimeout = Duration(seconds: 180);

  /// The URL of [path] on the control channel, with the auth token attached.
  ///
  /// Throws when the channel has not announced itself yet, which is the one
  /// state in which none of the callers below can do anything at all.
  Uri _controlUrl(
    String path, {
    Map<String, String> queryParameters = const {},
  }) {
    final info = httpControl;
    if (info == null) throw StateError('HTTP control channel not available');
    return info.uri.replace(
      path: path,
      queryParameters: {'token': info.token, ...queryParameters},
    );
  }

  /// Perform one request against the HTTP control channel, under [timeout].
  ///
  /// Every HTTP helper here goes through this, because none of them could
  /// express a bound on their own: `HttpClient`'s `idleTimeout` governs pooled
  /// *idle* connections and `connectionTimeout` only the connect, so an
  /// accepted request whose handler never returns waits forever. That is
  /// precisely the shape that strands a dev tool and the app it launched, since a
  /// `package:test` timeout leaves the abandoned body parked on the wait and
  /// never runs the teardown that would have stopped them.
  ///
  /// [what] names the thing being asked for, the way the protocol waits name
  /// theirs. On either ending — expired, or a transport error — the failure
  /// carries where the request got to, what the protocol stream said while it
  /// was outstanding, and the two output tails, because "which of us is stuck"
  /// is not answerable from the request alone.
  Future<_ControlReply> _controlRequest(
    Uri url, {
    required String what,
    required Duration timeout,
    String? postJson,
  }) async {
    // Snapshotted before anything is awaited, so the failure reports what
    // arrived *while this request was outstanding* rather than everything the
    // run has ever said.
    final sentAt = events.length;
    var phase = _RequestPhase.connecting;
    int? status;
    final client = HttpClient();

    Future<_ControlReply> attempt() async {
      final request = postJson == null
          ? await client.getUrl(url)
          : await client.postUrl(url);
      if (postJson != null) {
        request.headers.contentType = ContentType.json;
        request.write(postJson);
      }
      phase = _RequestPhase.awaitingHeader;
      final response = await request.close();
      status = response.statusCode;
      phase = _RequestPhase.readingBody;
      final chunks = <List<int>>[];
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(', ');
      });
      await response.forEach(chunks.add);
      return _ControlReply(
        response.statusCode,
        chunks.expand((chunk) => chunk).toList(),
        headers: headers,
      );
    }

    try {
      return await attempt().timeout(timeout);
    } on TimeoutException {
      throw StateError(
        'Timed out after ${_formatBound(timeout)} waiting for $what over the '
        'HTTP control channel.\n'
        '${_requestContext(phase, status, sentAt, expired: timeout)}',
      );
    } catch (e) {
      throw StateError(
        'The HTTP control channel request for $what did not complete: $e\n'
        '${_requestContext(phase, status, sentAt)}',
      );
    } finally {
      // Forced, so an expired bound severs the socket instead of leaving a
      // connection open to a handler that is never coming back. Safe on the
      // success path too: the body has been read in full by the time this runs,
      // and this client is never reused.
      client.close(force: true);
    }
  }

  /// What a failed control-channel request reports besides its headline.
  ///
  /// [expired] is the bound that ran out, and is null when the request failed
  /// in transport instead — where no bound was reached and naming one would
  /// invent a cause.
  String _requestContext(
    _RequestPhase phase,
    int? status,
    int sentAt, {
    Duration? expired,
  }) =>
      '${_phaseSentence(phase, status, expired)}\n'
      '${_trafficSince(sentAt)}\n'
      '${_lastLines('stderr', stderrLines)}'
      '${_lastLines('stdout (non-protocol)', nonProtocolStdoutLines)}';

  /// How far the request got, and — for the header phase — what that does and
  /// does not license the reader to conclude.
  ///
  /// It stops short of "so the handler that took it never returned", which the
  /// observation does not support: callers that bound a request by what is left
  /// of a polling deadline can hand it less time than one answer takes, so that
  /// sentence would accuse a handler that is answering promptly. The bound is
  /// named and the conclusion is left to the reader.
  static String _phaseSentence(
    _RequestPhase phase,
    int? status,
    Duration? expired,
  ) => switch (phase) {
    _RequestPhase.connecting => 'The request never established a connection.',
    _RequestPhase.awaitingHeader =>
      expired == null
          ? 'The request was sent and no response header arrived.'
          : 'The request was sent and no response header arrived within the '
                '${_formatBound(expired)} it was given, so the handler that '
                'took it had not returned by then — which is not the same as '
                'never returning, since a bound shorter than one answer takes '
                'ends here too.',
    _RequestPhase.readingBody =>
      'The response header arrived (status $status) and the body never '
          'ended.',
  };

  /// A bound as the reader has to read it: sub-second budgets rendered whole.
  ///
  /// `inSeconds` truncates, so a 200ms bound would print as "0s" and a request
  /// given a sliver of a deadline would read as one given no time at all.
  static String _formatBound(Duration bound) {
    if (bound.inMilliseconds < Duration.millisecondsPerSecond) {
      return '${bound.inMilliseconds}ms';
    }
    final seconds = bound.inMilliseconds / Duration.millisecondsPerSecond;
    return seconds == seconds.roundToDouble()
        ? '${seconds.round()}s'
        : '${seconds.toStringAsFixed(1)}s';
  }

  /// Fetch a page of app output from the HTTP control channel's `/logs`
  /// endpoint. [since] follows the endpoint's cursor rules: omitted tails,
  /// negative tails that many lines, 0 reads from the start, positive resumes.
  Future<Map<String, dynamic>> httpLogs(
    String appId, {
    int? since,
    int? limit,
    Duration timeout = _controlChannelTimeout,
  }) async {
    final reply = await _controlRequest(
      _controlUrl(
        '/sessions/$appId/logs',
        queryParameters: {
          if (since != null) 'since': '$since',
          if (limit != null) 'limit': '$limit',
        },
      ),
      what: 'the log page for $appId',
      timeout: timeout,
    );
    if (reply.statusCode != HttpStatus.ok) {
      throw StateError('logs failed (${reply.statusCode}): ${reply.body}');
    }
    return json.decode(reply.body) as Map<String, dynamic>;
  }

  /// Extract the HTTP control channel info from structured JSON stderr lines.
  ///
  /// Parses the `http_control_channel` structured log entry emitted by the
  /// dev tool when `LOG_FORMAT=json`.
  HttpControlInfo? get httpControl {
    for (final line in stderrLines) {
      try {
        final obj = json.decode(line) as Map<String, dynamic>;
        if (obj['message'] == 'http_control_channel') {
          return HttpControlInfo(
            uri: Uri.parse(obj['uri'] as String),
            token: obj['token'] as String,
          );
        }
      } catch (_) {
        // Not JSON — skip.
      }
    }
    return null;
  }

  /// Wait for the HTTP control channel to be available.
  Future<HttpControlInfo> waitForHttpControl({
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final existing = httpControl;
    if (existing != null) return existing;
    await _awaitFrom(
      _stderrController.stream.where((line) {
        try {
          final obj = json.decode(line) as Map<String, dynamic>;
          return obj['message'] == 'http_control_channel';
        } catch (_) {
          return false;
        }
      }),
      what: 'the http_control_channel log record',
      timeout: timeout,
    );
    return httpControl!;
  }

  /// Take a screenshot via the HTTP control channel.
  ///
  /// Asks the `flutter` endpoint (VM service `_flutter.screenshot`), which
  /// captures the widget tree without needing display access, and takes the
  /// `native` capture instead on the one answer that means this device can
  /// never serve the first: `501`. The channel returns that from a device
  /// declaring `supportsFlutterScreenshot => false`, which since the Flutter
  /// 3.47 bump is every device — every platform renders with Impeller, and
  /// Impeller cannot encode a compressed screenshot — and its body names
  /// `screenshot/native` as the way to capture the same app. Following a
  /// documented refusal is not a fallback; the second request is what the
  /// first one asked for.
  ///
  /// Every other failure propagates. Swallowing the first attempt would capture
  /// natively from a device that *should* serve `_flutter.screenshot` and has
  /// stopped, discarding the error that says so and leaving the reader only the
  /// second endpoint's failure when both fail. [httpFlutterScreenshotReply]
  /// exists to assert the refusal itself.
  Future<List<int>> httpScreenshot(
    String appId, {
    Duration timeout = _controlChannelTimeout,
  }) async {
    final flutter = await _screenshotReply(appId, 'flutter', timeout: timeout);
    if (flutter.statusCode != HttpStatus.notImplemented) {
      return _screenshotBytes(flutter, 'Screenshot');
    }
    return httpNativeScreenshot(appId, timeout: timeout);
  }

  /// The `screenshot/flutter` endpoint's own answer, whatever its status.
  ///
  /// [httpScreenshot] follows a `501` through to the native endpoint, which is
  /// right for a caller that wants pixels and wrong for a test that wants to
  /// see the refusal — under it, a device that stopped serving the RPC and one
  /// that never did look identical.
  Future<({int statusCode, String body})> httpFlutterScreenshotReply(
    String appId, {
    Duration timeout = _controlChannelTimeout,
  }) async {
    final reply = await _screenshotReply(appId, 'flutter', timeout: timeout);
    return (statusCode: reply.statusCode, body: reply.body);
  }

  /// One request to a screenshot endpoint, answered whatever its status.
  ///
  /// The status is handed back rather than thrown on, because [httpScreenshot]
  /// has to tell a refusal (`501`) from a failure and cannot do that from an
  /// exception alone.
  Future<_ControlReply> _screenshotReply(
    String appId,
    String type, {
    String? window,
    bool? settle,
    required Duration timeout,
  }) => _controlRequest(
    _controlUrl(
      '/sessions/$appId/screenshot/$type',
      queryParameters: {
        if (window != null) 'window': window,
        if (settle != null) 'settle': '$settle',
      },
    ),
    what: 'a $type screenshot of $appId',
    timeout: timeout,
  );

  /// The captured bytes, or the failure the endpoint answered with instead.
  static List<int> _screenshotBytes(_ControlReply reply, String what) {
    if (reply.statusCode != HttpStatus.ok) {
      throw StateError('$what failed (${reply.statusCode}): ${reply.body}');
    }
    return reply.bytes;
  }

  /// Take a screenshot and save to a file. Returns the file path.
  Future<String> httpScreenshotToFile(String appId, String outputPath) async {
    final bytes = await httpScreenshot(appId);
    await File(outputPath).writeAsBytes(bytes);
    return outputPath;
  }

  /// Hit the `native` screenshot endpoint directly, optionally selecting a
  /// window by exact title via `?window=<encoded>`. Distinct from
  /// [httpScreenshot], which asks the engine first.
  Future<List<int>> httpNativeScreenshot(
    String appId, {
    String? window,
    Duration timeout = _controlChannelTimeout,
  }) async => _screenshotBytes(
    await _screenshotReply(appId, 'native', window: window, timeout: timeout),
    'Native screenshot',
  );

  /// A native capture with the endpoint's own account of it.
  ///
  /// `settled` is `X-Settled` — `yes`, `no` or `skipped` — and `detail` the
  /// reason for anything but `yes`. A test that only reads pixels cannot tell
  /// a fresh frame from a stale one, which is the whole point of the header.
  Future<({List<int> bytes, String? settled, String? detail})>
  httpNativeScreenshotReply(
    String appId, {
    bool? settle,
    Duration timeout = _controlChannelTimeout,
  }) async {
    final reply = await _screenshotReply(
      appId,
      'native',
      settle: settle,
      timeout: timeout,
    );
    return (
      bytes: _screenshotBytes(reply, 'Native screenshot'),
      settled: reply.headers['x-settled'],
      detail: reply.headers['x-settle-detail'],
    );
  }

  /// Poll the `native` screenshot endpoint until the app has an on-screen
  /// window.
  ///
  /// Nothing announces "the NSWindow is on screen". `app.started` fires when
  /// the engine is up, which is strictly earlier, and ScreenCaptureKit only
  /// enumerates a window once the window server has mapped it. A flat
  /// `Future.delayed` cannot bridge that gap: it is wasteful when the window is
  /// already up and mute when it is not long enough, producing a failure that
  /// says only that the capture found no window, with no way to tell "still
  /// coming" from "never coming".
  ///
  /// The condition being waited for is exactly what this endpoint answers, so
  /// it is polled with backoff rather than slept past, and the first successful
  /// capture returns immediately. On expiry what gets thrown is the endpoint's
  /// own answer — which windows the pid owns and whether any of them are in
  /// ScreenCaptureKit's on-screen set — so the failure carries what was
  /// observed instead of reporting a bare timeout.
  ///
  /// Each attempt is bounded by what is left of [timeout], not by the default,
  /// because the deadline below is only consulted *between* attempts:
  /// otherwise one capture that never answers outlives the whole bound it is
  /// being polled under, which is the failure this helper exists to limit.
  ///
  /// That bound is why an *answer* and a *transport failure* are tracked apart
  /// rather than collapsed into one "last error". A later attempt can be handed
  /// a slice of the deadline shorter than one answer takes and expire before
  /// its header arrives; reporting that as the reason would replace a diagnosis
  /// the endpoint has already given with a sentence saying the handler never
  /// returned, reading a working endpoint as one that hangs. So an answer, once
  /// received, is the reason; a transport failure after it is reported beside
  /// it rather than over it.
  ///
  /// Preferring the answer is conditional on there being one, deliberately.
  /// Where nothing ever answers, the endpoint really is wedged, and that has to
  /// stay legible — it is the world in which "no response header ever arrived"
  /// is the true story rather than an artifact of the budget.
  Future<List<int>> nativeScreenshotWhenOnScreen(
    String appId, {
    String? window,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    const maxBackoff = Duration(seconds: 2);
    var backoff = const Duration(milliseconds: 100);
    String? lastAnswer;
    Object? lastTransportFailure;
    while (true) {
      // Checked *before* attempting, so no attempt is ever made with no time
      // left to make it in. One that is becomes an instant expiry naming the
      // connect phase, where what the reader needs is the endpoint's own
      // account of the windows it found.
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw StateError(
          'The app never presented an on-screen window within '
          '${timeout.inSeconds}s of polling the native screenshot endpoint. '
          '${_pollVerdict(lastAnswer, lastTransportFailure)}',
        );
      }
      final _ControlReply reply;
      try {
        reply = await _screenshotReply(
          appId,
          'native',
          window: window,
          timeout: remaining,
        );
      } catch (e) {
        // No answer at all: the request never got a status back, so this says
        // nothing about the window and cannot stand in for a diagnosis.
        lastTransportFailure = e;
        await Future<void>.delayed(backoff);
        backoff = _nextBackoff(backoff, maxBackoff);
        continue;
      }
      if (reply.statusCode == HttpStatus.ok) return reply.bytes;
      // `body` rather than a decode of `bytes`: this text goes straight into a
      // diagnostic, and a truncated or binary body must not throw a
      // [FormatException] out of the report of the thing that went wrong.
      lastAnswer = 'the endpoint answered ${reply.statusCode}: ${reply.body}';
      await Future<void>.delayed(backoff);
      backoff = _nextBackoff(backoff, maxBackoff);
    }
  }

  static Duration _nextBackoff(Duration backoff, Duration max) {
    final doubled = backoff * 2;
    return doubled > max ? max : doubled;
  }

  /// Why the poll above expired, told from what it actually collected.
  static String _pollVerdict(String? lastAnswer, Object? lastTransportFailure) {
    if (lastAnswer == null) {
      return 'No attempt ever reached an answer. The last one reported: '
          '$lastTransportFailure';
    }
    if (lastTransportFailure == null) {
      return 'Every attempt was refused: $lastAnswer';
    }
    return 'Every attempt that was answered was refused: $lastAnswer\n'
        'A later attempt did not reach an answer at all: $lastTransportFailure';
  }

  /// Extract appId from app.start events.
  String? get appId {
    for (final e in events) {
      if (e['event'] == 'app.start') {
        return e['params']?['appId'] as String?;
      }
    }
    return null;
  }

  /// What this run currently says it can be asked to do.
  ///
  /// Read from the most recent announcement rather than the first: the surface
  /// grows during a run (`app.setViewport` once a browser is up, the WASM pair
  /// once Chrome's debugging port is known), and `daemon.commandsChanged` is
  /// how that is announced. Empty until `daemon.connected` arrives.
  List<String> get commands {
    for (final e in events.reversed) {
      if (e['event'] == 'daemon.commandsChanged' ||
          e['event'] == 'daemon.connected') {
        final list = e['params']?['commands'] as List?;
        if (list == null) continue;
        return [for (final c in list) (c as Map)['name'] as String];
      }
    }
    return const [];
  }

  /// Send a command via the HTTP control channel and return the JSON response,
  /// with any failure reachable at the top-level `error` key.
  ///
  /// A fault the channel names itself — bad JSON, unknown method, a handler
  /// that threw — and a command that ran and refused both arrive with a
  /// top-level `{'error': ...}`. That is what makes `expect(r['error'],
  /// isNull)` — the guard nearly every caller here opens with — mean what it
  /// reads as: a check that saw only transport faults would let an `unknown
  /// appId` or a `waitFor` that timed out slide past it, and the test would go
  /// on to assert against an app that never answered.
  ///
  /// `result` is left in place, so `r['result']?['text']` still reads the
  /// payload and a test that cares which kind of failure it got can still tell:
  /// a transport fault has no `result` key at all.
  ///
  /// The status code is deliberately not checked. Both shapes above are
  /// *answers* — an unknown method and a handler that threw are things a test
  /// asserts on — so a non-2xx is decoded like any other reply rather than
  /// thrown out from under the caller.
  ///
  /// [timeout] bounds the wait the way every other one here is bounded, and
  /// this is the path that carries the entire agent surface: `app.getText`,
  /// `app.tap`, `app.waitFor` and the rest all arrive through it, none of them
  /// announce themselves on the protocol stream, and the command runner
  /// serializes them through a one-slot pool — so one that never returns stops
  /// every later one too.
  Future<Map<String, dynamic>> httpCommand(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = _controlChannelTimeout,
  }) async {
    final reply = await _controlRequest(
      _controlUrl('/command'),
      what: 'the $method command',
      timeout: timeout,
      postJson: json.encode({'method': method, 'params': params}),
    );
    // Returned whatever the status: a refused command answers with a 4xx and
    // a top-level `error`, which is a reply to assert on rather than a
    // transport failure to raise.
    return json.decode(reply.body) as Map<String, dynamic>;
  }

  /// Stop the dev tool and clean up.
  ///
  /// Asks for `daemon.shutdown` first and waits for the run to end on its own,
  /// because
  /// the tool's own teardown is the only thing that stops what it launched: a
  /// SIGTERM'd dev tool leaves its Chrome (and the `flutter_chrome_*` profile
  /// behind it) running. That matters beyond tidiness — an orphaned browser
  /// from a test that failed mid-run is a live window a *later* run can be
  /// screenshotted against, which is how a stale app produces a false pass.
  ///
  /// Killing stays as the bounded fallback for a tool that is wedged, and the
  /// whole graceful path is skipped once the process is gone, so this is safe
  /// to call twice or after the run already ended.
  Future<void> dispose() async {
    final endedOnItsOwn = await _requestStop();
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    await _eventController.close();
    await _stderrController.close();
    if (!_exited) {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -9;
        },
      );
    }
    // Every e2e test is a lifetime guard, not just the two that say so:
    // swallowing the timeout and killing would leave a tool that can no longer
    // end on its own costing every test in the suite silent seconds, caught
    // only by the two tests that assert on the exit. Reported after the kill,
    // so the process is gone either way and a failing test body still gets its
    // own error reported beside this one.
    if (!endedOnItsOwn) {
      throw StateError(
        'The dev tool answered `daemon.shutdown` but had not exited '
        '${_stopBound.inSeconds}s later, so this teardown killed it. Its own '
        'shutdown had already released the app, the browser and every socket '
        'it held, so what is keeping the process alive is the tool itself — '
        'an uncancelled subscription or a pending timer. A run that cannot '
        'end on its own is one an IDE or an agent cannot end either; see '
        '`SessionHost.closeTransports`.',
      );
    }
  }

  /// How long the tool gets to end itself after `daemon.shutdown`.
  ///
  /// A bound on a run that cannot end *at all*, not a performance assertion: a
  /// shutdown that lands normally returns the tool from its session loop in a
  /// second or two, and the failure this catches is indefinite. Sized
  /// generously for that reason, so that a busy machine under a full-suite run
  /// is not read as a stuck tool (`docs/TESTING.md` has the same caution about
  /// every other bound in this suite).
  ///
  /// The two tests that assert the exit *deliberately* keep their own tighter
  /// bounds; this is the backstop under every other test.
  static const _stopBound = Duration(seconds: 60);

  /// Send `daemon.shutdown` and wait for the process to exit.
  ///
  /// `daemon.shutdown`, not `app.stop`: the latter stops one named app and
  /// leaves the run going, which is upstream's contract and now ours.
  ///
  /// Answers whether it ended on its own, which [dispose] turns into a test
  /// failure. Returning quietly on expiry would let a tool that cannot end at
  /// all look like a tidy teardown.
  Future<bool> _requestStop({Duration timeout = _stopBound}) async {
    if (_exited) return true;
    try {
      process.stdin.writeln(
        json.encode({'id': _stopCommandId, 'method': 'daemon.shutdown'}),
      );
      await process.stdin.flush();
    } on IOException {
      // Broken pipe — the run ended between the check above and the write.
      return true;
    } on StateError {
      // stdin is already closed, same story.
      return true;
    }
    try {
      await process.exitCode.timeout(timeout);
      return true;
    } on TimeoutException {
      // Not a sentinel exit code: a process killed by a signal reports a
      // negative status of its own, so -1 could not tell "never exited" from
      // "exited on SIGHUP".
      return false;
    }
  }
}

/// Spawn the dev tool in machine mode and return a [DevToolProcess].
///
/// Sets `LOG_FORMAT=json` so the harness can parse structured log entries
/// from stderr (e.g. HTTP control channel info).
///
/// The commands differ only in their argv, so they share this: whichever
/// subcommand a test drives, it gets the same launch style, the same
/// environment, and — the part that matters — the same [DevToolProcess.dispose]
/// contract, so nothing it starts outlives the test.
///
/// [spawnBoundToTest] is what makes that last clause true rather than
/// aspirational. `package:test` abandons a timed-out body without running its
/// `finally`, so caller-owned disposal leaves the tool, the app it launched and
/// its frontend server running, reparented to init. Registering here — before
/// the spawn, on the one path every launch goes through — means no test can
/// forget and no test can be cut off before it remembers.
///
/// Launches the shipped AOT binary unless [viaDartRun] asks otherwise; see
/// [ensureBuiltDevTool] for why that is the default.
Future<DevToolProcess> _spawnDevTool({
  required String workspace,
  required String target,
  required List<String> args,
  bool viaDartRun = false,
}) async {
  return spawnBoundToTest(
    spawn: () async {
      final process = viaDartRun
          ? await Process.start(
              await hermeticDart(workspace: workspace, target: target),
              ['run', devToolBin, ...args],
              workingDirectory: workspace,
              environment: {...Platform.environment, 'LOG_FORMAT': 'json'},
            )
          : await Process.start(
              await ensureBuiltDevTool(),
              args,
              workingDirectory: workspace,
              environment: {...Platform.environment, 'LOG_FORMAT': 'json'},
            );
      return DevToolProcess(process);
    },
    dispose: (tool) => tool.dispose(),
  );
}

/// Start `flutter_bazel run` on [device].
Future<DevToolProcess> startDevTool({
  required String workspace,
  required String target,
  required String device,
  List<String> extraArgs = const [],
  bool viaDartRun = false,
  bool watch = false,
}) => _spawnDevTool(
  workspace: workspace,
  target: target,
  viaDartRun: viaDartRun,
  args: [
    'run',
    '-t',
    target,
    '-d',
    device,
    '--machine',
    '--no-devtools',
    // Machine mode defaults the filesystem watcher OFF; opt back in to
    // exercise watch-driven (terminal-style) reloads.
    if (watch) '--watch',
    ...extraArgs,
  ],
);

/// Start `flutter_bazel attach` against an already-running app's [debugUrl].
///
/// Machine mode, like every other launch here, and spawned rather than run to
/// completion: `Process.run` waits for an exit an interactive session never
/// reaches, so it can only time out and abandon a process still holding a
/// frontend server.
Future<DevToolProcess> attachDevTool({
  required String workspace,
  required String target,
  required String debugUrl,
  List<String> extraArgs = const [],
  bool viaDartRun = false,
}) => _spawnDevTool(
  workspace: workspace,
  target: target,
  viaDartRun: viaDartRun,
  args: [
    'attach',
    '-t',
    target,
    '--debug-url',
    debugUrl,
    '--machine',
    '--no-devtools',
    ...extraArgs,
  ],
);

/// Cache of resolved toolchain Darts, keyed by workspace. Resolution costs a
/// `bazel info` (and on a cold repo a `bazel fetch`) subprocess, and one e2e
/// file starts many runs against the same workspace.
final Map<String, String> _hermeticDartByWorkspace = {};

/// The `dart` the dev tool itself runs on: the Flutter toolchain's, resolved
/// out of [workspace]'s Bazel output base.
///
/// `dart run` compiles the tool's whole dependency graph, and `dwds` declares
/// language version 3.12, so a `dart` older than that on PATH fails the spawn
/// outright — every test then sees an unexplained timeout waiting for
/// `daemon.connected` rather than the compile error that caused it. Whichever
/// `dart` happens to come first on PATH is not a property of this repo, so the
/// harness resolves the same toolchain the dev tool passes to its own
/// subprocesses ([resolveToolchainPaths]) instead of inheriting it.
///
/// Throws rather than falling back to PATH when the toolchain cannot be found:
/// a run on an unknown Dart is exactly the failure this exists to prevent.
Future<String> hermeticDart({
  required String workspace,
  required String target,
}) async {
  final cached = _hermeticDartByWorkspace[workspace];
  if (cached != null) return cached;
  final toolchain = await resolveToolchainPaths(target, workspace: workspace);
  if (!File(toolchain.dart).existsSync()) {
    throw StateError(
      'Flutter toolchain dart not found at ${toolchain.dart} (resolved from '
      'the Bazel output base of $workspace). Fetch the toolchain with: '
      '(cd $workspace && bazel build $target)',
    );
  }
  return _hermeticDartByWorkspace[workspace] = toolchain.dart;
}

/// The result of [runBounded]. [exitCode] is null when the bound expired and
/// the process had to be killed — i.e. the command never answered.
class BoundedRun {
  final int? exitCode;
  final String stdout;
  final String stderr;

  BoundedRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// The command was still running when its bound expired.
  bool get timedOut => exitCode == null;

  /// The command answered, and answered successfully.
  bool get succeeded => exitCode == 0;

  @override
  String toString() => timedOut
      ? 'timed out'
      : 'exit $exitCode${stderr.trim().isEmpty ? '' : ': ${stderr.trim()}'}';
}

/// Run [executable] under a hard [timeout], and leave nothing behind if it
/// expires.
///
/// This exists for commands that can block *indefinitely* rather than fail —
/// `osascript` is the case in hand. macOS gates AppleEvents behind the
/// Automation TCC, and when that permission is undecided the send blocks in the
/// consent machinery instead of returning an error. [Process.run] cannot
/// express a bound (its future is not cancellable and the child outlives the
/// VM), so a test using it has no way to conclude "unavailable" — it sits
/// there, and when the enclosing test timeout fires the abandoned body never
/// runs its teardown: an orphaned `osascript`, plus a leaked app and dev tool,
/// outliving the suite.
///
/// The bound is not a sleep — nothing here waits out a fixed delay. It is the
/// deadline on an external call that has no other way to say "no", and the
/// wait ends the instant the process exits.
///
/// The kill mirrors [DevToolProcess.dispose]: ask with SIGTERM, escalate to
/// SIGKILL, and in both cases still await `exitCode` so the child is reaped
/// rather than left a zombie.
Future<BoundedRun> runBounded(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  Duration killGrace = const Duration(seconds: 2),
}) async {
  final process = await Process.start(executable, arguments);
  final out = StringBuffer();
  final err = StringBuffer();
  // `allowMalformed` because a command's bytes are its own business: strict
  // decoding would throw out of here, turning a caller's "unavailable, skip"
  // into a test failure over an encoding.
  const decoder = Utf8Decoder(allowMalformed: true);
  final drained = Future.wait([
    process.stdout.transform(decoder).forEach(out.write),
    process.stderr.transform(decoder).forEach(err.write),
  ]);

  int? code;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    try {
      await process.exitCode.timeout(killGrace);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }
  // The pipes close when the last holder of them does, and `kill` signals the
  // child alone — a grandchild that inherited them would keep this waiting
  // after the child is gone, which is the very hang being prevented. So the
  // drain is bounded too, and the output collected so far is what gets
  // reported.
  await drained.timeout(killGrace, onTimeout: () => const []);
  return BoundedRun(
    exitCode: code,
    stdout: out.toString(),
    stderr: err.toString(),
  );
}

/// Resolve `adb` the same way the dev tool itself does: $ANDROID_HOME
/// → macOS default → PATH. Inlined to keep the harness independent of
/// the dev tool's internal device library.
///
/// Note the fallthrough: an `$ANDROID_HOME` that holds no `platform-tools/adb`
/// does not mean "no adb", it means "keep looking", and on a machine with an
/// SDK in the default location the search then finds a perfectly working one.
/// That is why every message built from a probe names the path that actually
/// answered rather than the variable that was set.
String resolveAdb(Map<String, String> environment) {
  final androidHome = environment['ANDROID_HOME'];
  if (androidHome != null) {
    final adb = p.join(androidHome, 'platform-tools', 'adb');
    if (File(adb).existsSync()) return adb;
  }
  if (Platform.isMacOS) {
    final home = environment['HOME'];
    if (home != null) {
      final adb = p.join(
        home,
        'Library',
        'Android',
        'sdk',
        'platform-tools',
        'adb',
      );
      if (File(adb).existsSync()) return adb;
    }
  }
  return 'adb';
}

/// One line of `adb devices` output: a serial and the state adb reports it in.
class AdbEntry {
  final String serial;

  /// Everything after the serial, verbatim. Not just the first word: adb
  /// reports states that contain spaces — `no permissions (missing udev
  /// rules?)` is one — and a message that quotes half of it is worse than no
  /// message, because the half it keeps (`no`) reads like a state of its own.
  final String state;

  AdbEntry(this.serial, this.state);

  /// The only state in which a device can be run against. `unauthorized`,
  /// `offline`, `recovery`, `sideload` and the `no permissions …` family all
  /// describe hardware that is present and unusable — a different situation
  /// from an empty bench, and the reason [AndroidProbeFailed] exists.
  bool get isUsable => state == 'device';

  @override
  String toString() => '$serial ($state)';
}

/// What asking the host which Android device to run against actually found.
///
/// Three outcomes, because there are three, and collapsing them is the defect
/// this type exists to prevent. `adb devices` returning an empty list is an
/// environmental fact about a machine with nothing plugged in, and skipping is
/// the right answer. `adb` failing to run, exiting non-zero, printing
/// something unrecognisable, or listing only devices in a state nothing can be
/// run against are all *tooling* failures — the detector is broken, or the
/// device needs attention — and reporting those as "no device attached" hides
/// a fixable problem behind an unfixable-looking one.
///
/// Collapsed into a nullable string, a missing `adb`, a broken `adb`, an
/// unauthorized phone and an empty bench all produce the same skip and the same
/// green run: a whole platform's worth of e2e coverage can stop running and
/// nothing says so.
sealed class AndroidDeviceProbe {
  const AndroidDeviceProbe();

  /// Ask [environment]'s host which device an Android e2e run should use.
  ///
  /// [adbPath] overrides the [resolveAdb] search; tests inject a stub through
  /// it, since `Platform.environment` cannot be mutated in-process and a
  /// developer's shell profile must not be able to change a unit test's
  /// verdict.
  static AndroidDeviceProbe detect({
    Map<String, String>? environment,
    String? adbPath,
  }) {
    final env = environment ?? Platform.environment;
    final adb = adbPath ?? resolveAdb(env);

    final ProcessResult result;
    try {
      result = Process.runSync(adb, ['devices']);
    } on Object catch (error) {
      // Deliberately caught rather than propagated: `main()` evaluates this at
      // load time to build a group's `skip:`, and a throw there takes down the
      // macOS, iOS and web groups declared in the same file. The error is
      // carried as data instead of discarded.
      return AndroidProbeFailed(
        'could not run `$adb devices`: $error\n'
        'Set \$ANDROID_HOME to an SDK whose platform-tools/adb runs, or put '
        'adb on PATH.',
      );
    }

    final stdout = result.stdout as String;
    if (result.exitCode != 0) {
      return AndroidProbeFailed(
        '`$adb devices` exited ${result.exitCode}.\n'
        'stdout: ${stdout.trim()}\n'
        'stderr: ${(result.stderr as String).trim()}',
      );
    }

    final lines = stdout.split('\n');
    // Anchored on adb's header rather than `skip(1)`, because adb interleaves
    // daemon chatter — `* daemon not running; starting now at tcp:5037 *` —
    // ahead of it. Splitting those lines on whitespace and reading the second
    // field yields a "device" whose serial is `*` and whose state is `daemon`,
    // which is how a machine with nothing attached would report a usable
    // device.
    final header = lines.indexWhere(
      (l) => l.trim() == 'List of devices attached',
    );
    if (header < 0) {
      return AndroidProbeFailed(
        '`$adb devices` printed no "List of devices attached" header, so its '
        'output cannot be read as a device list:\n${stdout.trim()}',
      );
    }

    final entries = <AdbEntry>[];
    for (final raw in lines.skip(header + 1)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final split = line.indexOf(RegExp(r'\s'));
      if (split < 0) {
        return AndroidProbeFailed(
          '`$adb devices` listed "$line", which carries no state and so '
          'cannot be read as a device entry:\n${stdout.trim()}',
        );
      }
      entries.add(
        AdbEntry(
          line.substring(0, split),
          line.substring(split).trim(),
        ),
      );
    }

    // An explicit $ANDROID_SERIAL is the user naming a device, which makes
    // every other attached device irrelevant and its own absence an error.
    // Silently running something else — or silently skipping — would be
    // ignoring an instruction that was given.
    final requested = env['ANDROID_SERIAL'];
    if (requested != null && requested.isNotEmpty) {
      AdbEntry? match;
      for (final entry in entries) {
        if (entry.serial == requested) {
          match = entry;
          break;
        }
      }
      if (match == null) {
        return AndroidProbeFailed(
          '\$ANDROID_SERIAL names $requested, which `$adb devices` does not '
          'list. Attached: ${entries.isEmpty ? '(none)' : entries.join(', ')}',
        );
      }
      if (!match.isUsable) {
        return AndroidProbeFailed(
          '\$ANDROID_SERIAL names $requested, which `$adb devices` reports as '
          '"${match.state}" rather than "device".',
        );
      }
      return AndroidDeviceFound(match.serial, adb);
    }

    for (final entry in entries) {
      if (entry.isUsable) return AndroidDeviceFound(entry.serial, adb);
    }

    if (entries.isEmpty) {
      return NoAndroidDevice(
        'no Android device attached — `$adb devices` listed none. Boot an '
        'emulator or USB-authorize a phone, then re-run.',
      );
    }
    // Present but unusable. Not an empty bench, and not something a re-run
    // fixes: `unauthorized` wants the RSA prompt accepted on the handset,
    // `offline` wants the cable reseated. Skipping over that is how a bench
    // that looks staffed reports itself as empty.
    return AndroidProbeFailed(
      '`$adb devices` listed ${entries.length} device(s), none in the "device" '
      'state: ${entries.join(', ')}.\n'
      'Accept the USB-debugging prompt on the handset (unauthorized), or '
      'reconnect it (offline).',
    );
  }

  /// Why the `Android e2e` group should be skipped, or null when it must run.
  ///
  /// Only [NoAndroidDevice] answers this. A failed probe deliberately does not
  /// skip: the group runs, and the test fails carrying [AndroidProbeFailed]'s
  /// explanation, because a broken detector reporting itself as an absent
  /// device is exactly what must not happen quietly.
  String? get skipReason => switch (this) {
    NoAndroidDevice(:final reason) => reason,
    _ => null,
  };
}

/// A device that can be run against, and the `adb` that found it.
final class AndroidDeviceFound extends AndroidDeviceProbe {
  final String serial;

  /// The `adb` that answered — not the one `$ANDROID_HOME` pointed at, which
  /// [resolveAdb] may have fallen through. Reported so a run says which SDK it
  /// actually used.
  final String adb;

  const AndroidDeviceFound(this.serial, this.adb);
}

/// `adb` ran, was understood, and listed nothing. The legitimate skip.
final class NoAndroidDevice extends AndroidDeviceProbe {
  final String reason;
  const NoAndroidDevice(this.reason);
}

/// `adb` could not be run, failed, could not be understood, or listed only
/// devices nothing can run on. A tooling failure, never a skip.
final class AndroidProbeFailed extends AndroidDeviceProbe {
  final String reason;
  const AndroidProbeFailed(this.reason);
}

/// A screenshot decoded far enough to say whether anything was drawn.
///
/// A byte-count threshold cannot answer this. PNG compresses each scanline
/// separately, so a 2400-row image pays for 2400 of them however empty they
/// are: a fully transparent 1080x2400 capture off an Android emulator is over
/// 10 KB, and any threshold big enough to reject it scales with the screen
/// alongside the frames it is meant to accept. An entirely transparent capture
/// has to fail, so the pixels are read instead.
///
/// Only the envelope every capture path here emits is supported — 8-bit,
/// non-interlaced, colour type 2 (RGB) or 6 (RGBA), which covers `adb
/// screencap`, the emulator console, `simctl io screenshot`, CDP and the
/// desktop helpers. Anything else throws naming what it found rather than being
/// waved through: a decoder that quietly handles half of what it is given is
/// the byte threshold again in a new costume.
class DecodedPng {
  final int width;
  final int height;

  /// Every distinct pixel in the image, capped — the predicate only needs to
  /// know whether there is more than one, so a full-screen capture does not
  /// have to build a set of two million entries.
  final Set<int> distinctPixels;

  DecodedPng._(this.width, this.height, this.distinctPixels);

  /// Whether anything was drawn: more than one distinct pixel value.
  ///
  /// "Blank" in these tests means uniform — a `MissingPluginException` white
  /// screen, an engine that never drew, an emulator capture that came back
  /// entirely transparent. A gradient or a solid background with one glyph on
  /// it is a render and passes, which is the right answer: it drew.
  bool get isUniform => distinctPixels.length < 2;
}

/// Decode enough of [bytes] to answer [DecodedPng.isUniform].
DecodedPng decodePngForBlankness(List<int> bytes) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length < 8 ||
      List.generate(8, (i) => bytes[i]).indexed.any(
        (e) => e.$2 != signature[e.$1],
      )) {
    throw StateError(
      'Not a PNG: the first bytes are '
      '${bytes.take(8).map((b) => '0x${b.toRadixString(16)}').join(' ')}.',
    );
  }
  final data = Uint8List.fromList(bytes);
  final view = ByteData.sublistView(data);

  int? width, height, bitDepth, colorType, interlace;
  final idat = BytesBuilder();
  var offset = 8;
  while (offset + 8 <= data.length) {
    final length = view.getUint32(offset);
    final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));
    final start = offset + 8;
    if (type == 'IHDR') {
      width = view.getUint32(start);
      height = view.getUint32(start + 4);
      bitDepth = data[start + 8];
      colorType = data[start + 9];
      interlace = data[start + 12];
    } else if (type == 'IDAT') {
      idat.add(data.sublist(start, start + length));
    } else if (type == 'IEND') {
      break;
    }
    offset = start + length + 4; // + CRC
  }
  if (width == null || height == null) {
    throw StateError('PNG has no IHDR chunk, so it has no dimensions.');
  }
  if (bitDepth != 8 || (colorType != 2 && colorType != 6) || interlace != 0) {
    throw StateError(
      'PNG is not one this decoder reads: bit depth $bitDepth, colour type '
      '$colorType, interlace $interlace. Only 8-bit non-interlaced RGB (2) '
      'or RGBA (6) — what every capture path in this repo emits — is '
      'handled, and guessing at the rest would make a wrong answer look '
      'like a real one.',
    );
  }

  final channels = colorType == 6 ? 4 : 3;
  final raw = Uint8List.fromList(ZLibDecoder().convert(idat.takeBytes()));
  final stride = width * channels;
  final distinct = <int>{};
  // The previous scanline, un-filtered — every filter but None refers to it.
  var previous = Uint8List(stride);
  var pos = 0;
  for (var row = 0; row < height; row++) {
    if (pos >= raw.length) {
      throw StateError(
        'PNG pixel data ended at row $row of $height — the image is '
        'truncated, so what it shows cannot be judged.',
      );
    }
    final filter = raw[pos++];
    final line = Uint8List(stride);
    for (var i = 0; i < stride; i++) {
      final x = pos + i < raw.length ? raw[pos + i] : 0;
      final a = i >= channels ? line[i - channels] : 0; // left
      final b = previous[i]; // above
      final c = i >= channels ? previous[i - channels] : 0; // above-left
      line[i] =
          switch (filter) {
            0 => x,
            1 => x + a,
            2 => x + b,
            3 => x + ((a + b) >> 1),
            4 => x + _paeth(a, b, c),
            _ => throw StateError(
              'PNG scanline $row uses filter $filter, which '
              'is not one of the five PNG defines.',
            ),
          } &
          0xff;
    }
    pos += stride;
    for (var i = 0; i + channels <= stride; i += channels) {
      // Pack the channels into one int so "distinct pixel" is one comparison.
      var pixel = 0;
      for (var c = 0; c < channels; c++) {
        pixel = (pixel << 8) | line[i + c];
      }
      distinct.add(pixel);
      // Two is the whole answer; there is no reason to walk a 2.6-megapixel
      // capture once it has been given.
      if (distinct.length > 1) {
        return DecodedPng._(width, height, distinct);
      }
    }
    previous = line;
  }
  return DecodedPng._(width, height, distinct);
}

/// PNG's Paeth predictor (RFC 2083 §6.6).
int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

/// Assert that [bytes] is a screenshot with something drawn in it.
///
/// The one place an e2e says "the UI rendered". [what] names the capture in
/// the failure, since these tests take several.
void expectRendered(List<int> bytes, {required String what}) {
  final png = decodePngForBlankness(bytes);
  if (png.isUniform) {
    throw TestFailure(
      '$what is blank: every one of its ${png.width}x${png.height} pixels is '
      'the same value (${png.distinctPixels.map((p) => '0x'
          '${p.toRadixString(16).padLeft(8, '0')}').join()}), so nothing was '
      'drawn.\n'
      'A plugin that failed to register, Native Assets that did not resolve, '
      'or a capture mechanism that cannot see this device\'s surface all end '
      'here. ${bytes.length} bytes of PNG is not evidence to the contrary — '
      'a transparent 1080x2400 frame is over 10 KB.',
    );
  }
}
