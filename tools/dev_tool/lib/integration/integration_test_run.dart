/// One integration test run: launch the app on its device, drive the suite it
/// runs over the channel its device gives (a native app's VM service, a web
/// app's DevTools connection), report each test, stop the app.
///
/// What `flutter test integration_test/x_test.dart -d <device>` does, with
/// Bazel's test protocol in place of `flutter test`'s reporters: a
/// `--test_filter` and a shard select tests, a JUnit file is written to
/// `XML_OUTPUT_FILE`, and the target fails if any selected test did, or none
/// ran.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_rule_tools/remote_suite.dart';
import 'package:flutter_rule_tools/suite_annotations.dart';
import 'package:path/path.dart' as p;
import 'package:rules_flutter_macos_gui_session/macos_gui_session.dart';

import '../device.dart';
import '../web_options.dart';
import 'android_serial.dart';
import 'device_lock.dart';
import 'golden_comparator.dart';
import 'golden_requests.dart';
import 'golden_service_process.dart';
import 'integration_runner_config.dart';
import 'linux_runtime.dart';
import 'suite_connectors.dart';
import 'test_emulator.dart';
import 'test_simulator.dart';

/// What the run needs of its host beyond the device: the locks and the
/// desktop session the device's family asks for, taken before the app is
/// launched and given back after it is stopped.
typedef HostPreparation = Future<Future<void> Function()> Function();

/// A device and what must be true of the host to use it.
class DeviceChoice {
  /// A [device], the [prepare] that has to run before it is launched on, and
  /// the [connect] that reaches the suite of an app launched on it.
  const DeviceChoice(this.device, this.prepare, this.connect);

  /// The device the app runs on.
  final Device device;

  /// Takes what the device needs of the host, and returns what gives it back.
  /// Fails, naming the remedy, when the host cannot give it.
  final HostPreparation prepare;

  /// How the suite of an app launched on [device] is reached.
  final SuiteConnector connect;
}

