import 'package:args/args.dart';
import 'package:flutter_bazel_dev_tool/attach_command.dart';
import 'package:flutter_bazel_dev_tool/run_plan.dart';
import 'package:test/test.dart';

void main() {
  group('AttachCommand.parser', () {
    test('requires --target', () {
      final results = AttachCommand.parser.parse([]);
      expect(results.wasParsed('target'), isFalse);
    });

    test('accepts multiple --debug-url flags', () {
      final results = AttachCommand.parser.parse([
        '-t',
        '//:app',
        '--debug-url',
        'http://localhost:1234/',
        '--debug-url',
        'http://localhost:5678/',
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

    // Asserted through the same helper `run` resolves with, against attach's
    // own parser, so the two cannot drift into disagreeing about what a
    // terminal or machine session defaults to. `watchEnabledFor` reads
    // `wasParsed('watch')`, which throws outright if the flag is missing — so
    // these are also what catches the flag being dropped.
    group('--watch mirrors run', () {
      ArgResults parse(List<String> args) =>
          AttachCommand.parser.parse(['-t', '//:app', ...args]);

      test('terminal watches, machine does not', () {
        expect(RunPlan.watchEnabledFor(parse([]), isMachine: false), isTrue);
        expect(RunPlan.watchEnabledFor(parse([]), isMachine: true), isFalse);
      });

      test('an explicit --watch beats machine mode', () {
        expect(
          RunPlan.watchEnabledFor(parse(['--watch']), isMachine: true),
          isTrue,
        );
      });

      test('an explicit --no-watch beats terminal mode', () {
        expect(
          RunPlan.watchEnabledFor(parse(['--no-watch']), isMachine: false),
          isFalse,
        );
      });
    });

    test('defaults --devtools to true', () {
      final results = AttachCommand.parser.parse(['-t', '//:app']);
      expect(results['devtools'], isTrue);
    });

    test('accepts --no-devtools', () {
      final results = AttachCommand.parser.parse([
        '-t',
        '//:app',
        '--no-devtools',
      ]);
      expect(results['devtools'], isFalse);
    });

    // The running app reports the defines it was compiled with, and the
    // pipeline builds its dev config with those. A flag here could only repeat
    // them — or contradict the binary that is running, which is the failure it
    // would look like a fix for.
    test('takes no --dart-define', () {
      expect(AttachCommand.parser.options.containsKey('dart-define'), isFalse);
      expect(
        () => AttachCommand.parser.parse([
          '-t',
          '//:app',
          '--dart-define',
          'A=1',
        ]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('dart-define'),
          ),
        ),
      );
    });

    // Unlike a define, a build arg is recorded nowhere in the app, so attach
    // still has to be told the ones the run used.
    test('accepts repeated --build-arg, defaults empty', () {
      expect(
        AttachCommand.parser.parse(['-t', '//:app'])['build-arg'],
        isEmpty,
      );
      final results = AttachCommand.parser.parse([
        '-t',
        '//:app',
        '--build-arg',
        '--//flags:one',
        '--build-arg',
        '--//flags:two',
      ]);
      expect(results['build-arg'], ['--//flags:one', '--//flags:two']);
    });
  });
}
