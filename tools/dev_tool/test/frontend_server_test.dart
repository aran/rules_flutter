import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('FrontendServer', () {
    late FakeProcess fakeProcess;
    late FrontendServer server;

    setUp(() {
      fakeProcess = FakeProcess();
      server = FrontendServer(
        dartaotruntimePath: '/dart/bin/dartaotruntime',
        frontendServerPath: '/tools/frontend_server_aot.dart.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/patched-sdk'),
        packageConfig: '/packages/.dart_tool/package_config.json',
        processFactory: (executable, args) async => fakeProcess,
      );
    });

    test('start launches process with correct args', () async {
      String? capturedExe;
      List<String>? capturedArgs;
      final proc = FakeProcess();
      final s = FrontendServer(
        dartaotruntimePath: '/dart/bin/dartaotruntime',
        frontendServerPath: '/tools/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/sdk-root'),
        packageConfig: '/pkg.json',
        processFactory: (exe, args) async {
          capturedExe = exe;
          capturedArgs = args;
          return proc;
        },
      );
      await s.start();

      expect(capturedExe, '/dart/bin/dartaotruntime');
      expect(capturedArgs, contains('/tools/frontend_server.snapshot'));
      expect(capturedArgs, contains('--sdk-root=/sdk-root/'));
      expect(capturedArgs, contains('--incremental'));
      expect(capturedArgs, contains('--target=flutter'));
      expect(capturedArgs, contains('--packages=/pkg.json'));
      expect(capturedArgs, contains('--enable-asserts'));
    });

    test('compile sends "compile <entrypoint>" to stdin', () async {
      await server.start();
      final future = server.compile('lib/main.dart');

      // Simulate real frontend_server protocol: result <key>, then <key> <path> <errors>.
      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /tmp/out.dill 0');

      final result = await future;
      expect(fakeProcess.stdinBuffer.toString(), contains('compile lib/main.dart'));
      expect(result.dillPath, '/tmp/out.dill');
      expect(result.success, isTrue);
    });

    test('recompile sends recompile with boundary key + invalidated files',
        () async {
      await server.start();
      final future = server.recompile(
        'lib/main.dart',
        ['file:///lib/foo.dart', 'file:///lib/bar.dart'],
      );

      // boundary_1 because _boundaryKey starts at 0 and increments to 1 on recompile.
      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 0');

      await future;
      final stdin = fakeProcess.stdinBuffer.toString();
      expect(stdin, contains('recompile lib/main.dart boundary_1'));
      expect(stdin, contains('file:///lib/foo.dart'));
      expect(stdin, contains('file:///lib/bar.dart'));
      expect(stdin, contains('boundary_1'));
    });

    test('accept sends "accept" to stdin', () async {
      await server.start();
      server.accept();
      expect(fakeProcess.stdinBuffer.toString(), contains('accept'));
    });

    test('reject sends "reject" to stdin', () async {
      await server.start();
      server.reject();
      expect(fakeProcess.stdinBuffer.toString(), contains('reject'));
    });

    test('shutdown sends "quit" and kills process', () async {
      await server.start();
      fakeProcess.complete(0);
      await server.shutdown();
      expect(fakeProcess.stdinBuffer.toString(), contains('quit'));
    });

    test('compile before start throws StateError', () {
      expect(
        () => server.compile('lib/main.dart'),
        throwsStateError,
      );
    });

    test('CompileResult.success based on non-empty dillPath', () {
      expect(
        CompileResult(dillPath: '/out.dill', success: true).success,
        isTrue,
      );
      expect(
        CompileResult(dillPath: '', success: false).success,
        isFalse,
      );
    });

    test('output parsing extracts dill path from result line', () async {
      await server.start();
      final future = server.compile('lib/main.dart');

      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /path/to/output.dill 0');

      final result = await future;
      expect(result.dillPath, '/path/to/output.dill');
      expect(result.success, isTrue);
    });

    test('diagnostics captures non-result output lines', () async {
      await server.start();
      final future = server.compile('lib/main.dart');

      // Simulate compiler errors before the result line.
      fakeProcess.emitStdout(
          'lib/main.dart:10:5: Error: Expected \';\' after this.');
      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /tmp/out.dill 0');

      final result = await future;
      expect(result.diagnostics,
          contains("Error: Expected ';' after this."));
      expect(result.dillPath, '/tmp/out.dill');
    });

    test('diagnostics is empty when no errors', () async {
      await server.start();
      final future = server.compile('lib/main.dart');

      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /tmp/out.dill 0');

      final result = await future;
      expect(result.diagnostics, isEmpty);
    });
  });
}
