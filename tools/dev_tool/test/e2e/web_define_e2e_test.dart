@Tags(['e2e'])
/// `--web-define` parity for the dev loop, asserted from the live page.
///
/// A `web_defines` entry is a template substitution, so it reaches a running
/// app only through whatever `flutter_bootstrap.js` the page actually loads.
/// The bundle's is substituted by the build; the dev loop's must be too. A dev
/// loop that writes its own from string literals leaves a define referenced in
/// a `bootstrap_js` template working under `bazel build` and doing nothing at
/// all under `flutter_bazel run -d chrome` — the bundle carries it and the page
/// never sees it. Upstream has no such split: `WebAssetServer` substitutes the
/// user's `web/flutter_bootstrap.js` with the dev server's own build config.
///
/// So the assertion is on a JavaScript global read out of the browser over CDP,
/// not on the bytes of a file. A server can serve the right text to nobody: the
/// only thing that settles this is the page having run it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// The value `//:app_dev_boot` declares in `web_defines`.
const _apiUrl = 'https://api.example.com';

/// A port nothing is listening on right now, for `--web-browser-debug-port`.
Future<int> freePort() async {
  final socket = await ServerSocket.bind('localhost', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<dynamic> _getJson(Uri url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(url)).close();
    return json.decode(await response.transform(utf8.decoder).join());
  } finally {
    client.close();
  }
}

/// The debugger URL of a `page` target on [origin], once one is there.
///
/// Polled rather than sampled once: a page target exists from launch, but its
/// URL is not continuously the app's — for a moment the listing carries a page
/// with an empty URL.
Future<String> _appPageSocket(int cdpPort, String origin) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  var delay = const Duration(milliseconds: 50);
  var seen = <String>[];
  while (true) {
    final targets =
        await _getJson(Uri.parse('http://127.0.0.1:$cdpPort/json')) as List;
    final pages = targets.whereType<Map>().where((t) => t['type'] == 'page');
    seen = [for (final p in pages) (p['url'] as String?) ?? ''];
    for (final page in pages) {
      if (((page['url'] as String?) ?? '').startsWith(origin)) {
        return page['webSocketDebuggerUrl'] as String;
      }
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('no browser page reached $origin (saw: $seen)');
    }
    await Future<void>.delayed(delay);
    delay = delay * 2 > const Duration(milliseconds: 500)
        ? const Duration(milliseconds: 500)
        : delay * 2;
  }
}

/// Evaluate [expression] in the page at [socketUrl] and return its CDP result.
Future<Map<String, dynamic>> _evaluate(
  String socketUrl,
  String expression,
) async {
  final socket = await WebSocket.connect(
    socketUrl,
  ).timeout(const Duration(seconds: 30));
  try {
    final replies = socket.asBroadcastStream();
    socket.add(
      json.encode({
        'id': 1,
        'method': 'Runtime.evaluate',
        'params': {'expression': expression, 'awaitPromise': true},
      }),
    );
    final reply =
        json.decode(
              await replies
                      .firstWhere(
                        (m) =>
                            (json.decode(m as String)
                                as Map<String, dynamic>)['id'] ==
                            1,
                      )
                      .timeout(const Duration(seconds: 30))
                  as String,
            )
            as Map<String, dynamic>;
    return reply;
  } finally {
    await socket.close();
  }
}

void main() {
  test(
    'a web_define in the bootstrap template reaches the running page',
    () async {
      final cdpPort = await freePort();
      final webPort = await freePort();

      final dt = await startDevTool(
        workspace: e2eWorkspace('web_example'),
        // The one target whose bootstrap comes from a template of its own and
        // carries a define. Everything else in that workspace takes the
        // rule's built-in bootstrap, where a broken define path is invisible.
        target: ':app_dev_boot',
        device: 'chrome',
        extraArgs: [
          '--web-port=$webPort',
          '--web-hostname=localhost',
          '--web-run-headless',
          '--web-browser-debug-port=$cdpPort',
        ],
      );

      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 6));

      // On web `app.started` is emitted the moment Chrome is launched — before
      // the page has fetched anything. `app.debugPort` is not: the dev tool
      // emits it from its `connectedApps` handler, so it means DWDS's injected
      // client connected, which means the page loaded `main.dart.js`, which
      // means the bootstrap under test ran. That is the happens-before this
      // needs; reading the global on `app.started` alone is a race.
      await dt.waitForEvent(
        'app.debugPort',
        timeout: const Duration(minutes: 2),
      );

      final origin = 'http://localhost:$webPort';
      final page = await _appPageSocket(cdpPort, origin);

      // The define, read off the page's own global scope. Set by the bootstrap
      // the browser executed, so a value here means the dev loop served this
      // target's template rather than one of its own.
      final defineResult = await _evaluate(page, 'window.rulesFlutterApiUrl');
      expect(defineResult['error'], isNull, reason: '$defineResult');
      expect(
        defineResult['result']?['result']?['value'],
        _apiUrl,
        reason: 'the web_define did not reach the page: $defineResult',
      );

      // And the page that carries it is a rendered app, not a blank tab that ran
      // the first line of the bootstrap and stopped. The rest of that same file
      // is the engine's loader, reading a build config the build substituted for
      // DDC — so pixels here mean the whole served bootstrap ran, against the
      // right compiler's output. `screenshot/native` because web has no engine
      // screenshot; `screenshot/flutter` answers 501 there by design.
      final http = await dt.waitForHttpControl();
      expect(http, isNotNull);
      final shot = '${Directory.systemTemp.path}/web_define_e2e.png';
      final file = File(shot);
      addTearDown(() => file.existsSync() ? file.deleteSync() : null);
      await dt.httpScreenshotToFile(dt.appId!, shot);
      final bytes = file.readAsBytesSync();
      expect(bytes.sublist(0, 4), [
        0x89,
        0x50,
        0x4E,
        0x47,
      ], reason: 'not a PNG');
      expect(bytes.length, greaterThan(100));

      // No service worker: the dev loop substitutes a null version, so a
      // template that asks flutter.js to register one registers nothing. One
      // installed against localhost would outlive this run and serve the next
      // one a stale bundle.
      final workers = await _evaluate(
        page,
        'navigator.serviceWorker.getRegistrations().then(r => r.length)',
      );
      expect(
        workers['result']?['result']?['value'],
        0,
        reason: 'a dev run registered a service worker: $workers',
      );

      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
