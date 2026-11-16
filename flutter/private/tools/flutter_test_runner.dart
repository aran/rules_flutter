/// Bazel-side driver for `flutter_test` rule.
///
/// Spawns `flutter_tester` with the kernel `.dill` produced by the rule, hosts
/// a localhost WebSocket harness, and drives the per-test
/// `package:test_api/backend.dart` `RemoteListener` protocol. Reports per-test
/// pass/fail to stdout and exits non-zero on the first failure (or on
/// flutter_tester crash).
///
/// The protocol itself is `remote_suite.dart`'s; this file carries it over a
/// WebSocket the bootstrap dials back on.
///
/// Coverage: under `bazel coverage` ([CoverageRun]) the spawn switches to
/// `--vm-service-port=0`. The runner pulls the VM service URI from
/// flutter_tester's stdout and, once the suite has run and before it is told to
/// close, collects line coverage over the VM service JSON-RPC, which rules_dart's
/// `coverage_converter` then turns into the LCOV tracefile Bazel merges.
///
/// Goldens: `--update-goldens` (upstream's spelling) sets
/// `FLUTTER_TEST_UPDATE_GOLDENS` in the tester's environment, which the
/// comparator in the bootstrap reads. It is accepted only under `bazel run`,
/// where `BUILD_WORKSPACE_DIRECTORY` names a source tree to write to.
///
/// Bazel's test protocol wins wherever it has one. The suite's default timeout
/// is Bazel's own (`TEST_TIMEOUT`), not `package:test`'s 30 seconds; a test's
/// own `timeout:` still applies — see [suiteTimeout].
/// `--test_filter`, sharding, tag selection (`DART_TEST_TAGS`,
/// `DART_TEST_EXCLUDE_TAGS`, the rule's `include_tags` and `exclude_tags`) and
/// the per-case XML report follow `lib/bazel_test_protocol.dart`. A suite that
/// registers no test fails, as under `flutter test`. The test file's library
/// `@Tags` are read from `FLUTTER_TEST_SOURCE` with `package:test`'s own
/// parser, so every case carries them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rule_tools/remote_suite.dart';
import 'package:flutter_rule_tools/suite_annotations.dart';
import 'package:kernel_list/kernel_list.dart';
import 'package:runfiles/runfiles.dart';

/// The runfiles of the program started as [executable], or null.
///
/// Unlike `Runfiles.create`, which trusts `RUNFILES_DIR` first, this looks
/// only beside [executable]: a `RUNFILES_DIR` inherited from a caller names
/// the caller's tree, not this program's. `<executable>.runfiles` and
/// `<executable>.runfiles_manifest` are both read when both exist, with the
/// manifest answering first: where Bazel makes no symlink tree, as on Windows
/// by default, the directory is still there, holding only a `MANIFEST` and
/// empty directories. `.exe` is spelled both ways as on Windows.
///
/// Public, like [testCeiling], because the test reaches it directly.
Runfiles? runfilesBeside(String executable) {
  final withoutExe = executable.endsWith('.exe')
      ? executable.substring(0, executable.length - 4)
      : executable;
  final names = {executable, withoutExe, '$withoutExe.exe'};
  for (final name in names) {
    final dir = Directory('$name.runfiles');
    final file = File('$name.runfiles_manifest');
    final hasDir = dir.existsSync();
    final hasManifest = file.existsSync();
    if (!hasDir && !hasManifest) continue;
    final root = hasDir ? dir.resolveSymbolicLinksSync() : null;
    final manifest = hasManifest
        ? parseRunfilesManifest(file.readAsLinesSync())
        : null;
    final mappingFile = root != null && File('$root/_repo_mapping').existsSync()
        ? '$root/_repo_mapping'
        : manifest?['_repo_mapping'];
    return Runfiles.fromState(
      directory: root,
      manifest: manifest,
      repoMapping: mappingFile == null
          ? null
          : Runfiles.parseRepoMapping(File(mappingFile).readAsStringSync()),
    );
  }
  return null;
}

/// A runfiles manifest's `<runfiles path> <real path>` lines as a map.
///
/// Public, like [testCeiling], because the test reaches it directly.
Map<String, String> parseRunfilesManifest(Iterable<String> lines) {
  final result = <String, String>{};
  for (final line in lines) {
    final space = line.indexOf(' ');
    if (space < 0) continue;
    result[line.substring(0, space)] = line.substring(space + 1);
  }
  return result;
}

/// The start-up settings a `flutter_tester_binary` carries as
/// `<name>.launch.json` at the root of its own runfiles: a JSON object of
/// environment variables.
///
/// Public, like [testCeiling], because the test reaches it directly.
Map<String, String> readLaunchEnvironment(
  Runfiles runfiles,
  String executable,
) {
  var name = executable.split(RegExp(r'[/\\]')).last;
  if (name.endsWith('.exe')) name = name.substring(0, name.length - 4);
  final path = runfiles.rlocation('$name.launch.json');
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('flutter_test runner: no launch data at $path');
  }
  return (json.decode(file.readAsStringSync()) as Map<String, dynamic>)
      .cast<String, String>();
}

