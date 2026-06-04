import 'dart:async';

import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('FrontendServer process death (H4)', () {
    test('completes pending result when process exits unexpectedly', () async {
      final fakeProcess = FakeProcess();
      final server = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeProcess,
      );

      await server.start();
      final future = server.compile('lib/main.dart');

      // Simulate process death before result arrives.
      fakeProcess.complete(1);

      final result = await future;
      expect(result.success, isFalse);
      expect(result.diagnostics, contains('exited unexpectedly'));
    });

    test('does not hang on recompile when process dies', () async {
      final fakeProcess = FakeProcess();
      final server = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeProcess,
      );

      await server.start();
      final future = server.recompile('lib/main.dart', ['file:///lib/foo.dart']);

      fakeProcess.complete(1);

      final result = await future;
      expect(result.success, isFalse);
    });
  });

  group('Concurrent compile cancellation (H5)', () {
    test('first compile is cancelled when second starts', () async {
      final fakeProcess = FakeProcess();
      final server = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeProcess,
      );

      await server.start();

      // Start first compile.
      final future1 = server.compile('lib/main.dart');

      // Start second compile before first finishes — should cancel first.
      final future2 = server.compile('lib/main.dart');

      // First should complete with cancellation.
      final result1 = await future1;
      expect(result1.success, isFalse);
      expect(result1.diagnostics, contains('Cancelled'));

      // Complete second normally.
      fakeProcess.emitStdout('result abc123');
      fakeProcess.emitStdout('abc123 /tmp/out.dill 0');
      final result2 = await future2;
      expect(result2.success, isTrue);
      expect(result2.dillPath, '/tmp/out.dill');
    });

    test('recompile cancels pending compile', () async {
      final fakeProcess = FakeProcess();
      final server = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeProcess,
      );

      await server.start();

      final compileFuture = server.compile('lib/main.dart');
      final recompileFuture = server.recompile('lib/main.dart', ['file:///lib/a.dart']);

      // First should be cancelled.
      final compileResult = await compileFuture;
      expect(compileResult.success, isFalse);

      // Second should complete normally.
      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 0');
      final recompileResult = await recompileFuture;
      expect(recompileResult.success, isTrue);
    });
  });

  group('Line buffering (M9)', () {
    test('handles partial chunks correctly', () async {
      final fakeProcess = FakeProcess();
      final server = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeProcess,
      );

      await server.start();
      final future = server.compile('lib/main.dart');

      // Send result and completion in partial chunks.
      fakeProcess.emitStdoutRaw('result abc');
      await Future.delayed(Duration(milliseconds: 10));
      fakeProcess.emitStdoutRaw('123\nabc123 /tmp/out.dill 0\n');

      final result = await future;
      expect(result.success, isTrue);
      expect(result.dillPath, '/tmp/out.dill');
    });

    test('detects compile errors in diagnostics', () async {
      final fakeProcess = FakeProcess();
      final server = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeProcess,
      );

      await server.start();
      final future = server.compile('lib/main.dart');

      fakeProcess.emitStdout('lib/main.dart:1:8: Error: Not found');
      fakeProcess.emitStdout('result abc123');
      fakeProcess.emitStdout('abc123 /tmp/out.dill 1');

      final result = await future;
      expect(result.success, isFalse);
    });
  });
}
