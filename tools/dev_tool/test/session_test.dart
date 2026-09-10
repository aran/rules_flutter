import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dds/dds.dart';
import 'package:flutter_bazel_dev_tool/command_report.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/outcome_renderer.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/source_watcher.dart';
import 'package:flutter_bazel_dev_tool/reload_strategy.dart';
import 'package:flutter_bazel_dev_tool/run_plan.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:logging/logging.dart';
import 'package:vm_service/vm_service.dart' show IsolateRef;
import 'package:test/test.dart';
import 'package:watcher/watcher.dart';

import 'fakes.dart';

void main() {
  group('parseDevToolsUrl', () {
    // The line `dart devtools` actually prints. The period ends the sentence;
    // capturing it yields a URL Uri.parse rejects, and that value is what gets
    // opened in a browser.
    test('leaves the sentence-ending period out of the URL', () {
      const line = 'Serving DevTools at http://127.0.0.1:9100.';
      expect(parseDevToolsUrl(line), 'http://127.0.0.1:9100');
      expect(() => Uri.parse(parseDevToolsUrl(line)!), returnsNormally);
    });

    test('accepts the announcement without a trailing period', () {
      expect(
        parseDevToolsUrl('Serving DevTools at http://127.0.0.1:9100'),
        'http://127.0.0.1:9100',
      );
    });

    test('keeps a path intact', () {
      expect(
        parseDevToolsUrl('Serving DevTools at http://127.0.0.1:9100/abc/.'),
        'http://127.0.0.1:9100/abc/',
      );
    });

    test('declines lines that are not the announcement', () {
      for (final line in const [
        '',
        'Hit ctrl-c to terminate the server.',
        'Serving the Dart Tooling Daemon at ws://127.0.0.1:1234/abc.',
      ]) {
        expect(
          parseDevToolsUrl(line),
          isNull,
          reason: 'should decline "$line"',
        );
      }
    });
  });

  group('devToolsConnectUri', () {
    // Opening the bare server root lands on DevTools' "Connect to a Running
    // App" form — it has no idea which VM service to attach to. The target is
    // carried in the `uri` query parameter.
    final ws = Uri.parse('ws://127.0.0.1:51231/DoJ9hE44ZWc=/ws');

    test('carries the VM service ws URI in the uri query parameter', () {
      final connect = devToolsConnectUri('http://127.0.0.1:9100', ws);

      expect(connect.queryParameters['uri'], ws.toString());
      expect(connect.host, '127.0.0.1');
      expect(connect.port, 9100);
    });

    test('percent-encodes the nested URI so it survives as one parameter', () {
      final connect = devToolsConnectUri('http://127.0.0.1:9100', ws);

      // The `:` and `/` of the inner URI must not be readable as structure of
      // the outer one; round-tripping is what proves it.
      expect(connect.toString(), contains('uri=ws%3A%2F%2F'));
      expect(
        Uri.parse(connect.toString()).queryParameters['uri'],
        ws.toString(),
      );
    });

    test('preserves a served path prefix', () {
      final connect = devToolsConnectUri('http://127.0.0.1:9100/devtools/', ws);

      expect(connect.path, '/devtools/');
      expect(connect.queryParameters['uri'], ws.toString());
    });
  });

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

    test('a web session is debug-ready without a DDS of its own', () async {
      // DWDS owns the Dart Development Service and hands over URLs, so `dds`
      // stays null here even once the session is fully wired. The DevTools
      // launcher must not require it.
      final session = DeviceSession(
        device: WebDevice(),
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: null,
        appId: 'app_web',
      );
      session.markDebugReady();

      await expectLater(session.debugReady, completes);
      expect(session.dds, isNull);
      expect(session.devToolsUrl, isNull);
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

    test('terminated completes when the running app process exits', () async {
      final process = FakeProcess();
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: process),
        vmClient: null,
        appId: 'test',
      );

      var terminated = false;
      unawaited(session.terminated.then((_) => terminated = true));
      await pumpEventQueue();
      expect(terminated, isFalse);

      process.complete(0);
      await session.terminated.timeout(const Duration(seconds: 5));
    });

    // A restart that finds changed native libraries kills the running process
    // on purpose and installs a replacement. Reading that kill as "the app
    // exited" would end the run's session loop and close the HTTP control
    // channel a driver is still holding, with the relaunched app alive and no
    // second banner to find it by.
    test('a relaunch is not the session ending', () async {
      final first = FakeProcess();
      final second = FakeProcess();
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: first),
        vmClient: null,
        appId: 'test',
      );

      var terminated = false;
      unawaited(session.terminated.then((_) => terminated = true));

      await session.relaunch(() async {
        // What `device.stop()` does to the outgoing process.
        first.complete(0);
        return AppInstance(process: second);
      });
      await pumpEventQueue();

      expect(
        terminated,
        isFalse,
        reason: 'the replaced process exiting must not end the session',
      );
      expect(session.appInstance.process, second);
      expect(session.launch, 2, reason: 'second launch of this app');

      // The replacement's exit does end it.
      second.complete(0);
      await session.terminated.timeout(const Duration(seconds: 5));
    });

    test('a relaunch that fails to launch ends the session', () async {
      final first = FakeProcess();
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: first),
        vmClient: null,
        appId: 'test',
      );

      await expectLater(
        session.relaunch(() async {
          first.complete(0);
          throw StateError('launch failed');
        }),
        throwsStateError,
      );

      // Nothing replaced the process the relaunch killed, so the app really
      // is gone — the suppressed exit must not swallow that.
      await session.terminated.timeout(const Duration(seconds: 5));
      expect(session.launch, 1);
    });
  });

  group('runInteractiveSession', () {
    test(
      'quit key stops all sessions and shuts down',
      timeout: Timeout(Duration(seconds: 10)),
      () async {
        final fakeProcess = FakeProcess();
        final fakeFrontendProcess = FakeProcess();
        final stopped = <String>[];

        final device = _TrackingDevice(
          'test_device',
          onStop: () {
            stopped.add('test_device');
          },
        );

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

        // Started by the caller, as production does — the banner reports the
        // watcher it was handed, not a flag.
        final watcher = SourceWatcher(root: tmpDir.path);
        await watcher.start();

        try {
          await runInteractiveSession(
            sessions: [session],
            frontendServer: frontendServer,
            protocol: protocol,
            commandRunner: CommandRunner(),
            devToolsEnabled: false,
            dartExecutable: 'dart',
            hotReloadUnavailable: null,
            watcher: watcher,
            log: (msg) => logs.add(msg),
            keyboardReader: () => keyboardController.stream,
            setEchoMode: (_) {},
            setLineMode: (_) {},
          );
        } finally {
          await watcher.stop();
          await tmpDir.delete(recursive: true);
        }

        expect(stopped, contains('test_device'));
        expect(logs.first, contains('Watching for file changes'));
      },
    );

    // The keyboard is a command transport and nothing else: 'r' goes through
    // the same [CommandRunner] the watcher, the HTTP channel and the machine
    // protocol dispatch through. A second, private reload implementation
    // behind the key would drift from the pipeline unnoticed.
    test(
      'the r key dispatches app.hotReload through the command runner',
      timeout: Timeout(Duration(seconds: 10)),
      () async {
        final dispatched = <String>[];
        final commandRunner = CommandRunner()
          ..register('app.hotReload', (params) async {
            dispatched.add('app.hotReload');
            return {'message': 'Hot reload successful'};
          });

        final session = DeviceSession(
          device: _TrackingDevice('test_device', onStop: () {}),
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: null,
          appId: 'app_1',
        );

        // Buffered by the single-subscription controller until the loop reaches
        // the keyboard, so the two keys arrive in order however long setup takes.
        final keys = StreamController<List<int>>();
        keys.add(utf8.encode('r'));
        keys.add(utf8.encode('q'));

        final logs = <String>[];
        await runInteractiveSession(
          sessions: [session],
          frontendServer: null,
          protocol: MachineProtocol(enabled: false),
          commandRunner: commandRunner,
          devToolsEnabled: false,
          dartExecutable: 'dart',
          hotReloadUnavailable: null,
          log: logs.add,
          keyboardReader: () => keys.stream,
          setEchoMode: (_) {},
          setLineMode: (_) {},
        ).timeout(const Duration(seconds: 5));

        expect(
          dispatched,
          ['app.hotReload'],
          reason:
              'the keypress must reach the registered handler, not a '
              'second implementation of its own',
        );
        expect(
          logs,
          contains('Hot reload successful'),
          reason: "the handler's answer is what the user is told",
        );
      },
    );

    // A run that cannot reload still dispatches, so the ONE holder of the
    // reason — the readiness gate, reached through the handler — is what
    // answers, exactly as it does for the HTTP channel and the machine
    // protocol. Swallowing the key leaves no way to tell a refusal from a
    // keystroke the terminal never saw; refusing in the keyboard instead
    // would put a second answer beside the gate's.
    test(
      'a run that will not reload still lets the keys reach the handler',
      timeout: Timeout(Duration(seconds: 10)),
      () async {
        final dispatched = <String>[];
        final commandRunner = CommandRunner()
          ..register('app.hotReload', (params) async {
            dispatched.add('app.hotReload');
            return {'error': '`--no-hot` was passed'};
          })
          ..register('app.restart', (params) async {
            dispatched.add('app.restart');
            return {'error': '`--no-hot` was passed'};
          });

        final session = DeviceSession(
          device: _TrackingDevice('test_device', onStop: () {}),
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: null,
          appId: 'app_1',
        );

        final keys = StreamController<List<int>>();
        keys.add(utf8.encode('r'));
        keys.add(utf8.encode('R'));
        keys.add(utf8.encode('q'));

        final logs = <String>[];
        await runInteractiveSession(
          sessions: [session],
          frontendServer: null,
          protocol: MachineProtocol(enabled: false),
          commandRunner: commandRunner,
          devToolsEnabled: false,
          dartExecutable: 'dart',
          hotReloadUnavailable: '`--no-hot` was passed',
          log: logs.add,
          keyboardReader: () => keys.stream,
          setEchoMode: (_) {},
          setLineMode: (_) {},
        ).timeout(const Duration(seconds: 5));

        expect(
          dispatched,
          ['app.hotReload', 'app.restart'],
          reason:
              'swallowing the key leaves the user with no answer at all; '
              'the handler is where the reason lives',
        );
        expect(
          logs,
          isNot(contains('Performing hot restart...')),
          reason:
              'announcing a restart and then refusing it reads worse than '
              'saying nothing',
        );
      },
    );

    // `p` and `i` are the only keys whose work is a bare VM-service call, and
    // the client refuses one it has no live connection for by throwing.
    // Nothing between that throw and `main` catches a `StateError`, so an
    // uncaught one would end a run that is still usable for its logs, its
    // native screenshots and its own shutdown. Reachable well short of a dead
    // app: `_toggleExtension` also refuses while `_mainIsolateId` is null,
    // which is every restart's isolate rotation.
    test(
      'a toggle key the VM service cannot serve does not end the run',
      timeout: Timeout(Duration(seconds: 10)),
      () async {
        final session = DeviceSession(
          device: _TrackingDevice('test_device', onStop: () {}),
          appInstance: AppInstance(process: FakeProcess()),
          // Never connected, so there is no service to call — the same state a
          // client is left in once it has given up on an app.
          vmClient: VmServiceClient(),
          appId: 'app_1',
        );

        final keys = StreamController<List<int>>();
        keys.add(utf8.encode('p'));
        keys.add(utf8.encode('i'));
        keys.add(utf8.encode('q'));

        final logs = <String>[];
        await runInteractiveSession(
          sessions: [session],
          frontendServer: null,
          protocol: MachineProtocol(enabled: false),
          commandRunner: CommandRunner(),
          devToolsEnabled: false,
          dartExecutable: 'dart',
          hotReloadUnavailable: null,
          log: logs.add,
          keyboardReader: () => keys.stream,
          setEchoMode: (_) {},
          setLineMode: (_) {},
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () => fail('the run never reached the q that ends it'),
        );

        expect(
          logs.join('\n'),
          allOf(contains('performance overlay'), contains('widget inspector')),
          reason:
              'a key that cannot do its work has to say so; swallowing it '
              'leaves no way to tell that from a keystroke never delivered',
        );
        expect(
          logs.join('\n'),
          contains('Not connected to VM service'),
          reason: "the client's own reason is what names the cause",
        );
      },
    );

    // The reason travels through renderers that compose a sentence around it,
    // so a reason carrying its own subject and full stop reads as two
    // sentences glued together.
    test('a refusal reads as one sentence, not three glued together', () {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      // What `ReloadPipeline._awaitReady` hands back from a gate that was
      // settled unavailable — built the way it builds it, so this cannot
      // drift into testing a shape production stopped producing.
      reportReloadCommand(
        'Hot reload',
        toWire(
          CommandReport(
            verb: 'Hot reload',
            unavailable: RunPlan.hotReloadOffReason(
              profileMode: false,
              hotFlag: false,
            ),
          ),
        ),
        (_) {},
        method: 'app.hotReload',
        announce: (_) {},
      );

      final text = records
          .map((r) => (r.object as Map)['text'] as String)
          .join('\n');
      expect(text, contains('--no-hot'));
      expect(
        text,
        isNot(contains('..')),
        reason:
            'the reason must not bring a full stop into a sentence that '
            'already ends one',
      );
      expect(
        'Hot reload'.allMatches(text).length,
        1,
        reason:
            'the renderer supplies the subject; a reason that repeats it '
            'says "Hot reload failed: Hot reload is off…"',
      );
    });

    // The loop's return is what closes the run's transports, the HTTP control
    // channel included (`run_command.dart`'s `finally`). So whatever ends this
    // loop decides how long the advertised channel actually answers for — and
    // stdin reaching EOF is not the run ending: a script, a CI job or an agent
    // launching the tool with stdin at /dev/null still needs the channel it
    // was handed.
    group('a keyboard that closes', () {
      /// Run the loop over [keys] against one session holding [process].
      ({Future<void> loop, bool Function() returned, List<String> logs})
      loopOver(
        StreamController<List<int>> keys,
        FakeProcess process, {
        Future<void>? shutdownSignal,
      }) {
        final logs = <String>[];
        var returned = false;
        final loop = runInteractiveSession(
          sessions: [
            DeviceSession(
              device: _TrackingDevice('test_device', onStop: () {}),
              appInstance: AppInstance(process: process),
              vmClient: null,
              appId: 'app_1',
            ),
          ],
          frontendServer: null,
          protocol: MachineProtocol(enabled: false),
          commandRunner: CommandRunner(),
          devToolsEnabled: false,
          dartExecutable: 'dart',
          hotReloadUnavailable: null,
          shutdownSignal: shutdownSignal,
          log: logs.add,
          keyboardReader: () => keys.stream,
          setEchoMode: (_) {},
          setLineMode: (_) {},
        )..then((_) => returned = true);
        return (loop: loop, returned: () => returned, logs: logs);
      }

      test('does not end a run whose app is still alive', () async {
        final keys = StreamController<List<int>>();
        final process = FakeProcess();
        final run = loopOver(keys, process);

        await keys.close();
        await pumpEventQueue();

        expect(
          run.returned(),
          isFalse,
          reason:
              'the app and its VM service are up and the control '
              'channel was advertised; losing the keyboard withdraws none '
              'of that',
        );

        // …and the run still ends when the app does, rather than hanging on a
        // keyboard that will never speak again.
        process.complete(0);
        await run.loop.timeout(const Duration(seconds: 5));
      });

      test('leaves app.stop able to end the run', () async {
        // The only remaining way to end a detached run from outside. If EOF
        // cancelled the loop's wait on it, a driver holding the channel would
        // have no way out but killing the process.
        final keys = StreamController<List<int>>();
        final shutdown = Completer<void>();
        final run = loopOver(
          keys,
          FakeProcess(),
          shutdownSignal: shutdown.future,
        );

        await keys.close();
        await pumpEventQueue();
        expect(run.returned(), isFalse);

        shutdown.complete();
        await run.loop.timeout(const Duration(seconds: 5));
      });

      test('says so, rather than going quiet', () async {
        final keys = StreamController<List<int>>();
        final process = FakeProcess();
        final run = loopOver(
          keys,
          process,
          shutdownSignal: Completer<void>().future,
        );

        await keys.close();
        await pumpEventQueue();

        expect(
          run.logs.join('\n'),
          contains('stdin'),
          reason:
              'the banner just offered keys that no longer do anything; '
              'the user has to be told which ones went away',
        );
        expect(
          run.logs.join('\n'),
          contains('app.stop'),
          reason: 'and what is left to end the run with',
        );

        process.complete(0);
        await run.loop.timeout(const Duration(seconds: 5));
      });

      test('ends the run when there is nothing left to control', () async {
        // No sessions and no shutdown signal: no app can exit and no command
        // can arrive, so waiting would be waiting forever. Returning is what
        // lets the caller run its teardown.
        final keys = StreamController<List<int>>();
        final loop = runInteractiveSession(
          sessions: const [],
          frontendServer: null,
          protocol: MachineProtocol(enabled: false),
          commandRunner: CommandRunner(),
          devToolsEnabled: false,
          dartExecutable: 'dart',
          hotReloadUnavailable: null,
          keyboardReader: () => keys.stream,
          setEchoMode: (_) {},
          setLineMode: (_) {},
        );

        await keys.close();
        await loop.timeout(const Duration(seconds: 5));
      });
    });

    test(
      'the banner offers no key the run cannot honour',
      timeout: Timeout(Duration(seconds: 10)),
      () async {
        final keys = StreamController<List<int>>()..add(utf8.encode('q'));
        final logs = <String>[];

        await runInteractiveSession(
          sessions: [],
          frontendServer: null,
          protocol: MachineProtocol(enabled: false),
          commandRunner: CommandRunner(),
          devToolsEnabled: false,
          dartExecutable: 'dart',
          hotReloadUnavailable: 'profile mode builds AOT',
          log: logs.add,
          keyboardReader: () => keys.stream,
          setEchoMode: (_) {},
          setLineMode: (_) {},
        ).timeout(const Duration(seconds: 5));

        final banner = logs.first;
        expect(banner, isNot(contains('hot reload')));
        expect(banner, isNot(contains('restart')));
        expect(banner, contains('quit'));
        expect(
          banner,
          contains('profile mode builds AOT'),
          reason:
              'the banner is where the user learns the keys are gone '
              'before reaching for one',
        );
      },
    );

    test(
      'machine mode suppresses the interactive key banner',
      timeout: Timeout(Duration(seconds: 10)),
      () async {
        // In --machine mode stdin is the JSON-RPC channel, so "Press r/R/q" hints
        // are both inactive and (since `log` writes to stdout) would corrupt the
        // protocol stream. The banner must not be emitted.
        final protocol = MachineProtocol(enabled: true);
        final logs = <String>[];

        // No sessions + machine mode → the protocol.enabled branch returns
        // immediately (no exit futures to await).
        await runInteractiveSession(
          sessions: [],
          frontendServer: null,
          protocol: protocol,
          commandRunner: CommandRunner(),
          devToolsEnabled: false,
          dartExecutable: 'dart',
          hotReloadUnavailable: null,
          log: (msg) => logs.add(msg),
        );

        expect(
          logs.where((m) => m.contains('Press') || m.contains('Watching')),
          isEmpty,
          reason:
              'machine mode owns stdin via JSON-RPC; key hints mislead and '
              'pollute the protocol stdout stream',
        );
      },
    );

    test(
      'machine mode outlives a relaunch of the app process',
      timeout: Timeout(Duration(seconds: 10)),
      () async {
        // The loop's return is what closes the run's transports — the HTTP
        // control channel included. A restart that relaunches the process
        // (native libraries changed) must therefore not end it: the driver that
        // issued the restart is still holding the channel it issued it over.
        final first = FakeProcess();
        final second = FakeProcess();
        final session = DeviceSession(
          device: MacOSDevice(),
          appInstance: AppInstance(process: first),
          vmClient: null,
          appId: 'app_1',
        );

        var loopReturned = false;
        final loop = runInteractiveSession(
          sessions: [session],
          frontendServer: null,
          protocol: MachineProtocol(enabled: true),
          commandRunner: CommandRunner(),
          devToolsEnabled: false,
          dartExecutable: 'dart',
          hotReloadUnavailable: null,
        )..then((_) => loopReturned = true);

        await session.relaunch(() async {
          first.complete(0);
          return AppInstance(process: second);
        });
        await pumpEventQueue();

        expect(
          loopReturned,
          isFalse,
          reason: 'the relaunched app is running; the session has not ended',
        );

        second.complete(0);
        await loop;
      },
    );
  });

  group('recompileAndRestart', () {
    // Every completed compile owes the compiler a verdict: `FrontendServer`
    // sets its awaiting-verdict state from the result line whether or not it
    // carried errors, and for a full `compile` as much as an incremental
    // `recompile`. Returning without one leaves the compiler holding a broken
    // delta nobody has refused. `ReloadPipeline.restart` calls this on web
    // DDC, so a restart against broken sources is all it takes to reach it.
    test('a failed compile is rejected before the restart returns', () async {
      final fakeProcess = FakeProcess();
      final frontendServer = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.dart.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeProcess,
      );
      await frontendServer.start();
      // The server owns a temp directory for its output dill and only removes
      // it on shutdown, which needs the process to have exited first.
      addTearDown(() async {
        fakeProcess.complete(0);
        await frontendServer.shutdown();
      });

      final strategy = _RecordingReloadStrategy();
      var settled = false;
      final restart = recompileAndRestart(
        frontendServer: frontendServer,
        entrypoint: 'lib/main.dart',
        invalidatedFiles: const ['package:app/main.dart'],
        sessions: const [],
        reloadStrategy: strategy,
      );
      unawaited(restart.then((_) => settled = true));

      // The full compile answers with one error, so there is no dill to apply.
      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /tmp/out.dill 1');
      await pumpEventQueue();

      // The verb, before the verdict. A restart asks for `reset` +
      // `recompile`; it must never be a second `compile`, whose error count is
      // cumulative and which therefore owes every later restart in the session
      // a phantom failure once one has failed.
      final written = fakeProcess.stdinBuffer.toString();
      expect(
        written,
        matches(RegExp(r'^reset\nrecompile ', multiLine: true)),
        reason: 'a restart is reset + recompile: $written',
      );
      expect(
        written,
        isNot(matches(RegExp(r'^compile ', multiLine: true))),
        reason:
            'the bare `compile` verb is what this restart must not '
            'send: $written',
      );

      expect(
        written,
        contains('reject'),
        reason: 'a completed compile owes a verdict, failure included',
      );
      expect(
        settled,
        isFalse,
        reason:
            'reject is the one verdict the compiler answers, and the '
            'answer must be read before anything else is written',
      );

      // The acknowledgement: `result <key>` then the key alone.
      fakeProcess.emitStdout('result reject_key');
      fakeProcess.emitStdout('reject_key');

      final result = await restart.timeout(const Duration(seconds: 5));
      expect(result.compileSuccess, isFalse);
      expect(
        strategy.calls,
        isEmpty,
        reason: 'nothing compiled, so nothing may be applied',
      );

      // The stream is back in sync: the acknowledgement was consumed as one,
      // not mistaken for the next compile's boundary key.
      final next = frontendServer.compile('lib/main.dart');
      fakeProcess.emitStdout('result abc2');
      fakeProcess.emitStdout('abc2 /tmp/out2.dill 0');
      final compiled = await next.timeout(const Duration(seconds: 5));
      expect(compiled.success, isTrue);
      expect(compiled.dillPath, '/tmp/out2.dill');
    });
  });

  /// The compile and the apply are two different halves of the same command,
  /// and only one of them can be blamed at a time.
  ///
  /// Wrapping the pair in one try renders a throw out of the strategy — where
  /// the compiled output meets the device — as "Compilation failed", which
  /// sends the user to look at source the compiler has just accepted.
  ///
  /// Every strategy calls `WebModuleServer.updateModules` OUTSIDE its own try,
  /// and that throws a [DevToolException] when a compile the frontend server
  /// called successful left no DDC manifest behind.
  group('a delivery failure is not a compile failure', () {
    /// A started server whose FakeProcess is driven by the test.
    ///
    /// The compiler's answer must be emitted while the request is in flight —
    /// awaiting the future first deadlocks the test on itself.
    ({FrontendServer server, FakeProcess process}) startedServer() {
      final process = FakeProcess();
      final server = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.dart.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => process,
      );
      return (server: server, process: process);
    }

    /// The two lines a frontend server answers a clean compile with: the
    /// boundary key, then that key with the dill and an error count of zero.
    void emitCleanCompile(FakeProcess process) {
      process.emitStdout('result k');
      process.emitStdout('k /tmp/out.dill 0');
    }

    test(
      'a strategy that throws leaves the compile reported as successful',
      () async {
        final (:server, :process) = startedServer();
        await server.start();
        addTearDown(() async {
          process.complete(0);
          await server.shutdown();
        });

        final reload = recompileAndReload(
          frontendServer: server,
          entrypoint: 'lib/main.dart',
          invalidatedFiles: const ['package:app/main.dart'],
          sessions: const [],
          reloadStrategy: _ThrowingReloadStrategy(
            StateError('no DDC manifest to serve'),
          ),
        );
        emitCleanCompile(process);

        final result = await reload.timeout(const Duration(seconds: 5));

        expect(
          result.compileSuccess,
          isTrue,
          reason: 'the compile is exactly what did not fail',
        );
        // The throw is the *delivery's*, so it lands in the outcome — which is
        // what the report renders from, and where a reader is sent to look.
        expect(result.outcome, isA<StrategyThrew>());
        expect(
          result.outcome!.message,
          contains('no DDC manifest to serve'),
          reason: "the strategy's throw is what the user has to see",
        );
      },
    );

    test('a restart whose strategy throws blames the delivery too', () async {
      final (:server, :process) = startedServer();
      await server.start();
      addTearDown(() async {
        process.complete(0);
        await server.shutdown();
      });

      final restart = recompileAndRestart(
        frontendServer: server,
        entrypoint: 'lib/main.dart',
        invalidatedFiles: const ['package:app/main.dart'],
        sessions: const [],
        reloadStrategy: _ThrowingReloadStrategy(
          StateError('the page went away'),
        ),
      );
      emitCleanCompile(process);

      final result = await restart.timeout(const Duration(seconds: 5));

      expect(result.compileSuccess, isTrue);
      expect(result.outcome, isA<StrategyThrew>());
      expect(result.outcome!.message, contains('the page went away'));
    });

    // The other half of the split: a throw from the COMPILE must still be a
    // compile failure, and must reach no device. A server that was never
    // started throws `StateError('Frontend server not started')` from
    // `recompile` itself, which is the phase boundary this pins.
    test('a throw from the compile is still a compile failure', () async {
      final server = startedServer().server;
      final strategy = _RecordingReloadStrategy();

      final result = await recompileAndReload(
        frontendServer: server,
        entrypoint: 'lib/main.dart',
        invalidatedFiles: const ['package:app/main.dart'],
        sessions: const [],
        reloadStrategy: strategy,
      ).timeout(const Duration(seconds: 5));

      expect(result.compileSuccess, isFalse);
      expect(result.diagnostics, contains('not started'));
      expect(
        strategy.calls,
        isEmpty,
        reason: 'nothing compiled, so nothing may be applied',
      );
    });
  });

  group('DeviceSession.shutdown', () {
    test('a DDS that never shuts down still lets the app be stopped', () async {
      final process = FakeProcess();
      final device = MacOSDevice()
        ..teardownBound = const Duration(milliseconds: 50);
      final session = DeviceSession(
        device: device,
        appInstance: AppInstance(process: process),
        vmClient: null,
        appId: 'app-1',
        dds: _HangingDds(),
      );

      // `dds.shutdown()` sits before `device.stop()`, so an unbounded wait
      // there is not just a slow exit — the app is never asked to stop at all.
      await session
          .shutdown(MachineProtocol(enabled: false, output: BufferSink()))
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail(
              'shutdown() never returned: the DDS '
              'shutdown is still unbounded',
            ),
          );

      expect(
        process.signals,
        contains(ProcessSignal.sigterm),
        reason: 'the app must be stopped even when the DDS will not go',
      );
    });
  });

  /// What the watcher does with an edit it cannot map.
  ///
  /// The resolver is built by assembly, and assembly can fail on a `bazel
  /// build` and be retried by a later reload — so there are runs where every
  /// watched path resolves to null for a while, including the path of the file
  /// whose fix is what the pending attempt is waiting for.
  group('a watched edit with no resolver', () {
    /// Run the loop over one injected watcher and return what it dispatched.
    Future<List<Map<String, dynamic>>> dispatchesFor({
      required bool awaitingAssembly,
    }) async {
      final dispatched = <Map<String, dynamic>>[];
      final commandRunner = CommandRunner()
        ..register('app.hotReload', (params) async {
          dispatched.add(params);
          return {'message': 'Hot reload successful'};
        });

      final fake = _FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(
        root: '/root',
        debounce: const Duration(milliseconds: 5),
        watcherFactory: (_) => fake,
      );
      await watcher.start();

      final shutdown = Completer<void>();
      // Supplied, or the loop reads the process's real stdin — which the second
      // test in this group cannot subscribe to a second time.
      final keys = StreamController<List<int>>();
      final loop = runInteractiveSession(
        sessions: [
          DeviceSession(
            device: _TrackingDevice('test_device', onStop: () {}),
            appInstance: AppInstance(process: FakeProcess()),
            vmClient: null,
            appId: 'app_1',
          ),
        ],
        frontendServer: null,
        protocol: MachineProtocol(enabled: false),
        commandRunner: commandRunner,
        devToolsEnabled: false,
        dartExecutable: 'dart',
        hotReloadUnavailable: null,
        watcher: watcher,
        // The state under test: no resolver at all, because the build that
        // would have produced one failed.
        resolver: () => null,
        awaitingAssembly: () => awaitingAssembly,
        log: (_) {},
        keyboardReader: () => keys.stream,
        setEchoMode: (_) {},
        setLineMode: (_) {},
        shutdownSignal: shutdown.future,
      );

      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/main.dart'));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      shutdown.complete();
      await loop;
      await watcher.stop();
      await keys.close();
      return dispatched;
    }

    test('wakes a pipeline that still owes a build', () async {
      // Dropping this edit is what would leave the fix unseen: the reload
      // derives its own work from the disk snapshot once the pipeline exists,
      // so an empty `invalidatedFiles` costs nothing — and it is the only
      // thing the watcher can send when nothing can map a path yet.
      final dispatched = await dispatchesFor(awaitingAssembly: true);

      expect(dispatched, hasLength(1));
      expect(dispatched.single['invalidatedFiles'], isEmpty);
    });

    test('leaves a pipeline that will never assemble alone', () async {
      // A device with no compiler, an app that died: those runs answer every
      // save with a refusal if the watcher keeps waking them, and none of the
      // refusals is news. Asked of the pipeline rather than inferred from the
      // null resolver, which both states share.
      expect(await dispatchesFor(awaitingAssembly: false), isEmpty);
    });
  });

  /// `app.started` means the app's process is up and its debug link answers —
  /// which is what upstream's daemon protocol means by it, and what we mean
  /// too. It does not mean the app has painted, and on a device those are a
  /// minute apart. [DeviceSession.drivable] is that second question, asked
  /// separately.
  group('DeviceSession.drivable', () {
    final serviceUri = Uri.parse('http://127.0.0.1:8181/');

    FakeVmService newFake() => FakeVmService(
      isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
    );

    Future<VmServiceClient> connected(FakeVmService fake) async {
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(serviceUri, createDevFS: false);
      return client;
    }

    DeviceSession sessionOn(Device device, VmServiceClient? client) =>
        DeviceSession(
          device: device,
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: client,
          appId: 'app_1',
        );

    /// The params of every `app.progress` event on [sink], in order.
    List<Map<String, dynamic>> progressFrom(BufferSink sink) => [
      for (final line in sink.buffer.toString().trim().split('\n'))
        if (line.startsWith('[{'))
          for (final msg
              in (jsonDecode(line) as List).cast<Map<String, dynamic>>())
            if (msg['event'] == 'app.progress')
              msg['params'] as Map<String, dynamic>,
    ];

    // The wait's timeout timer, sized in minutes for a physical device, keeps
    // the Dart process alive on its own, so a run that ends has to release it
    // rather than sit out the budget.
    test(
      'the run ending releases the wait rather than sitting on it',
      () async {
        final sink = BufferSink();
        final fake = newFake();
        final session = sessionOn(MacOSDevice(), await connected(fake));
        // Answering nothing, so only the abandon can end this.
        fake.callServiceExtensionGate = Completer<void>();

        final waiting = session.waitUntilDrivable(
          MachineProtocol(enabled: true, output: sink),
        );
        await pumpEventQueue();
        session.stopWaitingForFirstFrame();

        // MacOSDevice's budget is 30s; this must not take it.
        await waiting.timeout(const Duration(seconds: 5));

        expect(session.drivable.isSettled, isTrue);
        expect(session.drivable.isReady, isFalse);
        expect(session.drivable.unavailableReason, contains('run ended'));
        expect(
          progressFrom(sink).last['finished'],
          isTrue,
          reason: 'the spinner has to stop even when the answer never came',
        );
        fake.callServiceExtensionGate!.complete();
      },
    );

    test('a live debug connection is not on its own drivable', () async {
      final session = sessionOn(MacOSDevice(), await connected(newFake()));

      expect(
        session.drivable.isSettled,
        isFalse,
        reason: 'the VM service answering is not the app having painted',
      );
    });

    test('settles ready on the first frame, and says so as progress', () async {
      final sink = BufferSink();
      final protocol = MachineProtocol(enabled: true, output: sink);
      final fake = newFake();
      final session = sessionOn(MacOSDevice(), await connected(fake));
      // The app is up but answering nothing, so the frame event is the only
      // thing that can settle this — the physical-device case.
      fake.callServiceExtensionGate = Completer<void>();

      final waiting = session.waitUntilDrivable(protocol);
      await pumpEventQueue();
      fake.emitFirstFrame();
      await waiting;

      expect(session.drivable.isReady, isTrue);
      expect(session.drivable.unavailableReason, isNull);

      final progress = progressFrom(sink);
      expect(progress, hasLength(2));
      expect(progress.first['appId'], 'app_1');
      expect(progress.first['finished'], isFalse);
      expect(progress.last['finished'], isTrue);
      expect(
        progress.last['id'],
        progress.first['id'],
        reason: 'one operation starting and stopping, not two operations',
      );
      fake.callServiceExtensionGate!.complete();
    });

    test(
      'an app that never paints settles with a reason, not silence',
      () async {
        final sink = BufferSink();
        final protocol = MachineProtocol(enabled: true, output: sink);
        final session = sessionOn(
          _ImpatientDevice(),
          await connected(newFake()),
        );

        await session.waitUntilDrivable(protocol);

        expect(session.drivable.isSettled, isTrue);
        expect(session.drivable.isReady, isFalse);
        expect(
          session.drivable.unavailableReason,
          allOf(contains('app_1'), contains('rendered')),
          reason: 'a command refused for this has to be able to say why',
        );
        expect(
          progressFrom(sink).last['finished'],
          isTrue,
          reason:
              'a progress that starts and never finishes is a stuck spinner',
        );
      },
    );

    test(
      // Web sessions exist before their VM service does: DWDS hands one over
      // seconds after `app.started` and signals this gate when it does.
      // Settling the gate on the strength of a field that is always null at
      // this moment would refuse every command the browser was still on its
      // way to serving — a gate, once settled, stays settled.
      'leaves the gate alone when the client has not arrived yet',
      () async {
        final session = sessionOn(WebDevice(), null);

        await session.waitUntilDrivable(
          MachineProtocol(enabled: true, output: BufferSink()),
        );

        expect(session.drivable.isSettled, isFalse);

        session.drivable.signalReady();
        expect(session.drivable.isReady, isTrue);
      },
    );
  });
}