/// The directories holding the runfiles [keys], each listed once and in order.
///
/// A manifest lists files, not directories, so a directory is found through
/// a file known to be under it. A library that cannot be found is an error
/// naming it: it is missing from the manifest, or listed but absent on disk.
///
/// Public, like [testCeiling], because the test reaches it directly.
List<String> nativeLibraryDirectories(
  Runfiles runfiles,
  Iterable<String> keys,
) {
  final directories = <String>{};
  for (final key in keys) {
    final String path;
    try {
      path = runfiles.rlocation(key);
    } on StateError {
      throw StateError(
        'flutter_test runner: native library $key is not in the runfiles.',
      );
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError(
        'flutter_test runner: native library $key resolves to $path, which '
        'does not exist.',
      );
    }
    directories.add(file.absolute.parent.path);
  }
  return directories.toList();
}

/// The program flutter_tester runs, from the runfiles path [key] of the test's
/// kernel: that kernel, or, when [isList], the kernels a kernel list there
/// names, joined into one because flutter_tester takes a single file. The
/// join is in memory on Linux and a file under [temporaryDirectory] (by
/// default the system's) elsewhere. Close it when the run is over.
///
/// Throws a [KernelListException] when the list or a kernel it names cannot be
/// found or joined.
///
/// Public, like [testCeiling], because the test reaches it directly.
JoinedKernel joinProgram(
  Runfiles runfiles,
  String key, {
  required bool isList,
  String? temporaryDirectory,
}) => joinKernels(
  isList ? kernelsInRunfiles(runfiles, key) : [runfiles.rlocation(key)],
  temporaryDirectory: temporaryDirectory,
);

/// What the runner says when [joinProgram] fails. The exception's own text
/// names the flag that builds joined kernels instead.
///
/// Public, like [testCeiling], because the test reaches it directly.
String joinFailure(KernelListException e) =>
    'flutter_test runner: cannot join the test\'s kernels: $e';

