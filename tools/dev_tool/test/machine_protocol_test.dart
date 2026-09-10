import 'dart:async';
import 'dart:convert';

import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  /// Command discovery for a `--machine` client.
  ///
  /// Such a client is the process that spawned this one: it reads stdout from
  /// the first byte and cannot miss `daemon.connected`, but it has no way to
  /// know to *ask* for anything. So the surface is pushed to it — once at
  /// connect, and again whenever it moves — rather than offered as a call it
  /// must first learn exists.
  group('command discovery', () {
    List<Map<String, dynamic>> eventsOf(BufferSink sink, String name) => [
      for (final line in sink.lines)
        ...(json.decode(line) as List).cast<Map<String, dynamic>>().where(
          (m) => m['event'] == name,
        ),
    ];

    test('daemon.connected carries the surface and the contract version', () {
      final sink = BufferSink();
      final runner = CommandRunner()
        ..register('app.stop', (_) async => {})
        ..register('app.hotReload', (_) async => {}, longRunning: true);
      MachineProtocol(
        enabled: true,
        commandRunner: runner,
        output: sink,
        inputLines: const Stream<String>.empty(),
      ).startListening();

      final connected = eventsOf(sink, 'daemon.connected').single;
      final params = connected['params'] as Map<String, dynamic>;
      expect(params['protocolVersion'], MachineProtocol.protocolVersion);
      expect(params['commands'], [
        {'name': 'app.hotReload', 'longRunning': true},
        {'name': 'app.stop', 'longRunning': false},
      ]);
    });

    test(
      'a command registered later is announced, not left to be asked for',
      () async {
        // The agent surface only exists once the VM service is up, which on web
        // and on an iOS device is well after app.started — so a client that
        // read daemon.connected and stopped listening would have a stale list.
        // Wired the way SessionHost wires them, so the coalescing and the
        // seeding are exercised together rather than driven by hand.
        final sink = BufferSink();
        late MachineProtocol protocol;
        final runner = CommandRunner(
          onCommandsChanged: () => protocol.commandsChanged(),
        );
        protocol = MachineProtocol(
          enabled: true,
          commandRunner: runner,
          output: sink,
          inputLines: const Stream<String>.empty(),
        );

        // Registered before the client is told anything — the ordering a real
        // run has, where reload, lifecycle and agent commands are all in place
        // before `startListening`.
        runner.register('app.stop', (_) async => {});
        protocol.startListening();
        expect(
          ((eventsOf(sink, 'daemon.connected').single['params']
                  as Map)['commands']
              as List),
          [
            {'name': 'app.stop', 'longRunning': false},
          ],
        );

        // That registration's announcement is still pending. It must not fire:
        // connect just carried the same list, so an announcement here would
        // restate it verbatim.
        await Future<void>.delayed(Duration.zero);
        expect(
          eventsOf(sink, 'daemon.commandsChanged'),
          isEmpty,
          reason: 'connect already carried app.stop',
        );

        // A genuinely new command is announced, with the whole surface.
        runner.register('app.getText', (_) async => {});
        await Future<void>.delayed(Duration.zero);
        expect(
          ((eventsOf(sink, 'daemon.commandsChanged').single['params']
                  as Map)['commands']
              as List),
          [
            {'name': 'app.getText', 'longRunning': false},
            {'name': 'app.stop', 'longRunning': false},
          ],
        );
      },
    );
  });

  group('MachineProtocol', () {
    late BufferSink sink;

    setUp(() {
      sink = BufferSink();
    });

    test('sendEvent does nothing when disabled', () {
      final protocol = MachineProtocol(enabled: false, output: sink);
      protocol.sendEvent('app.start', {'appId': 'test'});
      expect(sink.buffer.toString(), isEmpty);
    });

    test('sendEvent emits JSON-wrapped event', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.sendEvent('app.start', {'appId': 'test'});
      final lines = sink.lines;
      expect(lines, hasLength(1));
      final decoded = json.decode(lines.first) as List;
      expect(decoded, hasLength(1));
      final event = decoded.first as Map<String, dynamic>;
      expect(event['event'], 'app.start');
      expect(event['params']['appId'], 'test');
    });

    test('sendEvent without params omits params key', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.sendEvent('app.started');
      final decoded = json.decode(sink.lines.first) as List;
      final event = decoded.first as Map<String, dynamic>;
      expect(event['event'], 'app.started');
      expect(event.containsKey('params'), isFalse);
    });

    test('appStart event has correct fields', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appStart(
        'myapp',
        'macOS',
        supportsRestart: true,
        directory: '/work/my_app',
        launchMode: 'run',
        mode: 'debug',
      );
      final decoded = json.decode(sink.lines.first) as List;
      final params =
          (decoded.first as Map<String, dynamic>)['params']
              as Map<String, dynamic>;
      expect(params['appId'], 'myapp');
      expect(params['deviceId'], 'macOS');
      expect(params['supportsRestart'], isTrue);
      expect(params['launchMode'], 'run');
      expect(params['mode'], 'debug');
    });

    // The field upstream calls `projectDirectory`. Under `bazel run` — the
    // documented way to start this tool — `Directory.current.path` is the
    // runfiles tree, so the workspace has to be handed in rather than guessed
    // from the process.
    test('appStart reports the workspace it was given', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appStart(
        'myapp',
        'macOS',
        supportsRestart: true,
        directory: '/work/my_app',
        launchMode: 'run',
      );
      final decoded = json.decode(sink.lines.first) as List;
      final params =
          (decoded.first as Map<String, dynamic>)['params']
              as Map<String, dynamic>;
      expect(params['directory'], '/work/my_app');
      expect(
        params.containsKey('mode'),
        isFalse,
        reason:
            'attach knows no build mode, so it says nothing rather than '
            'guessing one a client cannot check',
      );
    });

    // What an IDE reads to decide whether to draw a restart button. A
    // profile-mode run has no reload pipeline on any platform, so claiming
    // otherwise offers a button that can only answer with an error.
    test('appStart reports a run that cannot restart', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appStart(
        'myapp',
        'Chrome',
        supportsRestart: false,
        directory: '/work/my_app',
        launchMode: 'run',
      );
      final decoded = json.decode(sink.lines.first) as List;
      final params =
          (decoded.first as Map<String, dynamic>)['params']
              as Map<String, dynamic>;
      expect(params['supportsRestart'], isFalse);
    });

    test('appDebugPort includes wsUri, conditionally baseUri', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      final wsUri = Uri.parse('ws://127.0.0.1:8181/abc/ws');

      protocol.appDebugPort('myapp', wsUri, null);
      var decoded = json.decode(sink.lines.first) as List;
      var params =
          (decoded.first as Map<String, dynamic>)['params']
              as Map<String, dynamic>;
      expect(params['wsUri'], wsUri.toString());
      expect(params.containsKey('baseUri'), isFalse);

      sink.buffer.clear();
      final baseUri = Uri.parse('http://127.0.0.1:8181/abc/');
      protocol.appDebugPort('myapp', wsUri, baseUri);
      decoded = json.decode(sink.lines.first) as List;
      params =
          (decoded.first as Map<String, dynamic>)['params']
              as Map<String, dynamic>;
      expect(params['baseUri'], baseUri.toString());
      expect(params['port'], 8181);
    });

    // Upstream's field, and the one a client that only wants to dial the
    // service reads. Without it such a client parses the port back out of a
    // URI we already had it from.
    test('appDebugPort carries the port', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appDebugPort(
        'myapp',
        Uri.parse('ws://127.0.0.1:8181/a/ws'),
        null,
      );
      final params =
          ((json.decode(sink.lines.first) as List).first
                  as Map<String, dynamic>)['params']
              as Map<String, dynamic>;
      expect(params['port'], 8181);
    });

    // The DevTools URL reaches a `--machine` client only here: the human line
    // beside it is a `session_report` log record, and the JSON log format
    // strips the human `text` field by design.
    test('appDevTools carries the url', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appDevTools('myapp', 'http://127.0.0.1:9100/?uri=ws://x/ws');
      final decoded =
          (json.decode(sink.lines.first) as List).first as Map<String, dynamic>;
      expect(decoded['event'], 'app.devTools');
      expect(
        (decoded['params'] as Map<String, dynamic>)['uri'],
        'http://127.0.0.1:9100/?uri=ws://x/ws',
      );
    });

    // The address a web run serves at reaches a client only here. The browser
    // this tool launches carries its own scratch profile and may be headless,
    // so someone wanting to open the page themselves has nowhere else to read
    // it but the browser process's argv.
    test('appWebLaunchUrl carries the url and whether we opened it', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appWebLaunchUrl(
        'myapp',
        'http://localhost:51140/',
        launched: true,
      );
      final decoded =
          (json.decode(sink.lines.first) as List).first as Map<String, dynamic>;
      expect(decoded['event'], 'app.webLaunchUrl');
      expect(decoded['params'], {
        'appId': 'myapp',
        'url': 'http://localhost:51140/',
        'launched': true,
      });
    });

    test('appProgress increments progressId each call', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appProgress('myapp', 'Building...');
      protocol.appProgress('myapp', 'Installing...');
      final lines = sink.lines;
      final id0 =
          ((json.decode(lines[0]) as List).first
                  as Map<String, dynamic>)['params']['id']
              as String;
      final id1 =
          ((json.decode(lines[1]) as List).first
                  as Map<String, dynamic>)['params']['id']
              as String;
      expect(id0, isNot(equals(id1)));
      expect(id0, startsWith('progress_'));
      expect(id1, startsWith('progress_'));
    });

    // An unaddressed command — a watcher save, a keypress — goes to every app,
    // and an empty string is an id no app has ever had. A client reading
    // `params['appId']` cannot tell that apart from an addressed command whose
    // id went missing, so the key is omitted instead.
    test(
      'appProgress omits appId entirely when the command addressed no app',
      () {
        final protocol = MachineProtocol(enabled: true, output: sink);
        protocol.appProgress(null, 'app.hotReload');
        protocol.appProgress('myapp', 'app.hotReload');
        final broadcast =
            ((json.decode(sink.lines[0]) as List).first
                    as Map<String, dynamic>)['params']
                as Map<String, dynamic>;
        final addressed =
            ((json.decode(sink.lines[1]) as List).first
                    as Map<String, dynamic>)['params']
                as Map<String, dynamic>;
        expect(broadcast.containsKey('appId'), isFalse);
        expect(broadcast['message'], 'app.hotReload');
        // The addressed case still carries it, so the assertion above is about
        // the null and not about the key having been dropped altogether.
        expect(addressed['appId'], 'myapp');
      },
    );

    test('appLog sets error field', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appLog('myapp', 'some error', error: true);
      final decoded = json.decode(sink.lines.first) as List;
      final params =
          (decoded.first as Map<String, dynamic>)['params']
              as Map<String, dynamic>;
      expect(params['log'], 'some error');
      expect(params['error'], isTrue);
    });

    test('appStop event structure', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appStop('myapp');
      final decoded = json.decode(sink.lines.first) as List;
      final event = decoded.first as Map<String, dynamic>;
      expect(event['event'], 'app.stop');
      expect(event['params']['appId'], 'myapp');
    });

    test('dispatches commands via CommandRunner', () async {
      final commandRunner = CommandRunner();
      commandRunner.register('app.restart', (params) async {
        return {'status': 'ok'};
      });

      final controller = StreamController<String>();
      final protocol = MachineProtocol(
        enabled: true,
        commandRunner: commandRunner,
        output: sink,
        inputLines: controller.stream,
      );
      protocol.startListening();

      controller.add(
        json.encode({
          'id': 1,
          'method': 'app.restart',
          'params': {},
        }),
      );

      // Give the async listener time to process.
      await Future.delayed(Duration(milliseconds: 50));

      final lines = sink.lines;
      expect(lines, isNotEmpty);
      // Skip daemon.connected event, find the command response.
      final responseLine = lines.firstWhere((line) {
        final decoded = json.decode(line) as List;
        final msg = decoded.first as Map<String, dynamic>;
        return msg.containsKey('id') && msg['id'] == 1;
      });
      final decoded = json.decode(responseLine) as List;
      final response = decoded.first as Map<String, dynamic>;
      expect(response['id'], 1);
      expect(response['result']['status'], 'ok');

      await controller.close();
    });

    test('an unknown method answers with upstream error shape', () async {
      final commandRunner = CommandRunner();
      final controller = StreamController<String>();
      final protocol = MachineProtocol(
        enabled: true,
        commandRunner: commandRunner,
        output: sink,
        inputLines: controller.stream,
      );
      protocol.startListening();

      controller.add(
        json.encode({
          'id': 2,
          'method': 'nonexistent.method',
        }),
      );

      await Future.delayed(Duration(milliseconds: 50));

      // Skip daemon.connected event, find the error response.
      final errorLine = sink.lines.firstWhere((line) {
        final decoded = json.decode(line) as List;
        final msg = decoded.first as Map<String, dynamic>;
        return msg.containsKey('id') && msg['id'] == 2;
      });
      final decoded = json.decode(errorLine) as List;
      final response = decoded.first as Map<String, dynamic>;
      expect(response['id'], 2);
      // Upstream's shape: `error` is a string, not a JSON-RPC {code, message}
      // object. Upstream's own DAP renders whatever arrives with `'$error'`,
      // so an object reaches the IDE's UI as a Dart map literal.
      expect(response['error'], isA<String>());
      expect(response['error'], contains('Unknown command'));

      await controller.close();
    });

    test('malformed JSON returns parse error', () async {
      final controller = StreamController<String>();
      final protocol = MachineProtocol(
        enabled: true,
        output: sink,
        inputLines: controller.stream,
      );
      protocol.startListening();

      controller.add('not valid json {{{');

      await Future.delayed(Duration(milliseconds: 50));

      // Should have daemon.connected + parse error response.
      final errorLine = sink.lines.firstWhere((line) {
        final decoded = json.decode(line) as List;
        final msg = decoded.first as Map<String, dynamic>;
        return msg.containsKey('error') &&
            '${msg['error']}'.contains('Parse error');
      });
      final decoded = json.decode(errorLine) as List;
      final response = decoded.first as Map<String, dynamic>;
      expect(response['error'], contains('Parse error'));

      await controller.close();
    });

    test(
      'a handler that breaks answers Internal error, with a trace',
      () async {
        final commandRunner = CommandRunner();
        commandRunner.register('test.fail', (_) async {
          throw StateError('boom');
        });

        final controller = StreamController<String>();
        final protocol = MachineProtocol(
          enabled: true,
          commandRunner: commandRunner,
          output: sink,
          inputLines: controller.stream,
        );
        protocol.startListening();

        controller.add(
          json.encode({
            'id': 3,
            'method': 'test.fail',
            'params': {},
          }),
        );

        await Future.delayed(Duration(milliseconds: 50));

        final errorLine = sink.lines.firstWhere((line) {
          final decoded = json.decode(line) as List;
          final msg = decoded.first as Map<String, dynamic>;
          return msg.containsKey('id') && msg['id'] == 3;
        });
        final decoded = json.decode(errorLine) as List;
        final response = decoded.first as Map<String, dynamic>;
        expect(response['error'], contains('Internal error'));
        expect(response['error'], contains('boom'));
        expect(response['trace'], isA<String>());

        await controller.close();
      },
    );
  });
}
