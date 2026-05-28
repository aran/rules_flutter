/// Bazel invocation helpers.
import 'dart:convert';
import 'dart:io';

/// Result of a Bazel build invocation.
class BazelBuildResult {
  final int exitCode;
  final List<String> outputFiles;
  final String stderr;

  BazelBuildResult({
    required this.exitCode,
    required this.outputFiles,
    required this.stderr,
  });

  bool get success => exitCode == 0;
}

/// Invokes `bazel build` for the given target and returns output file paths.
///
/// [workspace] must be the consumer's workspace root (see
/// [findWorkspaceRoot]). It is used as the spawned bazel process's
/// `workingDirectory`. Without this, under `bazel run` the dev tool's
/// `Directory.current` is the runfiles execroot, so the inner bazel
/// rejects with *"bazel should not be called from a bazel output
/// directory"*.
///
/// Output files come from `bazel cquery <target> --output=files` — the exact
/// outputs declared by the target rule. No guessing or heuristics.
Future<BazelBuildResult> bazelBuild(
  String target, {
  required String workspace,
  String? compilationMode,
  List<String> extraArgs = const [],
}) async {
  final args = ['build', target];
  if (compilationMode != null) {
    args.addAll(['-c', compilationMode]);
  }
  args.addAll(extraArgs);

  stdout.writeln('Running: bazel ${args.join(' ')}');

  final process = await Process.start('bazel', args,
      mode: ProcessStartMode.inheritStdio, workingDirectory: workspace);
  final exitCode = await process.exitCode;

  if (exitCode != 0) {
    return BazelBuildResult(exitCode: exitCode, outputFiles: [], stderr: '');
  }

  // Query for output files with the same flags used for build.
  final cqueryArgs = ['cquery', target, '--output=files'];
  if (compilationMode != null) {
    cqueryArgs.addAll(['-c', compilationMode]);
  }
  cqueryArgs.addAll(extraArgs);
  final cqueryResult =
      await Process.run('bazel', cqueryArgs, workingDirectory: workspace);
  final outputFiles = _absolutizeCqueryPaths(
    cqueryResult.stdout as String,
    workspace,
  );

  return BazelBuildResult(
    exitCode: exitCode,
    outputFiles: outputFiles,
    stderr: cqueryResult.stderr as String,
  );
}

/// Queries for the output files of the `flutter_application` target within
/// [target]'s dependency tree.
///
/// Platform wrapper targets (macOS, iOS, Android, Linux, Windows) apply
/// Starlark transitions, so the flutter_application may be built in a
/// different configuration. Using `cquery kind() within deps()` resolves
/// through those transitions.
///
/// Returns paths to files like `package_config.json` and `.dill` that the
/// frontend server needs for hot reload.
Future<List<String>> bazelCqueryFlutterApp(
  String target, {
  required String workspace,
  String? compilationMode,
  List<String> extraArgs = const [],
}) async {
  final args = [
    'cquery',
    'kind("flutter_application", deps($target))',
    '--output=files',
  ];
  if (compilationMode != null) {
    args.addAll(['-c', compilationMode]);
  }
  args.addAll(extraArgs);
  final result = await Process.run('bazel', args, workingDirectory: workspace);
  if (result.exitCode != 0) return [];
  return _absolutizeCqueryPaths(result.stdout as String, workspace);
}

/// Parse `bazel cquery --output=files` stdout into absolute paths.
///
/// `bazel cquery` returns workspace-relative paths
/// (e.g. `bazel-out/darwin_arm64-dbg-…/bin/foo.zip`). Downstream
/// consumers in this dev tool spawn subprocesses (`unzip`,
/// installers), open files via `dart:io`, and pass paths to user
/// stdout — most of those sites would otherwise have to know that
/// `Directory.current` under `bazel run` is the runfiles execroot,
/// not the workspace, and either prepend the workspace or set
/// `workingDirectory` on every subprocess. Absolutizing once at this
/// boundary avoids that whack-a-mole.
List<String> _absolutizeCqueryPaths(String stdout, String workspace) {
  final result = <String>[];
  for (final line in LineSplitter.split(stdout)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('/')) {
      result.add(trimmed);
    } else {
      result.add('$workspace/$trimmed');
    }
  }
  return result;
}

/// Locate the Bazel workspace root.
///
/// Two sources, in priority order:
///   1. `BUILD_WORKSPACE_DIRECTORY` — set by `bazel run` to the workspace
///      where bazel was invoked. Authoritative when present, and the
///      *only* reliable signal under `bazel run`: at that point
///      `Directory.current` is the runfiles execroot, so any cwd-based
///      lookup (manual walkup or `bazel info workspace`) would either
///      fail outright or, worse, return rules_flutter's own workspace
///      instead of the consumer's.
///   2. `bazel info workspace` — canonical for standalone invocations
///      where the env var is unset and the user is `cd`-ed into a
///      workspace.
///
/// Throws [StateError] if neither resolves. The dev tool genuinely
/// cannot proceed without knowing the workspace, and a silent fallback
/// (the prior `?? '.'`) is exactly what masked the original bug.
Future<String> findWorkspaceRoot() async {
  final fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;

  final result = await Process.run('bazel', ['info', 'workspace']);
  if (result.exitCode != 0) {
    throw StateError(
      'Could not determine workspace root: BUILD_WORKSPACE_DIRECTORY is '
      'unset (so this binary was not invoked via `bazel run`) and '
      '`bazel info workspace` failed (exit ${result.exitCode}) from cwd '
      '${Directory.current.path}:\n${result.stderr}',
    );
  }
  return (result.stdout as String).trim();
}
