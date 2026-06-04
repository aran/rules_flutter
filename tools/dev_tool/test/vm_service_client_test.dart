import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:vm_service/vm_service.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('VmServiceClient', () {
    test('connect converts http:// to ws://.../ws', () async {
      String? capturedUri;
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(
        connector: (wsUri) async {
          capturedUri = wsUri;
          return fakeService;
        },
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/abc/'));
      expect(capturedUri, 'ws://127.0.0.1:8181/abc/ws');
    });

    test('connect converts https:// to wss://.../ws', () async {
      String? capturedUri;
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(
        connector: (wsUri) async {
          capturedUri = wsUri;
          return fakeService;
        },
      );

      await client.connect(Uri.parse('https://127.0.0.1:8181/abc/'));
      expect(capturedUri, 'wss://127.0.0.1:8181/abc/ws');
    });

    test('connect finds isolate named "main"', () async {
      final fakeService = FakeVmService(
        isolates: [
          IsolateRef(id: 'iso-other', name: 'helper', number: '1'),
          IsolateRef(id: 'iso-main', name: 'main', number: '2'),
        ],
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      // Verify main isolate is used for reload.
      await client.hotReload('/tmp/out.dill');
      expect(fakeService.lastIsolateId, 'iso-main');
    });

    test('connect falls back to first isolate when no "main"', () async {
      final fakeService = FakeVmService(
        isolates: [
          IsolateRef(id: 'iso-first', name: 'worker', number: '1'),
          IsolateRef(id: 'iso-second', name: 'helper', number: '2'),
        ],
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      await client.hotReload('/tmp/out.dill');
      expect(fakeService.lastIsolateId, 'iso-first');
    });

    test('hotReload calls reloadSources on correct isolate', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      final success = await client.hotReload('/tmp/out.dill');

      expect(success, isTrue);
      expect(fakeService.reloadSourcesCalled, isTrue);
      expect(fakeService.lastIsolateId, 'iso-1');
    });

    test('hotReload returns false on RPCError', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        throwOnReload: true,
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      final success = await client.hotReload('/tmp/out.dill');
      expect(success, isFalse);
    });

    test('hotRestart re-runs main via runInView', () async {
      // Hot restart must spawn a fresh isolate running main() (engine
      // runInView), NOT just reloadSources+reassemble (which only re-runs
      // build()). This is what makes main()-level changes take effect.
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      final success = await client.hotRestart('/tmp/out.dill');

      expect(success, isTrue);
      expect(fakeService.runInViewCalled, isTrue);
    });

    test('methods throw StateError when not connected', () {
      final client = VmServiceClient(
        connector: (_) async => FakeVmService(),
      );
      expect(() => client.hotReload('/tmp/out.dill'), throwsStateError);
      expect(() => client.hotRestart('/tmp/out.dill'), throwsStateError);
    });

    test('callServiceExtension forwards to VM service', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      await client.callServiceExtension(
        'ext.flutter.pushRoute',
        args: {'route': '/settings'},
      );

      expect(fakeService.lastExtensionMethod, 'ext.flutter.pushRoute');
      expect(fakeService.lastExtensionArgs, {'route': '/settings'});
    });

    test('togglePerformanceOverlay toggles from off to on', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      final enabled = await client.togglePerformanceOverlay();

      // First toggle: off (default) → on.
      expect(enabled, isTrue);
      expect(fakeService.lastExtensionMethod,
          'ext.flutter.showPerformanceOverlay');
      expect(fakeService.lastExtensionArgs, {'enabled': 'true'});
    });

    test('toggleWidgetInspector toggles from off to on', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      final enabled = await client.toggleWidgetInspector();

      expect(enabled, isTrue);
      expect(fakeService.lastExtensionMethod, 'ext.flutter.inspector.show');
      expect(fakeService.lastExtensionArgs, {'enabled': 'true'});
    });

    test('callServiceExtension throws StateError when not connected', () {
      final client = VmServiceClient(
        connector: (_) async => FakeVmService(),
      );
      expect(
        () => client.callServiceExtension('ext.foo'),
        throwsStateError,
      );
    });

    test('screenshot writes PNG from _flutter.screenshot extension', () async {
      // Create a small valid PNG (1x1 pixel, red).
      final pngBytes = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x01, 0x36, 0x28, 0x19,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
      ];
      final b64 = base64.encode(pngBytes);

      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        screenshotData: b64,
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));

      final tmpFile = File('${Directory.systemTemp.path}/test_screenshot.png');
      try {
        await client.screenshot(tmpFile.path);
        expect(tmpFile.existsSync(), isTrue);
        expect(tmpFile.readAsBytesSync(), pngBytes);
        expect(fakeService.lastExtensionMethod, '_flutter.screenshot');
      } finally {
        if (tmpFile.existsSync()) tmpFile.deleteSync();
      }
    });

    test('screenshot throws when _flutter.screenshot returns no data', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        // screenshotData is null — extension will return normal toggle response
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      expect(() => client.screenshot('/tmp/test.png'), throwsStateError);
    });

    test('screenshot throws StateError when not connected', () {
      final client = VmServiceClient(
        connector: (_) async => FakeVmService(),
      );
      expect(() => client.screenshot('/tmp/test.png'), throwsStateError);
    });

    test('isConnected reflects state after connect/disconnect', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(
        connector: (_) async => fakeService,
      );

      expect(client.isConnected, isFalse);
      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      expect(client.isConnected, isTrue);
      await client.disconnect();
      expect(client.isConnected, isFalse);
    });

    test('callServiceExtension reconnects after the underlying service is killed',
        () async {
      // Reproduces the user-reported bug: the cached VmService dies (real-
      // world cause: WebSocket close on hot restart, idle timeout, or DDS
      // tunnel hiccup), and every subsequent RPC throws RPCError(-32000,
      // "Service connection disposed"). The fix is to re-run the connector
      // and retry once.
      final services = <FakeVmService>[];
      final client = VmServiceClient(
        connector: (_) async {
          final fake = FakeVmService(
            isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          );
          services.add(fake);
          return fake;
        },
      );
      await client.connect(Uri.parse('http://127.0.0.1:8181/abc/'));

      // Sanity: first call goes through. Connector ran once.
      await client.callServiceExtension('ext.flutter.foo');
      expect(services, hasLength(1));

      // Simulate the WebSocket dying.
      services.first.simulateDisposed();

      // The bug: this currently propagates the disposal RPCError.
      // The fix: VmServiceClient catches it, re-runs the connector
      // (constructing a second FakeVmService), and retries the RPC.
      await client.callServiceExtension('ext.flutter.foo');
      expect(services, hasLength(2));
    });

    test('hotReload reconnects and replays after the connection is disposed',
        () async {
      // The macOS-observed failure: the session VmServiceClient connects at
      // app launch, then the WebSocket is closed (DDS idle close) before the
      // first reload. `reloadSources` then throws RPCError(-32000, "Service
      // connection disposed"). hotReload must reconnect (rebuilding the
      // devFS) and replay the whole upload→reload→reassemble sequence once.
      final services = <FakeVmService>[];
      final client = VmServiceClient(
        connector: (_) async {
          final fake = FakeVmService(
            isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          );
          services.add(fake);
          return fake;
        },
      );
      await client.connect(Uri.parse('http://127.0.0.1:8181/abc/'));
      expect(services, hasLength(1));

      // WebSocket dies between connect and reload.
      services.first.simulateDisposed();

      final ok = await client.hotReload('/tmp/out.dill');
      expect(ok, isTrue,
          reason: 'hotReload must recover from a disposed connection');
      expect(services, hasLength(2), reason: 'connector re-ran (reconnected)');
      expect(services.last.reloadSourcesCalled, isTrue,
          reason: 'reload replayed on the fresh connection');
    });

    test('hotRestart reconnects and replays after the connection is disposed',
        () async {
      final services = <FakeVmService>[];
      final client = VmServiceClient(
        connector: (_) async {
          final fake = FakeVmService(
            isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          );
          services.add(fake);
          return fake;
        },
      );
      await client.connect(Uri.parse('http://127.0.0.1:8181/abc/'));
      expect(services, hasLength(1));

      services.first.simulateDisposed();

      final ok = await client.hotRestart('/tmp/out.dill');
      expect(ok, isTrue,
          reason: 'hotRestart must recover from a disposed connection');
      expect(services, hasLength(2), reason: 'connector re-ran (reconnected)');
      expect(services.last.runInViewCalled, isTrue,
          reason: 'restart replayed on the fresh connection');
    });

    test('hotReload reports failure when a Flutter.Error follows the reload',
        () async {
      // reloadSources succeeds (VM accepts the kernel) but the rebuilt
      // widget tree throws — the framework posts Flutter.Error. Declaring
      // this "successful" is the bug; success must reflect runtime health.
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        emitFlutterErrorOnReload: true,
        flutterErrorText: 'The following _CompileTimeError was thrown '
            'building MyApp(dirty): Lookup failed: result',
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(Uri.parse('http://127.0.0.1:8181/'));

      final ok = await client.hotReload('/tmp/out.dill');
      expect(ok, isFalse,
          reason: 'a post-reload Flutter.Error must fail the reload');
      expect(client.lastReloadError, contains('_CompileTimeError'));
    });

    test('hotRestart reports failure when a Flutter.Error follows the restart',
        () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        emitFlutterErrorOnReload: true,
        flutterErrorText: 'Lookup failed: result in @getters in MyApp',
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(Uri.parse('http://127.0.0.1:8181/'));

      final ok = await client.hotRestart('/tmp/out.dill');
      expect(ok, isFalse);
      expect(client.lastReloadError, contains('Lookup failed'));
    });

    test('hotReload still succeeds when no Flutter.Error is posted', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(Uri.parse('http://127.0.0.1:8181/'));

      expect(await client.hotReload('/tmp/out.dill'), isTrue);
      expect(client.lastReloadError, isNull);
    });
  });
}
