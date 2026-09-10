import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:test/test.dart';

void main() {
  // Both output modes funnel through one line at a time, so what is worth
  // pinning is where the lines come from: a pipe hands over arbitrary
  // fragments, and forwarding those as-is would put the frontend server's
  // prefix once per read rather than once per message, and give a JSON consumer
  // something other than one record per line.
  group('SubprocessOutput', () {
    test('holds a partial line until it is finished', () {
      final written = <String>[];
      final out = _RecordingOutput(written);

      out.write('INFO: Analyz');
      expect(written, isEmpty, reason: 'no newline yet, nothing complete');

      out.write('ed target //:app\n');
      expect(written, ['INFO: Analyzed target //:app']);
    });

    test('splits a chunk carrying several lines', () {
      final written = <String>[];
      _RecordingOutput(written).write('one\ntwo\nthree\n');
      expect(written, ['one', 'two', 'three']);
    });

    // A subprocess that dies mid-sentence still said something, and it is
    // usually the part that explains why it died.
    test('close releases a trailing line with no newline after it', () {
      final written = <String>[];
      final out = _RecordingOutput(written)..write('ERROR: no such target');
      expect(written, isEmpty);

      out.close();
      expect(written, ['ERROR: no such target']);
    });

    test(
      'close on a drained stream emits nothing, however often it is called',
      () {
        final written = <String>[];
        final out = _RecordingOutput(written)..write('done\n');
        out
          ..close()
          ..close();
        expect(written, ['done']);
      },
    );

    test('keeps blank lines, which are part of the output', () {
      final written = <String>[];
      _RecordingOutput(written).write('first\n\nsecond\n');
      expect(written, ['first', '', 'second']);
    });

    test('carries the source and stream it was given', () {
      final out = SubprocessOutput(
        source: 'frontend_server',
        stream: 'stderr',
        textPrefix: '[frontend_server] ',
      );
      expect(out.source, 'frontend_server');
      expect(out.stream, 'stderr');
      expect(out.textPrefix, '[frontend_server] ');
    });
  });

  // `LOG_LEVEL=DEBUG` is the natural guess and is not one of
  // `package:logging`'s names. Falling back to INFO would answer it by
  // ignoring it, which reads as a tool that does not honour the variable at
  // all.
  group('parseLogLevel', () {
    test('accepts the names package:logging defines', () {
      expect(parseLogLevel('INFO'), Level.INFO);
      expect(parseLogLevel('FINE'), Level.FINE);
      expect(parseLogLevel('SEVERE'), Level.SEVERE);
    });

    test('refuses a name that is not one, and lists the ones that are', () {
      expect(
        () => parseLogLevel('DEBUG'),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('LOG_LEVEL=DEBUG'), contains('FINE')),
          ),
        ),
      );
    });
  });
}

/// [SubprocessOutput] with the emit captured rather than written, so the line
/// splitting can be asserted without reading the test process's own stderr.
class _RecordingOutput extends SubprocessOutput {
  final List<String> written;
  _RecordingOutput(this.written) : super(source: 'test', stream: 'stdout');

  @override
  void emitLine(String line) => written.add(line);
}
