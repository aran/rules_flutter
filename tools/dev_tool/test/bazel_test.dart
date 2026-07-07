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
  // the surface-area cost. Verified manually with repros from a consumer
  // workspace and the standalone-invocation paths.
}
