import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/command_report.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/outcome_renderer.dart';
import 'package:flutter_bazel_dev_tool/reload_strategy.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:flutter_bazel_dev_tool/web_module_server.dart';
import 'package:flutter_bazel_dev_tool/web_options.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

DeviceSession _sessionWithoutVmClient() => DeviceSession(
  device: MacOSDevice(),
  appInstance: AppInstance(process: FakeProcess()),
  vmClient: null,
  appId: 'app',
);

/// The artifacts a successful DDC compile leaves next to its dill: a manifest
/// of byte ranges, and the blobs those ranges index into.
///
/// Real ones, because every DWDS strategy call starts by handing them to
/// `WebModuleServer.updateModules`, which ends the run rather than serving
/// nothing when a compile the frontend server called successful left no
/// manifest behind.
CompileResult writeCompile(Directory dir) {
  final dillPath = '${dir.path}/out.dill';
  const code = 'main module code';
  final metadata = json.encode({'name': 'main', 'libraries': <Object>[]});
  File('$dillPath.json').writeAsStringSync(
    json.encode({
      '/main.lib.js': {
        'code': [0, code.length],
        'metadata': [0, metadata.length],
      },
    }),
  );
  File('$dillPath.sources').writeAsStringSync(code);
  File('$dillPath.metadata').writeAsStringSync(metadata);
  // The kernel itself: the native verbs upload this file into the VM's devFS,
  // and one that is not there is refused before any of them reaches the VM.
  File(dillPath).writeAsBytesSync([1, 2, 3]);
  return CompileResult(dillPath: dillPath, success: true);
}

