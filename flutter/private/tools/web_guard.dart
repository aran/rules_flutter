/// Guards a Flutter web compile (dart2js, dart2wasm, or the `--cfe-only`
/// icon kernel) and then runs it.
///
/// Before the compiler runs, every declared source's directives are checked
/// against the declared inputs (`directive_guard.dart`): a directive that
/// names no declared file — a `file:` URI in any spelling, any other
/// unexpected scheme, or a relative URI climbing out of the declared inputs —
/// fails the build, under every strategy. The compile mounts only its staging
/// root, so an undeclared file is not there to be read whatever its spelling.
///
/// Unlike `kernel_filter.dart`, there is no post-compile read-set check: the
/// web compilers print no `+file://` dependency lines to verify. The guard
/// plus the stage-only root is the whole confinement.
///
/// A source that is not decodable UTF-8 fails closed here instead of being
/// skipped: the front ends accept such files, so skipping the check while the
/// compiler reads the import would confine nothing.
///
/// It is compiled to a self-contained native executable (see the `web_guard`
/// `dart_binary`): the guarded compile stages only the executable and its
/// manifest, never a Dart VM's snapshots and debug symbols.
///
/// Usage:
///   web_guard --declared-inputs <manifest> -- <executable> <arguments>
library;

import 'dart:io';

import 'directive_guard.dart';

Future<void> main(List<String> argv) async {
  exit(await runGuarded(argv, stdout, stderr));
}

/// Runs the command [argv] names after `--` once its declared sources pass
/// the directive guard, writing its output to [out] and [err]; returns its
/// exit code.
///
/// The tool flags before `--` name the compile's declared inputs
/// (`--declared-inputs <manifest>`): the manifest lists one exec-root-relative
/// path per line — the declared sources, then a `# staged` marker, then the
/// staging root's symlinks to them — written by the `flutter_dart2js_action`,
/// `flutter_dart2wasm_action` and `flutter_dart2js_cfe_action` helpers. The
/// `.dart` sources' directives are refused before the compiler runs when they
/// name an undeclared file; a source that cannot be read as text fails closed
/// for the same reason. The `--multi-root` values in the compiler's own
/// arguments are the filesystem roots the app-scheme keys resolve against.
Future<int> runGuarded(
  List<String> argv,
  StringSink out,
  StringSink err,
) async {
  final parsed = _parseGuardArgs(argv);
  if (parsed.error != null) {
    err.writeln(parsed.error);
    return 2;
  }
  final sources = _readGuardSources(parsed.manifestPath!);
  if (sources.error != null) {
    err.writeln(sources.error);
    return 2;
  }
  final refused = _refuseUndecodableSources(sources.paths, err);
  if (refused != null) return refused;
  final executable = argv[parsed.separator + 1];
  final cmdArgs = argv.sublist(parsed.separator + 2);
  final guardErrors = findDisallowedFlutterDirectives(
    sources.paths,
    _commandMultiRoots(cmdArgs),
    tool: 'flutter',
  );
  if (guardErrors.isNotEmpty) {
    for (final error in guardErrors) {
      err.writeln(error);
    }
    return 1;
  }
  return _runGuardedCommand(executable, cmdArgs, out, err);
}

/// The `--` separator and `--declared-inputs` value in [argv], or the usage
/// error to report when they are missing or malformed.
({int separator, String? manifestPath, String? error}) _parseGuardArgs(
  List<String> argv,
) {
  final i = argv.indexOf('--');
  if (i < 0 || i + 1 >= argv.length) {
    return (
      separator: -1,
      manifestPath: null,
      error: 'Usage: web_guard --declared-inputs <manifest> -- <executable> <arguments>',
    );
  }
  String? manifestPath;
  for (var j = 0; j < i; j++) {
    if (argv[j] == '--declared-inputs' && j + 1 < i) {
      manifestPath = argv[++j];
    } else {
      return (
        separator: i,
        manifestPath: null,
        error: 'web_guard: unexpected argument ${argv[j]}.',
      );
    }
  }
  if (manifestPath == null) {
    return (
      separator: i,
      manifestPath: null,
      error: 'web_guard: missing required --declared-inputs <manifest>.',
    );
  }
  return (separator: i, manifestPath: manifestPath, error: null);
}

/// The `.dart` sources the declared-inputs [manifestPath] lists, or the error
/// to report when the manifest does not exist.
///
/// The manifest lists the declared sources, then `# staged`, then the staging
/// root's symlinks to them: the guard scans the sources (the links hold the
/// same bytes).
({List<String> paths, String? error}) _readGuardSources(String manifestPath) {
  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    return (
      paths: const [],
      error:
          'web_guard: declared-inputs manifest $manifestPath does not exist.',
    );
  }
  final sources = <String>[];
  var staged = false;
  for (final line in manifest.readAsLinesSync()) {
    final path = line.trim().replaceAll(r'\', '/');
    if (path.isEmpty) continue;
    if (path.startsWith('#')) {
      staged = true;
      continue;
    }
    if (!staged && path.endsWith('.dart')) sources.add(path);
  }
  return (paths: sources, error: null);
}

/// Refuses a declared source the guard cannot decode, or null when all scan.
///
/// A file the guard cannot decode is refused rather than skipped: the web
/// front ends compile such files, so a skip would leave the import they carry
/// unchecked. A file missing here is left to the compiler, which reports it.
/// (`readAsStringSync` reports a decode failure as a `FileSystemException`, so
/// existence is what tells a missing file from an undecodable one.)
int? _refuseUndecodableSources(List<String> sources, StringSink err) {
  for (final path in sources) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      file.readAsStringSync();
    } on FileSystemException {
      err.writeln(
        "flutter: $path is not decodable text and is not a declared input.",
      );
      return 1;
    }
  }
  return null;
}

/// The `--multi-root` values in the compiler's own [cmdArgs]: the filesystem
/// roots the app-scheme keys resolve against.
///
/// The bzl helpers pass the staging root the compilers mount as
/// `--multi-root=<stage>`: app-scheme keys resolve against it the way the
/// compilers resolve them.
List<String> _commandMultiRoots(List<String> cmdArgs) {
  final fsRoots = <String>[];
  for (var j = 0; j < cmdArgs.length; j++) {
    final arg = cmdArgs[j];
    if (arg == '--multi-root' && j + 1 < cmdArgs.length) {
      fsRoots.add(cmdArgs[++j]);
    } else if (arg.startsWith('--multi-root=')) {
      fsRoots.add(arg.substring('--multi-root='.length));
    }
  }
  return fsRoots;
}

/// Runs the guarded [executable] with [cmdArgs], relaying its output.
Future<int> _runGuardedCommand(
  String executable,
  List<String> cmdArgs,
  StringSink out,
  StringSink err,
) async {
  final result = await Process.run(executable, cmdArgs);
  out.write(result.stdout as String);
  err.write(result.stderr as String);
  return result.exitCode;
}
