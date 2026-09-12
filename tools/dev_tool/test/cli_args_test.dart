import 'package:flutter_bazel_dev_tool/cli_args.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:test/test.dart';

void main() {
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
}