/// A [DirectoryWatcher] whose events a test decides.
class _FakeDirectoryWatcher implements DirectoryWatcher {
  @override
  final String path;

  final StreamController<WatchEvent> _events =
      StreamController<WatchEvent>.broadcast();

  _FakeDirectoryWatcher(this.path);

  void emit(WatchEvent event) => _events.add(event);

  @override
  Stream<WatchEvent> get events => _events.stream;

  @override
  Future<void> get ready async {}

  @override
  bool get isReady => true;

  @override
  String get directory => path;
}

/// A DDS whose `shutdown()` never completes.
///
/// It closes its socket to the app's VM service on the way out
/// (`dds_impl.dart:311`), and that peer is not ours to trust.
class _HangingDds implements DartDevelopmentService {
  @override
  Future<void> shutdown() => Completer<void>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A [ReloadStrategy] that records what it was asked to apply and applies
/// nothing. Lets a test assert that a failed compile reached no device.
class _RecordingReloadStrategy implements ReloadStrategy {
  final List<String> calls = [];

  @override
  Future<StrategyOutcome> applyReload(
    CompileResult result,
    List<DeviceSession> sessions,
  ) async {
    calls.add('reload');
    return const StrategyApplied(0);
  }

  @override
  Future<StrategyOutcome> applyRestart(
    CompileResult result,
    List<DeviceSession> sessions,
  ) async {
    calls.add('restart');
    return const StrategyApplied(0);
  }

