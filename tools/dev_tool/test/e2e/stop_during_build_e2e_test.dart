/// Stopping the dev tool while its bazel build is running stops the build.
///
/// The case this guards was measured before the fix: the tool exited on a
/// SIGINT in 11ms, and the build it had started ran on for five more seconds
/// to "Processing and signing app", while a `bazel` command issued meanwhile
/// printed `Another command (pid=…) is running` and waited behind it. bazelisk
/// ignores signals sent to its own pid, so nothing the tool held could reach
/// the build — only a signal to the command's process group does.
///
/// Every case forces a real build with a `--dart-define` no earlier run used,
/// so the kernel compile is still ahead when bazel reports its analysis done,
/// and each stops the run right then. What each then asks of the workspace is
/// the user's question — can I run bazel again now? — and it is asked with
/// `--noblock_for_lock`, which answers at once rather than waiting behind a
/// build that is still going.
@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('macos_example');

  /// A define no previous build has seen, so the build cannot be a cache hit.
  String unseenDefine() =>
      '--dart-define=STOP_DURING_BUILD=${DateTime.now().microsecondsSinceEpoch}';

  /// Whether bazel in [workspace] is free right now, and what it said if not.
  Future<({bool free, String said})> bazelIsFree() async {
    final result = await Process.run('bazel', [
      '--noblock_for_lock',
      'info',
      'server_pid',
    ], workingDirectory: workspace);
    return (
      free: result.exitCode == 0,
      said: '${result.stdout}${result.stderr}',
    );
  }

  /// The JSON log records in [lines] with `message` [name].
  List<Map<String, dynamic>> records(List<String> lines, String name) => [
    for (final line in lines)
      if (line.startsWith('{'))
        if (json.decode(line) case final Map<String, dynamic> record
            when record['message'] == name)
          record,
  ];

  /// Whether anything is still running in process group [pgid].
  Future<bool> groupAlive(int pgid) async =>
      (await Process.run('pgrep', ['-g', '$pgid'])).exitCode == 0;

  /// What every case asserts once the tool has exited: bazel was asked to
  /// stop, nothing of the command survived, and the workspace is free.
  Future<void> expectBuildStopped(List<String> stderrLines) async {
    final interrupted = records(stderrLines, 'bazel_interrupted');
    expect(
      interrupted,
      hasLength(1),
      reason:
          'the build has to have been running when the run was stopped, or '
          'this case proves nothing about stopping one',
    );
    expect(
      stderrLines.join('\n'),
      contains('Bazel caught terminate signal'),
      reason:
          "bazel's own word that the signal reached the real client, rather "
          'than the build finishing on its own inside the wait',
    );
    expect(
      await groupAlive(interrupted.single['pid'] as int),
      isFalse,
      reason: "the tool exits only once the bazel command's group is gone",
    );
    final check = await bazelIsFree();
    expect(
      check.free,
      isTrue,
      reason:
          'the build must not be holding the output base after the tool has '
          'exited:\n${check.said}',
    );
    expect(
      records(stderrLines, 'command_failed'),
      isEmpty,
      reason: 'a stopped build is not a failed one',
    );
  }

  group('Stopping during the launch build', () {
    for (final (name, signal, code) in [
      ('SIGTERM', ProcessSignal.sigterm, 143),
      ('SIGINT', ProcessSignal.sigint, 130),
    ]) {
      test('$name to the tool alone stops the build, and the run exits '
          '$code', () async {
        final dt = await startDevTool(
          workspace: workspace,
          target: ':app',
          device: 'macos',
          extraArgs: [unseenDefine()],
        );
        await dt.waitForStderr('Analyzed target');

        // `Process.kill` signals the tool's pid and nothing else — what an
        // IDE's stop button, a supervisor or `kill` does. A terminal's Ctrl-C
        // would also reach anything still in the tool's process group, which
        // is exactly the help this case must not get.
        dt.process.kill(signal);

        expect(
          await dt.process.exitCode.timeout(const Duration(seconds: 60)),
          code,
        );
        expect(
          dt.events.where((e) => e['event'] == 'app.started'),
          isEmpty,
        );
        await expectBuildStopped(dt.stderrLines);
      });
    }

    // The same stop, asked for by a machine client. No signal is involved at
    // all, so nothing but the tool's own teardown can reach the build.
    test('daemon.shutdown stops the build, answers, and exits 0', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app',
        device: 'macos',
        extraArgs: [unseenDefine()],
      );
      await dt.waitForStderr('Analyzed target');

      final reply = await dt.sendCommand(1, 'daemon.shutdown');

      expect(reply['result']?['message'], 'shutdown');
      expect(
        await dt.process.exitCode.timeout(const Duration(seconds: 60)),
        0,
      );
      await expectBuildStopped(dt.stderrLines);
    });
  }, skip: !Platform.isMacOS ? 'macOS only' : null);

  group('Stopping flutter_bazel build', () {
    test(
      'SIGINT to the tool alone stops the build, and it exits 130',
      () async {
        final stderrLines = <String>[];
        final analyzed = Completer<void>();
        final tool = await spawnBoundToTest(
          spawn: () async => Process.start(
            await ensureBuiltDevTool(),
            ['build', '-t', ':app', '-c', 'dbg', unseenDefine()],
            workingDirectory: workspace,
            environment: {...Platform.environment, 'LOG_FORMAT': 'json'},
          ),
          dispose: (process) async {
            process.kill(ProcessSignal.sigkill);
            await process.exitCode;
          },
        );
        unawaited(tool.stdout.drain<void>());
        final stderrDone = tool.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach((line) {
              stderrLines.add(line);
              if (line.contains('Analyzed target') && !analyzed.isCompleted) {
                analyzed.complete();
              }
            });
        await Future.any([
          analyzed.future,
          tool.exitCode.then<void>(
            (code) => fail(
              'flutter_bazel build exited ($code) before bazel finished '
              'analysis:\n${stderrLines.join('\n')}',
            ),
          ),
        ]).timeout(const Duration(seconds: 120));

        tool.kill(ProcessSignal.sigint);

        expect(await tool.exitCode.timeout(const Duration(seconds: 60)), 130);
        await stderrDone;
        await expectBuildStopped(stderrLines);
      },
    );
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}
