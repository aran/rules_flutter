// Tagged `runfiles`: the tool under test imports `package:runfiles`, which
// Bazel supplies via the `@rules_dart//dart/runfiles` dep its `dart_test`
// declares. A bare `dart test` resolves only this package's pubspec, where that
// import does not exist, so the file fails to load rather than failing a test.
// Coverage comes from //flutter/private/tools/test:flutter_test_runner_test.
@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// Imported under a prefix rather than plainly: this script is a `main`, and so
// is the test. Each public member of the runner is public because it is
// reachable from here and nowhere else — see their docstrings.
import '../flutter_test_runner.dart' as runner;

/// A VM service that answers exactly the three RPCs coverage collection makes.
///
/// Real enough to be worth having: it speaks JSON-RPC over a real WebSocket on
/// a real loopback port, so the transport, the framing, and the id/response
/// pairing in `_VmServiceRpc` are all under test rather than mocked away. Each
/// RPC can be told to answer with a JSON-RPC `error` or with a structurally
/// wrong `result`, which is how the tests below reach both failure classes.
class _FakeVmService {
  _FakeVmService._(this._server) {
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      // `collectCoverage` closes the socket from its `finally`, including
      // while unwinding a failure, so a mid-conversation close is expected
      // rather than an error.
      socket.listen(
        (raw) {
          final message = json.decode(raw as String) as Map<String, dynamic>;
          final method = message['method'] as String;
          final id = message['id'];
          final handler = handlers[method];
          if (handler == null) {
            socket.add(
              json.encode({
                'jsonrpc': '2.0',
                'id': id,
                'error': {'code': -32601, 'message': 'unexpected RPC: $method'},
              }),
            );
            return;
          }
          socket.add(json.encode({'jsonrpc': '2.0', 'id': id, ...handler()}));
        },
        onDone: () {},
        cancelOnError: true,
      );
    });
  }

  final HttpServer _server;

  /// Keyed by RPC method; each returns the `result`/`error` half of a reply.
  final handlers = <String, Map<String, dynamic> Function()>{};

  Uri get httpUri => Uri.parse('http://127.0.0.1:${_server.port}/');

  static Future<_FakeVmService> start() async =>
      _FakeVmService._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> stop() => _server.close(force: true);
}

/// One isolate, one script, one hit on line 5 and one miss on line 7.
Map<String, dynamic> _oneScriptReport() => {
  'result': {
    'scripts': [
      {'id': 'script-1', 'uri': 'file:///pkg/a.dart'},
    ],
    'ranges': [
      {
        'scriptIndex': 0,
        'coverage': {
          'hits': [10],
          'misses': [20],
        },
      },
    ],
  },
};

/// `[line, tokenPos, column, …]` — token 10 is line 5, token 20 is line 7.
Map<String, dynamic> _tokenTable() => {
  'result': {
    'tokenPosTable': [
      [5, 10, 1],
      [7, 20, 1],
    ],
  },
};

void main() {
  late _FakeVmService vm;

  setUp(() async {
    vm = await _FakeVmService.start();
    vm.handlers['getVM'] = () => {
      'result': {
        'isolates': [
          {'id': 'iso-1'},
        ],
      },
    };
    vm.handlers['getSourceReport'] = _oneScriptReport;
    vm.handlers['getObject'] = _tokenTable;
  });

  tearDown(() => vm.stop());

  group('collectCoverage', () {
    test('renders hits and misses as LCOV line records', () async {
      expect(
        await runner.collectCoverage(vm.httpUri),
        'SF:/pkg/a.dart\n'
        'DA:5,1\n'
        'DA:7,0\n'
        'end_of_record',
      );
    });

    // These must raise rather than report: an LCOV file missing an isolate,
    // or missing a file inside one, is indistinguishable downstream from a
    // complete one, so the run reads as green with a coverage number that was
    // never measured. The empty-report check only catches losing everything.

    test(
      'raises when an isolate refuses to report, rather than omitting it',
      () async {
        vm.handlers['getSourceReport'] = () => {
          'error': {'code': 112, 'message': 'isolate must be runnable'},
        };

        await expectLater(
          runner.collectCoverage(vm.httpUri),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('getSourceReport'), contains('must be runnable')),
            ),
          ),
        );
      },
    );

    test('raises when a script token table is refused, rather than dropping '
        'that file', () async {
      vm.handlers['getObject'] = () => {
        'error': {'code': -32602, 'message': 'object id expired'},
      };

      await expectLater(
        runner.collectCoverage(vm.httpUri),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('getObject'), contains('object id expired')),
          ),
        ),
      );
    });

    test(
      'raises on a malformed report instead of reading it as empty coverage',
      () async {
        // A cast failure inside the LCOV formatter, not an RPC error.
        vm.handlers['getSourceReport'] = () => {
          'result': {
            'scripts': [
              {'id': 42, 'uri': 'file:///pkg/a.dart'},
            ],
            'ranges': const [],
          },
        };

        await expectLater(
          runner.collectCoverage(vm.httpUri),
          throwsA(isA<TypeError>()),
        );
      },
    );
  });

  group('parseUpdateGoldens', () {
    // The refusal is the reason this is a function rather than three lines in
    // `main`: `bazel test` cannot be made to pass and fail the same target, so
    // the only place the rejected case is reachable as a *passing* assertion
    // is here.

    test('is off with no arguments, whether or not a workspace is set', () {
      expect(runner.parseUpdateGoldens([], null), isFalse);
      expect(runner.parseUpdateGoldens([], '/ws'), isFalse);
    });

    test('is on under `bazel run`, which sets BUILD_WORKSPACE_DIRECTORY', () {
      expect(runner.parseUpdateGoldens(['--update-goldens'], '/ws'), isTrue);
    });

    test('refuses under `bazel test`, where there is no source tree to write '
        'to — a golden regenerated into the sandbox would report success and '
        'change nothing', () {
      expect(
        () => runner.parseUpdateGoldens(['--update-goldens'], null),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('bazel run'), contains('--update-goldens')),
          ),
        ),
      );
      expect(
        () => runner.parseUpdateGoldens(['--update-goldens'], ''),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects an unrecognised argument rather than ignoring it, so a '
        'mistyped flag cannot report a green run that regenerated nothing', () {
      expect(
        () => runner.parseUpdateGoldens(['--update-golden'], '/ws'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--update-golden'),
          ),
        ),
      );
    });
  });

  group('testCeiling', () {
    test("derives the wedged-test backstop from Bazel's TEST_TIMEOUT, so a "
        'test given --test_timeout=1200 runs its full length', () {
      expect(runner.testCeiling('1200').inSeconds, greaterThan(600));
    });

    test('stays inside the Bazel budget, so a wedged test is reported here '
        'rather than killed from outside with no diagnostic', () {
      expect(runner.testCeiling('1200').inSeconds, lessThan(1200));
      expect(runner.testCeiling('60').inSeconds, lessThan(60));
    });

    test('falls back to five minutes with no TEST_TIMEOUT — a direct run '
        'outside `bazel test` has no budget to derive one from', () {
      expect(runner.testCeiling(null), const Duration(minutes: 5));
      expect(runner.testCeiling(''), const Duration(minutes: 5));
      expect(runner.testCeiling('not-a-number'), const Duration(minutes: 5));
      expect(runner.testCeiling('0'), const Duration(minutes: 5));
    });
  });
}
