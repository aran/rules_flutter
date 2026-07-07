@Tags(['e2e'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('macos_example');

  group('Machine protocol e2e', () {
    test('emits daemon.connected, app.start, app.debugPort, app.started', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'macos',
      );

      try {
        final connected = await dt.waitForEvent('daemon.connected');
        expect(connected['params'], containsPair('version', '0.1.0'));

        final start = await dt.waitForEvent('app.start');
        expect(start['params']?['deviceId'], 'macOS');

        final debugPort = await dt.waitForEvent('app.debugPort');
        expect(debugPort['params']?['wsUri'], isNotNull);
        expect(debugPort['params']?['baseUri'], isNotNull);

        final started = await dt.waitForEvent('app.started');
        expect(started['params']?['appId'], isNotNull);

        // Stop.
        final stopResp = await dt.sendCommand(1, 'app.stop');
        expect(stopResp['result']?['message'], 'stopped');
      } finally {
        await dt.dispose();
      }
    });

    // Reload/restart correctness is verified manually, not here — see
    // docs/TESTING.md "Hot reload / hot restart (manual)".

    test('HTTP app.stop returns a complete response before teardown',
        () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'macos',
      );

      try {
        await dt.waitForEvent('app.started');
        await dt.waitForHttpControl();

        // The command tears the session down; the channel must still flush
        // this response in full (it used to be severed mid-response by the
        // channel force-closing inside the app.stop handler).
        final resp = await dt.httpCommand('app.stop', {});
        expect(resp['result']?['message'], 'stopped');

        // And the tool exits cleanly afterwards: teardown ends the session
        // loop, which closes the channel and lets the process finish.
        final code = await dt.process.exitCode
            .timeout(const Duration(seconds: 30));
        expect(code, 0);
      } finally {
        await dt.dispose();
      }
    });

    test('unknown method returns error', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'macos',
      );

      try {
        await dt.waitForEvent('app.started');

        final resp = await dt.sendCommand(1, 'nonexistent.method');
        expect(resp['error'], isNotNull);
        expect(resp['error']['code'], -32601);

        await dt.sendCommand(2, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}
