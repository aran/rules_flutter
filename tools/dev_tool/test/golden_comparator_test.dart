/// The golden service as the host runs it: started on the first golden and
/// not before, told which test it compares for, asked one golden at a time over
/// its connection, and ended with the run. A service that dies says how, in
/// words that include what it printed, instead of leaving the app waiting.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_bazel_dev_tool/integration/golden_comparator.dart';
import 'package:flutter_bazel_dev_tool/integration/golden_service_process.dart';
import 'package:test/test.dart';

/// A golden service in this process: connects to the port it is told and
/// answers lines as `flutter/private/goldens/service.dart` does.
class _FakeService implements RunningGoldenService {
  _FakeService(this.environment);

  final Map<String, String> environment;
  final requests = <Map<String, Object?>>[];
  final _exit = Completer<int>();
  Socket? socket;
  var killed = false;

  /// How the fake answers a request: a map to send, or null to say nothing.
  Map<String, Object?>? Function(Map<String, Object?> request) answer = (
    request,
  ) => {'id': request['id'], 'matched': true};

  @override
  Future<int> get exitCode => _exit.future;

  final _output = StreamController<String>();

  @override
  Stream<String> get output => _output.stream;

  /// What the service prints as it ends, once its connection is closed.
  var lastWords = <String>[];

  /// The service prints [line].
  void say(String line) => _output.add(line);

  void _end(int code) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
    unawaited(_output.close());
  }

  @override
  void kill() {
    killed = true;
    socket?.destroy();
    _end(-9);
  }

  Future<void> connect() async {
    final connected = await Socket.connect(
      InternetAddress.loopbackIPv4,
      int.parse(environment[goldenServicePortVariable]!),
    );
    socket = connected;
    connected
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final request = json.decode(line) as Map<String, Object?>;
            requests.add(request);
            final response = answer(request);
            if (response != null) connected.writeln(json.encode(response));
          },
          onDone: () {
            connected.destroy();
            lastWords.forEach(say);
            _end(0);
          },
        );
  }

  void die(int code) {
    socket?.destroy();
    _end(code);
  }
}

