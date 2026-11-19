import 'dart:io';

import 'package:flutter_bazel_dev_tool/child_processes.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

/// The exit code of a child [ChildProcesses.killAllNow] ended: SIGKILL's, or
/// on Windows the code `TerminateProcess` gives it.
final _killed = Platform.isWindows ? -1 : -9;

void main() {
  late List<LogRecord> records;

  setUp(() {
    records = [];
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord.listen(records.add);
    addTearDown(() {
      sub.cancel();
      Logger.root.level = previous;
    });
  });

  // `sleep` stands for any child that keeps running until it is stopped: a
  // DTD, an `adb logcat`. Windows has no `sleep`; a minute of `ping` waits as
  // long.
  Future<Process> startSleeper() async {
    final process = Platform.isWindows
        ? await startChildProcess('ping', ['-n', '61', '127.0.0.1'])
        : await startChildProcess('sleep', ['60']);
    // A failing test still must not leave it behind.
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    return process;
  }

  test('a child is recorded until it is killed', () async {
    final process = await startSleeper();
    expect(ChildProcesses.livePids, contains(process.pid));

    ChildProcesses.killAllNow();

    expect(await process.exitCode, _killed);
    expect(ChildProcesses.livePids, isNot(contains(process.pid)));
  });

  // The case above leaves the record through `killAllNow`, which drops each
  // child it kills itself. This one leaves it through the exit alone.
  test('a child that exits by itself leaves the record', () async {
    // `cat` runs until its input ends, so it is recorded while it runs, and
    // ends when this test says. Windows' `sort` does the same.
    final process = await startChildProcess(
      Platform.isWindows ? 'sort' : 'cat',
      [],
    );
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    expect(ChildProcesses.livePids, contains(process.pid));

    await process.stdin.close();
    // The record's own wait on the exit was registered first, so it has run
    // by the time this one returns.
    expect(await process.exitCode, 0);
    expect(ChildProcesses.livePids, isNot(contains(process.pid)));
  });

  test('a killing at exit names each child the teardown missed', () async {
    final process = await startSleeper();

    ChildProcesses.killAllNow(report: true);
    await process.exitCode;

    expect(
      records.map((r) => r.message),
      contains(
        allOf(
          contains('child_process_outlived_teardown'),
          contains('pid ${process.pid}'),
        ),
      ),
    );
  });

  test('a killing on a forced exit names nothing', () async {
    final process = await startSleeper();

    ChildProcesses.killAllNow();
    await process.exitCode;

    expect(records, isEmpty);
  });
}