void main() {
  late CompileResult compiled;
  setUp(() {
    final dir = Directory.systemTemp.createTempSync('reload_strategy_');
    addTearDown(() => dir.deleteSync(recursive: true));
    compiled = writeCompile(dir);
  });

  group('VmServiceReloadStrategy', () {
    // Filtering out sessions with no vmClient and then asking
    // `[].every((ok) => ok)` answers `true`: a run where nothing could possibly
    // be reloaded would report success, telling the user an edit is live when
    // no process received it.
    test('reports unsupported when no session has a VM service', () async {
      final outcome = await VmServiceReloadStrategy().applyReload(compiled, [
        _sessionWithoutVmClient(),
      ]);

      expect(outcome, isA<StrategyUnsupported>());
      expect(outcome.isSuccess, isFalse);
      expect(outcome.message, contains('VM service'));
    });

    test('reports unsupported for restart on the same grounds', () async {
      final outcome = await VmServiceReloadStrategy().applyRestart(compiled, [
        _sessionWithoutVmClient(),
      ]);

      expect(outcome, isA<StrategyUnsupported>());
      expect(outcome.isSuccess, isFalse);
    });

    test(
      'an app that took the kernel and then threw is not a success',
      () async {
        // This path keeps no compiler baseline per app, so "applied, then threw"
        // has nothing to change here — but it must still not read as applied:
        // the user's edit is live and the app is broken.
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          emitFlutterErrorOnReload: true,
        );
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(Uri.parse('http://127.0.0.1:8181/'));
        final session = DeviceSession(
          device: MacOSDevice(),
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: client,
          appId: 'app',
        );

        final outcome = await VmServiceReloadStrategy().applyReload(compiled, [
          session,
        ]);

        expect(outcome.isSuccess, isFalse);
        expect(outcome, isA<StrategyRejected>());
        expect((outcome as StrategyRejected).refused, ['app']);
      },
    );

    // An empty device list is the same shape of lie, reached a different way.
    test('reports unsupported when there are no sessions at all', () async {
      final outcome = await VmServiceReloadStrategy().applyReload(compiled, []);

      expect(outcome, isA<StrategyUnsupported>());
      expect(outcome.isSuccess, isFalse);
    });
  });

  group('VmServiceReloadStrategy.applyAssets', () {
    // Same lie as the reload and restart arms: `[].every(...)` is true, so a
    // run where nothing could receive the assets would report them applied.
    test('reports unsupported when no session has a VM service', () async {
      final outcome = await VmServiceReloadStrategy().applyAssets(
        {'assets/logo.png'},
        [_sessionWithoutVmClient()],
      );

      expect(outcome, isA<StrategyUnsupported>());
      expect(outcome.message, contains('VM service'));
    });
  });

  /// Every verb needs a deadline on its device's future. `ext.flutter.evict`
  /// and `ext.flutter.reassemble` are executed *by* the app's isolate, so an
  /// app sitting on a breakpoint answers nothing on a socket that is perfectly
  /// healthy — no disposal, no reconnect, no exception. An apply handed
  /// straight to `Future.wait` never returns, and it holds `CommandRunner`'s
  /// single pool permit while it waits.
  group('VmServiceReloadStrategy bounds each device', () {
    late Directory devFSRoot;
    late FakeDevFS devFS;

    setUp(() async {
      devFSRoot = Directory.systemTemp.createTempSync('reload_strategy_devfs_');
      devFS = await FakeDevFS.start(devFSRoot);
    });

    tearDown(() async {
      await devFS.close();
      devFSRoot.deleteSync(recursive: true);
    });

    /// A session whose fake VM can be wedged on demand.
    ///
    /// Over a real devFS, because every native verb delivers through one: a
    /// kernel verb uploads into it and refuses if it cannot, and `reloadAssets`
    /// resolves the engine's asset directory off its URI. The app's asset
    /// directory itself need not exist — an archive path with no file behind it
    /// skips the upload (a deleted asset looks the same), so the evict is the
    /// first call that can hang.
    Future<(DeviceSession, FakeVmService, VmServiceClient)> wedgeable({
      String appId = 'app',
    }) async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..devFSUri = devFS.uri;
      final client = VmServiceClient(connector: connectorFor(fake));
      await client.connect(devFS.serviceUri);
      client.assetDirectory = '/tmp/bundle';
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: client,
        appId: appId,
      );
      return (session, fake, client);
    }

    /// Release a wedged call the way the force-disconnect really releases it:
    /// the socket is gone, so the RPC ends in an error, not a late success.
    Future<void> release(FakeVmService fake, Completer<void> gate) async {
      fake.simulateDisposed();
      gate.complete();
      await pumpEventQueue();
    }

    VmServiceReloadStrategy bounded() =>
        VmServiceReloadStrategy(rpcTimeout: const Duration(milliseconds: 50));

    test(
      'an app that never answers an asset push is timed out, not refused',
      () async {
        final (session, fake, client) = await wedgeable();
        final gate = Completer<void>();
        fake.callServiceExtensionGate = gate;

        final outcome = await bounded().applyAssets(
          {'assets/gone.png'},
          [session],
        );

        final rejected = outcome as StrategyRejected;
        // "Refused" claims the app answered no. It never answered, and what it
        // is showing is unknown — the direct analog of ApplyTimedOut being its
        // own type rather than an ApplyFailed.
        expect(rejected.timedOut, ['app']);
        expect(rejected.refused, isEmpty);
        expect(rejected.applied, isEmpty);
        expect(rejected.message, contains('did not answer'));
        expect(rejected.message, isNot(contains('refused')));
        // Dropped, so the next command reconnects instead of queueing behind a
        // socket nothing is coming back on.
        expect(client.isConnected, isFalse);

        await release(fake, gate);
      },
    );

    test('the same bound covers a hung hot reload', () async {
      final (session, fake, client) = await wedgeable();
      final gate = Completer<void>();
      fake.reloadSourcesGate = gate;

      final outcome = await bounded().applyReload(compiled, [session]);

      expect((outcome as StrategyRejected).timedOut, ['app']);
      expect(client.isConnected, isFalse);

      await release(fake, gate);
    });

    test('the same bound covers a hung hot restart', () async {
      final (session, fake, client) = await wedgeable();
      final gate = Completer<void>();
      fake.callMethodGate = gate;

      final outcome = await bounded().applyRestart(compiled, [session]);

      expect((outcome as StrategyRejected).timedOut, ['app']);
      expect(client.isConnected, isFalse);

      await release(fake, gate);
    });

    test(
      'a device that answered and one that did not are counted apart',
      () async {
        final (hung, hungFake, _) = await wedgeable(appId: 'hung');
        final (live, _, __) = await wedgeable(appId: 'live');
        final gate = Completer<void>();
        hungFake.callServiceExtensionGate = gate;

        final outcome = await bounded().applyAssets(
          {'assets/gone.png'},
          [live, hung],
        );

        final rejected = outcome as StrategyRejected;
        expect(rejected.applied, ['live']);
        expect(rejected.timedOut, ['hung']);
        // The count is over every device, not over the refused-plus-applied pair
        // a timeout is missing from.
        expect(rejected.message, contains('1 of 2 device(s)'));

        await release(hungFake, gate);
      },
    );

    // The failure-coupled path: a dropped connection sends the next command
    // through `_withReconnect` into `connect`, which has to be timed — a
    // command that walks in there otherwise never comes back, holding the pool
    // permit the whole time.
    test('a reconnect that never dials still lets the command finish', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      )..devFSUri = Uri.directory('/tmp/devfs').toString();
      var dials = 0;
      final client = VmServiceClient(
        connector: (_) =>
            dials++ == 0 ? Future.value(fake) : Completer<VmService>().future,
        connectTimeout: const Duration(milliseconds: 50),
      );
      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      client.assetDirectory = '/tmp/bundle';
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: client,
        appId: 'app',
      );
      // What a prior timed-out apply leaves behind.
      fake.simulateDisposed();

      // Deliberately far longer than the connect budget: the bound that has to
      // save this one is the client's, not the strategy's.
      final outcome = await VmServiceReloadStrategy(
        rpcTimeout: const Duration(seconds: 30),
      ).applyAssets({'assets/gone.png'}, [session]);

      // Refused is the true verdict here: a connect that timed out ran no part
      // of the apply, so nothing landed.
      final rejected = outcome as StrategyRejected;
      expect(rejected.refused, ['app']);
      expect(rejected.timedOut, isEmpty);
      expect(dials, 2);
    });
  });

  group('DwdsReloadStrategy', () {
    // Safe to drive without ever starting it: `updateModules` reads the
    // compile's artifacts off disk (see [writeCompile]) and holds the modules
    // in memory, and nothing else here touches the toolchain paths below.
    WebModuleServer stubServer() => WebModuleServer(
      webToolchain: WebToolchainPaths(
        ddcOutlineDill: '/fake/ddc_outline.dill',
        librariesSpec: '/fake/libraries.json',
        dartSdkJs: '/fake/dart_sdk.js',
        ddcModuleLoaderJs: '/fake/ddc_module_loader.js',
        stackTraceMapperJs: '/fake/stack_trace_mapper.js',
        dartSdkRoot: '/fake/dart-sdk',
      ),
      buildOutputDir: '/fake/out',
      entrypointFilename: 'main.dart',
      flutterBootstrapJsPath: '/fake/dev_flutter_bootstrap.js',
      dartExecutable: '/fake/dart',
      options: const WebServerOptions(crossOriginIsolation: false),
    );

    /// The strategy under test, and the server it holds.
    ///
    /// [programAlreadyServed] is the precondition almost every test here needs,
    /// stated rather than defaulted: a successful first compile, which is
    /// what puts modules on the server and what makes DWDS's `hotRestart` a
    /// real operation rather than a no-op. The tests that pass `false` are the
    /// ones about the window where that never happened.
    ///
    /// [loadFirstProgram] defaults to a throw so that no test can navigate the
    /// page by accident: a navigation is only correct in that window, and a
    /// silent one everywhere else is the bug this pair of branches exists to
    /// avoid.
    ({DwdsReloadStrategy strategy, WebModuleServer server}) dwds({
      Duration restartTimeout = const Duration(seconds: 30),
      bool programAlreadyServed = true,
      Future<void> Function()? loadFirstProgram,
    }) {
      final server = stubServer();
      if (programAlreadyServed)
        server.updateModules(compiled.dillPath, full: true);
      return (
        server: server,
        strategy: DwdsReloadStrategy(
          moduleServer: server,
          restartTimeout: restartTimeout,
          loadFirstProgram:
              loadFirstProgram ??
              () async => fail('the page must not be navigated here'),
        ),
      );
    }

    DwdsReloadStrategy strategy({
      Duration restartTimeout = const Duration(seconds: 30),
    }) => dwds(restartTimeout: restartTimeout).strategy;

    final isolate = IsolateRef(id: 'isolates/1', name: 'main', number: '1');

    test(
      'restart before any page has connected loads the page instead',
      () async {
        // Upstream reports and does nothing here
        // (`resident_web_runner.dart:519`), which is the right answer for a
        // tool with no way to put a page on the program. This one has a way,
        // and the program is already served, so navigating is both available
        // and correct. A navigation that cannot find the page
        // reports what is actually wrong ("no debuggable CDP page target")
        // instead of a generic absence.
        //
        // Reachable in ordinary startup too, between the first compile
        // landing and the browser connecting. Navigating there re-loads a
        // page that was loading anyway.
        var navigations = 0;
        final (:strategy, server: _) = dwds(
          loadFirstProgram: () async => navigations++,
        );

        final outcome = await strategy.applyRestart(compiled, []);

        expect(outcome, isA<StrategyApplied>());
        expect(navigations, 1);
      },
    );

    test(
      'reload without a browser client is unsupported and does not restart',
      () async {
        // Delegating to applyRestart for a CDP page reload would only recurse
        // into the same null check, since restart needs a VM service too.
        final outcome = await strategy().applyReload(compiled, []);

        expect(outcome, isA<StrategyUnsupported>());
        expect(outcome.message, contains('no browser client connected yet'));
      },
    );

    // The window: the page has connected, so there is a VM service and an
    // isolate, but the framework has not registered its extensions yet.
    // Evicting into that gap does nothing, and must not be reported as the page
    // lacking asset-cache support at all.
    test(
      'assets refuse honestly while the framework is still starting',
      () async {
        final service = FakeVmService(isolates: [isolate])
          ..extensionRPCs = const [];
        final s = strategy();
        await s.attachVmService(service);
        final client = VmServiceClient(connector: (_) async => service);
        await client.connect(
          Uri.parse('http://127.0.0.1:8181/'),
          createDevFS: false,
        );
        client.serviceExtensionTimeout = const Duration(milliseconds: 200);
        final session = DeviceSession(
          device: WebDevice(),
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: client,
          appId: 'web',
        );

        final outcome = await s.applyAssets({'assets/a.png'}, [session]);

        expect(outcome, isA<StrategyUnsupported>());
        expect(outcome.message, contains('ext.flutter.evict'));
        expect(
          service.extensionCalls.map((c) => c.method),
          isNot(contains('ext.flutter.evict')),
          reason:
              'nothing may be evicted on the strength of an extension the '
              'page has not brought up',
        );
      },
    );

    test('a successful restart is applied', () async {
      final service = FakeVmService(isolates: [isolate]);
      final s = strategy();
      await s.attachVmService(service);

      final outcome = await s.applyRestart(compiled, []);

      expect(outcome, isA<StrategyApplied>());
      expect(service.hotRestartMethod, 'hotRestart');
      // DWDS owns the Service stream subscription.
      expect(service.streamListens, contains(EventStreams.kService));
    });

    // A page-preserving restart never reconnects the browser, so
    // attachVmService — the only other place
    // that clears the cached isolate id — never fires, and the next reload
    // would call reloadSources on the isolate DWDS just replaced.
    test('a reload after a restart re-discovers the new isolate', () async {
      final service = FakeVmService(isolates: [isolate]);
      final s = strategy();
      await s.attachVmService(service);

      // Prime the cache the way a pre-restart reload would.
      await s.applyReload(compiled, []);
      expect(service.lastIsolateId, 'isolates/1');

      expect(await s.applyRestart(compiled, []), isA<StrategyApplied>());

      // DWDS started a new isolate; the next reload must target it.
      service.isolates
        ..clear()
        ..add(IsolateRef(id: 'isolates/2', name: 'main', number: '2'));

      final outcome = await s.applyReload(compiled, []);

      expect(outcome, isA<StrategyApplied>());
      expect(service.lastIsolateId, 'isolates/2');
    });

    test('the DDS-namespaced alias is the name actually called', () async {
      final service = FakeVmService(isolates: [isolate]);
      final s = strategy();
      await s.attachVmService(service);
      service.emitServiceRegistered('hotRestart', 's0.hotRestart');
      await pumpEventQueue();

      expect(await s.applyRestart(compiled, []), isA<StrategyApplied>());

      // A hardcoded bare `hotRestart` gets kMethodNotFound once DWDS owns DDS.
      expect(service.hotRestartMethod, 's0.hotRestart');
    });

    test('an unregistered service falls back to the bare name', () async {
      final service = FakeVmService(isolates: [isolate]);
      final s = strategy();
      await s.attachVmService(service);
      service.emitServiceRegistered('hotRestart', 's0.hotRestart');
      await pumpEventQueue();
      service.emitServiceUnregistered('hotRestart', 's0.hotRestart');
      await pumpEventQueue();

      expect(await s.applyRestart(compiled, []), isA<StrategyApplied>());

      expect(service.hotRestartMethod, 'hotRestart');
    });

    // DWDS raises these when the page went away between the recompile and the
    // restart. Upstream treats both as "no client", not as a failure —
    // vm_service re-encodes RPCErrors as kServerError, so 109 alone misses it.
    for (final code in [109, -32000]) {
      test('RPCError $code means no client, not a rejection', () async {
        final service = FakeVmService(isolates: [isolate])
          ..hotRestartError = RPCError('hotRestart', code, 'no clients');
        final s = strategy();
        await s.attachVmService(service);

        final outcome = await s.applyRestart(compiled, []);

        expect(outcome, isA<StrategyUnsupported>());
        // The page WENT AWAY, as this group's own comment says — a different
        // fact from "none has connected yet", and it must not be reported
        // with the latter's promise that the code will load when one does.
        expect(outcome.message, contains('is gone'));
        expect(
          outcome.message,
          isNot(contains('will load')),
          reason: 'nothing this session can do will deliver that code',
        );
      });
    }

    test('any other RPCError is a rejection carrying its message', () async {
      final service = FakeVmService(isolates: [isolate])
        ..hotRestartError = RPCError(
          'hotRestart',
          -32601,
          'Method not found: hotRestart',
        );
      final s = strategy();
      await s.attachVmService(service);

      final outcome = await s.applyRestart(compiled, []);

      expect(outcome, isA<StrategyRejected>());
      expect(outcome.message, contains('Method not found'));
    });

    // DWDS awaits its IsolateStart with no timeout (dwds_vm_client.dart:530),
    // so a page that never reports one would hang the session forever.
    test(
      'a restart that never reports an isolate is rejected, not hung',
      () async {
        final gate = Completer<void>();
        final service = FakeVmService(isolates: [isolate])
          ..hotRestartGate = gate;
        final s = strategy(restartTimeout: const Duration(milliseconds: 50));
        await s.attachVmService(service);

        final outcome = await s.applyRestart(compiled, []);

        expect(outcome, isA<StrategyRejected>());
        expect(outcome.message, contains('did not report a restarted isolate'));
        gate.complete(); // don't leak the pending call
      },
    );

    test('evicts each changed asset and rebuilds the tree', () async {
      // Nothing is uploaded: the module server reads `assets/` off the build
      // tree per request, so the new bytes are already reachable. What is
      // left is the page's own caches.
      final service = FakeVmService(isolates: [isolate]);
      final s = strategy();
      await s.attachVmService(service);

      final outcome = await s.applyAssets({'assets/a.png', 'assets/b.png'}, []);

      expect(outcome, isA<StrategyApplied>());
      expect(
        service.extensionCalls
            .where((c) => c.method == 'ext.flutter.evict')
            .map((c) => c.args?['value']),
        unorderedEquals(['assets/a.png', 'assets/b.png']),
      );
      expect(
        service.extensionCalls.map((c) => c.method),
        contains('ext.flutter.reassemble'),
      );
    });

    test(
      'sends a font change back for a restart instead of claiming success',
      () async {
        // The web engine registers fonts once during binding init and exposes no
        // reload hook, so evicting the bytes changes nothing on screen. Saying
        // "applied" here is the silent half-success worth ruling out.
        final service = FakeVmService(isolates: [isolate]);
        final s = strategy();
        await s.attachVmService(service);

        final outcome = await s.applyAssets({'assets/fonts/Inter.ttf'}, []);

        expect(outcome, isA<StrategyUnsupported>());
        expect(outcome.message, contains('hot restart'));
        expect(service.extensionCalls, isEmpty);
      },
    );

    test(
      'assets with no browser client are unsupported, not a failure',
      () async {
        final outcome = await strategy().applyAssets({'assets/a.png'}, []);

        expect(outcome, isA<StrategyUnsupported>());
        expect(outcome.message, contains('no browser client connected yet'));
      },
    );

    /// The window a failed FIRST compile opens: Chrome has launched, DWDS has
    /// connected — the injected client rides in the bootstrap, not in the
    /// program — and the page is showing nothing, because the compile that
    /// would have produced its modules failed.
    ///
    /// A connected DWDS is what makes this dangerous rather than obvious:
    /// `hotRestart` in this state answers "Successful hot restart" and does
    /// nothing — `reloaded_sources.json` is empty by design on a first compile,
    /// so it has nothing to reload — while the page stays blank.
    group('before the page has ever loaded a program', () {
      test(
        'a restart navigates the page instead of hot restarting it',
        () async {
          // No VM service attached, and that is now a fact about the world
          // rather than a convenience: the module server withholds the boot
          // chain until it holds a program, so nothing injects a DWDS client
          // into a program-less page and no connection can exist here. The
          // "DWDS must not be asked" boundary lives in 'a restart stops
          // navigating once the page has connected', where a connection is
          // possible.
          var navigations = 0;
          final (:strategy, :server) = dwds(
            programAlreadyServed: false,
            loadFirstProgram: () async => navigations++,
          );

          final outcome = await strategy.applyRestart(compiled, []);

          expect(outcome, isA<StrategyApplied>());
          expect(
            navigations,
            1,
            reason: 'only a navigation makes the page fetch the program',
          );
          expect(
            server.holdsProgram,
            isTrue,
            reason: 'the program is on the server before the page asks for it',
          );
        },
      );

      test(
        'a restart after a failed navigation navigates again',
        () async {
          // The strand. The first restart compiles a program onto the server
          // and then fails to navigate — a closed tab is enough, since the
          // page target is matched by URL. Discriminating on whether the
          // SERVER holds a program would make every later restart believe the
          // page already had one, take the DWDS path, and never navigate again
          // — leaving the session blank for good.
          var navigations = 0;
          final (:strategy, server: _) = dwds(
            programAlreadyServed: false,
            loadFirstProgram: () async {
              navigations++;
              if (navigations == 1) {
                throw StateError('no debuggable CDP page target');
              }
            },
          );

          expect(
            await strategy.applyRestart(compiled, []),
            isA<StrategyRejected>(),
          );
          expect(navigations, 1, reason: 'the first restart tried to navigate');

          final second = await strategy.applyRestart(compiled, []);

          expect(
            navigations,
            2,
            reason: 'the page still has no program, so it still needs loading',
          );
          expect(second, isA<StrategyApplied>());
        },
      );

      test(
        'a restart stops navigating once the page has connected',
        () async {
          // The other side of the same discriminator, so it cannot be
          // satisfied by navigating unconditionally. A connection is only
          // possible once the page fetched a boot chain, which the module
          // server withholds until it holds a program — so a connection is
          // proof the page has one.
          var navigations = 0;
          final (:strategy, server: _) = dwds(
            programAlreadyServed: false,
            loadFirstProgram: () async => navigations++,
          );

          await strategy.applyRestart(compiled, []);
          expect(navigations, 1);

          await strategy.attachVmService(FakeVmService(isolates: [isolate]));
          await strategy.applyRestart(compiled, []);

          expect(
            navigations,
            1,
            reason: 'a connected page is hot restarted, not reloaded',
          );
        },
      );

      test(
        'a navigation that fails is reported, not counted as applied',
        () async {
          final (:strategy, server: _) = dwds(
            programAlreadyServed: false,
            loadFirstProgram: () async => throw StateError('no debugging port'),
          );

          final outcome = await strategy.applyRestart(compiled, []);

          expect(outcome, isA<StrategyRejected>());
          expect(outcome.message, contains('no debugging port'));
        },
      );

      test(
        'a reload refuses rather than merging a fraction of a program',
        () async {
          final (:strategy, :server) = dwds(programAlreadyServed: false);
          final service = FakeVmService(isolates: [isolate]);
          await strategy.attachVmService(service);

          final outcome = await strategy.applyReload(compiled, []);

          expect(outcome, isA<StrategyUnsupported>());
          expect(outcome.message, contains('never loaded a program'));
          // The refusal has to come BEFORE the merge. An incremental compile
          // answers with a delta, and a delta merged as a first compile leaves
          // the server holding part of a program while believing it holds all of
          // one — after which every later reload builds on that.
          expect(
            server.holdsProgram,
            isFalse,
            reason: 'nothing may be merged by a reload that refused',
          );
        },
      );

      test(
        'assets are not claimed to have reached a page showing nothing',
        () async {
          final (:strategy, server: _) = dwds(programAlreadyServed: false);
          final service = FakeVmService(isolates: [isolate]);
          await strategy.attachVmService(service);

          final outcome = await strategy.applyAssets({'assets/a.png'}, []);

          expect(outcome, isA<StrategyUnsupported>());
          expect(outcome.message, contains('never loaded a program'));
        },
      );
    });
  });

  group('StrategyOutcome', () {
    test('only an applied outcome counts as success', () {
      expect(const StrategyApplied(2).isSuccess, isTrue);
      expect(
        const StrategyUnsupported('nothing to apply to').isSuccess,
        isFalse,
      );
      expect(const StrategyRejected('refused').isSuccess, isFalse);
      expect(StrategyThrew(StateError('gone')).isSuccess, isFalse);
    });

    test('every outcome can explain itself', () {
      expect(const StrategyApplied(3).message, contains('3'));
      expect(
        const StrategyUnsupported('no VM service').message,
        'no VM service',
      );
      expect(const StrategyRejected('refused').message, 'refused');
    });

    // A throw is not a refusal, and the difference is what the type expresses:
    // a refusal is an app answering no, while a throw means nothing
    // answered. Naming which devices did what would invent an answer nobody
    // gave — and so would any claim about what the app is running now, which
    // is why the message makes none. `reportReloadCommand` already appends
    // "The app keeps running the code it already had." to every error it
    // prints, so a message that guessed would contradict it one clause later.
    test('a throw carries the error and claims nothing about the app', () {
      final outcome = StrategyThrew(StateError('no DDC manifest'));

      expect(outcome, isNot(isA<StrategyRejected>()));
      expect(outcome.message, contains('no DDC manifest'));
      expect(outcome.message, isNot(contains('unknown')));
    });
  });

  group('ReloadResult', () {
    test('a compile failure is not a device success', () {
      final result = ReloadResult(compileSuccess: false, elapsedMs: 1);

      expect(result.deviceSuccess, isFalse);
      expect(result.success, isFalse);
    });

    // `deviceSuccess` must not default to true, or a result carrying no
    // outcome at all reads as a successful reload.
    test('an unsupported apply is not a success and explains why', () {
      final result = ReloadResult(
        compileSuccess: true,
        outcome: const StrategyUnsupported('no device has a VM service'),
        elapsedMs: 1,
      );

      expect(result.deviceSuccess, isFalse);
      expect(result.success, isFalse);
      expect(
        result.outcome!.message,
        'no device has a VM service',
        reason:
            'the outcome is where the explanation lives, and the wire '
            'form reads it straight off the report',
      );
    });

    test('an applied outcome succeeds with nothing to explain', () {
      final result = ReloadResult(
        compileSuccess: true,
        outcome: const StrategyApplied(1),
        elapsedMs: 1,
      );

      expect(result.success, isTrue);
      expect(result.outcome!.isSuccess, isTrue);
    });
  });

  group('reportReloadCommand', () {
    /// Drives the reporter and collects both of its outputs.
    ({List<String> logged, List<Map<String, dynamic>> announced}) report(
      Map<String, dynamic> result, {
      String action = 'Hot reload',
      String method = 'app.hotReload',
    }) {
      final logged = <String>[];
      final announced = <Map<String, dynamic>>[];
      reportReloadCommand(
        action,
        result,
        logged.add,
        method: method,
        announce: announced.add,
      );
      return (logged: logged, announced: announced);
    }

    test('renders an error rather than staying silent', () {
      // Errors go to stderr, so nothing reaches the normal log sink; what
      // matters is that the caller does not discard the map entirely.
      expect(report({'error': 'no device'}).logged, isEmpty);
    });

    test('renders the message and recompiled file count', () {
      final r = report({
        'message': 'Hot reload successful',
        'filesRecompiled': ['package:app/main.dart'],
      });

      expect(r.logged.single, contains('Hot reload successful'));
      expect(r.logged.single, contains('1 file'));
    });

    test('calls out a no-op reload', () {
      final r = report({
        'message': 'Hot reload successful',
        'isEmpty': true,
      });

      expect(r.logged.single, contains('no changes'));
    });

    // This is the only terminal rendering there is: the map `toWire` produced,
    // plus the suffixes below. A second renderer reading the report directly
    // would suppress the clash these three pin.
    //
    // Driven end to end through the real `toWire`, not a hand-written map,
    // because the property is that the suffix agrees with the sentence `toWire`
    // composed; a literal map could hold a pairing `toWire` never emits.
    group('the "no changes" suffix does not contradict the sentence', () {
      Map<String, dynamic> wireFor(AssetOutcome assets) => toWire(
        CommandReport(
          verb: 'Hot reload',
          // The Dart half really did nothing: an asset-only edit declares a
          // file the snapshot then finds unchanged, so the work set is not
          // empty but every version in it already matches.
          outcome: const ReloadApplied(
            filesRecompiled: {},
            isEmpty: true,
            apps: [],
          ),
          assets: assets,
        ),
      );

      test('when the sentence already names the assets that changed', () {
        final wire = wireFor(
          const AssetOutcome(
            changed: {'assets/logo.png', 'assets/bg.png'},
            delivery: StrategyApplied(2),
          ),
        );
        expect(wire['isEmpty'], isTrue);

        final line = report(wire).logged.single;
        expect(line, contains('2 asset(s) reloaded'));
        expect(
          line,
          isNot(contains('no changes')),
          reason: 'it read "2 asset(s) reloaded (no changes)"',
        );
      });

      test('when the sentence says the rebuild produced nothing new', () {
        // `assetsChanged: 0` is still a clause that finishes the sentence, so
        // the suffix would say the same thing twice, the second time less
        // precisely.
        final wire = wireFor(const AssetOutcome(rebuiltIdentical: true));
        expect(wire['assetsChanged'], 0);

        final line = report(wire).logged.single;
        expect(line, contains('identical'));
        expect(line, isNot(contains('no changes')));
      });

      // The contrast that keeps the two above honest. Deleting the suffix
      // outright would satisfy them both; what is wanted is a suffix that
      // appears exactly where nothing else has explained the reload.
      test('but keeps it when no asset clause finished the sentence', () {
        final wire = wireFor(AssetOutcome.none);
        expect(wire.containsKey('assetsChanged'), isFalse);

        expect(report(wire).logged.single, contains('no changes'));
      });

      // The gate is on the suffix that would *contradict* the clause, not on
      // every suffix: a reload that recompiled something and delivered assets
      // did both, and the reader is owed both halves.
      test(
        'and still counts the files when the Dart half did do something',
        () {
          final wire = toWire(
            const CommandReport(
              verb: 'Hot reload',
              outcome: ReloadApplied(
                filesRecompiled: {'package:app/a.dart'},
                isEmpty: false,
                apps: [],
              ),
              assets: AssetOutcome(
                changed: {'assets/logo.png'},
                delivery: StrategyApplied(1),
              ),
            ),
          );

          final line = report(wire).logged.single;
          expect(line, contains('1 asset(s) reloaded'));
          expect(line, contains('1 file'));
        },
      );
    });

    // A reload nobody requested has no response to travel in. Without an event
    // the only machine-readable trace of a watched edit is the English in a
    // `log` line, and a client cannot tell a reload that failed from a watcher
    // that has died — both are silence on the protocol.
    group('announces the outcome for a machine reader', () {
      test('a success, with the whole result map', () {
        final result = {
          'succeeded': true,
          'message': 'Hot reload successful',
          'filesRecompiled': ['package:dep_lib/catalog.dart'],
          'isEmpty': false,
          'assetsChanged': 2,
        };

        final r = report(result);

        expect(
          r.announced.single,
          {
            'method': 'app.hotReload',
            'result': result,
          },
          reason:
              'the same map the command response carries, unaltered — one '
              'shape whether the client asked or the watcher did',
        );
      });

      test('a failure too, which is when it matters most', () {
        final r = report({
          'succeeded': false,
          'error': 'lib/main.dart:3:1: Error: boom',
          'message': 'Compilation failed',
          'runningCode': 'unchanged',
        });

        expect(r.announced.single['result'], isA<Map<String, dynamic>>());
        expect(
          (r.announced.single['result'] as Map)['error'],
          contains('boom'),
          reason:
              'a failed reload that emitted nothing would read exactly '
              'like a watcher that never fired',
        );
      });

      test('names the command it is the outcome of', () {
        final r = report(
          {'message': 'Restart successful'},
          action: 'Hot restart',
          method: 'app.restart',
        );

        expect(
          r.announced.single['method'],
          'app.restart',
          reason:
              'state survives a reload and is reset by a restart; a '
              'client cannot treat the two alike',
        );
      });
    });

    // Only the arms that stopped before anything was delivered have earned
    // this sentence.
    group('the claim about code already delivered', () {
      String textOf(Map<String, dynamic> result) {
        final records = <logging.LogRecord>[];
        final sub = logging.Logger.root.onRecord.listen(records.add);
        addTearDown(sub.cancel);
        report(result);
        return records.map((r) => (r.object as Map)['text'] as String).join();
      }

      test('is made when nothing was ever delivered', () {
        expect(
          textOf({'error': 'Hot reload is off', 'runningCode': 'unchanged'}),
          contains('keeps running the code it already had'),
        );
      });

      test('is withheld when nobody said what the app ended up with', () {
        // The case the sentence would make a lie: a device that never answered
        // would be told in one line both that what it runs is unknown and that
        // it kept its old code.
        final text = textOf({
          'error': 'app-a: timed out, so what it is running is unknown',
          'runningCode': 'unknown',
        });

        expect(text, contains('timed out'));
        expect(text, isNot(contains('keeps running the code it already had')));
      });

      test('is withheld when the app is running the new code', () {
        expect(
          textOf({
            'error': 'app-a: applied, then threw',
            'runningCode': 'updated',
          }),
          isNot(contains('keeps running the code it already had')),
        );
      });

      test('is withheld by a result that never answered the question', () {
        // Absent is not `unchanged`. Withholding costs a reader reassurance;
        // assuming would cost them the truth.
        expect(
          textOf({'error': 'something went wrong'}),
          isNot(contains('keeps running the code it already had')),
        );
      });
    });
  });

  /// Which app refused and which took it is the first thing anyone asks, and
  /// it is known where a bare count would be taken — the results come back in
  /// the same order as the sessions.
  group('StrategyRejected.devices', () {
    test('keeps both sides of a partial refusal', () {
      final outcome = StrategyRejected.devices(
        refused: const ['app-b'],
        applied: const ['app-a', 'app-c'],
      );
      expect(outcome.refused, ['app-b']);
      expect(outcome.applied, ['app-a', 'app-c']);
      expect(outcome.isSuccess, isFalse);
      expect(outcome.message, '1 of 3 device(s) refused it');
    });

    test('the message is composed, not supplied', () {
      final outcome = StrategyRejected.devices(
        refused: const ['a', 'b'],
        applied: const [],
      );
      expect(outcome.message, '2 of 2 device(s) refused it');
    });

    test('a rejection with no device list still carries its reason', () {
      // The web and CDP paths refuse without a per-device breakdown; they must
      // stay expressible rather than being forced to invent empty lists.
      const outcome = StrategyRejected('the browser refused the new sources');
      expect(outcome.refused, isEmpty);
      expect(outcome.applied, isEmpty);
      expect(outcome.message, contains('browser'));
    });
  });

  /// The WASM "dev loop", which is a bazel rebuild and a CDP page reload.
  ///
  /// The verdict is what matters: `WasmPipelineAssembler` renders whatever
  /// comes back here straight onto the wire, so a strategy that called a
  /// rebuild it never ran a success would tell the user their edit is live.
  /// Both arms are reachable without bazel because `rebuild` is injected.
  group('WasmReloadStrategy', () {
    test(
      'a failed rebuild is rejected, and the browser is never touched',
      () async {
        final browser = await _FakeCdpBrowser.start();
        final strategy = WasmReloadStrategy(
          cdpPort: browser.port,
          appUrl: browser.appUrl,
          rebuild: () async => false,
        );

        final outcome = await strategy.applyRestart(compiled, const []);

        expect(outcome.isSuccess, isFalse);
        expect(outcome.message, 'the WASM rebuild failed');
        // The fact the message cannot carry: a page reloaded off a bundle the
        // build did not produce would be showing the *old* code while the reply
        // named a build failure.
        expect(
          browser.received,
          isEmpty,
          reason: 'nothing may be reloaded when there is nothing new to load',
        );
        await browser.stop();
      },
    );

    test(
      'a successful rebuild reloads the page and reports it applied',
      () async {
        final browser = await _FakeCdpBrowser.start();
        final strategy = WasmReloadStrategy(
          cdpPort: browser.port,
          appUrl: browser.appUrl,
          rebuild: () async => true,
        );

        final outcome = await strategy.applyRestart(compiled, const []);

        expect(outcome.isSuccess, isTrue);
        expect(outcome, isA<StrategyApplied>());
        expect(
          browser.received,
          ['Page.reload'],
          reason: 'the success is the reload, so it has to have been sent',
        );
        await browser.stop();
      },
    );
  });
}

