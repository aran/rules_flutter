/// Bazel invocation helpers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dev_tool_exception.dart';
import 'logging.dart';
import 'runfiles_helper.dart';

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

/// A bazel command that was stopped because the command running it is ending.
///
/// Not a failure, and deliberately not a [DevToolException]: nothing about the
/// build went wrong, and the run is already on its way out by a route that
/// decides its own exit status — a signal's `130`/`143`, or the `0` a
/// `daemon.shutdown` ends with. A caller that reported this as a failed build
/// would print "Build failed with exit code 8" for a Ctrl-C.
class BazelCancelled implements Exception {
  /// The bazel command, as the user would have typed it: `build //:app`.
  final String command;

  const BazelCancelled(this.command);

  @override
  String toString() => 'bazel $command was stopped: the run is shutting down.';
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

/// Starts the `bazel` client for [args], in [workingDirectory].
typedef BazelSpawn =
    Future<Process> Function(
      List<String> args, {
      required String workingDirectory,
    });

/// Asks a running bazel command to stop, the way a terminal's Ctrl-C does.
typedef BazelInterrupt = void Function(Process process);

/// One bazel command this tool started and has not seen end.
class _BazelCommand {
  final List<String> args;
  final Process process;

  /// Whether [Bazel.close] asked this command to stop. Decides what its caller
  /// is told, whatever status the command then exits with.
  bool stopped = false;

  final Completer<void> _read = Completer<void>();

  _BazelCommand(this.args, this.process);

  /// The command's exit status, or [BazelCancelled] if it was stopped.
  Future<int> get exited async {
    final exitCode = await process.exitCode;
    if (stopped) throw BazelCancelled(args.join(' '));
    return exitCode;
  }

  /// Completes once the command has exited *and* everything it printed has
  /// been read. What [Bazel.close] waits for: an interrupted bazel's last
  /// words — "Bazel caught terminate signal", "build interrupted" — follow its
  /// exit status down the pipe, and a run that ended on the status alone would
  /// drop the user's only confirmation that the build stopped.
  Future<void> get finished => _read.future;

  /// Called by whoever reads the command's output, once it has read it all.
  void markRead() {
    if (!_read.isCompleted) _read.complete();
  }
}

/// Every bazel command this tool runs, and the one way to stop them.
///
/// A dev-loop command runs bazel before it launches anything — `bazel info`,
/// a first `bazel fetch` of the toolchain, the launch build — and again on
/// reloads that regenerate code or rebuild assets. Any of those can be running
/// when the run is stopped, and a bazel command is not stopped by the tool that
/// started it exiting: measured, a build ran on for five seconds after the
/// tool had gone, to "Processing and signing app", and a `bazel` command issued
/// meanwhile printed `Another command (pid=…) is running` and waited behind it.
/// On a real project that is minutes of a build nobody wants, holding the
/// output base's lock against the rerun the user stopped the old run to make.
///
/// So every bazel command goes through here, and [close] — reached from the
/// run's [Teardown], and so from a signal and from `daemon.shutdown` alike —
/// interrupts the ones still running and waits for them to exit.
///
/// Interrupting means a signal to the command's *process group*, not to the
/// process this tool holds: that is usually bazelisk, which ignores SIGINT and
/// SIGTERM and counts on a terminal signalling the whole group
/// (`process_group_exec` explains the rest). SIGTERM rather than SIGINT because
/// the Bazel client counts interrupts: a third SIGINT makes it kill the Bazel
/// *server*, and a Ctrl-C the user presses on top of this one must not add up
/// to that. SIGTERM cancels the command the same way and is not counted.
///
/// The server itself is never touched. It belongs to the workspace, not to this
/// run — the user's own shells share it — and its analysis cache is what makes
/// the next run fast.
class Bazel {
  final BazelSpawn _spawn;

  /// Null for a bazel whose commands cannot be interrupted at all, and then
  /// [_cannotInterrupt] says why.
  final BazelInterrupt? _interrupt;

  /// Why a command cannot be interrupted, completing the sentence "… could not
  /// be interrupted, because …". Null exactly when [_interrupt] is not.
  final String? _cannotInterrupt;

  /// How long [close] waits for an interrupted command to exit before it
  /// reports it and moves on.
  final Duration _stopBound;

