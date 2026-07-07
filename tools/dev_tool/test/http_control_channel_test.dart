import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/http_control_channel.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:test/test.dart';

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
      client.close();
      await channel.stop();
    });

    Uri _uri(String path, {bool withToken = true}) {
      final base = channel.uri;
      final query = withToken ? 'token=test-token-abc' : '';
      return base.replace(path: path, query: query);
    }

    Future<HttpClientResponse> _get(String path,
        {bool withToken = true}) async {
      final request = await client.getUrl(_uri(path, withToken: withToken));
      return request.close();
    }

    Future<(HttpClientResponse, String)> _post(
        String path, Map<String, dynamic> body,
        {bool withToken = true}) async {
      final request = await client.postUrl(_uri(path, withToken: withToken));
      request.headers.contentType = ContentType.json;
      request.write(json.encode(body));
      final response = await request.close();
      final responseBody = await utf8.decoder.bind(response).join();
      return (response, responseBody);
    }

    group('http upgrade', () {
      test('rejects an Upgrade request with 426 before reading the body',
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
      });
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
        final request =
            await client.postUrl(_uri('/command'));
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

    group('GET /sessions/{appId}/screenshot/flutter', () {
      test('returns 404 for unknown appId', () async {
        final response =
            await _get('/sessions/unknown/screenshot/flutter');
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>();
      });
    });

    group('GET /sessions/{appId}/screenshot/native', () {
      test('returns 404 for unknown appId', () async {
        final response =
            await _get('/sessions/unknown/screenshot/native');
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

      test('stop during an in-flight command lets the response flush intact',
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
      });

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
          freshClient
              .postUrl(uri.replace(path: '/command', query: 'token=test-token-abc')),
          throwsA(isA<SocketException>()),
        );
        freshClient.close(force: true);

        handlerResume.complete();
        final (response, _) = await responseFuture;
        expect(response.statusCode, HttpStatus.ok);
        await stopFuture;
      });
    });
  });
}
