/// Shared host-Python driving for the iOS screenshot helpers.
///
/// `screenshot` and `tunneld` run their programs through a host `python3`
/// (see `screenshot.dart` for why), so both need the same lookup, the same
/// missing-interpreter diagnostic, and the same spawn plumbing. Dependency-
/// free (`dart:io` only) so the helpers stay standalone `dart_binary` targets.
import 'dart:io';

/// Names tried on PATH, most preferred first. `python` is a fallback for
/// machines where only that name exists (notably Windows); `python3` stays
/// first so a Python 2 `python` elsewhere on PATH never shadows it.
List<String> get _pythonNames => Platform.isWindows
    ? const ['python', 'python3']
    : const ['python3', 'python'];

/// Candidate file names for [name] in one PATH entry.
List<String> _candidates(String dir, String name) {
  if (Platform.isWindows) {
    return ['$dir\\$name.exe', '$dir\\$name.bat', '$dir\\$name.cmd'];
  }
  return ['$dir/$name'];
}

/// The host Python interpreter to run, or null when there is none.
///
/// Searches each PATH entry for the preferred names (specific files, never
/// a bare name handed to the shell), mirroring the `HostTool` lookup the
/// dev tool uses for `adb` and friends: absence is reported, not guessed.
String? findHostPython() {
  final path = Platform.environment['PATH'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  for (final name in _pythonNames) {
    for (final dir in path.split(separator)) {
      if (dir.isEmpty) continue;
      for (final candidate in _candidates(dir, name)) {
        if (FileSystemEntity.isFileSync(candidate)) return candidate;
      }
    }
  }
  return null;
}

/// Diagnostic for a missing interpreter, naming what to install.
String missingPythonMessage({required String purpose}) {
  final names = _pythonNames.join(' or ');
  return 'Could not find $names on PATH, which is needed for $purpose.\n'
      'Install Python 3 (https://www.python.org/downloads/) and pymobiledevice3:\n'
      '  python3 -m pip install pymobiledevice3';
}

/// Whether this process runs as root (POSIX `id -u`; always false where
/// that question has no meaning).
bool isRoot() {
  if (Platform.isWindows) return false;
  try {
    final result = Process.runSync('id', ['-u']);
    return result.exitCode == 0 && (result.stdout as String).trim() == '0';
  } on ProcessException {
    return false;
  }
}

/// Runs [program] with [python], forwarding its stdout/stderr and returning
/// its exit code. The program travels on stdin (`python - ...`), so no
/// source file is staged anywhere; [args] reach it as `sys.argv[1:]`.
///
/// When the run fails because `pymobiledevice3` is not installed, the
/// interpreter's own `ModuleNotFoundError` is followed by the install
/// remedy (the program's other diagnostics pass through verbatim, since
/// callers match on them).
Future<int> runPythonProgram(
  String python,
  String program,
  List<String> args,
) async {
  final process = await Process.start(python, ['-', ...args]);
  process.stdin.write(program);
  await process.stdin.close();
  final stderrBytes = <int>[];
  await Future.wait([
    stdout.addStream(process.stdout),
    process.stderr.listen((chunk) {
      stderr.add(chunk);
      stderrBytes.addAll(chunk);
    }).asFuture<void>(),
  ]);
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    final stderrText = String.fromCharCodes(stderrBytes);
    if (stderrText.contains('ModuleNotFoundError') &&
        stderrText.contains('pymobiledevice3')) {
      stderr.writeln(
        "pymobiledevice3 is not installed for $python, which iOS device commands need.\n"
        'Install it:\n'
        '  $python -m pip install pymobiledevice3',
      );
    }
  }
  return exitCode;
}

/// Runs [program] with [python] as a long-lived foreground process: stdio
/// is the terminal's, and the program travels as `python -c` (stdin is
/// taken, so it cannot carry the program). Returns the exit code.
Future<int> runPythonProgramInteractive(
  String python,
  String program,
  List<String> args,
) async {
  final process = await Process.start(
    python,
    ['-c', program, ...args],
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}
