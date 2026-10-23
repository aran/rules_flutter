import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/web_options.dart';
import 'package:test/test.dart';

/// A stand-in for Chrome's CDP endpoint with the one behaviour the viewport
/// depends on: `Emulation.setDeviceMetricsOverride` belongs to the connection
/// that sent it, and the page goes back to the window's own size when that
/// connection closes (measured on Chrome 154). With [honoursOverride] false it
/// ignores the override altogether, the way a browser that did not take it
/// would.
class _FakeChrome {
  _FakeChrome._(
    this._server, {
    required this.honoursOverride,
    required this.unsettledReads,
  }) {
    _server.listen((request) async {
      if (request.uri.path == '/json') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode([
              {
                'type': 'page',
                'url': 'http://localhost:8080/index.html',
                'webSocketDebuggerUrl': 'ws://127.0.0.1:${_server.port}/page',
              },
            ]),
          );
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      connectionsOpened++;
      _open.add(socket);
      socket.listen(
        (data) {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          final params = (msg['params'] as Map?)?.cast<String, dynamic>();
          switch (msg['method']) {
            case 'Emulation.setDeviceMetricsOverride':
              if (honoursOverride) {
                _override = params;
                _owner = socket;
              }
              overridesSet++;
              socket.add(jsonEncode({'id': msg['id'], 'result': {}}));
            case 'Runtime.evaluate':
              final o = _override;
              final unsettled = o != null && unsettledReads-- > 0;
              socket.add(
                jsonEncode({
                  'id': msg['id'],
                  'result': {
                    'result': {
                      'value': {
                        'w': unsettled ? 980 : o?['width'] ?? 2400,
                        'h': unsettled ? 2121 : o?['height'] ?? 1713,
                        'r': 1,
                      },
                    },
                  },
                }),
              );
          }
        },
        onDone: () {
          _open.remove(socket);
          if (identical(_owner, socket)) {
            _override = null;
            _owner = null;
          }
        },
      );
    });
  }

  final HttpServer _server;
  final bool honoursOverride;

  /// How many reads still answer as a page that has not yet settled at the
  /// size, whatever it laid out as before.
  int unsettledReads;
  final _open = <WebSocket>[];
  Map<String, dynamic>? _override;
  WebSocket? _owner;
  int connectionsOpened = 0;
  int overridesSet = 0;

  int get port => _server.port;
  int get openConnections => _open.length;

  /// What a page reports right now, the way a fresh client would ask.
  Map<String, dynamic>? get override => _override;

  static Future<_FakeChrome> start({
    bool honoursOverride = true,
    int unsettledReads = 0,
  }) async => _FakeChrome._(
    await HttpServer.bind('127.0.0.1', 0),
    honoursOverride: honoursOverride,
    unsettledReads: unsettledReads,
  );

  Future<void> stop() async {
    for (final s in _open.toList()) {
      await s.close();
    }
    await _server.close(force: true);
  }
}

const _appUrl = 'http://localhost:8080';

void main() {
  late _FakeChrome chrome;

  Future<void> start({
    bool honoursOverride = true,
    int unsettledReads = 0,
  }) async {
    chrome = await _FakeChrome.start(
      honoursOverride: honoursOverride,
      unsettledReads: unsettledReads,
    );
    addTearDown(chrome.stop);
  }

  group('applyViewportOverCdp', () {
    test('returns the connection that set the viewport, still open, because '
        'closing it would take the viewport with it', () async {
      await start();
      final hold = await applyViewportOverCdp(
        page: (cdpPort: chrome.port, appUrl: _appUrl),
        viewport: const WebViewport(
          width: 390,
          height: 844,
          deviceScaleFactor: 3,
        ),
        asked: '--web-viewport',
      );
      expect(hold.isClosed, isFalse);
      expect(chrome.override?['width'], 390, reason: 'in effect after return');
      expect(chrome.override?['deviceScaleFactor'], 3);
      expect(
        chrome.override?['mobile'],
        isFalse,
        reason:
            'a mobile override lays the page out at 980px until it declares '
            'a viewport, which a Flutter app does only after launch',
      );

      await hold.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        chrome.override,
        isNull,
        reason: 'the fake models Chrome 154: the override dies with its socket',
      );
    });

    test('changes the viewport on the connection it was given', () async {
      await start();
      final first = await applyViewportOverCdp(
        page: (cdpPort: chrome.port, appUrl: _appUrl),
        viewport: const WebViewport(width: 390, height: 844),
        asked: '--web-viewport',
      );
      final opened = chrome.connectionsOpened;
      final second = await applyViewportOverCdp(
        page: (cdpPort: chrome.port, appUrl: _appUrl),
        viewport: const WebViewport(width: 300, height: 500),
        asked: 'app.setViewport',
        hold: first,
      );
      expect(identical(second, first), isTrue);
      expect(chrome.override?['width'], 300);
      // One connection for the read-back and none for a second override.
      expect(chrome.connectionsOpened, opened + 1);
      await first.close();
    });

    test('replaces a held connection that has closed', () async {
      await start();
      final first = await applyViewportOverCdp(
        page: (cdpPort: chrome.port, appUrl: _appUrl),
        viewport: const WebViewport(width: 390, height: 844),
        asked: '--web-viewport',
      );
      await first.close();
      final second = await applyViewportOverCdp(
        page: (cdpPort: chrome.port, appUrl: _appUrl),
        viewport: const WebViewport(width: 390, height: 844),
        asked: 'app.setViewport',
        hold: first,
      );
      expect(identical(second, first), isFalse);
      expect(second.isClosed, isFalse);
      expect(chrome.override?['width'], 390);
      await second.close();
    });

    test('waits for a page that has not yet settled at the size', () async {
      await start(unsettledReads: 3);
      final hold = await applyViewportOverCdp(
        page: (cdpPort: chrome.port, appUrl: _appUrl),
        viewport: const WebViewport(width: 390, height: 844),
        asked: '--web-viewport',
        pollInterval: const Duration(milliseconds: 20),
      );
      expect(hold.isClosed, isFalse);
      await hold.close();
    });

    test('a browser that ignores the override fails the call and leaves no '
        'connection of ours open', () async {
      await start(honoursOverride: false);
      await expectLater(
        applyViewportOverCdp(
          page: (cdpPort: chrome.port, appUrl: _appUrl),
          viewport: const WebViewport(width: 390, height: 844),
          asked: '--web-viewport',
          settleTimeout: const Duration(milliseconds: 400),
          pollInterval: const Duration(milliseconds: 50),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('did not take'), contains('2400x1713')),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(chrome.openConnections, 0);
    });
  });
}
