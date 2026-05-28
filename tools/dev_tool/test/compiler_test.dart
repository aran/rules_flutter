import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/compiler.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('FrontendServerCompiler', () {
    late FakeProcess fakeProcess;
    late FrontendServerCompiler compiler;

    setUp(() async {
      fakeProcess = FakeProcess();
      final server = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeProcess,
      );
      await server.start();
      compiler = FrontendServerCompiler(server);
    });

    test('compileIncrement returns CompileSucceeded with dill path on success',
        () async {
      final future = compiler.compileIncrement(
        invalidated: {'package:app/main.dart'},
        entrypoint: 'package:app/main.dart',
      );

      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 0');

      final outcome = await future;
      expect(outcome, isA<CompileSucceeded>());
      expect((outcome as CompileSucceeded).dillPath, '/tmp/delta.dill');
    });

    test('compileIncrement returns CompileFailed with diagnostics on error',
        () async {
      final future = compiler.compileIncrement(
        invalidated: {'package:app/main.dart'},
        entrypoint: 'package:app/main.dart',
      );

      fakeProcess.emitStdout('lib/main.dart:1:8: Error: Bad syntax');
      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 1');

      final outcome = await future;
      expect(outcome, isA<CompileFailed>());
      expect((outcome as CompileFailed).diagnostics, contains('Bad syntax'));
    });

    test('compileFull returns CompileSucceeded on success', () async {
      final future = compiler.compileFull(entrypoint: 'package:app/main.dart');

      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/full.dill 0');

      final outcome = await future;
      expect(outcome, isA<CompileSucceeded>());
      expect((outcome as CompileSucceeded).dillPath, '/tmp/full.dill');
    });

    test('a second compileIncrement cancels the first (single-flight)',
        () async {
      final f1 = compiler.compileIncrement(
        invalidated: {'package:app/a.dart'},
        entrypoint: 'package:app/main.dart',
      );
      final f2 = compiler.compileIncrement(
        invalidated: {'package:app/b.dart'},
        entrypoint: 'package:app/main.dart',
      );

      // Complete the second one only.
      fakeProcess.emitStdout('result boundary_2');
      fakeProcess.emitStdout('boundary_2 /tmp/delta2.dill 0');

      final r1 = await f1;
      final r2 = await f2;

      expect(r1, isA<CompileFailed>(),
          reason: 'first compile should be cancelled by second');
      expect((r1 as CompileFailed).diagnostics, contains('Cancelled'));
      expect(r2, isA<CompileSucceeded>());
    });

    test('compileIncrement returns CompileFailed when the frontend_server process dies',
        () async {
      final future = compiler.compileIncrement(
        invalidated: {'package:app/main.dart'},
        entrypoint: 'package:app/main.dart',
      );

      fakeProcess.complete(1);

      final outcome = await future;
      expect(outcome, isA<CompileFailed>());
      expect(
        (outcome as CompileFailed).diagnostics,
        contains('exited unexpectedly'),
      );
    });

    test('commit and rollback delegate to FrontendServer accept/reject',
        () async {
      await compiler.commit();
      await compiler.rollback();

      final stdin = fakeProcess.stdinBuffer.toString();
      expect(stdin, contains('accept'));
      expect(stdin, contains('reject'));
    });
  });
}
