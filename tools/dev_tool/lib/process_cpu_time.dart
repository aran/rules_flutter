/// How much CPU a running process has used so far.
///
/// The question a watchdog needs answered to tell a slow subprocess from a
/// stuck one. Wall time cannot: on a machine at load average 800 a compile that
/// takes 13s idle takes many minutes, and is working the whole time. CPU time
/// keeps advancing while it works and stops when it waits on something that
/// will never come.
///
/// `dart:io` has no API for another process's CPU time, so each host answers
/// from its own source: `/proc` on Linux, `ps` on macOS, PowerShell's
/// `Get-Process` on Windows.
import 'dart:io';

/// Signature for reading a process's CPU time (allows test injection).
typedef CpuTimeReader = Future<Duration> Function(int pid);

/// User plus system CPU time [pid] has used since it started.
///
/// Throws [ProcessCpuTimeException] when the host cannot say, which includes
/// the process having exited.
Future<Duration> readProcessCpuTime(int pid) {
  if (Platform.isLinux) return _linux(pid);
  if (Platform.isMacOS) return _macos(pid);
  if (Platform.isWindows) return _windows(pid);
  throw ProcessCpuTimeException(
    'reading CPU time is not supported on ${Platform.operatingSystem}',
  );
}

class ProcessCpuTimeException implements Exception {
  final String message;
  ProcessCpuTimeException(this.message);

  @override
  String toString() => 'ProcessCpuTimeException: $message';
}

Future<int>? _clockTicksPerSecond;

/// `utime` and `stime` from `/proc/<pid>/stat`, in clock ticks.
///
/// Fields are counted from after the last `)`: the command name before it is
/// parenthesised and may itself contain spaces and parentheses.
Future<Duration> _linux(int pid) async {
  final String stat;
  try {
    stat = await File('/proc/$pid/stat').readAsString();
  } on FileSystemException catch (e) {
    throw ProcessCpuTimeException('cannot read /proc/$pid/stat: ${e.message}');
  }
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  // fields[0] is field 3 (state); utime and stime are fields 14 and 15.
  final ticks = int.parse(fields[11]) + int.parse(fields[12]);
  final perSecond = await (_clockTicksPerSecond ??= _getconfClockTicks());
  return Duration(microseconds: ticks * 1000000 ~/ perSecond);
}

Future<int> _getconfClockTicks() async {
  final result = await Process.run('getconf', ['CLK_TCK']);
  final value = int.tryParse((result.stdout as String).trim());
  if (result.exitCode != 0 || value == null || value <= 0) {
    throw ProcessCpuTimeException(
      'getconf CLK_TCK answered "${result.stdout}" (exit ${result.exitCode})',
    );
  }
  return value;
}

/// `ps -o cputime=`, which macOS prints as `[[dd-]hh:]mm:ss.cc`.
Future<Duration> _macos(int pid) async {
  final result = await Process.run('ps', ['-o', 'cputime=', '-p', '$pid']);
  final text = (result.stdout as String).trim();
  if (result.exitCode != 0 || text.isEmpty) {
    throw ProcessCpuTimeException('ps has no process $pid');
  }
  return parsePsCpuTime(text);
}

/// Parse `ps`'s `[[dd-]hh:]mm:ss[.cc]` CPU time.
Duration parsePsCpuTime(String text) {
  var days = 0;
  var rest = text;
  final dash = rest.indexOf('-');
  if (dash >= 0) {
    days = int.parse(rest.substring(0, dash));
    rest = rest.substring(dash + 1);
  }
  final parts = rest.split(':');
  final seconds = double.parse(parts.removeLast());
  var minutes = 0;
  for (final part in parts) {
    minutes = minutes * 60 + int.parse(part);
  }
  return Duration(
    days: days,
    minutes: minutes,
    microseconds: (seconds * 1000000).round(),
  );
}

/// `TotalProcessorTime` in 100ns ticks: an integer, so no locale decides the
/// decimal separator.
Future<Duration> _windows(int pid) async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '(Get-Process -Id $pid).TotalProcessorTime.Ticks',
  ]);
  final ticks = int.tryParse((result.stdout as String).trim());
  if (result.exitCode != 0 || ticks == null) {
    throw ProcessCpuTimeException(
      'Get-Process -Id $pid failed: ${(result.stderr as String).trim()}',
    );
  }
  return Duration(microseconds: ticks ~/ 10);
}
