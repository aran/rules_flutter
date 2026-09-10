@Tags(['e2e'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('macos_example');

  group('Machine protocol e2e', () {
    // A run can fail before it has launched anything — a misconfigured host, an
    // unplugged phone, devices that cannot share one build — and a `--machine`
    // client has to be told, because a DevToolException unwinds past the
    // protocol entirely and the JSON stream would otherwise just stop.
    //
    // This is ordering, not error handling: the protocol has to be built and
    // listening BEFORE the run resolves what it is going to do, or
    // `daemon.logMessage` goes to a null protocol and the client gets zero
    // bytes and a bare exit.
    //
    // Two devices that disagree on platform build args is the cheapest way in:
    // macOS contributes none and an iOS simulator contributes
    // `--ios_multi_cpus`, so the refusal is the first thing after device
    // resolution — before preflight, before any bazel work, and without
    // needing the simulator to exist.
    // Runs twice, over both launch styles. The suite otherwise drives the
    // shipped AOT binary throughout (see `ensureBuiltDevTool`), which is what
    // users get; `viaDartRun` is the deliberate negative control that keeps the
    // source path from rotting. Do not delete it as duplication:
    //
    //  * `dart run` is the documented contributor workflow, and the only thing
    //    that proves the tool still *starts* from source — a broken
    //    `bin/flutter_bazel.dart` or a dependency the AOT build happens to
    //    tolerate would otherwise surface to whoever next ran it by hand.
    //  * Only `dart run` emits the Dart SDK's "Running build hooks..." with no
    //    trailing newline, gluing the first protocol envelope to it. The
    //    harness tolerates that prefix on purpose (see the stdout listener in
    //    `DevToolProcess`), and this is the only test that exercises it.
    //
    // This case is the cheapest one to double: it fails at device resolution,
    // before any Bazel work, so the second launch costs a startup and nothing
    // else.
    for (final viaDartRun in [false, true]) {
      final how = viaDartRun ? 'dart run' : 'the shipped binary';
      test('a failure during device resolution still reaches a machine client '
          '($how)', () async {
        final dt = await startDevTool(
          workspace: workspace,
          target: ':app',
          device: 'macos',
          extraArgs: const [
            '-d',
            'ios-simulator:00000000-0000-0000-0000-000000000000',
          ],
          viaDartRun: viaDartRun,
        );

        // Proof the protocol was up before resolution ran at all.
        await dt.waitForEvent('daemon.connected');

        final failure = await dt.waitForEvent('daemon.logMessage');
        expect(failure['params']?['level'], 'error');
        expect(
          failure['params']?['message'],
          contains('Cannot build for multiple platforms'),
        );

        expect(
          await dt.process.exitCode.timeout(const Duration(seconds: 60)),
          isNot(0),
        );
      });
    }

    test(
      'emits daemon.connected, app.start, app.debugPort, app.started',
      () async {
        final dt = await startDevTool(
          workspace: workspace,
          target: ':app',
          device: 'macos',
        );

        final connected = await dt.waitForEvent('daemon.connected');
        expect(connected['params'], containsPair('version', '0.1.0'));

        final start = await dt.waitForEvent('app.start');
        expect(start['params']?['deviceId'], 'macOS');

        final debugPort = await dt.waitForEvent('app.debugPort');
        expect(debugPort['params']?['wsUri'], isNotNull);
        expect(debugPort['params']?['baseUri'], isNotNull);

        final started = await dt.waitForEvent('app.started');
        expect(started['params']?['appId'], isNotNull);

        // End the run — which is daemon.shutdown's job, not app.stop's.
        final stopResp = await dt.sendCommand(1, 'daemon.shutdown');
        expect(stopResp['result']?['message'], 'shutdown');
      },
    );

    // Reload/restart correctness is verified manually, not here — see
    // docs/TESTING.md "Hot reload / hot restart (manual)".

    test('HTTP app.stop returns a complete response before teardown', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'macos',
      );

      final start = await dt.waitForEvent('app.started');
      final appId = start['params']?['appId'] as String? ?? dt.appId!;
      await dt.waitForHttpControl();

      // It stops one app, so it needs to be told which: a bare app.stop that
      // tore the whole run down would answer 'stopped' for having stopped
      // whatever it liked.
      final bare = await dt.httpCommand('app.stop', {});
      expect(bare['error'], contains('needs an appId'));
      expect(bare['error'], contains('daemon.shutdown'));

      // The command tears the session down; the channel must still flush this
      // response in full, rather than severing it mid-response by force-closing
      // inside the app.stop handler.
      final resp = await dt.httpCommand('app.stop', {'appId': appId});
      expect(resp['result']?['message'], 'stopped');
      expect(resp['result']?['appId'], appId);

      // And the tool exits cleanly afterwards: this run's only app is gone, so
      // the session loop ends, which closes the channel and lets the process
      // finish.
      final code = await dt.process.exitCode.timeout(
        const Duration(seconds: 30),
      );
      expect(code, 0);
    });

    test('unknown method returns error', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'macos',
      );

      await dt.waitForEvent('app.started');

      final resp = await dt.sendCommand(1, 'nonexistent.method');
      // Upstream's shape: `error` is a string carrying the reason, not a
      // JSON-RPC {code, message} object. And the reason names the list, since
      // absence is often correct rather than a typo — a command can be
      // genuinely unavailable on this run.
      expect(resp['error'], isA<String>());
      expect(resp['error'], contains('Unknown command: nonexistent.method'));
      expect(resp['error'], contains('GET /commands'));

      await dt.sendCommand(2, 'daemon.shutdown');
    });
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}
