/// HTTP control channel for the dev tool.
///
/// Runs an HTTP server on the loopback with an auto-assigned port. All
/// endpoints require a `?token=<token>` query parameter for auth. This allows
/// external tools (like Claude Code) to send commands from isolated shell
/// sessions via simple `curl` POSTs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http_multi_server/http_multi_server.dart';

import 'command_failure.dart';
import 'command_runner.dart';
import 'machine_protocol.dart';
import 'session.dart';

/// HTTP server that exposes the dev tool's command dispatch and screenshot
/// endpoints to external clients.
class HttpControlChannel {
  final CommandRunner _commandRunner;
  final DeviceSession? Function(String appId) _findSession;
  final String _token;
  HttpServer? _server;
  int _inFlight = 0;
  Completer<void>? _drained;

  /// Distinguishes screenshot temp files taken within the same millisecond,
  /// which concurrent requests otherwise name identically.
  int _screenshotSeq = 0;

  HttpControlChannel({
    required CommandRunner commandRunner,
    required DeviceSession? Function(String appId) findSession,
    String? token,
  }) : _commandRunner = commandRunner,
       _findSession = findSession,
       _token = token ?? _generateToken();

  static String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// The auth token required for all requests.
  String get token => _token;

  /// The bound server URI (available after [start]).
  ///
  /// `localhost` rather than a literal address, so this names whichever
  /// loopback families [start] found on the host instead of one chosen here.
  Uri get uri {
    final server = _server;
    if (server == null) throw StateError('Server not started');
    return Uri(scheme: 'http', host: 'localhost', port: server.port);
  }

  /// Start the HTTP server on every loopback address this host has, with an
  /// auto-assigned port.
  ///
  /// Binding `::1` outright fails on a host with no IPv6 address to assign
  /// (EADDRNOTAVAIL), and with the channel goes the whole agent surface: every
  /// `app.*` command, every screenshot, every log poll.
  ///
  /// So the families are measured rather than named, through the package the
  /// Dart ecosystem's servers use for it and that the web dev server already
  /// binds through. It takes both loopbacks where the host has both, and the
  /// one it has where it has one.
  ///
  /// Both, and not just whichever one the host prefers, because [uri]
  /// publishes a *name*: a client resolving `localhost` picks a family itself,
  /// so a channel on one of them is reachable by half its own URL, and the
  /// other half reaches whatever else holds that port number — `adb` keeps
  /// dozens of listening sockets on 127.0.0.1 in the ephemeral range and
  /// answers a connection by closing it without a byte.
  ///
  /// Nothing checks afterwards that this server is the one the URL reaches,
  /// unlike the `--web-hostname any` path in `web_module_server.dart`. That
  /// check is there because a *wildcard* bind can succeed on a port another
  /// process already holds on a specific address. These are specific-address
  /// binds, which the kernel refuses outright when the port is held, and a
  /// check no test can make fail is not a check.
  Future<void> start() async {
    _server = await HttpMultiServer.loopback(0);
    _server!.listen(_handleRequest);
  }

  /// Stop the HTTP server.
  ///
  /// Refuses new connections immediately, then waits for in-flight request
  /// handlers to finish writing their responses. An `app.stop` command tears
  /// the session down and this channel is closed on the way out of the run —
  /// while the request that triggered it is still awaiting its response. A
  /// force-close here would sever that connection mid-response.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    if (server == null) return;
    // force: false stops the listener and closes idle connections but lets
    // active ones complete.
    await server.close();
    if (_inFlight > 0) {
      _drained ??= Completer<void>();
      await _drained!.future;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _inFlight++;
    try {
      await _dispatchRequest(request);
    } finally {
      _inFlight--;
      if (_inFlight == 0 && _drained != null && !_drained!.isCompleted) {
        _drained!.complete();
      }
    }
  }

  Future<void> _dispatchRequest(HttpRequest request) async {
    // Reject HTTP upgrade attempts (e.g. HTTP/2 cleartext "h2c"). Dart's
    // HttpServer is HTTP/1.1 only and, when an `Upgrade` header is present,
    // silently discards the request body — which turns a POST /command into a
    // mysterious hang/empty-reply. Fail loudly and early with guidance instead.
    final upgrade = request.headers.value(HttpHeaders.upgradeHeader);
    if (upgrade != null) {
      request.response.statusCode = HttpStatus.upgradeRequired;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        json.encode({
          'error':
              'HTTP upgrade ($upgrade) is not supported; this endpoint is '
              'HTTP/1.1 only. Retry with plain HTTP/1.1 (curl: --http1.1).',
        }),
      );
      await request.response.close();
      return;
    }

