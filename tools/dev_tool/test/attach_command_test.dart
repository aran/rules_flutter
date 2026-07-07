import 'package:flutter_bazel_dev_tool/attach_command.dart';
import 'package:test/test.dart';

void main() {
  group('AttachCommand.parser', () {
    test('requires --target', () {
      final results = AttachCommand.parser.parse([]);
      expect(results.wasParsed('target'), isFalse);
    });

    test('accepts multiple --debug-url flags', () {
      final results = AttachCommand.parser.parse([
        '-t', '//:app',
        '--debug-url', 'http://localhost:1234/',
        '--debug-url', 'http://localhost:5678/',
      ]);
      expect(results['debug-url'], [
        'http://localhost:1234/',
        'http://localhost:5678/',
      ]);
    });

    test('defaults --machine to false', () {
      final results = AttachCommand.parser.parse(['-t', '//:app']);
      expect(results['machine'], isFalse);
    });

    test('defaults --devtools to true', () {
      final results = AttachCommand.parser.parse(['-t', '//:app']);
      expect(results['devtools'], isTrue);
    });

    test('accepts --no-devtools', () {
      final results = AttachCommand.parser.parse([
        '-t', '//:app',
        '--no-devtools',
      ]);
      expect(results['devtools'], isFalse);
    });

    test('accepts repeated --dart-define, defaults empty', () {
      expect(AttachCommand.parser.parse(['-t', '//:app'])['dart-define'],
          isEmpty);
      final results = AttachCommand.parser.parse([
        '-t', '//:app',
        '--dart-define', 'A=1',
        '--dart-define', 'B=x,y',
      ]);
      expect(results['dart-define'], ['A=1', 'B=x,y']);
    });
  });
}
