/// The `frontend_server` incremental session behind the incremental worker.
///
/// A [CompilerSession] speaks the server's line protocol: `compile`,
/// `recompile` (a delta, then `accept`), and the two-phase `reset` plus an
/// empty `recompile` whose full dill carries no history (rule F). A failed
/// compile is `reject`ed so the server stays at its last accepted state.
/// [FrontendServerSession] is the real process; tests substitute a fake.
///
/// Change classification ([classifyChanged]) and URI mapping ([uriOfStaged])
/// are pure and shared by the worker and its tests.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The multi-root scheme a staged file is compiled under.
const incrAppSchemeRoot = 'org-dartlang-app:///';

/// The flag making the server write one component instead of one per package.
const noIncrementalSerialization = '--no-incremental-serialization';

/// The outcome of one `compile` or `recompile` command.
typedef CompileResult = ({
  int errors,
  List<String> diagnostics,
  List<String> depLines,
});

/// One warm `frontend_server`: `compile` once, then deltas.
///
/// The two-phase protocol always finishes with `reset` plus an empty
/// `recompile`, so the full dill is written by a compile that compiled
/// nothing and carries no per-library history.
abstract class CompilerSession {
  Future<CompileResult> compile(String entry);
  Future<CompileResult> recompile(
    String entry,
    List<String> uris, {
    bool resetFirst = false,
  });
  Future<void> accept();
  Future<void> reject();
  Future<void> close();
  bool get alive;
}

/// Drops a leading tool path (`argv[0]`): `kernel_filter`'s argv after
/// `argv[0]` starts with `--declared-inputs` or an `@flagfile`, so a first
/// argument that is neither can only be the tool itself. The harness sends
/// the full argv with the worker at `argv[0]`; Bazel's worker protocol and
/// `main` omit it, so stripping is a no-op there.
/// ([argv] is already flagfile-expanded or not; the tool path is never a
/// flag or a flagfile, so this runs the same before or after expansion.)
List<String> stripWorkerArgv0(List<String> argv) {
  if (argv.isNotEmpty &&
      !argv.first.startsWith('-') &&
      !argv.first.startsWith('@')) {
    return argv.sublist(1);
  }
  return argv;
}

/// Splits [argv] around `--`: the manifest flag and path before it, the
/// compiler command after it. Throws [FormatException] when malformed.
({String manifestPath, List<String> command}) splitWorkerArgv(
  List<String> argv,
) {
  final i = argv.indexOf('--declared-inputs');
  if (i < 0 || i + 1 >= argv.length) {
    throw const FormatException(
      'incr_fkc_worker: missing required --declared-inputs <manifest>.',
    );
  }
  final manifestPath = argv[i + 1];
  final j = argv.indexOf('--');
  if (j < 0 || j + 1 >= argv.length || j < i) {
    throw const FormatException(
      'Usage: incr_fkc_worker --declared-inputs <manifest> -- <executable> <arguments>',
    );
  }
  for (var k = 0; k < j; k++) {
    if (k == i || k == i + 1) continue;
    throw FormatException(
      'incr_fkc_worker: unexpected argument ${argv[k]}.',
    );
  }
  return (manifestPath: manifestPath, command: argv.sublist(j + 1));
}

/// Expands `@<flagfile>` entries in [argv] the way Bazel parameter files
/// arrive: each non-empty line of the file is one argument, in order.
/// Multiline param files shell-quote arguments holding whitespace with single
/// quotes, so a line wrapped in exactly one pair of quotes unwraps; anything
/// else passes through untouched. [readFile] reads a flagfile's lines; it
/// takes the working directory so tests can substitute a fake filesystem.
List<String> expandWorkerFlagfiles(
  List<String> argv, {
  List<String> Function(String path)? readFile,
}) {
  final read = readFile ?? _readFlagfileLines;
  final out = <String>[];
  for (final a in argv) {
    if (a.startsWith('@')) {
      for (final line in read(a.substring(1))) {
        out.add(_unquoteParamLine(line));
      }
    } else {
      out.add(a);
    }
  }
  return out;
}

List<String> _readFlagfileLines(String path) {
  final lines = <String>[];
  for (final line in File(path).readAsLinesSync()) {
    if (line.isNotEmpty) lines.add(line);
  }
  return lines;
}

/// Strips one pair of surrounding single quotes when the inside holds no
/// quote of its own; every other line is already a literal argument.
String _unquoteParamLine(String line) {
  if (line.length >= 2 &&
      line.startsWith("'") &&
      line.endsWith("'") &&
      !line.substring(1, line.length - 1).contains("'")) {
    return line.substring(1, line.length - 1);
  }
  return line;
}

