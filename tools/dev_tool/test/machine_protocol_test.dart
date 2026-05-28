import 'dart:async';
import 'dart:convert';

import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
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
      protocol.appStart('myapp', 'macOS');
      final decoded = json.decode(sink.lines.first) as List;
      final params = (decoded.first as Map<String, dynamic>)['params']
          as Map<String, dynamic>;
      expect(params['appId'], 'myapp');
      expect(params['deviceId'], 'macOS');
      expect(params['directory'], isA<String>());
      expect(params['supportsRestart'], isTrue);
      expect(params['launchMode'], 'run');
    });

    test('appDebugPort includes wsUri, conditionally baseUri', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      final wsUri = Uri.parse('ws://127.0.0.1:8181/abc/ws');

      protocol.appDebugPort('myapp', wsUri, null);
      var decoded = json.decode(sink.lines.first) as List;
      var params = (decoded.first as Map<String, dynamic>)['params']
          as Map<String, dynamic>;
      expect(params['wsUri'], wsUri.toString());
      expect(params.containsKey('baseUri'), isFalse);

      sink.buffer.clear();
      final baseUri = Uri.parse('http://127.0.0.1:8181/abc/');
      protocol.appDebugPort('myapp', wsUri, baseUri);
      decoded = json.decode(sink.lines.first) as List;
      params = (decoded.first as Map<String, dynamic>)['params']
          as Map<String, dynamic>;
      expect(params['baseUri'], baseUri.toString());
    });

    test('appProgress increments progressId each call', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appProgress('myapp', 'Building...');
      protocol.appProgress('myapp', 'Installing...');
      final lines = sink.lines;
      final id0 = ((json.decode(lines[0]) as List).first
          as Map<String, dynamic>)['params']['id'] as String;
      final id1 = ((json.decode(lines[1]) as List).first
          as Map<String, dynamic>)['params']['id'] as String;
      expect(id0, isNot(equals(id1)));
      expect(id0, startsWith('progress_'));
      expect(id1, startsWith('progress_'));
    });

    test('appLog sets error field', () {
      final protocol = MachineProtocol(enabled: true, output: sink);
      protocol.appLog('myapp', 'some error', error: true);
      final decoded = json.decode(sink.lines.first) as List;
      final params = (decoded.first as Map<String, dynamic>)['params']
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

      controller.add(json.encode({
        'id': 1,
        'method': 'app.restart',
        'params': {},
      }));

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

    test('unknown method returns error code -32601', () async {
      final commandRunner = CommandRunner();
      final controller = StreamController<String>();
      final protocol = MachineProtocol(
        enabled: true,
        commandRunner: commandRunner,
        output: sink,
        inputLines: controller.stream,
      );
      protocol.startListening();

      controller.add(json.encode({
        'id': 2,
        'method': 'nonexistent.method',
      }));

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
      expect(response['error']['code'], -32601);

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
        return msg.containsKey('error') && msg['error']['code'] == -32700;
      });
      final decoded = json.decode(errorLine) as List;
      final response = decoded.first as Map<String, dynamic>;
      expect(response['error']['code'], -32700);

      await controller.close();
    });

    test('handler exception returns -32603 internal error', () async {
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

      controller.add(json.encode({
        'id': 3,
        'method': 'test.fail',
        'params': {},
      }));

      await Future.delayed(Duration(milliseconds: 50));

      final errorLine = sink.lines.firstWhere((line) {
        final decoded = json.decode(line) as List;
        final msg = decoded.first as Map<String, dynamic>;
        return msg.containsKey('id') && msg['id'] == 3;
      });
      final decoded = json.decode(errorLine) as List;
      final response = decoded.first as Map<String, dynamic>;
      expect(response['error']['code'], -32603);
      expect(response['error']['message'], contains('boom'));

      await controller.close();
    });
  });
}
