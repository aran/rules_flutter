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
      final future = server.recompile('lib/main.dart', [
        'file:///lib/foo.dart',
      ]);

      fakeProcess.complete(1);

      final result = await future;
      expect(result.success, isFalse);
    });
  });

  group('Concurrent requests to one compiler', () {
    // Requests queue rather than cancel one another: the compiler is never told
    // about a cancellation, so a cancelled request's answer still arrives —
    // against the next request's completer, as a dill for a compile nobody
    // asked for. Every production compile is serialized by CommandRunner's
    // Pool(1) and each app owns its own server, so overlap is a caller bug.
    FrontendServer serverWith(FakeProcess p) => FrontendServer(
      dartaotruntimePath: '/fake/dartaotruntime',
      frontendServerPath: '/fake/frontend_server.snapshot',
      config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
      packageConfig: '/fake/package_config.json',
      processFactory: (exe, args) async => p,
    );

    test('a second compile queues behind the first', () async {
      // The protocol carries no request id, so two exchanges in flight at
      // once hand one request the other's answer. Serialized, each keeps its
      // own — which is what lets the debugger's expression compiles share
      // this compiler with the reload path.
      final fakeProcess = FakeProcess();
      final server = serverWith(fakeProcess);
      await server.start();

      final first = server.compile('lib/main.dart');
      final second = server.compile('lib/main.dart');

      fakeProcess.emitStdout('result abc123');
      fakeProcess.emitStdout('abc123 /tmp/first.dill 0');
      expect((await first).dillPath, '/tmp/first.dill');

      await pumpEventQueue();
      fakeProcess.emitStdout('result def456');
      fakeProcess.emitStdout('def456 /tmp/second.dill 0');
      expect(
        (await second).dillPath,
        '/tmp/second.dill',
        reason: 'each request keeps its own answer',
      );
    });

    test('a recompile queued behind a compile keeps its own answer', () async {
      final fakeProcess = FakeProcess();
      final server = serverWith(fakeProcess);
      await server.start();

      final first = server.compile('lib/main.dart');
      final second = server.recompile('lib/main.dart', ['file:///lib/a.dart']);

      fakeProcess.emitStdout('result abc123');
      fakeProcess.emitStdout('abc123 /tmp/first.dill 0');
      expect((await first).dillPath, '/tmp/first.dill');

      await pumpEventQueue();
      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 0');
      expect((await second).dillPath, '/tmp/delta.dill');
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