void main(List<String> args) async {
  // A flutter_test is handed its settings by Bazel's test environment. A
  // flutter_tester_binary carries them in its own runfiles, because the
  // build action that runs it as a tool has no environment for it.
  final Map<String, String> settings;
  final Runfiles r;
  if (Platform.environment['FLUTTER_TEST_DILL'] != null) {
    settings = Platform.environment;
    r = Runfiles.create();
  } else {
    final own = runfilesBeside(Platform.executable);
    if (own == null) {
      stderr.writeln(
        'flutter_test runner: no runfiles beside ${Platform.executable}, and '
        'no FLUTTER_TEST_DILL in the environment.',
      );
      exit(64);
    }
    r = own;
    settings = {
      ...Platform.environment,
      ...readLaunchEnvironment(r, Platform.executable),
    };
  }
  final launched = identical(settings, Platform.environment)
      ? const <String, String>{}
      : settings;

  final bool updateGoldens;
  try {
    updateGoldens = parseUpdateGoldens(
      args,
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
      program: 'flutter_test runner',
    );
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(64);
  }

  final testerKey = settings['FLUTTER_TEST_TESTER'];
  final icuKey = settings['FLUTTER_TEST_ICU'];
  final dillKey = settings['FLUTTER_TEST_DILL'];
  final assetsKey = settings['FLUTTER_TEST_ASSETS'];
  if (testerKey == null || icuKey == null || dillKey == null) {
    stderr.writeln(
      'flutter_test runner: FLUTTER_TEST_TESTER, FLUTTER_TEST_ICU, and '
      'FLUTTER_TEST_DILL must be set.',
    );
    exit(64);
  }

  final tester = r.rlocation(testerKey);
  final icu = r.rlocation(icuKey);
  final assetsDir = assetsKey == null ? null : r.rlocation(assetsKey);
  final nativeFiles = settings['FLUTTER_TEST_NATIVE_FILES'];
  final Map<String, String> loader;
  try {
    loader = libraryPathEnvironment(
      nativeFiles == null
          ? const []
          : nativeLibraryDirectories(r, nativeFiles.split('\n')),
      Platform.environment,
      Platform.operatingSystem,
    );
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(64);
  }
  final testPath = settings['FLUTTER_TEST_PATH'] ?? 'test.dart';
  final coverage = CoverageRun.of(r, settings, Platform.environment);

  final isTest = Platform.environment['FLUTTER_TEST_DILL'] != null;
  final TestSelection selection;
  try {
    selection = runSelection(settings, isTest: isTest);
  } on FormatException catch (e) {
    stderr.writeln('flutter_test runner: ${e.message}');
    exit(64);
  }
  var annotations = SuiteAnnotations.none();
  if (isTest) {
    final sourceKey = settings['FLUTTER_TEST_SOURCE'];
    if (sourceKey == null) {
      stderr.writeln('flutter_test runner: FLUTTER_TEST_SOURCE must be set.');
      exit(64);
    }
    try {
      annotations = suiteAnnotationsOf(File(r.rlocation(sourceKey)), testPath);
    } on FormatException catch (e) {
      stderr.writeln(
        'flutter_test runner: cannot read the annotations of $testPath: '
        '${e.message}',
      );
      exit(1);
    }
  }
  // Touched before the run, as Bazel asks: it is how a runner says it supports
  // sharding at all, and Bazel 9 fails a sharded test whose runner never does.
  final shardStatus = Platform.environment['TEST_SHARD_STATUS_FILE'];
  if (shardStatus != null) File(shardStatus).writeAsStringSync('');

  final exclusion = annotations.exclusion;
  if (exclusion != null) {
    exitCode = await reportSuiteNotRun(
      suitePath: testPath,
      note: exclusion,
      logPrefix: 'flutter_test',
      xmlOutput: Platform.environment['XML_OUTPUT_FILE'],
    );
    return;
  }

  final JoinedKernel program;
  try {
    program = joinProgram(
      r,
      dillKey,
      isList: settings['FLUTTER_TEST_KERNEL_LIST'] == '1',
      temporaryDirectory: Platform.environment['TEST_TMPDIR'],
    );
  } on KernelListException catch (e) {
    stderr.writeln(joinFailure(e));
    exitCode = 1;
    return;
  }
  // flutter_tester has read the program by the time it connects; the memory or
  // file is released when the run is over, however it ended.
  final int code;
  try {
    code = await _runOnce(
      tester: tester,
      icu: icu,
      dill: program.path,
      assetsDir: assetsDir,
      testPath: testPath,
      coverage: coverage,
      updateGoldens: updateGoldens,
      selection: selection,
      metadata: annotations.handshakeMetadata(
        Platform.environment['TEST_TIMEOUT'],
      ),
      xmlOutput: Platform.environment['XML_OUTPUT_FILE'],
      impeller: settings['FLUTTER_TEST_IMPELLER'] == '1',
      loader: {...launched, ...loader},
    );
  } finally {
    program.close();
  }
  // The run is over and reported, so the runner exits now rather than when
  // its event loop drains: anything the run left open would otherwise keep
  // the target alive, silent, until Bazel's timeout.
  await Future.wait([stdout.flush(), stderr.flush()]);
  exit(code);
}

/// The selection this run applies, from [settings].
///
/// A `flutter_test` ([isTest]) selects cases by the target's own
/// `include_tags`/`exclude_tags`, which the rule passes as newline-joined
/// `FLUTTER_TEST_INCLUDE_TAGS`/`FLUTTER_TEST_EXCLUDE_TAGS`, and by the
/// `DART_TEST_TAGS`/`DART_TEST_EXCLUDE_TAGS` of the run, and orders them by
/// its `DART_TEST_ORDERING_SEED`. A `flutter_tester_binary` is not a test,
/// and a shell's variable must not change what a build tool does: it takes
/// none of these.
///
/// Throws [FormatException] for a selector that does not parse.
///
/// Public, like [testCeiling], because the test reaches it directly.
TestSelection runSelection(
  Map<String, String> settings, {
  required bool isTest,
}) {
  if (!isTest) {
    return TestSelection.fromEnvironment({
      for (final entry in settings.entries)
        if (entry.key != 'DART_TEST_TAGS' &&
            entry.key != 'DART_TEST_EXCLUDE_TAGS' &&
            entry.key != 'DART_TEST_ORDERING_SEED')
          entry.key: entry.value,
    });
  }
  List<String> lines(String key) {
    final value = settings[key];
    return value == null || value.isEmpty ? const [] : value.split('\n');
  }

  return TestSelection.fromEnvironment(
    settings,
    fixedTags: TagSelection.fromAttribute(
      lines('FLUTTER_TEST_INCLUDE_TAGS'),
      lines('FLUTTER_TEST_EXCLUDE_TAGS'),
    ),
  );
}

/// The library annotations of [source], the test file shown to people as [displayPath].
///
/// Throws [FormatException] when the file's annotations cannot be read.
///
/// Public, like [testCeiling], because the test reaches it directly.
SuiteAnnotations suiteAnnotationsOf(File source, String displayPath) =>
    SuiteAnnotations.parse(displayPath, source.readAsStringSync());

