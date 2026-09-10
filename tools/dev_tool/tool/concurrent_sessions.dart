/// Drives two `flutter_bazel run` sessions against ONE workspace and reports
/// whether they break each other.
///
/// ```sh
/// dart run tools/dev_tool/tool/concurrent_sessions.dart pair             # two sessions
/// dart run tools/dev_tool/tool/concurrent_sessions.dart solo             # one, control
/// dart run tools/dev_tool/tool/concurrent_sessions.dart pair 3 hello_world
/// ```
///
/// The third argument picks the workspace, and which one matters: the two
/// sessions collide over *every* file they both read out of the output base,
/// and the workspaces differ in how many of those there are.
///
///  * `codegen` compiles `.g.dart` files that live in `bazel-out`, so every
///    edit makes both sessions run `bazel build` — which is what puts one
///    session's build under the other's compile. This is the one that
///    reproduces.
///  * `hello_world` has no codegen, so its reload loop never runs Bazel at all
///    (`ReloadPipeline.refreshGenerated` is null) and the two sessions have
///    nothing to collide over. It is the negative control — a workspace where
///    the same two sessions are genuinely safe — not a second reproduction.
///
/// ## The mechanism it exercises
///
/// Bazel plants a symlink forest at `<output_base>/execroot/_main/external/`,
/// one entry per repository the *current* command needs, and re-plants it on
/// every command. The frontend_server reads the Flutter SDK's sources through
/// that forest, so a Bazel command run by anyone else deletes those symlinks
/// out from under a live compile. The repository tree at
/// `<output_base>/external/` never churns, only its per-command forest.
///
/// Two sessions make that overlap near-certain rather than occasional, because
/// Bazel's own per-output-base command lock hands off from one session's build
/// directly into the other's compile: both sessions watch the same tree, so one
/// edit wakes both, and the loser of the lock starts executing actions at the
/// moment the winner starts compiling.
///
/// There are two such shared reads, and they fail differently. One is the
/// repository forest above; the other is the app's own generated sources, which
/// Bazel deletes before re-running the action that writes them, and which the
/// peer session reads through `--filesystem-root` as
/// `org-dartlang-app:///…/catalog.g.dart`. Read the `compiler said:` line to
/// tell which one a failure is — they are indistinguishable from the reload
/// verdict alone.
///
/// The race is timing-dependent, so read a passing `pair` as "the collision did
/// not happen in this run", not as "it cannot".
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What to run, and the edit that provokes a reload in it.
///
/// Every marker here is one `watch_reload_e2e_test.dart` already proves is a
/// legal hot reload. A probe that is itself an illegal reload — renaming a
/// field of a const-instantiated class, say — fails identically in `solo` and
/// `pair` and proves nothing about concurrency.
class _Fixture {
  final String workspace;
  final String target;

  /// Workspace-relative source to edit, and the text replaced in it.
  final String probeFile;
  final String marker;

  const _Fixture(this.workspace, this.target, this.probeFile, this.marker);
}

const _fixtures = <String, _Fixture>{
  // A codegen INPUT: every edit re-runs the `dart_codegen` action, so the peer
  // session's build has real work to do rather than reporting a cache hit.
  'codegen': _Fixture(
    'codegen',
    ':app_macos',
    'dep_lib/lib/catalog.dart',
    "catalogFields.join(',')",
  ),
  // No codegen anywhere in the graph, so the generated-sources collision cannot
  // arise and only the repository-forest one can.
  'hello_world': _Fixture(
    'hello_world',
    ':hello_world_macos',
    'lib/main.dart',
    r"'count: $_counter'",
  ),
};

