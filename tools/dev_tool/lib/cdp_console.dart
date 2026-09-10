/// Forwarding a web app's browser console over the Chrome DevTools Protocol.
///
/// A Flutter web app's `print()` goes to the browser console, not to Chrome's
/// process stdout, so the desktop approach of draining pipes finds nothing.
///
/// In DDC dev mode the dev tool already has a DWDS-backed VM service, and
/// `Stdout`/`Stderr` events on it carry the app's output — that path lives in
/// `run_command.dart` and is preferred, because it sees Dart's view of the
/// output. This file covers the case where there is no DWDS: WASM and plain
/// production JS builds, where CDP's `Runtime.consoleAPICalled` is the only
/// source available.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';

/// Choose the WebSocket debugger URL for the app's page from a CDP
/// `/json` target listing.
///
/// Only a `page` target on the same **origin** as [appUrl] qualifies — a
/// browser window always lists several targets (extension pages, service
/// workers, a fresh tab still on `about:blank`), and every CDP consumer here
/// drives *the app*: a console forwarded from the wrong target never says
/// anything, and a screenshot of it shows the wrong page while looking like a
/// healthy capture. There is no fallback: the app's page, or nothing.
///
/// The origin, not the whole URL, because these lookups are re-run for the
/// life of the session while the page's URL moves under them: a `--web-launch-url`
/// with a route on it, or a Flutter app that rewrites the URL as it navigates,
/// would stop matching mid-run and every later screenshot and reload would
/// fail. Nothing else this tool launches shares the dev server's origin.
///
/// Parsed rather than compared as a string prefix: `http://localhost:5234` is a
/// string prefix of `http://localhost:52341`, so a stale browser on a
/// neighbouring port could be picked.
///
/// Returns null when the page is not listed (yet) — at launch that means the
/// tab has not navigated and the caller should poll, see
/// [ChromeSession.resolveAppPage].
String? pickCdpPageTarget(List<dynamic> targets, {required String appUrl}) {
  final wanted = originOf(appUrl);
  if (wanted == null) return null;
  final page = targets.whereType<Map>().firstWhere(
    (t) => t['type'] == 'page' && originOf(t['url'] as String? ?? '') == wanted,
    orElse: () => const {},
  );
  return page['webSocketDebuggerUrl'] as String?;
}

/// The `scheme://host:port` of [url], or null when it has none.
///
/// `about:blank`, `chrome://…` and `devtools://…` all appear in a CDP target
/// listing and none of them has an origin; `Uri.origin` throws on each. Null
/// is the answer for "not a page on any origin", which is exactly what those
/// are.
String? originOf(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return uri.origin;
}

/// Fetch the CDP target listing from a browser's debugging port.
Future<List<dynamic>> fetchCdpTargets(int cdpPort) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:$cdpPort/json'),
    );
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return json.decode(body) as List<dynamic>;
  } finally {
    client.close();
  }
}

/// Ceiling on [resolveCdpPageTarget]'s backoff: the window it waits out is a
/// page target that is listed but not yet showing its URL, which is over in
/// well under a second, so the interval must not grow past the length of the
/// thing being waited for.
const maxCdpPollInterval = Duration(milliseconds: 500);

/// Resolve the app page's CDP WebSocket URL, or throw with a usable message.
///
/// Polled rather than sampled once, and this is the only place that poll
/// exists — every CDP consumer here (the console forwarder, the WASM page
/// reload, screenshots, and the launch's own readiness check via
/// [ChromeSession.resolveAppPage]) asks the same question and needs the same
/// patience for it.
///
/// The listing is not a settled fact at any instant. A page target exists from
/// launch, but its URL is not continuously the app's: cross-origin isolation
/// forces a browsing-context-group swap, and for a moment the app's own page
/// is listed with an empty URL. One sample lands inside that window often
/// enough to fail a run, and no amount of machine quiet closes the window — it
/// only narrows it.
///
/// Only "the page is not listed yet" is retried. A failure to reach the
/// listing at all propagates on the first attempt: a browser that has exited
/// refuses the connection, and that is a different fact from a page that has
/// not appeared yet — retrying it would spend the whole timeout dialling a
/// port nothing is listening to and then report the wrong cause.
///
/// [appUrl] is typed nullable only because callers hold it in nullable
/// fields populated at launch; passing null is a caller bug and throws
/// immediately rather than degrading into driving an arbitrary page.
Future<String> resolveCdpPageTarget(
  int cdpPort, {
  String? appUrl,
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 50),
}) async {
  if (appUrl == null) {
    throw ArgumentError.notNull('appUrl');
  }
  final stopwatch = Stopwatch()..start();
  var delay = pollInterval;
  while (true) {
    final targets = await fetchCdpTargets(cdpPort);
    final ws = pickCdpPageTarget(targets, appUrl: appUrl);
    if (ws != null) return ws;
    if (stopwatch.elapsed >= timeout) {
      throw StateError(
        'No debuggable CDP page target for $appUrl on port $cdpPort within '
        '${timeout.inMilliseconds}ms. '
        'Targets listed: ${describeCdpTargets(targets)}.',
      );
    }
    await Future<void>.delayed(delay);
    final doubled = delay * 2;
    delay = doubled > maxCdpPollInterval ? maxCdpPollInterval : doubled;
  }
}

