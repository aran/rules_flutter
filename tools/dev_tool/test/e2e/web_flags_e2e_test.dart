@Tags(['e2e'])
/// The web dev-loop flags, proved against a real run.
///
/// Every assertion here is on something outside the tool: a socket bound on
/// the port that was named, a header on the wire, the browser's own report of
/// what it is, the pixels a headless render produced, a value the debugger
/// computed. A flag that resolved into the right field and never reached the
/// server or the browser would pass a unit test and fail every one of these.
///
/// Three runs, not eleven. Each web run costs a DDC compile, so the flags are
/// asserted in the combinations that matter: everything switched on, a whole
/// dev loop over TLS, and the defaults plus the off-switches.
///
/// TLS gets its own run because it changes what the rest of the loop speaks —
/// the page, DWDS's injected client and the VM service all move to the same
/// https origin — so a handshake against the server proves the flag arrived
/// but only a session proves the dev loop survives it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tls_fixture.dart';
import 'dev_tool_e2e_harness.dart';

/// A port nothing is listening on right now.
///
/// The same way the servers under test take theirs, so the address family
/// cannot differ. There is an unavoidable window between releasing it and the
/// run claiming it; nothing else on a dev machine hands out ephemeral ports
/// fast enough to matter, and a collision fails loudly (which is the whole
/// point of `--web-port`) rather than silently passing.
Future<int> freePort() async {
  final socket = await ServerSocket.bind('localhost', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// GET [url] and return the response with its body already read.
///
/// Any certificate is accepted: the TLS case serves a self-signed fixture, and
/// what is under test is that the server speaks HTTPS at all, not that a CA
/// vouches for it.
Future<({HttpClientResponse response, String body})> get(Uri url) async {
  final client = HttpClient()..badCertificateCallback = (_, __, ___) => true;
  try {
    final response = await (await client.getUrl(url)).close();
    return (
      response: response,
      body: await response.transform(utf8.decoder).join(),
    );
  } finally {
    client.close();
  }
}

Future<dynamic> getJson(Uri url) async => json.decode((await get(url)).body);

/// The URLs of the browser's `page` targets on [cdpPort], once one of them is
/// on [origin].
///
/// Polled rather than sampled once. A page target exists from launch, but its
/// URL is not continuously the app's: cross-origin isolation forces a
/// browsing-context-group swap, and for a moment the listing carries a page
/// with an empty URL. Sampling once catches that window about half the time.
Future<List<String>> pageTargetsOn(int cdpPort, String origin) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  var delay = const Duration(milliseconds: 50);
  var seen = <String>[];
  while (true) {
    final targets =
        await getJson(Uri.parse('http://127.0.0.1:$cdpPort/json')) as List;
    seen = targets
        .whereType<Map>()
        .where((t) => t['type'] == 'page')
        .map((t) => (t['url'] as String?) ?? '')
        .toList();
    if (seen.any((u) => u.startsWith(origin))) return seen;
    if (DateTime.now().isAfter(deadline)) return seen;
    await Future<void>.delayed(delay);
    delay = delay * 2 > const Duration(milliseconds: 500)
        ? const Duration(milliseconds: 500)
        : delay * 2;
  }
}

/// The base URL the DDC module server reported, read off its structured log
/// rather than parsed out of prose.
Uri moduleServerUri(DevToolProcess dt) {
  for (final line in dt.stderrLines) {
    try {
      final record = json.decode(line) as Map<String, dynamic>;
      if (record['message'] == 'frontend_server_ready') {
        return Uri.parse(record['uri'] as String);
      }
    } catch (_) {
      // Not JSON — skip.
    }
  }
  fail('the DDC module server never reported its URL');
}

/// A live VM service connection to the run's app, with a request/reply helper.
class VmProbe {
  final WebSocket socket;
  final Stream<dynamic> replies;
  var _nextId = 1000;

  VmProbe(this.socket) : replies = socket.asBroadcastStream();

  static Future<VmProbe> connect(DevToolProcess dt) async {
    final debugPort = await dt.waitForEvent(
      'app.debugPort',
      timeout: const Duration(minutes: 2),
    );
    final wsUri = debugPort['params']?['wsUri'] as String?;
    expect(wsUri, isNotNull, reason: 'app.debugPort carried no wsUri');
    return VmProbe(
      await WebSocket.connect(wsUri!).timeout(const Duration(seconds: 30)),
    );
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final id = '${_nextId++}';
    socket.add(
      json.encode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    final reply =
        json.decode(
              await replies
                      .firstWhere(
                        (m) =>
                            (json.decode(m as String)
                                as Map<String, dynamic>)['id'] ==
                            id,
                      )
                      .timeout(const Duration(seconds: 60))
                  as String,
            )
            as Map<String, dynamic>;
    return reply;
  }

  /// The app's isolate and its root library — what an evaluation needs a
  /// target in.
  Future<({String isolateId, String rootLibId})> appIsolate() async {
    final vm = await call('getVM');
    final isolates = vm['result']?['isolates'] as List<dynamic>?;
    expect(isolates, isNotNull, reason: 'getVM listed no isolates: $vm');
    expect(isolates, isNotEmpty, reason: 'the app has no isolate: $vm');
    final isolateId = (isolates!.first as Map<String, dynamic>)['id'] as String;
    final isolate = await call('getIsolate', {'isolateId': isolateId});
    final rootLib = isolate['result']?['rootLib'] as Map<String, dynamic>?;
    expect(rootLib, isNotNull, reason: 'the isolate has no rootLib: $isolate');
    return (isolateId: isolateId, rootLibId: rootLib!['id'] as String);
  }

  Future<void> close() => socket.close();
}

/// Width and height out of a PNG's IHDR chunk.
({int width, int height}) pngSize(List<int> bytes) {
  expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'not a PNG');
  int be32(int at) =>
      (bytes[at] << 24) |
      (bytes[at + 1] << 16) |
      (bytes[at + 2] << 8) |
      bytes[at + 3];
  return (width: be32(16), height: be32(20));
}

void main() {
  final workspace = e2eWorkspace('web_example');

  test(
    'every serving and browser flag reaches the wire',
    () async {
      final port = await freePort();
      final debugPort = await freePort();
      final launchUrl = 'http://localhost:$port/#/flagprobe';

      final dt = await startDevTool(
        workspace: workspace,
        // Its default `--hot` run is the DDC dev loop — the shape with a module
        // server, DWDS, and a resident compiler.
        target: ':app_wasm',
        device: 'chrome',
        extraArgs: [
          '--web-port=$port',
          '--web-hostname=localhost',
          '--web-header=X-Rules-Flutter=on',
          '--web-header=X-Second-Header=two',
          '--cross-origin-isolation',
          '--web-run-headless',
          '--web-browser-debug-port=$debugPort',
          // Chosen because its effect is visible in the pixels: it overrides
          // the --window-size the tool's own headless mode sets, which only
          // works because user switches are spliced after the tool's.
          '--web-browser-flag=--window-size=800,600',
          '--web-launch-url=$launchUrl',
        ],
      );

      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 6));

      // --web-port and --web-hostname: the server is where it was told to be.
      expect(moduleServerUri(dt), Uri.parse('http://localhost:$port'));

      // --web-header and --cross-origin-isolation, on the wire.
      final page = await get(Uri.parse('http://localhost:$port/index.html'));
      expect(page.response.statusCode, 200);
      expect(page.response.headers.value('x-rules-flutter'), 'on');
      expect(page.response.headers.value('x-second-header'), 'two');
      expect(
        page.response.headers.value('cross-origin-opener-policy'),
        'same-origin',
      );
      expect(
        page.response.headers.value('cross-origin-embedder-policy'),
        'credentialless',
      );
      // dart:io adds this by itself, and it is what stopped the app being
      // embeddable in an iframe.
      expect(page.response.headers.value('x-frame-options'), isNull);

      // --web-browser-debug-port: CDP answers exactly there, and it is a
      // headless browser that answered.
      final version =
          await getJson(Uri.parse('http://127.0.0.1:$debugPort/json/version'))
              as Map<String, dynamic>;
      // The browser's own report, from its `User-Agent` rather than its
      // `Browser` field: Chrome 151 answers `Chrome/151…` for the latter
      // whether or not it is headless, and `HeadlessChrome/151…` in the user
      // agent only when it is.
      expect(
        version['User-Agent'],
        contains('HeadlessChrome'),
        reason: '--web-run-headless did not reach the browser: $version',
      );

      // --web-launch-url: the tab is on the URL that was named, fragment and
      // all, and the page lookup still resolves it.
      final pages = await pageTargetsOn(debugPort, 'http://localhost:$port');
      expect(
        pages.any((u) => u.startsWith('http://localhost:$port')),
        isTrue,
        reason: 'the browser is not on this run\'s dev server: $pages',
      );
      // The tab was opened on the launch URL, fragment and all — and by the
      // time this looks, the app may already have rewritten it away. That is
      // exactly why the page lookup matches on origin rather than on the URL
      // it was launched with.
      expect(
        pages.map(Uri.parse).map((u) => u.origin).toSet(),
        contains('http://localhost:$port'),
      );

      // --web-run-headless and --web-browser-flag together: a headless
      // browser really rendered, at the size the user's own switch asked for
      // rather than the one this tool sets for headless runs.
      final http = await dt.waitForHttpControl();
      expect(http, isNotNull);
      // Polled rather than taken once. A browser page is not capturable the
      // moment the control channel binds, and CDP answers a capture attempt
      // before then with `no data` or an expired bound — so on a loaded
      // machine a single attempt fails intermittently and reads as flake. A
      // web run cannot lean on the screenshot endpoint's own settle
      // either: there is no VM service behind a `--wasm` page to ask whether
      // it is idle, which is what its `X-Settled: skipped` says.
      await dt.nativeScreenshotWhenOnScreen(dt.appId!);
      final shot = '${Directory.systemTemp.path}/web_flags_e2e.png';
      await dt.httpScreenshotToFile(dt.appId!, shot);
      final file = File(shot);
      addTearDown(() => file.existsSync() ? file.deleteSync() : null);
      final size = pngSize(file.readAsBytesSync());
      // Width is the window's exactly; height comes back a little short of
      // the 600 asked for because the window includes browser chrome the
      // viewport does not. Both are far from the 2400x1800 this tool sets for
      // a headless run, which is the point: the user's switch is spliced
      // after the tool's own and wins.
      expect(
        size.width,
        800,
        reason:
            'the user switch did not override the tool\'s headless '
            'window size (got $size)',
      );
      expect(size.height, inInclusiveRange(1, 600), reason: 'got $size');

      // --web-enable-expression-evaluation, on by default here: the debugger
      // compiles a fragment against the running program and gets a value.
      final vm = await VmProbe.connect(dt);
      try {
        final target = await vm.appIsolate();
        final result = await vm.call('evaluate', {
          'isolateId': target.isolateId,
          'targetId': target.rootLibId,
          'expression': '1 + 1',
        });
        expect(
          result['error'],
          isNull,
          reason: 'expression evaluation failed: $result',
        );
        expect(
          result['result']?['valueAsString'],
          '2',
          reason: 'the debugger did not compute the expression: $result',
        );
      } finally {
        await vm.close();
      }

      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );

  test(
    'a whole DDC dev loop runs over TLS',
    () async {
      // Its own run, because TLS changes what every other part of the loop
      // speaks: the page is fetched over https, and DWDS's injected client and
      // its VM service ride the same origin. A handshake against the server
      // object proves the flags reached the bind; only a session proves the
      // dev loop still works on the other side of it.
      final dir = Directory.systemTemp.createTempSync('web_flags_tls_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final tls = writeTestCertificate(dir);
      final port = await freePort();

      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_wasm',
        device: 'chrome',
        extraArgs: [
          '--web-port=$port',
          '--web-tls-cert-path=${tls.certPath}',
          '--web-tls-cert-key-path=${tls.keyPath}',
          '--web-run-headless',
          // The certificate is self-signed, so the browser has to be told to
          // proceed anyway — which is itself a --web-browser-flag doing real
          // work rather than a decoration.
          '--web-browser-flag=--ignore-certificate-errors',
        ],
      );

      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 6));

      // The scheme follows the certificate, everywhere the URL is reported.
      final base = moduleServerUri(dt);
      expect(base, Uri.parse('https://localhost:$port'));

      final page = await get(base.replace(path: '/index.html'));
      expect(page.response.statusCode, 200);
      expect(page.body, isNotEmpty);

      // The dev loop itself, on the far side of TLS: DWDS connected, the VM
      // service answers, and the debugger can still compile against the
      // running program.
      final vm = await VmProbe.connect(dt);
      try {
        final target = await vm.appIsolate();
        final result = await vm.call('evaluate', {
          'isolateId': target.isolateId,
          'targetId': target.rootLibId,
          'expression': '1 + 1',
        });
        expect(result['error'], isNull, reason: 'over TLS: $result');
        expect(result['result']?['valueAsString'], '2', reason: '$result');
      } finally {
        await vm.close();
      }

      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );

  test(
    'the defaults and the off-switches are what they say',
    () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_wasm',
        device: 'chrome',
        extraArgs: ['--no-web-enable-expression-evaluation'],
      );

      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 6));
      final base = moduleServerUri(dt);

      // Cross-origin isolation is OFF by default for the DDC dev loop, as it
      // is upstream. On, it costs the page every cross-origin subresource
      // without a CORP header and buys nothing: this loop has no
      // SharedArrayBuffer to protect.
      final page = await get(base.replace(path: '/index.html'));
      expect(page.response.statusCode, 200);
      expect(page.response.headers.value('cross-origin-opener-policy'), isNull);
      expect(
        page.response.headers.value('cross-origin-embedder-policy'),
        isNull,
      );
      expect(page.response.headers.value('x-frame-options'), isNull);

      // --no-web-enable-expression-evaluation: DWDS has no compiler to ask,
      // so an evaluation is refused rather than answered.
      final vm = await VmProbe.connect(dt);
      try {
        final target = await vm.appIsolate();
        final result = await vm.call('evaluate', {
          'isolateId': target.isolateId,
          'targetId': target.rootLibId,
          'expression': '1 + 1',
        });
        final answered =
            result['error'] == null &&
            result['result']?['valueAsString'] == '2';
        expect(
          answered,
          isFalse,
          reason:
              'the flag was off and the expression was evaluated '
              'anyway: $result',
        );
      } finally {
        await vm.close();
      }

      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