/// A file every Flutter app's compile reads, used to watch the forest churn.
const _sdkProbe = 'lib/src/material/date_picker_theme.dart';

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'pair' : args.first;
  if (mode != 'solo' && mode != 'pair') {
    stderr.writeln('usage: concurrent_sessions.dart [solo|pair] [edits]');
    exit(2);
  }
  final editCount = args.length > 1 ? int.parse(args[1]) : 3;
  final fixtureName = args.length > 2 ? args[2] : 'codegen';
  final fixture = _fixtures[fixtureName];
  if (fixture == null) {
    stderr.writeln(
      'unknown workspace "$fixtureName"; '
      'known: ${_fixtures.keys.join(', ')}',
    );
    exit(2);
  }

  final repoRoot = await _repoRoot();
  final workspace = '$repoRoot/e2e/${fixture.workspace}';
  final probe = File('$workspace/${fixture.probeFile}');
  if (!probe.existsSync()) {
    stderr.writeln('probe source not found: ${probe.path}');
    exit(2);
  }
  final original = probe.readAsStringSync();
  if (!original.contains(fixture.marker)) {
    stderr.writeln('probe marker "${fixture.marker}" not in ${probe.path}');
    exit(2);
  }

  final devTool = await _buildDevTool(repoRoot);
  // Warm the fixture's own output base before sampling it. The execroot forest
  // holds only what some command has already asked for, so on a server that has
  // never built this workspace there is nothing to watch yet — and a cold build
  // inside the measurement would dominate it anyway.
  final warm = await Process.run('bazel', [
    'build',
    fixture.target,
  ], workingDirectory: workspace);
  if (warm.exitCode != 0) {
    stderr.writeln(
      'warming build of ${fixture.target} in $workspace failed '
      '(exit ${warm.exitCode})\n${warm.stdout}${warm.stderr}',
    );
    exit(1);
  }
  final sampler = await _ForestSampler.create(workspace);

  final sessions = <_Session>[];
  var failures = 0;
  // Restore on interrupt too: a half-edited fixture leaves every later run
  // staring at a red exception screen.
  final sigint = ProcessSignal.sigint.watch().listen((_) async {
    probe.writeAsStringSync(original);
    for (final s in sessions) {
      await s.dispose();
    }
    exit(130);
  });

  try {
    // Sampling starts before either session does, because startup is when the
    // damage lands: what fails is a session's *initial* compile, the long one
    // that reads the whole Flutter SDK. Later incremental compiles finish in
    // about 200ms and mostly miss the window.
    sampler.start();
    final a = await _startSession(
      'A',
      devTool,
      workspace,
      fixture.target,
      sessions,
    );
    final b = mode == 'pair'
        ? await _startSession('B', devTool, workspace, fixture.target, sessions)
        : null;

    for (var i = 0; i < editCount; i++) {
      final tag = 'PROBE$i';
      final aFrom = a.events.length;
      final bFrom = b?.events.length ?? 0;
      _log('edit -> $tag');
      probe.writeAsStringSync(
        original.replaceFirst(fixture.marker, "'$tag-' + ${fixture.marker}"),
      );
      failures += _verdict(a, tag, await a.awaitReload(aFrom));
      if (b != null) failures += _verdict(b, tag, await b.awaitReload(bFrom));
    }
    sampler.stop();
    _log(sampler.summary);
  } finally {
    probe.writeAsStringSync(original);
    for (final s in sessions) {
      await s.dispose();
    }
    await sigint.cancel();
  }

  _log(
    'RESULT workspace=$fixtureName mode=$mode edits=$editCount '
    'failedVerdicts=$failures',
  );
  if (failures > 0) exitCode = 1;
}

int _verdict(_Session session, String tag, Map<String, dynamic> result) {
  final ok = result['succeeded'] == true;
  _log(
    '  ${session.name} [$tag] succeeded=$ok'
    '${ok ? '' : ' :: ${jsonEncode(result)}'}',
  );
  // `Initial compile failed` on its own names no cause: a missing Flutter SDK
  // source and a missing generated `.g.dart` are different defects that read
  // identically at this level.
  if (!ok) {
    final why = session.compileDiagnostics;
    if (why != null) _log('    compiler said: ${_firstLines(why, 4)}');
  }
  return ok ? 0 : 1;
}