  @override
  Future<StrategyOutcome> applyAssets(
    Set<String> changed,
    List<DeviceSession> sessions,
  ) async {
    calls.add('assets');
    return const StrategyApplied(0);
  }
}

/// A [ReloadStrategy] whose every verb throws — what a strategy does when it
/// fails before it can form a verdict of its own.
class _ThrowingReloadStrategy implements ReloadStrategy {
  final Object error;

  _ThrowingReloadStrategy(this.error);

  @override
  Future<StrategyOutcome> applyReload(
    CompileResult result,
    List<DeviceSession> sessions,
  ) async => throw error;

  @override
  Future<StrategyOutcome> applyRestart(
    CompileResult result,
    List<DeviceSession> sessions,
  ) async => throw error;

  @override
  Future<StrategyOutcome> applyAssets(
    Set<String> changed,
    List<DeviceSession> sessions,
  ) async => throw error;
}

/// A device that tracks stop calls.
class _TrackingDevice extends Device {
  final String _name;
  final void Function() onStop;

  _TrackingDevice(this._name, {required this.onStop});

  @override
  String get name => _name;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnsupportedError('Not used in this test');

  @override
  Future<void> stop(AppInstance instance) async {
    onStop();
  }
}

/// A device whose budget for the app's first frame is short enough to test.
class _ImpatientDevice extends MacOSDevice {
  @override
  Duration get applyTimeout => const Duration(milliseconds: 100);
}
