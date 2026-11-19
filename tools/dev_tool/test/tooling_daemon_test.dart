import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/process_cpu_time.dart';
import 'package:flutter_bazel_dev_tool/teardown.dart';
import 'package:flutter_bazel_dev_tool/tooling_daemon.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// What `dart tooling-daemon --machine` prints once it listens.
String detailsLine({
  String uri = 'ws://127.0.0.1:4242/token=',
  String secret = 's3cret',
}) => jsonEncode({
  'tooling_daemon_details': {'uri': uri, 'trusted_client_secret': secret},
});

class FakeRegistry implements ConnectedAppRegistry {
  final registered = <({String uri, String secret, String? name})>[];
  bool closed = false;
  Object? registerError;

  @override
  Future<void> registerVmService({
    required String uri,
    required String secret,
    String? name,
  }) async {
    if (registerError case final e?) throw e;
    registered.add((uri: uri, secret: secret, name: name));
  }

  @override
  Future<void> close() async => closed = true;
}

/// A `dart tooling-daemon` that answers as [onStart] makes it.
class FakeDaemonHost {
  final process = FakeProcess();
  final registry = FakeRegistry();
  final spawned = <({String executable, List<String> args, String cwd})>[];
  final connectedTo = <Uri>[];

  Future<Process> spawn(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    spawned.add((
      executable: executable,
      args: arguments,
      cwd: workingDirectory,
    ));
    return process;
  }

  Future<ConnectedAppRegistry> connect(Uri uri) async {
    connectedTo.add(uri);
    return registry;
  }

  /// What the daemon's CPU time reads as, by pid.
  Future<Duration> Function(int pid) cpuTime = (_) async =>
      const Duration(milliseconds: 40);

  Future<ToolingDaemon> start({
    Duration timeout = const Duration(seconds: 5),
  }) => ToolingDaemon.start(
    dartExecutable: '/sdk/bin/dart',
    workingDirectory: '/ws',
    spawn: spawn,
    connect: connect,
    timeout: timeout,
    cpuTime: cpuTime,
  );
}

