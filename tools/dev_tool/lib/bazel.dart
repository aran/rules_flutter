/// Bazel invocation helpers.
import 'dart:convert';
import 'dart:io';

import 'dev_tool_exception.dart';
import 'logging.dart';

final _logger = Logger('dev_tool.bazel');

/// A bazel invocation the caller needed, which bazel itself rejected.
///
/// Carried as a type of its own because of what cures it: the tree on disk. A
/// bazel command that failed can be asked again the moment the source it
/// choked on is fixed, which is not true of the other ways assembling a reload
/// pipeline goes wrong, and the reader's next move is completely different —
/// they go and look at their own code rather than at the dev tool.
///
/// [diagnostics] is a bounded tail of what bazel printed, not a transcript:
/// every line already reached a machine client as a `subprocess_output`
/// record, and this exists so the failure itself names its cause rather than
/// pointing at output that scrolled past.
class BazelInvocationFailure implements Exception {
  /// The bazel command, as the user would have typed it: `build //:app`.
  final String command;

  /// The tail of bazel's own output. Empty only if bazel printed nothing.
  final String diagnostics;

  const BazelInvocationFailure({
    required this.command,
    required this.diagnostics,
  });

  @override
  String toString() => diagnostics.isEmpty
      ? 'bazel $command failed'
      : 'bazel $command failed:\n$diagnostics';
}

/// Result of a Bazel build invocation.
class BazelBuildResult {
  final int exitCode;
  final List<String> outputFiles;

  /// Whatever stderr explains this result: on failure the tail of the build's
  /// own output, on success the stderr of the cquery that listed the outputs.
  final String stderr;

  BazelBuildResult({
    required this.exitCode,
    required this.outputFiles,
    required this.stderr,
  });

  bool get success => exitCode == 0;

  /// This result as the failure it is. Only call it on a failed build.
  BazelInvocationFailure asFailure(String command) {
    if (success) {
      throw StateError(
        'bazel $command succeeded; there is no failure to raise.',
      );
    }
    return BazelInvocationFailure(command: command, diagnostics: stderr);
  }
}

/// A [SubprocessOutput] that also keeps the last few lines it emitted.
///
/// Bounded, and deliberately small: the whole stream already reaches the user
/// (text mode) and a machine client (`subprocess_output` records) line by line
/// as it arrives. This exists only so a failure record can name its own cause.
class _TailedOutput extends SubprocessOutput {
  static const _maxLines = 40;

  final List<String> lines = [];

  _TailedOutput({required super.source, required super.stream});

  @override
  void emitLine(String line) {
    super.emitLine(line);
    lines.add(line);
    if (lines.length > _maxLines) lines.removeAt(0);
  }

  String get tail => lines.join('\n');
}

/// Maps `--dart-define KEY=VALUE` values to the rules_flutter build-setting
/// flags every bazel invocation (build AND cquery) must carry so they all
/// resolve in the same configuration.
///
/// The flag is repeatable: one occurrence per define, so values containing
/// commas survive intact.
List<String> dartDefineFlags(List<String> dartDefines) => [
  for (final define in dartDefines)
    '--@rules_flutter//flutter:extra_dart_defines=$define',
];

/// Requests the build outputs this tool reads off disk.
///
/// Bazel materializes an output when it belongs to a target named on the
/// command line. A launchable target names only its bundle, while this tool
/// reads the `flutter_application`'s outputs — the assets tree, the dev config,
/// the package configs, the registrants. Those belong to a configured target
/// reached through a split transition, which no command line can name, so the
/// request travels as an aspect over the existing dep edges.
///
/// Web needs none of this: `flutter_web_application` declares its own dev
/// outputs and the tool names that target directly.
const _devFilesAspect = [
  '--aspects=@rules_flutter//flutter:dev_files.bzl%flutter_dev_files',
  '--output_groups=+flutter_dev_files',
];

