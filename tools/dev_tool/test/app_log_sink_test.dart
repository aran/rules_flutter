import 'package:flutter_bazel_dev_tool/app_log.dart';
import 'package:flutter_bazel_dev_tool/app_log_sink.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:test/test.dart';

import 'fakes.dart';

AppLogLine line(String text, {bool isError = false, int index = 0}) =>
    AppLogLine(text: text, isError: isError, index: index);

void main() {
  group('TerminalAppLogSink', () {
    test('writes normal output to stdout', () {
      final out = BufferSink();
      final err = BufferSink();
      TerminalAppLogSink(out: out, err: err)(line('flutter: hello'));

      expect(out.lines, ['flutter: hello']);
      expect(err.lines, isEmpty);
    });

    test('writes error output to stderr', () {
      final out = BufferSink();
      final err = BufferSink();
      TerminalAppLogSink(out: out, err: err)(line('boom', isError: true));

      expect(out.lines, isEmpty);
      expect(err.lines, ['boom']);
    });

    test('does not prefix when there is a single device', () {
      final out = BufferSink();
      TerminalAppLogSink(out: out, err: BufferSink())(line('plain'));

      expect(out.lines, [
        'plain',
      ], reason: 'a single-device run should read like `flutter run`');
    });

    test('prefixes with the device name when running multiple devices', () {
      final out = BufferSink();
      TerminalAppLogSink(out: out, err: BufferSink(), prefix: 'macOS')(
        line('hello'),
      );

      expect(out.lines, ['[macOS] hello']);
    });

    test('prefixes error lines too', () {
      final err = BufferSink();
      TerminalAppLogSink(out: BufferSink(), err: err, prefix: 'Chrome')(
        line('bad', isError: true),
      );

      expect(err.lines, ['[Chrome] bad']);
    });

    test('preserves blank lines rather than swallowing them', () {
      final out = BufferSink();
      TerminalAppLogSink(out: out, err: BufferSink())(line(''));

      expect(out.lines, ['']);
    });
  });

  group('MachineAppLogSink', () {
    late BufferSink out;
    late MachineProtocol protocol;

    setUp(() {
      out = BufferSink();
      protocol = MachineProtocol(enabled: true, output: out);
    });

    test('emits an app.log event rather than raw text', () {
      MachineAppLogSink(protocol, 'app1')(line('flutter: hello'));

      final event = decodeSingleEvent(out);
      expect(event['event'], 'app.log');
      expect(event['params']['appId'], 'app1');
      expect(event['params']['log'], 'flutter: hello');
      expect(event['params']['error'], isFalse);
    });

    test('marks error lines with the error flag', () {
      MachineAppLogSink(protocol, 'app1')(line('boom', isError: true));

      expect(decodeSingleEvent(out)['params']['error'], isTrue);
    });

    test('every emitted line is well-formed protocol JSON', () {
      final sink = MachineAppLogSink(protocol, 'app1');
      sink(line('one'));
      sink(line('two'));

      // Nothing may reach stdout except `[{...}]` envelopes — an IDE parsing
      // this stream chokes on interleaved raw text.
      for (final l in out.lines) {
        expect(
          l.startsWith('[{') && l.endsWith('}]'),
          isTrue,
          reason: 'unexpected non-protocol line on stdout: $l',
        );
      }
      expect(out.lines, hasLength(2));
    });

    test('carries text that would otherwise break the JSON envelope', () {
      MachineAppLogSink(protocol, 'app1')(
        line('quote " brace } newline-ish \\n'),
      );

      expect(
        decodeSingleEvent(out)['params']['log'],
        'quote " brace } newline-ish \\n',
      );
    });

    test('a disabled protocol emits nothing at all', () {
      final quiet = BufferSink();
      MachineAppLogSink(
        MachineProtocol(enabled: false, output: quiet),
        'app1',
      )(line('hello'));

      expect(quiet.lines, isEmpty);
    });
  });

  group('appLogSinkFor', () {
    test('returns a machine sink when the protocol is enabled', () {
      final out = BufferSink();
      final sink = appLogSinkFor(
        protocol: MachineProtocol(enabled: true, output: out),
        appId: 'app1',
        deviceName: 'macOS',
        multiDevice: false,
        out: BufferSink(),
        err: BufferSink(),
      );
      sink(line('hello'));

      expect(decodeSingleEvent(out)['event'], 'app.log');
    });

    test('returns a terminal sink when the protocol is disabled', () {
      final terminalOut = BufferSink();
      final sink = appLogSinkFor(
        protocol: MachineProtocol(enabled: false, output: BufferSink()),
        appId: 'app1',
        deviceName: 'macOS',
        multiDevice: false,
        out: terminalOut,
        err: BufferSink(),
      );
      sink(line('hello'));

      expect(terminalOut.lines, ['hello']);
    });

    test('a multi-device terminal run prefixes with the device name', () {
      final terminalOut = BufferSink();
      final sink = appLogSinkFor(
        protocol: MachineProtocol(enabled: false, output: BufferSink()),
        appId: 'app1',
        deviceName: 'Chrome',
        multiDevice: true,
        out: terminalOut,
        err: BufferSink(),
      );
      sink(line('hello'));

      expect(terminalOut.lines, ['[Chrome] hello']);
    });

    test('machine mode ignores multiDevice — appId already disambiguates', () {
      final out = BufferSink();
      final sink = appLogSinkFor(
        protocol: MachineProtocol(enabled: true, output: out),
        appId: 'app1',
        deviceName: 'Chrome',
        multiDevice: true,
        out: BufferSink(),
        err: BufferSink(),
      );
      sink(line('hello'));

      expect(
        decodeSingleEvent(out)['params']['log'],
        'hello',
        reason: 'no [Chrome] prefix should be baked into the log payload',
      );
    });
  });
}