void main() {
  group('ToolingDaemon.start', () {
    test(
      "starts the toolchain's dart in the workspace and reads its address",
      () async {
        final host = FakeDaemonHost();
        final started = host.start();
        await host.process.outputAttached;
        // What precedes the details line is not the details line.
        host.process.emitStdout('The Dart Tooling Daemon is starting');
        host.process.emitStdout(detailsLine());

        final daemon = await started;
        expect(host.spawned.single.executable, '/sdk/bin/dart');
        expect(host.spawned.single.args, ['tooling-daemon', '--machine']);
        expect(host.spawned.single.cwd, '/ws');
        expect(daemon.uri, Uri.parse('ws://127.0.0.1:4242/token='));
        expect(host.connectedTo, [daemon.uri]);
      },
    );

    test('registers an app with the secret DTD printed', () async {
      final host = FakeDaemonHost();
      final started = host.start();
      await host.process.outputAttached;
      host.process.emitStdout(detailsLine(secret: 'only-the-spawner'));
      final daemon = await started;

      await daemon.registerVmService(
        Uri.parse('ws://127.0.0.1:5555/abc=/ws'),
        name: 'Kind: Flutter - Device: macOS - Package: //:app',
      );
      expect(host.registry.registered.single, (
        uri: 'ws://127.0.0.1:5555/abc=/ws',
        secret: 'only-the-spawner',
        name: 'Kind: Flutter - Device: macOS - Package: //:app',
      ));
    });

    test('fails with what DTD said when it exits before listening', () async {
      final host = FakeDaemonHost();
      final started = host.start();
      await host.process.outputAttached;
      host.process.emitStderr(
        'Could not find a command named "tooling-daemon".',
      );
      // Let stderr arrive before the exit, as a pipe delivers it.
      await Future<void>.delayed(Duration.zero);
      host.process.complete(64);

      await expectLater(
        started,
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('exited with 64'), contains('tooling-daemon".')),
          ),
        ),
      );
      expect(host.connectedTo, isEmpty);
    });

    test('stops DTD when it says nothing within the timeout', () async {
      final host = FakeDaemonHost();
      final started = host.start(timeout: const Duration(milliseconds: 50));
      await host.process.outputAttached;

      await expectLater(
        started,
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('did not say where it listens'),
              contains('using 40ms of CPU'),
            ),
          ),
        ),
      );
      expect(host.process.killed, isTrue);
    });

    test(
      'times out with what it can say when its CPU time cannot be read',
      () async {
        final host = FakeDaemonHost()
          ..cpuTime = ((_) async =>
              throw ProcessCpuTimeException('no such pid'));
        final started = host.start(timeout: const Duration(milliseconds: 50));
        await host.process.outputAttached;

        await expectLater(
          started,
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('did not say where it listens'),
                contains('its CPU time could not be read: no such pid'),
              ),
            ),
          ),
        );
        expect(host.process.killed, isTrue);
      },
    );

    // The read runs in a timer, where an error that escapes is unhandled and
    // ends the tool. `ps` failing to start is not a ProcessCpuTimeException.
    test(
      'times out the same way whatever reading its CPU time throws',
      () async {
        final host = FakeDaemonHost()
          ..cpuTime = ((_) async =>
              throw const ProcessException('ps', [], 'not found', 2));
        final started = host.start(timeout: const Duration(milliseconds: 50));
        await host.process.outputAttached;

        await expectLater(
          started,
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('did not say where it listens'),
                contains('its CPU time could not be read'),
              ),
            ),
          ),
        );
        expect(host.process.killed, isTrue);
      },
    );

    test('stops DTD when it cannot be connected to', () async {
      final host = FakeDaemonHost();
      final started = ToolingDaemon.start(
        dartExecutable: '/sdk/bin/dart',
        workingDirectory: '/ws',
        spawn: host.spawn,
        connect: (_) async => throw const SocketException('refused'),
      );
      await host.process.outputAttached;
      host.process.emitStdout(detailsLine());

      await expectLater(started, throwsA(isA<DevToolException>()));
      expect(host.process.killed, isTrue);
    });

    test('close closes the connection and stops the process', () async {
      final host = FakeDaemonHost();
      final started = host.start();
      await host.process.outputAttached;
      host.process.emitStdout(detailsLine());
      final daemon = await started;

      await daemon.close();
      expect(host.registry.closed, isTrue);
      expect(host.process.signals, [ProcessSignal.sigterm]);
    });

    test('close escalates to SIGKILL for a DTD that ignores SIGTERM', () async {
      final host = FakeDaemonHost();
      host.process.ignoresSigterm = true;
      final started = host.start();
      await host.process.outputAttached;
      host.process.emitStdout(detailsLine());
      final daemon = await started;

      await daemon.close();
      expect(host.process.signals, [
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('RunToolingDaemon', () {
    late BufferSink sink;
    late MachineProtocol protocol;
    late Teardown teardown;
    late List<LogRecord> records;

    setUp(() {
      sink = BufferSink();
      protocol = MachineProtocol(enabled: true, output: sink);
      teardown = Teardown();
      records = [];
      final previous = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(() {
        sub.cancel();
        Logger.root.level = previous;
      });
    });

    List<Map<String, dynamic>> dtdEvents() => [
      for (final line in sink.lines)
        for (final event in (json.decode(line) as List))
          if ((event as Map<String, dynamic>)['event'] == 'app.dtd')
            (event['params'] as Map).cast<String, dynamic>(),
    ];

    Future<({FakeDaemonHost host, RunToolingDaemon run, List<int> starts})>
    newRun({bool printUri = false}) async {
      final host = FakeDaemonHost();
      final starts = <int>[];
      final run = RunToolingDaemon(
        start: () {
          starts.add(starts.length);
          final started = host.start();
          unawaited(
            host.process.outputAttached.then(
              (_) => host.process.emitStdout(detailsLine()),
            ),
          );
          return started;
        },
        teardown: teardown,
        protocol: protocol,
        logger: Logger('test.dtd'),
        printUri: printUri,
      );
      return (host: host, run: run, starts: starts);
    }

    test('one DTD serves every app of the run, each announced', () async {
      final (:host, :run, :starts) = await newRun();

      final a = await run.register(
        appId: 'a',
        vmServiceWsUri: Uri.parse('ws://127.0.0.1:1/a=/ws'),
        name: 'A',
      );
      final b = await run.register(
        appId: 'b',
        vmServiceWsUri: Uri.parse('ws://127.0.0.1:2/b=/ws'),
        name: 'B',
      );

      expect(starts, hasLength(1));
      expect(a, Uri.parse('ws://127.0.0.1:4242/token='));
      expect(b, a);
      expect(host.registry.registered.map((r) => r.name), ['A', 'B']);
      expect(dtdEvents(), [
        {'appId': 'a', 'uri': 'ws://127.0.0.1:4242/token='},
        {'appId': 'b', 'uri': 'ws://127.0.0.1:4242/token='},
      ]);
    });

    test("the run's teardown stops the DTD it started", () async {
      final (:host, :run, starts: _) = await newRun();
      await run.register(
        appId: 'a',
        vmServiceWsUri: Uri.parse('ws://127.0.0.1:1/a=/ws'),
        name: 'A',
      );

      await teardown.run();
      expect(host.registry.closed, isTrue);
      expect(host.process.killed, isTrue);
    });

    test('a run that is already over starts no DTD', () async {
      final (host: _, :run, :starts) = await newRun();
      await teardown.run();

      final uri = await run.register(
        appId: 'a',
        vmServiceWsUri: Uri.parse('ws://127.0.0.1:1/a=/ws'),
        name: 'A',
      );
      expect(uri, isNull);
      expect(starts, isEmpty);
    });

    test('a registration that fails is a warning, not a failed run', () async {
      final (:host, :run, starts: _) = await newRun();
      host.registry.registerError = StateError('connection failed');

      final uri = await run.register(
        appId: 'a',
        vmServiceWsUri: Uri.parse('ws://127.0.0.1:1/a=/ws'),
        name: 'A',
      );
      expect(uri, isNull);
      expect(dtdEvents(), isEmpty);
      final warning = records.singleWhere((r) => r.level == Level.WARNING);
      expect(
        (warning.object as Map)['text'],
        allOf(contains('Dart MCP server'), contains('ws://127.0.0.1:1/a=/ws')),
      );
    });

    test('--print-dtd prints upstream\'s line', () async {
      final (host: _, :run, starts: _) = await newRun(printUri: true);
      run.announce('a', Uri.parse('ws://127.0.0.1:9/t='));

      final line = records.singleWhere(
        (r) => (r.object as Map?)?['message'] == 'dtd',
      );
      expect(line.level, Level.INFO);
      expect(
        (line.object as Map)['text'],
        'The Dart Tooling Daemon is available at: ws://127.0.0.1:9/t=',
      );
      expect(dtdEvents(), [
        {'appId': 'a', 'uri': 'ws://127.0.0.1:9/t='},
      ]);
    });

    test('without --print-dtd the line is detail only', () async {
      final (host: _, :run, starts: _) = await newRun();
      run.announce('a', Uri.parse('ws://127.0.0.1:9/t='));

      final line = records.singleWhere(
        (r) => (r.object as Map?)?['message'] == 'dtd',
      );
      expect(line.level, Level.FINE);
    });
  });

  test('dtdAppName is flutter run\'s form', () {
    expect(
      dtdAppName(device: 'macOS', target: '//:app'),
      'Kind: Flutter - Device: macOS - Package: //:app',
    );
  });
}