    // Auth check.
    //
    // The refusal names where the token is read from. A field called `token`
    // reads as a bearer credential, so the first thing a caller tries is an
    // `Authorization` header — and a bare "invalid or missing" then looks like
    // the value is wrong rather than in the wrong place, which is a round trip
    // spent on the wrong question.
    final requestToken = request.uri.queryParameters['token'];
    if (requestToken != _token) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        json.encode({
          'error':
              'Invalid or missing token. This channel reads the token from '
              'the `token` query parameter (…?token=<token>), not from a '
              'header. The run\'s `http_control_channel` log record carries '
              'the value, and a ready-made URL for each endpoint.',
        }),
      );
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    try {
      if (request.method == 'POST' && path == '/command') {
        await _handleCommand(request);
      } else if (request.method == 'GET' && path == '/commands') {
        await _handleCommands(request);
      } else if (request.method == 'GET' &&
          _sessionScreenshotMatch(path) != null) {
        final match = _sessionScreenshotMatch(path)!;
        if (match.type == 'flutter') {
          await _handleFlutterScreenshot(request, match.appId);
        } else {
          await _handleNativeScreenshot(request, match.appId);
        }
      } else if (request.method == 'GET' && _sessionLogsMatch(path) != null) {
        await _handleLogs(request, _sessionLogsMatch(path)!);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.headers.contentType = ContentType.json;
        request.response.write(json.encode({'error': 'Not found'}));
        await request.response.close();
      }
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': e.toString()}));
      await request.response.close();
    }
  }

  /// `GET /commands` — what this run can be asked to do, right now.
  ///
  /// The HTTP counterpart of `daemon.connected`'s `commands` field and the
  /// `daemon.commandsChanged` event, which a client on this channel cannot
  /// receive: there is nothing pushed here, by design — see the `/logs`
  /// cursor rather than a stream.
  ///
  /// Re-read rather than cached by the caller, because the surface grows
  /// through a run: the agent commands appear once the VM service is up,
  /// which on web and on an iOS device is well after `app.started`, and
  /// `app.setViewport` appears only once a browser is launched.
  Future<void> _handleCommands(HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      json.encode({
        'protocolVersion': MachineProtocol.protocolVersion,
        'commands': _commandRunner.describe(),
      }),
    );
    await request.response.close();
  }

  Future<void> _handleCommand(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    Map<String, dynamic> parsed;
    try {
      parsed = json.decode(body) as Map<String, dynamic>;
    } catch (e) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': 'Invalid JSON: $e'}));
      await request.response.close();
      return;
    }

    final method = parsed['method'] as String?;
    if (method == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': 'Missing "method" field'}));
      await request.response.close();
      return;
    }

    final params = (parsed['params'] as Map<String, dynamic>?) ?? {};

    try {
      final result = await _commandRunner.run(method, params);
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'result': result}));
    } on CommandFailure catch (e) {
      // One shape for every no: a status that says what kind, and the reason
      // where every other error on this channel puts it.
      request.response.statusCode = _statusFor(e.kind);
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': e.message}));
    } catch (e) {
      // Not a refusal — the tool broke. 500 is the honest answer, and the
      // exception's own text is all there is to say.
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': e.toString()}));
    }
    await request.response.close();
  }

  /// How a refusal reads over HTTP.
  ///
  /// `failed` is 422 rather than 500: the request was well formed and the tool
  /// is fine — the app said no, or never answered. A 500 there would tell a
  /// client to retry against a tool that is working exactly as it should.
  static int _statusFor(CommandFailureKind kind) => switch (kind) {
    CommandFailureKind.notFound => HttpStatus.notFound,
    CommandFailureKind.badRequest => HttpStatus.badRequest,
    CommandFailureKind.unavailable => HttpStatus.notImplemented,
    CommandFailureKind.failed => HttpStatus.unprocessableEntity,
  };

  Future<void> _handleFlutterScreenshot(
    HttpRequest request,
    String appId,
  ) async {
    final session = _findSession(appId);
    if (session == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': 'Unknown appId: $appId'}));
      await request.response.close();
      return;
    }

    final native = '/sessions/${Uri.encodeComponent(appId)}/screenshot/native';

    // Refuse up front where the capture can never work, rather than passing
    // an engine error back as a 500 that reads as transient. `_flutter.
    // screenshot` cannot encode under Impeller — every iOS run — and has no
    // web implementation at all.
    if (!session.device.supportsFlutterScreenshot) {
      request.response.statusCode = HttpStatus.notImplemented;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        json.encode({
          'error':
              '_flutter.screenshot cannot capture on ${session.device.name} '
              '(the renderer there cannot encode a compressed screenshot); this '
              'will not succeed on a retry. Use GET $native, which captures the '
              'same app through the platform.',
        }),
      );
      await request.response.close();
      return;
    }

    if (session.vmClient == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        json.encode({'error': 'No VM service for $appId'}),
      );
      await request.response.close();
      return;
    }

    // The engine capture is a moment too, and the same argument applies: an
    // agent that acts and then captures wants the frame that includes the
    // action. See [_settleBeforeCapture].
    final settle = await _settleBeforeCapture(session, request);

    final List<int> bytes;
    try {
      bytes = await session.vmClient!.screenshotBytes();
    } catch (e) {
      // A device we believe can do this still failed. The overwhelmingly
      // common cause is an app rendering with Impeller, so say so and name
      // the endpoint that works instead of leaving the engine's bare
      // "Could not capture image screenshot" to be read as a retryable fault.
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        json.encode({
          'error':
              '$e (an app rendering with Impeller cannot produce a '
              'compressed screenshot; GET $native captures it through the '
              'platform instead)',
        }),
      );
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('image', 'png');
    _reportSettle(request, settle);
    request.response.add(bytes);
    await request.response.close();
  }

  /// Wait for [session]'s app to go idle before a capture, and say what
  /// happened in headers the picture itself cannot carry.
  ///
  /// A capture is a moment, and the moment a caller wants is the one *after*
  /// the command they just sent has painted. Without the wait, a screenshot
  /// taken straight after an `app.tap` shows the frame from before it — a stale
  /// picture that reads exactly like a feature that did not work.
  ///
  /// Never fatal. An app that cannot settle is the one whose picture is most
  /// worth having, so the capture goes ahead and the answer says so:
  /// `X-Settled: yes` when it went idle first, `no` when the wait ran out or
  /// the app is backgrounded, `skipped` when `?settle=false` was asked for or
  /// this run has no VM service to ask through (`--wasm`, `--profile`).
  /// `X-Settle-Detail` carries the reason for anything but `yes`.
  Future<({String state, String? detail})> _settleBeforeCapture(
    DeviceSession session,
    HttpRequest request,
  ) async {
    final raw = request.uri.queryParameters['settle'];
    if (raw != null && raw != 'true' && raw != 'false') {
      return (
        state: 'skipped',
        detail: 'settle must be "true" or "false", not "$raw"; not waiting',
      );
    }
    if (raw == 'false') {
      return (state: 'skipped', detail: 'the caller asked not to wait');
    }
    if (session.vmClient == null) {
      return (
        state: 'skipped',
        detail:
            'this run has no VM service, so the app cannot be asked whether '
            'it is idle',
      );
    }
    try {
      final json = await _commandRunner.run('app.settle', {
        'appId': session.appId,
      });
      if (json['settled'] == true) return (state: 'yes', detail: null);
      return (state: 'no', detail: json['reason']?.toString());
    } on CommandFailure catch (e) {
      return (state: 'no', detail: e.message);
    }
  }

  /// Apply what [_settleBeforeCapture] found to the response.
  ///
  /// Set before the body: headers cannot be written once bytes have gone out.
  void _reportSettle(
    HttpRequest request,
    ({String state, String? detail}) settle,
  ) {
    request.response.headers.set('X-Settled', settle.state);
    if (settle.detail case final detail?) {
      request.response.headers.set('X-Settle-Detail', detail);
    }
  }

  Future<void> _handleNativeScreenshot(
    HttpRequest request,
    String appId,
  ) async {
    final session = _findSession(appId);
    if (session == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': 'Unknown appId: $appId'}));
      await request.response.close();
      return;
    }

    // `?window=<title>` narrows the capture to a single window on devices
    // that support multi-window selection (currently macOS, exact title
    // match). Devices that ignore it composite or capture however they do
    // by default.
    final window = request.uri.queryParameters['window'];

    final settle = await _settleBeforeCapture(session, request);

    final tmpFile = File(
      '${Directory.systemTemp.path}/'
      'flutter_bazel_screenshot_${DateTime.now().millisecondsSinceEpoch}'
      '_${_screenshotSeq++}.png',
    );
    try {
      // Pass vmClient: null to force the platform-native capture path
      // (bundled macOS helper, adb screencap, etc.) instead of
      // _flutter.screenshot.
      await session.device.screenshot(
        session.appInstance,
        tmpFile.path,
        window: window,
      );
      final bytes = await tmpFile.readAsBytes();
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType('image', 'png');
      _reportSettle(request, settle);
      request.response.add(bytes);
      await request.response.close();
    } finally {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
    }
  }

  /// Default page size for `/logs`, and the cap on a caller-supplied `limit`
  /// beyond [AppLogStream]'s own.
  static const _defaultLogLimit = 500;

  /// How much a caller with no cursor gets: the tail, because "show me what
  /// the app just printed" is the question an agent or a human almost always
  /// arrives with.
  static const _defaultLogTail = -200;

  /// `GET /sessions/{appId}/logs?since=<cursor>&limit=<n>`.
  ///
  /// Cursor polling rather than a streaming response: a caller reads only what
  /// it asks for, and there is no long-lived connection to manage on either
  /// end. See the README for the full contract.
  Future<void> _handleLogs(HttpRequest request, String appId) async {
    Future<void> fail(int status, String error) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(json.encode({'error': error}));
      await request.response.close();
    }

    final session = _findSession(appId);
    if (session == null) {
      return fail(HttpStatus.notFound, 'Unknown appId: $appId');
    }

    final params = request.uri.queryParameters;

    // A malformed cursor is an error, not a reason to quietly serve the
    // default: a caller polling with a typo'd cursor would otherwise re-read
    // the tail forever and never notice.
    final sinceRaw = params['since'];
    final int since;
    if (sinceRaw == null) {
      since = _defaultLogTail;
    } else {
      final parsed = int.tryParse(sinceRaw);
      if (parsed == null) {
        return fail(
          HttpStatus.badRequest,
          'Invalid `since`: "$sinceRaw" is not an integer. Use a cursor '
          'from a previous `nextCursor`, 0 for the start of the buffer, or '
          'a negative number to tail that many lines.',
        );
      }
      since = parsed;
    }

    final limitRaw = params['limit'];
    final int limit;
    if (limitRaw == null) {
      limit = _defaultLogLimit;
    } else {
      final parsed = int.tryParse(limitRaw);
      if (parsed == null || parsed <= 0) {
        return fail(
          HttpStatus.badRequest,
          'Invalid `limit`: "$limitRaw" is not a positive integer.',
        );
      }
      limit = parsed > _defaultLogLimit ? _defaultLogLimit : parsed;
    }

    final logs = session.appInstance.logs;
    final page = logs.read(since, limit: limit);

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      json.encode({
        // Whole words: an abbreviated `{i, t, err}` would make a reader learn
        // three abbreviations, one of which (`err`) names the same thing
        // `app.log` calls `error`.
        'lines': [
          for (final line in page.lines)
            {
              'index': line.index,
              'text': line.text,
              'error': line.isError,
            },
        ],
        'nextCursor': page.nextCursor,
        // Which launch of this app the page came from: 1 for the original, one
        // more for each relaunch (a restart whose native libraries changed
        // replaces the process). Every launch buffers its own output from zero,
        // so a cursor is only meaningful within one launch — a poller that sees
        // this change must drop its cursor and re-tail.
        'launch': session.launch,
        // Lines lost between the requested cursor and this page…
        'missed': page.missed,
        // …versus lines evicted over the whole run.
        'dropped': logs.dropped,
        // True once the app's output source has ended — no more lines will ever
        // arrive, so a poller can stop.
        'closed': logs.isClosed,
      }),
    );
    await request.response.close();
  }

  /// Parse `/sessions/{appId}/screenshot/{type}` from a path.
  _ScreenshotMatch? _sessionScreenshotMatch(String path) {
    final match = RegExp(
      r'^/sessions/([^/]+)/screenshot/(flutter|native)$',
    ).firstMatch(path);
    if (match == null) return null;
    return _ScreenshotMatch(
      appId: Uri.decodeComponent(match.group(1)!),
      type: match.group(2)!,
    );
  }

  /// Parse `/sessions/{appId}/logs` from a path, returning the appId.
  String? _sessionLogsMatch(String path) {
    final match = RegExp(r'^/sessions/([^/]+)/logs$').firstMatch(path);
    if (match == null) return null;
    return Uri.decodeComponent(match.group(1)!);
  }
}

class _ScreenshotMatch {
  final String appId;
  final String type;
  _ScreenshotMatch({required this.appId, required this.type});
}
