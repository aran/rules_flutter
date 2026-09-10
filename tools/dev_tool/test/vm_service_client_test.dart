import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('VmServiceClient', () {
    // Every hot reload puts its kernel in the VM's devFS and reloads from
    // there, so a test of one needs a devFS to upload into and a kernel that
    // exists. Without both the client refuses before it reaches
    // `reloadSources` — exactly as it would against a device.
    late Directory tmp;
    late FakeDevFS devFS;
    late String dillPath;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('vm_service_client_');
      devFS = await FakeDevFS.start(
        Directory(p.join(tmp.path, 'devfs'))..createSync(),
      );
      dillPath = p.join(tmp.path, 'out.dill');
      File(dillPath).writeAsBytesSync([1, 2, 3]);
    });

    tearDown(() async {
      await devFS.close();
      tmp.deleteSync(recursive: true);
    });

    /// [fake] connected over that live devFS.
    Future<VmServiceClient> connected(FakeVmService fake) async {
      fake.devFSUri = devFS.uri;
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(devFS.serviceUri);
      return client;
    }

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

    test(
      'disconnect returns when the app never answers _deleteDevFS',
      () async {
        final fakeService = FakeVmService(
          isolates: [IsolateRef(id: 'iso-main', name: 'main', number: '1')],
        );
        fakeService.devFSUri = devFS.uri;
        final client = VmServiceClient(
          connector: (_) async => fakeService,
          disconnectTimeout: const Duration(milliseconds: 50),
        );
        await client.connect(devFS.serviceUri);

        // What a wedged app looks like from here: the socket is up and the
        // request is delivered, and no answer ever comes. There is no error to
        // catch — only silence — so the `catch` around this RPC can never fire,
        // and `forceDisconnect`'s own docstring says as much twelve lines below
        // the call.
        fakeService.callServiceExtensionGate = Completer<void>();

        await client.disconnect().timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail(
            'disconnect() never returned: the _deleteDevFS RPC is '
            'still unbounded, so teardown waits on a dead app forever',
          ),
        );
      },
    );

    // After a deliberate teardown the client must stay retired. An in-flight
    // caller coming back to a client with no service would otherwise dial a
    // replacement, publishing a WebSocket nothing owns and nothing will close
    // — and a live socket keeps the Dart VM running, so a process that has
    // reported a clean shutdown never exits.
    group('a retired client', () {
      test('does not dial again for an RPC that was in flight', () async {
        var dials = 0;
        final fakeService = FakeVmService(
          isolates: [IsolateRef(id: 'iso-main', name: 'main', number: '1')],
        );
        fakeService.devFSUri = devFS.uri;
        final client = VmServiceClient(
          connector: (_) async {
            dials++;
            return fakeService;
          },
        );
        await client.connect(devFS.serviceUri);
        expect(dials, 1);

        await client.retire();

        // What an in-flight consumer does on its way back: ask for something.
        // The client has no service, so this is the path that would re-dial.
        // The verdict does not matter — the socket count does.
        try {
          await client.hotReload(dillPath);
        } catch (_) {
          // A retired client refuses.
        }
        expect(
          dials,
          1,
          reason: 'a retired client must not open a second socket',
        );
      });

      // Not the same as a wedged one. `forceDisconnect` drops a socket the run
      // still wants back, and the next command dialling a fresh one is the
      // recovery it exists for — so the refusal has to be the deliberate
      // teardown alone.
      test('a force-disconnected one still recovers', () async {
        var dials = 0;
        final fakeService = FakeVmService(
          isolates: [IsolateRef(id: 'iso-main', name: 'main', number: '1')],
        );
        fakeService.devFSUri = devFS.uri;
        final client = VmServiceClient(
          connector: (_) async {
            dials++;
            return fakeService;
          },
        );
        await client.connect(devFS.serviceUri);
        await client.forceDisconnect();

        try {
          await client.hotReload(dillPath);
        } catch (_) {
          // The fake's reload verdict is not what this is about.
        }
        expect(
          dials,
          2,
          reason:
              'the next command after a wedged socket must dial a fresh one',
        );
      });

      test('refuses an explicit reconnect too', () async {
        final fakeService = FakeVmService(
          isolates: [IsolateRef(id: 'iso-main', name: 'main', number: '1')],
        );
        fakeService.devFSUri = devFS.uri;
        final client = VmServiceClient(connector: (_) async => fakeService);
        await client.connect(devFS.serviceUri);
        await client.retire();

        await expectLater(
          client.connect(devFS.serviceUri),
          throwsA(isA<StateError>()),
        );
      });
    });

    test('connect finds isolate named "main"', () async {
      final fakeService = FakeVmService(
        isolates: [
          IsolateRef(id: 'iso-other', name: 'helper', number: '1'),
          IsolateRef(id: 'iso-main', name: 'main', number: '2'),
        ],
      );
      final client = await connected(fakeService);
      // Verify main isolate is used for reload.
      await client.hotReload(dillPath);
      expect(fakeService.lastIsolateId, 'iso-main');
    });

    test('connect falls back to first isolate when no "main"', () async {
      final fakeService = FakeVmService(
        isolates: [
          IsolateRef(id: 'iso-first', name: 'worker', number: '1'),
          IsolateRef(id: 'iso-second', name: 'helper', number: '2'),
        ],
      );
      final client = await connected(fakeService);
      await client.hotReload(dillPath);
      expect(fakeService.lastIsolateId, 'iso-first');
    });

    test('hotReload calls reloadSources on correct isolate', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = await connected(fakeService);
      final verdict = await client.hotReload(dillPath);

      expect(verdict, isA<VerdictApplied>());
      expect(fakeService.reloadSourcesCalled, isTrue);
      expect(fakeService.lastIsolateId, 'iso-1');
    });

    test('hotReload reports a refusal on RPCError', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        throwOnReload: true,
      );
      final client = await connected(fakeService);
      final verdict = await client.hotReload(dillPath);
      expect(verdict, isA<VerdictRefused>());
      expect(
        (verdict as VerdictRefused).reason,
        contains('Reload failed'),
        reason: 'what threw travels with the refusal',
      );
    });

    test('a kernel the devFS would not take refuses the reload', () async {
      // The upload *is* the delivery. Reloading from a `file://` path when it
      // fails is a reload only a VM sharing this machine's filesystem could
      // perform; every device instead reports
      // whatever it makes of a path that is not there, and the upload failure
      // is never named.
      devFS.uploadStatus = HttpStatus.internalServerError;
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = await connected(fakeService);

      final verdict = await client.hotReload(dillPath);

      expect(verdict, isA<VerdictRefused>());
      expect(
        (verdict as VerdictRefused).reason,
        contains('devFS'),
        reason:
            'the reader learns the upload failed, not that some path '
            'could not be found',
      );
      expect(
        fakeService.reloadSourcesCalled,
        isFalse,
        reason: 'nothing was delivered, so nothing was asked of the VM',
      );
    });

    test('a VM that made no devFS refuses the reload', () async {
      // The other way [_uploadToDevFS] answers nothing: `_createDevFS` was
      // refused at connect, so there is no devFS to upload into at all.
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fakeService);
      await client.connect(devFS.serviceUri);

      final verdict = await client.hotReload(dillPath);

      expect(verdict, isA<VerdictRefused>());
      expect(fakeService.reloadSourcesCalled, isFalse);
    });

    test('a kernel the devFS would not take refuses the restart', () async {
      // The same delivery [hotReload] has, and the same reason it cannot fall
      // back to a `file://` path: a phone, a simulator and a sandboxed macOS
      // app all read their own VM's filesystem and none of them can read this
      // machine's. Restarting from a path that is not there is a restart that
      // cannot work, reported as whatever the VM makes of the missing file.
      devFS.uploadStatus = HttpStatus.internalServerError;
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = await connected(fakeService);

      final verdict = await client.hotRestart(dillPath);

      expect(verdict, isA<VerdictRefused>());
      expect(
        (verdict as VerdictRefused).reason,
        contains('devFS'),
        reason:
            'the reader learns the upload failed, not that some path '
            'could not be found',
      );
      expect(
        fakeService.runInViewCalled,
        isFalse,
        reason: 'nothing was delivered, so no view was restarted',
      );
    });

    test('a VM that made no devFS refuses the restart', () async {
      // The other way the upload answers nothing: `_createDevFS` was refused at
      // connect, so there is nowhere on the VM to put the kernel at all.
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fakeService);
      await client.connect(devFS.serviceUri);

      expect(await client.hotRestart(dillPath), isA<VerdictRefused>());
      expect(fakeService.runInViewCalled, isFalse);
    });

    test('hotRestart re-runs main via runInView', () async {
      // Hot restart must spawn a fresh isolate running main() (engine
      // runInView), NOT just reloadSources+reassemble (which only re-runs
      // build()). This is what makes main()-level changes take effect.
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = await connected(fakeService);
      final verdict = await client.hotRestart(dillPath);

      expect(verdict, isA<VerdictApplied>());
      expect(fakeService.runInViewCalled, isTrue);
      // And it runs the copy inside the VM's own devFS. The engine opens
      // `mainScript` on the machine the app is on, so the only path that works
      // everywhere is one the VM handed us.
      final runInView = fakeService.methodCalls.firstWhere(
        (c) => c.method == '_flutter.runInView',
      );
      expect(
        runInView.args?['mainScript'],
        devFS.fileAt('main.dart.dill').uri.toString(),
      );
      expect(
        runInView.args?['mainScript'],
        isNot(Uri.file(dillPath).toString()),
        reason: 'a path on this machine is not one a device can open',
      );
    });

    test('methods throw StateError when not connected', () {
      final client = VmServiceClient(
        connector: (_) async => FakeVmService(),
      );
      expect(() => client.hotReload(dillPath), throwsStateError);
      expect(() => client.hotRestart(dillPath), throwsStateError);
    });

    test('callServiceExtension forwards to VM service', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = await connected(fakeService);
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
      final client = await connected(fakeService);
      final enabled = await client.togglePerformanceOverlay();

      // First toggle: off (default) → on.
      expect(enabled, isTrue);
      expect(
        fakeService.lastExtensionMethod,
        'ext.flutter.showPerformanceOverlay',
      );
      expect(fakeService.lastExtensionArgs, {'enabled': 'true'});
    });

    test('toggleWidgetInspector toggles from off to on', () async {
      final fakeService = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = await connected(fakeService);
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
      final client = await connected(fakeService);

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
      final client = await connected(fakeService);
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

    // Pinned because it is documented, not because it is wanted: the getter is
    // published before the handshake it does not wait for. Left that way — a
    // throwing `connect` is the caller's retry signal, and both real callers
    // take it (attach stops; the launcher builds a fresh client per attempt) —
    // but a contract that reads "connected" for a client that never handshook
    // has to be one a test states, or the next reader will use it as a guard.
    test('isConnected is true after a handshake that threw, and false after a '
        'dial that did', () async {
      final died = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..simulateDisposed();
      final published = VmServiceClient(connector: (_) async => died);
      await expectLater(
        published.connect(Uri.parse('http://127.0.0.1:8181/')),
        throwsA(isA<RPCError>()),
        reason: 'the first handshake call is what fails',
      );
      expect(
        published.isConnected,
        isTrue,
        reason:
            'the socket was published before the handshake ran; this is '
            'the window the getter documents',
      );

      final refused = VmServiceClient(
        connector: (_) async => throw StateError('refused'),
      );
      await expectLater(
        refused.connect(Uri.parse('http://127.0.0.1:8181/')),
        throwsStateError,
      );
      expect(
        refused.isConnected,
        isFalse,
        reason: 'a dial that never landed publishes nothing',
      );
    });

    test(
      'callServiceExtension reconnects after the underlying service is killed',
      () async {
        // The cached VmService can die — a WebSocket close on hot restart, an
        // idle timeout, a DDS tunnel hiccup — after which every RPC throws
        // RPCError(-32000, "Service connection disposed"). The client re-runs
        // the connector and retries once.
        final services = <FakeVmService>[];
        final client = VmServiceClient(
          connector: (_) async {
            final fake = FakeVmService(
              isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
            )..devFSUri = devFS.uri;
            services.add(fake);
            return fake;
          },
        );
        await client.connect(devFS.serviceUri);

        // Sanity: first call goes through. Connector ran once.
        await client.callServiceExtension('ext.flutter.foo');
        expect(services, hasLength(1));

        // Simulate the WebSocket dying.
        services.first.simulateDisposed();

        // VmServiceClient catches the disposal RPCError, re-runs the connector
        // (constructing a second FakeVmService), and retries the RPC.
        await client.callServiceExtension('ext.flutter.foo');
        expect(services, hasLength(2));
      },
    );

    test(
      'hotReload reconnects and replays after the connection is disposed',
      () async {
        // A WebSocket closed by DDS between app launch and the first reload
        // makes `reloadSources` throw RPCError(-32000, "Service connection
        // disposed"). hotReload must reconnect (rebuilding the devFS) and
        // replay the whole upload→reload→reassemble sequence once.
        final services = <FakeVmService>[];
        final client = VmServiceClient(
          connector: (_) async {
            final fake = FakeVmService(
              isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
            )..devFSUri = devFS.uri;
            services.add(fake);
            return fake;
          },
        );
        await client.connect(devFS.serviceUri);
        expect(services, hasLength(1));

        // WebSocket dies between connect and reload.
        services.first.simulateDisposed();

        final verdict = await client.hotReload(dillPath);
        expect(
          verdict,
          isA<VerdictApplied>(),
          reason: 'hotReload must recover from a disposed connection',
        );
        expect(
          services,
          hasLength(2),
          reason: 'connector re-ran (reconnected)',
        );
        expect(
          services.last.reloadSourcesCalled,
          isTrue,
          reason: 'reload replayed on the fresh connection',
        );
      },
    );

    test(
      'hotRestart reconnects and replays after the connection is disposed',
      () async {
        final services = <FakeVmService>[];
        final client = VmServiceClient(
          connector: (_) async {
            final fake = FakeVmService(
              isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
            )..devFSUri = devFS.uri;
            services.add(fake);
            return fake;
          },
        );
        await client.connect(devFS.serviceUri);
        expect(services, hasLength(1));

        services.first.simulateDisposed();

        final verdict = await client.hotRestart(dillPath);
        expect(
          verdict,
          isA<VerdictApplied>(),
          reason: 'hotRestart must recover from a disposed connection',
        );
        expect(
          services,
          hasLength(2),
          reason: 'connector re-ran (reconnected)',
        );
        expect(
          services.last.runInViewCalled,
          isTrue,
          reason: 'restart replayed on the fresh connection',
        );
      },
    );

    test(
      'hotReload reports failure when a Flutter.Error follows the reload',
      () async {
        // reloadSources succeeds (VM accepts the kernel) but the rebuilt
        // widget tree throws — the framework posts Flutter.Error. Success must
        // reflect runtime health, so this is not one. And it is not a refusal
        // either: the VM is running this kernel.
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          emitFlutterErrorOnReload: true,
          flutterErrorText:
              'The following _CompileTimeError was thrown '
              'building MyApp(dirty): Lookup failed: result',
        );
        final client = await connected(fake);

        final verdict = await client.hotReload(dillPath);
        expect(
          verdict,
          isA<VerdictAppErrored>(),
          reason:
              'a post-reload Flutter.Error must fail the reload — as an '
              'app error, not as a refusal the compiler would roll back',
        );
        // Asserted on the structured record, not on a flattened string: the
        // rendered text and the description arrive together and both survive.
        final error = (verdict as VerdictAppErrored).error;
        expect(error.renderedText, contains('_CompileTimeError'));
        expect(error.data, isNotEmpty);
      },
    );

    test(
      'a reassemble that throws after the kernel landed is not a refusal',
      () async {
        // The VM has the code: `reloadSources` said so. Only the rebuild that
        // follows failed, and a refusal here would have the compiler roll its
        // baseline back to a program the VM has already stopped running.
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        );
        fake.extensionErrors['ext.flutter.reassemble'] = RPCError(
          'ext.flutter.reassemble',
          113,
          'Isolate must be runnable',
        );
        final client = await connected(fake);

        final verdict = await client.hotReload(dillPath);

        expect(
          fake.reloadSourcesCalled,
          isTrue,
          reason: 'the kernel reached the VM before the rebuild failed',
        );
        expect(verdict, isA<VerdictAppErrored>());
        expect(
          (verdict as VerdictAppErrored).error.description,
          contains('Isolate must be runnable'),
          reason: 'what actually threw has to reach the reader',
        );
      },
    );

    test('the app\'s own report outlives a throwing reassemble', () async {
      // Both accounts of the same moment exist: the framework posted its
      // structured error, and the extension call then failed. The app's is the
      // one with the rendering, the stack and the error count.
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        emitFlutterErrorOnReload: true,
        flutterErrorText: 'The following _CompileTimeError was thrown',
      );
      fake.extensionErrors['ext.flutter.reassemble'] = RPCError(
        'ext.flutter.reassemble',
        113,
        'Isolate must be runnable',
      );
      final client = await connected(fake);

      final verdict = await client.hotReload(dillPath);

      expect(verdict, isA<VerdictAppErrored>());
      expect(
        (verdict as VerdictAppErrored).error.renderedText,
        contains('_CompileTimeError'),
      );
    });

    test(
      'hotReload reports a refusal when the VM rejects the kernel',
      () async {
        // Nothing landed: the app is still running what it had, so this is the
        // verdict the compiler is allowed to roll back on.
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          reloadSuccess: false,
        );
        final client = await connected(fake);

        expect(await client.hotReload(dillPath), isA<VerdictRefused>());
      },
    );

    test(
      'hotRestart reports failure when a Flutter.Error follows the restart',
      () async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          emitFlutterErrorOnReload: true,
          flutterErrorText: 'Lookup failed: result in @getters in MyApp',
        );
        final client = await connected(fake);

        final verdict = await client.hotRestart(dillPath);
        expect(verdict, isA<VerdictAppErrored>());
        expect(
          (verdict as VerdictAppErrored).error.renderedText,
          contains('Lookup failed'),
        );
      },
    );

    test('hotReload still succeeds when no Flutter.Error is posted', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = await connected(fake);

      expect(await client.hotReload(dillPath), isA<VerdictApplied>());
    });

    /// A restart is a loop: `_flutter.runInView` once per Flutter view, and a
    /// multi-window app has several. The loop can therefore fail with some
    /// views already running the new `main()` — which is not a refusal, and
    /// telling the compiler it was leaves its baseline describing a program no
    /// app is running.
    ///
    /// The errors here are the engine's own, verbatim; both share the `-32000`
    /// a disposed connection uses, so a client that classified by code alone
    /// would re-dial a connection that is perfectly healthy.
    group('a restart across several views', () {
      /// Two shells, two root isolates, two views — `multi_window_example`.
      FakeVmService twoViews() => FakeVmService(
        isolates: [
          IsolateRef(id: 'iso-1', name: 'main', number: '1'),
          IsolateRef(id: 'iso-2', name: 'main', number: '2'),
        ],
      )..viewIds = const ['view-1', 'view-2'];

      /// [fake] connected over the live devFS, counting the dials so a test can
      /// tell a replay from a single attempt.
      Future<(VmServiceClient, List<FakeVmService>)> connectedCounting(
        FakeVmService fake,
      ) async {
        final services = <FakeVmService>[];
        final client = VmServiceClient(
          connector: (_) async {
            services.add(fake..devFSUri = devFS.uri);
            return fake;
          },
        );
        await client.connect(devFS.serviceUri);
        return (client, services);
      }

      test(
        'a later view that fails leaves the first one running the new code',
        () async {
          final fake = twoViews()
            ..runInViewErrors['view-2'] = RPCError(
              '_flutter.runInView',
              -32000,
              'Could not run configuration in engine.',
            );
          final (client, services) = await connectedCounting(fake);

          final verdict = await client.hotRestart(dillPath);

          expect(
            verdict,
            isA<VerdictAppErrored>(),
            reason:
                'view-1 is running the new main(); a refusal would have '
                'the compiler roll back code the app has',
          );
          expect(
            (verdict as VerdictAppErrored).error.description,
            contains('Could not run configuration'),
          );
          expect(fake.runInViewCalls, ['view-1']);
          expect(
            services,
            hasLength(1),
            reason:
                'the engine says -32000 for its own failures too, so this '
                'must not be read as a dropped connection',
          );
        },
      );

      test(
        'the first view failing is a refusal — nothing was restarted',
        () async {
          final fake = twoViews()
            ..runInViewErrors['view-1'] = RPCError(
              '_flutter.runInView',
              -32000,
              'Service protocol could not handle or find a handler for the '
                  'requested method.',
            );
          final (client, services) = await connectedCounting(fake);

          final verdict = await client.hotRestart(dillPath);

          expect(verdict, isA<VerdictRefused>());
          expect(fake.runInViewCalls, isEmpty);
          expect(services, hasLength(1));
        },
      );

      test('every view is restarted when none of them fails', () async {
        final fake = twoViews();
        final (client, _) = await connectedCounting(fake);

        expect(await client.hotRestart(dillPath), isA<VerdictApplied>());
        expect(fake.runInViewCalls, ['view-1', 'view-2']);
      });
    });

    /// `package:vm_service` completes every call with
    /// `RPCError(method, -32000, 'Service connection disposed')` once its
    /// WebSocket has closed — an idle DDS tunnel, a restart rotating the VM.
    /// That is this end's transport failing, not the app's code, and
    /// [_withReconnect] exists to replay the whole apply on a fresh
    /// connection. What it must never do is come back as a refusal once the
    /// first attempt has already put the code in the VM: a closed socket does
    /// not take a kernel back out.
    group('a connection disposed after the code landed', () {
      RPCError disposed(String method) =>
          RPCError(method, -32000, 'Service connection disposed');

      /// A client whose every dial builds a fresh fake, prepared by [prepare].
      (VmServiceClient, List<FakeVmService>) dialling(
        void Function(FakeVmService fake, int dial) prepare,
      ) {
        final services = <FakeVmService>[];
        final client = VmServiceClient(
          connector: (_) async {
            final fake = FakeVmService(
              isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
            )..devFSUri = devFS.uri;
            prepare(fake, services.length);
            services.add(fake);
            return fake;
          },
        );
        return (client, services);
      }

      test(
        'a reassemble that finds it disposed is replayed, not reported',
        () async {
          final (client, services) = dialling((fake, dial) {
            if (dial == 0) {
              fake.extensionErrors['ext.flutter.reassemble'] = disposed(
                'ext.flutter.reassemble',
              );
            }
          });
          await client.connect(devFS.serviceUri);

          expect(
            await client.hotReload(dillPath),
            isA<VerdictApplied>(),
            reason: 'the app was fine; the socket was not',
          );
          expect(services, hasLength(2), reason: 'the drop was re-dialled');
          expect(
            services.last.reloadSourcesCalled,
            isTrue,
            reason: 'the whole apply replayed on the fresh connection',
          );
        },
      );

      test(
        'a restart\'s later view finding it disposed is replayed too',
        () async {
          final (client, services) = dialling((fake, dial) {
            fake
              ..isolates.addAll([
                IsolateRef(id: 'iso-2', name: 'main', number: '2'),
              ])
              ..viewIds = const ['view-1', 'view-2'];
            if (dial == 0) {
              fake.runInViewErrors['view-2'] = disposed('_flutter.runInView');
            }
          });
          await client.connect(devFS.serviceUri);

          expect(await client.hotRestart(dillPath), isA<VerdictApplied>());
          expect(services, hasLength(2));
          expect(
            services.last.runInViewCalls,
            ['view-1', 'view-2'],
            reason: 'the replay restarts every view on the new connection',
          );
        },
      );

      test('a disposal the replay hits too is not a refusal', () async {
        final (client, services) = dialling((fake, _) {
          fake.extensionErrors['ext.flutter.reassemble'] = disposed(
            'ext.flutter.reassemble',
          );
        });
        await client.connect(devFS.serviceUri);

        final verdict = await client.hotReload(dillPath);

        expect(
          verdict,
          isA<VerdictAppErrored>(),
          reason:
              'both attempts put the kernel in a VM, so the app has it '
              'however badly this ended',
        );
        expect(
          (verdict as VerdictAppErrored).error.description,
          contains('connection'),
        );
        expect(services, hasLength(2), reason: 'replayed exactly once');
      });

      test(
        'a replay that can no longer deliver is not a refusal either',
        () async {
          // The app dying mid-reload is exactly when the fresh devFS refuses the
          // upload. The first attempt still landed the kernel, so the refusal
          // the second one answers is not the run's verdict.
          final (client, services) = dialling((fake, dial) {
            if (dial == 0) {
              fake.extensionErrors['ext.flutter.reassemble'] = disposed(
                'ext.flutter.reassemble',
              );
            } else {
              devFS.uploadStatus = HttpStatus.internalServerError;
            }
          });
          await client.connect(devFS.serviceUri);

          expect(
            await client.hotReload(dillPath),
            isA<VerdictAppErrored>(),
            reason:
                'the first attempt delivered; a later upload failing does '
                'not un-deliver it',
          );
          expect(services, hasLength(2));
        },
      );
    });
  });

  /// `connect` is what every other entry point falls back into: a
  /// force-disconnected client sends the next call through `_withReconnect`
  /// into `connect`. Untimed, one unreachable device wedges `app.getText` and
  /// `app.dumpWidgetTree` just as surely as a reload — all of them inside the
  /// single command permit.
  group('VmServiceClient.connect bound', () {
    final serviceUri = Uri.parse('http://127.0.0.1:8181/');

    test(
      'a dial that never answers throws instead of blocking forever',
      () async {
        final client = VmServiceClient(
          connector: (_) => Completer<VmService>().future,
          connectTimeout: const Duration(milliseconds: 50),
        );

        await expectLater(
          client.connect(serviceUri),
          throwsA(isA<TimeoutException>()),
        );
        expect(client.isConnected, isFalse);
      },
    );

    test(
      'a connection that arrives after the deadline is closed, not adopted',
      () async {
        // Otherwise the abandoned dial publishes itself into a client whose
        // caller has already been told the connect failed, leaving a socket open
        // behind a connection nobody asked for.
        final dial = Completer<VmService>();
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        );
        final client = VmServiceClient(
          connector: (_) => dial.future,
          connectTimeout: const Duration(milliseconds: 50),
        );

        await expectLater(
          client.connect(serviceUri),
          throwsA(isA<TimeoutException>()),
        );

        dial.complete(fake);
        await pumpEventQueue();

        expect(client.isConnected, isFalse);
        expect(fake.disposed, isTrue);
      },
    );

    test('a VM that dials but never answers getVM is disconnected', () async {
      // The hang can land anywhere in the sequence, and past the dial the
      // client has already published the connection — so the deadline has to
      // close it rather than leave `isConnected` reporting a wedged socket.
      final gate = Completer<void>();
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..callServiceExtensionGate = gate; // held on _createDevFS
      final client = VmServiceClient(
        connector: (_) async => fake,
        connectTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        client.connect(serviceUri),
        throwsA(isA<TimeoutException>()),
      );

      expect(client.isConnected, isFalse);
      expect(fake.disposed, isTrue);

      fake.simulateDisposed();
      gate.complete();
      await pumpEventQueue();
    });
  });

  /// The one lifecycle fact a client can observe about an app it does not own.
  ///
  /// `attach` has no process to watch — it did not launch the app — so the
  /// connection closing and not coming back is the whole of its evidence that
  /// the app is gone. These tests draw the distinction: a socket that closes
  /// and reopens is a *reconnect*, which this client survives, and treating one
  /// as a death would make an attach kill itself over a DDS hiccup.
  group('VmServiceClient.gone', () {
    final serviceUri = Uri.parse('http://127.0.0.1:8181/');

    FakeVmService newFake() => FakeVmService(
      isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
    );

    /// Whether [client] has reported its app gone, sampled after the event
    /// queue has drained so a pending watcher has had its turn.
    Future<bool> reportedGone(VmServiceClient client) async {
      var fired = false;
      unawaited(client.gone.then((_) => fired = true));
      await pumpEventQueue();
      return fired;
    }

    test('a closed socket that will not re-dial is the app gone', () async {
      var dials = 0;
      final fake = newFake();
      final client = VmServiceClient(
        connector: (_) async {
          if (dials++ > 0) {
            throw const SocketException('Connection refused');
          }
          return fake;
        },
      );
      await client.connect(serviceUri);

      // What a dead app looks like from here: the WebSocket's input stream
      // ends, `package:vm_service` disposes itself, and nothing answers the
      // port any more.
      fake.simulateDisposed();

      await client.gone.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'the connection closed and the re-dial was refused, and the client '
          'still has not reported the app gone',
        ),
      );
      expect(dials, 2, reason: 'the close was probed exactly once');
    });

    test('a closed socket that re-dials is a reconnect, not a death', () async {
      final services = <FakeVmService>[];
      final client = VmServiceClient(
        connector: (_) async {
          final fake = newFake();
          services.add(fake);
          return fake;
        },
      );
      await client.connect(serviceUri);
      services.first.simulateDisposed();

      expect(
        await reportedGone(client),
        isFalse,
        reason: 'the app answered the re-dial, so it is still there',
      );
      expect(services, hasLength(2), reason: 'the drop was re-dialled');
      // And the reconnect is a real one, not just a silence: the client works.
      await client.callServiceExtension('ext.flutter.foo');
      expect(services.last.callServiceExtensionCalled, isTrue);
    });

    test(
      'disconnecting is this end hanging up, not the app going away',
      () async {
        var dials = 0;
        final client = VmServiceClient(
          connector: (_) async {
            dials++;
            return newFake();
          },
        );
        await client.connect(serviceUri);

        await client.disconnect();

        expect(
          await reportedGone(client),
          isFalse,
          reason: 'we closed the connection; the app was never asked about',
        );
        expect(dials, 1, reason: 'a hang-up we chose is not probed');
      },
    );

    // An app dying *during* a command is one event reaching two places out of
    // order: the watcher re-dials and fails, and only then does the command's
    // own RPC come back `-32000` and ask about a connection nobody rebuilt.
    // The command has to be answered with the reason the re-dial failed —
    // replaying it against the connection that is not there is a null
    // dereference reported as whatever the caller makes of a `TypeError`. The
    // answer comes from the report rather than from a third dial to an app
    // already known to be gone, so the reason survives and the type is the
    // client's own.
    test(
      'an RPC that outlives a failed re-dial fails with its reason',
      () async {
        var dials = 0;
        final fake = newFake();
        final client = VmServiceClient(
          connector: (_) async {
            if (dials++ > 0) {
              throw const SocketException('Connection refused');
            }
            return fake;
          },
        );
        await client.connect(serviceUri);

        // Set after connect: `_createDevFS` goes through the same door, and a
        // gate held across it would park the connect itself.
        final gate = Completer<void>();
        fake.callServiceExtensionGate = gate;
        final inFlight = client.callServiceExtension('ext.flutter.foo');
        await pumpEventQueue();

        fake.simulateDisposed();
        await client.gone.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the re-dial was refused'),
        );

        gate.complete();
        await expectLater(
          inFlight,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('the app is gone'),
                contains('Connection refused'),
              ),
            ),
          ),
        );
        expect(dials, 2, reason: 'the close was probed once and never again');
      },
    );

    // The window a probe opens that nothing else did: a run ends *because* its
    // app exited, so the teardown and the re-dial that exit provoked are the
    // same moment. A dial landing after the teardown would publish itself into
    // a client nobody will disconnect again, and the socket it leaves open is
    // what keeps the process alive after the run is over.
    test(
      'a re-dial that lands after a teardown is closed, not published',
      () async {
        final first = newFake();
        final late_ = Completer<VmService>();
        final arriving = newFake();
        var dials = 0;
        final client = VmServiceClient(
          connector: (_) => dials++ == 0 ? Future.value(first) : late_.future,
        );
        await client.connect(serviceUri);

        first.simulateDisposed();
        await pumpEventQueue();
        expect(dials, 2, reason: 'the close is being probed');

        await client.disconnect();
        late_.complete(arriving);
        await pumpEventQueue();

        expect(client.isConnected, isFalse);
        expect(
          arriving.disposed,
          isTrue,
          reason: 'a socket published into a torn-down client is never closed',
        );
      },
    );

    // A hang-up is a fact about one socket, not about the client. Whoever
    // resets a wedged connection — the apply timeout does, the relauncher does
    // — hands back a run that has to keep watching the next one, or the app
    // could die at any point after and never be noticed.
    test(
      'a client that hung up and dialled again watches the new socket',
      () async {
        final services = <FakeVmService>[];
        var refuse = false;
        final client = VmServiceClient(
          connector: (_) async {
            if (refuse) throw const SocketException('Connection refused');
            final fake = newFake();
            services.add(fake);
            return fake;
          },
        );
        await client.connect(serviceUri);
        await client.forceDisconnect();
        await client.connect(serviceUri);

        refuse = true;
        services.last.simulateDisposed();

        await client.gone.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail(
            'the app died on a connection made after a hang-up, and the client '
            'was still treating closes as its own doing',
          ),
        );
      },
    );

    // A probe is only evidence about the app if it rebuilds the same
    // connection. Web connects without a devFS — DWDS's proxy has no
    // filesystem — and a re-dial that asked for one anyway would answer the
    // predictable `-32601` with a warning that the run's reload is broken.
    test(
      'a re-dial rebuilds the connection it replaces, devFS and all',
      () async {
        final services = <FakeVmService>[];
        final client = VmServiceClient(
          connector: (_) async {
            final fake = newFake();
            services.add(fake);
            return fake;
          },
        );
        await client.connect(serviceUri, createDevFS: false);
        services.first.simulateDisposed();

        expect(await reportedGone(client), isFalse);
        expect(services, hasLength(2));
        expect(
          services.last.extensionCalls.map((c) => c.method),
          isNot(contains('_createDevFS')),
          reason: 'the connection being replaced had no devFS',
        );
      },
    );

    // The relauncher and the apply-timeout path both take this door, and the
    // relauncher's is the one that matters: it disconnects on purpose, in the
    // window where the app is *meant* to disappear and be replaced.
    test(
      'force-disconnecting a wedged connection is not the app going away',
      () async {
        var dials = 0;
        final client = VmServiceClient(
          connector: (_) async {
            dials++;
            return newFake();
          },
        );
        await client.connect(serviceUri);

        await client.forceDisconnect();

        expect(await reportedGone(client), isFalse);
        expect(dials, 1);
      },
    );
  });

  /// A connection that comes back and then dies again, over and over.
  ///
  /// Every dial *succeeds* here, so nothing ever throws and none of the group
  /// above can see it: the death is in the pattern, not in any one event. This
  /// is the shape a flapping tunnel has, and an unbounded client answers it by
  /// re-dialling forever without ever reporting anything.
  group('VmServiceClient and a connection that will not stay up', () {
    final serviceUri = Uri.parse('http://127.0.0.1:8181/');

    FakeVmService newFake() => FakeVmService(
      isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
    );

    /// Whether [client] has reported its app gone, sampled after the event
    /// queue has drained so a pending watcher has had its turn.
    Future<bool> reportedGone(VmServiceClient client) async {
      var fired = false;
      unawaited(client.gone.then((_) => fired = true));
      await pumpEventQueue();
      return fired;
    }

    /// A client whose every dial is answered by a fresh, live connection, and
    /// a hook to kill whichever one it currently holds.
    ///
    /// [now] drives the flap window, because the window is measured in
    /// wall-clock and the alternative — a test that sleeps past it — would be
    /// both slow and a coin toss.
    ({
      VmServiceClient client,
      List<FakeVmService> services,
      void Function() killCurrent,
    })
    flapping({
      required DateTime Function() now,
      int flapLimit = 5,
      Duration flapWindow = const Duration(seconds: 5),
    }) {
      final services = <FakeVmService>[];
      final client = VmServiceClient(
        connector: (_) async {
          final fake = newFake();
          services.add(fake);
          return fake;
        },
        flapLimit: flapLimit,
        flapWindow: flapWindow,
        now: now,
      );
      return (
        client: client,
        services: services,
        killCurrent: () => services.last.simulateDisposed(),
      );
    }

    /// Kill the live connection [times] over, letting each re-dial land.
    Future<void> flap(
      ({
        VmServiceClient client,
        List<FakeVmService> services,
        void Function() killCurrent,
      })
      f,
      int times,
    ) async {
      for (var i = 0; i < times; i++) {
        f.killCurrent();
        await pumpEventQueue();
      }
    }

    // The bound, asserted as a number rather than as "the test finished".
    // Non-termination is only visible to bazel — `dart test` kills the isolate
    // and calls it a pass — so a test that merely runs to the end here proves
    // nothing at all about a loop.
    test(
      'stops re-dialling after a fixed number of flaps, and says so',
      () async {
        var clock = DateTime(2026);
        // Time never advances, so every close is inside any window.
        final f = flapping(now: () => clock, flapLimit: 5);
        await f.client.connect(serviceUri);
        expect(f.services, hasLength(1));

        // Ten kills offered; only the first few may be answered with a dial.
        await flap(f, 10);

        expect(
          f.services,
          hasLength(5),
          reason:
              'the initial connection plus four re-dials is the whole of '
              'what a limit of five permits',
        );
        await f.client.gone.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail(
            'the connection never stayed up and the client '
            'still has not reported the app gone',
          ),
        );
        expect(
          f.client.isConnected,
          isFalse,
          reason:
              'the socket it was holding is dead and nothing will replace '
              'it',
        );
        // The clock is untouched by the assertion above; nothing here waited.
        expect(clock, DateTime(2026));
      },
    );

    // The calls that answer from the null service directly — the screenshot and
    // the two extension toggles — never reach `_reconnect`, so the report it
    // hands every other caller passes them by. A bare "Not connected to VM
    // service" sends whoever reads it looking for a connect that failed, when
    // what happened is that the client gave up re-dialling for a reason it had
    // already established.
    test(
      'a client that gave up names why, not just that it is disconnected',
      () async {
        var clock = DateTime(2026);
        final f = flapping(now: () => clock, flapLimit: 2);
        await f.client.connect(serviceUri);
        await flap(f, 5);
        await f.client.gone.timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the client never reported the app gone'),
        );

        for (final call in <(String, Future<Object?> Function())>[
          ('screenshotBytes', f.client.screenshotBytes),
          ('togglePerformanceOverlay', f.client.togglePerformanceOverlay),
          ('toggleWidgetInspector', f.client.toggleWidgetInspector),
        ]) {
          await expectLater(
            call.$2(),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                allOf(contains('the app is gone'), contains('died within')),
              ),
            ),
            reason: '${call.$1} has to carry the reason the client recorded',
          );
        }
      },
    );

    // Otherwise the cap is a countdown on the session rather than a bound on a
    // loop: a long attach that hiccups once an hour would spend its strikes
    // over a day and kill an app that was never unwell.
    test('a connection that lasted resets the count', () async {
      var clock = DateTime(2026);
      final f = flapping(
        now: () => clock,
        flapLimit: 3,
        flapWindow: const Duration(seconds: 5),
      );
      await f.client.connect(serviceUri);

      // Two flaps: two strikes, one short of the limit.
      await flap(f, 2);
      expect(f.services, hasLength(3));
      expect(await reportedGone(f.client), isFalse);

      // The next connection stands for an hour before it drops. That is a
      // hiccup, and it says nothing about the two that came before it.
      clock = clock.add(const Duration(hours: 1));
      await flap(f, 1);
      expect(
        await reportedGone(f.client),
        isFalse,
        reason: 'a connection that stood for an hour is not a flap',
      );
      expect(f.services, hasLength(4));

      // Proof the count really went back to zero: a full limit's worth of
      // flaps is needed again, and the one before it is not enough.
      await flap(f, 2);
      expect(
        await reportedGone(f.client),
        isFalse,
        reason: 'two flaps against a limit of three is not yet an answer',
      );
      await flap(f, 1);
      await f.client.gone.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('three flaps after the reset went unreported'),
      );
      expect(f.services, hasLength(6));
    });

    // Completing the report and stopping the work are two different things: a
    // client that only completes `gone` goes on dialling behind it.
    test('nothing dials once the app has been reported gone', () async {
      var clock = DateTime(2026);
      final f = flapping(now: () => clock, flapLimit: 2);
      await f.client.connect(serviceUri);
      await flap(f, 5);
      await f.client.gone;
      final dialsAtDeath = f.services.length;

      // Every door to a dial, tried after the report: the watcher's own (more
      // closes), and a caller arriving through `_withReconnect` — a reload
      // dispatched by a driver that had not heard yet, which is the realistic
      // way this is reached.
      await flap(f, 5);
      final verdict = await f.client.hotReload('/does/not/matter.dill');
      expect(
        verdict,
        isA<VerdictRefused>().having(
          (v) => v.reason,
          'reason',
          contains('the app is gone'),
        ),
        reason: 'the reload is refused with the report, not by dialling',
      );
      await pumpEventQueue();

      expect(
        f.services,
        hasLength(dialsAtDeath),
        reason:
            'the app was reported gone; that answer cannot be taken back '
            'and nothing may dial behind it',
      );
    });

    // The relauncher and the apply timeout both hang up on purpose and then go
    // on using the client. A strike carried across that boundary would be a
    // charge against a connection the caller had already replaced.
    test('a teardown this end chose forgets the strikes before it', () async {
      var clock = DateTime(2026);
      final f = flapping(now: () => clock, flapLimit: 3);
      await f.client.connect(serviceUri);
      await flap(f, 2);
      expect(await reportedGone(f.client), isFalse);

      await f.client.forceDisconnect();
      await f.client.connect(serviceUri);

      // Two more flaps. With the strikes carried over this would be the fifth
      // and the app would be declared gone.
      await flap(f, 2);
      expect(
        await reportedGone(f.client),
        isFalse,
        reason: 'the count belongs to the connection the caller tore down',
      );
    });

    // A dial that dies mid-handshake must not install the watcher that dials
    // again, or a connect that could never finish builds its own successor. It
    // is [connect]'s caller — or, on a re-dial, `gone` — that owns that failure.
    test('a handshake that cannot finish is not re-dialled forever', () async {
      final services = <FakeVmService>[];
      final client = VmServiceClient(
        connector: (_) async {
          final fake = newFake();
          services.add(fake);
          // Dead before it can answer `getVM`: the dial succeeded and the socket
          // went away underneath it.
          fake.simulateDisposed();
          return fake;
        },
      );

      await expectLater(client.connect(serviceUri), throwsA(isA<RPCError>()));
      await pumpEventQueue();

      expect(
        services,
        hasLength(1),
        reason:
            'a connect that never completed is the caller\'s to retry, '
            'not something this client dials behind its back',
      );
    });
  });

  group('VmServiceClient.pausedReason', () {
    Future<(VmServiceClient, FakeVmService)> connected(String pauseKind) async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..pauseKind = pauseKind;
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      return (client, fake);
    }

    test('a running isolate has no reason', () async {
      final (client, _) = await connected(EventKind.kResume);

      expect(await client.pausedReason(), isNull);
    });

    // Every `ext.*` call runs *on* the isolate, so dispatching one to a paused
    // isolate never returns: an `app.getText` against a --start-paused run
    // would wedge the HTTP control channel for the rest of the session.
    test('a start-paused isolate names the flag that paused it', () async {
      final (client, _) = await connected(EventKind.kPauseStart);

      expect(await client.pausedReason(), contains('--start-paused'));
    });

    test('a breakpoint says so, and says who has to resume it', () async {
      final (client, _) = await connected(EventKind.kPauseBreakpoint);

      final reason = await client.pausedReason();
      expect(reason, contains('breakpoint'));
      expect(reason, contains('resume'));
    });

    test('an exited isolate is reported, not treated as running', () async {
      final (client, _) = await connected(EventKind.kPauseExit);

      expect(await client.pausedReason(), contains('exited'));
    });
  });

  group('VmServiceClient.reloadAssets', () {
    late Directory root;
    late String assetsDir;
    late String devFSRoot;
    late HttpServer devFSServer;
    late Uri serviceUri;

    /// Stand-in for the VM's devFS HTTP endpoint: decodes the `dev_fs_uri_b64`
    /// header the way the VM does and writes the gzipped body under
    /// [devFSRoot].
    ///
    /// A real server rather than a stub, because the upload is the delivery.
    /// A double that just recorded calls could not tell a devFS the engine can
    /// actually open from one that was never written.
    Future<void> startDevFS() async {
      devFSServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serviceUri = Uri.parse('http://127.0.0.1:${devFSServer.port}/');
      unawaited(
        devFSServer.forEach((request) async {
          final encoded = request.headers.value('dev_fs_uri_b64')!;
          final relative = utf8.decode(base64.decode(encoded));
          final bytes = <int>[];
          await for (final chunk in request) {
            bytes.addAll(chunk);
          }
          final file = File(p.join(devFSRoot, relative))
            ..parent.createSync(recursive: true);
          file.writeAsBytesSync(gzip.decode(bytes));
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();
        }),
      );
    }

    setUp(() async {
      root = Directory.systemTemp.createTempSync('reload_assets_');
      assetsDir = p.join(root.path, 'bundle');
      devFSRoot = p.join(root.path, 'devfs');
      Directory(devFSRoot).createSync();
      File(p.join(assetsDir, 'assets', 'logo.png'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('new bytes');
      await startDevFS();
    });

    tearDown(() async {
      await devFSServer.close(force: true);
      root.deleteSync(recursive: true);
    });

    Future<(VmServiceClient, FakeVmService)> connected() async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..devFSUri = Uri.directory(devFSRoot).toString();
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);
      client.assetDirectory = assetsDir;
      return (client, fake);
    }

    test('uploads the changed bytes into the devFS', () async {
      final (client, _) = await connected();

      expect(
        await client.reloadAssets({'assets/logo.png'}),
        isA<VerdictApplied>(),
      );

      // The app reads this copy, not the build tree. An APK, a phone, and a
      // sandboxed macOS app can all reach it.
      expect(
        File(
          p.join(devFSRoot, 'flutter_assets', 'assets', 'logo.png'),
        ).readAsStringSync(),
        'new bytes',
      );
    });

    test(
      'points the engine at the devFS directory, evicts, and reassembles',
      () async {
        final (client, fake) = await connected();

        await client.reloadAssets({'assets/logo.png'});

        final setPath = fake.methodCalls.firstWhere(
          (c) => c.method == '_flutter.setAssetBundlePath',
        );
        expect(setPath.args?['viewId'], 'view-1');
        expect(
          setPath.args?['assetDirectory'],
          p.join(devFSRoot, 'flutter_assets') + p.separator,
        );
        // Order matters: reassembling before the cache is emptied rebuilds the
        // tree against the bytes being evicted a moment later.
        expect(
          fake.extensionCalls.map((c) => c.method),
          containsAllInOrder(['ext.flutter.evict', 'ext.flutter.reassemble']),
        );
        expect(
          fake.extensionCalls
              .firstWhere((c) => c.method == 'ext.flutter.evict')
              .args,
          {'value': 'assets/logo.png'},
        );
      },
    );

    test('evicts every changed archive path, not just the last', () async {
      File(p.join(assetsDir, 'assets', 'b.png')).writeAsStringSync('b');
      File(p.join(assetsDir, 'AssetManifest.bin')).writeAsStringSync('m');
      final (client, fake) = await connected();

      await client.reloadAssets({
        'assets/logo.png',
        'assets/b.png',
        'AssetManifest.bin',
      });

      expect(
        fake.extensionCalls
            .where((c) => c.method == 'ext.flutter.evict')
            .map((c) => c.args?['value']),
        unorderedEquals([
          'assets/logo.png',
          'assets/b.png',
          'AssetManifest.bin',
        ]),
      );
    });

    test('points the engine at the devFS only once per connection', () async {
      // The directory does not move, and every extra call rebuilds the
      // engine's asset manager.
      final (client, fake) = await connected();

      await client.reloadAssets({'assets/logo.png'});
      await client.reloadAssets({'assets/logo.png'});

      expect(
        fake.methodCalls
            .where((c) => c.method == '_flutter.setAssetBundlePath')
            .length,
        1,
      );
    });

    test('asks the engine to re-register fonts when a font changed', () async {
      // Evicting drops the framework's copy of the bytes; only the engine
      // holds the registered font families that text renders from.
      File(
        p.join(assetsDir, 'assets', 'Inter.ttf'),
      ).writeAsStringSync('font bytes');
      final (client, fake) = await connected();

      await client.reloadAssets({'assets/Inter.ttf'});

      final reload = fake.methodCalls.firstWhere(
        (c) => c.method == '_flutter.reloadAssetFonts',
      );
      expect(reload.args, {'viewId': 'view-1'});
      expect(reload.isolateId, 'iso-1');
    });

    test('leaves the font collection alone when no font changed', () async {
      final (client, fake) = await connected();

      await client.reloadAssets({'assets/logo.png'});

      expect(
        fake.methodCalls.map((c) => c.method),
        isNot(contains('_flutter.reloadAssetFonts')),
      );
    });

    test('a deleted asset is evicted without an upload', () async {
      // devFS has no delete, so the app falls back to its shipped copy. What
      // must not happen is a failed upload of a file that is gone.
      final (client, fake) = await connected();

      expect(
        await client.reloadAssets({'assets/gone.png'}),
        isA<VerdictApplied>(),
      );
      expect(
        fake.extensionCalls
            .where((c) => c.method == 'ext.flutter.evict')
            .map((c) => c.args?['value']),
        ['assets/gone.png'],
      );
    });

    test(
      'an eviction that fails after the bytes went up is not a refusal',
      () async {
        // The uploads are the delivery, and the evictions are what make the app
        // re-read them. Failing partway through the second half leaves an app
        // that may already be showing some of the new assets, so "it keeps
        // showing the assets it already had" is not something this can say.
        final (client, fake) = await connected();
        fake.extensionErrors['ext.flutter.evict'] = RPCError(
          'ext.flutter.evict',
          113,
          'Isolate must be runnable',
        );

        final verdict = await client.reloadAssets({'assets/logo.png'});

        expect(verdict, isA<VerdictAppErrored>());
        expect(
          (verdict as VerdictAppErrored).error.description,
          contains('Isolate must be runnable'),
        );
        expect(
          File(
            p.join(devFSRoot, 'flutter_assets', 'assets', 'logo.png'),
          ).existsSync(),
          isTrue,
          reason: 'the bytes reached the devFS before the eviction failed',
        );
      },
    );

    test('a failure before any upload is still a refusal', () async {
      // The other side of the same boundary: `_flutter.listViews` throwing is
      // a failure with nothing delivered, and nothing to have to claim about.
      final fake =
          FakeVmService(
              isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
            )
            ..devFSUri = Uri.directory(devFSRoot).toString()
            ..methodErrors['_flutter.listViews'] = RPCError(
              '_flutter.listViews',
              -32000,
              'Service protocol unavailable.',
            );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);
      client.assetDirectory = assetsDir;

      expect(
        await client.reloadAssets({'assets/logo.png'}),
        isA<VerdictRefused>(),
      );
      expect(
        fake.extensionCalls.map((c) => c.method),
        isNot(contains('ext.flutter.evict')),
      );
    });

    test('a devFS the VM would not create fails the reload', () async {
      // Carrying on would evict the app's good copy and put nothing in its
      // place — a reload that makes the app worse and reports success.
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);
      client.assetDirectory = assetsDir;

      expect(
        await client.reloadAssets({'assets/logo.png'}),
        isA<VerdictRefused>(),
      );
      expect(
        fake.extensionCalls.map((c) => c.method),
        isNot(contains('ext.flutter.evict')),
      );
    });

    test('refuses to run without an asset directory', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..devFSUri = Uri.directory(devFSRoot).toString();
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      // A silent no-op here would report the assets as delivered while
      // nothing was ever read off disk.
      expect(
        () => client.reloadAssets({'assets/logo.png'}),
        throwsA(isA<StateError>()),
      );
    });
  });

  /// The main isolate is not a constant. A restart replaces it, and on the
  /// paths where we do not drive the restart ourselves — DWDS's, or a browser
  /// page the user reloaded — the `Isolate` stream is the only notice we get.
  /// Holding the old id is not a degraded state but a dead one: every
  /// subsequent RPC answers `Sentinel(Collected)` / `Unrecognized isolateId`,
  /// forever.
  group('VmServiceClient main-isolate rotation', () {
    final serviceUri = Uri.parse('http://127.0.0.1:8181/');

    test(
      'follows the root isolate across a restart it did not initiate',
      () async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        );
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(serviceUri);

        // What DWDS does on hot restart: destroy the isolate, then create one
        // with a fresh id (`chrome_proxy_service.dart:385` then `:331`). The
        // restart runs through DwdsReloadStrategy over this same connection, so
        // nothing calls back into this client.
        fake.emitIsolateExit('iso-1');
        fake.emitIsolateStart('iso-2');
        await pumpEventQueue();

        await client.callServiceExtension('ext.rules_flutter.getText');
        expect(fake.lastIsolateId, 'iso-2');
      },
    );

    test('ignores an isolate that is not the one it is targeting', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      // An app spawning a background isolate (`compute`, `Isolate.spawn`) is
      // ordinary and must not move the target off main.
      fake.emitIsolateStart('iso-worker', name: 'worker');
      fake.emitIsolateExit('iso-worker', name: 'worker');
      await pumpEventQueue();

      await client.callServiceExtension('ext.rules_flutter.getText');
      expect(fake.lastIsolateId, 'iso-1');
    });

    test(
      'stops targeting an isolate that exited with no replacement yet',
      () async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        );
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(serviceUri);

        fake.emitIsolateExit('iso-1');
        await pumpEventQueue();

        // Said plainly rather than sent to a collected isolate and reported as
        // whatever sentinel came back.
        expect(
          () => client.callServiceExtension('ext.rules_flutter.getText'),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('subscribes to the Isolate stream on connect', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      expect(fake.streamListens, contains(EventStreams.kIsolate));
    });

    test('a re-subscribe after reconnect is not an error', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..alreadySubscribedStreams.add(EventStreams.kIsolate);
      final client = VmServiceClient(connector: (_) async => fake);

      // kStreamAlreadySubscribed is what a real VM answers when the stream is
      // still listened to from before; connect must survive it, as it already
      // does for the Extension stream.
      await client.connect(serviceUri);
      expect(client.isConnected, isTrue);
    });
  });

  /// Waiting for an extension to exist before calling it.
  ///
  /// Native registers the agent surface from the engine's pre-main hook, so it
  /// is there before anything could ask. Web has no such hook: the extensions
  /// are registered by the first lines of the generated entrypoint, and DWDS
  /// does not run that until its injected client has connected — which is
  /// seconds after `app.started`. In that window every `ext.*` call, the
  /// framework's own included, answers `-32601 Unknown method`.
  group('VmServiceClient waitForServiceExtension', () {
    final serviceUri = Uri.parse('http://127.0.0.1:8181/');
    const getText = 'ext.rules_flutter.getText';

    test('returns at once for one the isolate already reports', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..extensionRPCs = [getText];
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      expect(await client.waitForServiceExtension(getText), isTrue);
    });

    test('waits for a registration that has not happened yet', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      final waiting = client.waitForServiceExtension(getText);
      await pumpEventQueue();
      fake.emitServiceExtensionAdded('iso-1', getText);

      expect(await waiting, isTrue);
    });

    test('a different extension registering does not end the wait', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      final waiting = client.waitForServiceExtension(
        getText,
        timeout: const Duration(milliseconds: 200),
      );
      await pumpEventQueue();
      fake.emitServiceExtensionAdded('iso-1', 'ext.flutter.reassemble');

      expect(await waiting, isFalse);
    });

    test('says so rather than hanging when it never registers', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      expect(
        await client.waitForServiceExtension(
          getText,
          timeout: const Duration(milliseconds: 200),
        ),
        isFalse,
      );
    });

    // The restart window is the same window again: DDC's `hotRestart` resets
    // the SDK's lazy `_extensions` map, so the new isolate starts with none and
    // re-registers as the regenerated entrypoint runs. A set carried over from
    // the dead isolate would say "already there" and send the call into the gap.
    test('forgets what the previous isolate had registered', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..extensionRPCs = [getText];
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);
      expect(await client.waitForServiceExtension(getText), isTrue);

      // The restarted isolate has not re-registered yet.
      fake.extensionRPCs = const [];
      fake.emitIsolateExit('iso-1');
      fake.emitIsolateStart('iso-2');
      await pumpEventQueue();

      final waiting = client.waitForServiceExtension(getText);
      var answered = false;
      unawaited(waiting.then((_) => answered = true));
      await pumpEventQueue();
      expect(
        answered,
        isFalse,
        reason: 'iso-2 has not registered it, so it must not count',
      );

      fake.emitServiceExtensionAdded('iso-2', getText);
      expect(await waiting, isTrue);
    });

    test('waits through the gap where there is no main isolate at all', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      // Half a rotation: the old isolate is gone and its replacement has not
      // been announced. Answering "no" here would report a moment as a verdict.
      fake.emitIsolateExit('iso-1');
      await pumpEventQueue();

      final waiting = client.waitForServiceExtension(getText);
      var answered = false;
      unawaited(waiting.then((_) => answered = true));
      await pumpEventQueue();
      expect(answered, isFalse);

      fake.emitIsolateStart('iso-2');
      await pumpEventQueue();
      fake.emitServiceExtensionAdded('iso-2', getText);
      expect(await waiting, isTrue);
    });

    test(
      'ignores a background isolate registering the same extension',
      () async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        );
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(serviceUri);

        final waiting = client.waitForServiceExtension(
          getText,
          timeout: const Duration(milliseconds: 200),
        );
        await pumpEventQueue();
        fake.emitServiceExtensionAdded('iso-worker', getText);

        expect(await waiting, isFalse);
      },
    );

    // The seed read is the only source of registrations that already happened
    // — `ServiceExtensionAdded` is not replayed — so a `getIsolate` that fails
    // and is swallowed leaves this waiting for an event that already fired.
    // The timeout then reads as an answer, and both callers state it as one:
    // "the app never brought it up", "the running app never registered X".
    test('raises when it could not read the registrations, rather than '
        'timing out into "never registered"', () async {
      final fake =
          FakeVmService(
              isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
            )
            ..extensionRPCs = [getText]
            ..getIsolateError = RPCError(
              'getIsolate',
              104,
              'stream disconnected',
            );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      // `getText` *is* registered here, so a swallowed seed-read failure would
      // answer false after the full timeout instead of surfacing the error.
      await expectLater(
        client.waitForServiceExtension(
          getText,
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<RPCError>()),
      );
    });

    test(
      'tolerates the read failing for an isolate that has since rotated',
      () async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        );
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(serviceUri);

        // Hold the seed's read open, then rotate under it. What comes back
        // describes iso-1, which is gone — an error about it says nothing about
        // the app, and the replacement's registrations arrive on the stream.
        fake
          ..getIsolateGate = Completer<void>()
          ..getIsolateError = RPCError('getIsolate', 104, 'isolate collected');
        final waiting = client.waitForServiceExtension(
          getText,
          timeout: const Duration(seconds: 5),
        );
        await pumpEventQueue();
        fake.emitIsolateExit('iso-1');
        fake.emitIsolateStart('iso-2');
        await pumpEventQueue();
        fake.getIsolateGate!.complete();
        await pumpEventQueue();

        fake.emitServiceExtensionAdded('iso-2', getText);
        expect(await waiting, isTrue);
      },
    );
  });

  /// `--start-paused` is reported to the user as fact either way: paused, or
  /// "the main isolate is running — whatever a debugger attaches to now has
  /// already executed main()". Both claims need the isolate to have actually
  /// been read, and the poll that reads it swallows its errors by design,
  /// because an in-deadline failure is the connection still settling.
  group('VmServiceClient.waitUntilPausedAtStart', () {
    final serviceUri = Uri.parse('http://127.0.0.1:8181/');

    test('reports paused when the isolate holds at PauseStart', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..pauseKind = EventKind.kPauseStart;
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      expect(
        await client.waitUntilPausedAtStart(),
        StartPausedState.pausedAtStart,
      );
    });

    test(
      'reports running when it read the isolate and it never paused',
      () async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        )..pauseKind = EventKind.kResume;
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(serviceUri);

        expect(
          await client.waitUntilPausedAtStart(
            timeout: const Duration(milliseconds: 200),
          ),
          StartPausedState.running,
        );
      },
    );

    test('reports unknown when no poll ever read the isolate', () async {
      final fake =
          FakeVmService(
              isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
            )
            ..pauseKind = EventKind.kPauseStart
            ..getIsolateError = RPCError(
              'getIsolate',
              104,
              'stream disconnected',
            );
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri);

      // The isolate is in fact paused at start. Nothing here saw that, so the
      // one answer this must not give is `running` — the launcher turns that
      // into a severe telling the user main() has already executed.
      expect(
        await client.waitUntilPausedAtStart(
          timeout: const Duration(milliseconds: 200),
        ),
        StartPausedState.unknown,
      );
    });
  });

  /// A first frame is what makes an app drivable: the framework is up, so its
  /// service extensions — the `ext.rules_flutter.*` agent surface among them —
  /// are registered. Two things can say so, and they are not interchangeable.
  ///
  /// `didSendFirstFrameEvent` is a latched query, so it is the only one that
  /// can answer for a frame that happened before anyone was listening. Its
  /// rasterized twin is the wrong question, because rasterization is about a
  /// display and can stay false in a running, answering app.
  /// `Flutter.FirstFrame` is the only one that can arrive while the VM is
  /// answering no requests at all. Waiting on either alone leaves one of those
  /// cases hanging.
  group('VmServiceClient.waitForFirstFrame', () {
    final serviceUri = Uri.parse('http://127.0.0.1:8181/');

    FakeVmService newFake() => FakeVmService(
      isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
    );

    Future<VmServiceClient> connected(FakeVmService fake) async {
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri, createDevFS: false);
      return client;
    }

    test('true when the app painted before anyone asked', () async {
      final fake = newFake();
      fake.extensionResponses['ext.flutter.didSendFirstFrameEvent'] = {
        'enabled': 'true',
      };
      final client = await connected(fake);

      expect(await client.waitForFirstFrame(), isTrue);
    });

    test('true on the event alone, with the query never answered', () async {
      final fake = newFake();
      final client = await connected(fake);
      // Every extension call from here on hangs: the app is up but its VM is
      // answering nothing, which is exactly the window this has to see through.
      fake.callServiceExtensionGate = Completer<void>();

      final waiting = client.waitForFirstFrame(
        timeout: const Duration(seconds: 30),
      );
      await pumpEventQueue();
      fake.emitFirstFrame();

      expect(await waiting, isTrue);
      fake.callServiceExtensionGate!.complete();
    });

    /// The web ordering, which a single ask cannot survive.
    ///
    /// `Flutter.FirstFrame` is posted from the framework's frame-*timings*
    /// callback, and the web engine flushes timings only while rasterizing a
    /// frame. An app that paints its startup frames and then sits still never
    /// rasterizes again, so the event never comes. The query is the only thing
    /// left, and at the handover it answers `-32601` because the framework has
    /// not registered it yet — so it has to be asked again rather than once.
    test(
      'true from the query alone, first -32601 then false then true',
      () async {
        final fake = newFake();
        const method = 'ext.flutter.didSendFirstFrameEvent';
        fake.extensionErrors[method] = RPCError(
          method,
          -32601,
          'Unknown method',
        );
        final client = await connected(fake);

        final waiting = client.waitForFirstFrame(
          timeout: const Duration(seconds: 20),
        );

        Future<void> afterCalls(int n) async {
          while (fake.extensionCalls.where((c) => c.method == method).length <
              n) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        // The framework registers the extension: no longer an error, not yet
        // painted.
        await afterCalls(2);
        fake.extensionErrors.remove(method);
        fake.extensionResponses[method] = {'enabled': 'false'};

        // And then it paints. No event is ever emitted.
        await afterCalls(3);
        fake.extensionResponses[method] = {'enabled': 'true'};

        expect(await waiting, isTrue);
      },
    );

    /// A `-32601` is the boot sequence; anything else is a fault, and reporting
    /// it as "the app never rendered" sends the reader after the wrong thing.
    test('a non -32601 query error surfaces instead of a bare false', () async {
      final fake = newFake();
      const method = 'ext.flutter.didSendFirstFrameEvent';
      fake.extensionErrors[method] = RPCError(
        method,
        -32000,
        'Service disposed',
      );
      final client = await connected(fake);

      await expectLater(
        client.waitForFirstFrame(timeout: const Duration(milliseconds: 500)),
        throwsA(isA<RPCError>()),
      );
    });

    test(
      'false at the bound when the query hangs and nothing paints',
      () async {
        final fake = newFake();
        final client = await connected(fake);
        fake.callServiceExtensionGate = Completer<void>();

        final elapsed = Stopwatch()..start();
        final answer = await client.waitForFirstFrame(
          timeout: const Duration(milliseconds: 200),
        );
        elapsed.stop();

        expect(answer, isFalse);
        expect(
          elapsed.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason:
              'the bound is the bound: a query the app never answers must not '
              'hold the wait open past it, or the caller that sized the budget '
              'gets a wait it did not ask for and a false that is not true yet',
        );
        fake.callServiceExtensionGate!.complete();
      },
    );

    /// The precondition every framework-extension caller shares. Asking whether
    /// an extension is registered and then calling it regardless makes a
    /// `-32601` ambiguous: a framework still starting and a framework that will
    /// never register it give the same error, and call sites are left guessing.
    group('VmServiceClient.requireServiceExtension', () {
      final serviceUri = Uri.parse('http://127.0.0.1:8181/');

      Future<VmServiceClient> connected(FakeVmService fake) async {
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(serviceUri, createDevFS: false);
        return client;
      }

      test('returns once the app has the extension', () async {
        final client = await connected(
          FakeVmService(
            isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          )..extensionRPCs = ['ext.flutter.evict'],
        );

        await client.requireServiceExtension('ext.flutter.evict');
      });

      test(
        'throws, naming the extension and the wait, when it never comes',
        () async {
          final client = await connected(
            FakeVmService(
              isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
            )..extensionRPCs = const [],
          );
          client.serviceExtensionTimeout = const Duration(milliseconds: 200);

          await expectLater(
            client.requireServiceExtension('ext.flutter.evict'),
            throwsA(
              isA<ServiceExtensionUnavailable>()
                  .having((e) => e.method, 'method', 'ext.flutter.evict')
                  .having(
                    (e) => e.toString(),
                    'message',
                    contains('not registered'),
                  ),
            ),
          );
        },
      );

      test('waits for a registration that arrives late', () async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        )..extensionRPCs = const [];
        final client = await connected(fake);
        client.serviceExtensionTimeout = const Duration(seconds: 5);

        final waiting = client.requireServiceExtension('ext.flutter.evict');
        await pumpEventQueue();
        fake.emitServiceExtensionAdded('iso-1', 'ext.flutter.evict');

        await waiting;
      });
    });
  });
}
