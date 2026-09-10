import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/command_failure.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/session_host.dart';
import 'package:test/test.dart';

import 'fakes.dart';
import 'loopbacks.dart';

SessionHost newHost() =>
    SessionHost(isMachine: false, logger: Logger('test.session_host'));

DeviceSession newSession(String appId) => DeviceSession(
  device: MacOSDevice(),
  appInstance: AppInstance(process: FakeProcess()),
  vmClient: null,
  appId: appId,
);

void main() {
  group('SessionHost.findSession', () {
    test('finds a session by appId', () {
      final host = newHost();
      final a = newSession('a');
      host.sessions.addAll([a, newSession('b')]);

      expect(host.findSession('a'), same(a));
    });

    test('is null for an unknown appId', () {
      final host = newHost();
      host.sessions.add(newSession('a'));

      expect(host.findSession('nope'), isNull);
    });

    // A command that names no app is not asking about a particular one, so
    // there is nothing to find. `targetSessions` is what turns that into "all
    // of them" — this returning the first session instead would silently make
    // every unaddressed command act on one device in a multi-device run.
    test('is null when no appId was given', () {
      final host = newHost();
      host.sessions.add(newSession('a'));

      expect(host.findSession(null), isNull);
    });
  });

  group('SessionHost.targetSessions', () {
    test('a named appId targets just that session', () {
      final host = newHost();
      final b = newSession('b');
      host.sessions.addAll([newSession('a'), b]);

      expect(host.targetSessions({'appId': 'b'}), [same(b)]);
    });

    test('no appId targets every session', () {
      final host = newHost();
      host.sessions.addAll([newSession('a'), newSession('b')]);

      expect(host.targetSessions({}), hasLength(2));
    });

    // Empty, not "all" — the caller distinguishes the two to answer `Unknown
    // appId` rather than quietly reloading every device the user did not name.
    test('an unknown appId targets nothing', () {
      final host = newHost();
      host.sessions.add(newSession('a'));

      expect(host.targetSessions({'appId': 'ghost'}), isEmpty);
    });
  });

  group('SessionHost.performCleanup', () {
    test('runs the registered disposers and signals shutdown', () async {
      final host = newHost();
      final disposed = <String>[];
      await host.teardown.add(() async => disposed.add('first'));
      await host.teardown.add(() async => disposed.add('second'));

      await host.performCleanup();

      // Reverse registration order: resources come down the way they went up.
      expect(disposed, ['second', 'first']);
      expect(host.shutdownRequested.isCompleted, isTrue);
    });

    test('is safe to run twice', () async {
      final host = newHost();
      var disposals = 0;
      await host.teardown.add(() async => disposals++);

      await host.performCleanup();
      await host.performCleanup();

      expect(disposals, 1);
      expect(host.shutdownRequested.isCompleted, isTrue);
    });

    // The window this whole object exists to close: a `daemon.shutdown`
    // answering `app.started` reaches cleanup while setup is still building
    // things. A resource registered after that must not outlive the run.
    test('a disposer registered after cleanup runs immediately', () async {
      final host = newHost();
      await host.performCleanup();

      var disposed = false;
      await host.teardown.add(() async => disposed = true);

      expect(disposed, isTrue);
    });

    // The signal is what ends the session loop. Losing it to a failed
    // disposer leaves a run nothing can stop — including the `daemon.shutdown`
    // that just answered with a 500.
    test('signals the session loop even when a disposer throws', () async {
      final host = newHost();
      await host.teardown.add(() async => throw StateError('adb went away'));

      await expectLater(host.performCleanup(), throwsStateError);

      expect(host.shutdownRequested.isCompleted, isTrue);
    });
  });

  group('SessionHost.fail', () {
    test('records the failure and tears the session down', () async {
      final host = newHost();
      var disposed = false;
      await host.teardown.add(() async => disposed = true);

      host.fail(DevToolException('the browser never wired up'));
      await host.shutdownRequested.future;

      expect(host.deferredFailure?.message, 'the browser never wired up');
      expect(disposed, isTrue);
    });

    // The failures after the first are usually its consequences — the VM
    // service dropping because the run is already coming down, say. Reporting
    // the last one would name the symptom and lose the cause.
    test('keeps the first failure, not the last', () async {
      final host = newHost();

      host.fail(DevToolException('cause'));
      host.fail(DevToolException('consequence'));
      await host.shutdownRequested.future;

      expect(host.deferredFailure?.message, 'cause');
    });
  });

  group('SessionHost.registerLifecycleCommands', () {
    // Upstream's contract: it stops the app it names, so a client that names
    // one app of two must not lose both.
    test('app.stop needs to be told which app', () async {
      final host = newHost();
      host.registerLifecycleCommands();

      await expectLater(
        host.commandRunner.run('app.stop', {}),
        throwsA(
          isA<CommandFailure>()
              .having((e) => e.kind, 'kind', CommandFailureKind.badRequest)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('needs an appId'), contains('daemon.shutdown')),
              ),
        ),
      );
    });

    test('app.stop refuses an app this run has never heard of', () async {
      final host = newHost();
      host.registerLifecycleCommands();
      host.sessions.add(newSession('a'));

      await expectLater(
        host.commandRunner.run('app.stop', {'appId': 'ghost'}),
        throwsA(
          isA<CommandFailure>().having(
            (e) => e.kind,
            'kind',
            CommandFailureKind.notFound,
          ),
        ),
      );
    });

    // Stopping an app is not ending the run: the run ends when its last app
    // does, which the session loop decides — not this handler.
    test('app.stop stops the named app and answers for it', () async {
      final host = newHost();
      host.registerLifecycleCommands();
      host.sessions.add(newSession('a'));
      var toreDown = false;
      await host.teardown.add(() async => toreDown = true);

      final response = await host.commandRunner.run('app.stop', {
        'appId': 'a',
      });

      expect(response, {'message': 'stopped', 'appId': 'a'});
      expect(
        toreDown,
        isFalse,
        reason: 'the run owns the teardown; app.stop owns one app',
      );
    });

    test('daemon.shutdown tears down and answers', () async {
      final host = newHost();
      host.registerLifecycleCommands();

      final response = await host.commandRunner.run('daemon.shutdown', {});

      expect(response, {'message': 'shutdown'});
      expect(host.shutdownRequested.isCompleted, isTrue);
    });

    // Conditional for the same reason `app.buildInfo` is: these proxy to
    // `ext.rules_flutter.*` over a VM service, and a `--wasm` or `--profile`
    // web run has none — so advertising them there offers a surface that can
    // only answer `no VM service for <appId>`.
    test(
      'the app.* agent surface is not part of the unconditional surface',
      () {
        final host = newHost();
        host.registerLifecycleCommands();

        expect(host.commandRunner.hasCommand('app.getText'), isFalse);
        expect(host.commandRunner.hasCommand('app.tap'), isFalse);
        expect(host.commandRunner.hasCommand('app.dumpWidgetTree'), isFalse);

        host.registerAgentCommands();

        expect(host.commandRunner.hasCommand('app.getText'), isTrue);
        expect(host.commandRunner.hasCommand('app.tap'), isTrue);
        expect(host.commandRunner.hasCommand('app.dumpWidgetTree'), isTrue);
      },
    );

    // Conditional on the plan, which does not exist when the lifecycle
    // commands are registered — so it is not here, and a run that cannot
    // answer it never offers it.
    test('app.buildInfo is not part of the unconditional surface', () {
      final host = newHost();
      host.registerLifecycleCommands();

      expect(host.commandRunner.hasCommand('app.buildInfo'), isFalse);

      host.registerBuildInfo();

      expect(host.commandRunner.hasCommand('app.buildInfo'), isTrue);
    });

    // Reload and restart are deliberately NOT here: they need a pipeline the
    // host knows nothing about, and registering a stub would answer a client
    // that should have been told to wait.
    test('reload and restart are left to the pipeline', () {
      final host = newHost();
      host.registerLifecycleCommands();

      expect(host.commandRunner.hasCommand('app.hotReload'), isFalse);
      expect(host.commandRunner.hasCommand('app.restart'), isFalse);
    });
  });

  group('SessionHost.startHttpChannel', () {
    // The record is the only instruction a client gets, and under `--machine`
    // the JSON log format drops `text` — so everything a caller needs has to
    // be in the structured fields. A bare `token` reads as an `Authorization`
    // header; the channel wants a query parameter and answers a header with
    // `Invalid or missing token`, saying nothing about where it looked.
    test('every endpoint carries a URL that works, token included', () async {
      final host = newHost();
      final logger = Logger('test.session_host');
      final records = <Map<String, Object?>>[];
      final subscription = logger.onRecord.listen((r) {
        if (r.object case final Map<String, Object?> fields) {
          records.add(fields);
        }
      });
      addTearDown(subscription.cancel);
      Logger.root.level = Level.ALL;

      await host.startHttpChannel();
      addTearDown(host.closeTransports);

      final record = records.singleWhere(
        (r) => r['message'] == 'http_control_channel',
      );
      final token = record['token']! as String;
      expect(record['tokenParam'], 'token');
      final endpoints = (record['endpoints']! as List)
          .cast<Map<String, String>>();
      expect(endpoints, isNotEmpty);
      final base = host.httpChannel!.uri.toString();
      for (final endpoint in endpoints) {
        // Compared as text, not as a parsed `Uri`: two of these paths carry a
        // `{appId}` placeholder, and parsing percent-encodes the braces into
        // something a caller cannot substitute into.
        expect(endpoint['url'], '$base${endpoint['path']}?token=$token');
      }
      // The prose is rendered from the same list, so an endpoint cannot be
      // added to one and not the other.
      for (final endpoint in endpoints) {
        expect(record['text'], contains(endpoint['url']));
      }
    });
  });

  group('SessionHost.closeTransports', () {
    test('stops the HTTP channel it started', () async {
      final host = newHost();
      await host.startHttpChannel();
      final uri = host.httpChannel!.uri;

      await host.closeTransports();

      // Binding the same port again is what proves the channel is actually
      // down, rather than merely dereferenced.
      //
      // Every loopback family this host can assign, because the channel binds
      // every one of them: naming a single family asks whether *that* socket
      // was released and says nothing about the others, so a teardown that
      // left one listening would still pass. Discovered rather than named for
      // the same reason the channel discovers them — a host with no IPv6
      // cannot assign ::1, and asking for it there reports on the machine.
      for (final address in await assignableLoopbacks()) {
        final rebound = await HttpServer.bind(address, uri.port);
        await rebound.close();
      }
    });

    test('is safe with no HTTP channel started', () async {
      final host = newHost();

      await expectLater(host.closeTransports(), completes);
    });
  });

  // A run that ends has to let go of the signals it was listening for. They
  // are a transport like stdin and the HTTP channel, and an uncancelled
  // `ProcessSignal.watch()` keeps the Dart VM alive after `main` returns: a
  // tool that has answered `daemon.shutdown` and released the app, the browser
  // and every socket it held will still sit there until it is killed.
  group('SessionHost shutdown signals', () {
    test('closeTransports stops listening for them', () async {
      final host = newHost();
      final signals = StreamController<ProcessSignal>();
      host.listenForShutdownSignals(
        signals: [signals.stream],
        exitProcess: (_) {},
      );
      expect(signals.hasListener, isTrue);

      await host.closeTransports();

      expect(signals.hasListener, isFalse);
    });

    // The signalled path reaches `closeTransports` from *inside* the signal
    // handler, so it cancels the very subscription it is running on. The exit
    // is what comes after that cancellation, and it still has to happen.
    test('a signalled shutdown still exits after cancelling itself', () async {
      final host = newHost();
      final signals = StreamController<ProcessSignal>();
      final exited = Completer<int>();
      host.listenForShutdownSignals(
        signals: [signals.stream],
        exitProcess: (code) {
          if (!exited.isCompleted) exited.complete(code);
        },
      );

      signals.add(ProcessSignal.sigterm);

      expect(await exited.future, 143);
      expect(signals.hasListener, isFalse);
    });

    // One handler across every signal: a SIGINT after a SIGTERM is the second
    // signal, not another first one, and the teardown must not run beside
    // itself. Two streams because that is how the signals actually arrive —
    // `sigint.watch()` and `sigterm.watch()` are separate streams.
    test('a second signal on another stream does not re-run cleanup', () async {
      final host = newHost();
      final sigint = StreamController<ProcessSignal>();
      final sigterm = StreamController<ProcessSignal>();
      final exitCodes = <int>[];
      var cleanups = 0;
      await host.teardown.add(() async => cleanups++);
      host.listenForShutdownSignals(
        signals: [sigint.stream, sigterm.stream],
        exitProcess: exitCodes.add,
      );

      sigint.add(ProcessSignal.sigint);
      sigterm.add(ProcessSignal.sigterm);
      await pumpEventQueue();

      expect(cleanups, 1);
      expect(exitCodes, isNotEmpty);
    });

    test('is safe to close with no signals installed', () async {
      final host = newHost();

      await expectLater(host.closeTransports(), completes);
    });
  });
}