/// The loader's search path for a `flutter_tester_binary`'s Native Assets.
///
/// Its kernel names each bundled library by filename alone, so the program
/// may run from any working directory; this puts [nativeDirs], where they are
/// staged, ahead of the search path [environment] already has. Empty when
/// there are no such directories, as for every `flutter_test`, whose libraries
/// are named by their paths under the runfiles root it runs in.
///
/// Windows has no variable for the purpose: `LoadLibrary` of a bare name
/// looks in the application's directory, the system directories, the working
/// directory and then `PATH`, and only `PATH` can be set for a child. Its
/// directories are joined with `;` and spelled with `\`, and its variable is
/// found without regard to case, as Windows does, so the child is not given
/// `Path` and `PATH` both.
///
/// Public, like [testCeiling], because the test reaches it directly.
Map<String, String> libraryPathEnvironment(
  List<String> nativeDirs,
  Map<String, String> environment,
  String os,
) {
  if (nativeDirs.isEmpty) return const {};
  final windows = os == 'windows';
  final String variable;
  switch (os) {
    case 'macos':
      variable = 'DYLD_LIBRARY_PATH';
    case 'linux':
      variable = 'LD_LIBRARY_PATH';
    case 'windows':
      variable = environment.keys.firstWhere(
        (k) => k.toUpperCase() == 'PATH',
        orElse: () => 'PATH',
      );
    default:
      throw UnsupportedError('flutter_tester_binary: no loader path on $os');
  }
  final separator = windows ? ';' : ':';
  final dirs = [
    for (final dir in nativeDirs) windows ? dir.replaceAll('/', r'\') : dir,
    if (environment[variable] case final existing? when existing.isNotEmpty)
      existing,
  ];
  return {variable: dirs.join(separator)};
}

Future<int> _runOnce({
  required String tester,
  required String icu,
  required String dill,
  required String? assetsDir,
  required String testPath,
  required CoverageRun? coverage,
  required bool updateGoldens,
  required TestSelection selection,
  required Map<String, Object?> metadata,
  required String? xmlOutput,
  required bool impeller,
  required Map<String, String> loader,
}) async {
  final harness = await _Harness.bind();
  try {
    return await harness.run(
      tester: tester,
      icu: icu,
      dill: dill,
      assetsDir: assetsDir,
      testPath: testPath,
      coverage: coverage,
      updateGoldens: updateGoldens,
      selection: selection,
      metadata: metadata,
      xmlOutput: xmlOutput,
      impeller: impeller,
      loader: loader,
    );
  } finally {
    await harness.dispose();
  }
}

/// The `flutter_tester` bootstrap's WebSocket, as a [SuiteTransport].
class _TesterTransport implements SuiteTransport {
  _TesterTransport(this._ws, this._process) {
    _ws.listen(
      (raw) => _incoming.add(raw as String),
      onDone: () {
        unawaited(_incoming.close());
        if (!_lost.isCompleted) _lost.complete('flutter_tester disconnected');
      },
    );
  }

  final WebSocket _ws;
  final Process _process;
  final _incoming = StreamController<String>();
  final _lost = Completer<String?>();

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  void send(String json) {
    if (_lost.isCompleted) return;
    _ws.add(json);
  }

  @override
  Future<String?> get lostReason => _lost.future;

  @override
  Future<void> close() => _ws.close();

  @override
  Future<void> abandon(String why) async {
    stderr.writeln('flutter_test: killing flutter_tester.');
    _process.kill(ProcessSignal.sigkill);
  }
}

/// Harness state: server, tester process, WebSocket.
class _Harness {
  _Harness._(this._server);

  final HttpServer _server;
  Process? _process;
  WebSocket? _ws;

  /// Binds the socket the test bootstrap dials back on.
  ///
  /// The IPv4 loopback specifically, and the bootstrap dials
  /// `ws://127.0.0.1:$port` for it — one family at both ends, deliberately.
  /// Only a port number crosses to the tester process
  /// (`FLUTTER_TEST_HARNESS_PORT`), so nothing here publishes a *name* for a
  /// client to choose a family from. That is what makes this unlike the
  /// control channel and the web dev server, which bind both loopbacks
  /// because their URLs say `localhost`: a client resolving that name picks a
  /// family itself, so half of such a URL would reach whatever else holds the
  /// port on the family the server left free. A specific-address bind is also
  /// refused outright by the kernel when the port is already held, so nothing
  /// can be reached here in place of this server.
  ///
  /// The one host this cannot run on is one with no assignable 127.0.0.1 — an
  /// IPv6-only loopback. Never tested, and accepted as untested rather than
  /// coded around, because a Flutter test cannot work there for reasons above
  /// this file. The engine binds its VM service to 127.0.0.1 unless launched
  /// with `--ipv6` (`engine/src/flutter/shell/common/switches.cc`, read at all
  /// five engine revisions `versions.bzl` pins), nothing in this repo passes
  /// that flag, the only VM-service host it does name is the IPv4 wildcard
  /// `0.0.0.0` for a wireless iOS device, and the `adb`/`iproxy` forwards a
  /// device run is dialed through listen on 127.0.0.1. Widening this bind
  /// alone would buy nothing.
  ///
  /// So do not change it without a failure reproduced on such a host — and
  /// never without the dial in `flutter/private/flutter_test.bzl`, which has
  /// to name the same family.
  static Future<_Harness> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _Harness._(server);
  }

  /// Closes all three of the harness's resources, independently.
  ///
  /// Separate `try`s because none of the three depends on the one before it,
  /// and this runs on the failure paths too — a socket that will not close
  /// must not leave the tester process alive or the port bound. They stay
  /// broad and quiet because what they throw is "already closed", which is
  /// the state the call was asking for.
  ///
  /// [Process.kill] is not one of them and is no longer wrapped. It answers
  /// with a bool and does not throw for a dead process — dart-sdk
  /// `lib/io/process.dart`: "Returns `true` if the signal is successfully
  /// delivered... Otherwise the signal could not be sent, usually meaning that
  /// the process is already dead." The `try` around it was guarding a failure
  /// that cannot happen, while the value that does report it went unread.
  ///
  /// The tester is killed first, so a socket close that never answers cannot
  /// leave it running.
  Future<void> dispose() async {
    _process?.kill(ProcessSignal.sigkill);
    try {
      await _ws?.close();
    } catch (_) {}
    try {
      await _server.close(force: true);
    } catch (_) {}
  }

  Future<int> run({
    required String tester,
    required String icu,
    required String dill,
    required String? assetsDir,
    required String testPath,
    required CoverageRun? coverage,
    required bool updateGoldens,
    required TestSelection selection,
    required Map<String, Object?> metadata,
    required String? xmlOutput,
    required bool impeller,
    required Map<String, String> loader,
  }) async {
    final enableVmService = coverage != null;
    // Coverage does not start the tester paused, and `flutter test --coverage`
    // does not either. Nothing needs holding: the VM records coverage from
    // the first line `main()` runs, and collection happens before the suite
    // is told to close, while the isolate is still alive. Starting paused and
    // resuming over the VM service hung one run in ten, measured on a
    // one-case suite: the resumed isolate sat idle inside the
    // bootstrap, never dialling the harness, until an unrelated VM service
    // request woke it. Unpaused, 80 runs in a row passed with identical
    // covered lines.
    final command = <String>[
      tester,
      if (enableVmService) '--vm-service-port=0' else '--disable-vm-service',
      '--icu-data-file-path=$icu',
      '--enable-checked-mode',
      '--verify-entry-points',
      // `flutter test --enable-impeller`'s choice: Impeller, or software
      // Skia rendered deterministically.
      if (impeller)
        '--enable-impeller'
      else ...[
        '--enable-software-rendering',
        '--skia-deterministic-rendering',
      ],
      '--enable-dart-profiling',
      '--non-interactive',
      '--use-test-fonts',
      '--disable-asset-fonts',
      if (assetsDir != null) '--flutter-assets-dir=$assetsDir',
      dill,
    ];

    // flutter_tester writes to the runner's own stdout and stderr, the
    // target's log, so all it wrote is there once it has exited, its last
    // lines after a crash included. Through a pipe the runner would have to
    // read to the end, and the end may not come: a process the test starts
    // inherits the tester's output and can hold the pipe open long after the
    // tester is gone. Here such a process writes to the log too, and holds up
    // nothing.
    _process = await Process.start(
      command.first,
      command.sublist(1),
      mode: ProcessStartMode.inheritStdio,
      environment: {
        'FLUTTER_TEST': 'true',
        'FLUTTER_TEST_HARNESS_PORT': '${_server.port}',
        // `flutter test` bakes `autoUpdateGoldenFiles = true` into a bootstrap
        // it regenerates for every run. Here the bootstrap is a build artifact
        // shared by every run of the target, so update mode has to reach the
        // tester at runtime instead. The parent environment comes along by
        // default, which is how the comparator also sees
        // BUILD_WORKSPACE_DIRECTORY and TEST_UNDECLARED_OUTPUTS_DIR.
        if (updateGoldens) 'FLUTTER_TEST_UPDATE_GOLDENS': '1',
        ...loader,
      },
    );

    // Wait for the bootstrap to dial back.
    Uri? coverageVmServiceUri;
    final bound = dialBackBound(
      testCeiling(Platform.environment['TEST_TIMEOUT']),
    );
    final dialBack = await awaitDialBack(
      connected: _server.first,
      exited: _process!.exitCode,
      bound: bound,
    );
    switch (dialBack) {
      case TesterExited(:final exitCode):
        stderr.writeln(dialBackFailure(dialBack, bound));
        return exitCode == 0 ? 1 : exitCode;
      case DialBackTimedOut():
        stderr.writeln(dialBackFailure(dialBack, bound));
        return 1;
      case BootstrapConnected(:final request):
        // A coverage run that cannot reach the VM service cannot produce what
        // it exists for, so it ends here rather than running the whole suite
        // first and failing at collection.
        if (enableVmService) {
          final named = request.uri.queryParameters['vm-service'];
          if (named == null) {
            stderr.writeln(
              'flutter_test (coverage): flutter_tester connected without a '
              'VM service.',
            );
            return 1;
          }
          coverageVmServiceUri = Uri.parse(named);
        }
        _ws = await WebSocketTransformer.upgrade(request);
    }

    // Collect coverage before the driver tells the tester to close — the
    // isolate must still be alive when we fetch source reports.
    String? coverageError;
    Future<void> collect() async {
      if (coverage == null || coverageVmServiceUri == null) return;
      try {
        // Bounded inside Bazel's own budget, like the suite and each test: a
        // VM service that stops answering mid-collection would otherwise park
        // here until Bazel kills the target with no reason given. Not a fixed
        // bound: on a starved machine the tester gets a few percent of a core
        // and a collection that takes seconds idle takes minutes.
        final hits = await collectCoverage(
          coverageVmServiceUri,
        ).timeout(testCeiling(Platform.environment['TEST_TIMEOUT']));
        // Every healthy run reports at least the test's own `main` file, so
        // nothing at all means collection reached no source. Converting it
        // would produce exactly the green-test-with-empty-LCOV outcome the
        // exit below exists to prevent.
        if ((hits['coverage'] as List).isEmpty) {
          coverageError = 'collected no coverage records';
        } else {
          coverage.writeHits(hits);
        }
      } catch (e) {
        coverageError = 'failed to collect coverage: $e';
      }
      if (coverageError != null) {
        stderr.writeln('flutter_test (coverage): $coverageError');
      }
    }

    // The driver ends the suite politely: it tells RemoteListener to close,
    // then closes the WebSocket. The bootstrap's `socket.map(...).pipe(sink)`
    // and `socket.addStream(...)` both terminate on socket close, draining the
    // isolate so flutter_tester exits on its own. Without the explicit
    // close, the bootstrap's main isolate keeps the engine alive and
    // we'd block on the tester-exit timeout for every test run.
    final ceiling = testCeiling(Platform.environment['TEST_TIMEOUT']);
    final outcome =
        await RemoteSuiteDriver(
          _TesterTransport(_ws!, _process!),
          suitePath: testPath,
          metadata: metadata,
        ).run(
          selection: selection,
          xmlOutput: xmlOutput,
          ceiling: ceiling,
          afterSuite: collect,
        );

    // `-1` can't double as a "we killed it" sentinel here: on POSIX a
    // signal-killed process reports `-signum`, and SIGHUP is signal 1, so
    // `-1` is a real exit value. Track the timeout kill explicitly instead.
    var killedAfterTimeout = false;
    final testerExit = await _process!.exitCode.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        killedAfterTimeout = true;
        _process!.kill(ProcessSignal.sigkill);
        return 0;
      },
    );
    if (killedAfterTimeout) {
      stderr.writeln(
        'flutter_test: flutter_tester did not exit within 30s after the '
        'suite finished; killed it.',
      );
    }

    stdout.writeln(outcome.summary());

    // Converted whatever the outcome, as Bazel reports the coverage of a
    // failing test too; only once collection succeeded, as a partial report
    // reads as a complete one.
    if (coverage != null && coverageError == null && coverage.collected) {
      final converted = await coverage.convert();
      if (converted != 0) {
        coverageError = 'coverage_converter exited with $converted';
        stderr.writeln('flutter_test (coverage): $coverageError');
      }
    }

    if (outcome.hasFailure) return 1;
    // A requested coverage run that produced no data is a failure — Bazel
    // would otherwise record a green test with an empty/absent LCOV file.
    if (coverageError != null) return 1;
    if (!killedAfterTimeout && testerExit != 0) {
      stderr.writeln('flutter_test: flutter_tester exited with $testerExit');
      return testerExit;
    }
    return 0;
  }
}

