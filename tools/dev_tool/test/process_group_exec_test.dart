/// What `process_group_exec` has to guarantee for a `bazel` command to be
/// stoppable.
///
/// A `bazel` on `PATH` is usually bazelisk, which runs the real Bazel client as
/// a child and ignores SIGINT and SIGTERM instead of passing them on — it
/// relies on a terminal signalling the whole process group. Measured against
/// bazelisk 1.27: a SIGTERM to its pid alone left the build running to
/// completion, holding the output base's lock. The fixture below reproduces
/// that shape with two shells, so the guarantee is checked without a Bazel.
///
/// Tagged `runfiles`: the helper is a `data` dependency, so these need the
/// Bazel runfiles tree.
@TestOn('!windows')
@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:test/test.dart';

const _helperKey = 'rules_flutter/tools/dev_tool/process_group_exec';

String _helper() {
  final path = resolveRunfile(_helperKey);
  if (path == null) {
    throw StateError(
      'Could not resolve $_helperKey from runfiles. Run this with '
      '`bazel test //tools/dev_tool:process_group_exec_test`.',
    );
  }
  return path;
}

/// Everything a finished process said, and how it ended.
typedef _Finished = ({int exitCode, String stdout, String stderr});

Future<_Finished> _finish(Process process) async {
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  return (
    exitCode: await process.exitCode,
    stdout: await out,
    stderr: await err,
  );
}

Future<String> _pgidOf(int pid) async {
  final ps = await Process.run('ps', ['-o', 'pgid=', '-p', '$pid']);
  return (ps.stdout as String).trim();
}

void main() {
  test(
    'runs the program as the leader of a process group of its own',
    () async {
      final process = await Process.start(_helper(), [
        '/bin/sh',
        '-c',
        // Blocks on stdin, so the group can be read while the program is alive.
        r'echo $$; read _',
      ]);
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final reportedPid = await lines.first;

      final groupOfProgram = await _pgidOf(process.pid);
      final groupOfTest = await _pgidOf(pid);
      await process.stdin.close();
      await process.exitCode;

      expect(
        reportedPid,
        '${process.pid}',
        reason:
            'the program replaces the helper, so the pid the caller holds is '
            "the program's own",
      );
      expect(groupOfProgram, '${process.pid}');
      expect(groupOfProgram, isNot(groupOfTest));
    },
  );

  // The bazelisk shape: a parent that catches SIGTERM and does nothing with
  // it, and the child doing the actual work. Signalling the parent's pid alone
  // leaves the child running; signalling the group reaches it.
  test('one signal to the group reaches a child its parent does not '
      'forward to', () async {
    final dir = await Directory.systemTemp.createTemp('process_group_exec');
    addTearDown(() => dir.delete(recursive: true));
    final parent = File('${dir.path}/parent.sh')
      ..writeAsStringSync(r'''
trap 'echo parent got TERM' TERM
sh -c 'trap "echo child got TERM; exit 3" TERM; echo ready; sleep 1000 & wait' &
child=$!
wait "$child"
status=$?
# A caught signal interrupts `wait`; the child's own status comes after.
while kill -0 "$child" 2>/dev/null; do wait "$child"; status=$?; done
exit "$status"
''');
    final process = await Process.start(_helper(), ['/bin/sh', parent.path]);
    final stdoutLines = StreamController<String>.broadcast();
    final collected = <String>[];
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          collected.add(line);
          stdoutLines.add(line);
        });
    await stdoutLines.stream.firstWhere((line) => line == 'ready');

    // First the parent alone, which is all a `Process.kill` reaches. Waiting
    // for the parent to say it took the signal is what makes the check below
    // mean something: the child was never sent one, so there is nothing still
    // in flight that could stop it later.
    Process.killPid(process.pid, ProcessSignal.sigterm);
    await stdoutLines.stream.firstWhere((line) => line == 'parent got TERM');
    expect(
      collected,
      isNot(contains('child got TERM')),
      reason:
          'the fixture has to ignore a signal the way bazelisk does, or '
          'the group signal below proves nothing',
    );

    expect(Process.killPid(-process.pid, ProcessSignal.sigterm), isTrue);

    expect(await process.exitCode, 3);
    expect(collected, contains('child got TERM'));
  });

  test("the program's exit status is the caller's", () async {
    final process = await Process.start(_helper(), ['/bin/sh', '-c', 'exit 7']);

    expect((await _finish(process)).exitCode, 7);
  });

  test("the program's output reaches the caller's pipes", () async {
    final process = await Process.start(_helper(), [
      '/bin/sh',
      '-c',
      'echo to-stdout; echo to-stderr >&2',
    ]);

    final finished = await _finish(process);
    expect(finished.stdout, 'to-stdout\n');
    expect(finished.stderr, 'to-stderr\n');
  });

  // Starting `bazel` through the helper turns "bazel is not installed" from a
  // ProcessException into an exit status, so the status and the words have to
  // say so on their own.
  test('a program that cannot be started is named, with the reason', () async {
    final process = await Process.start(_helper(), ['/nonexistent/bazel']);

    final finished = await _finish(process);
    expect(finished.exitCode, 127, reason: "the shell's `not found` status");
    expect(finished.stderr, contains('/nonexistent/bazel'));
    expect(finished.stderr, contains('No such file or directory'));
  });

  test('refuses to run with no program', () async {
    final process = await Process.start(_helper(), []);

    final finished = await _finish(process);
    expect(finished.exitCode, 64);
    expect(finished.stderr, contains('usage'));
  });
}
