/// Runs `frontend_server` for a kernel compile and drops the lines of its
/// batch protocol from the output, so a successful build prints nothing.
///
/// Outside interactive mode `frontend_server` still frames each compile for a
/// client that is not there: `result <uuid>`, the bare `<uuid>`, and
/// `<uuid> <output.dill> <error count>`. No flag turns them off, and Bazel
/// shows an action's output on success. Every other line, errors above all,
/// passes through unchanged, as does the exit code.
///
/// Before the compiler runs, every declared source's directives are checked
/// against the declared inputs (`directive_guard.dart`): a directive that
/// names no declared file — a `file:` URI in any spelling, any other
/// unexpected scheme, or a relative URI climbing out of the declared inputs —
/// fails the build, under every strategy. The compile mounts only its staging
/// root, so an undeclared file is not there to be read whatever its spelling.
///
/// After the compiler runs, its `+file://` dependency lines are verified
/// against the same manifest: a read of a file the manifest does not name
/// fails the build instead of caching bytes Bazel never reruns on.
/// The lines are dropped either way, so a successful build stays silent.
///
/// The report cannot be switched off: the tool appends its own
/// `--print-incremental-dependencies` after the caller's flags (the last
/// occurrence wins in `frontend_server`'s `package:args` parsing), and a
/// compile that exits 0 while reporting no reads at all fails closed — a
/// real compile reads at least its entrypoint, so zero reads means the
/// report was silenced by other means.
///
/// The manifest is the only source of allowances: the tool derives nothing
/// from the compile argv. A flag smuggled into the argv (`--packages`,
/// `--import-dill`, `--platform` and the like, whether in `vm_flags` or
/// `extra_flags`) names no allowed read, and the refusal path deletes only
/// the manifest's output — never a path the argv names.
///
/// A plugin that is not available on the compiled platform fails the build
/// with a hint saying so: shipping without its registration (where `flutter
/// build` would fail) is never the right recovery.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart kernel_filter.dart --declared-inputs <manifest> -- <executable> <arguments>
library;

import 'dart:io';

import 'directive_guard.dart';

const _uuid =
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';

final _boundary = RegExp('^(result $_uuid|$_uuid|$_uuid \\S.* \\d+)\$');

/// Whether [line] is one of `frontend_server`'s batch-protocol lines.
bool isBoundaryLine(String line) => _boundary.hasMatch(line);

/// [output] without its batch-protocol lines.
String withoutBoundaryLines(String output) {
  final kept = [
    for (final line in output.split('\n'))
      if (!isBoundaryLine(line)) line,
  ];
  return kept.join('\n');
}

/// Splits [stdoutText] into the `+uri` dependency lines the compiler printed
/// and everything else (without its batch-protocol lines).
({List<String> reads, String rest}) splitDependencyLines(String stdoutText) {
  final reads = <String>[];
  final kept = <String>[];
  for (final line in stdoutText.split('\n')) {
    if (isBoundaryLine(line)) continue;
    if (line.startsWith('+')) {
      reads.add(line);
    } else {
      kept.add(line);
    }
  }
  return (reads: reads, rest: kept.join('\n'));
}