/// How long flutter_tester gets to open its socket back to us: two minutes,
/// or less where Bazel's own [ceiling] is shorter, so that a flutter_tester
/// that hangs while starting is named here and not killed by Bazel's clock
/// with no reason given.
///
/// Public, like [testCeiling], because the test reaches it directly.
Duration dialBackBound(Duration ceiling) {
  const bound = Duration(minutes: 2);
  return ceiling < bound ? ceiling : bound;
}

/// Waits for the bootstrap's dial-back, reporting which of the three possible
/// outcomes happened: it [connected], flutter_tester [exited], or neither
/// within [bound].
///
/// The distinction is load-bearing rather than tidiness. A single nullable
/// `HttpRequest?` collapses "flutter_tester died" and "flutter_tester is
/// alive and silent" into one `null`, and only the first of those has an exit
/// code worth awaiting — awaiting it on the second blocks forever, and a
/// paused coverage run then reaches Bazel's outer test timeout with no
/// diagnostic of its own.
///
/// Public, like [testCeiling], because the test reaches it directly.
Future<DialBack> awaitDialBack({
  required Future<HttpRequest> connected,
  required Future<int> exited,
  required Duration bound,
}) async {
  final outcome = await Future.any([
    connected.then<DialBack?>(BootstrapConnected.new),
    exited.then<DialBack?>(TesterExited.new),
  ]).timeout(bound, onTimeout: () => null);
  return outcome ?? const DialBackTimedOut();
}