/// The device `config` runs on, on a host whose operating system is [os].
///
/// [resolve] turns a runfiles path into a file, for what the runner's config
/// names (the browser, the `adb`). [environment] is the test's environment,
/// which names the Android device (`ANDROID_SERIAL`). [run] runs the host's own
/// tools (`adb` to list the attached devices, `simctl` to make a simulator),
/// [lockDirectory] is where a device's lock is kept, and [processId] is the run
/// a simulator is named for, unless a test of this says otherwise.
/// [startIsolated] starts a Linux test's X server, unless a test of this says
/// otherwise.
///
/// Throws a [StateError] for a device no runner has been written for, or one
/// the host does not have: the run fails, saying so, rather than falling back
/// to another.
Future<DeviceChoice> chooseDevice(
  IntegrationRunnerConfig config, {
  required String os,
  required String Function(String runfilesPath) resolve,
  Map<String, String> environment = const {},
  ProcessRunSync? run,
  Directory? lockDirectory,
  int? processId,
  void Function(String message)? log,
  IsolatedProcessStarter? startIsolated,
}) async {
  switch (config.family) {
    case IntegrationFamily.desktop when os == 'macos':
      return DeviceChoice(
        MacOSDevice(),
        () => _prepareMacOs(log),
        vmServiceConnector(),
      );
    case IntegrationFamily.desktop when os == 'windows':
      // No lock and no session probe, as macOS has. Measured on a Windows VM:
      // windows that overlap keep drawing (two tests' windows at one origin
      // each completed forty awaited frames), so tests need not take turns on
      // the screen, and an app started from an SSH logon, which has no visible
      // desktop, drew and was driven all the same. An app that cannot start
      // is reported by the launch, by name (`whyAppExited`, `SuiteUnreachable`).
      return DeviceChoice(
        WindowsDevice(),
        () async => () async {},
        vmServiceConnector(),
      );
    case IntegrationFamily.desktop when os == 'linux':
      // The app draws on an X server of the test's own, with the runtime's
      // GTK and software OpenGL: never the host's display or libraries. No
      // lock and no session probe: each test has a screen to itself.
      final runtime = _linuxRuntime(config, resolve);
      final device = LinuxDevice();
      return DeviceChoice(device, () async {
        final cache = _cacheDir(environment);
        final display = await runtime.startDisplay(
          host: environment,
          cacheDir: cache,
          start: startIsolated ?? startIsolatedProcess,
        );
        device.environment = runtime.environment(
          host: environment,
          cacheDir: cache,
          display: display.number,
        );
        return display.stop;
      }, vmServiceConnector());
    case IntegrationFamily.desktop:
      throw StateError(
        'integration tests run on macOS, Windows and Linux desktops; this host '
        'is $os, which has no runner.',
      );
    case IntegrationFamily.web when os == 'linux':
      final runtime = _linuxRuntime(config, resolve);
      final browserEnvironment = runtime.environment(
        host: environment,
        cacheDir: _cacheDir(environment),
      );
      return DeviceChoice(
        WebDevice(
          chromePath: resolve(config.chromePath),
          startProcess: (exe, args) =>
              startIsolatedProcess(exe, args, browserEnvironment),
        )..webOptions = _unsandboxedHeadlessWebOptions,
        () async => () async {},
        chromePageConnector(),
      );
    case IntegrationFamily.web when os == 'macos':
      return DeviceChoice(
        WebDevice(chromePath: resolve(config.chromePath))
          ..webOptions = _unsandboxedHeadlessWebOptions,
        () async => () async {},
        chromePageConnector(),
      );
    case IntegrationFamily.web:
      return DeviceChoice(
        WebDevice(chromePath: resolve(config.chromePath))
          ..webOptions = headlessWebOptions,
        () async => () async {},
        chromePageConnector(),
      );
    case IntegrationFamily.android when config.emulator != null:
      return _emulatorChoice(
        config,
        config.emulator!.resolved(resolve),
        os: os,
        resolve: resolve,
        environment: environment,
        run: run,
        lockDirectory: lockDirectory,
        log: log,
        startIsolated: startIsolated,
      );
    case IntegrationFamily.android:
      final adb = _runnerTool(resolve(config.adbPath), 'adb');
      final serial = await chooseAndroidSerial(
        adb: adb,
        requested: environment['ANDROID_SERIAL'],
        run: run ?? Process.run,
      );
      return DeviceChoice(
        AndroidDevice(
            deviceId: serial,
            adbPath: adb,
            aapt2Path: _runnerTool(resolve(config.aapt2Path), 'aapt2'),
          )
          // A debug app serves the VM service the suite is driven through, and
          // cannot without the INTERNET permission, which the launch checks.
          ..expectsVmService = true,
        () => _hold('android-$serial', lockDirectory, log),
        vmServiceConnector(),
      );
    case IntegrationFamily.iosSimulator when os == 'macos':
      final device = TestSimulatorDevice();
      final deviceType = config.simulatorDeviceType;
      final runtime = config.simulatorRuntime;
      return DeviceChoice(device, () async {
        // Made when the run takes what it needs of the host, not before: a run
        // that is refused earlier has made nothing to remove.
        final runner = run ?? Process.run;
        await reclaimOrphanedSimulators(run: runner, log: log ?? (_) {});
        final owner = await simulatorOwnerOfProcess(processId ?? pid, runner);
        final simulator = await TestSimulator.create(
          name: testSimulatorName(config.testDisplayName, owner),
          deviceType: deviceType,
          runtime: runtime,
          run: runner,
        );
        device.simulator = simulator;
        return simulator.remove;
      }, vmServiceConnector());
    case IntegrationFamily.iosSimulator:
      throw StateError(
        'iOS simulators run on macOS; this host is $os, which has none.',
      );
  }
}

