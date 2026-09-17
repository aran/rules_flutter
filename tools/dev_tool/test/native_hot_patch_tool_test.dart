import 'dart:io';

import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/native_hot_patch_tool.dart';
import 'package:test/test.dart';

void main() {
  group('manifest', () {
    const valid = '''
{
  "version": 1,
  "library": "bazel-out/arm64-dbg/bin/libadd.so",
  "sources": ["native/add.c", "native/add.h"],
  "command": ["bazel-out/host/bin/patcher", "--crate", "add"]
}''';

    test('reads every field', () {
      final m = NativeHotPatchManifest.parse('m.hot_patch.json', valid);
      expect(m.library, 'bazel-out/arm64-dbg/bin/libadd.so');
      expect(m.sources, ['native/add.c', 'native/add.h']);
      expect(m.command, ['bazel-out/host/bin/patcher', '--crate', 'add']);
    });

    // A manifest is read at launch; a mistake in one stops that, naming the
    // file and the field, instead of surfacing on some later reload.
    for (final (what, text, says) in [
      ('not JSON', '{', 'is not JSON'),
      ('not an object', '[]', 'is not a JSON object'),
      (
        'another version',
        valid.replaceFirst('"version": 1', '"version": 2'),
        'declares version 2, and this dev tool reads version 1',
      ),
      (
        'no library',
        valid.replaceFirst('"library"', '"lib"'),
        'has no `library` path',
      ),
      (
        'empty sources',
        valid.replaceFirst('["native/add.c", "native/add.h"]', '[]'),
        'has an empty `sources`',
      ),
      (
        'a command that is not strings',
        valid.replaceFirst('"--crate"', '7'),
        'has a `command` that is not a list of non-empty strings',
      ),
    ]) {
      test('refuses $what', () {
        expect(
          () => NativeHotPatchManifest.parse('/w/m.hot_patch.json', text),
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('/w/m.hot_patch.json $says'),
                contains('hot_patch'),
              ),
            ),
          ),
        );
      });
    }
  });

  group('tool', () {
    const manifest = NativeHotPatchManifest(
      path: 'm.hot_patch.json',
      library: 'bazel-out/bin/libadd.so',
      sources: ['add.c'],
      command: ['bazel-out/host/bin/patcher', '--crate', 'add'],
    );

    ({NativePatchTool tool, List<(String, List<String>, String)> calls})
    toolAnswering(
      int exitCode,
      String stdout, {
      String stderr = '',
    }) {
      final calls = <(String, List<String>, String)>[];
      final tool = NativePatchTool(
        manifest: manifest,
        executionRoot: '/exec/root',
        run: (exe, args, {required workingDirectory}) async {
          calls.add((exe, args, workingDirectory));
          return ProcessResult(1, exitCode, stdout, stderr);
        },
      );
      return (tool: tool, calls: calls);
    }

    ({NativePatchTool tool, List<(String, List<String>, String)> calls})
    toolAnsweringEach(Map<String, String> stdoutByCommand) {
      final calls = <(String, List<String>, String)>[];
      final tool = NativePatchTool(
        manifest: manifest,
        executionRoot: '/exec/root',
        run: (exe, args, {required workingDirectory}) async {
          calls.add((exe, args, workingDirectory));
          final command = args.firstWhere(stdoutByCommand.containsKey);
          return ProcessResult(1, 0, stdoutByCommand[command], '');
        },
      );
      return (tool: tool, calls: calls);
    }

    Future<PatchBuilderAnswer> patchWith(
      int exitCode,
      String stdout, {
      String stderr = '',
    }) => toolAnswering(exitCode, stdout, stderr: stderr).tool.patch(
      stateDirectory: '/state',
      applyAddress: 0x10a0,
      outputDirectory: '/out',
    );

    test('runs the manifest command from the execution root', () async {
      final t = toolAnsweringEach({
        'snapshot': '{"status":"ok"}\n',
        'patch': '{"status":"unchanged"}\n',
      });
      await t.tool.snapshot('/state');
      await t.tool.patch(
        stateDirectory: '/state',
        applyAddress: 0x7ff00010a0,
        outputDirectory: '/out',
      );
      // Records compare their lists by identity, so the calls are compared as
      // the command lines they are.
      expect(
        [
          for (final (exe, args, cwd) in t.calls)
            '$cwd: $exe ${args.join(' ')}',
        ],
        [
          '/exec/root: bazel-out/host/bin/patcher --crate add snapshot --state /state',
          '/exec/root: bazel-out/host/bin/patcher --crate add patch --state /state '
              '--symbol flutter_hot_patch_apply=0x7ff00010a0 --out /out',
        ],
      );
    });

    test('a snapshot answers ok', () async {
      await toolAnswering(0, '{"status":"ok"}\n').tool.snapshot('/state');
    });

    test('a snapshot that fails stops the launch with the builder\'s own '
        'sentence', () async {
      final t = toolAnswering(
        1,
        '{"status":"failed","message":"test_api was built with debuginfo=0"}',
        stderr: 'noise',
      );
      await expectLater(
        t.tool.snapshot('/state'),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('need a hot restart'),
              contains('test_api was built with debuginfo=0'),
              isNot(contains('noise')),
            ),
          ),
        ),
      );
    });

    test('a snapshot with no status quotes what the builder printed', () async {
      for (final (exit, out) in [(3, ''), (0, 'done')]) {
        await expectLater(
          toolAnswering(exit, out, stderr: 'no IR for crate add').tool.snapshot(
            '/state',
          ),
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              contains('no IR for crate add'),
            ),
          ),
        );
      }
    });

    test('reads each status from the last line', () async {
      expect(
        await patchWith(0, 'building...\n{"status":"unchanged"}\n'),
        isA<PatchUnchanged>(),
      );
      expect(
        await patchWith(
          0,
          '{"status":"patched","file":"/out/p1.so","functions":["add::add"]}',
        ),
        isA<PatchBuilt>().having((r) => r.file, 'file', '/out/p1.so').having(
          (r) => r.functions,
          'functions',
          ['add::add'],
        ),
      );
      expect(
        await patchWith(
          0,
          '{"status":"restart","reasons":["`add::Point` changed layout"]}',
        ),
        isA<PatchNeedsRestart>().having(
          (r) => r.reasons,
          'reasons',
          ['`add::Point` changed layout'],
        ),
      );
    });

    test('a failed status is the builder\'s own message, whatever the exit '
        'code', () async {
      expect(
        await patchWith(1, '{"status":"failed","message":"error[E0308]"}'),
        isA<PatchFailed>().having(
          (r) => r.message,
          'message',
          'error[E0308]',
        ),
      );
    });

    // A patch the builder claimed while exiting non-zero is not one to load:
    // the exit code is the builder saying something went wrong after it wrote
    // the line.
    test('anything else is a failure carrying what it printed', () async {
      for (final (exit, out, err, says) in [
        (0, '', 'segfault', 'answered with no status'),
        (0, 'not json', '', 'answered with no status'),
        (0, '{"status":"patched"}', '', 'answered with no status'),
        (0, '{"status":"restart","reasons":[]}', '', 'answered with no status'),
        (
          2,
          '{"status":"patched","file":"/p","functions":[]}',
          'oops',
          'exited 2',
        ),
      ]) {
        final result = await patchWith(exit, out, stderr: err);
        expect(
          result,
          isA<PatchFailed>().having(
            (r) => r.message,
            'message',
            allOf(contains('bazel-out/bin/libadd.so $says'), contains(err)),
          ),
          reason: 'stdout "$out", exit $exit',
        );
      }
    });

    test('a builder that cannot start is a failure, not a throw', () async {
      final tool = NativePatchTool(
        manifest: manifest,
        executionRoot: '/exec/root',
        run: (exe, args, {required workingDirectory}) =>
            throw const ProcessException('patcher', [], 'No such file'),
      );
      expect(
        await tool.patch(
          stateDirectory: '/s',
          applyAddress: 1,
          outputDirectory: '/o',
        ),
        isA<PatchFailed>().having(
          (r) => r.message,
          'message',
          contains('could not be started: No such file'),
        ),
      );
    });
  });
}
