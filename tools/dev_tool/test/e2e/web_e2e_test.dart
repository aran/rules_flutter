@Tags(['e2e'])
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// Overrides the `-c dbg` a `--hot` run asks for (bazel takes the last
/// occurrence of a flag), so the build succeeds and emits no
/// `_dev_config.json` — the artifact the whole DDC dev loop hangs off.
///
/// fastbuild rather than opt on purpose: it is the configuration
/// `bazel test //...` already populates in this workspace, so the negative
/// tests below cost a cache hit instead of a release web compile.
const _notDebug = ['--build-arg=--compilation_mode=fastbuild'];

void main() {
  final workspace = e2eWorkspace('web_example');

  group('Web/Chrome startup failures', () {
    // What this whole group exists for: a tool that warns on stderr and then
    // falls back to serving the stale bazel bundle launches Chrome, renders the
    // app and reports `app.started` — with no DWDS, no VM service, no hot
    // reload, no DevTools and no app console. It looks like a healthy run and
    // cannot be debugged or reloaded at all.
    test(
      'a web target built without -c dbg ends the run, naming the cause',
      () async {
        final dt = await startDevTool(
          workspace: workspace,
          target: ':app_wasm',
          device: 'chrome',
          extraArgs: _notDebug,
        );

        final failure = await dt.waitForStderr(
          '_dev_config.json',
          timeout: const Duration(minutes: 4),
        );
        // LOG_FORMAT=json is on (the harness sets it), so the line a machine
        // consumer reads must be a record with a level — not loose prose.
        final record = json.decode(failure) as Map<String, dynamic>;
        expect(record['level'], 'SEVERE');
        expect(record['error'], contains('-c dbg'));

        // And a --machine client is told why, rather than watching the
        // JSON-RPC stream stop mid-run with no final event.
        final logMessage = await dt.waitForEvent(
          'daemon.logMessage',
          timeout: const Duration(seconds: 30),
        );
        final params = logMessage['params'] as Map<String, dynamic>;
        expect(params['level'], 'error');
        expect(params['message'], contains('_dev_config.json'));

        expect(
          await dt.process.exitCode.timeout(const Duration(seconds: 30)),
          isNot(0),
        );
        // Nothing reached the point of claiming a running app.
        expect(
          dt.events.map((e) => e['event']),
          isNot(contains('app.started')),
        );
      },
    );

    test(
      '--allow-no-vm-service runs the same build anyway, degraded',
      () async {
        final dt = await startDevTool(
          workspace: workspace,
          target: ':app_wasm',
          device: 'chrome',
          extraArgs: [..._notDebug, '--allow-no-vm-service'],
        );

        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 4),
        );
        // The one line that says which flag is keeping this run alive, and
        // what it gave up for it.
        final degraded =
            json.decode(
                  await dt.waitForStderr(
                    'web_dev_server_failed',
                    timeout: const Duration(seconds: 30),
                  ),
                )
                as Map<String, dynamic>;
        expect(degraded['level'], 'WARNING');
        expect(degraded['flag'], '--allow-no-vm-service');
        expect(degraded['error'], contains('_dev_config.json'));

        // And the reload surface reports the real reason rather than a
        // generic "no frontend server".
        final reload = await dt.sendCommand(1, 'app.hotReload');
        expect(reload['result']?['error'], contains('hot reload unavailable'));

        await dt.sendCommand(2, 'daemon.shutdown');
      },
    );
  });

  group('Web/Chrome e2e', () {
    // Two facts a `--wasm` run has to state rather than leave a caller to
    // discover. dart2wasm produces a bundle with no VM service behind it, so
    // the `app.*` agent surface cannot exist; advertised anyway it answers `no
    // VM service for <appId>` a minute later, which reads as a connection that
    // failed rather than one that was never going to exist. And the address has
    // to be announced: this tool launches Chrome with its own scratch profile,
    // `--web-run-headless` gives it no window, and the address is otherwise
    // recoverable only from that process's argv.
    test('a WASM run says where the app is, and what it cannot do', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_wasm',
        device: 'chrome',
        extraArgs: const ['--wasm'],
      );

      final launched = await dt.waitForEvent(
        'app.webLaunchUrl',
        timeout: const Duration(minutes: 4),
      );
      final params = launched['params'] as Map<String, dynamic>;
      expect(params['url'], startsWith('http://'));
      expect(params['launched'], isTrue);
      expect(params['appId'], isNotEmpty);

      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 4));

      // Said once, up front, rather than one refused command at a time.
      final absent =
          json.decode(
                await dt.waitForStderr(
                  'agent_surface_unavailable',
                  timeout: const Duration(seconds: 30),
                ),
              )
              as Map<String, dynamic>;
      expect(absent['reason'], 'wasm');

      // And the surface really is absent, not present-and-refusing.
      final refusal = await dt.sendCommand(
        1,
        'app.getText',
        params: {'appId': params['appId'], 'text': 'anything'},
      );
      expect(refusal['error'], contains('Unknown command: app.getText'));

      // What a WASM run *can* still do is unaffected: its console arrives
      // over CDP rather than a VM service.
      expect(dt.commands, isNot(contains('app.getText')));
      expect(dt.commands, contains('app.restart'));

      // A screenshot waits for the app to go idle first — except here, where
      // there is no VM service to ask. Said rather than silently skipped: the
      // header is how a caller learns the picture carries no such promise,
      // and on this run it is why waiting for a capturable page is the
      // caller's job rather than the endpoint's.
      final appId = params['appId']! as String;
      await dt.nativeScreenshotWhenOnScreen(appId);
      final shot = await dt.httpNativeScreenshotReply(appId);
      expect(shot.settled, 'skipped');
      expect(shot.detail, contains('no VM service'));

      await dt.sendCommand(2, 'daemon.shutdown');
    }, timeout: const Timeout(Duration(minutes: 6)));

    test('WASM screenshot via HTTP control channel', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_wasm',
        device: 'chrome',
      );

      await dt.waitForEvent('app.started');
      final http = await dt.waitForHttpControl();
      expect(http, isNotNull);
      await Future<void>.delayed(const Duration(seconds: 5));

      final outputPath = '${Directory.systemTemp.path}/web_wasm_e2e.png';
      await dt.httpScreenshotToFile(dt.appId!, outputPath);

      final file = File(outputPath);
      expect(file.existsSync(), isTrue);
      final bytes = file.readAsBytesSync();
      expect(bytes.length, greaterThan(100));
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      file.deleteSync();

      await dt.sendCommand(1, 'daemon.shutdown');
    });

    test('JS screenshot via HTTP control channel', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_js',
        device: 'chrome',
      );

      await dt.waitForEvent('app.started');
      final http = await dt.waitForHttpControl();
      expect(http, isNotNull);
      await Future<void>.delayed(const Duration(seconds: 5));

      final outputPath = '${Directory.systemTemp.path}/web_js_e2e.png';
      await dt.httpScreenshotToFile(dt.appId!, outputPath);

      final file = File(outputPath);
      expect(file.existsSync(), isTrue);
      final bytes = file.readAsBytesSync();
      expect(bytes.length, greaterThan(100));
      expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      file.deleteSync();

      await dt.sendCommand(1, 'daemon.shutdown');
    });

    // `daemon.shutdown` is one of only two documented ways to end a run, and
    // the only one an agent driving `--machine` has that is not "kill it".
    // A run can answer `{"message":"shutdown"}`, emit `app.stop` and still
    // leave the process alive — DWDS's debug-extension backend can hold a
    // listening socket past `Dwds.stop()`, and a listening socket keeps the
    // Dart VM up. Asserting on the answer alone cannot see that, so this
    // asserts on the exit.
    test('daemon.shutdown ends the process, not just the app', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_js',
        device: 'chrome',
      );

      await dt.waitForEvent('app.started');
      final response = await dt.sendCommand(1, 'daemon.shutdown');
      expect(response['result']?['message'], 'shutdown');

      final code = await dt.process.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw StateError(
          'daemon.shutdown was answered but the process was still running '
          '20s later. Something the run owns is still holding the VM open.',
        ),
      );
      expect(code, 0);
    });
  });
}
