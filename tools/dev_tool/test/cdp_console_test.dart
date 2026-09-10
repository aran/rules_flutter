import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/app_log.dart';
import 'package:flutter_bazel_dev_tool/cdp_console.dart';
import 'package:test/test.dart';

/// A local WebSocket server standing in for the browser's CDP endpoint, so a
/// test can hand the client a live connection and then take it away.
class _FakeCdpEndpoint {
  final HttpServer _server;
  final _connections = <Completer<WebSocket>>[];
  final _accepted = <WebSocket>[];

  _FakeCdpEndpoint._(this._server) {
    var next = 0;
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      _accepted.add(socket);
      _slot(next++).complete(socket);
    });
  }

  static Future<_FakeCdpEndpoint> start() async =>
      _FakeCdpEndpoint._(await HttpServer.bind('127.0.0.1', 0));

  Completer<WebSocket> _slot(int index) {
    while (_connections.length <= index) {
      _connections.add(Completer<WebSocket>());
    }
    return _connections[index];
  }

  Future<WebSocket> connect() =>
      WebSocket.connect('ws://127.0.0.1:${_server.port}');

  /// Completes once the client has finished attaching to connection [index]:
  /// `Runtime.enable` is the first thing it sends.
  Future<void> attached(int index) async {
    await (await _slot(index).future).first;
  }

  /// Close the browser side, the way a page reload or a closed window does.
  Future<void> drop(int index) async => (await _slot(index).future).close();

  /// An upgraded socket is detached from its server, so closing the server is
  /// not enough: a still-open one keeps the test binary's event loop alive.
  Future<void> stop() async {
    await _server.close(force: true);
    for (final socket in _accepted) {
      await socket.close();
    }
  }
}

/// A `Runtime.consoleAPICalled` notification as Chrome sends it.
Map<String, dynamic> consoleEvent(
  String type,
  List<Map<String, dynamic>> args,
) => {
  'method': 'Runtime.consoleAPICalled',
  'params': {'type': type, 'args': args},
};

Map<String, dynamic> stringArg(String v) => {'type': 'string', 'value': v};

