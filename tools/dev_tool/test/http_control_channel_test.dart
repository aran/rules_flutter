import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/command_failure.dart';
import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/http_control_channel.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:test/test.dart';

import 'loopbacks.dart';

void main() {
  group('HttpControlChannel', () {
    late CommandRunner commandRunner;
    late HttpControlChannel channel;
    late HttpClient client;
    final sessions = <String, DeviceSession>{};

    setUp(() async {
      commandRunner = CommandRunner();
      commandRunner.register('test.echo', (params) async {
        return {'echo': params['msg']};
      });
      commandRunner.register('test.fail', (_) async {
        throw StateError('handler error');
      });
      commandRunner.register('test.refuse', (_) async {
        throw const CommandFailure.failed('no widget matching ValueKey(x)');
      });
      commandRunner.register('test.badParams', (_) async {
        throw const CommandFailure.badRequest('needs width and height');
      });
      commandRunner.register('test.cannot', (_) async {
        throw const CommandFailure.unavailable('no engine screenshot on web');
      });

      sessions.clear();

      channel = HttpControlChannel(
        commandRunner: commandRunner,
        findSession: (appId) => sessions[appId],
        token: 'test-token-abc',
      );
      await channel.start();
      client = HttpClient();
    });

    tearDown(() async {
      // force: true, or the client's keep-alive sockets stay open until they
      // idle out. `dart test` force-exits the VM once tests finish and hides
      // that, but running the file directly — as the Bazel target does —
      // makes the VM linger on the open handles until every socket idles out.
      client.close(force: true);
      await channel.stop();
    });

    Uri _uri(String path, {bool withToken = true}) {
      final base = channel.uri;
      final query = withToken ? 'token=test-token-abc' : '';
      return base.replace(path: path, query: query);
    }

    Future<HttpClientResponse> _get(
      String path, {
      bool withToken = true,
    }) async {
      final request = await client.getUrl(_uri(path, withToken: withToken));
      return request.close();
    }

    Future<(HttpClientResponse, String)> _post(
      String path,
      Map<String, dynamic> body, {
      bool withToken = true,
    }) async {
      final request = await client.postUrl(_uri(path, withToken: withToken));
      request.headers.contentType = ContentType.json;
      request.write(json.encode(body));
      final response = await request.close();
      final responseBody = await utf8.decoder.bind(response).join();
      return (response, responseBody);
    }

    group('http upgrade', () {
      test(
        'rejects an Upgrade request with 426 before reading the body',
        () async {
          // Mimic an HTTP/2 cleartext (h2c) upgrade attempt: Dart's HttpServer
          // would otherwise silently drop the request body and hang the POST.
          final request = await client.postUrl(_uri('/command'));
          request.headers.contentType = ContentType.json;
          request.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
          request.headers.set(HttpHeaders.upgradeHeader, 'h2c');
          request.write(json.encode({'method': 'test.echo'}));
          final response = await request.close();
          final body = await utf8.decoder.bind(response).join();
          expect(response.statusCode, HttpStatus.upgradeRequired);
          expect(body, contains('HTTP/1.1 only'));
        },
      );
    });

    group('auth', () {
      test('returns 401 without token', () async {
        final response = await _get('/command', withToken: false);
        expect(response.statusCode, HttpStatus.unauthorized);
        await response.drain<void>();
      });

      test('returns 401 with wrong token', () async {
        final request = await client.getUrl(
          channel.uri.replace(path: '/command', query: 'token=wrong'),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.unauthorized);
        await response.drain<void>();
      });

      // A field called `token` reads as a bearer credential, so the first
      // thing a caller tries is an `Authorization` header. The refusal has to
      // say where the token is actually read from, or it looks like the value
      // is wrong rather than in the wrong place.
      test('a 401 names the query parameter it read', () async {
        final request = await client.getUrl(
          channel.uri.replace(path: '/command'),
        );
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer test-token-abc',
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.unauthorized);
        final body =
            json.decode(await response.transform(utf8.decoder).join())
                as Map<String, dynamic>;
        expect(body['error'], contains('token'));
        expect(body['error'], contains('query parameter'));
        expect(body['error'], contains('not from a header'));
      });

      test('accepts correct token', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.echo',
          'params': {'msg': 'hi'},
        });
        expect(response.statusCode, HttpStatus.ok);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['result']['echo'], 'hi');
      });
    });

    group('POST /command', () {
      test('executes valid command', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.echo',
          'params': {'msg': 'hello'},
        });
        expect(response.statusCode, HttpStatus.ok);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['result']['echo'], 'hello');
      });

      test('returns 404 for unknown method', () async {
        final (response, body) = await _post('/command', {
          'method': 'nonexistent',
        });
        expect(response.statusCode, HttpStatus.notFound);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['error'], contains('Unknown command'));
      });

      test('returns 400 for malformed JSON', () async {
        final request = await client.postUrl(_uri('/command'));
        request.headers.contentType = ContentType.json;
        request.write('not json {{{');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.badRequest);
        await response.drain<void>();
      });

      test('returns 400 when method field is missing', () async {
        final (response, body) = await _post('/command', {
          'params': {'msg': 'hi'},
        });
        expect(response.statusCode, HttpStatus.badRequest);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['error'], contains('Missing "method" field'));
      });

      // One shape for every no, so a client checking for failures has one
      // place to look rather than a status code and a nested `error` field.
      test('a refused command answers 422 with the reason', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.refuse',
        });
        // 422, not 500: the request was fine and the tool is fine — the app
        // said no. A 500 would tell a client to retry against a healthy run.
        expect(response.statusCode, HttpStatus.unprocessableEntity);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['error'], contains('no widget matching'));
        expect(
          parsed.containsKey('result'),
          isFalse,
          reason: 'a refusal is not a result',
        );
      });

      test('bad parameters answer 400', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.badParams',
        });
        expect(response.statusCode, HttpStatus.badRequest);
        expect(
          (json.decode(body) as Map<String, dynamic>)['error'],
          contains('needs width and height'),
        );
      });

      test('a command this run cannot serve answers 501', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.cannot',
        });
        expect(response.statusCode, HttpStatus.notImplemented);
        expect(
          (json.decode(body) as Map<String, dynamic>)['error'],
          contains('no engine screenshot'),
        );
      });

      // Still a 500, and deliberately: the tool broke, which is not the same
      // as the command being refused.
      test('returns 500 when handler throws', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.fail',
        });
        expect(response.statusCode, HttpStatus.internalServerError);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['error'], contains('handler error'));
      });

      test('defaults params to empty map', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.echo',
        });
        expect(response.statusCode, HttpStatus.ok);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['result']['echo'], isNull);
      });
    });

    /// `GET /commands` — the HTTP half of command discovery.
    ///
    /// A client on this channel gets no pushed events (there is nothing
    /// streamed here by design), and the surface grows during a run, so
    /// re-reading this is how it stays current.
    group('GET /commands', () {
      test('lists what is registered, with the slow ones marked', () async {
        final response = await _get('/commands');
        expect(response.statusCode, 200);
        final body =
            json.decode(await response.transform(utf8.decoder).join())
                as Map<String, dynamic>;
        final commands = (body['commands'] as List).cast<Map>();
        expect(commands, isNotEmpty);
        // Sorted by name, so a client can diff two readings.
        final names = commands.map((c) => c['name'] as String).toList();
        expect(names, orderedEquals([...names]..sort()));
        // Every entry carries the flag a client needs to pick a timeout.
        expect(
          commands.every((c) => c['longRunning'] is bool),
          isTrue,
        );
        // And the contract version, so a client knows what to expect without
        // probing for fields.
        expect(body['protocolVersion'], isA<int>());
      });
    });

    group('GET /sessions/{appId}/screenshot/flutter', () {
      test('returns 404 for unknown appId', () async {
        final response = await _get('/sessions/unknown/screenshot/flutter');
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>();
      });

      // On iOS and web this capture can never succeed — Impeller cannot
      // encode a compressed screenshot, and there is no engine screenshot on
      // web at all. A 500 carrying the engine's bare "Could not capture image
      // screenshot" makes a permanent condition read as a transient one and
      // names nothing that does work.
      test(
        'refuses where the capture can never work, naming the alternative',
        () async {
          sessions['app1'] = DeviceSession(
            device: _NoFlutterScreenshotDevice(),
            appInstance: AppInstance(process: _StubProcess()),
            vmClient: null,
            appId: 'app1',
          );

          final response = await _get('/sessions/app1/screenshot/flutter');
          final body = await utf8.decoder.bind(response).join();

          expect(
            response.statusCode,
            HttpStatus.notImplemented,
            reason: 'not a server fault and not worth retrying',
          );
          expect(body, contains('/sessions/app1/screenshot/native'));
          expect(body, contains('will not succeed on a retry'));
        },
      );
    });

    group('GET /sessions/{appId}/screenshot/native', () {
      test('returns 404 for unknown appId', () async {
        final response = await _get('/sessions/unknown/screenshot/native');
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>();
      });
    });

    group('routing', () {
      test('returns 404 for unknown paths', () async {
        final response = await _get('/unknown/path');
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>();
      });
    });

    group('binding', () {
      // The URL this channel publishes names a *host*, and a client resolving
      // that name picks a family itself — so every family the name can lead to
      // has to be one this channel answers on, or half its own URL reaches
      // whatever else on the machine holds that port number. `adb` keeps
      // dozens of listening sockets on 127.0.0.1 in the ephemeral range and
      // answers a connection by closing it without a byte
      // (web_module_server.dart:351-377).
      //
      // The families are discovered rather than named, because the set differs
      // per host: a Linux host with no IPv6 address cannot assign ::1 at all,
      // and a case that hard-codes it there reports on the machine instead of
      // on the tool.
      test(
        'every loopback family this host can assign reaches the channel',
        () async {
          final loopbacks = await assignableLoopbacks();
          expect(loopbacks, isNotEmpty);
          for (final address in loopbacks) {
            // Dialled by address, not by name: the point is which sockets exist,
            // and a name would let the resolver pick the one family that works.
            final request = await client.postUrl(
              channel.uri.replace(
                host: address.address,
                path: '/command',
                query: 'token=test-token-abc',
              ),
            );
            request.headers.contentType = ContentType.json;
            request.write(
              json.encode({
                'method': 'test.echo',
                'params': {'msg': address.address},
              }),
            );
            final response = await request.close();
            final body = await utf8.decoder.bind(response).join();

            expect(
              response.statusCode,
              HttpStatus.ok,
              reason: 'over ${address.address}',
            );
            // The echoed value and not just a 200: something else holding this
            // port can accept the connection and answer.
            expect(
              json.decode(body),
              {
                'result': {'echo': address.address},
              },
              reason: 'over ${address.address}',
            );
          }
        },
      );
    });

    group('lifecycle', () {
      test('token is 64 hex chars when auto-generated', () async {
        final autoChannel = HttpControlChannel(
          commandRunner: commandRunner,
          findSession: (_) => null,
        );
        expect(autoChannel.token.length, 64);
        expect(RegExp(r'^[0-9a-f]+$').hasMatch(autoChannel.token), isTrue);
      });

      test('uri throws before start', () {
        final notStarted = HttpControlChannel(
          commandRunner: commandRunner,
          findSession: (_) => null,
        );
        expect(() => notStarted.uri, throwsA(isA<StateError>()));
      });

      test('stop is idempotent', () async {
        await channel.stop();
        await channel.stop(); // Should not throw.
      });

      test(
        'stop during an in-flight command lets the response flush intact',
        () async {
          // Models `app.stop`: the command's own side effects lead to the
          // channel being stopped while the request that triggered them is
          // still awaiting its response. The client must still receive the
          // complete JSON response, not a torn-down connection.
          final handlerEntered = Completer<void>();
          final handlerResume = Completer<void>();
          commandRunner.register('test.slowStop', (_) async {
            handlerEntered.complete();
            await handlerResume.future;
            return {'message': 'stopped'};
          });

          final responseFuture = _post('/command', {'method': 'test.slowStop'});
          await handlerEntered.future;

          final stopFuture = channel.stop();
          handlerResume.complete();

          final (response, body) = await responseFuture;
          expect(response.statusCode, HttpStatus.ok);
          final parsed = json.decode(body) as Map<String, dynamic>;
          expect(parsed['result']['message'], 'stopped');

          await stopFuture;
        },
      );

      test('stop refuses new connections but drains in-flight ones', () async {
        final handlerEntered = Completer<void>();
        final handlerResume = Completer<void>();
        commandRunner.register('test.slowStop', (_) async {
          handlerEntered.complete();
          await handlerResume.future;
          return {'message': 'stopped'};
        });

        final uri = channel.uri;
        final responseFuture = _post('/command', {'method': 'test.slowStop'});
        await handlerEntered.future;

        final stopFuture = channel.stop();

        // New connections must be refused once stop() has begun.
        final freshClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5);
        await expectLater(
          freshClient.postUrl(
            uri.replace(path: '/command', query: 'token=test-token-abc'),
          ),
          throwsA(isA<SocketException>()),
        );
        freshClient.close(force: true);

        handlerResume.complete();
        final (response, _) = await responseFuture;
        expect(response.statusCode, HttpStatus.ok);
        await stopFuture;
      });
    });

    group('GET /sessions/{appId}/logs', () {
      late AppLogStream logs;

      /// Register a session whose app has printed [count] numbered lines.
      void seedSession(String appId, {int count = 0, int capacity = 2000}) {
        logs = AppLogStream(capacity: capacity);
        for (var i = 0; i < count; i++) {
          logs.add('line$i');
        }
        sessions[appId] = DeviceSession(
          device: _StubDevice(),
          appInstance: AppInstance(process: _StubProcess(), logs: logs),
          vmClient: null,
          appId: appId,
        );
      }

      Future<Map<String, dynamic>> getLogs(String query) async {
        final request = await client.getUrl(
          channel.uri.replace(
            path: '/sessions/app1/logs',
            query: 'token=test-token-abc${query.isEmpty ? '' : '&$query'}',
          ),
        );
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        expect(response.statusCode, HttpStatus.ok, reason: body);
        return json.decode(body) as Map<String, dynamic>;
      }

      List<String> textsOf(Map<String, dynamic> page) => [
        for (final l in page['lines'] as List) (l as Map)['text'] as String,
      ];

      test('with no cursor, tails the most recent lines', () async {
        seedSession('app1', count: 500);
        final page = await getLogs('');

        // The default is a tail, so an agent arriving with no cursor sees what
        // just happened rather than the start of the run.
        expect(textsOf(page).last, 'line499');
        expect(textsOf(page).length, lessThan(500));
        expect(page['nextCursor'], 500);
      });

      test('since=-N returns the last N lines', () async {
        seedSession('app1', count: 20);
        expect(textsOf(await getLogs('since=-3')), [
          'line17',
          'line18',
          'line19',
        ]);
      });

      test('since=0 reads from the start of the buffer', () async {
        seedSession('app1', count: 5);
        expect(textsOf(await getLogs('since=0')), [
          'line0',
          'line1',
          'line2',
          'line3',
          'line4',
        ]);
      });

      test('polling with nextCursor neither overlaps nor gaps', () async {
        seedSession('app1', count: 3);
        final first = await getLogs('since=0');
        expect(textsOf(first), ['line0', 'line1', 'line2']);

        logs.add('line3');
        logs.add('line4');
        final second = await getLogs('since=${first['nextCursor']}');

        expect(textsOf(second), ['line3', 'line4']);
        expect(second['nextCursor'], 5);
      });

      test(
        'polling with nothing new returns an empty page, not an error',
        () async {
          seedSession('app1', count: 2);
          final page = await getLogs('since=2');
          expect(page['lines'], isEmpty);
          expect(page['nextCursor'], 2);
        },
      );

      test('reports missed lines when the cursor has been evicted', () async {
        seedSession('app1', count: 10, capacity: 3);
        final page = await getLogs('since=0');

        expect(textsOf(page), ['line7', 'line8', 'line9']);
        expect(
          page['missed'],
          7,
          reason:
              'a poller must learn it has a gap rather than read a '
              'short page as if it were complete',
        );
        expect(page['dropped'], 7);
      });

      test('a cursor still inside the buffer reports no gap', () async {
        seedSession('app1', count: 10, capacity: 5);
        expect((await getLogs('since=7'))['missed'], 0);
      });

      test('limit caps the page', () async {
        seedSession('app1', count: 20);
        final page = await getLogs('since=0&limit=4');
        expect(textsOf(page), ['line0', 'line1', 'line2', 'line3']);
        expect(page['nextCursor'], 4);
      });

      test('an oversized limit is clamped rather than honoured', () async {
        seedSession('app1', count: 900);
        final page = await getLogs('since=0&limit=100000');
        expect((page['lines'] as List).length, lessThanOrEqualTo(500));
      });

      test('carries the error flag per line', () async {
        seedSession('app1');
        logs.add('fine');
        logs.add('broken', isError: true);

        final lines = (await getLogs('since=0'))['lines'] as List;
        expect((lines[0] as Map)['error'], isFalse);
        expect((lines[1] as Map)['error'], isTrue);
      });

      test('reports which launch of the app the page came from', () async {
        seedSession('app1', count: 2);
        final before = await getLogs('since=0');
        expect(before['launch'], 1);

        // A relaunch (restart with changed native libraries) starts a fresh
        // buffer numbered from zero, so the cursor a poller is holding now
        // points into a process that no longer exists. `launch` is how it
        // learns that instead of silently re-reading unrelated lines.
        final session = sessions['app1']!;
        final relaunchedLogs = AppLogStream()..add('after relaunch');
        await session.relaunch(
          () async =>
              AppInstance(process: _StubProcess(), logs: relaunchedLogs),
        );

        final after = await getLogs('since=${before['nextCursor']}');
        expect(after['launch'], 2);
        expect(textsOf(await getLogs('since=0')), ['after relaunch']);
      });

      test('reports closed once the app output source has ended', () async {
        seedSession('app1', count: 1);
        expect((await getLogs('since=0'))['closed'], isFalse);

        await logs.close();

        final page = await getLogs('since=0');
        expect(
          page['closed'],
          isTrue,
          reason: 'a poller needs to know when to stop',
        );
        expect(
          textsOf(page),
          ['line0'],
          reason: "an exited app's final output must still be readable",
        );
      });

      test('rejects a non-numeric since with 400', () async {
        seedSession('app1', count: 3);
        final request = await client.getUrl(
          channel.uri.replace(
            path: '/sessions/app1/logs',
            query: 'token=test-token-abc&since=abc',
          ),
        );
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();

        expect(response.statusCode, HttpStatus.badRequest);
        expect(
          body,
          contains('since'),
          reason:
              'silently serving the default would make a typo look like '
              'a working poll loop',
        );
      });

      test('rejects a non-positive limit with 400', () async {
        seedSession('app1', count: 3);
        final request = await client.getUrl(
          channel.uri.replace(
            path: '/sessions/app1/logs',
            query: 'token=test-token-abc&limit=0',
          ),
        );
        expect((await request.close()).statusCode, HttpStatus.badRequest);
      });

      test('404s an unknown appId', () async {
        final response = await _get('/sessions/nope/logs');
        expect(response.statusCode, HttpStatus.notFound);
      });

      test('401s without a valid token', () async {
        seedSession('app1', count: 1);
        final response = await _get('/sessions/app1/logs', withToken: false);
        expect(response.statusCode, HttpStatus.unauthorized);
      });
    });
  });
}

/// Minimal [Device] for session fixtures — the logs endpoint never touches it.
class _StubDevice extends Device {
  @override
  String get name => 'stub';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnimplementedError();

  @override
  Future<void> stop(AppInstance instance) async {}
}

/// A device that declares `_flutter.screenshot` unavailable — what iOS and
/// web do.
class _NoFlutterScreenshotDevice extends _StubDevice {
  @override
  String get name => 'iOS Simulator';

  @override
  bool get supportsFlutterScreenshot => false;
}

class _StubProcess implements Process {
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  int get pid => -1;
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}