/// The argv for a `bazel build` this dev tool runs.
///
/// The aspect flags go last. `--output_groups=+name` is additive and a
/// repeated aspect is applied once, so nothing here overrides what the caller
/// passed as `--build-arg`.
List<String> bazelBuildArgs(
  String target, {
  String? compilationMode,
  List<String> extraArgs = const [],
}) => [
  'build',
  target,
  if (compilationMode != null) ...['-c', compilationMode],
  ...extraArgs,
  ..._devFilesAspect,
];

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
  final args = bazelBuildArgs(
    target,
    compilationMode: compilationMode,
    extraArgs: extraArgs,
  );

  // Diagnostics + bazel's own output go to STDERR, never stdout: in
  // `--machine` mode the dev tool's stdout is the JSON protocol channel, and a
  // mid-session rebuild (refreshGenerated) would otherwise inject bazel chatter
  // into it.
  _logger.info({
    'message': 'bazel_command',
    'text': 'Running: bazel ${args.join(' ')}',
    'args': args,
    'workspace': workspace,
  });

  final process = await Process.start(
    'bazel',
    args,
    workingDirectory: workspace,
  );
  // Both of bazel's streams, each labelled, so a JSON consumer can tell them
  // apart.
  final out = SubprocessOutput(source: 'bazel', stream: 'stdout');
  final err = _TailedOutput(source: 'bazel', stream: 'stderr');
  final outSub = process.stdout.transform(utf8.decoder).listen(out.write);
  final errSub = process.stderr.transform(utf8.decoder).listen(err.write);
  final exitCode = await process.exitCode;
  await outSub.cancel();
  await errSub.cancel();
  out.close();
  err.close();

  // The tail travels with the result. A caller that turns this into a failure
  // has to be able to say what bazel said, and the streamed copy above is gone
  // by then — scrolled past in a terminal, and thousands of records back in a
  // machine client's log.
  if (exitCode != 0) {
    return BazelBuildResult(
      exitCode: exitCode,
      outputFiles: [],
      stderr: err.tail,
    );
  }

  // Query for output files with the same flags used for build.
  final cqueryArgs = ['cquery', target, '--output=files'];
  if (compilationMode != null) {
    cqueryArgs.addAll(['-c', compilationMode]);
  }
  cqueryArgs.addAll(extraArgs);
  final cqueryResult = await Process.run(
    'bazel',
    cqueryArgs,
    workingDirectory: workspace,
  );
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

/// Returns the label of the `flutter_application` target within [target]'s
/// dependency tree (e.g. `//:app`), or null if none is found.
///
/// The dev tool builds this label directly to materialize the
/// `flutter_application`'s `DefaultInfo` outputs (the hot-reload
/// `_dev_config.json` + dev `package_config.json`). Those live only in
/// `DefaultInfo`, which the platform wrapper (macOS/iOS/...) consumes via
/// providers, not files — so building the wrapper alone never produces them.
///
/// Throws [BazelInvocationFailure] when the query itself failed. Null is
/// reserved for the query having run and answered nothing: a `BUILD` file with
/// a typo in it must not be reported as "No flutter_application found in deps
/// of $target", which describes a target wired the wrong way and sends the
/// reader to rewrite a dependency list that is fine.
Future<String?> bazelCqueryFlutterAppLabel(
  String target, {
  required String workspace,
  String? compilationMode,
  List<String> extraArgs = const [],
}) async {
  final args = [
    'cquery',
    'kind("flutter_application", deps($target))',
    '--output=label',
  ];
  if (compilationMode != null) {
    args.addAll(['-c', compilationMode]);
  }
  args.addAll(extraArgs);
  final result = await Process.run('bazel', args, workingDirectory: workspace);
  if (result.exitCode != 0) {
    throw BazelInvocationFailure(
      command: args.join(' '),
      diagnostics: (result.stderr as String).trim(),
    );
  }
  for (final line in LineSplitter.split(result.stdout as String)) {
    final t = line.trim();
    if (t.startsWith('//') || t.startsWith('@')) {
      // cquery --output=label prints "<label> (<config hash>)"; keep the label.
      return t.split(' ').first;
    }
  }
  return null;
}

/// Every output file of the `flutter_application` inside [target]'s deps, in
/// [target]'s own configuration, as workspace-relative bazel paths.
///
/// The difference from `bazelBuild(<the flutter_application>).outputFiles`:
/// that call also ends in a cquery, and a cquery of a bare label lists the
/// target in *every* configuration the Bazel server happens to have analysed —
/// sometimes the top-level one alone, sometimes that plus the split-transition
/// one, in an order nothing guarantees. Asking through the launch target
/// instead makes the transitioned configuration the question rather than a
/// coincidence.
///
/// Returns a candidate *set*, not one path: an Android wrapper reaches the
/// application in several configurations at once, so which of them the running
/// app came from is settled by the app's own `BuildInfo.assetsDir`, not by
/// picking one here.
///
/// Paths are left workspace-relative on purpose — that is the form
/// `BuildInfo.assetsDir` is baked in, and comparing the two is the only reason
/// this exists.
Future<List<String>> bazelCqueryFlutterAppFiles(
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
  if (result.exitCode != 0) {
    throw DevToolException(
      'bazel cquery for the flutter_application inside $target failed:\n'
      '${result.stderr}',
    );
  }
  return [
    for (final line in LineSplitter.split(result.stdout as String))
      if (line.trim().isNotEmpty) line.trim(),
  ];
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
/// such as `?? '.'` would mask the failure.
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
