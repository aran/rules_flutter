/// What a [FakeProcess]'s stdin owes a test.
///
/// Asserted against the fake alone: the real half of this contract needs a
/// child process to read the pipe, and `cat` does not exist on Windows, which
/// this repo builds for.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  late FakeProcess process;

  setUp(() => process = FakeProcess());

  test('stdin is one sink, not a new one per access', () {
    // A real Process hands back one sink; a fresh sink per access would drop
    // the half-written line the splitting below depends on.
    expect(identical(process.stdin, process.stdin), isTrue);
  });

  group('lines come from the characters written, not the method', () {
    test('write with a terminator is a line', () async {
      final lines = <String>[];
      process.stdinLines.listen(lines.add);

      process.stdin.write('compile lib/main.dart\n');
      await pumpEventQueue();

      expect(lines, ['compile lib/main.dart']);
    });

    test('writeln is the same line as write plus a terminator', () async {
      final viaWrite = <String>[];
      final viaWriteln = <String>[];
      process.stdinLines.listen(viaWrite.add);
      process.stdin.write('quit\n');

      final other = FakeProcess();
      other.stdinLines.listen(viaWriteln.add);
      other.stdin.writeln('quit');
      await pumpEventQueue();

      // A reader cannot tell these apart, so neither may the fake.
      expect(viaWrite, viaWriteln);
    });

    test('bytes handed to add are a line too', () async {
      final lines = <String>[];
      process.stdinLines.listen(lines.add);

      process.stdin.add(utf8.encode('accept\n'));
      await pumpEventQueue();

      expect(lines, ['accept']);
    });

    test('a line split across two writes arrives once, whole', () async {
      final lines = <String>[];
      process.stdinLines.listen(lines.add);

      process.stdin.write('recompile ');
      process.stdin.write('lib/other.dart\n');
      await pumpEventQueue();

      expect(lines, ['recompile lib/other.dart']);
    });

    test('nothing is a line until its terminator is written', () async {
      final lines = <String>[];
      process.stdinLines.listen(lines.add);

      process.stdin.write('half a request');
      await pumpEventQueue();

      expect(lines, isEmpty);
      // ...and it is still buffered, not lost.
      expect(process.stdinBuffer.toString(), 'half a request');
    });
  });

  group('a sink that can no longer be written to', () {
    test('every write method throws once it is closed', () async {
      await process.stdin.close();

      // All five throw `StateError: StreamSink is closed` on a real IOSink.
      expect(() => process.stdin.write('x'), throwsStateError);
      expect(() => process.stdin.writeln('x'), throwsStateError);
      expect(() => process.stdin.add(const [120]), throwsStateError);
      expect(() => process.stdin.writeAll(const ['x']), throwsStateError);
      expect(() => process.stdin.writeCharCode(120), throwsStateError);
    });

    test('a broken pipe is a different failure from a closed sink', () {
      // The compiler tells these apart: a dead process under an open sink
      // raises an IOException, and it is reported rather than swallowed.
      process.stdinWriteError = const SocketException('Broken pipe');

      expect(() => process.stdin.write('x'), throwsA(isA<SocketException>()));
      expect(
        () => process.stdin.writeAll(const ['x']),
        throwsA(isA<SocketException>()),
      );
    });

    test('a refused write leaves nothing behind', () {
      process.stdinWriteError = const SocketException('Broken pipe');

      expect(
        () => process.stdin.write('lost'),
        throwsA(isA<SocketException>()),
      );
      expect(process.stdinBuffer.toString(), isEmpty);
    });
  });
}
