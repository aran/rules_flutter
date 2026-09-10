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

    test(
      'compileIncrement returns CompileSucceeded with dill path on success',
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
      },
    );

    test(
      'compileIncrement returns CompileFailed with diagnostics on error',
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
      },
    );

    test('compileFull returns CompileSucceeded on success', () async {
      final future = compiler.compileFull(
        entrypoint: 'package:app/main.dart',
        invalidated: {'package:app/a.dart'},
      );

      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/full.dill 0');

      final outcome = await future;
      expect(outcome, isA<CompileSucceeded>());
      expect((outcome as CompileSucceeded).dillPath, '/tmp/full.dill');
    });

    // The verb a restart goes out as, and the one thing about it a fake
    // frontend server can see. `compile` would be wrong twice over: it answers
    // with the compiler's CUMULATIVE error count — a compile that failed once
    // reports a failure for every later `compile`, with the corrected code in
    // the dill it just wrote — and it is not what upstream sends. `reset`
    // makes the answer a whole program; the `recompile` verb is what clears
    // the error list.
    test(
      'compileFull sends reset then recompile, not a second compile',
      () async {
        final future = compiler.compileFull(
          entrypoint: 'package:app/main.dart',
          invalidated: {'file:///app/lib/a.dart'},
        );

        fakeProcess.emitStdout('result boundary_1');
        fakeProcess.emitStdout('boundary_1 /tmp/full.dill 0');
        await future;

        final written = fakeProcess.stdinBuffer.toString();
        expect(written, contains('reset\n'));
        expect(
          written,
          contains('recompile package:app/main.dart boundary_1'),
          reason: 'the restart must go out as a recompile: $written',
        );
        expect(
          written,
          contains('file:///app/lib/a.dart'),
          reason: 'the invalidation travels on the same request: $written',
        );
        expect(
          written.indexOf('reset'),
          lessThan(written.indexOf('recompile package:app/main.dart')),
          reason: 'the reset has to precede the recompile it applies to',
        );
        expect(
          written,
          isNot(contains('compile package:app/main.dart\n')),
          reason:
              'a bare `compile` is the verb whose error count is '
              'cumulative: $written',
        );
      },
    );

    test('a second compileIncrement queues behind the first', () async {
      // The compiler's protocol carries no request id, so two exchanges in
      // flight at once hand one request the other's answer. Serialized, each
      // keeps its own dill — including when the second caller is the debugger
      // rather than the reload path.
      final first = compiler.compileIncrement(
        invalidated: {'package:app/a.dart'},
        entrypoint: 'package:app/main.dart',
      );
      final second = compiler.compileIncrement(
        invalidated: {'package:app/b.dart'},
        entrypoint: 'package:app/main.dart',
      );

      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/delta1.dill 0');
      final firstOutcome = await first;
      expect((firstOutcome as CompileSucceeded).dillPath, '/tmp/delta1.dill');

      await pumpEventQueue();
      fakeProcess.emitStdout('result boundary_2');
      fakeProcess.emitStdout('boundary_2 /tmp/delta2.dill 0');
      final secondOutcome = await second;
      expect(
        (secondOutcome as CompileSucceeded).dillPath,
        '/tmp/delta2.dill',
        reason: 'each request keeps its own answer',
      );
    });
    test(
      'compileIncrement returns CompileFailed when the frontend_server process dies',
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
      },
    );

    test(
      'commit and rollback delegate to FrontendServer accept/reject',
      () async {
        // A verdict is only meaningful on a compile the server is still holding,
        // so each half needs its own compile to answer for.
        final first = compiler.compileIncrement(
          invalidated: {'package:app/main.dart'},
          entrypoint: 'package:app/main.dart',
        );
        fakeProcess.emitStdout('result boundary_1');
        fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 0');
        await first;
        await compiler.commit();

        final second = compiler.compileIncrement(
          invalidated: {'package:app/main.dart'},
          entrypoint: 'package:app/main.dart',
        );
        fakeProcess.emitStdout('result boundary_2');
        fakeProcess.emitStdout('boundary_2 /tmp/delta2.dill 0');
        await second;
        final rolledBack = compiler.rollback();
        fakeProcess.emitStdout('result reject_key');
        fakeProcess.emitStdout('reject_key');
        await rolledBack;

        final stdin = fakeProcess.stdinBuffer.toString();
        expect(stdin, contains('accept'));
        expect(stdin, contains('reject'));
      },
    );

    test(
      'rollback does not return until the compiler acknowledges it',
      () async {
        // The contract `package:frontend_server_client` states: the result of a
        // reject must be awaited before a new compile can be done. A rollback
        // that returns early lets the next compile start against two unread
        // protocol lines, which wedges the session.
        final first = compiler.compileIncrement(
          invalidated: {'package:app/main.dart'},
          entrypoint: 'package:app/main.dart',
        );
        fakeProcess.emitStdout('result boundary_1');
        fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 1');
        await first;

        var returned = false;
        final rolledBack = compiler.rollback().then((_) => returned = true);
        await pumpEventQueue();
        expect(
          returned,
          isFalse,
          reason: 'rollback returned before the reject was acknowledged',
        );

        fakeProcess.emitStdout('result reject_key');
        fakeProcess.emitStdout('reject_key');
        await rolledBack;
        expect(returned, isTrue);
      },
    );
  });
}
