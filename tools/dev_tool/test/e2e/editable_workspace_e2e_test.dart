@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The contract in `editable_workspace.dart`, asserted rather than described.
///
/// This is the seam every mutating e2e test now sits on, so the properties it
/// promises are the ones a whole suite's isolation rests on: the copy builds,
/// the copy's build reads the copy's sources, and the source workspace is
/// never touched.
void main() {
  group('editableWorkspace', () {
    Future<ProcessResult> build(EditableWorkspace ws, String target) =>
        Process.run('bazel', [
          'build',
          target,
        ], workingDirectory: ws.root).timeout(const Duration(minutes: 10));

    test(
      'gives a copy that builds on its own',
      () async {
        final ws = await editableWorkspace('web_example');

        // Invariant 1: the source's `bazel-*` links point into an output base
        // keyed by the SOURCE path. Copying them would let the new workspace
        // read another build's tree.
        final copied = Directory(
          ws.root,
        ).listSync().map((e) => p.basename(e.path)).toList();
        expect(
          copied.where((n) => n.startsWith('bazel-')),
          isEmpty,
          reason: 'convenience symlinks belong to the source output base',
        );
        expect(copied, contains('MODULE.bazel'), reason: 'sources came across');

        // Invariant 2, and the one that fails first and least legibly without
        // the rewrite: the source resolves rules_flutter by `path = "../.."`.
        final config = ws.file('.bazelrc.user').readAsStringSync();
        expect(config, contains('--override_module=rules_flutter='));
        expect(
          config,
          contains(p.normalize(p.join(e2eWorkspace('web_example'), '../..'))),
          reason: 'the override has to name where the ruleset actually is',
        );

        // A target that actually compiles Dart. `:app_lib` gathers sources
        // without type-checking them, so a broken file builds clean through
        // it — useless as proof that the copy's sources are what got built.
        final built = await build(ws, ':app_js');
        expect(
          built.exitCode,
          0,
          reason:
              'a copy that cannot build is not a workspace: ${built.stderr}',
        );
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );

    test(
      'builds the copy\'s sources, and leaves the source alone',
      () async {
        final ws = await editableWorkspace('web_example');
        final source = File(
          p.join(e2eWorkspace('web_example'), 'lib/main.dart'),
        );
        final sourceBefore = source.readAsStringSync();

        expect((await build(ws, ':app_js')).exitCode, 0);

        // Break it in a way only a compiler can miss: if the build still passes,
        // it compiled something other than this file.
        ws
            .file('lib/main.dart')
            .writeAsStringSync(
              '${ws.file('lib/main.dart').readAsStringSync()}\n'
              'int COPY_ONLY_MARKER = "not an int";\n',
            );

        final broken = await build(ws, ':app_js');
        expect(
          broken.exitCode,
          isNot(0),
          reason: 'the copy\'s build must read the copy\'s sources',
        );
        expect(
          '${broken.stdout}${broken.stderr}',
          contains('COPY_ONLY_MARKER'),
        );

        // The payoff: no teardown restored anything, and the shared workspace
        // is byte-for-byte what it was.
        expect(
          source.readAsStringSync(),
          sourceBefore,
          reason: 'a mutating test must not be able to touch the source tree',
        );
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );

    test(
      'takes its output base with it',
      () async {
        // Deleting the copy destroys the only pointer back to its output
        // base: Bazel keys the base by workspace path and never collects one,
        // so a base left here is unreachable and permanent.
        String? outputBase;

        // Registered BEFORE the workspace exists, and therefore run AFTER its
        // teardown — `addTearDown` callbacks run in reverse order of
        // registration. Asserting from a callback registered later would read
        // the directory before the cleanup that is under test had run.
        addTearDown(() {
          expect(
            outputBase,
            isNotNull,
            reason:
                'the test must learn the output base before asserting on it',
          );
          expect(
            Directory(outputBase!).existsSync(),
            isFalse,
            reason: 'the copy\'s output base outlived the copy',
          );
        });

        final ws = await editableWorkspace('web_example');

        // Built, not merely configured. Bazel leaves build outputs in
        // read-only directories, and a recursive delete gives up on those
        // with `Permission denied` partway through — so a base with nothing
        // built in it would pass this test with the fix removed.
        expect((await build(ws, ':app_js')).exitCode, 0);

        final info = await Process.run('bazel', [
          'info',
          'output_base',
        ], workingDirectory: ws.root).timeout(const Duration(minutes: 2));
        expect(info.exitCode, 0, reason: 'no output base to assert on');
        final made = (info.stdout as String).trim();
        outputBase = made;
        expect(
          Directory(made).existsSync(),
          isTrue,
          reason: 'the build should have made one',
        );
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );
  });
}
