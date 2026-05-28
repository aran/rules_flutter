import 'dart:async';

import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:vm_service/vm_service.dart';
import 'package:test/test.dart';

import 'fakes.dart';

VmServiceClient _connectedClient(FakeVmService service) {
  final client = VmServiceClient(connector: (_) async => service);
  return client;
}

Future<VmServiceClient> _connect(FakeVmService service) async {
  final client = _connectedClient(service);
  await client.connect(Uri.parse('http://127.0.0.1:8181/'));
  return client;
}

void main() {
  group('AppInstance.applyKernel', () {
    test('returns Applied on a successful reloadSources + reassemble',
        () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = await _connect(fake);
      final app = VmServiceAppInstance(id: 'app1', client: client);

      final outcome = await app.applyKernel('/tmp/out.dill',
          mode: ApplyMode.hotReload);

      expect(outcome, isA<Applied>());
      expect(fake.reloadSourcesCalled, isTrue);
      expect(fake.lastExtensionMethod, 'ext.flutter.reassemble');
    });

    test('returns ApplyFailed when reloadSources reports success=false',
        () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        reloadSuccess: false,
      );
      final client = await _connect(fake);
      final app = VmServiceAppInstance(id: 'app1', client: client);

      final outcome = await app.applyKernel('/tmp/out.dill',
          mode: ApplyMode.hotReload);
      expect(outcome, isA<ApplyFailed>());
    });

    test('returns ApplyFailed when reloadSources throws RPCError', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        throwOnReload: true,
      );
      final client = await _connect(fake);
      final app = VmServiceAppInstance(id: 'app1', client: client);

      final outcome = await app.applyKernel('/tmp/out.dill',
          mode: ApplyMode.hotReload);
      // VmServiceClient.hotReload swallows the exception and returns false;
      // AppInstance maps that to ApplyFailed.
      expect(outcome, isA<ApplyFailed>());
    });

    test('returns ApplyTimedOut when reloadSources hangs longer than the RPC budget',
        () async {
      final gate = Completer<void>();
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        reloadSourcesGate: gate,
      );
      final client = await _connect(fake);
      final app = VmServiceAppInstance(
        id: 'app1',
        client: client,
        rpcTimeout: const Duration(milliseconds: 50),
      );

      final outcome = await app.applyKernel('/tmp/out.dill',
          mode: ApplyMode.hotReload);
      expect(outcome, isA<ApplyTimedOut>());
      // Release the gate so the leaked future doesn't leave a pending
      // microtask in the test runner's bookkeeping.
      gate.complete();
    });

    test('on timeout, the underlying connection is force-closed (no leak)',
        () async {
      final gate = Completer<void>();
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        reloadSourcesGate: gate,
      );
      final client = await _connect(fake);
      final app = VmServiceAppInstance(
        id: 'app1',
        client: client,
        rpcTimeout: const Duration(milliseconds: 50),
      );

      expect(client.isConnected, isTrue);
      await app.applyKernel('/tmp/out.dill', mode: ApplyMode.hotReload);

      // After timeout, the connection has been force-closed.
      expect(client.isConnected, isFalse);
      gate.complete();
    });

    test('a hung applyKernel call does not block a concurrent applyKernel on a different AppInstance',
        () async {
      // The hot-reload pipeline applies kernel to multiple AppInstances in
      // parallel (one per device). A hung VM on one device must not delay
      // the other. With per-AppInstance VmServiceClients and per-call
      // timeouts, this is structural.
      final hungGate = Completer<void>();
      final fakeHung = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        reloadSourcesGate: hungGate,
      );
      final fakeHealthy = FakeVmService(
        isolates: [IsolateRef(id: 'iso-2', name: 'main', number: '1')],
      );
      final hungClient = await _connect(fakeHung);
      final healthyClient = await _connect(fakeHealthy);

      final hungApp = VmServiceAppInstance(
        id: 'hung',
        client: hungClient,
        rpcTimeout: const Duration(seconds: 5),
      );
      final healthyApp = VmServiceAppInstance(id: 'healthy', client: healthyClient);

      // Fire both in parallel.
      final hungFuture = hungApp.applyKernel('/tmp/out.dill',
          mode: ApplyMode.hotReload);
      final healthyFuture = healthyApp.applyKernel('/tmp/out.dill',
          mode: ApplyMode.hotReload);

      // The healthy one completes promptly without waiting on hungGate.
      final healthyOutcome =
          await healthyFuture.timeout(const Duration(seconds: 2));
      expect(healthyOutcome, isA<Applied>());

      // Drain the hung one for cleanup.
      hungGate.complete();
      await hungFuture;
    });

    test('hotRestart routes through reloadSources with force=true', () async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      final client = await _connect(fake);
      final app = VmServiceAppInstance(id: 'app1', client: client);

      final outcome = await app.applyKernel('/tmp/full.dill',
          mode: ApplyMode.hotRestart);
      expect(outcome, isA<Applied>());
      expect(fake.reloadSourcesCalled, isTrue);
    });
  });
}