/// What the runner says of a dial-back that did not happen.
///
/// Public, like [testCeiling], because the test reaches it directly.
String dialBackFailure(DialBack outcome, Duration bound) => switch (outcome) {
  TesterExited(:final exitCode) =>
    'flutter_test: flutter_tester exited with code $exitCode before '
        'connecting to the harness.',
  DialBackTimedOut() =>
    'flutter_test: flutter_tester did not connect to the harness within '
        '${_describe(bound)} and is still running; killing it.',
  BootstrapConnected() => throw ArgumentError.value(outcome, 'outcome'),
};

String _describe(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
  if (d.inSeconds < 120) return '${d.inSeconds} seconds';
  return '${d.inMinutes} minutes';
}

/// The outcome of waiting for flutter_tester's bootstrap to connect back.
sealed class DialBack {
  const DialBack();
}

/// The bootstrap connected; [request] is the HTTP request to upgrade.
final class BootstrapConnected extends DialBack {
  const BootstrapConnected(this.request);

  final HttpRequest request;
}

/// flutter_tester exited before connecting, with [exitCode].
final class TesterExited extends DialBack {
  const TesterExited(this.exitCode);

  final int exitCode;
}

/// Nothing happened within the bound: flutter_tester is alive and has not
/// connected. There is no exit code to wait for.
final class DialBackTimedOut extends DialBack {
  const DialBackTimedOut();
}