/// An emulator of the test's own: its ports are taken now, which names the
/// device, and it is booted when the run takes what it needs of the host.
Future<DeviceChoice> _emulatorChoice(
  IntegrationRunnerConfig config,
  EmulatorSettings settings, {
  required String os,
  required String Function(String runfilesPath) resolve,
  required Map<String, String> environment,
  required ProcessRunSync? run,
  required Directory? lockDirectory,
  required void Function(String message)? log,
  required IsolatedProcessStarter? startIsolated,
}) async {
  final requested = environment['ANDROID_SERIAL'];
  if (requested != null && requested.isNotEmpty) {
    throw StateError(
      'ANDROID_SERIAL is $requested, but this test runs on an emulator it '
      'boots for itself, never on an attached device. To run it on $requested, '
      'build it for an attached device: '
      '`--@rules_flutter//flutter/integration_test:android_device=attached`.',
    );
  }
  final adb = _runnerTool(resolve(config.adbPath), 'adb');
  final aapt2 = _runnerTool(resolve(config.aapt2Path), 'aapt2');
  final ps = run ?? Process.run;
  final say = log ?? (_) {};
  final scratch = EmulatorScratch(
    p.join(
      environment['TEST_TMPDIR'] ?? Directory.systemTemp.path,
      'android_emulator',
    ),
  );
  final runEnv = run == null
      ? runIsolatedProcess
      : (String exe, List<String> args, Map<String, String> _) =>
            run(exe, args);

  final ports = await EmulatorPorts.take(
    lockDirectory: lockDirectory ?? DeviceLock.defaultDirectory,
    isFree: loopbackPortIsFree,
    reclaim: (record) => reclaimEmulator(
      record,
      adb: adb,
      adbEnvironment: adbEnvironment(
        host: environment,
        scratch: scratch,
        server: record.server,
      ),
      ps: ps,
      run: runEnv,
    ),
    log: say,
  );
  final adbEnv = adbEnvironment(
    host: environment,
    scratch: scratch,
    server: ports.server,
  );
  final device = AndroidDevice(
    deviceId: ports.serial,
    adbPath: adb,
    aapt2Path: aapt2,
    runProcess:
        run ??
        (exe, args) => Process.run(
          exe,
          args,
          environment: adbEnv,
          includeParentEnvironment: false,
        ),
    startProcess: (exe, args) => Process.start(
      exe,
      args,
      environment: adbEnv,
      includeParentEnvironment: false,
    ),
  )..expectsVmService = true;

  return DeviceChoice(device, () async {
    // The emulator's own output and the device's log, which the test's
    // outputs keep: an app that ends without a reason the launch can read left
    // its reason there.
    final outputs = environment['TEST_UNDECLARED_OUTPUTS_DIR'];
    IOSink? output;
    try {
      final base = os == 'linux'
          ? _linuxRuntime(config, resolve).environment(
              host: environment,
              cacheDir: _cacheDir(environment),
            )
          : const <String, String>{};
      final emulatorEnv = emulatorEnvironment(
        base: base,
        scratch: scratch,
        server: ports.server,
      );
      layOutEmulator(scratch, settings);
      await checkAcceleration(
        emulator: settings.executable,
        environment: emulatorEnv,
        os: os,
        run: runEnv,
      );
      output = outputs == null
          ? null
          : File(p.join(outputs, 'emulator.log')).openWrite();
      final emulator = await TestEmulator.boot(
        output: output,
        settings: settings,
        ports: ports,
        scratch: scratch,
        adb: adb,
        environment: emulatorEnv,
        adbEnv: adbEnv,
        run: runEnv,
        start: startIsolated ?? startIsolatedProcess,
        ps: ps,
        log: say,
      );
      final log = output;
      return () async {
        try {
          await emulator.stop(
            logcat: outputs == null ? null : p.join(outputs, 'logcat.txt'),
          );
        } finally {
          await log?.close();
          await ports.release();
          Directory(scratch.root).deleteSync(recursive: true);
        }
      };
    } catch (_) {
      await output?.close();
      await ports.release();
      rethrow;
    }
  }, vmServiceConnector());
}

/// [path], the runner's [tool], once it is there: a runfile that is missing
/// names itself rather than failing to start.
String _runnerTool(String path, String tool) {
  if (!File(path).existsSync()) {
    throw StateError(
      'the runner\'s $tool $path is not there: the Android SDK or toolchain '
      'it comes from is gone.',
    );
  }
  return path;
}

/// Takes the lock [key] for the run, and returns what gives it back.
Future<Future<void> Function()> _hold(
  String key,
  Directory? directory,
  void Function(String message)? log,
) async {
  final lock = await DeviceLock.acquire(key, directory: directory, log: log);
  return lock.release;
}

/// What a test's browser is: headless, serving the bundle as a static site, with
/// the cross-origin isolation `flutter_bazel run -d chrome --wasm` serves a
/// WebAssembly app under (the renderer's threads need it), and no debugger, so
/// no expression evaluation.
const headlessWebOptions = WebOptions(
  server: WebServerOptions(crossOriginIsolation: true),
  browser: BrowserLaunchOptions(headless: true),
  enableExpressionEvaluation: false,
);