/// The exec-root-relative path a `+file://` dependency [line] names, or null
/// when the line names no file under the compile's working directory. Percent
/// escapes decode once, the way the front end spells them.
String? dependencyExecPath(String line) {
  final text = line.substring(1).trim();
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  if (uri.scheme != 'file') return null;
  final path = uri.toFilePath().replaceAll(r'\', '/');
  final cwd = Directory.current.path.replaceAll(r'\', '/');
  if (path == cwd) return '';
  if (!path.startsWith('$cwd/')) return null;
  return path.substring(cwd.length + 1);
}

/// The absolute normalized path a `+file://` dependency [line] names, or null
/// when the line is not a `file:` URI. Relative spellings resolve against the
/// compile's working directory. Percent escapes decode once and `.`/`..`
/// segments resolve first (`toFilePath` normalizes both spellings), the way
/// the front end spells them.
String? dependencyAbsolutePath(String line) {
  final text = line.substring(1).trim();
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  if (uri.scheme != 'file') return null;
  var path = uri.toFilePath().replaceAll(r'\', '/');
  if (!path.startsWith('/') && !RegExp(r'^[a-zA-Z]:').hasMatch(path)) {
    path = '${Directory.current.path.replaceAll(r'\', '/')}/$path';
  }
  return path;
}

/// The subset of `frontend_server`'s `+uri` dependency [lines] that names no
/// declared input: each entry is the offending line. [declared] holds the
/// exec-root-relative paths from the `--declared-inputs` manifest's source
/// and staged sections, and [extraAllowed] the manifest's `allowed-reads`
/// section (the package config, the platform dill, the summary dills, the
/// native-assets manifest) — never the compile argv.
///
/// A read spelt like a working-directory path is decided by the manifest
/// alone, exactly like the batch path. [requestRoots] additionally excuses a
/// read from outside the working directory when it sits strictly under one of
/// the request's `--filesystem-root` values (see [_readUnderRoot]); callers
/// that pass none see exactly the old behavior.
List<String> findUndeclaredReads(
  List<String> lines,
  Set<String> declared,
  Set<String> extraAllowed, {
  List<String> requestRoots = const [],
}) {
  final undeclared = <String>[];
  for (final line in lines) {
    final rel = dependencyExecPath(line);
    if (rel != null) {
      if (!declared.contains(rel) && !extraAllowed.contains(rel)) {
        undeclared.add(line);
      }
      continue;
    }
    if (!_readUnderRoot(line, requestRoots)) {
      undeclared.add(line);
    }
  }
  return undeclared;
}

/// Whether a `+uri` dependency [line] from outside the working directory
/// names a file strictly under one of the request-time compiler [roots].
///
/// The check is structural on purpose, matching the prototype: the roots
/// stage exactly the declared inputs, so in production every read under a
/// root is a declared file and this branch never fires (every production
/// read sits under the working directory, where the manifest decides). It
/// fires only when the roots are remapped elsewhere — the differential
/// harness mirrors the staging root, linking created libraries in the way
/// the build stages them — and there it accepts the mirrored tree the same
/// way a re-analysis would declare and stage it. Reads outside every root
/// (absolute `file:` imports, package-config escapes: the RT8/RT10 cases)
/// are still refused, as are `..` escapes, which resolve before the prefix
/// check and so name a path outside the root.
bool _readUnderRoot(String line, List<String> requestRoots) {
  if (requestRoots.isEmpty) return false;
  final abs = dependencyAbsolutePath(line);
  if (abs == null) return false;
  final cwd = Directory.current.path.replaceAll(r'\', '/');
  for (final rawRoot in requestRoots) {
    if (abs.startsWith('${_absoluteRoot(rawRoot, cwd)}/')) return true;
  }
  return false;
}

/// [root] as an absolute slash path: a relative root resolves against [cwd].
String _absoluteRoot(String root, String cwd) {
  var path = root.replaceAll(r'\', '/');
  while (path.endsWith('/') && path.length > 1) {
    path = path.substring(0, path.length - 1);
  }
  if (!path.startsWith('/') && !RegExp(r'^[a-zA-Z]:').hasMatch(path)) {
    path = '$cwd/$path';
  }
  return path;
}

/// The compile argv with the dependency report forced on.
///
/// Returns [cmdArgs] with `--print-incremental-dependencies` inserted after
/// the caller's flags, immediately before the final entrypoint argument (the
/// entrypoint closes the `frontend_server` argv, so a flag appended after it
/// would not parse as a flag). `frontend_server` parses flags with
/// `package:args`, where the last occurrence of a boolean flag wins, so the
/// tool's occurrence overrides any caller spelling that analysis did not
/// already refuse.
List<String> withForcedDependencyReport(List<String> cmdArgs) {
  const forced = '--print-incremental-dependencies';
  if (cmdArgs.length < 2) return [...cmdArgs, forced];
  return [...cmdArgs.sublist(0, cmdArgs.length - 1), forced, cmdArgs.last];
}

/// The compile's declared inputs, read from a `--declared-inputs` manifest.
///
/// The manifest lists one exec-root-relative path per line in sections: the
/// declared sources, then a `# staged` marker with the staging root's
/// symlinks to them, then `# allowed-reads` with every other file the
/// compiler may read (the package config, the platform dill, the summary
/// dills, the native-assets manifest), then `# filesystem-roots` with the
/// mounted roots the directive guard resolves through, then `# output` with
/// the output dill. Written by `flutter_kernel_compile_action` from its
/// Starlark `File` objects. Shared with the incremental worker, which guards
/// and verifies against the same manifest.
typedef KernelInputsManifest = ({
  /// Every path in the manifest's sources section, in order.
  List<String> sources,

  /// The sources plus the staged spellings: what the compiler may read as
  /// program inputs.
  Set<String> declared,

  /// The manifest's `allowed-reads` section (never the compile argv).
  Set<String> extraAllowed,

  /// The manifest's `filesystem-roots` section.
  List<String> fsRoots,

  /// The manifest's `# output` entry, or null when absent.
  String? outputDill,
});

/// Reads the `--declared-inputs` manifest at [manifestPath].
KernelInputsManifest readKernelInputsManifest(String manifestPath) {
  final sources = <String>[];
  final declared = <String>{};
  final extraAllowed = <String>{};
  final fsRoots = <String>[];
  String? outputDill;
  var section = 'sources';
  for (final line in File(manifestPath).readAsLinesSync()) {
    final path = line.trim().replaceAll(r'\', '/');
    if (path.isEmpty) continue;
    if (path.startsWith('#')) {
      section = switch (path) {
        '# staged' => 'staged',
        '# allowed-reads' => 'reads',
        '# filesystem-roots' => 'roots',
        '# output' => 'output',
        _ => 'unknown',
      };
      continue;
    }
    switch (section) {
      case 'sources':
        sources.add(path);
        declared.add(path);
      case 'staged':
        declared.add(path);
      case 'reads':
        extraAllowed.add(path);
      case 'roots':
        fsRoots.add(path);
      case 'output':
        outputDill ??= path;
      case 'unknown':
        break;
    }
  }
  return (
    sources: sources,
    declared: declared,
    extraAllowed: extraAllowed,
    fsRoots: fsRoots,
    outputDill: outputDill,
  );
}

/// The refusal for a compiler read of a file the manifest does not name.
/// Shared with the incremental worker so both paths refuse with the same
/// message.
String undeclaredReadMessage(String line) =>
    'flutter: the compiler read $line, which is not a declared input of '
    'this compile. Declare the file in `srcs` (typically '
    '`glob(["lib/**/*.dart"])`) or stop importing it.';

/// The failure when a successful compile reports no dependency reads at all:
/// a real compile reads at least its entrypoint, so zero reads means the
/// report was silenced and the read-set check has nothing to verify. Shared
/// with the incremental worker so both paths fail closed with the same
/// message.
String noDependencyReadsMessage() =>
    'flutter: the compiler reported no dependency reads, so the read-set '
    'check has nothing to verify. A real compile reads at least its '
    'entrypoint: the report was silenced, and the compile controls '
    '`--print-incremental-dependencies` itself. Remove any silencer from '
    '`extra_flags` and rebuild.';

Future<void> main(List<String> argv) async {
  exit(await runFiltered(argv, stdout, stderr));
}

/// Parses the tool flags before `--`: the manifest path plus the compiler
/// argv.
///
/// Returns null after describing the usage error on [err].
({String manifestPath, String executable, List<String> cmdArgs})?
_splitFilterArgv(List<String> argv, StringSink err) {
  final i = argv.indexOf('--');
  if (i < 0 || i + 1 >= argv.length) {
    err.writeln(
      'Usage: dart kernel_filter.dart --declared-inputs <manifest> -- <executable> <arguments>',
    );
    return null;
  }
  String? manifestPath;
  for (var j = 0; j < i; j++) {
    if (argv[j] == '--declared-inputs' && j + 1 < i) {
      manifestPath = argv[++j];
    } else {
      err.writeln('kernel_filter: unexpected argument ${argv[j]}.');
      return null;
    }
  }
  if (manifestPath == null) {
    err.writeln(
      'kernel_filter: missing required --declared-inputs <manifest>.',
    );
    return null;
  }
  return (
    manifestPath: manifestPath,
    executable: argv[i + 1],
    cmdArgs: argv.sublist(i + 2),
  );
}

/// Refuses declared sources whose directives name no declared input.
///
/// Returns 1 after writing each refusal on [err], or null to keep going.
int? _refuseDisallowedDirectives(
  List<String> sources,
  List<String> fsRoots,
  StringSink err,
) {
  final guardErrors = findDisallowedFlutterDirectives(
    sources,
    fsRoots,
    tool: 'flutter',
  );
  if (guardErrors.isEmpty) return null;
  for (final error in guardErrors) {
    err.writeln(error);
  }
  return 1;
}

/// Deletes a refused compile's output dill when it exists.
void _deleteRefusedOutput(String? outputDill) {
  if (outputDill == null) return;
  try {
    File(outputDill).deleteSync();
  } on FileSystemException {
    // Already gone; the nonzero exit fails the action either way.
  }
}

/// Reports a failed compile: its dependency lines are dropped while every
/// other line, both streams and the exit code pass through. A missing
/// platform plugin gets the hint instead of a silent pass-through.
int _reportCompilerFailure(
  ProcessResult result,
  StringSink out,
  StringSink err,
) {
  final split = splitDependencyLines(result.stdout as String);
  out.write(split.rest);
  err.write(result.stderr as String);
  if ('${result.stdout}${result.stderr}'.contains(
    'is not available on this platform.',
  )) {
    err.writeln(
      'flutter: this compile imports a plugin that is not available on the '
      'compiled platform. Remove the dependency or add a platform '
      "implementation; the build fails instead of shipping without the "
      "plugin's registration.",
    );
  }
  return result.exitCode;
}

/// Verifies a successful compile's dependency report against the manifest.
///
/// Returns 1 after writing each refusal on [err] — deleting only the
/// manifest's output, never a path the argv names — or null when every read
/// is declared and the caller should print the filtered output.
int? _refuseUndeclaredReads(
  ({List<String> reads, String rest}) split,
  Set<String> declared,
  Set<String> extraAllowed,
  String? outputDill,
  StringSink err,
) {
  if (split.reads.isEmpty) {
    err.writeln(noDependencyReadsMessage());
    _deleteRefusedOutput(outputDill);
    return 1;
  }
  final undeclared = findUndeclaredReads(split.reads, declared, extraAllowed);
  if (undeclared.isEmpty) return null;
  for (final line in undeclared) {
    err.writeln(undeclaredReadMessage(line));
  }
  // Delete only the manifest's output: an `--output-dill` smuggled into
  // the argv names no file here, so the refusal cannot be redirected at
  // (or away from) another path.
  _deleteRefusedOutput(outputDill);
  return 1;
}

/// Runs the command [argv] names after `--`, writing its output to [out] and
/// [err] without the protocol and dependency lines; returns its exit code.
///
/// The tool flags before `--` name the compile's declared inputs
/// (`--declared-inputs <manifest>`): the manifest lists one exec-root-relative
/// path per line in sections — the declared sources, then a `# staged`
/// marker, then the staging root's symlinks to them, then `# allowed-reads`
/// (the package config, the platform dill, the summary dills, the
/// native-assets manifest), then `# filesystem-roots` (the mounted roots the
/// directive guard resolves through), then `# output` with the output dill —
/// written by `flutter_kernel_compile_action` from its Starlark `File`
/// objects. The sources' directives are refused before the compiler runs
/// when they name an undeclared file, and the compiler's own read set is
/// verified against the manifest after it runs. Nothing is read from the
/// compile argv: flags after `--` run the compiler unchanged, and never
/// widen what it may read.
Future<int> runFiltered(
  List<String> argv,
  StringSink out,
  StringSink err,
) async {
  final parsed = _splitFilterArgv(argv, err);
  if (parsed == null) return 2;
  final manifestPath = parsed.manifestPath;
  if (!File(manifestPath).existsSync()) {
    err.writeln(
      'kernel_filter: declared-inputs manifest $manifestPath does not exist.',
    );
    return 2;
  }
  // The manifest lists the declared sources, then `# staged` with the
  // staging root's symlinks to them, then `# allowed-reads` with every other
  // file the compiler may read, then `# filesystem-roots`, then `# output`
  // with the output dill. The guard scans the sources (the links hold the
  // same bytes), while the read set allows the source spellings, the staged
  // spellings, and the allowed reads — all of them manifest entries, never
  // argv values.
  final inputs = readKernelInputsManifest(manifestPath);
  final sources = [
    for (final path in inputs.sources)
      if (path.endsWith('.dart')) path,
  ];

  final directiveRefusal = _refuseDisallowedDirectives(
    sources,
    inputs.fsRoots,
    err,
  );
  if (directiveRefusal != null) return directiveRefusal;

  final result = await Process.run(
    parsed.executable,
    withForcedDependencyReport(parsed.cmdArgs),
  );
  if (result.exitCode != 0) {
    return _reportCompilerFailure(result, out, err);
  }

  final split = splitDependencyLines(result.stdout as String);
  final readsRefusal = _refuseUndeclaredReads(
    split,
    inputs.declared,
    inputs.extraAllowed,
    inputs.outputDill,
    err,
  );
  if (readsRefusal != null) return readsRefusal;
  out.write(split.rest);
  err.write(result.stderr as String);
  return result.exitCode;
}