// ---------------------------------------------------------------------------
// Coverage support.

/// A run under `bazel coverage`: the VM's line coverage of the program,
/// collected over flutter_tester's VM service into a scratch directory, and
/// converted by rules_dart's `coverage_converter` into the LCOV tracefile in
/// `COVERAGE_DIR` that Bazel's coverage runner merges.
///
/// The converter names each file by its workspace path and reports only the
/// files Bazel instruments (`COVERAGE_MANIFEST`), which is how
/// `--instrumentation_filter` reaches a `flutter_test`.
class CoverageRun {
  CoverageRun._(this.converter, this.sources, this.directory, this.hitmaps);

  /// The run's coverage, when the test was built for coverage
  /// (`FLUTTER_TEST_COVERAGE_CONVERTER`) and Bazel collects it
  /// (`COVERAGE_DIR`): `bazel run` of a coverage build collects none.
  static CoverageRun? of(
    Runfiles runfiles,
    Map<String, String> settings,
    Map<String, String> environment,
  ) {
    final converter = settings['FLUTTER_TEST_COVERAGE_CONVERTER'];
    final sources = settings['FLUTTER_TEST_COVERAGE_SOURCES'];
    final directory = environment['COVERAGE_DIR'];
    if (converter == null || sources == null || directory == null) return null;
    final scratch = environment['TEST_TMPDIR'] ?? Directory.systemTemp.path;
    return CoverageRun._(
      runfiles.rlocation(converter),
      runfiles.rlocation(sources),
      directory,
      Directory(scratch).createTempSync('flutter_test_coverage.').path,
    );
  }

  /// `coverage_converter`.
  final String converter;

  /// The file naming each package's `lib/` directories, which it reads.
  final String sources;

  /// `COVERAGE_DIR`, where the tracefile goes.
  final String directory;

  /// Where the collected coverage goes before it is converted: not
  /// `COVERAGE_DIR`, whose every file Bazel's coverage runner reads.
  final String hitmaps;

  /// Whether [writeHits] has written anything to convert.
  bool collected = false;

  /// Writes what [collectCoverage] returned, for [convert].
  void writeHits(Map<String, Object?> hits) {
    File('$hitmaps/flutter_tester.json').writeAsStringSync(json.encode(hits));
    collected = true;
  }