String _firstLines(String text, int count) {
  final lines = const LineSplitter().convert(text);
  final head = lines.take(count).join('\n                   ');
  return lines.length > count ? '$head\n                   …' : head;
}

void _log(String message) =>
    print('[${DateTime.now().toIso8601String()}] $message');

/// The repository root, from Bazel rather than by walking up from
/// `Directory.current` — the script may be invoked from anywhere.
Future<String> _repoRoot() async {
  final result = await Process.run('bazel', ['info', 'workspace']);
  if (result.exitCode != 0) {
    throw StateError('bazel info workspace failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

/// Build the shipped binary and return its path.
///
/// Deliberately no fall back to `dart run`: a run that quietly measured a
/// different binary than the one shipped is worse than no run.
Future<String> _buildDevTool(String repoRoot) async {
  const label = '//tools/dev_tool:flutter_bazel';
  final result = await Process.run('bazel', [
    'build',
    label,
  ], workingDirectory: repoRoot);
  if (result.exitCode != 0) {
    throw StateError(
      'failed to build $label (exit ${result.exitCode})\n'
      '${result.stdout}${result.stderr}',
    );
  }
  final path = '$repoRoot/bazel-bin/tools/dev_tool/flutter_bazel';
  if (!File(path).existsSync()) {
    throw StateError('$label built but $path is missing');
  }
  return path;
}

/// Watches one Flutter SDK source through the execroot's per-command symlink
/// forest and records every window in which it was not readable.
class _ForestSampler {
  final String _leaf;
  Timer? _timer;
  int _samples = 0;
  int _absent = 0;
  int _gaps = 0;
  DateTime? _gapStart;
  Duration _longest = Duration.zero;

  _ForestSampler._(this._leaf);

  static Future<_ForestSampler> create(String workspace) async {
    final info = await Process.run('bazel', [
      'info',
      'output_base',
    ], workingDirectory: workspace);
    if (info.exitCode != 0) {
      throw StateError('bazel info output_base failed: ${info.stderr}');
    }
    final outputBase = (info.stdout as String).trim();
    final external = Directory('$outputBase/execroot/_main/external');
    // Found rather than named: the canonical repository name carries the
    // module-extension mangling (`rules_flutter++flutter+deps__flutter`), which
    // is not a string this script should pretend to know.
    final matches = external.existsSync()
        ? external
              .listSync()
              .map((e) => e.path)
              .where((p) => p.endsWith('+deps__flutter'))
              .toList()
        : <String>[];
    if (matches.length != 1) {
      throw StateError(
        'expected exactly one "+deps__flutter" entry under '
        '${external.path}, found ${matches.length}: $matches',
      );
    }
    return _ForestSampler._('${matches.single}/$_sdkProbe');
  }

  void start() {
    _timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      _samples++;
      if (File(_leaf).existsSync()) {
        final started = _gapStart;
        if (started != null) {
          final held = DateTime.now().difference(started);
          if (held > _longest) _longest = held;
          _gapStart = null;
        }
        return;
      }
      _absent++;
      if (_gapStart == null) {
        _gapStart = DateTime.now();
        _gaps++;
      }
    });
  }

  void stop() => _timer?.cancel();

  String get summary =>
      'Flutter SDK source unreadable through the execroot in '
      '$_absent of $_samples samples, in $_gaps window(s), '
      'longest ${_longest.inMilliseconds}ms';
}

/// One `flutter_bazel run --watch --machine` subprocess.
class _Session {
  final String name;
  final Process process;
  final List<Map<String, dynamic>> events = [];
  final List<String> stderrLines = [];
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _httpBound = Completer<void>();
  bool _exited = false;

  _Session(this.name, this.process) {
    unawaited(process.exitCode.then((_) => _exited = true));
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onStdout);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderrLines.add(line);
          if (line.contains('"message":"http_control_channel"') &&
              !_httpBound.isCompleted) {
            _httpBound.complete();
          }
        });
  }

  void _onStdout(String line) {
    // Machine protocol wraps each message in [...].
    final start = line.indexOf('[{');
    if (start < 0 || !line.endsWith('}]')) return;
    final decoded = json.decode(line.substring(start)) as List;
    for (final item in decoded) {
      final message = item as Map<String, dynamic>;
      events.add(message);
      _events.add(message);
    }
  }

  /// What the compiler actually said, from the run's own log records.
  ///
  /// Null when it never reported a compile failure.
  String? get compileDiagnostics {
    for (final line in stderrLines.reversed) {
      if (!line.contains('initial_compile_failed')) continue;
      final decoded = json.decode(line);
      if (decoded is Map<String, dynamic>) {
        final diagnostics = decoded['diagnostics'];
        if (diagnostics is String && diagnostics.isNotEmpty) return diagnostics;
      }
    }
    return null;
  }

  String get _stderrTail =>
      stderrLines.reversed.take(30).toList().reversed.join('\n');

  /// The first [event] at or after [fromIndex], failing as soon as the run dies
  /// rather than sitting out the timeout on a process that is already gone.
  Future<Map<String, dynamic>> waitFor(
    String event, {
    required Duration timeout,
    int fromIndex = 0,
  }) async {
    for (var i = fromIndex; i < events.length; i++) {
      if (events[i]['event'] == event) return events[i];
    }
    final done = Completer<Map<String, dynamic>>();
    final sub = _events.stream.listen((m) {
      if (m['event'] == event && !done.isCompleted) done.complete(m);
    });
    unawaited(
      process.exitCode.then((code) {
        if (!done.isCompleted) {
          done.completeError(
            StateError(
              '[$name] exited ($code) waiting for $event\n$_stderrTail',
            ),
          );
        }
      }),
    );
    try {
      return await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }

  /// Ready in the same sense the passing watch-reload e2e uses: the HTTP
  /// control channel has bound, which is the last thing a run does before it is
  /// interactive. `app.start` alone means only that the app is *launching*.
  Future<void> waitUntilReady() async {
    const limit = Duration(seconds: 420);
    await waitFor('app.start', timeout: limit);
    await waitFor('app.started', timeout: limit);
    if (_httpBound.isCompleted) return;
    final done = Completer<void>();
    unawaited(
      _httpBound.future.then((_) {
        if (!done.isCompleted) done.complete();
      }),
    );
    unawaited(
      process.exitCode.then((code) {
        if (!done.isCompleted) {
          done.completeError(
            StateError(
              '[$name] exited ($code) before the control channel bound\n'
              '$_stderrTail',
            ),
          );
        }
      }),
    );
    await done.future.timeout(limit);
  }

  Future<Map<String, dynamic>> awaitReload(int fromIndex) async {
    final event = await waitFor(
      'app.reloadResult',
      timeout: const Duration(seconds: 180),
      fromIndex: fromIndex,
    );
    return (event['params'] as Map<String, dynamic>)['result']
        as Map<String, dynamic>;
  }

  Future<void> dispose() async {
    if (_exited) return;
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -9;
      },
    );
  }
}

Future<_Session> _startSession(
  String name,
  String devTool,
  String workspace,
  String target,
  List<_Session> sessions,
) async {
  _log('$name: starting');
  final process = await Process.start(
    devTool,
    [
      'run',
      '-t',
      target,
      '-d',
      'macos',
      '--machine',
      '--no-devtools',
      '--watch',
    ],
    workingDirectory: workspace,
    environment: {...Platform.environment, 'LOG_FORMAT': 'json'},
  );
  final session = _Session(name, process);
  sessions.add(session);
  await session.waitUntilReady();
  _log('$name: ready');
  return session;
}
