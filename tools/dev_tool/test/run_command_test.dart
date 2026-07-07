
import 'package:flutter_bazel_dev_tool/run_command.dart';
import 'package:test/test.dart';

void main() {
  group('RunCommand.parser', () {
    test('requires --target', () {
      final results = RunCommand.parser.parse([]);
      expect(results.wasParsed('target'), isFalse);
    });

    test('defaults --hot to true', () {
      final results = RunCommand.parser.parse(['-t', '//:app']);
      expect(results['hot'], isTrue);
    });

    test('defaults --machine to false', () {
      final results = RunCommand.parser.parse(['-t', '//:app']);
      expect(results['machine'], isFalse);
    });

    test('defaults --devtools to true', () {
      final results = RunCommand.parser.parse(['-t', '//:app']);
      expect(results['devtools'], isTrue);
    });

    test('accepts --no-devtools', () {
      final results = RunCommand.parser.parse(['-t', '//:app', '--no-devtools']);
      expect(results['devtools'], isFalse);
    });

    test('accepts multiple --device flags', () {
      final results = RunCommand.parser.parse([
        '-t', '//:app',
        '-d', 'macos',
        '-d', 'chrome',
      ]);
      expect(results['device'], ['macos', 'chrome']);
    });

    test('defaults --device to empty list', () {
      final results = RunCommand.parser.parse(['-t', '//:app']);
      expect(results['device'], isEmpty);
    });

    test('defaults --verbose to false', () {
      final results = RunCommand.parser.parse(['-t', '//:app']);
      expect(results['verbose'], isFalse);
    });

    test('accepts --verbose', () {
      final results = RunCommand.parser.parse(['-t', '//:app', '--verbose']);
      expect(results['verbose'], isTrue);
    });

    test('accepts -v shorthand for verbose', () {
      final results = RunCommand.parser.parse(['-t', '//:app', '-v']);
      expect(results['verbose'], isTrue);
    });

    test('accepts --help flag', () {
      final results = RunCommand.parser.parse(['--help']);
      expect(results['help'], isTrue);
    });

    test('defaults --watch to true', () {
      final results = RunCommand.parser.parse(['-t', '//:app']);
      expect(results['watch'], isTrue);
    });

    test('accepts --no-watch', () {
      final results = RunCommand.parser.parse(['-t', '//:app', '--no-watch']);
      expect(results['watch'], isFalse);
    });

    test('accepts --watch explicitly', () {
      final results = RunCommand.parser.parse(['-t', '//:app', '--watch']);
      expect(results['watch'], isTrue);
    });

    test('defaults --http-control-channel to true', () {
      final results = RunCommand.parser.parse(['-t', '//:app']);
      expect(results['http-control-channel'], isTrue);
    });

    test('accepts --no-http-control-channel', () {
      final results = RunCommand.parser.parse(['-t', '//:app', '--no-http-control-channel']);
      expect(results['http-control-channel'], isFalse);
    });

    test('accepts repeated --dart-define, values kept whole', () {
      final results = RunCommand.parser.parse([
        '-t', '//:app',
        '--dart-define', 'A=1',
        '--dart-define', 'B=x,y',
      ]);
      expect(results['dart-define'], ['A=1', 'B=x,y']);
    });

    test('defaults --dart-define to empty list', () {
      final results = RunCommand.parser.parse(['-t', '//:app']);
      expect(results['dart-define'], isEmpty);
    });
  });

  group('DevToolException', () {
    test('has message and default exit code', () {
      final e = DevToolException('build failed');
      expect(e.message, 'build failed');
      expect(e.exitCode, 1);
      expect(e.toString(), 'build failed');
    });

    test('accepts custom exit code', () {
      final e = DevToolException('failed', exitCode: 42);
      expect(e.exitCode, 42);
    });
  });

  group('categorizeOutputFiles', () {
    test('categorizes .dill as kernel', () {
      final result = categorizeOutputFiles(['/out/app.dill']);
      expect(result['kernel'], ['/out/app.dill']);
    });

    test('categorizes .so and .dylib as native', () {
      final result = categorizeOutputFiles([
        '/out/libapp.so',
        '/out/app.dylib',
      ]);
      expect(result['native'], hasLength(2));
    });

    test('categorizes .apk as apk', () {
      final result = categorizeOutputFiles(['/out/app.apk']);
      expect(result['apk'], ['/out/app.apk']);
    });

    test('categorizes .ipa as ipa', () {
      final result = categorizeOutputFiles(['/out/app.ipa']);
      expect(result['ipa'], ['/out/app.ipa']);
    });

    test('categorizes .app as bundle', () {
      final result = categorizeOutputFiles(['/out/MyApp.app']);
      expect(result['bundle'], ['/out/MyApp.app']);
    });

    test('categorizes unknown extensions as other', () {
      final result = categorizeOutputFiles(['/out/file.txt']);
      expect(result['other'], ['/out/file.txt']);
    });

    test('handles mixed file types', () {
      final result = categorizeOutputFiles([
        '/out/MyApp.app',
        '/out/app.dill',
        '/out/libapp.so',
        '/out/app.apk',
        '/out/app.ipa',
        '/out/other.txt',
      ]);
      expect(result['bundle'], ['/out/MyApp.app']);
      expect(result['kernel'], ['/out/app.dill']);
      expect(result['native'], ['/out/libapp.so']);
      expect(result['apk'], ['/out/app.apk']);
      expect(result['ipa'], ['/out/app.ipa']);
      expect(result['other'], ['/out/other.txt']);
    });

    test('returns empty map for empty list', () {
      final result = categorizeOutputFiles([]);
      expect(result, isEmpty);
    });
  });
}