  /// Converts the collected coverage into `COVERAGE_DIR/flutter_test.dat`,
  /// with the converter's own messages on this process's; its exit status.
  Future<int> convert() async {
    final converting = await Process.start(converter, [
      '--hitmaps=$hitmaps',
      '--sources=$sources',
      '--output=$directory/flutter_test.dat',
    ], mode: ProcessStartMode.inheritStdio);
    return converting.exitCode;
  }
}

/// Collects the line coverage of every isolate group the VM service lists,
/// as `package:coverage`'s `collect` reports it:
/// `{"type": "CodeCoverage", "coverage": [{"source": <uri>, "hits":
/// [line, count, ...]}]}`, a line that ran counted once and one that did not
/// as 0. `dart:` libraries are left out; which of the rest are reported is
/// the converter's to decide, from what Bazel instruments.
///
/// Public so `flutter_test_runner_test.dart` can drive it against a fake VM
/// service; nothing else in this script calls it from outside [main].
///
/// Every failure propagates. The caller turns one into `failed to collect
/// coverage: …` and exits non-zero, which is the only honest answer available:
/// a report missing an isolate — or missing one file within an isolate — is
/// indistinguishable from a complete one once written, so a run that drops
/// part of its coverage reads as a run that simply exercised less code. That
/// sends someone to write tests that already exist, or passes a coverage bar
/// that was never actually met. Collection runs before the suite is told to
/// close, so the isolates `getVM` just listed are alive by construction.
Future<Map<String, Object?>> collectCoverage(Uri httpUri) async {
  final ws = await _connectVmServiceWebSocket(httpUri);
  try {
    final rpc = _VmServiceRpc(ws);
    final vm = await rpc.call('getVM');
    final isolates = (vm['isolates'] as List?) ?? const [];
    final entries = <Map<String, Object?>>[];
    // Isolates of one group share their code and so their counters: one
    // report per group, or every hit would count once per isolate.
    final groups = <String>{};
    for (final iso in isolates) {
      final ref = iso as Map;
      final group = ref['isolateGroupId'] as String?;
      if (group != null && !groups.add(group)) continue;
      final report = await rpc.call('getSourceReport', {
        'isolateId': ref['id'] as String,
        'reports': const ['Coverage'],
        // Every function, run or not, so a line that never ran is reported
        // as such rather than left out; by line rather than token position.
        'forceCompile': true,
        'reportLines': true,
      });
      entries.addAll(_hitEntries(report));
    }
    return {'type': 'CodeCoverage', 'coverage': entries};
  } finally {
    await ws.close();
  }
}

/// [report]'s line coverage, one entry per script.
List<Map<String, Object?>> _hitEntries(Map<String, dynamic> report) {
  final scripts = (report['scripts'] as List?) ?? const [];
  final ranges = (report['ranges'] as List?) ?? const [];
  final uris = [for (final s in scripts) (s as Map)['uri'] as String];
  final byScript = <int, Map<int, int>>{};
  for (final range in ranges) {
    final scriptIndex = (range as Map)['scriptIndex'] as int;
    if (uris[scriptIndex].startsWith('dart:')) continue;
    final coverage = (range['coverage'] as Map?)?.cast<String, dynamic>();
    if (coverage == null) continue;
    final lines = byScript.putIfAbsent(scriptIndex, () => {});
    for (final line in (coverage['hits'] as List?)?.cast<int>() ?? const []) {
      lines[line] = 1;
    }
    for (final line in (coverage['misses'] as List?)?.cast<int>() ?? const []) {
      lines.putIfAbsent(line, () => 0);
    }
  }
  return [
    for (final MapEntry(key: index, value: lines) in byScript.entries)
      if (lines.isNotEmpty)
        {
          'source': uris[index],
          'hits': [
            for (final line in lines.keys.toList()..sort()) ...[
              line,
              lines[line],
            ],
          ],
        },
  ];
}

Future<WebSocket> _connectVmServiceWebSocket(Uri httpUri) {
  final wsUri = httpUri.replace(
    scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    path: '${httpUri.path}ws',
  );
  return WebSocket.connect(wsUri.toString());
}

class _VmServiceRpc {
  _VmServiceRpc(this._ws) {
    _sub = _ws.listen(_onMessage);
  }

  final WebSocket _ws;
  late final StreamSubscription<dynamic> _sub;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  int _id = 1;

  void _onMessage(dynamic raw) {
    final m = json.decode(raw as String) as Map<String, dynamic>;
    final id = m['id']?.toString();
    if (id != null && _pending.containsKey(id)) {
      _pending[id]!.complete(m);
    }
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    final id = '${_id++}';
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _ws.add(
      json.encode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    );
    return c.future.then((response) {
      _pending.remove(id);
      if (response.containsKey('error')) {
        throw StateError('VM service error on $method: ${response['error']}');
      }
      return response['result'] as Map<String, dynamic>;
    });
  }

  Future<void> close() async {
    await _sub.cancel();
  }
}