/// [headlessWebOptions] on a Linux or macOS host, where the browser runs
/// without its own sandbox, as upstream's headless Chrome always does. On Linux
/// the sandbox needs the host set up for it: unprivileged user namespaces,
/// which Ubuntu since 23.10 denies to programs AppArmor has no profile for ("No
/// usable sandbox!", on Ubuntu 24.04), or Chrome's set-user-ID helper installed
/// by root. On macOS it is a Seatbelt profile each browser process applies to
/// itself, which the kernel refuses inside Bazel's own (`sandbox-exec`) sandbox
/// that the test runs in ("forbidden-sandbox-reinit"), and the browser's
/// processes crash. The page is the test's own, and Bazel's sandbox is what
/// confines the run.
const _unsandboxedHeadlessWebOptions = WebOptions(
  server: WebServerOptions(crossOriginIsolation: true),
  browser: BrowserLaunchOptions(
    headless: true,
    browserFlags: ['--no-sandbox'],
  ),
  enableExpressionEvaluation: false,
);

/// The Linux runtime the runner of [config] carries. Throws a [StateError]
/// for a runner that carries none: a Linux test runs with nothing of the
/// host's but its C and C++ runtime.
LinuxRuntime _linuxRuntime(
  IntegrationRunnerConfig config,
  String Function(String runfilesPath) resolve,
) {
  final runtime = config.linuxRuntime;
  if (runtime == null) {
    throw StateError(
      'the runner has no Linux runtime, which a Linux test runs its app or '
      'browser with: give the runner rule `linux_runtime` (the default '
      'runners of @rules_flutter//flutter/integration_test do).',
    );
  }
  return LinuxRuntime.fromConfig(runtime, resolve);
}

/// Where fontconfig keeps its cache for this test: under the test's own
/// temporary directory, which Bazel removes.
String _cacheDir(Map<String, String> environment) {
  final base = environment['TEST_TMPDIR'] ?? Directory.systemTemp.path;
  return '$base/linux_runtime_cache';
}

/// The lock on the screen and the held-awake session a macOS window needs.
Future<Future<void> Function()> _prepareMacOs(
  void Function(String message)? log,
) async {
  final lock = await DeviceLock.acquire('macos-gui', log: log);
  GuiSession? session;
  try {
    session = await GuiSession.hold();
    final state = await GuiSession.probe();
    if (state.screenLocked || state.displayAsleep) {
      throw StateError(
        'the app cannot show a window: ${GuiSession.explain(GuiSession.diagnose(state))} '
        '(Read: $state.)',
      );
    }
  } catch (_) {
    await session?.release();
    await lock.release();
    rethrow;
  }
  return () async {
    await session?.release();
    await lock.release();
  };
}

