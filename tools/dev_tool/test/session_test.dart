import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('DeviceSession', () {
    test('stores device, appInstance, vmClient, and appId', () {
      final device = MacOSDevice();
      final process = FakeProcess();
      final appInstance = AppInstance(process: process);
      final session = DeviceSession(
        device: device,
        appInstance: appInstance,
        vmClient: null,
        appId: 'test_app',
      );

      expect(session.device, device);
      expect(session.appInstance, appInstance);
      expect(session.vmClient, isNull);
      expect(session.appId, 'test_app');
      expect(session.devToolsUrl, isNull);
      expect(session.devToolsProcess, isNull);
    });

    test('devToolsUrl is mutable', () {
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: null,
        appId: 'test',
      );

      session.devToolsUrl = 'http://localhost:9100';
      expect(session.devToolsUrl, 'http://localhost:9100');
    });

    test('devToolsProcess is mutable', () {
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: null,
        appId: 'test',
      );

      final fakeProcess = FakeProcess();
      session.devToolsProcess = fakeProcess;
      expect(session.devToolsProcess, fakeProcess);
    });
  });

  group('runInteractiveSession', () {
    test('quit key stops all sessions and shuts down', timeout: Timeout(Duration(seconds: 10)), () async {
      final fakeProcess = FakeProcess();
      final fakeFrontendProcess = FakeProcess();
      final stopped = <String>[];

      final device = _TrackingDevice('test_device', onStop: () {
        stopped.add('test_device');
      });

      final session = DeviceSession(
        device: device,
        appInstance: AppInstance(process: fakeProcess),
        vmClient: null,
        appId: 'app_1',
      );

      final protocol = MachineProtocol(enabled: false);

      final frontendServer = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.dart.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeFrontendProcess,
      );
      await frontendServer.start();

      // Use a real temp directory so the watcher can start.
      final tmpDir = await Directory.systemTemp.createTemp('session_test_');

      // Create a keyboard stream that sends 'q' after a short delay.
      final keyboardController = StreamController<List<int>>();
      Future.delayed(const Duration(milliseconds: 100), () {
        keyboardController.add(utf8.encode('q'));
        // Allow shutdown to complete by making the frontend server process exit.
        Future.delayed(const Duration(milliseconds: 50), () {
          fakeFrontendProcess.complete(0);
        });
      });

      final logs = <String>[];

      try {
        await runInteractiveSession(
          sessions: [session],
          frontendServer: frontendServer,
          entrypoint: '/fake/main.dart',
          workspace: tmpDir.path,
          protocol: protocol,
          devToolsEnabled: false,
          log: (msg) => logs.add(msg),
          keyboardReader: () => keyboardController.stream,
          setEchoMode: (_) {},
          setLineMode: (_) {},
        );
      } finally {
        await tmpDir.delete(recursive: true);
      }

      expect(stopped, contains('test_device'));
      expect(logs.first, contains('Watching for file changes'));
    });
  });
}

/// A device that tracks stop calls.
class _TrackingDevice extends Device {
  final String _name;
  final void Function() onStop;

  _TrackingDevice(this._name, {required this.onStop});

  @override
  String get name => _name;

  @override
  Future<AppInstance> launch(String appPath) =>
      throw UnsupportedError('Not used in this test');

  @override
  Future<void> stop(AppInstance instance) async {
    onStop();
  }
}
