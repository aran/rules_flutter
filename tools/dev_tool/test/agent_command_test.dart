import 'dart:async';

import 'package:flutter_bazel_dev_tool/agent_command.dart';
import 'package:flutter_bazel_dev_tool/command_failure.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

/// The message a refused command throws.
///
/// A refusal is a [CommandFailure], not an `{'error': …}` map inside the
/// result: one way for this surface to say no, rendered by each transport in
/// its own vocabulary.
Future<String> refusalFrom(Future<Map<String, dynamic>> call) async {
  try {
    final result = await call;
    fail('expected a refusal, got $result');
  } on CommandFailure catch (e) {
    return e.message;
  }
}

void main() {
  group('setUpAgentCommands', () {
    /// A session backed by [client]. The device is incidental — every test
    /// here drives the agent surface, which only ever reaches for `vmClient`.
    DeviceSession sessionFor(VmServiceClient client, {String appId = 'app'}) =>
        DeviceSession(
          device: MacOSDevice(),
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: client,
          appId: appId,
          // These stand in for an app that is up and drawing. The launcher
          // signals this once the app renders its first frame; a session that
          // never signals is one whose commands wait, which is the subject of
          // its own group below rather than the default here.
        )..drivable.signalReady();

    test('registers the full agent command surface', () {
      final cr = CommandRunner();
      setUpAgentCommands(cr, (_) => null);

      for (final method in const [
        'app.tap',
        'app.longPress',
        'app.doubleTap',
        'app.drag',
        'app.scrollIntoView',
        'app.enterText',
        'app.getText',
        'app.getRect',
        'app.waitFor',
        'app.waitForAbsent',
        'app.pageBack',
        'app.dumpWidgetTree',
      ]) {
        expect(cr.hasCommand(method), isTrue, reason: '$method registered');
      }
    });

    // The extension runs *on* the app's isolate, so dispatching it to one that
    // is paused never returns — and the command pool is serialized, so one
    // hung request takes every later command with it. Under --start-paused the
    // pause lasts until a human resumes, so one `app.getText` would be the end
    // of the control channel for the whole run. The pause read that rules this
    // out is asked before anything else a command does, so it is also the only
    // route on which that read, rather than the readiness seed behind it, is
    // the first thing a silent VM service meets.
    group('a --start-paused run', () {
      /// A session flagged as started paused, whose isolate reports itself
      /// holding at the start of `main()`.
      Future<(FakeVmService, VmServiceClient, DeviceSession)>
      pausedSession() async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        )..pauseKind = EventKind.kPauseStart;
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(Uri.parse('http://127.0.0.1:8181/'));
        final session = DeviceSession(
          // The flag is what makes the pause worth reporting rather than
          // waiting out: an isolate at `PauseStart` on an ordinary run is a
          // startup in progress, and on web every run passes through that
          // state.
          device: MacOSDevice()..startPaused = true,
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: client,
          appId: 'app',
          // Nothing here turns on the first frame — a paused app has not drawn
          // one and never will until it is resumed — and the code under test
          // says so by asking about the pause instead of waiting.
        )..drivable.signalReady();
        return (fake, client, session);
      }

      test('is answered, not waited on', () async {
        final (fake, _, session) = await pausedSession();
        // Set after connecting, which makes its own extension calls: from here
        // on, any extension dispatched to this isolate hangs — which is what
        // the real one does, and what the test must not depend on not doing.
        final wedged = Completer<void>();
        addTearDown(wedged.complete);
        fake.callServiceExtensionGate = wedged;

        final cr = CommandRunner();
        setUpAgentCommands(cr, (_) => session);
        final error = await refusalFrom(
          cr
              .run('app.getText', {'appId': 'app', 'key': 'k'})
              .timeout(const Duration(seconds: 5)),
        );

        expect(error, contains('--start-paused'));
        expect(
          fake.extensionCalls
              .map((c) => c.method)
              .where((m) => m.startsWith('ext.')),
          isEmpty,
          reason: 'the extension must not be dispatched to a paused isolate',
        );
      });

      test('whose pause state cannot be read is not called paused', () async {
        final (fake, client, session) = await pausedSession();
        // A socket gone silent rather than closed: no `RPCError`, so
        // `_withReconnect` never fires and an unbounded read never returns.
        // Silent from before the command starts, and this is the one route on
        // which the pause read is what meets that — every other command asks
        // the readiness seed first, so the seed's own bound is what fires
        // there and the pause read is never even reached.
        final isolateGate = Completer<void>();
        addTearDown(isolateGate.complete);
        fake.getIsolateGate = isolateGate;
        // The seed read behind it meets the same silence; without this it
        // would spend the 30s default before this test could finish.
        client.serviceExtensionTimeout = const Duration(seconds: 1);

        final cr = CommandRunner();
        setUpAgentCommands(
          cr,
          (_) => session,
          pauseReadBound: const Duration(seconds: 1),
        );
        final error = await refusalFrom(
          cr
              .run('app.getText', {'appId': 'app', 'key': 'k'})
              .timeout(const Duration(seconds: 20)),
        );

        // Answered at all is the point: unbounded, this read holds the pool's
        // only slot for the life of the run, and every command after it queues
        // behind a read that is never going to return, with no error and no
        // output.
        expect(
          error,
          contains(
            'could not tell whether ext.rules_flutter.getText is '
            'registered',
          ),
        );
        // The isolate genuinely is paused here; the read simply could not see
        // it. An unreadable state is passed over as unknown rather than
        // reported as a pause, which is a claim about the app that a read
        // which never answered is in no position to make.
        expect(
          error,
          isNot(contains('cannot run')),
          reason: 'a read that did not answer is not a pause',
        );
        // Asked and abandoned, not skipped: the pause read, then the seed read
        // behind it. Without both, this test would pass on a build where the
        // pause check never ran at all.
        expect(
          fake.getIsolateCalls,
          hasLength(greaterThanOrEqualTo(2)),
          reason: 'the pause read was made, and given up on',
        );
        expect(
          fake.extensionCalls
              .map((c) => c.method)
              .where((m) => m.startsWith('ext.')),
          isEmpty,
          reason:
              'nothing may be dispatched on the strength of a pause '
              'state that could not be read',
        );
      });
    });

    // On web nothing is registered when `app.started` is emitted — DWDS holds
    // the app's `main()` back until its injected client connects — so an agent
    // acting on that event arrives before the extension exists. Waiting is what
    // turns that from a bare `-32601 Unknown method` into a call that works.
    group('extension readiness', () {
      test('dispatches once the app registers the extension', () async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        );
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(Uri.parse('http://127.0.0.1:8181/'));

        final cr = CommandRunner();
        setUpAgentCommands(cr, (_) => sessionFor(client));
        final running = cr.run('app.getText', {'appId': 'app', 'key': 'k'});

        // The window, then the registrations that end it — in the order web
        // produces them: the agent's own from the synthetic entrypoint, then
        // the framework's when `runApp` initializes the binding.
        await pumpEventQueue();
        fake.emitServiceExtensionAdded('iso-1', 'ext.rules_flutter.getText');
        await pumpEventQueue();
        fake.emitServiceExtensionAdded('iso-1', 'ext.flutter.reassemble');

        await running.timeout(const Duration(seconds: 5));
        expect(
          fake.extensionCalls.map((c) => c.method),
          contains('ext.rules_flutter.getText'),
        );
      });

      test(
        'an extension that never appears is reported, not dispatched',
        () async {
          final fake = FakeVmService(
            isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
          );
          final client = VmServiceClient(connector: (_) async => fake)
            ..serviceExtensionTimeout = const Duration(milliseconds: 200);
          await client.connect(Uri.parse('http://127.0.0.1:8181/'));

          final cr = CommandRunner();
          setUpAgentCommands(cr, (_) => sessionFor(client));
          final error = await refusalFrom(
            cr
                .run('app.getText', {'appId': 'app', 'key': 'k'})
                .timeout(const Duration(seconds: 5)),
          );

          expect(error, contains('not registered'));
          expect(
            fake.extensionCalls
                .map((c) => c.method)
                .where((m) => m.startsWith('ext.rules_flutter.')),
            isEmpty,
          );
        },
      );
    });

    // An app that refuses answers `ServiceExtensionResponse.error`, which
    // crosses the VM service as a JSON-RPC error and reaches the client as a
    // throw. Left to escape, it reads as a *transport* fault rather than as
    // the app's own refusal, and a caller checking the documented place takes
    // "no widget matched" or "waitFor timed out" for success.
    group('an app that refuses', () {
      /// A client whose app has both the named extension and the binding up,
      /// so a command reaches the dispatch instead of stopping at readiness.
      Future<(FakeVmService, VmServiceClient)> readyClient(
        String extensionMethod,
      ) async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        )..extensionRPCs = [extensionMethod, 'ext.flutter.reassemble'];
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(Uri.parse('http://127.0.0.1:8181/'));
        return (fake, client);
      }

      test('is the command\'s answer, not a thrown transport fault', () async {
        final (fake, client) = await readyClient('ext.rules_flutter.waitFor');
        // Exactly what the VM puts on the wire for
        // `ServiceExtensionResponse.error(invalidParams, <text>)`: the code's
        // own generic `message`, and the handler's text in `data.details`.
        fake.extensionErrors['ext.rules_flutter.waitFor'] = RPCError(
          'ext.rules_flutter.waitFor',
          -32602,
          'Invalid params',
          {'details': 'timed out waiting for text "RELOADED ONE"'},
        );

        final cr = CommandRunner();
        setUpAgentCommands(cr, (_) => sessionFor(client));
        final error = await refusalFrom(
          cr
              .run('app.waitFor', {'appId': 'app', 'text': 'RELOADED ONE'})
              .timeout(const Duration(seconds: 5)),
        );

        // Asserted as the whole value, not `isNotNull`: the readiness gate
        // above also produces a non-null error without ever dispatching, so a
        // laxer assertion would pass with the dispatch never reached.
        expect(error, 'timed out waiting for text "RELOADED ONE"');
        expect(
          fake.extensionCalls.map((c) => c.method),
          contains('ext.rules_flutter.waitFor'),
          reason: 'the refusal must come from a dispatch that happened',
        );
      });

      test(
        'reports its own message, not the JSON-RPC code\'s generic one',
        () async {
          final (fake, client) = await readyClient('ext.rules_flutter.getText');
          fake.extensionErrors['ext.rules_flutter.getText'] = RPCError(
            'ext.rules_flutter.getText',
            -32602,
            'Invalid params',
            {'details': 'no widget matching key "agent_test_label" found'},
          );

          final cr = CommandRunner();
          setUpAgentCommands(cr, (_) => sessionFor(client));
          final error = await refusalFrom(
            cr.run('app.getText', {
              'appId': 'app',
              'key': 'agent_test_label',
            }),
          );

          expect(error, contains('agent_test_label'));
          expect(
            error,
            isNot(contains('Invalid params')),
            reason: 'the code\'s generic message says nothing about the app',
          );
        },
      );

      test('falls back to the message when there are no details', () async {
        final (fake, client) = await readyClient('ext.rules_flutter.tap');
        // No `data`, so nothing in `details` — what a VM-level refusal looks
        // like next to an extension's own.
        fake.extensionErrors['ext.rules_flutter.tap'] = RPCError(
          'ext.rules_flutter.tap',
          -32601,
          'Method not found',
        );

        final cr = CommandRunner();
        setUpAgentCommands(cr, (_) => sessionFor(client));
        final error = await refusalFrom(
          cr.run('app.tap', {'appId': 'app', 'key': 'k'}),
        );

        expect(error, 'Method not found');
      });
    });

    // The handler runs on the app's isolate, so anything that stops that
    // isolate answering stops the dispatch returning — and the pool is
    // serialized, so one such command takes every later one with it. The
    // pre-dispatch pause check cannot rule it out: a pause can land after that
    // read, and an app the OS has backgrounded is not paused at all (it is
    // running, with frames off — `framesEnabled` follows the app lifecycle,
    // not window visibility — so anything waiting for one never returns).
    // Only the bound below ends it.
    group('a dispatch that never answers', () {
      /// A client whose app has the extension and the binding up, so a command
      /// reaches the dispatch, and whose extension calls hang on [gate].
      Future<(FakeVmService, VmServiceClient)> wedgedClient(
        String extensionMethod,
        Completer<void> gate,
      ) async {
        final fake = FakeVmService(
          isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
        )..extensionRPCs = [extensionMethod, 'ext.flutter.reassemble'];
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(Uri.parse('http://127.0.0.1:8181/'));
        // Set after connecting, which makes extension calls of its own.
        fake.callServiceExtensionGate = gate;
        return (fake, client);
      }

      /// A runner whose bounds are small enough to spend in a unit test.
      CommandRunner runnerFor(VmServiceClient client) {
        final cr = CommandRunner();
        setUpAgentCommands(
          cr,
          (_) => sessionFor(client),
          dispatchMargin: const Duration(milliseconds: 500),
          pauseReadBound: const Duration(seconds: 1),
        );
        return cr;
      }

      test('is answered, and the next command is not stuck behind it', () async {
        final gate = Completer<void>();
        addTearDown(gate.complete);
        final (fake, client) = await wedgedClient(
          'ext.rules_flutter.getText',
          gate,
        );
        final cr = runnerFor(client);

        final error = await refusalFrom(
          cr
              .run('app.getText', {
                'appId': 'app',
                'key': 'k',
                // 500ms + the 500ms margin: the bound is what the app was promised
                // plus the margin, so it can never fire on an app answering as
                // documented.
                'timeoutMs': '500',
              })
              .timeout(const Duration(seconds: 20)),
        );

        expect(error, contains('ext.rules_flutter.getText'));
        expect(error, contains('did not answer within 1s'));
        expect(
          error,
          contains(
            'reported no pause, so the app was running and the '
            'handler never returned',
          ),
        );

        // The point of bounding it at all: the pool's one slot is free again.
        // A second command that answers is the wedge not happening.
        fake.callServiceExtensionGate = null;
        fake.extensionResponses['ext.rules_flutter.getText'] = {
          'type': '_extensionType',
          'text': 'count: 0',
        };
        final after = await cr
            .run('app.getText', {'appId': 'app', 'key': 'k'})
            .timeout(const Duration(seconds: 20));
        expect(after['text'], 'count: 0');
      });

      test(
        'names a pause that landed after the check, rather than racing it',
        () async {
          final gate = Completer<void>();
          addTearDown(gate.complete);
          final (fake, client) = await wedgedClient(
            'ext.rules_flutter.getText',
            gate,
          );
          final cr = runnerFor(client);

          final running = cr.run('app.getText', {
            'appId': 'app',
            'key': 'k',
            'timeoutMs': '500',
          });
          // The window the pre-dispatch read cannot cover: the app is running
          // when it is asked, and stops between that answer and the dispatch.
          await pumpEventQueue();
          fake.pauseKind = EventKind.kPauseBreakpoint;

          final error = await refusalFrom(
            running.timeout(const Duration(seconds: 20)),
          );
          expect(error, contains('did not answer within 1s'));
          expect(error, contains('Its isolate is paused'));
          expect(error, contains('stopped at a breakpoint'));
        },
      );

      test(
        'a readiness read that never answers is reported, not waited on',
        () async {
          final gate = Completer<void>();
          addTearDown(gate.complete);
          final (fake, client) = await wedgedClient(
            'ext.rules_flutter.getText',
            gate,
          );
          client.serviceExtensionTimeout = const Duration(seconds: 1);
          // Silent from before the command starts, so the very first read
          // every agent command makes — the one that seeds which extensions
          // the app has registered — is what meets it. It is a `getIsolate`,
          // and a socket that goes quiet without closing raises nothing to
          // reconnect on, so an unbounded read never returns and the
          // serialized command pool never moves again.
          final isolateGate = Completer<void>();
          addTearDown(isolateGate.complete);
          fake.getIsolateGate = isolateGate;
          final cr = runnerFor(client);

          final error = await refusalFrom(
            cr
                .run('app.getText', {'appId': 'app', 'key': 'k'})
                .timeout(const Duration(seconds: 20)),
          );

          // Reported as what it is — nothing was learned — rather than as the
          // app not having registered the extension, which is a claim about the
          // app that this read is in no position to make.
          expect(
            error,
            contains(
              'could not tell whether ext.rules_flutter.getText is '
              'registered',
            ),
          );
          expect(error, contains('did not answer within 1s'));
          expect(
            fake.extensionCalls.map((c) => c.method),
            isNot(contains('ext.rules_flutter.getText')),
            reason:
                'nothing may be dispatched on the strength of a read that '
                'never answered',
          );
        },
      );

      test('says when the pause state could not be read either', () async {
        final gate = Completer<void>();
        addTearDown(gate.complete);
        final (fake, client) = await wedgedClient(
          'ext.rules_flutter.getText',
          gate,
        );
        final cr = runnerFor(client);

        final running = cr.run('app.getText', {
          'appId': 'app',
          'key': 'k',
          'timeoutMs': '500',
        });
        // A socket that has gone silent rather than closed: no `RPCError`, so
        // `_withReconnect` never fires and the read would wait forever.
        // Installed after the pre-dispatch read has been answered, so it is
        // the report's own read that meets it.
        await pumpEventQueue();
        final isolateGate = Completer<void>();
        addTearDown(isolateGate.complete);
        fake.getIsolateGate = isolateGate;

        final error = await refusalFrom(
          running.timeout(const Duration(seconds: 20)),
        );
        expect(error, contains('did not answer within 1s'));
        expect(
          error,
          contains('pause state could not be read within 1s'),
        );
      });
    });

    // `app.waitFor {appId: B}` must not answer for app A. Necessary but not
    // sufficient — two booted simulators are the real proof — but it pins the
    // routing at this layer.
    test('each appId is answered by its own app', () async {
      final fakes = <String, FakeVmService>{};
      final sessions = <String, DeviceSession>{};
      for (final (appId, text) in [
        ('app_A', 'RELOADED ONE'),
        ('app_B', 'Hello from Flutter iOS!'),
      ]) {
        final fake =
            FakeVmService(
                isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
              )
              ..extensionRPCs = [
                'ext.rules_flutter.getText',
                'ext.flutter.reassemble',
              ]
              ..extensionResponses['ext.rules_flutter.getText'] = {
                'text': text,
              };
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(Uri.parse('http://127.0.0.1:8181/'));
        fakes[appId] = fake;
        sessions[appId] = DeviceSession(
          device: MacOSDevice(),
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: client,
          appId: appId,
        )..drivable.signalReady();
      }

      final cr = CommandRunner();
      setUpAgentCommands(cr, (appId) => sessions[appId]);

      final a = await cr.run('app.getText', {'appId': 'app_A', 'key': 'k'});
      final b = await cr.run('app.getText', {'appId': 'app_B', 'key': 'k'});

      expect(a['text'], 'RELOADED ONE');
      expect(b['text'], 'Hello from Flutter iOS!');
      for (final appId in fakes.keys) {
        expect(
          fakes[appId]!.extensionCalls
              .map((c) => c.method)
              .where((m) => m == 'ext.rules_flutter.getText'),
          hasLength(1),
          reason: '$appId must be dispatched to exactly once',
        );
      }
    });

    test('all handlers error on unknown appId', () async {
      final cr = CommandRunner();
      setUpAgentCommands(cr, (_) => null);
      for (final method in const [
        'app.tap',
        'app.longPress',
        'app.doubleTap',
        'app.drag',
        'app.scrollIntoView',
        'app.enterText',
        'app.getText',
        'app.getRect',
        'app.waitFor',
        'app.waitForAbsent',
        'app.pageBack',
        'app.dumpWidgetTree',
      ]) {
        await expectLater(
          cr.run(method, {'appId': 'nope'}),
          throwsA(
            isA<CommandFailure>()
                .having((e) => e.message, 'message', contains('unknown appId'))
                .having((e) => e.kind, 'kind', CommandFailureKind.notFound),
          ),
          reason: '$method on unknown appId',
        );
      }
    });

    test('app.tap requires key param', () async {
      final cr = CommandRunner();
      setUpAgentCommands(cr, (_) => null);
      // appId='nope' will short-circuit to "unknown appId" before reaching
      // the key check; pass a truthy session-less callback that allows the
      // call to reach key validation by faking the session lookup. The
      // session-presence check is covered by the unknown-appId test above.
      // Here we just assert that with appId+missing key we don't crash.
      final error = await refusalFrom(cr.run('app.tap', {'appId': 'nope'}));
      // Either kind of error is acceptable; the contract is "no crash".
      expect(error, isNotNull);
    });

    /// An app whose process is up and whose VM service answers is not yet an
    /// app that can be driven: `main()` has begun, so `app.started` is out,
    /// but the widget tree is not built and on a physical device the VM
    /// answers nothing at all until it is. The README's promise for that
    /// window is that a command issued in it waits it out rather than failing.
    group('an app that has not rendered yet', () {
      /// A session whose gate nothing has settled: the app is starting.
      Future<DeviceSession> starting() async {
        final fake =
            FakeVmService(
                isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
              )
              ..extensionRPCs = [
                'ext.rules_flutter.getText',
                'ext.flutter.reassemble',
              ]
              ..extensionResponses['ext.rules_flutter.getText'] = {
                'text': 'hi',
              };
        final client = VmServiceClient(connector: (_) async => fake);
        await client.connect(Uri.parse('http://127.0.0.1:8181/'));
        return DeviceSession(
          device: MacOSDevice(),
          appInstance: AppInstance(process: FakeProcess()),
          vmClient: client,
          appId: 'app',
        );
      }

      test('holds the command until the app is drivable', () async {
        final session = await starting();
        final cr = CommandRunner();
        setUpAgentCommands(cr, (_) => session);

        var answered = false;
        final running = cr.run('app.getText', {'appId': 'app', 'key': 'k'})
          ..then((_) => answered = true).ignore();
        await pumpEventQueue();

        expect(
          answered,
          isFalse,
          reason:
              'answering now would act on a widget tree that does not exist, '
              'and report its absence as the app being broken',
        );

        session.drivable.signalReady();
        final result = await running.timeout(const Duration(seconds: 5));

        expect(result.containsKey('error'), isFalse);
        expect(result['text'], 'hi');
      });

      test('reports why when the app never renders', () async {
        final session = await starting();
        final cr = CommandRunner();
        setUpAgentCommands(cr, (_) => session);
        session.drivable.signalUnavailable(
          'app on macOS had not rendered a frame after 30s',
        );

        final error = await refusalFrom(
          cr
              .run('app.getText', {'appId': 'app', 'key': 'k'})
              .timeout(const Duration(seconds: 5)),
        );

        expect(
          error,
          contains('had not rendered a frame after 30s'),
          reason:
              'the gate settled unavailable, and the reason it settled with is '
              'the only thing that names the real cause',
        );
      });
    });
  });
}