/// One-line summary of a `/json` listing, for error messages: what was there
/// when the app's page was not is the fact someone will debug from.
String describeCdpTargets(List<dynamic> targets) => targets.isEmpty
    ? 'none'
    : targets
          .whereType<Map>()
          .map((t) => '${t['type']}:${t['url']}')
          .join(', ');

/// Render one CDP `RemoteObject` argument the way a console would show it.
String _renderArg(Map arg) {
  if (arg.containsKey('value')) return '${arg['value']}';
  final description = arg['description'];
  if (description is String) return description;
  return arg['type'] as String? ?? '';
}

/// CDP console message types that belong on an error channel.
const _errorConsoleTypes = {'error', 'warning', 'assert'};

/// Translate a single CDP notification into [logs] lines.
///
/// Handles `Runtime.consoleAPICalled` (every `console.*` call, which is where
/// a Dart web `print()` lands) and `Runtime.exceptionThrown` (uncaught
/// errors). Anything else — command responses, other domains' events — is
/// ignored. Malformed payloads are dropped rather than thrown: a console
/// forwarder must never be able to take down the run it is reporting on.
///
/// Exposed for testing.
void handleCdpConsoleMessage(Map<String, dynamic> message, AppLogStream logs) {
  void addLines(String text, {required bool isError}) {
    if (text.isEmpty) return;
    for (final line in const LineSplitter().convert(text)) {
      logs.add(line, isError: isError);
    }
  }

  try {
    switch (message['method']) {
      case 'Runtime.consoleAPICalled':
        final params = message['params'] as Map?;
        final args = params?['args'];
        if (args is! List || args.isEmpty) return;
        final type = params?['type'] as String? ?? 'log';
        final text = args.whereType<Map>().map(_renderArg).join(' ');
        addLines(text, isError: _errorConsoleTypes.contains(type));

      case 'Runtime.exceptionThrown':
        final details =
            (message['params'] as Map?)?['exceptionDetails'] as Map?;
        if (details == null) return;
        final description =
            (details['exception'] as Map?)?['description'] as String?;
        addLines(
          description ?? details['text'] as String? ?? '',
          isError: true,
        );
    }
  } catch (_) {
    // A console line is never worth failing a run over.
  }
}

/// Open the socket for the app page's CDP endpoint.
///
/// [resolveTimeout] is how long one attempt waits for the page to be listed.
/// It is deliberately far shorter than [resolveCdpPageTarget]'s own default:
/// this caller is [CdpConsoleClient], which already retries on its own
/// schedule and counts its give-up budget in scheduled delay alone. An attempt
/// that could itself wait the full default would push the real give-up out to
/// several times the budget the warning names. Waiting out a context-group swap
/// is all one attempt here has to do; the rest is the reconnect loop's job.
Future<WebSocket> _openPageSocket(
  int cdpPort,
  String? appUrl, {
  required Duration resolveTimeout,
}) async => WebSocket.connect(
  await resolveCdpPageTarget(cdpPort, appUrl: appUrl, timeout: resolveTimeout),
);

/// Streams a page's console output into an [AppLogStream] over CDP.
///
/// Reconnects when the page goes away: a web hot restart is a CDP page reload,
/// which drops the target and would otherwise silently end console forwarding
/// for the rest of the session. The other reason a target disappears is that
/// the browser is gone for good, which no amount of retrying fixes, so the
/// reconnect backs off and eventually gives up out loud.
class CdpConsoleClient {
  final int cdpPort;
  final String? appUrl;
  final AppLogStream logs;

  /// How long to wait before re-resolving a target after the socket drops.
  /// Each further attempt in the same outage waits twice as long.
  final Duration reconnectDelay;

