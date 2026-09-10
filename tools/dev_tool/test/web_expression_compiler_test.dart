/// The adapter between DWDS's expression evaluation and our resident
/// frontend server.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dwds/dwds.dart';
import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:flutter_bazel_dev_tool/web_expression_compiler.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  late FakeProcess fakeProcess;
  late FrontendServer server;
  late FrontendServerExpressionCompiler compiler;
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('web_expression_compiler_');
    addTearDown(() => dir.deleteSync(recursive: true));
    fakeProcess = FakeProcess();
    server = FrontendServer(
      dartaotruntimePath: '/fake/dartaotruntime',
      frontendServerPath: '/fake/frontend_server.snapshot',
      config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
      packageConfig: '/fake/package_config.json',
      processFactory: (exe, args) async => fakeProcess,
    );
    await server.start();
    compiler = FrontendServerExpressionCompiler(server);
  });

  /// Ask the way DWDS asks — positionally, in its own order.
  Future<ExpressionCompilationResult> evaluate({String expression = 'a + b'}) =>
      compiler.compileExpressionToJs(
        'isolates/1',
        'package:app/main.dart',
        'org-dartlang-app:/web_entrypoint.dart',
        3,
        7,
        const {'dart': 'dart_sdk'},
        const {'x': '1'},
        'packages/app/main.dart',
        expression,
      );

  /// Answer the in-flight request with [output] written to a real file.
  Future<void> answerWith(String output, {int errorCount = 0}) async {
    await pumpEventQueue();
    final file = File('${dir.path}/expr.js')..writeAsStringSync(output);
    fakeProcess.emitStdout('result exp1');
    fakeProcess.emitStdout('exp1 ${file.path} $errorCount');
  }

  test('hands DWDS the compiled JavaScript the compiler wrote', () async {
    // The compiler answers with a path, not a value — the JS is on disk, and
    // reading it is this adapter's job.
    final pending = evaluate();
    await answerWith('a + b');

    final result = await pending;
    expect(result.isError, isFalse);
    expect(result.result, 'a + b');
  });

  test(
    'passes DWDS\'s positional arguments through in the right places',
    () async {
      // Nine positional arguments, three of them ints and two of them maps: a
      // transposition here compiles fine and evaluates the wrong expression in
      // the wrong scope.
      final pending = evaluate(expression: 'widget.title');
      await pumpEventQueue();
      final line = fakeProcess.stdinBuffer
          .toString()
          .split('\n')
          .firstWhere((l) => l.startsWith('{'));
      expect(json.decode(line)['data'], {
        'expression': 'widget.title',
        'libraryUri': 'package:app/main.dart',
        'scriptUri': 'org-dartlang-app:/web_entrypoint.dart',
        'line': 3,
        'column': 7,
        'jsModules': {'dart': 'dart_sdk'},
        'jsFrameValues': {'x': '1'},
        'moduleName': 'packages/app/main.dart',
      });

      await answerWith('x');
      await pending;
    },
  );

  test(
    'a fragment that does not compile is an error carrying the message',
    () async {
      // The compiler writes the diagnostic into the same output file, and it is
      // what the debugger shows in place of a value. Reporting an empty success
      // instead would put a blank where the reason should be.
      final pending = evaluate(expression: 'not valid dart');
      await answerWith("Error: Expected ';' after this.", errorCount: 1);

      final result = await pending;
      expect(result.isError, isTrue);
      expect(result.result, contains("Expected ';'"));
    },
  );

  test('an output file that is not there is reported, not thrown', () async {
    // The compiler named a file it did not write. A raw FileSystemException
    // out of a debugger evaluation names nothing a user can act on.
    final pending = evaluate();
    await pumpEventQueue();
    fakeProcess.emitStdout('result exp1');
    fakeProcess.emitStdout('exp1 ${dir.path}/never-written.js 0');

    final result = await pending;
    expect(result.isError, isTrue);
    expect(result.result, contains('never-written.js'));
  });

  test('a compiler that is gone is an error naming the expression', () async {
    // Distinct from "compiled, with errors": there is no file at all.
    final shuttingDown = server.shutdown();
    await pumpEventQueue();

    final result = await evaluate(expression: 'a + b');
    expect(result.isError, isTrue);
    expect(result.result, contains('a + b'));
    expect(result.result, contains('shutting down'));

    fakeProcess.complete(0);
    await shuttingDown;
  });

  test('reports nothing to update', () async {
    // The resident compiler already holds the program's state and updates it
    // on every recompile, so there are no module summaries for this adapter
    // to load. `false` here would make DWDS treat every evaluation as
    // unprepared. Upstream answers the same constant.
    //
    // `initialize` is the other half of the same story and is not exercised
    // here: its argument type (`ModuleFormat`) is not exported from
    // `package:dwds`, so a test cannot construct one without reaching into
    // the package's `src/`. The analyzer holds the signature.
    expect(await compiler.updateDependencies(const {}), isTrue);
  });
}
