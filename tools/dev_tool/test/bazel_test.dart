import 'package:flutter_bazel_dev_tool/bazel.dart';
import 'package:test/test.dart';

void main() {
  group('BazelBuildResult', () {
    test('success is true when exitCode is 0', () {
      final result = BazelBuildResult(
        exitCode: 0,
        outputFiles: ['/tmp/out'],
        stderr: '',
      );
      expect(result.success, isTrue);
    });

    test('success is false when exitCode is non-zero', () {
      final result = BazelBuildResult(
        exitCode: 1,
        outputFiles: [],
        stderr: 'error',
      );
      expect(result.success, isFalse);
    });

    // Without this, a failed build is indistinguishable from one that produced
    // nothing: the caller reads `.outputFiles`, gets an empty list, and reports
    // whichever output it wanted as missing.
    test('asFailure carries the command and what bazel said', () {
      final failure = BazelBuildResult(
        exitCode: 1,
        outputFiles: [],
        stderr: "lib/main.dart:12:5: Error: Expected ';' after this.",
      ).asFailure('build //:app');

      expect(failure.command, 'build //:app');
      expect(failure.diagnostics, contains("Expected ';'"));
      expect('$failure', contains('bazel build //:app failed'));
      expect(
        '$failure',
        contains("Expected ';'"),
        reason:
            'the cause has to travel with the failure; by the time this '
            'is read the streamed copy has scrolled past',
      );
    });

    test('asFailure refuses a build that succeeded', () {
      // There is no failure to raise, and inventing one would report a working
      // build as broken.
      expect(
        () => BazelBuildResult(
          exitCode: 0,
          outputFiles: ['/tmp/out'],
          stderr: '',
        ).asFailure('build //:app'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('BazelInvocationFailure', () {
    test('says which command failed even when bazel printed nothing', () {
      const failure = BazelInvocationFailure(
        command: 'cquery //:app',
        diagnostics: '',
      );
      expect('$failure', 'bazel cquery //:app failed');
    });
  });

  // The dev tool reads build outputs off disk. The `flutter_assets` tree it
  // diffs belongs to a transitioned configuration, so it is an output of a
  // configured target nobody names on the command line — requested through an
  // aspect rather than by widening the download policy, which would make bazel
  // write down everything it produces for every user and every build.
  group('bazelBuildArgs', () {
    test('asks bazel for the files the dev loop reads', () {
      final args = bazelBuildArgs('//:app', compilationMode: 'dbg');
      expect(args, containsAllInOrder(['build', '//:app', '-c', 'dbg']));
      expect(
        args,
        contains(
          '--aspects=@rules_flutter//flutter:dev_files.bzl%flutter_dev_files',
        ),
      );
      expect(args, contains('--output_groups=+flutter_dev_files'));
    });

    test('does not touch the download policy', () {
      // Requesting the outputs is enough; overriding how bazel materializes
      // everything else is not the dev tool's call.
      expect(
        bazelBuildArgs('//:app', compilationMode: 'dbg').join(' '),
        isNot(contains('--remote_download_outputs')),
      );
    });

    test('leaves the caller\'s download policy alone', () {
      // A user who sets one means it. The aspect asks for more outputs; it
      // does not change how anything is built, so there is nothing here that
      // needs to win over `--build-arg`.
      final args = bazelBuildArgs(
        '//:app',
        extraArgs: ['--remote_download_outputs=minimal'],
      );
      expect(args, contains('--remote_download_outputs=minimal'));
      expect(
        args.where((a) => a.startsWith('--remote_download_outputs')).length,
        1,
      );
    });

    test('passes the caller\'s own args through in order', () {
      expect(
        bazelBuildArgs(
          '//:app',
          compilationMode: 'dbg',
          extraArgs: ['--define=a=b', '--//flutter:x=y'],
        ),
        containsAllInOrder([
          'build',
          '//:app',
          '-c',
          'dbg',
          '--define=a=b',
          '--//flutter:x=y',
        ]),
      );
    });
  });

  group('dartDefineFlags', () {
    test('maps each define to one repeatable build-setting flag', () {
      expect(dartDefineFlags(['A=1', 'B=x,y']), [
        '--@rules_flutter//flutter:extra_dart_defines=A=1',
        '--@rules_flutter//flutter:extra_dart_defines=B=x,y',
      ]);
    });

    test('empty defines produce no flags', () {
      expect(dartDefineFlags([]), isEmpty);
    });
  });

  // findWorkspaceRoot() reads BUILD_WORKSPACE_DIRECTORY (set by
  // `bazel run`) and falls back to spawning `bazel info workspace`.
  // Both paths are end-to-end signals that don't unit-test cleanly
  // without dependency injection, and the function is small enough that
  // the gain from injecting a fake env / process runner doesn't pay for
  // the surface-area cost.
}
