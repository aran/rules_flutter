/// Starting a program in a process group of its own, and signalling that group.
///
/// A signal to a process reaches that process alone. What it started lives on,
/// and keeps whatever it inherited: a Bazel client behind bazelisk keeps the
/// output base's lock, a `flutter_tester` behind its `flutter_test` runner
/// keeps the runner's stdout and stderr. A signal to the process's group
/// reaches all of them. `dart:io` cannot start a child in a group of its own,
/// so the child is started through `process_group_exec`, which makes the group
/// and then becomes the program (see `bin/process_group_exec.dart`): the pid
/// this process holds is the program's and the group's id.
///
/// POSIX only: Windows has no process group a console process can be moved
/// into this way.
library;

import 'dart:io';

import 'dev_tool_exception.dart';
import 'runfiles_helper.dart';

const _processGroupExecKey = 'rules_flutter/tools/dev_tool/process_group_exec';

/// Where `process_group_exec` is, once asked for.
String? _processGroupExec;

/// Starts [executable] with [arguments] as the leader of a new process group.
///
/// [binary] is the label of the program doing the starting, whose runfiles
/// must hold `process_group_exec`, for the message when they do not. The other
/// arguments are [Process.start]'s.
Future<Process> startInProcessGroup(
  String executable,
  List<String> arguments, {
  required String binary,
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) {
  final exec = _processGroupExec ??= _resolveProcessGroupExec(binary);
  return Process.start(
    exec,
    [executable, ...arguments],
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
}

String _resolveProcessGroupExec(String binary) {
  final path = resolveRunfile(_processGroupExecKey);
  if (path == null) {
    final name = binary.substring(binary.lastIndexOf(':') + 1);
    throw DevToolException(
      '$name starts processes through the process_group_exec it bundles '
      '($_processGroupExecKey), and its runfiles do not have it. The build '
      'that produced this $name dropped a declared data dependency; rebuild '
      'it with `bazel build $binary`.',
    );
  }
  return path;
}

/// Sends [signal] to the whole process group [process] leads, as started by
/// [startInProcessGroup].
///
/// The result is not read: `false` means the group has already gone, which is
/// what a caller stopping it wants, and its wait for the exit sees it.
void signalProcessGroup(Process process, ProcessSignal signal) =>
    Process.killPid(-process.pid, signal);