  /// Commands whose process exists and has not exited.
  final Set<_BazelCommand> _running = {};

  /// Commands whose process is still being created. [close] waits for these
  /// before it interrupts, so none comes into existence unowned.
  final Set<Future<void>> _starting = {};

  bool _closed = false;

  /// Enough for Bazel's own shutdown of an interrupted command: it gives a
  /// running local action `--local_termination_grace_seconds` (15 by default)
  /// to exit after its SIGTERM before it kills it.
  static const _defaultStopBound = Duration(seconds: 20);

  /// The `bazel` on `PATH`, stopped the way this process is able to stop it.
  ///
  /// As Bazel builds and bundles it, off Windows: every command starts in a
  /// process group of its own, through `process_group_exec`, and is
  /// interrupted through that group.
  ///
  /// Two situations have no group to signal, and each is a fact about how the
  /// tool was started rather than a guess, so the commands start directly and
  /// [close] says why it could not interrupt one that would not end:
  ///
  ///  * **Windows**, which has no process group a console process can be moved
  ///    into, and where nothing `dart:io` sends reaches the Bazel client behind
  ///    bazelisk. A console Ctrl-C still reaches it — every process on the
  ///    console receives one.
  ///  * **Running from source** (`dart run bin/flutter_bazel.dart`), the
  ///    contributor workflow, which has no runfiles tree and so none of the
  ///    helpers Bazel bundles. The commands share the terminal's process group,
  ///    so a Ctrl-C there reaches them as it would any shell pipeline.
  ///
  /// A runfiles tree without the helper in it is neither: that is a build that
  /// dropped a declared `data` dependency, and the first command fails loudly.
  factory Bazel() {
    if (Platform.isWindows) {
      return Bazel.uninterruptible(
        spawn: _spawnDirectly,
        because: 'Windows has no process group to signal it through',
      );
    }
    if (!hasRunfilesContext) {
      return Bazel.uninterruptible(
        spawn: _spawnDirectly,
        because:
            'flutter_bazel is running from source, without the '
            'process_group_exec a Bazel-built flutter_bazel stops it through',
      );
    }
    return Bazel.using(spawn: _spawnInGroup, interrupt: _interruptGroup);
  }

  /// Bazel commands started by [spawn] and stopped by [interrupt].
  Bazel.using({
    required BazelSpawn spawn,
    required BazelInterrupt interrupt,
    Duration stopBound = _defaultStopBound,
  }) : _spawn = spawn,
       _interrupt = interrupt,
       _cannotInterrupt = null,
       _stopBound = stopBound;

  /// Bazel commands started by [spawn] that nothing here can interrupt,
  /// [because] of what — completing "… could not be interrupted, because …".
  ///
  /// [close] still waits for them: something else may stop them (a console
  /// Ctrl-C reaches every process on the console), and the output base is
  /// released only when they exit.
  Bazel.uninterruptible({
    required BazelSpawn spawn,
    required String because,
    Duration stopBound = _defaultStopBound,
  }) : _spawn = spawn,
       _interrupt = null,
       _cannotInterrupt = because,
       _stopBound = stopBound;