/// Runs the integration test [config] describes and returns the exit status
/// the target should end with.
///
/// [resolve] turns a runfiles path into a file. [environment] is the test's
/// environment: Bazel's variables for the selection, the timeout and the
/// report. [terminated] has an event when the test is told to end (Bazel
/// terminates a test that runs out of time): the run is undone as it ends any
/// other way, the app stopped and what the host gave given back, and ends with
/// 143. By default that is SIGTERM and SIGINT.
///
/// [readSource] reads the test source at a resolved path (by default, the file).
///
/// The goldens the app asks about are compared by the golden service the config
/// names, started by [startGoldenService] (by default as a process) when the
/// first is asked, and written instead of compared when [updateGoldens].
Future<int> runIntegrationTest(
  IntegrationRunnerConfig config, {
  required String Function(String runfilesPath) resolve,
  required DeviceChoice choice,
  required Map<String, String> environment,
  StringSink? out,
  StringSink? err,
  Stream<void>? terminated,
  bool updateGoldens = false,
  GoldenServiceLauncher? startGoldenService,
  String Function(String path)? readSource,
}) async {
  final sink = out ?? stdout;
  final errors = err ?? stderr;
  final TestSelection selection;
  try {
    selection = TestSelection.fromEnvironment(
      environment,
      fixedTags: TagSelection.fromAttribute(
        config.includeTags,
        config.excludeTags,
      ),
    );
  } on FormatException catch (e) {
    errors.writeln('integration_test: ${e.message}');
    return 64;
  }
  // The library's annotations, which give every case its tags, skips and
  // timeout: read before the app is launched, since a test whose annotations
  // cannot be read cannot be selected from.
  final SuiteAnnotations annotations;
  try {
    annotations = readSuiteAnnotations(config, resolve, readSource);
  } on FormatException catch (e) {
    errors.writeln(
      'integration_test: cannot read the annotations of '
      '${config.testDisplayName}: ${e.message}',
    );
    return 1;
  }
  // Touched before the run, as Bazel asks: it is how a runner says it supports
  // sharding at all, and Bazel 9 fails a sharded test whose runner never does.
  final shardStatus = environment['TEST_SHARD_STATUS_FILE'];
  if (shardStatus != null) File(shardStatus).writeAsStringSync('');

  // A suite the platform excludes is never launched, as `flutter test` never
  // loads it.
  final exclusion = annotations.exclusion;
  if (exclusion != null) {
    final note = StringBuffer();
    final status = await reportSuiteNotRun(
      suitePath: config.testDisplayName,
      note: exclusion,
      logPrefix: 'integration_test',
      xmlOutput: environment['XML_OUTPUT_FILE'],
      out: note,
    );
    sink.write(note);
    return status;
  }

  final teardown = _Teardown(choice.device, errors);
  final progress = _Progress();
  final ended = Completer<int>();
  final signals = (terminated ?? _terminationSignals()).listen((_) {
    if (ended.isCompleted) return;
    errors.writeln(
      'integration_test: the test was terminated while $progress, so it '
      'ends.',
    );
    // The status is the answer once the run is undone, whichever of this and
    // the run's own end undoes it first.
    ended.complete(143);
    unawaited(teardown.run());
  });
  try {
    final result = await Future.any([
      _drive(
        config,
        resolve: resolve,
        choice: choice,
        environment: environment,
        selection: selection,
        annotations: annotations,
        out: sink,
        err: errors,
        teardown: teardown,
        progress: progress,
        updateGoldens: updateGoldens,
        startGoldenService: startGoldenService,
      ),
      ended.future,
    ]);
    if (ended.isCompleted) await teardown.done;
    return result == 0 && teardown.failed ? 1 : result;
  } finally {
    await signals.cancel();
  }
}

/// SIGTERM and SIGINT, where the platform has them.
Stream<void> _terminationSignals() {
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  late final StreamController<void> controller;
  controller = StreamController<void>(
    onListen: () {
      if (Platform.isWindows) return;
      for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
        subscriptions.add(signal.watch().listen(controller.add));
      }
    },
    onCancel: () => Future.wait(subscriptions.map((s) => s.cancel())),
  );
  return controller.stream;
}

/// What a run is doing, and since when: what a run that is terminated says,
/// since a test that times out has nothing else to show for where its time
/// went.
class _Progress {
  final _run = Stopwatch()..start();
  final _stage = Stopwatch()..start();
  var _doing = 'starting';

  /// The run has started [doing], such as `launching the app`.
  set doing(String doing) {
    _doing = doing;
    _stage.reset();
  }

  @override
  String toString() =>
      '$_doing (for ${_stage.elapsed.inSeconds}s, '
      '${_run.elapsed.inSeconds}s into the run)';
}

/// What a run has to undo as it ends: the transport and the app it started
/// and what the host gave it. Once, however many things end the run.
class _Teardown {
  _Teardown(this._device, this._errors);

  final Device _device;
  final StringSink _errors;

  SuiteTransport? transport;
  GoldenHost? goldens;
  AppInstance? instance;
  Future<void> Function()? give;

  /// Whether something could not be undone, which fails the run: a simulator
  /// that was left behind is not a pass.
  bool failed = false;

  Future<void>? _running;

  /// Completes when [run] has.
  Future<void> get done => _running ?? Future.value();

  Future<void> run() => _running ??= _undo();

  Future<void> _undo() async {
    try {
      if (transport != null) await transport!.abandon('the run is over');
      // After the transport, whose end is the end of what the app asks.
      await goldens?.close();
      if (instance != null) {
        await _device.stop(instance!);
      } else {
        await _device.abandonLaunch();
      }
    } on Object catch (e) {
      failed = true;
      _errors.writeln('integration_test: stopping the app failed: $e');
    }
    final giveBack = give;
    if (giveBack != null) {
      try {
        await giveBack();
      } on StateError catch (e) {
        failed = true;
        _errors.writeln('integration_test: ${e.message}');
      }
    }
  }
}