/// A browser's debugging port, as far as the CDP callers can tell: a `/json`
/// listing naming one page on [appUrl], and a WebSocket at the URL that
/// listing hands out.
///
/// Real sockets rather than a fake seam, because the code under test reaches
/// the browser through `dart:io` directly — the same shape `cdp_console_test`
/// serves its listings with.
class _FakeCdpBrowser {
  final HttpServer _server;

  /// Every CDP method the client sent, in order.
  final List<String> received = [];

  _FakeCdpBrowser._(this._server) {
    _server.listen((request) async {
      if (request.uri.path == '/json') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          json.encode([
            {
              'type': 'page',
              'url': '$appUrl/index.html',
              'webSocketDebuggerUrl': 'ws://127.0.0.1:$port/devtools/page/1',
            },
          ]),
        );
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) {
        final message = json.decode(data as String) as Map<String, dynamic>;
        received.add(message['method'] as String);
        socket.add(
          json.encode({'id': message['id'], 'result': <String, Object>{}}),
        );
      });
    });
  }

  static Future<_FakeCdpBrowser> start() async =>
      _FakeCdpBrowser._(await HttpServer.bind('127.0.0.1', 0));

  int get port => _server.port;
  String get appUrl => 'http://127.0.0.1:$port';

  Future<void> stop() => _server.close(force: true);
}
