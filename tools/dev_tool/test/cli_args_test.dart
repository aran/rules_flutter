import 'package:args/args.dart';
import 'package:flutter_bazel_dev_tool/attach_command.dart';
import 'package:flutter_bazel_dev_tool/build_command.dart';
import 'package:flutter_bazel_dev_tool/cli_args.dart';
import 'package:flutter_bazel_dev_tool/device_id.dart';
import 'package:flutter_bazel_dev_tool/run_command.dart';
import 'package:test/test.dart';

void main() {
  group('topLevelUsage', () {
    final usage = topLevelUsage(
      ArgParser()
        ..addCommand('build', BuildCommand.parser)
        ..addCommand('run', RunCommand.parser)
        ..addCommand('attach', AttachCommand.parser),
    );
    // Wrapping puts line breaks and indents between words; read past them.
    final prose = usage.replaceAll(RegExp(r'\s+'), ' ');

    test('offers exactly the -d forms the tool accepts', () {
      for (final form in acceptedDeviceIdForms) {
        expect(prose, contains(form));
      }
      // `resolveDevices` refuses an id that does not name its kind
      // (device_id_test covers that), so help offering one sends the reader
      // straight to the refusal.
      expect(prose, isNot(contains('or Android serial')));
      expect(prose, contains('a bare UDID or serial is refused'));
    });

    test('says run builds -c dbg for --hot, not that the user must', () {
      // `RunPlan.compilationModeFor` picks `dbg` when hot reload is on and
      // refuses a `-c` that contradicts it; run_plan_test covers both.
      expect(prose, isNot(contains('requires -c dbg')));
      expect(prose, contains('Builds -c dbg'));
      expect(
        RunCommand.parser.options['hot']!.help,
        allOf(contains('Builds -c dbg'), isNot(contains('requires'))),
      );
    });

    test('summarizes run options with run --help\'s own text', () {
      for (final name in ['device', 'hot', 'devtools', 'machine']) {
        final help = RunCommand.parser.options[name]!.help!;
        expect(prose, contains(help.replaceAll(RegExp(r'\s+'), ' ')));
      }
      expect(prose, contains('--[no-]hot'));
    });

    test('points at the agent commands and where a run lists them', () {
      expect(prose, contains('app.tap'));
      expect(prose, contains('GET /commands'));
    });

    test('keeps every line within 80 columns', () {
      final topLevel = usage.substring(0, usage.indexOf('Machine protocol'));
      for (final line in topLevel.split('\n')) {
        expect(line.length, lessThanOrEqualTo(80), reason: line);
      }
    });
  });

  test('a bazel flag that could not parse as an option is refused', () {
    // The mistake this exists for. `--@rules_flutter//...` carries `@`, `/` and
    // `:`, so `ArgParser` never sees an option name and the whole thing becomes
    // a positional argument — where silence means the run builds with the app's
    // defaults and fails much later, somewhere else.
    expect(
      () => requireNoPositionalArgs('run', [
        '--@rules_flutter//flutter:extra_dart_defines=KEY=VALUE',
      ]),
      throwsA(
        isA<DevToolException>().having(
          (e) => '$e',
          'message',
          allOf(
            contains('--@rules_flutter//flutter:extra_dart_defines=KEY=VALUE'),
            // Both spellings that would have worked, because which one a reader
            // needs depends on what they were trying to pass.
            contains('--build-arg'),
            contains('--dart-define'),
            contains('flutter_bazel run --help'),
          ),
        ),
      ),
    );
  });

  test('every stray argument is named, not just the first', () {
    expect(
      () => requireNoPositionalArgs('build', ['--one=1', 'two']),
      throwsA(
        isA<DevToolException>().having(
          (e) => '$e',
          'message',
          allOf(contains('--one=1'), contains('two')),
        ),
      ),
    );
  });

  test('an argv with no positionals passes', () {
    expect(() => requireNoPositionalArgs('run', const []), returnsNormally);
  });

  // `ArgParser` splits a multi-option on commas unless told not to, which cut
  // `--build-arg=--ui_event_filters=-info,-progress` in two and handed bazel a
  // bare `-progress` it refused. A comma inside a bazel flag's value is
  // ordinary — `--copt=-Wl,-rpath`, `--platforms=a,b` — and `--build-arg` is
  // already repeatable, so there is no second meaning for one to carry.
  group('--build-arg keeps a comma inside the flag it passes', () {
    for (final (command, parser) in [
      ('run', RunCommand.parser),
      ('build', BuildCommand.parser),
      ('attach', AttachCommand.parser),
    ]) {
      test(command, () {
        final results = parser.parse([
          '-t',
          '//:app',
          '--build-arg=--ui_event_filters=-info,-progress',
          '--build-arg',
          '--copt=-Wl,-rpath',
        ]);

        expect(results['build-arg'], [
          '--ui_event_filters=-info,-progress',
          '--copt=-Wl,-rpath',
        ]);
      });
    }
  });
}