void main() {
  late List<_FakeService> started;
  late bool Function() connectsOnStart;
  late List<String> logged;
  setUp(() {
    started = [];
    connectsOnStart = () => true;
    logged = [];
  });

  GoldenServiceComparator comparatorOf({
    Duration ceiling = const Duration(seconds: 30),
    void Function(_FakeService)? onStart,
  }) => GoldenServiceComparator(
    testPath: 'pkg/x_test.dart',
    ceiling: ceiling,
    environment: const {'TEST_TARGET': '//pkg:x_test'},
    log: logged.add,
    launch: (environment) async {
      final service = _FakeService(environment);
      started.add(service);
      onStart?.call(service);
      if (connectsOnStart()) await service.connect();
      return service;
    },
  );

  final bytes = Uint8List.fromList([1, 2, 3]);

  test('the service is not started until a golden is asked for', () async {
    final comparator = comparatorOf();

    expect(started, isEmpty);
    await comparator.close();
    expect(started, isEmpty);
  });

  test('the service is told the test it compares for and the port to connect '
      'to, with the rest of the environment it was given', () async {
    final comparator = comparatorOf();

    await comparator.compare('goldens/a.png', bytes);

    final env = started.single.environment;
    expect(env[goldenServiceTestPathVariable], 'pkg/x_test.dart');
    expect(env['TEST_TARGET'], '//pkg:x_test');
    expect(int.parse(env[goldenServicePortVariable]!), greaterThan(0));
    await comparator.close();
  });

  test('a request is the golden\'s key and the picture\'s bytes, and a match '
      'comes back as one', () async {
    final comparator = comparatorOf();

    final answer = await comparator.compare('goldens/a.png', bytes);

    final request = started.single.requests.single;
    expect(request['op'], 'compare');
    expect(request['key'], 'goldens/a.png');
    expect(base64.decode(request['bytes']! as String), bytes);
    expect(answer.matched, isTrue);
    await comparator.close();
  });

  test('the same service answers every golden of the run', () async {
    final comparator = comparatorOf();

    await comparator.compare('goldens/a.png', bytes);
    await comparator.update('goldens/b.png', bytes);
    await comparator.compare('goldens/c.png', bytes);

    expect(started, hasLength(1));
    expect(
      started.single.requests.map((r) => '${r['op']} ${r['key']}'),
      [
        'compare goldens/a.png',
        'update goldens/b.png',
        'compare goldens/c.png',
      ],
    );
    await comparator.close();
  });

  test(
    'a golden the service wrote is answered with where it wrote it',
    () async {
      final comparator = comparatorOf();
      await comparator.compare('goldens/a.png', bytes);
      started.single.answer = (request) => {
        'id': request['id'],
        'matched': true,
        'wrote': '/ws/pkg/goldens/a.png',
      };

      final answer = await comparator.update('goldens/a.png', bytes);

      expect(answer.wrote, '/ws/pkg/goldens/a.png');
      await comparator.close();
    },
  );

  test('a mismatch is the service\'s error, in its words', () async {
    final comparator = comparatorOf();
    await comparator.compare('goldens/a.png', bytes);
    started.single.answer = (request) => {
      'id': request['id'],
      'error': 'Golden "goldens/a.png": Pixel test failed, 100.00%',
    };

    final answer = await comparator.compare('goldens/a.png', bytes);

    expect(answer.matched, isNull);
    expect(answer.error, 'Golden "goldens/a.png": Pixel test failed, 100.00%');
    await comparator.close();
  });

  test('what the service prints is logged as it prints it, though it lives, '
      'so warnings from a comparison reach the test\'s log', () async {
    final comparator = comparatorOf();
    await comparator.compare('goldens/a.png', bytes);
    final service = started.single;

    service
      ..say('[ERROR:flutter/impeller] a warning')
      ..say('second line');
    await pumpEventQueue();

    expect(logged, ['[ERROR:flutter/impeller] a warning', 'second line']);
    await comparator.close();
  });

  test('what the service prints as it ends is logged before closing '
      'returns', () async {
    final comparator = comparatorOf();
    await comparator.compare('goldens/a.png', bytes);
    final service = started.single;
    service.lastWords = ['last words'];

    await comparator.close();

    expect(logged, ['last words']);
  });

  test('closing ends the service by closing its connection, and waits for it '
      'to end', () async {
    final comparator = comparatorOf();
    await comparator.compare('goldens/a.png', bytes);

    await comparator.close();

    expect(await started.single.exitCode, 0);
    expect(started.single.killed, isFalse);
  });

  test('a service that dies while it is asked says how it ended and what it '
      'printed, so the failure is a reason and not a hang', () async {
    final comparator = comparatorOf();
    await comparator.compare('goldens/a.png', bytes);
    final service = started.single;
    service.say('[flutter_tester] Segmentation fault');
    service.answer = (request) {
      service.die(139);
      return null;
    };

    await expectLater(
      comparator.compare('goldens/a.png', bytes),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('exited with code 139'),
            contains('Segmentation fault'),
          ),
        ),
      ),
    );
    await comparator.close();
  });

  test('a service that ends before it connects says how, instead of the '
      'golden waiting for the ceiling', () async {
    connectsOnStart = () => false;
    final comparator = comparatorOf(
      onStart: (service) {
        service.say('[flutter_tester] cannot open the kernel');
        Timer.run(() => service.die(64));
      },
    );

    await expectLater(
      comparator.compare('goldens/a.png', bytes),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('ended before it connected'),
            contains('exited with code 64'),
            contains('cannot open the kernel'),
          ),
        ),
      ),
    );
    await comparator.close();
  });

  test(
    'a service that neither connects nor ends is killed at the ceiling',
    () async {
      connectsOnStart = () => false;
      final comparator = comparatorOf(
        ceiling: const Duration(milliseconds: 50),
      );

      await expectLater(
        comparator.compare('goldens/a.png', bytes),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('did not connect within'),
          ),
        ),
      );
      expect(started.single.killed, isTrue);
      await comparator.close();
    },
  );

  // The service is a `flutter_test` runner whose `flutter_tester` writes
  // straight into the runner's stdout and stderr. Here a shell plays the
  // runner and a `sleep` the tester: killing the shell alone would leave the
  // `sleep` holding the pipes, and the output would not end for minutes.
  test(
    'killing a started service kills what it started, so its output ends',
    () async {
      final dir = Directory.systemTemp.createTempSync('golden_service_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final service = File('${dir.path}/service')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          '/bin/sleep 120 &\n'
          'echo started\n'
          'wait\n',
        );
      Process.runSync('/bin/chmod', ['+x', service.path]);

      final running = await startGoldenServiceProcess(
        service.path,
        const {},
        binary: '//tools/dev_tool:golden_comparator_test',
      );
      final lines = <String>[];
      final printed = Completer<void>();
      final ended = running.output.forEach((line) {
        lines.add(line);
        if (!printed.isCompleted) printed.complete();
      });
      // Started is what makes the `sleep` exist to be killed.
      await Future.any([printed.future, ended]);
      expect(lines, ['started']);

      running.kill();

      await ended.timeout(
        const Duration(seconds: 30),
        onTimeout: () => fail('the output never ended: the sleep outlived it'),
      );
      expect(await running.exitCode, -ProcessSignal.sigkill.signalNumber);
    },
    testOn: '!windows',
  );

  group('the environment the service is started with', () {
    const host = {
      'PATH': '/bin',
      'RUNFILES_DIR': '/runfiles',
      'TEST_UNDECLARED_OUTPUTS_DIR': '/outputs',
      'TEST_TARGET': '//pkg:x_test',
      'BUILD_WORKSPACE_DIRECTORY': '/ws',
      // The test's own.
      'TESTBRIDGE_TEST_ONLY': 'increments',
      'TEST_TOTAL_SHARDS': '2',
      'TEST_SHARD_INDEX': '1',
      'TEST_SHARD_STATUS_FILE': '/shard',
      'XML_OUTPUT_FILE': '/report.xml',
      'COVERAGE_OUTPUT_FILE': '/coverage',
      // A tag selection for the test's cases: the service's one case carries
      // no tag, so it would be selected away and every golden would fail with
      // no comparator.
      'DART_TEST_TAGS': 'golden',
      'DART_TEST_EXCLUDE_TAGS': 'slow',
    };

    test('is the host\'s, so the service finds the runfiles, where failures '
        'go and the source tree, without what is the test\'s own: its '
        'filter would select none of the service\'s case and its report '
        'path would be written over', () {
      final env = goldenServiceEnvironment(
        host,
        const {'FLUTTER_TEST_DILL': 'g.dill'},
        update: false,
      );

      expect(env, {
        'PATH': '/bin',
        'RUNFILES_DIR': '/runfiles',
        'TEST_UNDECLARED_OUTPUTS_DIR': '/outputs',
        'TEST_TARGET': '//pkg:x_test',
        'BUILD_WORKSPACE_DIRECTORY': '/ws',
        'FLUTTER_TEST_DILL': 'g.dill',
      });
    });

    test('says so when goldens are to be written', () {
      final env = goldenServiceEnvironment(host, const {}, update: true);

      expect(env[goldenServiceUpdateVariable], '1');
    });
  });
}
