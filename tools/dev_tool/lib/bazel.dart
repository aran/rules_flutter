/// Bazel invocation helpers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'child_processes.dart';
import 'dev_tool_exception.dart';
import 'launch_bundle_parts.dart';
import 'local_packages.dart';
import 'logging.dart';
import 'phase_log.dart';
import 'process_group.dart';
import 'runfiles_helper.dart';
import 'web_bundle_facts.dart';

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

  /// The files of each group of the bundle parts the build was asked for (see
  /// [Bazel.build]'s `parts`), by group name; empty when it was asked for none.
  final Map<String, List<String>> partsFiles;

  /// The options that decided the build's module graph (see
  /// [moduleGraphFlagsFromBuildEvents]), when [Bazel.build] was asked to
  /// record them; empty otherwise.
  final List<String> moduleGraphFlags;

  BazelBuildResult({
    required this.exitCode,
    required this.outputFiles,
    required this.stderr,
    this.partsFiles = const {},
    this.moduleGraphFlags = const [],
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

/// What [Bazel.buildAspectOutputs] built.
class BazelAspectOutputs {
  final int exitCode;

  /// Every file in the requested group, absolute.
  final List<String> files;

  /// The files of every group asked for, by group name; [files] is the first
  /// one's. Empty for a result built without groups to name.
  final Map<String, List<String>> filesByGroup;

  /// The directory the build ran actions in, which paths an aspect's manifests
  /// name are relative to. Null when the build failed.
  final String? executionRoot;

  /// The tail of the build's output when it failed.
  final String stderr;

  /// The options that decided this build's module graph (see
  /// [moduleGraphFlagsFromBuildEvents]). Empty when the build failed.
  final List<String> moduleGraphFlags;

  const BazelAspectOutputs({
    required this.exitCode,
    required this.files,
    required this.executionRoot,
    required this.stderr,
    this.filesByGroup = const {},
    this.moduleGraphFlags = const [],
  });

  bool get success => exitCode == 0;
}

/// The files [aspect] put in [outputGroup], read from a build's JSON event
/// stream (`--build_event_json_file`).
///
/// An aspect's completion names its output groups by file-set id, and a file
/// set lists files plus further sets, so the files are the closure of those
/// ids.
///
/// Each file is located by the path the event gives it under the execution
/// root (`pathPrefix` + `name`), and the root by the build's `workspaceInfo`.
/// Never by `uri`: with a remote cache, Bazel reports a file by its address in
/// that cache (`bytestream://…`) whether or not it also downloaded it, so a
/// `uri` says where the bytes can be fetched from, not where they sit here.
///
/// Throws [DevToolException] when the group holds files and the stream names no
/// execution root to find them under.
BazelAspectOutputs aspectOutputsFromBuildEvents(
  String events, {
  required String aspect,
  required String outputGroup,
  List<String> otherGroups = const [],
}) {
  final sets = <String, Map<String, Object?>>{};
  final groupNames = [outputGroup, ...otherGroups];
  final roots = {for (final name in groupNames) name: <String>[]};
  String? executionRoot;
  for (final line in LineSplitter.split(events)) {
    if (line.trim().isEmpty) continue;
    final event = jsonDecode(line) as Map<String, Object?>;
    final id = event['id'] as Map<String, Object?>? ?? const {};
    final namedSet = id['namedSet'] as Map<String, Object?>?;
    if (namedSet != null) {
      sets[namedSet['id'] as String] =
          event['namedSetOfFiles'] as Map<String, Object?>? ?? const {};
      continue;
    }
    final workspaceInfo = event['workspaceInfo'] as Map<String, Object?>?;
    if (workspaceInfo != null) {
      executionRoot = workspaceInfo['localExecRoot'] as String?;
      continue;
    }
    final completed = id['targetCompleted'] as Map<String, Object?>?;
    // Matched on the aspect's own name: the event spells the repository in
    // its canonical form (`@@rules_flutter+//…`), which is not what was passed.
    final completedAspect = completed?['aspect'] as String?;
    if (completedAspect == null ||
        completedAspect.split('%').last != aspect.split('%').last) {
      continue;
    }
    final groups =
        (event['completed'] as Map<String, Object?>?)?['outputGroup']
            as List? ??
        const [];
    for (final group in groups.cast<Map<String, Object?>>()) {
      final into = roots[group['name']];
      if (into == null) continue;
      for (final set in (group['fileSets'] as List? ?? const [])) {
        into.add((set as Map<String, Object?>)['id'] as String);
      }
    }
  }

  Set<String> closure(List<String> from) {
    final relative = <String>{};
    final seen = <String>{};
    final pending = [...from];
    while (pending.isNotEmpty) {
      final setId = pending.removeLast();
      if (!seen.add(setId)) continue;
      final set = sets[setId] ?? const {};
      for (final file in (set['files'] as List? ?? const [])) {
        final entry = file as Map<String, Object?>;
        final prefix = (entry['pathPrefix'] as List? ?? const [])
            .cast<String>();
        relative.add([...prefix, entry['name'] as String].join('/'));
      }
      for (final nested in (set['fileSets'] as List? ?? const [])) {
        pending.add((nested as Map<String, Object?>)['id'] as String);
      }
    }
    return relative;
  }

  final byGroup = {
    for (final entry in roots.entries) entry.key: closure(entry.value),
  };
  if (byGroup.values.any((files) => files.isNotEmpty) &&
      executionRoot == null) {
    throw DevToolException(
      'The build event stream of the $outputGroup build named '
      '${byGroup.values.expand((f) => f).toSet().length} file(s) and no '
      'execution root (its `workspaceInfo` event), so none of them can be '
      'found.',
    );
  }
  List<String> absolute(Set<String> relative) => [
    for (final path in relative) '$executionRoot/$path',
  ]..sort();
  final filesByGroup = {
    for (final entry in byGroup.entries) entry.key: absolute(entry.value),
  };
  return BazelAspectOutputs(
    exitCode: 0,
    files: filesByGroup[outputGroup]!,
    filesByGroup: filesByGroup,
    executionRoot: executionRoot,
    stderr: '',
  );
}

/// The options that change which repository a module or repository name
/// resolves to, and that `bazel mod` takes.
const _moduleGraphOptions = {
  'allow_yanked_versions',
  'enable_bzlmod',
  'ignore_dev_dependency',
  'inject_repository',
  'lockfile_mode',
  'override_module',
  'override_repository',
  'registry',
  'repo_env',
  'vendor_dir',
};

/// Of the options a build ran with, those that decided its module graph, in
/// order, from its JSON event stream (`--build_event_json_file`).
///
/// Read from the `canonical` command line, which is the build's options after
/// Bazel expanded every `--config` and read every rc file: an override a
/// `build:<name>` line turns on is there as the `--override_module` it is.
/// Passed to `bazel mod` as they are, they make it resolve the graph that
/// build resolved, which no `--config` can, since `bazel mod` reads only a
/// config's `common` and `mod` lines and refuses one that has neither.
///
/// Throws [DevToolException] when the stream has no canonical command line.
List<String> moduleGraphFlagsFromBuildEvents(String events) {
  for (final line in LineSplitter.split(events)) {
    if (line.trim().isEmpty) continue;
    final event = jsonDecode(line) as Map<String, Object?>;
    final commandLine = event['structuredCommandLine'] as Map<String, Object?>?;
    if (commandLine == null || commandLine['commandLineLabel'] != 'canonical') {
      continue;
    }
    return [
      for (final section in (commandLine['sections'] as List? ?? const []))
        if ((section as Map<String, Object?>)['sectionLabel'] ==
            'command options')
          for (final option
              in ((section['optionList'] as Map<String, Object?>?)?['option']
                      as List? ??
                  const []))
            if (_moduleGraphOptions.contains(
              (option as Map<String, Object?>)['optionName'],
            ))
              option['combinedForm'] as String,
    ];
  }
  throw DevToolException(
    'The build event stream has no canonical command line, so the options '
    'that decided the build\'s module graph are unknown.',
  );
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

/// Maps `--dart-define KEY=VALUE` values to the rules_dart build-setting
/// flags every bazel invocation (build AND cquery) must carry so they all
/// resolve in the same configuration.
///
/// The flag is repeatable: one occurrence per define, so values containing
/// commas survive intact.
List<String> dartDefineFlags(List<String> dartDefines) => [
  for (final define in dartDefines)
    '--@rules_dart//dart:extra_dart_defines=$define',
];

/// The cquery [Bazel.cqueryExtraDartDefines] runs, but for the options.
///
/// `config(…, target)` keeps the answer to the top-level configuration, the one
/// a build's own flags make. Starlark flags are keyed by their canonical label in
/// `build_options`, which is the setting's own `str(target.label)`; one that is
/// at its default is not there at all.
const extraDartDefinesQuery = [
  'cquery',
  'config(@rules_dart//dart:extra_dart_defines, target)',
  '--output=starlark',
  '--starlark:expr=json.encode(build_options(target).get(str(target.label), []))',
];

/// The defines [extraDartDefinesQuery] printed: one JSON list of strings.
List<String> extraDartDefinesFrom(String stdout) {
  final lines = [
    for (final line in LineSplitter.split(stdout))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (lines.length == 1) {
    final decoded = jsonDecode(lines.single);
    if (decoded is List && decoded.every((d) => d is String)) {
      return decoded.cast<String>();
    }
  }
  throw DevToolException(
    'bazel cquery for the value of --@rules_dart//dart:extra_dart_defines '
    'printed something other than one list of defines:\n$stdout',
  );
}

/// Maps `--config` values to the `--config=<name>` flags every bazel
/// invocation of a run must carry. Bazel reads the named config out of the
/// workspace's own `.bazelrc` files; this tool never parses them.
List<String> bazelConfigFlags(List<String> configs) => [
  for (final config in configs) '--config=$config',
];

/// Compiles into a debug app what this tool needs to drive it: the service
/// extensions, native hot patching and `rules_flutter.build_info`.
///
/// On by default, but a `.bazelrc` can turn it off for builds no dev tool runs,
/// and an app built without it cannot be driven, reloaded or attached to.
const devToolSupportFlag = '--@rules_flutter//flutter:dev_tool_support=true';

/// The flags every bazel command this tool runs for the app carries: the
/// user's `--config`s, then their `--build-arg`s, then [devToolSupportFlag].
///
/// The configs come first so an explicit `--build-arg` overrides what a config
/// sets, as it would on a bazel command line. [devToolSupportFlag] comes last
/// so that nothing the user passes, and no `.bazelrc`, turns it off. It is on
/// every command, not only the builds: a query of the build's outputs has to
/// ask about the configuration the build made, and a setting at its default
/// leaves that configuration as it was.
List<String> devToolBazelFlags({
  required List<String> configs,
  required List<String> buildArgs,
}) => [...bazelConfigFlags(configs), ...buildArgs, devToolSupportFlag];

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
const devFilesAspect =
    '@rules_flutter//flutter:dev_files.bzl%flutter_dev_files_aspect';

/// The output group [devFilesAspect] fills: the `flutter_application`'s own
/// outputs, in each configuration the launch target reaches it in.
const devFilesGroup = 'flutter_dev_files';

const _devFilesAspect = [
  '--aspects=$devFilesAspect',
  '--output_groups=+$devFilesGroup',
];

/// The argv for a `bazel build` this dev tool runs.
///
/// The aspect flags go last. `--output_groups=+name` is additive and a
/// repeated aspect is applied once, so nothing here overrides what the caller
/// passed as `--build-arg`.
///
/// [parts] adds the groups a restart reads of the bundle (see
/// [LaunchBundleParts]), for the launch build, whose parts are the baseline a
/// restart compares against.
List<String> bazelBuildArgs(
  String target, {
  String? compilationMode,
  List<String> extraArgs = const [],
  LaunchBundleParts? parts,
}) => [
  'build',
  target,
  if (compilationMode != null) ...['-c', compilationMode],
  ...extraArgs,
  ..._devFilesAspect,
  if (parts != null) ...[
    '--aspects=${parts.aspect}',
    '--output_groups=+${parts.assetsGroup},+${parts.nativeLibsGroup}',
  ],
];

/// Starts the `bazel` client for [args], in [workingDirectory].
typedef BazelSpawn = Future<Process> Function(
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
/// the first analysis, which fetches the toolchain, the launch build — and
/// again on reloads that regenerate code or rebuild assets. Any of those can be
/// running when the run is stopped, and a bazel command is not stopped by the
/// tool that started it exiting: measured, a build ran on for five seconds
/// after the tool had gone, to "Processing and signing app", and a `bazel`
/// command issued meanwhile printed `Another command (pid=…) is running` and
/// waited behind it. On a real project that is minutes of a build nobody wants,
/// holding the output base's lock against the rerun the user stopped the old
/// run to make.
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
  /// Output files come from `bazel cquery 'config(<target>, target)'
  /// --output=files` — the outputs the target rule declares, in the one
  /// configuration this build put it in. A cquery of the bare label lists the
  /// target in every configuration the server has analysed: once a launch
  /// build has reached a `flutter_application` through its platform
  /// transition, that is the transitioned instance as well, listed first and
  /// on disk, and its files are ones this build never rewrites.
  ///
  /// [recordModuleGraph] reads [BazelBuildResult.moduleGraphFlags] off the
  /// build's event stream.
  ///
  /// Throws [BazelCancelled] if [close] stopped it.
  Future<BazelBuildResult> build(
    String target, {
    required String workspace,
    String? compilationMode,
    List<String> extraArgs = const [],
    LaunchBundleParts? parts,
    bool recordModuleGraph = false,
  }) async {
    // The parts are an aspect's outputs, which no cquery lists, so they are
    // read from the build's own event stream, as the options are.
    final events = parts == null && !recordModuleGraph
        ? null
        : await Directory.systemTemp.createTemp('flutter_bep_');
    try {
      return await _build(
        target,
        workspace: workspace,
        compilationMode: compilationMode,
        extraArgs: extraArgs,
        parts: parts,
        recordModuleGraph: recordModuleGraph,
        eventFile: events == null ? null : '${events.path}/events.json',
      );
    } finally {
      await events?.delete(recursive: true);
    }
  }

  Future<BazelBuildResult> _build(
    String target, {
    required String workspace,
    required String? compilationMode,
    required List<String> extraArgs,
    required LaunchBundleParts? parts,
    required bool recordModuleGraph,
    required String? eventFile,
  }) async {
    final args = [
      ...bazelBuildArgs(
        target,
        compilationMode: compilationMode,
        extraArgs: extraArgs,
        parts: parts,
      ),
      if (eventFile != null) '--build_event_json_file=$eventFile',
    ];

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

    final built = await _timed(
      phase: 'bazel build',
      target: target,
      what: 'bazel build $target',
      body: () => _streamed(args, workspace),
      detail: (r) => ' (exit ${r.exitCode})',
    );
    if (built.exitCode != 0) {
      return BazelBuildResult(
        exitCode: built.exitCode,
        outputFiles: [],
        stderr: built.tail,
      );
    }

    // Query for output files with the same flags used for build.
    final cqueryArgs = ['cquery', 'config($target, target)', '--output=files'];
    if (compilationMode != null) {
      cqueryArgs.addAll(['-c', compilationMode]);
    }
    cqueryArgs.addAll(extraArgs);
    final cqueryResult = await _timed(
      phase: 'bazel query',
      target: target,
      what: 'bazel query of $target outputs',
      announce: true,
      body: () => run(cqueryArgs, workingDirectory: workspace),
    );
    final outputFiles = _absolutizeCqueryPaths(
      cqueryResult.stdout as String,
      workspace,
    );

    final stream = eventFile == null
        ? null
        : await File(eventFile).readAsString();
    return BazelBuildResult(
      exitCode: built.exitCode,
      outputFiles: outputFiles,
      stderr: cqueryResult.stderr as String,
      partsFiles: parts == null || stream == null
          ? const {}
          : aspectOutputsFromBuildEvents(
              stream,
              aspect: parts.aspect,
              outputGroup: parts.assetsGroup,
              otherGroups: [parts.nativeLibsGroup],
            ).filesByGroup,
      moduleGraphFlags: recordModuleGraph
          ? moduleGraphFlagsFromBuildEvents(stream!)
          : const [],
    );
  }

  /// Build the output group an [aspect] adds to [target], and [otherGroups] it
  /// fills too, and return their files.
  ///
  /// The files come from the build's own event stream, not from a cquery: a
  /// cquery lists a target's outputs and never an aspect's, and it re-runs
  /// analysis with options of its own. The stream also carries where each
  /// output sits under the execution root, which is the one directory an
  /// aspect's consumers can resolve every path it hands them against.
  ///
  /// Throws [BazelCancelled] if [close] stopped it.
  Future<BazelAspectOutputs> buildAspectOutputs(
    String target, {
    required String workspace,
    required String aspect,
    required String outputGroup,
    List<String> otherGroups = const [],
    String? compilationMode,
    List<String> extraArgs = const [],
  }) async {
    final events = await Directory.systemTemp.createTemp('flutter_bep_');
    try {
      final eventFile = '${events.path}/events.json';
      // Not [bazelBuildArgs]: the group replaces the default outputs rather
      // than adding to them (`--output_groups=<name>`, no `+`), and the dev
      // files aspect stays off. Either would make this build the launch
      // target's own bundle and the app's kernel — on Android an APK repackage
      // — when all that was asked for is what the aspect collects.
      final args = [
        'build',
        target,
        if (compilationMode != null) ...['-c', compilationMode],
        ...extraArgs,
        '--aspects=$aspect',
        '--output_groups=${[outputGroup, ...otherGroups].join(',')}',
        // The caller reads these files from disk, and a build without the
        // bytes keeps whatever it was not asked for in the remote cache. The
        // group is this build's only top-level output, so this downloads it
        // and nothing else. Without a remote cache it does nothing, and
        // switching it does not discard the analysis cache.
        '--remote_download_toplevel',
        '--build_event_json_file=$eventFile',
      ];
      _logger.info({
        'message': 'bazel_command',
        'text': 'Running: bazel ${args.join(' ')}',
        'args': args,
        'workspace': workspace,
      });
      final built = await _timed(
        phase: 'bazel build',
        target: target,
        what: 'bazel build $target ($outputGroup)',
        body: () => _streamed(args, workspace),
        detail: (r) => ' (exit ${r.exitCode})',
      );
      if (built.exitCode != 0) {
        return BazelAspectOutputs(
          exitCode: built.exitCode,
          files: const [],
          executionRoot: null,
          stderr: built.tail,
        );
      }
      final stream = await File(eventFile).readAsString();
      final outputs = aspectOutputsFromBuildEvents(
        stream,
        aspect: aspect,
        outputGroup: outputGroup,
        otherGroups: otherGroups,
      );
      return BazelAspectOutputs(
        exitCode: outputs.exitCode,
        files: outputs.files,
        filesByGroup: outputs.filesByGroup,
        executionRoot: outputs.executionRoot,
        stderr: outputs.stderr,
        moduleGraphFlags: moduleGraphFlagsFromBuildEvents(stream),
      );
    } finally {
      await events.delete(recursive: true);
    }
  }

  /// Run [body], a bazel invocation, and say how long it took.
  ///
  /// A reload that stalls inside bazel and one that stalls in the query after
  /// it look the same without this: the build prints a line when it starts and
  /// nothing when it ends. [announce] adds a line at the start, for an
  /// invocation that does not print its own command. Observation only: the
  /// result is [body]'s own, and a failure is rethrown unchanged.
  Future<R> _timed<R>({
    required String phase,
    required String target,
    required String what,
    required Future<R> Function() body,
    bool announce = false,
    String Function(R result)? detail,
  }) async {
    final clock = Stopwatch()..start();
    void say(String event, String text) => _logger.info({
      'message': 'bazel_phase',
      'text': text,
      'phase': phase,
      'event': event,
      'target': target,
      'ms': clock.elapsedMilliseconds,
    });
    if (announce) say('started', 'Running $what');
    try {
      final result = await body();
      say(
        'finished',
        '$what finished in ${formatElapsed(clock.elapsed)}'
            '${detail?.call(result) ?? ''}',
      );
      return result;
    } on BazelCancelled {
      // A deliberate stop is not a failure: the run is ending and asked bazel
      // to end with it.
      say(
        'stopped',
        '$what stopped after ${formatElapsed(clock.elapsed)}: '
            'the run is shutting down',
      );
      rethrow;
    } catch (e) {
      say(
        'failed',
        '$what failed after ${formatElapsed(clock.elapsed)}: $e',
      );
      rethrow;
    }
  }

  /// Run a build to completion with both of bazel's streams relayed as they
  /// arrive, and keep the tail of stderr for a failure to quote.
  Future<({int exitCode, String tail})> _streamed(
    List<String> args,
    String workspace,
  ) async {
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
    return (exitCode: exitCode, tail: err.tail);
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
  /// call lists the application in the top-level configuration only, which is
  /// the one the dev tool builds it in and never the one a platform rule's
  /// transition launched. Asking through the launch target makes the
  /// transitioned configuration the question.
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

  /// The value Bazel's options give `--@rules_dart//dart:extra_dart_defines`
  /// in the configuration [compilationMode] and [extraArgs] make, with every
  /// `.bazelrc` line applied: what a build in exactly those options compiles
  /// with.
  ///
  /// A cquery in the options of the build after it, so asking keeps Bazel's
  /// analysis cache.
  Future<List<String>> cqueryExtraDartDefines({
    required String workspace,
    String? compilationMode,
    List<String> extraArgs = const [],
  }) async {
    final args = [
      ...extraDartDefinesQuery,
      if (compilationMode != null) ...['-c', compilationMode],
      ...extraArgs,
    ];
    final result = await run(args, workingDirectory: workspace);
    if (result.exitCode != 0) {
      throw BazelInvocationFailure(
        command: args.join(' '),
        diagnostics: (result.stderr as String).trim(),
      );
    }
    return extraDartDefinesFrom(result.stdout as String);
  }

  /// What the web bundle [target] names says about itself, or null when
  /// [target] is not, and does not alias, a single `flutter_web_bundle`. See
  /// [WebBundleFacts].
  ///
  /// Asked in the configuration the run builds in ([compilationMode] and
  /// [extraArgs]), so the answer is the one the build will act on.
  Future<WebBundleFacts?> cqueryWebBundleFacts(
    String target, {
    required String workspace,
    String? compilationMode,
    List<String> extraArgs = const [],
  }) async {
    final args = [
      ...webBundleFactsQuery(target),
      if (compilationMode != null) ...['-c', compilationMode],
      ...extraArgs,
    ];
    final result = await run(args, workingDirectory: workspace);
    if (result.exitCode != 0) {
      throw DevToolException(
        'bazel could not read how $target is configured, which decides the '
        'web dev loop it runs under:\n'
        '  bazel ${args.join(' ')}\n'
        '${(result.stderr as String).trim()}',
      );
    }
    try {
      return parseWebBundleFacts(result.stdout as String);
    } on FormatException catch (e) {
      throw DevToolException(
        'bazel cquery answered something unreadable about $target: '
        '${e.message}',
      );
    }
  }

  /// The labels of the web bundles built over [target], for naming them to a
  /// run that was handed the application instead. Empty when there are none or
  /// the query fails: the run is already failing, and its message says how to
  /// ask by hand.
  Future<List<String>> queryWebBundlesOver(
    String target, {
    required String workspace,
  }) async {
    final labelArgs = ['query', target, '--output=label', '--noshow_progress'];
    final labelResult = await run(labelArgs, workingDirectory: workspace);
    if (labelResult.exitCode != 0) return const [];
    final label = (labelResult.stdout as String).trim();
    final result = await run(
      webBundlesOverQuery(label),
      workingDirectory: workspace,
    );
    if (result.exitCode != 0) return const [];
    return parseWebBundlesOver(result.stdout as String);
  }

  /// Which of [repos] (canonical names) are local repositories, and the
  /// directory each one is: see `local_packages.dart`.
  ///
  /// [moduleGraphFlags] are the options that decided the module graph of the
  /// build the app came from, read off its event stream; see [showRepoArgs].
  ///
  /// Throws [BazelInvocationFailure] when Bazel cannot say: the answer decides
  /// which edits a reload can see, and guessing it would drop some silently.
  Future<Map<String, String>> localRepositories(
    Iterable<String> repos, {
    required String workspace,
    required List<String> moduleGraphFlags,
  }) async {
    if (repos.isEmpty) return const {};
    final args = showRepoArgs(repos, moduleGraphFlags: moduleGraphFlags);
    final result = await run(args, workingDirectory: workspace);
    if (result.exitCode != 0) {
      throw BazelInvocationFailure(
        command: args.take(2).join(' '),
        diagnostics: result.stderr as String,
      );
    }
    return parseLocalRepositories(
      result.stdout as String,
      workspace: workspace,
    );
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

Future<Process> _spawnInGroup(
  List<String> args, {
  required String workingDirectory,
}) => startInProcessGroup(
  'bazel',
  args,
  binary: '@rules_flutter//tools/dev_tool:flutter_bazel',
  workingDirectory: workingDirectory,
);

Future<Process> _spawnDirectly(
  List<String> args, {
  required String workingDirectory,
}) => startChildProcess('bazel', args, workingDirectory: workingDirectory);

/// Signal the command's whole process group.
void _interruptGroup(Process process) =>
    signalProcessGroup(process, ProcessSignal.sigterm);

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
