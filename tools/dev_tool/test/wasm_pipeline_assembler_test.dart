/// [WasmPipelineAssembler] — the two commands a `--wasm` run answers.
///
/// dart2wasm has no incremental compiler, so `app.hotReload` is not
/// implementable here. The refusal has to carry an `error`: a client deciding
/// success by the absence of that key reads a bare `message` as a hot reload
/// that worked.
///
/// [_noWorkspace] is what makes a restart assertable without bazel:
/// `Process.start` refuses a working directory that does not exist, so the
/// rebuild throws and the strategy's own verdict on the throw is what the
/// reply has to carry.
library;

import 'package:flutter_bazel_dev_tool/logging.dart';
import 'package:flutter_bazel_dev_tool/reload_pipeline.dart';
import 'package:flutter_bazel_dev_tool/session_host.dart';
import 'package:flutter_bazel_dev_tool/web_pipeline_assembler.dart';
import 'package:test/test.dart';

/// A directory no bazel invocation can run in.
const _noWorkspace = '/nonexistent/rules_flutter/wasm_assembler_test_workspace';

/// What the pipeline-backed handlers answer in this test, so an assertion can
/// tell "the WASM handler replied" from "the one it was supposed to replace
/// did". Nothing in the production sentence contains it.
const _pipelineSentinel = 'PIPELINE-HANDLER-ANSWERED';

void main() {
  late SessionHost host;
  late ReloadPipeline pipeline;

  setUp(() {
    host = SessionHost(isMachine: false, logger: Logger('test.wasm_assembler'));
    pipeline = ReloadPipeline(host: host);
  });

  /// Assemble a WASM run whose browser announced [cdpPort].
  void assemble({int? cdpPort = 9222}) => WasmPipelineAssembler(
    cdpPort: cdpPort,
    appUrl: 'http://localhost:8080',
    target: '//:app_wasm',
    workspace: _noWorkspace,
    compilationMode: 'dbg',
    extraArgs: const [],
    host: host,
    pipeline: pipeline,
    logger: Logger('test.wasm_assembler'),
  ).assemble();

  /// Register the handlers this assembly is supposed to shadow, exactly as the
  /// run does — and settle their gate, so a failure to shadow answers instead
  /// of blocking the test for the gate's ninety seconds.
  void registerPipelineHandlers() {
    host.registerReloadCommands(pipeline);
    pipeline.ready.signalUnavailable(_pipelineSentinel);
  }

  group('hot reload', () {
    test('is refused, and the refusal is legible as a failure', () async {
      assemble();

      final reply = await host.commandRunner.run('app.hotReload', {});

      // `error` is what a client reads, and its absence reads as success;
      // `succeeded` says the same thing outright so the two cannot drift;
      // `runningCode` is provable here rather than asserted, because the
      // refusal stops before a compiler or a browser is touched.
      expect(reply['succeeded'], isFalse);
      expect(reply['error'], contains('not supported in WASM'));
      expect(reply['runningCode'], 'unchanged');
    });

    test(
      'replaces the pipeline-backed handler rather than sitting behind it',
      () async {
        registerPipelineHandlers();
        assemble();

        final reply = await host.commandRunner.run('app.hotReload', {});

        // Load-bearing for every route in, not just a machine client: a keypress
        // and the file watcher both dispatch through `commandRunner.run`.
        expect(
          reply['error'],
          isNot(contains(_pipelineSentinel)),
          reason: 'the WASM refusal must be the registration that answers',
        );
        expect(reply['error'], contains('use restart'));
      },
    );
  });

  group('restart', () {
    test('answers with the strategy\'s own verdict on the reload', () async {
      assemble();

      final reply = await host.commandRunner.run('app.restart', {});

      // Not a refusal and not a hand-built map: the rebuild is attempted and
      // falls over, and what the reply carries is what the strategy says about
      // it. A handler deciding the verdict itself can leave an arm of this pair
      // without an `error` at all.
      expect(reply['succeeded'], isFalse);
      expect(reply['error'], contains('WASM hot restart failed'));
      expect(reply['message'], contains('Restart failed'));
      expect(reply['elapsedMs'], isA<int>());
    });

    test(
      'replaces the pipeline-backed handler rather than sitting behind it',
      () async {
        registerPipelineHandlers();
        assemble();

        final reply = await host.commandRunner.run('app.restart', {});

        expect(reply['error'], isNot(contains(_pipelineSentinel)));
        expect(reply['error'], contains('WASM hot restart failed'));
      },
    );
  });

  group('with no CDP port', () {
    test('registers nothing, so the run\'s own gate answers', () async {
      registerPipelineHandlers();
      assemble(cdpPort: null);

      // Both commands still exist — they are the pipeline's — and both say
      // what the run said about itself. There is no page to reload without a
      // port, so offering a restart that cannot happen would be the failure.
      expect(
        await host.commandRunner.run('app.hotReload', {}),
        containsPair('error', _pipelineSentinel),
      );
      expect(
        await host.commandRunner.run('app.restart', {}),
        containsPair('error', _pipelineSentinel),
      );
    });

    test('leaves the pipeline without a strategy', () async {
      assemble(cdpPort: null);

      expect(pipeline.strategy, isNull);
      expect(
        host.commandRunner.hasCommand('app.hotReload'),
        isFalse,
        reason: 'nothing was registered at all',
      );
    });
  });
}