  /// Run `bazel <args>` to completion and return everything it said.
  ///
  /// The shape of [BazelRunner], so it can be handed to
  /// `resolveToolchainPaths` directly.
  ///
  /// Throws [BazelCancelled] if [close] stopped it, or was called before it.
  Future<ProcessResult> run(
    List<String> args, {
    required String workingDirectory,
  }) async {
    final command = await _start(args, workingDirectory);
    // Drained from the moment the process exists: a command whose pipe fills
    // blocks on its next write and never exits.
    final stdout = command.process.stdout.transform(utf8.decoder).join();
    final stderr = command.process.stderr.transform(utf8.decoder).join();
    final int exitCode;
    try {
      exitCode = await command.exited;
    } finally {
      try {
        await Future.wait([stdout, stderr]);
      } finally {
        command.markRead();
      }
    }
    return ProcessResult(
      command.process.pid,
      exitCode,
      await stdout,
      await stderr,
    );
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
  ///
  /// Throws [BazelCancelled] if [close] stopped it.
  Future<BazelBuildResult> build(
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
    // `--machine` mode the dev tool's stdout is the JSON protocol channel, and
    // a mid-session rebuild (refreshGenerated) would otherwise inject bazel
    // chatter into it.
    _logger.info({
      'message': 'bazel_command',
      'text': 'Running: bazel ${args.join(' ')}',
      'args': args,
      'workspace': workspace,
    });

    final command = await _start(args, workspace);
    // Both of bazel's streams, each labelled, so a JSON consumer can tell them
    // apart.
    final out = SubprocessOutput(source: 'bazel', stream: 'stdout');
    final err = _TailedOutput(source: 'bazel', stream: 'stderr');
    // Read to their end rather than cancelled at exit: the exit status and the
    // last of the output arrive separately, and the last lines are the ones
    // that say why a build failed.
    final streamed = Future.wait([
      command.process.stdout.transform(utf8.decoder).forEach(out.write),
      command.process.stderr.transform(utf8.decoder).forEach(err.write),
    ]);
    final int exitCode;
    try {
      exitCode = await command.exited;
    } finally {
      try {
        await streamed;
      } finally {
        out.close();
        err.close();
        command.markRead();
      }
    }

    // The tail travels with the result. A caller that turns this into a
    // failure has to be able to say what bazel said, and the streamed copy
    // above is gone by then — scrolled past in a terminal, and thousands of
    // records back in a machine client's log.
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
    final cqueryResult = await run(cqueryArgs, workingDirectory: workspace);
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
  /// reserved for the query having run and answered nothing: a `BUILD` file
  /// with a typo in it must not be reported as "No flutter_application found in
  /// deps of $target", which describes a target wired the wrong way and sends
  /// the reader to rewrite a dependency list that is fine.
  Future<String?> cqueryFlutterAppLabel(
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
    final result = await run(args, workingDirectory: workspace);
    if (result.exitCode != 0) {
      throw BazelInvocationFailure(
        command: args.join(' '),
        diagnostics: (result.stderr as String).trim(),
      );
    }
    for (final line in LineSplitter.split(result.stdout as String)) {
      final t = line.trim();
      if (t.startsWith('//') || t.startsWith('@')) {
        // cquery --output=label prints "<label> (<config hash>)"; keep the
        // label.
        return t.split(' ').first;
      }
    }
    return null;
  }

  /// Every output file of the `flutter_application` inside [target]'s deps, in
  /// [target]'s own configuration, as workspace-relative bazel paths.
  ///
  /// The difference from `build(<the flutter_application>).outputFiles`: that
  /// call also ends in a cquery, and a cquery of a bare label lists the target
  /// in *every* configuration the Bazel server happens to have analysed —
  /// sometimes the top-level one alone, sometimes that plus the
  /// split-transition one, in an order nothing guarantees. Asking through the
  /// launch target instead makes the transitioned configuration the question
  /// rather than a coincidence.
  ///
  /// Returns a candidate *set*, not one path: an Android wrapper reaches the
  /// application in several configurations at once, so which of them the
  /// running app came from is settled by the app's own `BuildInfo.assetsDir`,
  /// not by picking one here.
  ///
  /// Paths are left workspace-relative on purpose — that is the form
  /// `BuildInfo.assetsDir` is baked in, and comparing the two is the only
  /// reason this exists.
  Future<List<String>> cqueryFlutterAppFiles(
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
    final result = await run(args, workingDirectory: workspace);
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

    final cwd = Directory.current.path;
    final result = await run(['info', 'workspace'], workingDirectory: cwd);
    if (result.exitCode != 0) {
      throw StateError(
        'Could not determine workspace root: BUILD_WORKSPACE_DIRECTORY is '
        'unset (so this binary was not invoked via `bazel run`) and '
        '`bazel info workspace` failed (exit ${result.exitCode}) from cwd '
        '$cwd:\n${result.stderr}',
      );
    }
    return (result.stdout as String).trim();
  }

  /// Interrupt every bazel command still running, wait for each to exit, and
  /// refuse any started after this.
  ///
  /// Waits because the output base is released when bazel exits, not when it
  /// is asked to stop: a run that returned first would hand the user back a
  /// workspace whose next bazel command waits behind this one. The wait is
  /// bounded — past it the command is reported and left to finish stopping on
  /// its own, since it has already been told to.
  ///
  /// Idempotent. The callers of the stopped commands get [BazelCancelled].
  Future<void> close() async {
    _closed = true;
    // A command still being created has no process to interrupt yet. Every
    // start is either in here or already in [_running]: nothing awaits
    // between [_start]'s check of [_closed] and its registering the start.
    await Future.wait(_starting);
    final running = List.of(_running);
    for (final command in running) {
      // A second close finds these already stopped, and only waits.
      if (command.stopped) continue;
      command.stopped = true;
      final interrupt = _interrupt;
      if (interrupt == null) continue;
      _logger.info({
        'message': 'bazel_interrupted',
        'text': 'Stopping `bazel ${command.args.join(' ')}`...',
        'args': command.args,
        // Also the id of the process group the signal goes to.
        'pid': command.process.pid,
      });
      interrupt(command.process);
    }
    await Future.wait(running.map(_awaitFinished));
  }

  Future<void> _awaitFinished(_BazelCommand command) async {
    final finished = await command.finished
        .then((_) => true)
        .timeout(_stopBound, onTimeout: () => false);
    if (finished) return;
    final what = '`bazel ${command.args.join(' ')}`';
    final waited = '${_stopBound.inMilliseconds}ms';
    _logger.warning({
      'message': 'bazel_stop_timed_out',
      'text': _cannotInterrupt == null
          ? '$what was interrupted but had not ended $waited later. It is '
                'left to finish stopping; until it does, other bazel commands '
                'in this workspace wait for it.'
          : '$what could not be interrupted, because $_cannotInterrupt, and '
                'was still running $waited later. It is left to finish; until '
                'it does, other bazel commands in this workspace wait for it.',
      'args': command.args,
      'pid': command.process.pid,
    });
  }

  Future<_BazelCommand> _start(
    List<String> args,
    String workingDirectory,
  ) async {
    if (_closed) throw BazelCancelled(args.join(' '));
    // Registered as running inside the spawn's own continuation, before
    // anything awaiting the spawn resumes — [close] included.
    final started = _spawn(args, workingDirectory: workingDirectory).then((
      process,
    ) {
      final command = _BazelCommand(args, process);
      _running.add(command);
      unawaited(process.exitCode.then((_) => _running.remove(command)));
      return command;
    });
    // [close] waits on the start, not on its outcome: a spawn that throws
    // reaches this command's own caller below, which is where it is reported.
    final settled = started.then<void>((_) {}, onError: (Object _) {});
    _starting.add(settled);
    try {
      return await started;
    } finally {
      _starting.remove(settled);
    }
  }
}

/// Where `process_group_exec` is, once asked for.
String? _processGroupExec;

Future<Process> _spawnInGroup(
  List<String> args, {
  required String workingDirectory,
}) {
  final exec = _processGroupExec ??= _resolveProcessGroupExec();
  return Process.start(exec, [
    'bazel',
    ...args,
  ], workingDirectory: workingDirectory);
}

String _resolveProcessGroupExec() {
  const key = 'rules_flutter/tools/dev_tool/process_group_exec';
  final path = resolveRunfile(key);
  if (path == null) {
    // A runfiles tree exists (see [Bazel.new]), so this is not the tool
    // running from source: a declared `data` dependency did not make it in.
    throw DevToolException(
      'flutter_bazel starts every bazel command through the process_group_exec '
      'it bundles ($key), and its runfiles do not have it. The build that '
      'produced this flutter_bazel dropped a declared data dependency; rebuild '
      'it with `bazel build @rules_flutter//tools/dev_tool:flutter_bazel`.',
    );
  }
  return path;
}

Future<Process> _spawnDirectly(
  List<String> args, {
  required String workingDirectory,
}) => Process.start('bazel', args, workingDirectory: workingDirectory);

/// Signal the command's whole process group. The pid is the group's id,
/// because `process_group_exec` made the program the leader of its own group.
///
/// The result is not read: `false` means the group has already gone, which is
/// the outcome being asked for, and the wait that follows sees the exit.
void _interruptGroup(Process process) =>
    Process.killPid(-process.pid, ProcessSignal.sigterm);

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
