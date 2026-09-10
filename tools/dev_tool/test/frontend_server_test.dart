import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:logging/logging.dart';
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

    /// Put the server in the state a verdict is meaningful in: one compile
    /// done and not yet accepted or rejected.
    Future<void> compileAwaitingVerdict() async {
      final first = server.recompile('lib/main.dart', const []);
      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 0');
      await first;
    }

    /// Put the server in the window where `shutdown` has begun and written its
    /// `quit` but the process has not exited, so the pipe is already gone
    /// while the run is still using the server.
    Future<Future<void>> beginShutdown() async {
      final shuttingDown = server.shutdown();
      await pumpEventQueue();
      fakeProcess.stdinWriteError = const SocketException(
        'Broken pipe',
        osError: OSError('', 32),
      );
      return Future.value(shuttingDown);
    }

    // `app.stop` arriving while a compile is in flight shuts the compiler
    // down, and the `accept()` that follows writes to a closed pipe. A broken
    // pipe is an IOException, not a StateError, so a guard that catches only
    // StateError lets it end the whole run instead of tearing down cleanly.
    test('accept mid-shutdown is silent, not fatal', () async {
      await server.start();
      await compileAwaitingVerdict();
      final logs = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(logs.add);
      addTearDown(sub.cancel);
      final shuttingDown = await beginShutdown();

      expect(server.accept, returnsNormally);
      expect(server.reject, returnsNormally);
      // Expected while quitting, so it must not be reported as a problem — a
      // run on its way out should not print a compiler failure.
      expect(logs.where((r) => r.level >= Level.SEVERE), isEmpty);

      fakeProcess.complete(0);
      await shuttingDown;
    });

    // Silence is not enough, because a real pipe does not fail the way the
    // fake above does. `Socket.write` hands the bytes to the sink and the
    // failure comes back out of the sink's own delivery, where it is reported
    // to the zone instead of thrown to the caller — past every `try` in this
    // class, and fatal. So the guarantee has to be that nothing is written at
    // all once the shutdown has begun.
    test('nothing is written to the pipe after shutdown begins', () async {
      await server.start();
      await compileAwaitingVerdict();
      final shuttingDown = server.shutdown();
      await pumpEventQueue();
      final afterQuit = fakeProcess.stdinBuffer.length;

      server.accept();
      server.reject();
      expect(
        fakeProcess.stdinBuffer.length,
        afterQuit,
        reason: 'the pipe is gone; these must not reach it at all',
      );

      fakeProcess.complete(0);
      await shuttingDown;
    });

    test('a compiler that dies mid-reject does not hold the queue', () async {
      // `reject` is the one exchange the compiler answers, so a process that
      // dies waiting to acknowledge one must not leave the request waiting out
      // the full response timeout — it holds the single request permit, with
      // every queued reload stalled behind it, and there is nothing left to
      // wait for.
      await server.start();
      await compileAwaitingVerdict();

      final rejecting = server.reject();
      await pumpEventQueue();
      fakeProcess.complete(1);

      // Bounded, not "eventually": the point is that it does not wait out the
      // two-minute response timeout.
      await expectLater(
        rejecting.timeout(const Duration(seconds: 5)),
        completes,
      );
    });

    test(
      'a stale result key does not swallow the next request\'s answer',
      () async {
        // A `result <key>` line can arrive with nothing waiting for it — an
        // abandoned request's answer turning up late. A key left over from it
        // makes the next request's own `result` line look like the stray echo
        // the parser skips, after which nothing matches and that request waits
        // out its whole timeout too.
        await server.start();
        fakeProcess.emitStdout('result stale');
        await pumpEventQueue();

        final next = server.compile('lib/main.dart');
        await pumpEventQueue();
        fakeProcess.emitStdout('result fresh');
        fakeProcess.emitStdout('fresh /tmp/next.dill 0');
        expect(
          (await next.timeout(const Duration(seconds: 5))).dillPath,
          '/tmp/next.dill',
        );
      },
    );

    test(
      'a compiler that dies on its own is reported, not swallowed',
      () async {
        await server.start();
        await compileAwaitingVerdict();
        final logs = <LogRecord>[];
        final sub = Logger.root.onRecord.listen(logs.add);
        addTearDown(sub.cancel);

        // No shutdown: the pipe went away by itself, which means every later
        // reload will fail and the user has to be told why.
        fakeProcess.stdinWriteError = const SocketException(
          'Broken pipe',
          osError: OSError('', 32),
        );

        expect(server.accept, returnsNormally);
        expect(
          logs.map((r) => r.message.toString()),
          contains(contains('frontend_server_gone')),
        );
      },
    );

    test(
      'a compile requested mid-shutdown answers instead of hanging',
      () async {
        // `compile` returns `_pendingResult.future`, and skipping the write
        // without completing it would leave the caller waiting forever for a
        // compiler that is gone.
        await server.start();
        final shuttingDown = await beginShutdown();

        final result = await server
            .compile('package:app/main.dart')
            .timeout(const Duration(seconds: 5));

        expect(result.success, isFalse);
        expect(result.diagnostics, contains('shutting down'));

        fakeProcess.complete(0);
        await shuttingDown;
      },
    );

    test('a recompile requested mid-shutdown answers too', () async {
      await server.start();
      final shuttingDown = await beginShutdown();

      final result = await server
          .recompile('package:app/main.dart', ['package:app/main.dart'])
          .timeout(const Duration(seconds: 5));

      expect(result.success, isFalse);
      expect(result.diagnostics, contains('shutting down'));

      fakeProcess.complete(0);
      await shuttingDown;
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

    test(
      'NativeCompilerConfig emits multi-root flags for codegen apps',
      () async {
        List<String>? capturedArgs;
        final s = FrontendServer(
          dartaotruntimePath: '/dart/bin/dartaotruntime',
          frontendServerPath: '/tools/frontend_server.snapshot',
          config: NativeCompilerConfig(
            patchedSdkRoot: '/sdk-root',
            fileSystemRoots: ['/exec', '/exec/bazel-out/bin'],
            fileSystemScheme: 'org-dartlang-app',
          ),
          packageConfig: '/pkg.json',
          processFactory: (exe, args) async {
            capturedArgs = args;
            return FakeProcess();
          },
        );
        await s.start();

        // One --filesystem-root per root, plus a single --filesystem-scheme.
        expect(
          capturedArgs,
          containsAllInOrder(['--filesystem-root', '/exec']),
        );
        expect(
          capturedArgs,
          containsAllInOrder(['--filesystem-root', '/exec/bazel-out/bin']),
        );
        expect(capturedArgs, contains('--filesystem-scheme=org-dartlang-app'));
      },
    );

    test(
      'NativeCompilerConfig emits no multi-root flags without roots',
      () async {
        List<String>? capturedArgs;
        final s = FrontendServer(
          dartaotruntimePath: '/dart/bin/dartaotruntime',
          frontendServerPath: '/tools/frontend_server.snapshot',
          config: NativeCompilerConfig(patchedSdkRoot: '/sdk-root'),
          packageConfig: '/pkg.json',
          processFactory: (exe, args) async {
            capturedArgs = args;
            return FakeProcess();
          },
        );
        await s.start();

        expect(capturedArgs, isNot(contains('--filesystem-root')));
        expect(
          capturedArgs!.where((a) => a.startsWith('--filesystem-scheme')),
          isEmpty,
        );
      },
    );

    test('NativeCompilerConfig emits -D flags for dartDefines', () async {
      List<String>? capturedArgs;
      final s = FrontendServer(
        dartaotruntimePath: '/dart/bin/dartaotruntime',
        frontendServerPath: '/tools/frontend_server.snapshot',
        config: NativeCompilerConfig(
          patchedSdkRoot: '/sdk-root',
          dartDefines: ['A=1', 'B=x,y'],
        ),
        packageConfig: '/pkg.json',
        processFactory: (exe, args) async {
          capturedArgs = args;
          return FakeProcess();
        },
      );
      await s.start();

      // Launch-time flags persist for every later recompile — this is what
      // keeps String.fromEnvironment stable across hot reload/restart.
      expect(capturedArgs, contains('-DA=1'));
      expect(capturedArgs, contains('-DB=x,y'));
    });

    test('NativeCompilerConfig emits the registrant trio when set', () async {
      List<String>? capturedArgs;
      final s = FrontendServer(
        dartaotruntimePath: '/dart/bin/dartaotruntime',
        frontendServerPath: '/tools/frontend_server.snapshot',
        config: NativeCompilerConfig(
          patchedSdkRoot: '/sdk-root',
          dartPluginRegistrantUri:
              'file:///exec/bin/app_plugin_registrant.dart',
        ),
        packageConfig: '/pkg.json',
        processFactory: (exe, args) async {
          capturedArgs = args;
          return FakeProcess();
        },
      );
      await s.start();

      // The engine invokes _PluginRegistrant.register() (from the library
      // named by the -D) before main() on every isolate launch — including
      // hot restart of the dill this resident compiler produces.
      expect(
        capturedArgs,
        containsAllInOrder([
          '--source',
          'file:///exec/bin/app_plugin_registrant.dart',
          '--source',
          'package:flutter/src/dart_plugin_registrant.dart',
        ]),
      );
      expect(
        capturedArgs,
        contains(
          '-Dflutter.dart_plugin_registrant='
          'file:///exec/bin/app_plugin_registrant.dart',
        ),
      );
    });

    test('NativeCompilerConfig omits the registrant trio when unset', () async {
      List<String>? capturedArgs;
      final s = FrontendServer(
        dartaotruntimePath: '/dart/bin/dartaotruntime',
        frontendServerPath: '/tools/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/sdk-root'),
        packageConfig: '/pkg.json',
        processFactory: (exe, args) async {
          capturedArgs = args;
          return FakeProcess();
        },
      );
      await s.start();

      expect(capturedArgs, isNot(contains('--source')));
      expect(
        capturedArgs!.where(
          (a) => a.startsWith('-Dflutter.dart_plugin_registrant'),
        ),
        isEmpty,
      );
    });

    test('WebCompilerConfig emits -D flags for dartDefines', () async {
      List<String>? capturedArgs;
      final s = FrontendServer(
        dartaotruntimePath: '/dart/bin/dartaotruntime',
        frontendServerPath: '/tools/frontend_server.snapshot',
        config: WebCompilerConfig(
          webToolchain: WebToolchainPaths(
            ddcOutlineDill: '/web/ddc_outline.dill',
            librariesSpec: '/web/libraries.json',
            dartSdkJs: '/web/dart_sdk.js',
            ddcModuleLoaderJs: '/web/ddc_module_loader.js',
            stackTraceMapperJs: '/web/stack_trace_mapper.js',
            dartSdkRoot: '/web/dart-sdk',
          ),
          dartDefines: ['MSG=hello'],
        ),
        packageConfig: '/pkg.json',
        processFactory: (exe, args) async {
          capturedArgs = args;
          return FakeProcess();
        },
      );
      await s.start();

      expect(capturedArgs, contains('-DMSG=hello'));
    });

    test('compile sends "compile <entrypoint>" to stdin', () async {
      await server.start();
      final future = server.compile('lib/main.dart');

      // Simulate real frontend_server protocol: result <key>, then <key> <path> <errors>.
      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /tmp/out.dill 0');

      final result = await future;
      expect(
        fakeProcess.stdinBuffer.toString(),
        contains('compile lib/main.dart'),
      );
      expect(result.dillPath, '/tmp/out.dill');
      expect(result.success, isTrue);
    });

    test(
      'recompile sends recompile with boundary key + invalidated files',
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
      },
    );

    test('accept sends "accept" to stdin', () async {
      await server.start();
      await compileAwaitingVerdict();
      server.accept();
      expect(fakeProcess.stdinBuffer.toString(), contains('accept'));
    });

    test('reject sends "reject" to stdin', () async {
      await server.start();
      final first = server.recompile('lib/main.dart', const []);
      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 1');
      await first;

      final rejected = server.reject();
      fakeProcess.emitStdout('result reject_key');
      fakeProcess.emitStdout('reject_key');
      await rejected;
      expect(fakeProcess.stdinBuffer.toString(), contains('reject'));
    });

    test('a recompile after a rejected compile still completes', () async {
      // `reject` is the ONE command whose response the protocol sends and a
      // client is tempted not to read. Leaving its `result <key>` line stored
      // as the pending boundary key sets that key forever, so the NEXT
      // compile's result lines match nothing and its future never completes —
      // one failed reload hanging every command after it.
      await server.start();
      final first = server.recompile('lib/main.dart', const []);
      fakeProcess.emitStdout('result boundary_1');
      fakeProcess.emitStdout('boundary_1 /tmp/delta.dill 1');
      await first;

      final rejected = server.reject();
      fakeProcess.emitStdout('result reject_key');
      fakeProcess.emitStdout('reject_key');
      await rejected;

      final next = server.recompile('lib/main.dart', ['file:///lib/a.dart']);
      fakeProcess.emitStdout('result boundary_2');
      fakeProcess.emitStdout('boundary_2 /tmp/delta2.dill 0');

      final result = await next.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw StateError(
          'the compile after a reject never completed — the parser is still '
          'holding the reject response',
        ),
      );
      expect(result.success, isTrue);
      expect(result.dillPath, '/tmp/delta2.dill');
    });

    test('a second request waits its turn and gets its own answer', () async {
      // The protocol is one stream of `result <key>` / `<key> …` exchanges
      // with no request id in it, so two in flight at once hands one request
      // the other's answer. `CommandRunner`'s Pool(1) is not the only caller:
      // the debugger's expression compiles arrive on DWDS's own schedule.
      // Queued, both get the right dill.
      await server.start();
      final first = server.compile('lib/main.dart');
      final second = server.recompile('lib/main.dart', const []);

      var secondSettled = false;
      second.then((_) => secondSettled = true).ignore();
      await pumpEventQueue();
      expect(
        secondSettled,
        isFalse,
        reason: 'the queued request must not be answered before its turn',
      );

      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /tmp/first.dill 0');
      expect((await first).dillPath, '/tmp/first.dill');

      await pumpEventQueue();
      fakeProcess.emitStdout('result def');
      fakeProcess.emitStdout('def /tmp/second.dill 0');
      expect((await second).dillPath, '/tmp/second.dill');
    });

    test('the queued request is not even written until its turn', () async {
      // Queuing has to hold the bytes back, not merely the answer: two
      // requests interleaved on the compiler's stdin is the same corruption
      // seen from the writing end.
      await server.start();
      final first = server.compile('lib/main.dart');
      await pumpEventQueue();
      final writtenBefore = fakeProcess.stdinBuffer.toString();

      final second = server.recompile('lib/other.dart', const []);
      await pumpEventQueue();
      expect(
        fakeProcess.stdinBuffer.toString(),
        writtenBefore,
        reason: 'nothing of the second request may reach stdin yet',
      );

      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /tmp/first.dill 0');
      await first;
      await pumpEventQueue();
      expect(
        fakeProcess.stdinBuffer.toString(),
        contains('recompile lib/other.dart'),
      );

      fakeProcess.emitStdout('result def');
      fakeProcess.emitStdout('def /tmp/second.dill 0');
      await second;
    });

    group('compileExpressionToJs', () {
      /// The one line of JSON the compiler is sent, decoded.
      Map<String, dynamic> requestJson() {
        final lines = fakeProcess.stdinBuffer
            .toString()
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
        expect(
          lines.first,
          'JSON_INPUT',
          reason: 'the compiler takes a structured request this way',
        );
        return json.decode(lines[1]) as Map<String, dynamic>;
      }

      Future<CompileResult> compileExpression({String expression = 'a + b'}) {
        return server.compileExpressionToJs(
          libraryUri: 'package:app/main.dart',
          scriptUri: 'org-dartlang-app:/web_entrypoint.dart',
          line: 12,
          column: 4,
          jsModules: const {'dart': 'dart_sdk'},
          jsFrameValues: const {'x': '1'},
          moduleName: 'packages/app/main.dart',
          expression: expression,
        );
      }

      test('sends the request the frontend server understands', () async {
        await server.start();
        final pending = compileExpression();
        await pumpEventQueue();

        final request = requestJson();
        expect(request['type'], 'COMPILE_EXPRESSION_JS');
        expect(request['data'], {
          'expression': 'a + b',
          'libraryUri': 'package:app/main.dart',
          'scriptUri': 'org-dartlang-app:/web_entrypoint.dart',
          'line': 12,
          'column': 4,
          'jsModules': {'dart': 'dart_sdk'},
          'jsFrameValues': {'x': '1'},
          'moduleName': 'packages/app/main.dart',
        });

        fakeProcess.emitStdout('result exp1');
        fakeProcess.emitStdout('exp1 /tmp/expr.js 0');
        final result = await pending;
        expect(result.success, isTrue);
        expect(result.outputPath, '/tmp/expr.js');
      });

      test(
        'keeps the output path even when the fragment does not compile',
        () async {
          // The compiler writes the error into that same file, and it is what
          // the debugger shows in place of a value. `dillPath` cannot carry it:
          // every reload caller treats a path there as something to hand a
          // device.
          await server.start();
          final pending = compileExpression(expression: 'not valid dart');
          await pumpEventQueue();
          fakeProcess.emitStdout('result exp1');
          fakeProcess.emitStdout('exp1 /tmp/expr.js 1');

          final result = await pending;
          expect(result.success, isFalse);
          expect(result.errorCount, 1);
          expect(result.dillPath, isEmpty);
          expect(result.outputPath, '/tmp/expr.js');
        },
      );

      test('does not leave a verdict owing', () async {
        // No expression compile changes the program the compiler is holding,
        // so there is nothing to accept. Arming the verdict here would send
        // the server an `accept` it has no state to interpret, desynchronising
        // the stream.
        await server.start();
        final pending = compileExpression();
        await pumpEventQueue();
        fakeProcess.emitStdout('result exp1');
        fakeProcess.emitStdout('exp1 /tmp/expr.js 0');
        await pending;

        final before = fakeProcess.stdinBuffer.length;
        server.accept();
        expect(
          fakeProcess.stdinBuffer.length,
          before,
          reason: 'nothing was compiled, so nothing is accepted',
        );
      });

      test('cannot swallow a real compile\'s verdict', () async {
        // The sharp edge: an evaluation landing between a compile and its
        // accept. The verdict belongs to the compile and has to survive.
        await server.start();
        await compileAwaitingVerdict();

        final pending = compileExpression();
        await pumpEventQueue();
        fakeProcess.emitStdout('result exp1');
        fakeProcess.emitStdout('exp1 /tmp/expr.js 0');
        await pending;

        final before = fakeProcess.stdinBuffer.length;
        server.accept();
        expect(
          fakeProcess.stdinBuffer.toString().substring(before).trim(),
          'accept',
          reason: 'the compile still owes a verdict and still gets one',
        );
      });

      test(
        'queues behind an in-flight compile rather than racing it',
        () async {
          // DWDS calls this on its own schedule, with no knowledge of the
          // reload path. Two exchanges at once would hand one the other's
          // answer.
          await server.start();
          final compiling = server.compile('lib/main.dart');
          await pumpEventQueue();
          final beforeExpression = fakeProcess.stdinBuffer.toString();

          final evaluating = compileExpression();
          await pumpEventQueue();
          expect(
            fakeProcess.stdinBuffer.toString(),
            beforeExpression,
            reason: 'the evaluation must not interleave on stdin',
          );

          fakeProcess.emitStdout('result abc');
          fakeProcess.emitStdout('abc /tmp/out.dill 0');
          expect((await compiling).dillPath, '/tmp/out.dill');

          await pumpEventQueue();
          expect(fakeProcess.stdinBuffer.toString(), contains('JSON_INPUT'));
          fakeProcess.emitStdout('result exp1');
          fakeProcess.emitStdout('exp1 /tmp/expr.js 0');
          expect((await evaluating).outputPath, '/tmp/expr.js');
        },
      );

      test(
        'answers instead of hanging once the compiler is shutting down',
        () async {
          await server.start();
          final shuttingDown = await beginShutdown();

          final result = await compileExpression().timeout(
            const Duration(seconds: 5),
          );
          expect(result.success, isFalse);
          expect(result.diagnostics, contains('shutting down'));

          fakeProcess.complete(0);
          await shuttingDown;
        },
      );
    });

    test('a compiler that stops answering is terminated, and its late answer '
        'never reaches a later request', () async {
      // A timed-out request nulls the pending completer, but the compiler was
      // told nothing and may still answer. If it is left alive, that answer
      // lands on whatever completer exists by then — a silently wrong dill for
      // a compile the caller was told had failed.
      final s = FrontendServer(
        dartaotruntimePath: '/dart/bin/dartaotruntime',
        frontendServerPath: '/tools/frontend_server.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/sdk-root'),
        packageConfig: '/pkg.json',
        processFactory: (exe, args) async => fakeProcess,
        responseTimeout: const Duration(milliseconds: 50),
      );
      await s.start();

      final abandoned = await s.compile('lib/main.dart');
      expect(abandoned.success, isFalse);
      expect(abandoned.diagnostics, contains('did not answer'));
      expect(
        fakeProcess.killed,
        isTrue,
        reason: 'a compiler of unknown state must stop emitting',
      );

      // The late answer arrives. Nothing may pick it up.
      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /tmp/stale.dill 0');
      await pumpEventQueue();

      final later = await s.compile('lib/main.dart');
      expect(
        later.dillPath,
        isNot('/tmp/stale.dill'),
        reason: 'a superseded compile must never answer a later request',
      );
      expect(later.success, isFalse);
    });

    test('reject is not sent when no compile is awaiting a verdict', () async {
      // Writing an unowed verdict desynchronises the stream: the server has no
      // compile to reject, so whatever it answers belongs to nothing.
      await server.start();
      await server.reject();
      expect(fakeProcess.stdinBuffer.toString(), isNot(contains('reject')));
    });

    test('accept is not sent when no compile is awaiting a verdict', () async {
      await server.start();
      server.accept();
      expect(fakeProcess.stdinBuffer.toString(), isNot(contains('accept')));
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
        'lib/main.dart:10:5: Error: Expected \';\' after this.',
      );
      fakeProcess.emitStdout('result abc');
      fakeProcess.emitStdout('abc /tmp/out.dill 0');

      final result = await future;
      expect(result.diagnostics, contains("Error: Expected ';' after this."));
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