Future<int> _drive(
  IntegrationRunnerConfig config, {
  required String Function(String runfilesPath) resolve,
  required DeviceChoice choice,
  required Map<String, String> environment,
  required TestSelection selection,
  required SuiteAnnotations annotations,
  required StringSink out,
  required StringSink err,
  required _Teardown teardown,
  required _Progress progress,
  required bool updateGoldens,
  required GoldenServiceLauncher? startGoldenService,
}) async {
  final bazelTimeout = environment['TEST_TIMEOUT'];
  final ceiling = testCeiling(bazelTimeout);
  final device = choice.device;

  try {
    // For an iOS simulator, making it; for an emulator, booting it.
    progress.doing = 'preparing the device';
    teardown.give = await choice.prepare();
  } on StateError catch (e) {
    err.writeln('integration_test: ${e.message}');
    return 1;
  }

  try {
    final AppInstance instance;
    try {
      progress.doing = 'launching the app';
      await device.preflight();
      final artifact = device.pickArtifact([
        for (final path in config.appArtifacts) resolve(path),
      ]);
      instance = teardown.instance = await device.launch(
        artifact,
        onLog: (line) => err.writeln('[app] ${line.text}'),
      );
    } on Object catch (e) {
      err.writeln('integration_test: launching the app failed: $e');
      return 1;
    }

    final IntegrationSuiteTransport connected;
    try {
      progress.doing = 'waiting for the app to start its test suite';
      connected = await choice.connect(device, instance, ceiling: ceiling);
    } on SuiteUnreachable catch (e) {
      err.writeln('integration_test: ${e.message}');
      return 1;
    }
    teardown.transport = connected;
    teardown.goldens = GoldenHost(
      connected,
      _goldenComparator(
        config,
        resolve: resolve,
        environment: environment,
        update: updateGoldens,
        ceiling: ceiling,
        start: startGoldenService,
        err: err,
      ),
      update: updateGoldens,
      log: (message) => err.writeln('integration_test: $message'),
    );

    progress.doing = 'running the suite';
    final outcome =
        await RemoteSuiteDriver(
          connected,
          suitePath: config.testDisplayName,
          metadata: annotations.handshakeMetadata(bazelTimeout),
          logPrefix: 'integration_test',
          out: out,
          err: err,
        ).run(
          selection: selection,
          xmlOutput: environment['XML_OUTPUT_FILE'],
          ceiling: ceiling,
        );
    out.writeln(outcome.summary());
    return outcome.exitCode;
  } finally {
    await teardown.run();
  }
}

/// The comparator for the goldens the app asks about: the service the config
/// names, or one that says there is none.
GoldenComparator _goldenComparator(
  IntegrationRunnerConfig config, {
  required String Function(String runfilesPath) resolve,
  required Map<String, String> environment,
  required bool update,
  required Duration ceiling,
  required GoldenServiceLauncher? start,
  required StringSink err,
}) {
  final goldens = config.goldens;
  if (goldens == null) {
    return const NoGoldenComparator(
      'this test was given no golden comparator. The `flutter_*_integration_test` '
      'macros declare one; a test made of the rules themselves gives its '
      'source as `src` and the comparator as `golden_service`.',
    );
  }
  final executable = resolve(goldens.executable);
  return GoldenServiceComparator(
    testPath: goldens.testSource,
    ceiling: ceiling,
    log: (line) => err.writeln('[golden service] $line'),
    environment: goldenServiceEnvironment(
      environment,
      goldens.environment,
      update: update,
    ),
    launch: (serviceEnvironment) => (start ?? _startProcess(executable))(
      serviceEnvironment,
    ),
  );
}

GoldenServiceLauncher _startProcess(String executable) =>
    (environment) => startGoldenServiceProcess(
      executable,
      environment,
      binary: '@rules_flutter//tools/dev_tool:integration_test_runner',
    );

/// The library annotations of [config]'s test source, read through [resolve] with
/// [readSource] (by default, the file).
///
/// Throws [FormatException] when the source cannot be read or its annotations
/// cannot be parsed.
SuiteAnnotations readSuiteAnnotations(
  IntegrationRunnerConfig config,
  String Function(String runfilesPath) resolve,
  String Function(String path)? readSource,
) {
  final path = resolve(config.source);
  final String contents;
  try {
    contents = (readSource ?? (p) => File(p).readAsStringSync())(path);
  } on FileSystemException catch (e) {
    throw FormatException('${e.message}: $path');
  }
  return SuiteAnnotations.parse(config.testDisplayName, contents);
}
