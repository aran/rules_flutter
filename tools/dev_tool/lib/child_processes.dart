/// The processes this tool has started and not yet seen end, so that none of
/// them outlives it.
///
/// A child does not die with its parent. `dart tooling-daemon`, `adb logcat`,
/// a desktop app, a frontend server: each keeps running, reparented to
/// launchd or init, when the tool that started it exits without stopping it.
/// The run's [Teardown] is what stops them in the ordinary way, but some
/// exits never reach it, or reach it before a child it would stop exists:
///
///  * an error nothing caught, which ends the VM;
///  * a second signal, which asks for an exit without waiting for teardown;
///  * a teardown that ran while a spawn was still in flight (a DTD that has
///    not yet said where it listens, say), and the command then returning.
///
/// Every long-lived child is started through [startChildProcess], which
/// records it until it exits, and every way out of the tool calls
/// [ChildProcesses.killAllNow] last. Short `Process.run` calls are not
/// recorded: the tool awaits them, so they end before it can.
///
/// What this cannot cover is the tool itself being killed with SIGKILL: no
/// code runs then, and macOS has no signal that tells a child its parent died.
library;

import 'dart:io';

import 'package:logging/logging.dart';

final _logger = Logger('dev_tool.child_processes');

/// [Process.start], recording the child until it exits.
///
/// Same signature as [Process.start], so it stands in for it wherever a
/// spawn is injected. A detached child is not recorded: detaching is a request
/// for it to outlive this process.
Future<Process> startChildProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
  bool runInShell = false,
  ProcessStartMode mode = ProcessStartMode.normal,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: runInShell,
    mode: mode,
  );
  if (mode == ProcessStartMode.normal ||
      mode == ProcessStartMode.inheritStdio) {
    ChildProcesses.add(process, executable);
  }
  return process;
}

/// The record [startChildProcess] keeps.
abstract final class ChildProcesses {
  static final Map<Process, _Child> _live = {};

  /// Record [process], started from [executable], until it exits.
  ///
  /// [group] says [process] leads a process group of its own (see
  /// `process_group.dart`), so that ending it ends the group.
  static void add(Process process, String executable, {bool group = false}) {
    _live[process] = _Child(executable, group: group);
    process.exitCode.then((_) => _live.remove(process));
  }

  /// The pids of the children still running, for a test or a report.
  static List<int> get livePids => [for (final p in _live.keys) p.pid];

  /// SIGKILL every child still running, without waiting for any of them.
  ///
  /// For the moment the tool is about to exit. Each one left is named in a
  /// warning when [report] is set: on an ordinary exit the teardown should
  /// already have stopped it, so one still here is a teardown that missed
  /// something. On a crash or a forced exit, children still running are
  /// expected, and the exit itself has already been reported.
  static void killAllNow({bool report = false}) {
    for (final MapEntry(key: process, value: child) in _live.entries.toList()) {
      if (report) {
        _logger.warning({
          'message': 'child_process_outlived_teardown',
          'text':
              '${child.executable} (pid ${process.pid}) was still running '
              'as the tool exited, after everything it started should have '
              'been stopped. Killed it.',
          'executable': child.executable,
          'pid': process.pid,
        });
      }
      // SIGKILL because nothing will be left to escalate if a softer signal
      // is ignored. The result is not read: false is a child that has just
      // exited, which is what is wanted.
      Process.killPid(
        child.group ? -process.pid : process.pid,
        ProcessSignal.sigkill,
      );
      _live.remove(process);
    }
  }
}

class _Child {
  final String executable;
  final bool group;

  _Child(this.executable, {required this.group});
}