  /// Ceiling on the backoff: everything the page prints before the client is
  /// back is output nobody sees, so a reload must not end up behind a long
  /// wait.
  final Duration maxReconnectDelay;

  /// How much waiting one outage gets before the client stops trying.
  final Duration reconnectBudget;

  /// How long a single attach waits for the app's page to be listed, before
  /// the outage's own backoff takes over again — see [_openPageSocket].
  final Duration resolveTimeout;

  /// Opens the CDP socket. Injectable so tests can drive the reconnect loop
  /// without a browser.
  final Future<WebSocket> Function(int cdpPort, String? appUrl) _open;

  /// Starts the timer for the next attempt. Injectable so tests can read the
  /// backoff off the schedule instead of waiting through it.
  final Timer Function(Duration delay, void Function() callback) _schedule;

  /// Where the give-up warning goes.
  final void Function(String message) _warn;

  WebSocket? _socket;
  Timer? _reconnect;
  bool _closed = false;
  int _nextId = 1;

  /// Backoff state for the current outage, reset once a socket is live again
  /// so that a session's tenth hot restart gets the same budget as its first.
  Duration _nextDelay;
  Duration _waited = Duration.zero;
  Object? _lastError;

  CdpConsoleClient({
    required this.cdpPort,
    required this.logs,
    this.appUrl,
    this.reconnectDelay = const Duration(milliseconds: 500),
    this.maxReconnectDelay = const Duration(seconds: 2),
    this.reconnectBudget = const Duration(seconds: 15),
    this.resolveTimeout = const Duration(seconds: 1),
    Future<WebSocket> Function(int cdpPort, String? appUrl)? openSocket,
    Timer Function(Duration delay, void Function() callback)? scheduleTimer,
    void Function(String message)? warn,
  }) : _nextDelay = reconnectDelay,
       _open =
           openSocket ??
           ((int port, String? url) =>
               _openPageSocket(port, url, resolveTimeout: resolveTimeout)),
       _schedule = scheduleTimer ?? Timer.new,
       _warn = warn ?? ((String message) => stderr.writeln(message));

  /// Connect and begin forwarding. Returns once the first connection is
  /// established; later reconnections happen in the background.
  Future<void> start() async {
    await _connect();
  }

  Future<void> _connect() async {
    if (_closed) return;
    final socket = await _open(cdpPort, appUrl);
    if (_closed) {
      await socket.close();
      return;
    }
    _socket = socket;
    _nextDelay = reconnectDelay;
    _waited = Duration.zero;
    _lastError = null;

    socket.listen(
      (data) {
        if (data is! String) return;
        try {
          handleCdpConsoleMessage(
            json.decode(data) as Map<String, dynamic>,
            logs,
          );
        } on FormatException {
          // Not JSON; nothing to forward.
        }
      },
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
      cancelOnError: true,
    );

    // Runtime.enable starts consoleAPICalled/exceptionThrown notifications.
    socket.add(json.encode({'id': _nextId++, 'method': 'Runtime.enable'}));
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _socket = null;
    if (_waited >= reconnectBudget) {
      _giveUp();
      return;
    }
    final delay = _nextDelay;
    _waited += delay;
    final doubled = delay * 2;
    _nextDelay = doubled > maxReconnectDelay ? maxReconnectDelay : doubled;
    // Held so [close] can cancel it: a pending timer keeps the isolate alive
    // until it fires, and a reconnect racing teardown would reopen a socket
    // nobody is going to close.
    _reconnect = _schedule(delay, () async {
      if (_closed) return;
      try {
        await _connect();
      } catch (e) {
        // The page may still be reloading; try again, further out each time.
        _lastError = e;
        _scheduleReconnect();
      }
    });
  }

  /// Stop reconnecting, and say so: a console that quietly stops forwarding is
  /// indistinguishable from an app that stopped printing.
  void _giveUp() {
    _reconnect = null;
    _warn(
      'Warning: browser console forwarding stopped — no CDP page target '
      'came back on port $cdpPort within ${reconnectBudget.inSeconds}s'
      '${_lastError == null ? '' : ' ($_lastError)'}. The browser has '
      'probably exited; app output will not appear for the rest of this '
      'run.',
    );
  }

  /// Stop forwarding and close the socket. Idempotent.
  Future<void> close() async {
    _closed = true;
    _reconnect?.cancel();
    _reconnect = null;
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }
}