/// Normalizes an exec-root-relative path for prefix comparison: `/`
/// separators, no trailing slashes, no leading `./` segments.
String normalizeWorkerPath(String path) {
  var slash = path.replaceAll(r'\', '/');
  slash = slash.replaceFirst(RegExp(r'/+$'), '');
  return slash.replaceFirst(RegExp(r'^(?:\./)+'), '');
}

/// The multi-root URI the compiler knows the staged file [path] by, or null
/// when [path] sits under no filesystem [roots] and is not itself a staged
/// input the compiler resolves.
String? uriOfStaged(String path, List<String> roots) {
  final p = normalizeWorkerPath(path);
  for (final rawRoot in roots) {
    final r = normalizeWorkerPath(rawRoot);
    if (r.isEmpty || r == '.') continue;
    if (p.startsWith('$r/')) {
      return incrAppSchemeRoot + p.substring(r.length + 1);
    }
  }
  return null;
}

/// How the worker reaches the changed inputs of one request.
typedef ChangedInputs = ({
  /// Staged `.dart` files to recompile through their multi-root URIs.
  List<String> uris,

  /// When non-null, a changed input no delta can carry: the server must
  /// restart cold. Names the reason (the offending path).
  String? restartReason,
});

/// Sorts [changed] exec-root-relative paths into a delta or a cold restart.
///
/// Changed staged `.dart` files recompile through their multi-root URIs. A
/// changed `.dart` source behind a staged symlink carries no URI itself: its
/// staged twin is in [changed] too and supplies the URI, so it is skipped
/// here. Any other changed input (the package config, the platform dill, the
/// flags, a non-`.dart` file, a `.dart` file under no root and in no manifest
/// section) restarts the server cold. [manifestSources] holds the manifest's
/// sources section.
ChangedInputs classifyChanged(
  List<String> changed,
  List<String> roots,
  Set<String> manifestSources,
) {
  final uris = <String>[];
  for (final p in changed) {
    if (p.endsWith('.dart')) {
      final uri = uriOfStaged(p, roots);
      if (uri != null) {
        uris.add(uri);
        continue;
      }
      if (manifestSources.contains(p)) {
        // The source behind a staged symlink: its staged twin carries the
        // URI.
        continue;
      }
    }
    return (uris: const [], restartReason: p);
  }
  return (uris: uris, restartReason: null);
}

/// Folds one compile's `+uri`/`-uri` dependency [lines] into [current], the
/// cumulative read set: additions join it, removals leave it.
void foldDepLines(Set<String> current, List<String> lines) {
  for (final d in lines) {
    if (d.startsWith('+')) {
      current.add(d.substring(1));
    } else if (d.startsWith('-')) {
      current.remove(d.substring(1));
    }
  }
}

/// A [CompilerSession] over a real `frontend_server` child process.
///
/// [fs] is the compiler command from the action argv (`dartaotruntime`, VM
/// flags, the snapshot, flags, entrypoint last). The server runs with
/// `--incremental` and `--no-incremental-serialization`, writing its full
/// dill to [fullDill] (a private path, never the action output) and deltas
/// to [incrementalDill]. The dependency report is forced on so the worker
/// can verify the read set.
class FrontendServerSession implements CompilerSession {
  FrontendServerSession._(
    this._process,
    this._lines,
    this.roots,
    this.entry,
  ) {
    _process.exitCode.then((_) => _exited = true);
  }

  final Process _process;
  final StreamIterator<String> _lines;
  final List<String> roots;
  final String entry;
  bool _exited = false;

  /// Starts the server for [fs] in [cwd], deleting any stale private output
  /// first: `frontend_server` initializes from `--output-dill` when that file
  /// exists, so a restarted server must not see the old output.
  static Future<FrontendServerSession> start(
    List<String> fs,
    String fullDill,
    String incrementalDill, {
    required String cwd,
  }) async {
    final flags = [...fs.sublist(0, fs.length - 1)];
    final entry = fs.last;
    final outI = flags.indexOf('--output-dill');
    if (outI < 0 || outI + 1 >= flags.length) {
      throw const FormatException(
        'incr_fkc_worker: compiler argv has no --output-dill.',
      );
    }
    for (final p in [fullDill, incrementalDill]) {
      try {
        File(p).deleteSync();
      } on FileSystemException {
        // Absent; the fresh server starts clean either way.
      }
    }
    flags[outI + 1] = fullDill;
    final insertAt = incrementalFlagIndex(flags);
    final spawnArgs = [
      ...flags.sublist(1, insertAt + 1),
      '--incremental',
      noIncrementalSerialization,
      '--output-incremental-dill',
      incrementalDill,
      ...flags.sublist(insertAt + 1),
      // The worker verifies the compiler's read set against the
      // declared-inputs manifest; the report cannot be left off. Appended
      // after the caller's flags so it wins `package:args`' last occurrence.
      '--print-incremental-dependencies',
    ];
    final roots = <String>[];
    for (var k = 0; k < flags.length - 1; k++) {
      if (flags[k] == '--filesystem-root') roots.add(flags[k + 1]);
    }
    final process = await Process.start(
      flags[0],
      spawnArgs,
      workingDirectory: cwd,
    );
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    return FrontendServerSession._(process, lines, roots, entry);
  }

  Future<void> _send(String text) async {
    _process.stdin.writeln(text);
    await _process.stdin.flush();
  }

  Future<CompileResult> _readResult() async {
    if (!await _lines.moveNext()) {
      throw const FormatException(
        'incr_fkc_worker: frontend_server exited before its result line.',
      );
    }
    final first = _lines.current;
    if (!first.startsWith('result ')) {
      throw FormatException(
        'incr_fkc_worker: expected a result line, got "$first".',
      );
    }
    final key = first.split(' ')[1];
    final diagnostics = <String>[];
    final deps = <String>[];
    while (await _lines.moveNext()) {
      final s = _lines.current;
      if (s == key) continue;
      if (s.startsWith('$key ')) {
        final parts = s.split(' ');
        final errors = parts.length > 2 ? int.parse(parts.last) : 1;
        return (errors: errors, diagnostics: diagnostics, depLines: deps);
      }
      if ((s.startsWith('+') || s.startsWith('-')) && s.contains('://')) {
        deps.add(s);
      } else {
        diagnostics.add(s);
      }
    }
    throw const FormatException(
      'incr_fkc_worker: frontend_server exited mid-compile.',
    );
  }

  @override
  Future<CompileResult> compile(String entry) async {
    await _send('compile $entry');
    return _readResult();
  }

  @override
  Future<CompileResult> recompile(
    String entry,
    List<String> uris, {
    bool resetFirst = false,
  }) async {
    if (resetFirst) await _send('reset');
    final urisBlock = uris.map((u) => '$u\n').join();
    await _send('recompile $entry kk\n${urisBlock}kk');
    return _readResult();
  }

  @override
  Future<void> accept() async => _send('accept');

  @override
  Future<void> reject() async {
    await _send('reject');
    // The rejection acknowledgement is two lines; they carry no content the
    // worker uses.
    await _lines.moveNext();
    await _lines.moveNext();
  }

  @override
  bool get alive => !_exited;

  @override
  Future<void> close() async {
    if (!alive) return;
    try {
      await _send('quit');
      await _process.exitCode.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
    } on StateError catch (_) {
      // Already gone (stdin closed under us); the exit handler marks it.
    }
  }
}

/// Where the server's own flags go in the compiler command [flags]: after
/// the frontend_server snapshot when one is named, else after the first
/// non-flag argument past the executable (a script path in tests).
int incrementalFlagIndex(List<String> flags) {
  final snap = flags.indexWhere((a) => a.endsWith('.snapshot'));
  if (snap >= 0) return snap;
  final script = flags.indexWhere(
    (a) => !a.startsWith('-'),
    1,
  );
  return script < 0 ? 0 : script;
}

/// Builds the compiler command for one request: [fs] with `--output-dill`
/// pointed at the private [fullDill].
List<String> redirectOutputDill(List<String> fs, String fullDill) {
  final flags = [...fs];
  final outI = flags.indexOf('--output-dill');
  if (outI < 0 || outI + 1 >= flags.length) {
    throw const FormatException(
      'incr_fkc_worker: compiler argv has no --output-dill.',
    );
  }
  flags[outI + 1] = fullDill;
  return flags;
}

/// The configuration key of one compiler command: the argv minus the output
/// path, so requests that differ only in where the dill lands share a warm
/// server.
String configurationKey(List<String> fs, String Function(List<int>) hash) {
  final flags = redirectOutputDill(fs, '<out>');
  return hash(utf8.encode(flags.join('\x00'))).substring(0, 16);
}
