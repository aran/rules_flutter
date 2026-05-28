import 'package:flutter_bazel_dev_tool/build_command.dart';
import 'package:test/test.dart';

void main() {
  group('BuildCommand.parser', () {
    test('requires --target', () {
      // mandatory: true means accessing the option throws if not provided.
      final results = BuildCommand.parser.parse([]);
      expect(results.wasParsed('target'), isFalse);
    });

    test('accepts -t shorthand', () {
      final results = BuildCommand.parser.parse(['-t', '//:my_app']);
      expect(results['target'], '//:my_app');
    });

    test('accepts --config', () {
      final results = BuildCommand.parser
          .parse(['-t', '//:app', '--config', 'release']);
      expect(results['config'], 'release');
    });

    test('accepts multiple --build-arg values', () {
      final results = BuildCommand.parser.parse([
        '-t', '//:app',
        '--build-arg', '--verbose',
        '--build-arg', '--jobs=4',
      ]);
      expect(results['build-arg'], ['--verbose', '--jobs=4']);
    });
  });
}