void main() {
  group('pickCdpPageTarget', () {
    final targets = [
      {
        'type': 'background_page',
        'url': 'chrome-extension://x/bg.html',
        'webSocketDebuggerUrl': 'ws://bg',
      },
      {
        'type': 'page',
        'url': 'about:blank',
        'webSocketDebuggerUrl': 'ws://blank',
      },
      {
        'type': 'page',
        'url': 'http://localhost:8080/index.html',
        'webSocketDebuggerUrl': 'ws://app',
      },
    ];

    test('picks the one page whose URL is the app among several targets', () {
      expect(
        pickCdpPageTarget(targets, appUrl: 'http://localhost:8080'),
        'ws://app',
      );
    });

    test('returns null while the only page is an about:blank that has not '
        'navigated', () {
      final notYetNavigated = [
        {
          'type': 'page',
          'url': 'about:blank',
          'webSocketDebuggerUrl': 'ws://blank',
        },
      ];
      expect(
        pickCdpPageTarget(notYetNavigated, appUrl: 'http://localhost:8080'),
        isNull,
      );
    });

    test('never picks an extension page, even when it is all there is', () {
      final onlyExtension = [
        {
          'type': 'background_page',
          'url': 'chrome-extension://x/bg.html',
          'webSocketDebuggerUrl': 'ws://bg',
        },
      ];
      expect(
        pickCdpPageTarget(onlyExtension, appUrl: 'http://localhost:8080'),
        isNull,
      );
    });

    test('never picks a non-page target whose URL happens to match', () {
      final serviceWorker = [
        {
          'type': 'service_worker',
          'url': 'http://localhost:8080/flutter_service_worker.js',
          'webSocketDebuggerUrl': 'ws://sw',
        },
      ];
      expect(
        pickCdpPageTarget(serviceWorker, appUrl: 'http://localhost:8080'),
        isNull,
      );
    });

    test('picks the first listed page when more than one serves the app', () {
      // A fresh-profile launch owns exactly one tab, so two matches only
      // happen if something outside the run opened a second one; the
      // browser lists its own tab first.
      final twoMatches = [
        {
          'type': 'page',
          'url': 'http://localhost:8080/index.html',
          'webSocketDebuggerUrl': 'ws://first',
        },
        {
          'type': 'page',
          'url': 'http://localhost:8080/other.html',
          'webSocketDebuggerUrl': 'ws://second',
        },
      ];
      expect(
        pickCdpPageTarget(twoMatches, appUrl: 'http://localhost:8080'),
        'ws://first',
      );
    });

    test('returns null when there are no targets at all', () {
      expect(
        pickCdpPageTarget(const [], appUrl: 'http://localhost:8080'),
        isNull,
      );
    });

    test('returns null when the app page exposes no debugger URL', () {
      expect(
        pickCdpPageTarget([
          {'type': 'page', 'url': 'http://localhost:8080/index.html'},
        ], appUrl: 'http://localhost:8080'),
        isNull,
      );
    });

    test('never picks a page on a port that merely starts the same', () {
      // `http://localhost:5234` is a string prefix of
      // `http://localhost:52341`, so a prefix check would drive a stale
      // browser on a neighbouring port instead of this run's.
      expect(
        pickCdpPageTarget([
          {
            'type': 'page',
            'url': 'http://localhost:52341/index.html',
            'webSocketDebuggerUrl': 'ws://neighbour',
          },
        ], appUrl: 'http://localhost:5234'),
        isNull,
      );
    });

    test('matches the app page however the app has routed since', () {
      // These lookups are re-run for the life of the session, and the page's
      // URL moves under them: a `--web-launch-url` with a route, or an app
      // that rewrites the URL as it navigates. Matching on origin is what
      // keeps a screenshot an hour in from silently failing.
      const routed = [
        {
          'type': 'page',
          'url': 'http://localhost:8080/#/settings?q=1',
          'webSocketDebuggerUrl': 'ws://app',
        },
      ];
      expect(
        pickCdpPageTarget(routed, appUrl: 'http://localhost:8080'),
        'ws://app',
      );
      expect(
        pickCdpPageTarget(routed, appUrl: 'http://localhost:8080/#/home'),
        'ws://app',
      );
    });

    test('an app URL with no origin matches nothing', () {
      // A caller bug rather than a state to guess at: driving "some page"
      // is what the whole picker exists to refuse.
      expect(
        pickCdpPageTarget([
          {
            'type': 'page',
            'url': 'http://localhost:8080/index.html',
            'webSocketDebuggerUrl': 'ws://app',
          },
        ], appUrl: 'about:blank'),
        isNull,
      );
    });
  });

  group('originOf', () {
    test('answers for the URLs a page really has', () {
      expect(
        originOf('http://localhost:8080/index.html'),
        'http://localhost:8080',
      );
      expect(originOf('https://example.com/a/b?c=1#d'), 'https://example.com');
      // The port is part of it, so two ports are two origins.
      expect(
        originOf('http://localhost:8080/'),
        isNot(originOf('http://localhost:8081/')),
      );
    });

    test('is null for everything in a target listing that has no origin', () {
      // `Uri.origin` throws on each of these, and they are all really listed:
      // an unnavigated tab, a browser page, a DevTools window, an extension.
      for (final url in [
        'about:blank',
        'chrome://newtab/',
        'devtools://devtools/bundled/x.html',
        'chrome-extension://x/bg.html',
        '',
      ]) {
        expect(originOf(url), isNull, reason: url);
      }
    });
  });

  group('resolveCdpPageTarget', () {
    const appUrl = 'http://localhost:8080';

    /// A CDP `/json` endpoint whose listing is scripted per request, so a test
    /// can play out the states a real browser passes through.
    Future<HttpServer> serveCdpJson(
      List<dynamic> Function(int call) listing,
    ) async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      var calls = 0;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(json.encode(listing(calls++)));
        await request.response.close();
      });
      return server;
    }

    const blankPage = {
      'type': 'page',
      'url': 'about:blank',
      'webSocketDebuggerUrl': 'ws://blank',
    };

    const extensionPage = {
      'type': 'background_page',
      'url': 'chrome-extension://x/bg.html',
      'webSocketDebuggerUrl': 'ws://bg',
    };

    test('waits out a page target that is listed with no URL yet', () async {
      // A cross-origin-isolated app forces a browsing-context-group swap, and
      // for a moment the app's own page is listed with an empty URL. Sampling
      // once catches that about half the time.
      final cdp = await serveCdpJson(
        (call) => call == 0
            ? [
                {
                  'type': 'page',
                  'url': '',
                  'webSocketDebuggerUrl': 'ws://mid-swap',
                },
              ]
            : [
                {
                  'type': 'page',
                  'url': '$appUrl/index.html',
                  'webSocketDebuggerUrl': 'ws://app',
                },
              ],
      );

      expect(
        await resolveCdpPageTarget(
          cdp.port,
          appUrl: appUrl,
          pollInterval: const Duration(milliseconds: 5),
        ),
        'ws://app',
        reason:
            'the empty-URL sample must be waited through, and the page '
            'it was hiding is the one to drive — never the URL-less target '
            'itself',
      );
    });

    test('throws with the listing when the app page never appears', () async {
      final cdp = await serveCdpJson((_) => [extensionPage, blankPage]);

      await expectLater(
        resolveCdpPageTarget(
          cdp.port,
          appUrl: appUrl,
          timeout: const Duration(milliseconds: 60),
          pollInterval: const Duration(milliseconds: 5),
        ),
        // Asserted on the listing's own text, not on the `Targets listed:`
        // label: every message this function can throw carries that label, so
        // checking it would pass whatever went wrong.
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(appUrl),
              contains('${cdp.port}'),
              contains('chrome-extension://x/bg.html'),
              contains('about:blank'),
            ),
          ),
        ),
      );
    });

    test('gives up at the timeout rather than polling on', () async {
      final cdp = await serveCdpJson((_) => const <dynamic>[]);
      final stopwatch = Stopwatch()..start();
      await expectLater(
        resolveCdpPageTarget(
          cdp.port,
          appUrl: appUrl,
          timeout: const Duration(milliseconds: 80),
          pollInterval: const Duration(milliseconds: 5),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'a page that never appears must not be waited on forever',
      );
    });

    test('fails immediately when the browser is gone, without waiting out '
        'the timeout', () async {
      // A dead browser refuses the connection, which is a different fact from
      // "the page is not listed yet" and must not be retried into a long
      // silence: the whole timeout would otherwise be spent on a port nothing
      // is listening to.
      final dead = await HttpServer.bind('127.0.0.1', 0);
      final port = dead.port;
      await dead.close(force: true);

      final stopwatch = Stopwatch()..start();
      await expectLater(
        resolveCdpPageTarget(
          port,
          appUrl: appUrl,
          timeout: const Duration(seconds: 30),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason:
            'a refused connection must surface at once, not after the '
            'page-not-listed timeout',
      );
    });

    test('a null app URL is a caller bug, not something to poll for', () async {
      await expectLater(
        resolveCdpPageTarget(1, appUrl: null),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('handleCdpConsoleMessage', () {
    late AppLogStream logs;
    setUp(() => logs = AppLogStream());

    test('forwards a console.log call', () {
      handleCdpConsoleMessage(
        consoleEvent('log', [stringArg('hello from the page')]),
        logs,
      );
      final line = logs.read(0).lines.single;
      expect(line.text, 'hello from the page');
      expect(line.isError, isFalse);
    });

    test('joins multiple arguments with a space, like the browser console', () {
      handleCdpConsoleMessage(
        consoleEvent('log', [stringArg('a'), stringArg('b')]),
        logs,
      );
      expect(logs.read(0).lines.single.text, 'a b');
    });

    test('flags console.error as an error line', () {
      handleCdpConsoleMessage(
        consoleEvent('error', [stringArg('it broke')]),
        logs,
      );
      expect(logs.read(0).lines.single.isError, isTrue);
    });

    test('flags console.warning as an error line', () {
      handleCdpConsoleMessage(
        consoleEvent('warning', [stringArg('careful')]),
        logs,
      );
      expect(logs.read(0).lines.single.isError, isTrue);
    });

    test('renders non-string arguments from their description', () {
      handleCdpConsoleMessage({
        'method': 'Runtime.consoleAPICalled',
        'params': {
          'type': 'log',
          'args': [
            {'type': 'object', 'description': 'Instance of MyClass'},
          ],
        },
      }, logs);
      expect(logs.read(0).lines.single.text, 'Instance of MyClass');
    });

    test('renders numeric and boolean values', () {
      handleCdpConsoleMessage({
        'method': 'Runtime.consoleAPICalled',
        'params': {
          'type': 'log',
          'args': [
            {'type': 'number', 'value': 42},
            {'type': 'boolean', 'value': true},
          ],
        },
      }, logs);
      expect(logs.read(0).lines.single.text, '42 true');
    });

    test('forwards an uncaught exception as an error line', () {
      handleCdpConsoleMessage({
        'method': 'Runtime.exceptionThrown',
        'params': {
          'exceptionDetails': {
            'text': 'Uncaught',
            'exception': {'description': 'Error: boom\n  at main'},
          },
        },
      }, logs);
      // A stack trace keeps its line structure rather than arriving as one
      // unreadable blob.
      final lines = logs.read(0).lines;
      expect(lines.map((l) => l.text), ['Error: boom', '  at main']);
      expect(lines.every((l) => l.isError), isTrue);
    });

    test(
      'falls back to exceptionDetails.text when there is no description',
      () {
        handleCdpConsoleMessage({
          'method': 'Runtime.exceptionThrown',
          'params': {
            'exceptionDetails': {'text': 'Uncaught SyntaxError'},
          },
        }, logs);
        expect(logs.read(0).lines.single.text, 'Uncaught SyntaxError');
      },
    );

    test('splits an embedded multi-line message into separate lines', () {
      handleCdpConsoleMessage(
        consoleEvent('log', [stringArg('first\nsecond')]),
        logs,
      );
      expect(logs.read(0).lines.map((l) => l.text), ['first', 'second']);
    });

    test('ignores unrelated CDP methods', () {
      handleCdpConsoleMessage({'method': 'Page.frameNavigated'}, logs);
      handleCdpConsoleMessage({'id': 1, 'result': {}}, logs);
      expect(logs.read(0).lines, isEmpty);
    });

    test('ignores a console call carrying no arguments', () {
      handleCdpConsoleMessage(consoleEvent('log', const []), logs);
      expect(logs.read(0).lines, isEmpty);
    });

    test('a malformed event does not throw', () {
      expect(
        () => handleCdpConsoleMessage({
          'method': 'Runtime.consoleAPICalled',
          'params': {'type': 'log', 'args': 'not-a-list'},
        }, logs),
        returnsNormally,
      );
      expect(logs.read(0).lines, isEmpty);
    });
  });

  group('CdpConsoleClient reconnect', () {
    late _FakeCdpEndpoint endpoint;

    setUp(() async {
      endpoint = await _FakeCdpEndpoint.start();
      addTearDown(endpoint.stop);
    });

    test(
      'backs off exponentially and gives up when nothing comes back',
      () async {
        final delays = <Duration>[];
        final warnings = <String>[];
        final gaveUp = Completer<void>();
        var opens = 0;

        final client = CdpConsoleClient(
          cdpPort: 0,
          logs: AppLogStream(),
          reconnectDelay: const Duration(milliseconds: 100),
          maxReconnectDelay: const Duration(milliseconds: 400),
          reconnectBudget: const Duration(seconds: 1),
          // Connected once, then the browser is gone for the rest of the run.
          openSocket: (_, __) async {
            if (opens++ > 0) throw const SocketException('connection refused');
            return endpoint.connect();
          },
          // The requested delay is the assertion; the wall clock is not.
          scheduleTimer: (delay, callback) {
            delays.add(delay);
            return Timer(Duration.zero, callback);
          },
          warn: (message) {
            warnings.add(message);
            if (!gaveUp.isCompleted) gaveUp.complete();
          },
        );
        addTearDown(client.close);

        await client.start();
        await endpoint.drop(0);
        await gaveUp.future;

        expect(delays, const [
          Duration(milliseconds: 100),
          Duration(milliseconds: 200),
          Duration(milliseconds: 400),
          Duration(milliseconds: 400),
        ]);
        expect(opens, delays.length + 1);
        expect(warnings.single, contains('console forwarding stopped'));
        expect(warnings.single, contains('connection refused'));
      },
    );

    test('resets the backoff after reattaching to a reloaded page', () async {
      final delays = <Duration>[];

      final client = CdpConsoleClient(
        cdpPort: 0,
        logs: AppLogStream(),
        reconnectDelay: const Duration(milliseconds: 100),
        openSocket: (_, __) => endpoint.connect(),
        scheduleTimer: (delay, callback) {
          delays.add(delay);
          return Timer(Duration.zero, callback);
        },
        warn: (message) => fail('unexpected give-up: $message'),
      );
      addTearDown(client.close);

      await client.start();
      await endpoint.drop(0);
      await endpoint.attached(1);
      await endpoint.drop(1);
      await endpoint.attached(2);

      expect(delays, const [
        Duration(milliseconds: 100),
        Duration(milliseconds: 100),
      ]);
    });

    test('close cancels a pending reconnect and is idempotent', () async {
      Timer? scheduled;
      final pending = Completer<void>();
      var opens = 0;

      final client = CdpConsoleClient(
        cdpPort: 0,
        logs: AppLogStream(),
        // Long enough that only cancellation, not expiry, can end the wait.
        reconnectDelay: const Duration(minutes: 5),
        openSocket: (_, __) {
          opens++;
          return endpoint.connect();
        },
        scheduleTimer: (delay, callback) {
          final timer = Timer(delay, callback);
          scheduled = timer;
          if (!pending.isCompleted) pending.complete();
          return timer;
        },
        warn: (message) => fail('unexpected give-up: $message'),
      );

      await client.start();
      await endpoint.drop(0);
      await pending.future;

      await client.close();
      await client.close();

      expect(scheduled!.isActive, isFalse);
      expect(opens, 1);
    });
  });
}
