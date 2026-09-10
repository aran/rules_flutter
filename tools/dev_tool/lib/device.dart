/// Device abstraction for launching Flutter apps.
///
/// Handles platform-specific launch, VM service discovery, and
/// process lifecycle management.
///
/// ## One log source per platform
///
/// Every launched app exposes its console output on [AppInstance.logs]. Which
/// source feeds that stream is a per-platform decision, and there is exactly
/// one source per platform — this is an invariant, not a preference:
///
/// | Platform            | Source                                        |
/// | ------------------- | --------------------------------------------- |
/// | macOS/Linux/Windows | the app process's stdout + stderr             |
/// | Android             | `adb logcat`                                  |
/// | iOS Simulator       | a dedicated `simctl spawn log stream`         |
/// | iOS device          | `devicectl --console`, plus lldb's own output |
/// | Chrome (DDC)        | DWDS VM service `Stdout`/`Stderr` streams     |
/// | Chrome (WASM)       | CDP `Runtime.consoleAPICalled`                |
/// | attach mode         | VM service `Stdout`/`Stderr` streams          |
///
/// A Dart `print()` on a native device reaches *both* the process's stdout and
/// the VM service's `Stdout` stream, so subscribing to both would print every
/// line twice. VM-service streams are therefore used only where no process log
/// source exists (web, attach). This mirrors flutter_tools' `DeviceLogReader`
/// and is the reason the tempting "just read the VM service everywhere"
/// simplification is wrong.
///
/// ## Finding the VM service
///
/// On every platform above, the VM-service URI arrives in-band: the engine
/// prints it, so discovery is a *reader* of the log stream and never an owner
/// of the underlying subscriptions (see [pumpProcessLines] and
/// [discoverVmServiceUri]).
///
/// A physical iOS device is the one exception, and it is out-of-band rather
/// than a second in-band source: a wirelessly attached device has no console
/// channel at all, and the one a wired device has belongs to the `devicectl`
/// invocation that launched the app. The URI is taken from the app's
/// `_dartVmService._tcp` mDNS advertisement instead
/// ([MdnsVmServiceDiscovery]). That is the single mechanism for iOS hardware,
/// wired and wireless alike; nothing races it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'cdp_console.dart';
import 'compiler_config.dart';
import 'host_tools.dart';
import 'logging.dart';
import 'mdns_vm_service_discovery.dart';
import 'reload_strategy.dart';
import 'runfiles_helper.dart';
import 'temp_dir.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'teardown.dart';
import 'web_module_server.dart';
import 'web_options.dart';

export 'app_log.dart' show AppLogLine, AppLogStream, LogPage;
export 'host_tools.dart' show HostTool, MissingHostToolException;

final _logger = Logger('dev_tool.device');

/// Report a process the OS would not let us kill.
///
/// Every `stop` implementation kills the process it launched; a refused kill
/// leaves an app (or a log tailer) running that the next run will collide with,
/// so it must be said out loud rather than swallowed by the `await exitCode`
/// that follows.
void _warnKillFailed(String what, Process process) => _logger.warning({
  'message': 'process_kill_failed',
  'text':
      'Could not kill the $what process (pid ${process.pid}); it may '
      'still be running. Stop it by hand if the next run finds the port or '
      'window already taken.',
  'process': what,
  'pid': process.pid,
});

/// Stop [process], escalating past a SIGTERM it refuses.
///
/// SIGTERM is a request: a wedged process can take it and keep running, so
/// `await process.exitCode` on its own is unbounded.
///
/// SIGKILL is not refusable, so here the bound has a real remedy rather than
/// only a report. Should even that not land, this returns anyway and says so —
/// a teardown that cannot confirm a death is still better than one that never
/// ends, and the user needs to be told which they got.
///
/// The escalation's own `kill` return value is deliberately not checked: a
/// process that exits in the race between the bound expiring and the SIGKILL
/// makes it report `false`, and that is success, not failure.
Future<void> _stopProcess(String what, Process process, Duration bound) async {
  if (!process.kill()) _warnKillFailed(what, process);
  if (await _exitedWithin(process, bound)) return;

  _logger.warning({
    'message': 'process_kill_escalated',
    'text':
        'The $what process (pid ${process.pid}) did not exit within '
        '${bound.inMilliseconds}ms of being asked to. Sending SIGKILL.',
    'process': what,
    'pid': process.pid,
  });
  process.kill(ProcessSignal.sigkill);
  if (await _exitedWithin(process, bound)) return;

  _logger.severe({
    'message': 'process_survived_sigkill',
    'text':
        'The $what process (pid ${process.pid}) did not exit even after '
        'SIGKILL. Ending the run without it; kill it by hand if the next run '
        'finds the port or window already taken.',
    'process': what,
    'pid': process.pid,
  });
}

/// Whether [process] exits within [bound].
Future<bool> _exitedWithin(Process process, Duration bound) =>
    process.exitCode.then((_) => true).timeout(bound, onTimeout: () => false);

/// Run a helper to completion under [bound], or kill it and say what it said.
///
/// `Process.run` cannot express this: it has no bound, and there is no handle
/// to kill through even if there were. A helper that never exits therefore
/// makes its *caller* never return, and where the caller is an HTTP handler
/// that is a request held open forever — the one outcome that leaves the other
/// end with nothing to act on.
///
/// Both output streams are drained from the moment the process exists, into
/// buffers rather than futures. A read started only after the deadline loses
/// whatever the helper managed to say before it wedged, which is exactly the
/// part a reader needs; and buffers can be read on the expiry path without
/// awaiting anything, so the diagnostic itself cannot be what hangs.
///
/// SIGKILL rather than SIGTERM-then-SIGKILL: this is not a teardown that a
/// well-behaved helper should get to finish, it is a wedge, and an escalation
/// ladder here would only add a second bound to wait out.
Future<ProcessResult> runProcessBounded(
  ProcessStarterWithEnvironment start,
  String executable,
  List<String> arguments, {
  required Map<String, String> environment,
  required Duration bound,
  required String what,
}) async {
  final process = await start(executable, arguments, environment);
  final out = StringBuffer();
  final err = StringBuffer();
  final drained = Future.wait([
    process.stdout.transform(utf8.decoder).forEach(out.write),
    process.stderr.transform(utf8.decoder).forEach(err.write),
  ]);
  final int exitCode;
  try {
    exitCode = await process.exitCode.timeout(bound);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    throw StateError(
      '$what (pid ${process.pid}) did not answer within '
      '${bound.inMilliseconds}ms and was killed. What it had written by then, '
      'on stderr: ${err.isEmpty ? '(nothing)' : err}',
    );
  }
  await drained;
  return ProcessResult(process.pid, exitCode, out.toString(), err.toString());
}

/// Called for each line of a running app's console output.
typedef AppLogListener = void Function(AppLogLine line);

/// A running Flutter application instance.
class AppInstance {
  final Process process;
  final Uri? vmServiceUri;

  /// Optional HTTP server (used by WebDevice).
  final HttpServer? server;

  /// The app's console output, for the lifetime of the run.
  ///
  /// Buffered, so a consumer that attaches after launch still sees everything
  /// printed during startup. Closed by the owning device's `stop()`.
  final AppLogStream logs;

  /// Helper processes spawned alongside [process] that must die with the run —
  /// e.g. the iOS Simulator's second `log stream`. Tracked here so `stop()`
  /// cannot leak them, rather than each device inventing its own field.
  final List<Process> auxiliaryProcesses;

  /// Temporary directories this launch created that live as long as it does —
  /// an unpacked `.app`, a staging copy, a throwaway browser profile.
  ///
  /// Here for the same reason [auxiliaryProcesses] is: the directory belongs to
  /// the launch, not to the device object, and a device that tracks one
  /// privately never deletes it.
  final List<Directory> scratchDirs;

  AppInstance({
    required this.process,
    this.vmServiceUri,
    this.server,
    AppLogStream? logs,
    this.auxiliaryProcesses = const [],
    this.scratchDirs = const [],
  }) : logs = logs ?? AppLogStream();

  /// Kill every [auxiliaryProcesses] entry and await its exit.
  /// [bound] is how long each one gets before it is escalated to SIGKILL —
  /// these are the same refusable SIGTERMs every other stopped process gets,
  /// and a log tailer that ignores one would hang the whole teardown.
  Future<void> disposeAuxiliaryProcesses(Duration bound) async {
    await Future.wait(
      auxiliaryProcesses.map((aux) => _stopProcess('auxiliary', aux, bound)),
    );
  }

  /// Remove every [scratchDirs] entry.
  ///
  /// Call after the processes that were using them have exited: a directory
  /// deleted out from under a still-running program comes back partly written.
  Future<void> disposeScratchDirs() async {
    for (final dir in scratchDirs) {
      await deleteTempDir(dir);
    }
  }
}

/// Abstract device that can launch and manage a Flutter app.
abstract class Device {
  /// How long [stop] waits on any one thing it is stopping before giving up on
  /// that step and moving to the next.
  ///
  /// Teardown talks to peers this process does not control — a browser, an
  /// app's VM service, a third-party service's own shutdown — and any of them
  /// can stop answering. Every await on one is bounded by this, so a wedged
  /// peer costs a run a few seconds instead of never returning: the whole
  /// chain must reach the kill, and `flutter_bazel` must come back.
  ///
  /// Settable so tests can drive the expiry paths in milliseconds instead of
  /// waiting out the real bound.
  Duration teardownBound = const Duration(seconds: 5);

  /// Launch the app and return the running instance.
  ///
  /// [appPath] is the path to the built application artifact.
  ///
  /// [onLog] is attached to the app's output stream *before* VM-service
  /// discovery begins, so a caller sees startup output as it happens rather
  /// than in a burst once `launch` returns. That matters most when discovery
  /// never succeeds: an app that crashes before binding its VM service prints
  /// the reason during the discovery window. Callers that pass [onLog] must
  /// not also subscribe to [AppInstance.logs], or every line arrives twice.
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog});

  /// Stop the running app.
  Future<void> stop(AppInstance instance);

  /// The external programs a launch on this device will drive.
  ///
  /// Declared rather than discovered at each call site so [preflight] can check
  /// them all before a run does any work, and declared *per device* so an iOS,
  /// macOS or Chrome run is never made to install the Android SDK. Async
  /// because the answer can depend on the device itself: a cabled iOS device is
  /// reached through an `iproxy` forward and a wireless one is not.
  Future<List<HostTool>> requiredHostTools() async => const [];

  /// Fail now, by name, if the host is missing anything this device needs.
  ///
  /// Called before the build, so a missing `aapt2` or an unattached phone is
  /// reported in seconds. Without it the shortfall surfaces mid-launch as a
  /// symptom instead of a cause.
  Future<void> preflight() async {
    for (final tool in await requiredHostTools()) {
      tool.require();
    }
  }

  /// Capture a screenshot of the running app.
  ///
  /// For native platforms, uses the VM service `_flutter.screenshot` extension
  /// (pass [vmClient]). For web, subclasses override with CDP.
  /// Throws [UnsupportedError] if no VM client is available.
  ///
  /// [window] is an optional, platform-specific selector for which window to
  /// capture (e.g. on macOS, the exact window title). Devices that don't
  /// support window selection ignore it.
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    throw UnsupportedError(
      'Screenshot not supported on $name without VM service',
    );
  }

  /// Whether `_flutter.screenshot` — the VM-service capture of just the
  /// widget tree — can ever succeed on this device.
  ///
  /// The engine cannot encode a compressed screenshot under Impeller, so the
  /// RPC fails with a bare "Could not capture image screenshot" wherever
  /// Impeller renders, and there is no engine screenshot on web at all.
  /// Declared rather than inferred from a failure, so a caller is told the
  /// request can never work — and which endpoint does — instead of getting a
  /// 500 that reads as transient and invites a retry.
  ///
  /// False for every device at the pinned Flutter, because every platform
  /// renders with Impeller by default there.
  ///
  /// An app that opts out of Impeller — the desktop embedders and Android
  /// still allow it — *could* serve the RPC, and this gives up on it. That is
  /// deliberate: the renderer is a runtime property of the app, so nothing
  /// here can tell the two apart without asking it, and the `native` endpoint
  /// captures both. Kept a getter rather than made a constant so a device that
  /// can serve the RPC has somewhere to say so.
  bool get supportsFlutterScreenshot => false;

  /// Whether to hold the app's root isolate at the start of `main()`.
  ///
  /// Set before [launch]: every platform delivers it as a launch-time engine
  /// argument, so it cannot be turned on afterwards. The app then sits at
  /// `PauseStart` until a debugger resumes it — which is the point, and also
  /// why nothing that needs a running framework (a first frame, a service
  /// extension, an `app.*` command) will answer until it does.
  bool startPaused = false;

  /// Whether filesystem paths on this device are Windows-shaped.
  ///
  /// The device answers, not the host: a devFS path comes back from the target
  /// VM, and converting it with `Platform.isWindows` is right only while the
  /// two happen to agree. Driving an Android phone from a Windows desktop is
  /// where they do not.
  bool get usesWindowsPaths => false;

  /// Display name for this device.
  String get name;

  /// How long a single hot reload or hot restart RPC may take here.
  ///
  /// A latency budget, not a correctness knob: the call is abandoned and the
  /// VM-service connection force-closed when it expires, so it has to be
  /// longer than the slowest legitimate apply on this platform. The default
  /// suits a host process, where the VM is local and a restart is
  /// milliseconds of work.
  Duration get applyTimeout => const Duration(seconds: 30);

  /// Pick the runnable artifact from a target's cquery outputs.
  ///
  /// Default returns the first output. Subclasses override when the
  /// rule emits multiple outputs in an order that doesn't put the
  /// runnable artifact first — `android_binary`, for example, lists
  /// `<name>_deploy.jar` before `<name>.apk`, and the deploy jar is
  /// not installable.
  String pickArtifact(List<String> outputs) => outputs.first;

  /// Platform-specific arguments for `bazel build`.
  ///
  /// These are injected into `bazel build` and `bazel cquery` to ensure
  /// correct cross-compilation and output resolution.
  List<String> get buildArgs => const [];

  /// Create the compiler config for hot reload on this platform.
  ///
  /// Returns null if this device does not support hot reload.
  CompilerConfig? createCompilerConfig(
    ToolchainPaths toolchain, {
    WebToolchainPaths? webToolchain,
    List<String> fileSystemRoots = const [],
    String fileSystemScheme = '',
    List<String> dartDefines = const [],
    String dartPluginRegistrantUri = '',
    List<String> enableExperiments = const [],
  }) => NativeCompilerConfig(
    patchedSdkRoot: toolchain.patchedSdkRoot,
    fileSystemRoots: fileSystemRoots,
    fileSystemScheme: fileSystemScheme,
    dartDefines: dartDefines,
    dartPluginRegistrantUri: dartPluginRegistrantUri,
    enableExperiments: enableExperiments,
  );

  /// Create the reload strategy for this platform.
  ///
  /// Every device that gets here has one: a device this cannot answer for
  /// refuses by name (see [WebDevice.createReloadStrategy]) rather than
  /// returning null.
  ReloadStrategy createReloadStrategy() => VmServiceReloadStrategy();
}

/// macOS desktop device.
class MacOSDevice extends Device {
  final ProcessRunSync _runProcess;
  final ProcessStarter? _injectedStart;

  /// Starts the bundled screenshot helper, when a test supplies one.
  ///
  /// Separate from [_injectedStart], which carries the app's own launch
  /// environment: a test that fakes a launch must not thereby fake every
  /// capture too.
  final ProcessStarter? _injectedScreenshotStart;

  MacOSDevice({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
    ProcessStarter? startScreenshotProcess,
  }) : _runProcess = runProcess ?? Process.run,
       _injectedStart = startProcess,
       _injectedScreenshotStart = startScreenshotProcess;

  Future<Process> _startProcess(String exe, List<String> args) =>
      (_injectedStart ?? _defaultStart)(exe, args);

  /// Start the app with the engine switches this launch asked for.
  ///
  /// An instance method because the switches depend on [startPaused], which is
  /// set on the device after it is constructed. The
  /// injected [_startProcess] bypasses this entirely, which is why the
  /// environment it builds lives in [desktopLaunchEnvironment] where a test
  /// can reach it.
  Future<Process> _defaultStart(String exe, List<String> args) => Process.start(
    exe,
    args,
    environment: desktopLaunchEnvironment(startPaused: startPaused),
  );

  @override
  String get name => 'macOS';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    // Extract .app from .zip if needed (Bazel macOS bundles are zipped).
    String resolvedPath = appPath;
    Directory? extracted;
    if (appPath.endsWith('.zip')) {
      final unpacked = await _extractAppFromZip(appPath);
      resolvedPath = unpacked.appPath;
      extracted = unpacked.dir;
    }

    // For .app bundles, find the executable inside.
    String executable;
    if (resolvedPath.endsWith('.app')) {
      // The executable is at Contents/MacOS/<name>.
      final bundleName = resolvedPath.split('/').last.replaceAll('.app', '');
      executable = '$resolvedPath/Contents/MacOS/$bundleName';
    } else {
      executable = resolvedPath;
    }

    final process = await _startProcess(
      executable,
      [],
    );

    final logs = _startProcessLogs(process, onLog);
    final vmServiceUri = await discoverVmServiceUri(logs);

    return AppInstance(
      process: process,
      vmServiceUri: vmServiceUri,
      logs: logs,
      // The app runs out of this directory, so it goes only once the process
      // has exited — which `stop` awaits before disposing it.
      scratchDirs: [if (extracted != null) extracted],
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    await _stopProcess('macOS app', instance.process, teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  /// How long the bundled ScreenCaptureKit helper gets to answer.
  ///
  /// The capture runs inside an HTTP handler, so a helper that never returns
  /// is an endpoint that never answers — the request stays open and the caller
  /// learns nothing at all, which is strictly worse than any error. Ten seconds
  /// is a wedge, not a slow machine.
  ///
  /// ScreenCaptureKit is a real candidate for wedging: it is TCC-gated, and an
  /// *undecided* Screen Recording permission blocks rather than refuses.
  ///
  /// Settable so a test can drive the expiry in milliseconds.
  Duration screenshotBound = const Duration(seconds: 10);

  /// Captures the launched app's windows via the bundled Swift helper.
  ///
  /// With [vmClient] set, uses `_flutter.screenshot` (Flutter view only).
  /// Otherwise invokes `tools/macos_screenshot:screenshot`, which uses
  /// ScreenCaptureKit's `SCShareableContent` to enumerate on-screen windows
  /// owned by the app's PID and either composites all of them or — when
  /// [window] is provided — captures only the window whose `SCWindow.title`
  /// matches exactly. The helper requires Screen Recording permission for
  /// the terminal that launched the dev tool.
  ///
  /// Bounded by [screenshotBound]: see there for why an unbounded capture is
  /// the one failure this path must not have.
  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    final resolved = resolveRunfileWithManifest(
      'rules_flutter/tools/macos_screenshot/screenshot',
    );
    if (resolved == null) {
      throw StateError(
        'Could not find bundled macOS screenshot tool. '
        'Build first: bazel build //tools/dev_tool:flutter_bazel',
      );
    }
    final result = await runProcessBounded(
      _startScreenshotProcess,
      resolved.path,
      [
        '--pid',
        '${instance.process.pid}',
        '--output',
        outputPath,
        if (window != null) ...['--title', window],
      ],
      environment: {
        ...Platform.environment,
        if (resolved.manifestPath != null)
          'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
      },
      bound: screenshotBound,
      what: 'The bundled macOS screenshot helper',
    );
    if (result.exitCode != 0) {
      throw StateError('macOS screenshot failed: ${result.stderr}');
    }
  }

  Future<Process> _startScreenshotProcess(
    String exe,
    List<String> args,
    Map<String, String> environment,
  ) => _injectedScreenshotStart != null
      ? _injectedScreenshotStart(exe, args)
      : Process.start(exe, args, environment: environment);

  /// Extract .app bundle from a .zip archive.
  ///
  /// Returns the directory as well as the bundle: the caller runs the app out
  /// of it, so it is the caller — not this function — that knows when it can go.
  Future<({String appPath, Directory dir})> _extractAppFromZip(
    String zipPath,
  ) async {
    final tempDir = await createTempDir('flutter_macos_');
    try {
      final result = await _runProcess('unzip', [
        '-oq',
        zipPath,
        '-d',
        tempDir.path,
      ]);
      if (result.exitCode != 0) {
        throw StateError('Failed to extract zip: ${result.stderr}');
      }
      // Find the .app bundle inside.
      final apps = tempDir
          .listSync()
          .where((e) => e.path.endsWith('.app'))
          .toList();
      if (apps.isEmpty) {
        throw StateError('No .app bundle found in zip');
      }
      return (appPath: apps.first.path, dir: tempDir);
    } catch (_) {
      // Nothing usable came out of the archive; the half-unpacked copy is only
      // going to sit there.
      await deleteTempDir(tempDir);
      rethrow;
    }
  }
}

/// Linux desktop device.
class LinuxDevice extends Device {
  final ProcessRunSync _runProcess;
  final ProcessStarter? _injectedStart;

  LinuxDevice({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) : _runProcess = runProcess ?? Process.run,
       _injectedStart = startProcess;

  Future<Process> _startProcess(String exe, List<String> args) =>
      (_injectedStart ?? _defaultStart)(exe, args);

  /// Start the app with the engine switches this launch asked for.
  ///
  /// An instance method because the switches depend on [startPaused], which is
  /// set on the device after it is constructed. The
  /// injected [_startProcess] bypasses this entirely, which is why the
  /// environment it builds lives in [desktopLaunchEnvironment] where a test
  /// can reach it.
  Future<Process> _defaultStart(String exe, List<String> args) => Process.start(
    exe,
    args,
    environment: desktopLaunchEnvironment(startPaused: startPaused),
  );

  @override
  String get name => 'Linux';

  @override
  List<String> get buildArgs => Platform.isLinux
      ? const []
      : const ['--platforms=@rules_flutter//flutter/platforms:linux_x64'];

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    // Bundle directories contain the executable at <dir>/<name>.
    String executable = appPath;
    if (FileSystemEntity.isDirectorySync(appPath)) {
      final dirName = p.basename(appPath);
      executable = p.join(appPath, dirName);
    }

    final process = await _startProcess(executable, []);
    final logs = _startProcessLogs(process, onLog);
    final vmServiceUri = await discoverVmServiceUri(logs);
    return AppInstance(
      process: process,
      vmServiceUri: vmServiceUri,
      logs: logs,
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    await _stopProcess('Linux app', instance.process, teardownBound);
    await instance.logs.close();
  }

  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    final result = await _runProcess('scrot', [outputPath]);
    if (result.exitCode != 0) {
      throw StateError('scrot failed: ${result.stderr}');
    }
  }
}

/// Windows desktop device.
class WindowsDevice extends Device {
  final ProcessStarter? _injectedStart;
  final Directory Function() _makeStagingDir;
  Directory? _staged;

  /// Starts the bundled screenshot helper, when a test supplies one.
  ///
  /// Separate from [_injectedStart], which carries the app's own launch
  /// environment: a test that fakes a launch must not thereby fake every
  /// capture too.
  final ProcessStarter? _injectedScreenshotStart;

  WindowsDevice({
    ProcessStarter? startProcess,
    ProcessStarter? startScreenshotProcess,
    Directory Function()? makeStagingDir,
  }) : _injectedStart = startProcess,
       _injectedScreenshotStart = startScreenshotProcess,
       _makeStagingDir = makeStagingDir ?? _defaultStagingDir;

  Future<Process> _startProcess(String exe, List<String> args) =>
      (_injectedStart ?? _defaultStart)(exe, args);

  static Directory _defaultStagingDir() =>
      Directory.systemTemp.createTempSync('flutter_bazel_win_app');

  /// Start the app with the engine switches this launch asked for.
  ///
  /// An instance method because the switches depend on [startPaused], which is
  /// set on the device after it is constructed. The
  /// injected [_startProcess] bypasses this entirely, which is why the
  /// environment it builds lives in [desktopLaunchEnvironment] where a test
  /// can reach it.
  Future<Process> _defaultStart(String exe, List<String> args) => Process.start(
    exe,
    args,
    environment: desktopLaunchEnvironment(startPaused: startPaused),
  );

  @override
  bool get usesWindowsPaths => true;

  @override
  String get name => 'Windows';

  @override
  List<String> get buildArgs => Platform.isWindows
      ? const []
      : const ['--platforms=@rules_flutter//flutter/platforms:windows_x64'];

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    // Run from a copy, never from `bazel-out` itself.
    //
    // Windows holds an exclusive lock on a running executable image, so while
    // the app is up, bazel cannot replace `bin/app/app.exe` — and the bundling
    // action does exactly that on any rebuild, which `app.restart` performs
    // before it swaps the kernel in. macOS and Linux let a running image be
    // unlinked and replaced, so only Windows needs the copy.
    final launchPath = _stage(appPath);

    // Bundle directories contain the executable at <dir>/<name>.exe.
    String executable = launchPath;
    if (FileSystemEntity.isDirectorySync(launchPath)) {
      final dirName = p.basename(launchPath);
      executable = p.join(launchPath, '$dirName.exe');
    }

    final process = await _startProcess(executable, []);
    final logs = _startProcessLogs(process, onLog);
    final vmServiceUri = await discoverVmServiceUri(logs);
    return AppInstance(
      process: process,
      vmServiceUri: vmServiceUri,
      logs: logs,
    );
  }

  /// Copies the built bundle out of `bazel-out` and returns the copy's path.
  ///
  /// A bundle is a directory whose layout the runner depends on — it resolves
  /// `data/flutter_assets` relative to its own executable — so the whole tree
  /// is copied, not just the `.exe`. Each launch gets a fresh directory and
  /// the previous one is removed, so a relaunch never runs yesterday's assets.
  String _stage(String appPath) {
    _clearStaging();
    final staging = _makeStagingDir();
    _staged = staging;

    final source = FileSystemEntity.typeSync(appPath);
    if (source != FileSystemEntityType.directory) {
      final dest = p.join(staging.path, p.basename(appPath));
      File(appPath).copySync(dest);
      return dest;
    }

    final dest = Directory(p.join(staging.path, p.basename(appPath)))
      ..createSync(recursive: true);
    for (final entity in Directory(appPath).listSync(recursive: true)) {
      final relative = p.relative(entity.path, from: appPath);
      final target = p.join(dest.path, relative);
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        Directory(p.dirname(target)).createSync(recursive: true);
        entity.copySync(target);
      }
    }
    return dest.path;
  }

  void _clearStaging() {
    final staged = _staged;
    _staged = null;
    if (staged != null && staged.existsSync()) {
      staged.deleteSync(recursive: true);
    }
  }

  @override
  Future<void> stop(AppInstance instance) async {
    await _stopProcess('Windows app', instance.process, teardownBound);
    await instance.logs.close();
    _clearStaging();
  }

  /// How long the bundled DXGI screenshot helper gets to answer.
  ///
  /// The capture runs inside an HTTP handler, so a helper that never returns
  /// is an endpoint that never answers: the request stays open and the caller
  /// learns nothing at all, which is strictly worse than any error. Desktop
  /// Duplication is a plausible way to wedge — it blocks on the compositor
  /// handing over a frame, and a session with nothing being drawn to (a locked
  /// workstation, an RDP session that has detached) is a real state on a CI
  /// runner.
  ///
  /// Generous rather than tight: what matters here is that the request ends.
  ///
  /// Settable so a test can drive the expiry in milliseconds.
  Duration screenshotBound = const Duration(seconds: 30);

  /// Captures the screen with the bundled DXGI Desktop Duplication helper.
  ///
  /// Bounded by [screenshotBound]: see there for why an unbounded capture is
  /// the one failure this path must not have.
  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    // GDI CopyFromScreen cannot capture D3D/Flutter surfaces.
    // Use DXGI Desktop Duplication via bundled dxcam py_binary.
    final resolved = resolveRunfileWithManifest(
      'rules_flutter/tools/windows_screenshot/screenshot',
    );
    if (resolved == null) {
      throw StateError(
        'Could not find bundled Windows screenshot tool. '
        'Build first: bazel build //tools/dev_tool:flutter_bazel',
      );
    }
    final result = await runProcessBounded(
      _startScreenshotProcess,
      resolved.path,
      [outputPath],
      environment: {
        ...Platform.environment,
        if (resolved.manifestPath != null)
          'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
      },
      bound: screenshotBound,
      what: 'The bundled Windows screenshot helper',
    );
    if (result.exitCode != 0) {
      throw StateError('DXGI screenshot failed: ${result.stderr}');
    }
  }

  Future<Process> _startScreenshotProcess(
    String exe,
    List<String> args,
    Map<String, String> environment,
  ) => _injectedScreenshotStart != null
      ? _injectedScreenshotStart(exe, args)
      : Process.start(exe, args, environment: environment);
}

/// Signature for running a process and returning its result (allows test injection).
typedef ProcessRunSync =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Signature for starting a streaming process (allows test injection).
typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// [ProcessStarter] for a helper whose environment the caller assembles.
///
/// The bundled screenshot helpers need `RUNFILES_MANIFEST_FILE` forwarded to
/// find their own runfiles, and that path is only known at the call site.
typedef ProcessStarterWithEnvironment =
    Future<Process> Function(
      String executable,
      List<String> arguments,
      Map<String, String> environment,
    );

/// The environment a desktop Flutter app is launched with.
///
/// The desktop embedders take engine switches from the environment and nowhere
/// else — `FLUTTER_ENGINE_SWITCHES` holds the count and `FLUTTER_ENGINE_SWITCH_<N>`
/// holds each switch, numbered from 1. The runner's own argv is passed to the
/// Dart entrypoint, not to the engine, so there is no command line to put them
/// on.
///
/// A function rather than something assembled inline in each device's process
/// starter: the starters are the one seam tests replace, so anything built
/// inside them is invisible to every test that injects one.
///
/// [base] defaults to this process's environment, which the app inherits.
Map<String, String> desktopLaunchEnvironment({
  bool startPaused = false,
  Map<String, String>? base,
}) {
  final switches = <String>[
    if (startPaused) 'start-paused=true',
  ];
  return {
    ...(base ?? Platform.environment),
    // Always: a fixed port would collide across a multi-device run, and 0
    // makes the embedder pick one and announce it on stdout, which is where
    // [discoverVmServiceUri] reads it from.
    'FLUTTER_VM_SERVICE_PORT': '0',
    if (switches.isNotEmpty) 'FLUTTER_ENGINE_SWITCHES': '${switches.length}',
    for (var i = 0; i < switches.length; i++)
      'FLUTTER_ENGINE_SWITCH_${i + 1}': switches[i],
  };
}

/// Extract package name and launchable activity from an APK via aapt2.
///
/// [aapt2Path] names the binary to run; when omitted it is resolved through
/// [aapt2Tool], which throws a [MissingHostToolException] rather than handing
/// `Process.run` a bare `'aapt2'` and letting a misconfigured SDK surface as a
/// failure to launch.
Future<({String packageName, String? activityName})> extractPackageInfo(
  String apkPath, {
  ProcessRunSync? runProcess,
  String? aapt2Path,
}) async {
  final run = runProcess ?? Process.run;
  final aapt2 = aapt2Path ?? aapt2Tool().require();
  final result = await run(aapt2, ['dump', 'badging', apkPath]);
  if (result.exitCode != 0) {
    throw StateError(
      '`$aapt2 dump badging $apkPath` failed '
      '(exit ${result.exitCode}): ${result.stderr}',
    );
  }
  final output = result.stdout as String;
  final pkgMatch = RegExp(r"package: name='([^']+)'").firstMatch(output);
  if (pkgMatch == null) {
    throw StateError('Could not extract package name from APK');
  }
  final actMatch = RegExp(
    r"launchable-activity: name='([^']+)'",
  ).firstMatch(output);
  return (
    packageName: pkgMatch.group(1)!,
    activityName: actMatch?.group(1),
  );
}

/// Android device (via adb).
class AndroidDevice extends Device {
  final String? deviceId;
  String? _packageName;
  String? _activityName;
  final String abi;
  final String? _explicitAdbPath;
  final String? _explicitAapt2Path;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  /// Starts the `adb` a capture shells to, when a test supplies one.
  ///
  /// Separate from [_startProcess], which is the launch's own logcat: a test
  /// that fakes a launch must not thereby fake every capture too.
  final ProcessStarter? _injectedScreenshotStart;

  /// The host port `adb forward tcp:0` allocated for this launch, if any.
  ///
  /// Held so [stop] can remove exactly the forward this launch created. The
  /// forward is not a process: it is state inside the adb *server*, which
  /// outlives every dev tool run and every device disconnect, so nothing
  /// reclaims it on its own. Clearing all forwards instead would take out
  /// another session's on the same host.
  int? _forwardedHostPort;

  /// Whether the upcoming launch expects the app to host a Dart VM service
  /// (debug/JIT builds). Set by the run command before [launch]; enables the
  /// INTERNET-permission preflight, which release/profile launches skip.
  bool expectsVmService = false;

  AndroidDevice({
    this.deviceId,
    String? packageName,
    String? activityName,
    this.abi = 'arm64',
    String? adbPath,
    String? aapt2Path,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
    ProcessStarter? startScreenshotProcess,
  }) : _packageName = packageName,
       _activityName = activityName,
       _explicitAdbPath = adbPath,
       _explicitAapt2Path = aapt2Path,
       _runProcess = runProcess ?? Process.run,
       _startProcess = startProcess ?? Process.start,
       _injectedScreenshotStart = startScreenshotProcess;

  /// The `adb` to run, resolved on first use.
  ///
  /// Lazy so that merely naming an Android serial on a machine with no SDK is
  /// not itself an error — [preflight] is where that gets reported, with the
  /// context that a run is about to need it.
  late final String adbPath = _explicitAdbPath ?? adbTool().require();

  /// The `aapt2` to run, resolved on first use. Only a launch that has to read
  /// the APK's manifest touches it.
  late final String aapt2Path = _explicitAapt2Path ?? aapt2Tool().require();

  @override
  Future<List<HostTool>> requiredHostTools() async => [
    if (_explicitAdbPath == null) adbTool(),
    // Needed only to read the package name and launchable activity out of
    // the APK, which a caller that already named them skips.
    if (_packageName == null && _explicitAapt2Path == null) aapt2Tool(),
  ];

  @override
  String get name => 'Android${deviceId != null ? ' ($deviceId)' : ''}';

  @override
  String pickArtifact(List<String> outputs) {
    // android_binary emits `<name>_deploy.jar`, `<name>_unsigned.apk`,
    // and `<name>.apk`. Only the signed `.apk` is installable; the
    // deploy jar comes first in the output list and would trip
    // `adb install` with `filename doesn't end .apk or .apex`.
    for (final f in outputs) {
      if (f.endsWith('.apk') && !f.endsWith('_unsigned.apk')) return f;
    }
    return outputs.first;
  }

  @override
  List<String> get buildArgs => [
    '--platforms=@rules_flutter//flutter/platforms:android_$abi',
  ];

  /// Build the common adb prefix args (includes -s <deviceId> if set).
  List<String> _adbArgs(List<String> args) {
    if (deviceId != null) return ['-s', deviceId!, ...args];
    return args;
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    final packageName = _packageName ?? await _readPackageName(appPath);

    // Step 1: Install the APK.
    final installResult = await _runProcess(
      adbPath,
      _adbArgs(['install', '-r', appPath]),
    );
    if (installResult.exitCode != 0) {
      final stderr = '${installResult.stderr}';
      if (stderr.contains('INSTALL_FAILED_INSUFFICIENT_STORAGE')) {
        throw StateError(
          await _insufficientStorageMessage(appPath, packageName, stderr),
        );
      }
      throw StateError('adb install failed: $stderr');
    }

    // Step 1a: Debug launches await the VM service, which can never come up
    // without android.permission.INTERNET — fail fast instead.
    if (expectsVmService) {
      await _verifyInternetPermission(packageName, appPath);
    }

    // Step 2: Start adb logcat — the app's log source as well as where the
    // VM-service announcement appears.
    //
    // Deliberately unfiltered at the adb level (`-v time`, no tag spec) with
    // filtering done in Dart by [androidLogFilter]: an adb-level tag spec such
    // as `flutter:I *:S` silences everything but the `flutter` tag, hiding Java
    // exceptions (`AndroidRuntime`), VM messages (`DartVM`) and native crashes
    // — exactly the output you most need when an app misbehaves. Matches
    // flutter_tools' AdbLogReader, which filters host-side for the same reason.
    final logcat = await _startProcess(
      adbPath,
      _adbArgs(['logcat', '-v', 'time', '-T', '1']),
    );
    // logcat has no stdout/stderr split: severity lives in the line's tag, so
    // [androidLogFilter] decides, and the raw stderr channel (adb's own
    // diagnostics) is not treated as app error output.
    final logs = _startProcessLogs(
      logcat,
      onLog,
      stderrIsError: false,
      transform: androidLogFilter,
    );

    // Step 3: Launch the activity.
    final activity = _activityName ?? '.MainActivity';
    final startResult = await _runProcess(
      adbPath,
      _adbArgs([
        'shell', 'am', 'start',
        // `--ez <key> <bool>` is an intent extra; the embedder reads
        // `start-paused` off the launch intent.
        if (startPaused) ...['--ez', 'start-paused', 'true'],
        '-n', '$packageName/$activity',
      ]),
    );
    if (startResult.exitCode != 0) {
      throw StateError('adb am start failed: ${startResult.stderr}');
    }

    // Step 4: Discover VM service URI from logcat.
    final deviceUri = await discoverVmServiceUri(logs);

    // Port forwarding — the URI logcat announces is device-local, and a failed
    // forward has no usable second answer. `127.0.0.1:<devicePort>` on the host
    // is not the device's loopback for a handset over USB, and not the
    // emulator's either (that loopback lives inside its own VM), so any
    // fallback would hand on a URI nothing could dial — adb's error arriving
    // later as a connect timeout against whatever the *host* has on that port,
    // blaming the app.
    Uri? vmServiceUri;
    if (deviceUri != null) {
      final devicePort = deviceUri.port;
      final forwardResult = await _runProcess(
        adbPath,
        _adbArgs(['forward', 'tcp:0', 'tcp:$devicePort']),
      );
      if (forwardResult.exitCode != 0) {
        throw StateError(
          'adb forward tcp:0 tcp:$devicePort failed on $name, so the VM '
          'service it announced at $deviceUri cannot be reached from this '
          'host: ${forwardResult.stderr}',
        );
      }
      // `tcp:0` asks adb to allocate the host port and print it. Anything else
      // on stdout means the forward is not the one this code goes on to dial.
      final printed = (forwardResult.stdout as String).trim();
      final hostPort = int.tryParse(printed);
      if (hostPort == null) {
        throw StateError(
          'adb forward tcp:0 tcp:$devicePort reported success on $name but '
          'printed "$printed" where the host port it allocated belongs, so '
          'there is no port to reach the VM service on.',
        );
      }
      _forwardedHostPort = hostPort;
      vmServiceUri = deviceUri.replace(host: '127.0.0.1', port: hostPort);
    }

    return AppInstance(process: logcat, vmServiceUri: vmServiceUri, logs: logs);
  }

  /// Read the package name (and launchable activity) out of the APK.
  ///
  /// Fatal when it fails, because the package name is what starts the activity
  /// and what [stop] force-stops: a launch without one installs an APK, runs
  /// nothing, and then waits out VM-service discovery on an app that was never
  /// started, blaming the wrong culprit.
  Future<String> _readPackageName(String appPath) async {
    if (!appPath.endsWith('.apk')) {
      throw StateError(
        'Cannot launch $appPath on $name: it is not an APK, so there is no '
        'manifest to read the package name from.',
      );
    }
    final info = await extractPackageInfo(
      appPath,
      runProcess: _runProcess,
      aapt2Path: aapt2Path,
    );
    _packageName = info.packageName;
    _activityName ??= info.activityName;
    return info.packageName;
  }

  /// What to say when `adb install` ran out of room.
  ///
  /// adb reports `Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE: Failed to
  /// override installation location]` and stops there, naming neither the size
  /// of the thing it could not fit nor the space it had. Both are one adb call
  /// and a `stat` away, and without them the failure reads as a bug in this
  /// tool — the message is the whole fix, because there is nothing here to
  /// retry: the device is genuinely out of room.
  ///
  /// Deliberately **not** an uninstall-and-reinstall. Upstream's
  /// `flutter_tools` does exactly that, and it is wrong twice over: it throws
  /// away the user's app data to work around a full disk, and it does nothing
  /// at all when no earlier copy is installed. Removing an existing copy is
  /// offered as a command the developer can run, not taken behind their back.
  ///
  /// PackageManager's own estimate is left unquantified on purpose: it counts
  /// the staged APK and the uncompressed libraries at once, and there is no
  /// reliable multiplier to state.
  Future<String> _insufficientStorageMessage(
    String apkPath,
    String packageName,
    String adbStderr,
  ) async {
    final apkBytes = await File(apkPath).length();
    final free = await _freeSpaceOnData();
    final installed = await _isInstalled(packageName);
    return 'adb install failed: the device is out of room for this APK.\n'
        '  APK:  ${_formatBytes(apkBytes)} ($apkPath)\n'
        '  Free: $free on /data\n'
        'A debug APK carries the entire Flutter debug engine — libflutter.so '
        'plus the Vulkan validation layer, both stored uncompressed — so it '
        'is hundreds of megabytes, and Android needs room for more than the '
        'file itself while it installs.\n'
        '${installed ? 'A copy of $packageName is already installed; '
                  'removing it frees its share first:\n'
                  '  adb ${deviceId != null ? '-s $deviceId ' : ''}uninstall '
                  '$packageName\n' : '$packageName is not currently installed, so '
                  'there is no earlier copy holding the space.\n'}'
        'On an emulator the durable fix is a bigger data partition: raise '
        'disk.dataPartition.size in the AVD\'s config.ini '
        '(~/.android/avd/<name>.avd/config.ini) and restart it. Measured with '
        'a 640 MB debug APK: a 6 GB partition does not take it, a 16 GB one '
        'does. Note the emulator\'s -partition-size flag does not resize '
        'userdata.\n'
        'adb said: $adbStderr';
  }

  /// Free space on the device's `/data`, as a human-readable string.
  ///
  /// Reported rather than parsed into a number the caller compares: this
  /// exists only to be printed beside the APK size. When `df` cannot be read
  /// its own output is quoted instead of a fabricated figure — an error path
  /// that lies about the device is worse than one that admits it does not
  /// know.
  Future<String> _freeSpaceOnData() async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'df', '/data']),
    );
    if (result.exitCode != 0) {
      return 'unknown (`adb shell df /data` failed: ${result.stderr})';
    }
    final lines = const LineSplitter()
        .convert('${result.stdout}')
        .where((l) => l.trim().isNotEmpty);
    if (lines.isEmpty) return 'unknown (`adb shell df /data` printed nothing)';
    // `Filesystem 1K-blocks Used Available Use% Mounted on` — the available
    // column, in 1K blocks, off the last row df printed.
    final fields = lines.last.trim().split(RegExp(r'\s+'));
    final availableKb = fields.length > 3 ? int.tryParse(fields[3]) : null;
    if (availableKb == null) return 'unknown (df said: ${lines.last.trim()})';
    return _formatBytes(availableKb * 1024);
  }

  /// Whether [packageName] is installed, by asking for the path of its APK.
  ///
  /// `pm path` exits non-zero and prints nothing for a package that is not
  /// there, which is the answer rather than an error.
  Future<bool> _isInstalled(String packageName) async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'pm', 'path', packageName]),
    );
    return result.exitCode == 0 && '${result.stdout}'.contains('package:');
  }

  /// Bytes as the size a person would say out loud — `640.1 MB`, `2.5 GB`.
  ///
  /// Powers of 1024 with SI-style suffixes, which is what `df -h` and `ls -lh`
  /// print, so the number here can be compared with the ones a developer sees
  /// from those tools.
  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  /// Fails the launch when the installed [packageName] does not request
  /// `android.permission.INTERNET`.
  ///
  /// Android enforces the INTERNET permission at the kernel level (AID_INET
  /// group membership): a process without it cannot create any socket —
  /// including the 127.0.0.1 server socket the Dart VM service must bind —
  /// so a debug launch would only ever time out waiting for the service.
  /// Queries the installed package (not the APK on disk) so the check
  /// reflects exactly what the device enforces.
  Future<void> _verifyInternetPermission(
    String packageName,
    String apkPath,
  ) async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'dumpsys', 'package', packageName]),
    );
    if (result.exitCode != 0) {
      throw StateError(
        'Could not verify INTERNET permission for $packageName: '
        '`adb shell dumpsys package` failed (exit ${result.exitCode}): '
        '${result.stderr}',
      );
    }
    final output = result.stdout as String;
    if (!output.contains('Package [$packageName]')) {
      throw StateError(
        'Could not verify INTERNET permission for $packageName: '
        '`adb shell dumpsys package` returned no package record:\n'
        '${output.trim()}',
      );
    }
    if (!_requestsInternetPermission(output)) {
      throw StateError(
        '$packageName ($apkPath) does not request '
        'android.permission.INTERNET, so the Dart VM service cannot bind '
        'its socket and this debug launch would hang.\n'
        'Debug APKs built with flutter_android_app get INTERNET from the '
        'debug variant manifest '
        '(android/app/src/debug/AndroidManifest.xml, merged into -c dbg '
        'builds): make sure that file exists (flutter create emits it) '
        'and was not disabled via debug_manifest = False. For a custom '
        'manifest, add <uses-permission '
        'android:name="android.permission.INTERNET"/> or pass a '
        'debug_manifest. Alternatively pass --allow-no-vm-service to '
        'launch without debugging.',
      );
    }
  }

  /// True when the dumpsys package record lists
  /// `android.permission.INTERNET` under `requested permissions:`.
  /// A package that requests no permissions has no such section at all.
  static bool _requestsInternetPermission(String dumpsysOutput) {
    final lines = const LineSplitter().convert(dumpsysOutput);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() != 'requested permissions:') continue;
      final headerIndent = lines[i].length - lines[i].trimLeft().length;
      for (var j = i + 1; j < lines.length; j++) {
        final line = lines[j];
        if (line.trim().isEmpty) break;
        final indent = line.length - line.trimLeft().length;
        if (indent <= headerIndent) break;
        final permission = line.trim().split(RegExp(r'[:\s]')).first;
        if (permission == 'android.permission.INTERNET') return true;
      }
    }
    return false;
  }

  /// Force-stops the app, removes this launch's `adb forward`, and kills
  /// logcat.
  ///
  /// The forward has to be removed by hand because it is not a process: `adb
  /// forward` writes a rule into the adb server, and the server survives the
  /// app exiting, the device unplugging and the dev tool quitting. A launch
  /// that skips the removal leaves a host port bound to a device port for as
  /// long as the adb server runs.
  ///
  /// Only this launch's forward, named by the host port adb allocated —
  /// `adb forward --remove-all` would take out a concurrent session's on the
  /// same host, and there is no way to tell from a rule which run owns it.
  ///
  /// A run that never reaches here still leaks one: nothing in the adb server
  /// is tied to the dev tool's lifetime, so a killed or crashed run leaves its
  /// rule behind. That is accepted rather than reconciled at launch, because
  /// there is nothing to reconcile *against* — `tcp:0` has adb allocate a
  /// fresh host port every time, and the device port is whichever ephemeral
  /// port the app's VM service happened to bind, so no two launches share a
  /// pair to match on. `adb forward --list`, or restarting the adb server,
  /// clears what a killed run left.
  @override
  Future<void> stop(AppInstance instance) async {
    if (_packageName != null) {
      await _runProcess(
        adbPath,
        _adbArgs(['shell', 'am', 'force-stop', _packageName!]),
      );
    }
    final hostPort = _forwardedHostPort;
    if (hostPort != null) {
      final removal = await _runProcess(
        adbPath,
        _adbArgs(['forward', '--remove', 'tcp:$hostPort']),
      );
      _forwardedHostPort = null;
      if (removal.exitCode != 0) {
        _logger.warning({
          'message': 'adb_forward_remove_failed',
          'text':
              'Could not remove this run\'s adb forward on $name: '
              'host port $hostPort stays bound to the device until the adb '
              'server restarts. adb said: ${removal.stderr}',
          'device': name,
          'hostPort': hostPort,
          'error': '${removal.stderr}',
        });
      }
    }
    await _stopProcess('Android logcat', instance.process, teardownBound);
    await instance.logs.close();
  }

  /// How long a whole capture gets to answer — all three `adb` calls, not
  /// each.
  ///
  /// The capture runs inside an HTTP handler, so an `adb` that never returns
  /// is an endpoint that never answers: the request stays open and the caller
  /// learns nothing at all, which is strictly worse than any error. One
  /// deadline across the sequence rather than one per call, because what has
  /// to be bounded is what the caller waits for; three separate bounds would
  /// let the endpoint hold a request for three times the number written here.
  ///
  /// Thirty seconds is not a slow device, it is a wedge — with room for an
  /// `adb` that has to start its server first.
  ///
  /// Settable so a test can drive the expiry in milliseconds.
  Duration screenshotBound = const Duration(seconds: 30);

  /// Whether this device is a local emulator rather than a physical one.
  ///
  /// `emulator-5554` and friends are the serials `adb` gives an emulator whose
  /// console it can reach on the loopback — which is exactly the set that can
  /// be captured through that console, and exactly the set whose `screencap`
  /// cannot see a Flutter surface. A device reached as `host:port` or by a
  /// hardware serial is not one of them.
  bool get _isEmulator => deviceId?.startsWith('emulator-') ?? false;

  /// Captures the device's screen.
  ///
  /// Two mechanisms, chosen by what the device *is* rather than tried in turn:
  /// a physical device is captured with `adb screencap`, an emulator through
  /// its own console. Neither is a fallback for the other, because on an
  /// emulator `screencap` does not fail — it succeeds and returns a fully
  /// transparent PNG.
  ///
  /// How much of the screen goes blank varies with the emulator's GPU mode and
  /// is deliberately not relied on. What holds across all of them is that
  /// `screencap` can report success and return nothing, and that the console
  /// capture works in every GPU mode — so the choice is made by device kind,
  /// never by inspecting the pixels that came back.
  ///
  /// **Rotation.** The console captures the emulator's window, so it is
  /// faithful to what a person looking at that window sees. Rotate with
  /// `adb -s <serial> emu rotate` (or the emulator's own controls), which
  /// turns the window and the guest display together and yields an upright
  /// landscape capture. `settings put system user_rotation` turns only the
  /// guest: the window stays portrait with the UI lying on its side, and a
  /// capture that showed anything else would be misreporting the screen.
  ///
  /// Bounded by [screenshotBound]: see there for why an unbounded capture is
  /// the one failure this path must not have.
  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    if (_isEmulator) return _consoleScreenshot(outputPath);
    const remotePath = '/sdcard/flutter_screenshot.png';
    final deadline = DateTime.now().add(screenshotBound);
    Future<ProcessResult> step(List<String> args, String what) =>
        runProcessBounded(
          _startScreenshotProcess,
          adbPath,
          _adbArgs(args),
          environment: const {},
          bound: deadline.difference(DateTime.now()),
          what: what,
        );

    final capResult = await step([
      'shell',
      'screencap',
      '-p',
      remotePath,
    ], 'adb screencap');
    if (capResult.exitCode != 0) {
      throw StateError('adb screencap failed: ${capResult.stderr}');
    }
    final pullResult = await step(['pull', remotePath, outputPath], 'adb pull');
    if (pullResult.exitCode != 0) {
      throw StateError('adb pull failed: ${pullResult.stderr}');
    }
    await step(['shell', 'rm', remotePath], 'adb rm of the captured file');
  }

  /// Captures an emulator's screen through its console.
  ///
  /// `adb emu screenrecord screenshot <dir>` tells the emulator process to
  /// write a PNG of its own framebuffer into [dir], naming the file itself
  /// (`Screenshot_<n>.png`). That host-side capture is the one that sees a
  /// Flutter surface — see [screenshot].
  ///
  /// **The file on disk is the only evidence the capture worked.** `adb emu`
  /// answers `OK` and exits 0 even for a directory that does not exist, so
  /// neither the exit code nor the console's own reply distinguishes a capture
  /// from a no-op. A directory created fresh for
  /// this one call, holding exactly one PNG afterwards, does: it cannot be
  /// satisfied by a leftover from an earlier capture, and it does not depend
  /// on the emulator's choice of filename.
  Future<void> _consoleScreenshot(String outputPath) =>
      withTempDir('flutter_emu_shot_', (dir) async {
        final result = await runProcessBounded(
          _startScreenshotProcess,
          adbPath,
          _adbArgs(['emu', 'screenrecord', 'screenshot', dir.path]),
          environment: const {},
          bound: screenshotBound,
          what: 'adb emu screenrecord screenshot',
        );
        final pngs = dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.toLowerCase().endsWith('.png'))
            .toList();
        if (pngs.isEmpty) {
          throw StateError(
            'The emulator console wrote no PNG for $name. It was asked to '
            'capture into ${dir.path} and answered '
            '"${'${result.stdout}'.trim()}" (exit ${result.exitCode}) — but '
            '`adb emu` reports OK even when it writes nothing, so that reply '
            'is not evidence of a capture.\n'
            'Check that this emulator is a local one whose console adb can '
            'reach: the console capture is what sees a Flutter surface, which '
            '`adb screencap` on an emulator cannot.',
          );
        }
        if (pngs.length > 1) {
          throw StateError(
            'The emulator console wrote ${pngs.length} PNGs into ${dir.path} '
            'for $name and there is no way to tell which is this capture: '
            '${pngs.map((f) => p.basename(f.path)).join(', ')}.',
          );
        }
        await pngs.single.copy(outputPath);
      });

  /// Starts the `adb` a capture shells to.
  ///
  /// [Process.start] with an empty [environment] still inherits the parent's,
  /// which is what `adb` needs — there is nothing extra to add, unlike the
  /// bundled helpers that have to be told where their runfiles are.
  Future<Process> _startScreenshotProcess(
    String exe,
    List<String> args,
    Map<String, String> environment,
  ) => _injectedScreenshotStart != null
      ? _injectedScreenshotStart(exe, args)
      : Process.start(exe, args, environment: environment);
}

/// Wait until a local TCP listener on 127.0.0.1:[port] accepts connections.
///
/// Port forwarders (iproxy, adb forward) bind their local listener
/// asynchronously after `Process.start` returns; dialing the forward before
/// it is bound gets ECONNREFUSED. Polls `Socket.connect` with exponential
/// backoff and destroys each probe socket. Throws [StateError] naming [what]
/// if the listener never accepts within [budget].
Future<void> waitForLocalTcpPort(
  int port, {
  required String what,
  Duration budget = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(budget);
  var delay = const Duration(milliseconds: 50);
  while (true) {
    try {
      final probe = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(seconds: 1),
      );
      probe.destroy();
      return;
    } catch (_) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          '$what on 127.0.0.1:$port did not accept connections within '
          '${budget.inSeconds}s of starting.',
        );
      }
      await Future<void>.delayed(delay);
      final doubled = delay * 2;
      delay = doubled > const Duration(milliseconds: 500)
          ? const Duration(milliseconds: 500)
          : doubled;
    }
  }
}

/// One parsed `adb logcat -v time` record.
///
/// The `-v time` format is
/// `MM-DD HH:MM:SS.mmm L/Tag( pid): message`, where the pid is space-padded to
/// a fixed width and the tag may itself contain dots (`System.err`).
class LogcatLine {
  /// Priority letter: V, D, I, W, E or F.
  final String level;
  final String tag;
  final String message;

  /// The record without its timestamp — what gets shown.
  final String display;

  const LogcatLine({
    required this.level,
    required this.tag,
    required this.message,
    required this.display,
  });
}

const _logcatTimestamp = r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\s+';
final _logcatTimestampPrefix = RegExp(_logcatTimestamp);
final _logcatTimeFormat = RegExp(
  '$_logcatTimestamp'
  r'([VDIWEF])/(.*?)\(\s*\d+\):\s?(.*)$',
);

/// Parse a `-v time` logcat record, or null if the line isn't one (banners,
/// continuation lines, partial reads).
///
/// Parsing once and matching on the parsed tag is deliberate: flutter_tools'
/// equivalent allowlist is a set of regexes written against a tag-only format
/// even though it requests `-v time`, so several of them — `AndroidRuntime`,
/// `System.err`, fatal `F/` — never match a real padded-pid line. Copying them
/// verbatim would silently drop exactly the crash output this is here to
/// surface.
LogcatLine? parseLogcatLine(String rawLine) {
  final match = _logcatTimeFormat.firstMatch(rawLine);
  if (match == null) return null;
  final level = match.group(1)!;
  final tag = match.group(2)!.trim();
  final message = match.group(3)!;
  return LogcatLine(
    level: level,
    tag: tag,
    message: message,
    display: rawLine.replaceFirst(_logcatTimestampPrefix, ''),
  );
}

/// Tags worth showing from an Android device.
///
/// `adb logcat` carries the whole device's logging, almost none of which
/// concerns the app under development, so this is an allowlist. The set is
/// flutter_tools' (`AdbLogReader._allowedTags`):
///
///   * `flutter*` — Dart `print`/`debugPrint` output.
///   * `DartVM*` — VM messages, including the VM-service announcement.
///   * `AndroidRuntime` — uncaught Java exceptions, i.e. crashes.
///   * `System.err` — Java stderr.
///   * `ActivityManager` — but only when it mentions the app.
///   * any tag at all when the record is fatal (`F`).
///
/// Not ported: flutter's tombstone state machine and repeated-line collapsing.
/// Those polish a crash report; the allowlist is what makes crashes *visible*.
bool _isAndroidTagOfInterest(LogcatLine line) {
  final tag = line.tag.toLowerCase();
  if (line.level == 'F') return true;
  if (tag.startsWith('flutter')) return true;
  if (tag.startsWith('dartvm') && (line.level == 'I' || line.level == 'E')) {
    return true;
  }
  if (!const {'W', 'E', 'F'}.contains(line.level)) return false;
  if (tag == 'androidruntime' || tag == 'system.err') return true;
  if (tag == 'activitymanager') {
    return RegExp(r'\b(flutter|domokit|sky)\b').hasMatch(line.message);
  }
  return false;
}

/// Messages that pass the tag allowlist but are never actionable.
///
/// From flutter_tools' `AdbLogReader._filteredMessages`.
final _androidFilteredMessages = <RegExp>[
  RegExp(r'^Failed to find sync for id=\d+$'),
  RegExp(r'^updateAcquireFence: Did not find frame\.$'),
  RegExp(r'ViewPostIme pointer'),
  RegExp(r'mali\.instrumentation\.graph\.work'),
];

/// Decide whether a raw `adb logcat -v time` line is worth showing, returning
/// it with the timestamp stripped, or null to drop it.
///
/// Exposed for testing.
String? androidLogFilter(String rawLine) {
  final line = parseLogcatLine(rawLine);
  // Banners ("--------- beginning of main") and anything else that isn't a
  // record.
  if (line == null) return null;
  if (!_isAndroidTagOfInterest(line)) return null;
  if (_androidFilteredMessages.any((re) => re.hasMatch(line.message))) {
    return null;
  }
  return line.display;
}

/// Pattern matching Dart VM service URI announcements from Flutter apps.
/// Matches Flutter's own `kVMServiceMessageRegExp` from globals.dart.
final vmServiceUriPattern = RegExp(
  r'The Dart VM service is listening on ((http|//)[a-zA-Z0-9:/=_\-\.\[\]]+)',
);

/// How long a launch waits for the VM-service announcement before giving up.
const _vmServiceDiscoveryTimeout = Duration(seconds: 30);

/// Watch [logs] for the VM-service announcement.
///
/// The Flutter engine prints a line like:
///   "The Dart VM service is listening on http://127.0.0.1:XXXXX/..."
///
/// This is a pure *reader*: it owns only its own subscription to [logs] and
/// cancels only that, leaving whatever feeds the stream running for the app's
/// lifetime. Cancelling the app's own stdout/stderr subscriptions here would
/// kill all subsequent output and leave the OS pipes unread — see the library
/// docs.
///
/// Returns null if nothing announced a VM service within
/// [_vmServiceDiscoveryTimeout] or the stream ended first.
Future<Uri?> discoverVmServiceUri(
  AppLogStream logs, {
  Duration timeout = _vmServiceDiscoveryTimeout,
}) async {
  final completer = Completer<Uri?>();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) completer.complete(null);
  });

  final sub = logs.lines.listen(
    (line) {
      if (completer.isCompleted) return;
      final match = vmServiceUriPattern.firstMatch(line.text);
      if (match != null) completer.complete(Uri.parse(match.group(1)!));
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    },
  );

  try {
    return await completer.future;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}

/// Create the log stream for a launch, attach [onLog], and start draining
/// [process] into it as its only source.
///
/// [onLog] is wired before the pump starts so no line can slip past it.
///
/// For every platform but a physical iOS device the app has exactly one log
/// source, so the stream's life is that source's life — see
/// [IOSDevice.launch] for the one place that owns two.
AppLogStream _startProcessLogs(
  Process process,
  AppLogListener? onLog, {
  bool stderrIsError = true,
  String? Function(String line)? transform,
}) {
  final logs = _newAppLogs(onLog);
  final pump = pumpProcessLines(
    process,
    logs,
    stderrIsError: stderrIsError,
    transform: transform,
  );
  logs.closeWhen([pump.done]);
  return logs;
}

/// An empty log stream with [onLog] already attached.
///
/// Wiring the sink before any pump starts is what guarantees no line can slip
/// past it — including output printed during startup, before `launch()` has
/// returned.
AppLogStream _newAppLogs(AppLogListener? onLog) {
  final logs = AppLogStream();
  if (onLog != null) logs.lines.listen(onLog);
  return logs;
}

/// Detect the appropriate device for the current platform.
Device detectDevice() {
  if (Platform.isMacOS) return MacOSDevice();
  if (Platform.isLinux) return LinuxDevice();
  if (Platform.isWindows) return WindowsDevice();
  throw UnsupportedError(
    'No device available for ${Platform.operatingSystem}. '
    'Desktop devices are supported on macOS, Linux, and Windows.',
  );
}

/// Resolve device IDs to [Device] instances.
///
/// If [ids] is empty, auto-detects one device for the current platform.
/// Accepted IDs: `macos`, `linux`, `windows`, `ios-simulator`,
/// `ios-simulator:<udid>`, `ios`, `ios:<udid>`, `chrome`, or an Android serial.
///
/// Unknown IDs are treated as Android serial numbers with a warning.
List<Device> resolveDevices(List<String> ids) {
  if (ids.isEmpty) return [detectDevice()];
  return ids.map(_resolveDevice).toList();
}

Device _resolveDevice(String id) {
  switch (id) {
    case 'macos':
      return MacOSDevice();
    case 'linux':
      return LinuxDevice();
    case 'windows':
      return WindowsDevice();
    case 'chrome':
      return WebDevice();
    case 'ios-simulator':
      return IOSSimulatorDevice.booted();
    case 'ios':
      return IOSDevice();
    default:
      if (id.startsWith('ios-simulator:')) {
        return IOSSimulatorDevice(udid: id.substring('ios-simulator:'.length));
      }
      if (id.startsWith('ios:')) {
        return IOSDevice(udid: id.substring('ios:'.length));
      }
      // Warn if it looks like a typo of a known device name.
      const knownIds = [
        'macos',
        'linux',
        'windows',
        'chrome',
        'ios-simulator',
        'ios',
      ];
      _logger.warning({
        'message': 'unknown_device_id',
        'text':
            "Unknown device ID '$id' — treating it as an Android serial "
            'number, so a typo here surfaces as adb not finding the device. '
            'Known device IDs: ${knownIds.join(', ')}.',
        'device': id,
        'knownIds': knownIds,
      });
      return AndroidDevice(deviceId: id);
  }
}

/// iOS Simulator device (via xcrun simctl).
class IOSSimulatorDevice extends Device {
  final String udid;
  final String? _bundleId;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  IOSSimulatorDevice({
    required this.udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) : _bundleId = bundleId,
       _runProcess = runProcess ?? Process.run,
       _startProcess = startProcess ?? Process.start;

  /// Create a device targeting the first booted simulator.
  factory IOSSimulatorDevice.booted({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) {
    final run = runProcess ?? Process.run;
    return _IOSSimulatorDeviceBooted(
      runProcess: run,
      startProcess: startProcess ?? Process.start,
    );
  }

  @override
  String get name => 'iOS Simulator ($udid)';

  @override
  List<String> get buildArgs => const ['--ios_multi_cpus=sim_arm64'];

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    // Extract .app from .ipa if needed — simctl install requires .app.
    String installPath = appPath;
    Directory? unpacked;
    if (appPath.endsWith('.ipa')) {
      final extracted = await _extractAppFromIpa(appPath);
      installPath = extracted.appPath;
      unpacked = extracted.dir;
    }

    // Boot sim (idempotent — no-op if already booted).
    await _runProcess('xcrun', ['simctl', 'boot', udid]);

    // Install.
    final installResult = await _runProcess('xcrun', [
      'simctl',
      'install',
      udid,
      installPath,
    ]);
    if (installResult.exitCode != 0) {
      throw StateError('simctl install failed: ${installResult.stderr}');
    }

    // Two log streams, deliberately.
    //
    // Discovery matches on message content and nothing else. App output needs
    // a process-scoped predicate with several NOT(...) noise filters
    // ([iosSimulatorLogPredicate]). Folding the two together would make
    // VM-service discovery — which hot reload, screenshots and agent control
    // all depend on — contingent on those exclusion clauses continuing to
    // spare the announcement. Two narrow streams fail independently and
    // visibly; one broad stream fails silently.
    final discoveryLog = await _startProcess('xcrun', [
      'simctl',
      'spawn',
      udid,
      'log',
      'stream',
      '--predicate',
      'eventMessage contains "Observatory" or eventMessage contains "Dart VM service"',
    ]);

    final appName = p.basename(installPath).replaceAll('.app', '');
    final outputLog = await _startProcess('xcrun', [
      'simctl',
      'spawn',
      udid,
      'log',
      'stream',
      '--style',
      'json',
      '--predicate',
      iosSimulatorLogPredicate(appName),
    ]);

    // Unified logging carries no stdout/stderr split, so nothing is flagged as
    // an error channel here.
    final logs = _startProcessLogs(
      outputLog,
      onLog,
      stderrIsError: false,
      transform: parseUnifiedLoggingLine,
    );

    // Launch app.
    final bundleId = _bundleId ?? await _extractBundleId(installPath);
    await _runProcess('xcrun', [
      'simctl', 'launch', udid, bundleId,
      // Anything after the bundle id is passed to the app as argv, which is
      // where the iOS embedder looks for engine switches.
      if (startPaused) '--start-paused',
    ]);

    // Discover VM service URI from the dedicated discovery stream.
    final uri = await discoverVmServiceUriFromProcess(discoveryLog);

    return AppInstance(
      process: discoveryLog,
      vmServiceUri: uri,
      logs: logs,
      auxiliaryProcesses: [outputLog],
      scratchDirs: [if (unpacked != null) unpacked],
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    // Read into a local rather than null-asserting the field: whether the
    // field promotes across the check depends on the language version the
    // analyzer is given, and a local is what every version accepts.
    final bundleId = _bundleId;
    if (bundleId != null) {
      await _runProcess('xcrun', ['simctl', 'terminate', udid, bundleId]);
    }
    await _stopProcess('iOS Simulator app', instance.process, teardownBound);
    await instance.disposeAuxiliaryProcesses(teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  /// iOS Simulator uses `simctl io screenshot` because `_flutter.screenshot`
  /// returns "Could not capture image screenshot" on the Simulator rendering
  /// pipeline. Waits for the first frame via VM service before capturing.
  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      await vmClient.waitForFirstFrame();
    }
    final result = await _runProcess('xcrun', [
      'simctl',
      'io',
      udid,
      'screenshot',
      outputPath,
    ]);
    if (result.exitCode != 0) {
      throw StateError('simctl screenshot failed: ${result.stderr}');
    }
  }

  Future<String> _extractBundleId(String appPath) async {
    final result = await _runProcess('defaults', [
      'read',
      '$appPath/Info.plist',
      'CFBundleIdentifier',
    ]);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
    throw StateError('Could not extract bundle ID from $appPath');
  }

  /// Extract the .app directory from an .ipa archive.
  ///
  /// Returns the directory alongside the bundle so the caller can hold it for
  /// exactly as long as the launch needs it — see [AppInstance.scratchDirs].
  Future<({String appPath, Directory dir})> _extractAppFromIpa(
    String ipaPath,
  ) async {
    final tempDir = await createTempDir('flutter_ipa_');
    try {
      final result = await _runProcess('unzip', [
        '-oq',
        ipaPath,
        '-d',
        tempDir.path,
      ]);
      if (result.exitCode != 0) {
        throw StateError('Failed to extract IPA: ${result.stderr}');
      }
      final payloadDir = Directory(p.join(tempDir.path, 'Payload'));
      if (!payloadDir.existsSync()) {
        throw StateError('No Payload directory found in IPA');
      }
      final apps = payloadDir
          .listSync()
          .where((e) => e.path.endsWith('.app'))
          .toList();
      if (apps.isEmpty) {
        throw StateError('No .app found in IPA Payload directory');
      }
      return (appPath: apps.first.path, dir: tempDir);
    } catch (_) {
      // Nothing usable came out of the archive; the half-unpacked copy is only
      // going to sit there.
      await deleteTempDir(tempDir);
      rethrow;
    }
  }
}

/// An [IOSSimulatorDevice] that resolves the UDID on first launch.
class _IOSSimulatorDeviceBooted extends IOSSimulatorDevice {
  String? _resolvedUdid;

  _IOSSimulatorDeviceBooted({
    required ProcessRunSync runProcess,
    required ProcessStarter startProcess,
  }) : super(
         udid: 'booted',
         runProcess: runProcess,
         startProcess: startProcess,
       );

  @override
  String get name => _resolvedUdid != null
      ? 'iOS Simulator ($_resolvedUdid)'
      : 'iOS Simulator (booted)';

  Future<String> _resolveBootedUdid() async {
    if (_resolvedUdid != null) return _resolvedUdid!;
    final result = await _runProcess('xcrun', [
      'simctl',
      'list',
      'devices',
      'booted',
      '-j',
    ]);
    if (result.exitCode == 0) {
      final output = result.stdout as String;
      final match = RegExp(r'"udid"\s*:\s*"([^"]+)"').firstMatch(output);
      if (match != null) {
        _resolvedUdid = match.group(1)!;
        return _resolvedUdid!;
      }
    }
    throw StateError(
      'No booted iOS simulator found. '
      'Boot one with: xcrun simctl boot <device-name>',
    );
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    final resolvedUdid = await _resolveBootedUdid();
    final real = IOSSimulatorDevice(
      udid: resolvedUdid,
      runProcess: _runProcess,
      startProcess: _startProcess,
    );
    return real.launch(appPath, onLog: onLog);
  }
}

/// How a paired physical device is currently reachable.
///
/// This decides two things that have to agree with each other: whether the app
/// is launched with its VM service bound to all interfaces, and whether that
/// service is dialed through a port forward or at the device's own address.
enum IOSDeviceTransport {
  /// Attached by cable. The VM service binds to the device's loopback — which
  /// is what `--vm-service-host` defaults to — so it is reached through an
  /// `iproxy` forward.
  wired,

  /// Reachable over the network. There is no cable to forward through, so the
  /// app must be launched with `--vm-service-host=0.0.0.0` and dialed at the
  /// device's own address.
  wireless,
}

/// What `devicectl list devices` reports about one paired physical device.
class IOSDeviceInfo {
  /// The hardware UDID.
  ///
  /// This is the identifier every tool here is addressed with. `devicectl`
  /// also answers to its own CoreDevice UUID ([coreDeviceId]) and reports that
  /// one first, but `lldb device select`, `iproxy -u` and the pymobiledevice3
  /// screenshot helper all go through usbmuxd, which has never heard of it —
  /// addressing them with it produces a port forward that binds locally and
  /// then resets every connection.
  final String udid;

  /// The CoreDevice UUID `devicectl` lists as `identifier`. Kept so that a
  /// UDID copied out of `devicectl list devices` still selects this device.
  final String coreDeviceId;

  final String name;
  final IOSDeviceTransport transport;

  /// The device's own mDNS hostnames, of the form
  /// `<device-name>.coredevice.local`.
  ///
  /// These are what tell this device's `_dartVmService._tcp` advertisement
  /// apart from every other advertiser on the network — including this Mac
  /// running the same bundle id in a simulator. See
  /// [MdnsVmServiceDiscovery.discover].
  final List<String> hostnames;

  IOSDeviceInfo({
    required this.udid,
    required this.coreDeviceId,
    required this.name,
    required this.transport,
    required this.hostnames,
  });

  /// Whether [identifier] names this device, in either identifier space.
  bool matches(String identifier) =>
      udid == identifier || coreDeviceId == identifier;

  @override
  String toString() => '$name ($udid, ${transport.name})';
}

/// The devices `devicectl list devices --json-output` reports as usable now.
///
/// Entries without a recognised `transportType` are dropped: a device that was
/// paired once but is not currently attached is still listed, with no
/// transport and `tunnelState: unavailable`. Picking one of those produces a
/// launch that installs nothing and then waits out every timeout, instead of
/// a "no device attached" error at the first step.
List<IOSDeviceInfo> parseDevicectlDevices(String jsonText) {
  final data = json.decode(jsonText) as Map<String, dynamic>;
  final devices = (data['result']?['devices'] as List?) ?? const [];
  final result = <IOSDeviceInfo>[];
  for (final entry in devices) {
    final device = entry as Map<String, dynamic>;
    final connection =
        (device['connectionProperties'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final transport = switch ((connection['transportType'] as String?)
        ?.toLowerCase()) {
      'wired' => IOSDeviceTransport.wired,
      'localnetwork' => IOSDeviceTransport.wireless,
      _ => null,
    };
    if (transport == null) continue;
    final coreDeviceId = device['identifier'] as String?;
    final udid = ((device['hardwareProperties'] as Map?)?['udid']) as String?;
    if (coreDeviceId == null || udid == null) continue;
    final properties =
        (device['deviceProperties'] as Map?)?.cast<String, dynamic>() ??
        const {};
    result.add(
      IOSDeviceInfo(
        udid: udid,
        coreDeviceId: coreDeviceId,
        name: properties['name'] as String? ?? udid,
        transport: transport,
        hostnames:
            ((connection['localHostnames'] as List?) ??
                    (connection['potentialHostnames'] as List?) ??
                    const [])
                .cast<String>(),
      ),
    );
  }
  return result;
}

/// iOS physical device (via xcrun devicectl + lldb).
class IOSDevice extends Device {
  /// The UDID the user asked for, or null to use whichever device is attached.
  final String? requestedUdid;
  final String? _bundleId;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;
  final MdnsVmServiceDiscovery _mdns;

  /// Filled in by the first [_resolveInfo].
  IOSDeviceInfo? _info;

  /// iproxy process for port forwarding (killed on stop).
  Process? _iproxyProcess;

  /// devicectl --console process for stdout capture (killed on stop).
  Process? _consoleLauncherProcess;

  /// lldb process for debugger attachment (killed on stop).
  Process? _lldbProcess;

  IOSDevice({
    String? udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
    MdnsVmServiceDiscovery? mdns,
  }) : requestedUdid = udid,
       _bundleId = bundleId,
       _runProcess = runProcess ?? Process.run,
       _startProcess = startProcess ?? Process.start,
       _mdns = mdns ?? MdnsVmServiceDiscovery();

  /// The UDID in play.
  ///
  /// The resolved hardware UDID wins over whatever was asked for: a user may
  /// legitimately pass the CoreDevice UUID (it is what `devicectl list
  /// devices` prints), but usbmuxd-backed tools cannot use it. Before a device
  /// is resolved there is nothing else to report, so the request stands in.
  String? get udid => _info?.udid ?? requestedUdid;

  /// The UDID of the device commands are addressed to.
  ///
  /// Throws rather than guessing: every caller runs after [launch] has
  /// resolved a device, or was handed an explicit UDID.
  String get _addressedUdid {
    final resolved = udid;
    if (resolved == null) {
      throw StateError(
        'No iOS device has been resolved yet. This device was '
        'created without a UDID, so launch() must run first.',
      );
    }
    return resolved;
  }

  @override
  String get name => 'iOS (${udid ?? 'auto-detect'})';

  @override
  List<String> get buildArgs => const ['--ios_multi_cpus=arm64'];

  /// Resolves the device as a side effect, which is the point: an unattached
  /// or ambiguous phone is a launch-blocking condition too, and finding out
  /// here costs one `devicectl list` instead of a whole build.
  @override
  Future<List<HostTool>> requiredHostTools() async {
    final info = await _resolveInfo();
    return [
      lldbTool(),
      // Only a cabled device is reached through a port forward; a wireless one
      // is dialed at its own address, so demanding iproxy there would refuse a
      // run that works. `xcrun` is not listed: it is part of macOS, and a
      // missing or misconfigured Xcode is already reported by [_resolveInfo],
      // with devicectl's own explanation attached.
      if (info.transport == IOSDeviceTransport.wired) iproxyTool(),
    ];
  }

  /// A hot restart re-runs `main()`, which re-JITs the app — and every new
  /// executable page traps into the `NOTIFY_DEBUGGER_ABOUT_RX_PAGES`
  /// breakpoint, whose handler writes to device memory over the debugserver
  /// link. That per-page round trip is what makes a cold start here cost far
  /// more than the under-a-second a desktop app takes; a restart is the same
  /// work. (Setting `--auto-continue` on the breakpoint does not help: the cost
  /// is the memory write, not the stop/resume handshake.) The host default
  /// would abandon the RPC and force-close the connection while the device was
  /// still working.
  ///
  /// The magnitude depends on the host as much as the link: a Mac whose Xcode
  /// symbol copy is stranded half-finished leaves lldb without the on-disk
  /// shared cache, and costs an order of magnitude more than a healthy one.
  /// These budgets are sized for that degraded host deliberately — they are
  /// backstops for a run that will never succeed, not estimates of a healthy
  /// one.
  @override
  Duration get applyTimeout => switch (_info?.transport) {
    IOSDeviceTransport.wireless => const Duration(minutes: 15),
    _ => const Duration(minutes: 5),
  };

  /// Ask `devicectl` which device this is, once per run.
  ///
  /// Resolves the UDID when none was given, and in every case picks up the
  /// transport and mDNS hostnames the rest of [launch] needs. Ambiguity is an
  /// error, not a first-match: two attached devices means the user has to say
  /// which one, and silently choosing would look like a working run against
  /// the wrong phone.
  Future<IOSDeviceInfo> _resolveInfo() async {
    final cached = _info;
    if (cached != null) return cached;

    final available = await withTempDir('flutter_devicectl_', (dir) async {
      final jsonPath = p.join(dir.path, 'devices.json');
      final result = await _runProcess('xcrun', [
        'devicectl',
        'list',
        'devices',
        '--json-output',
        jsonPath,
      ]);
      if (result.exitCode != 0) {
        throw StateError('devicectl list devices failed: ${result.stderr}');
      }
      final jsonFile = File(jsonPath);
      if (!jsonFile.existsSync()) {
        throw StateError(
          'devicectl list devices reported success but wrote no '
          'device list to $jsonPath.',
        );
      }
      return parseDevicectlDevices(jsonFile.readAsStringSync());
    });

    final requested = requestedUdid;
    if (requested != null) {
      final match = available.where((d) => d.matches(requested));
      if (match.isEmpty) {
        throw StateError(
          'No attached iOS device with UDID $requested.'
          '${_availableSuffix(available)}',
        );
      }
      return _info = match.first;
    }
    if (available.isEmpty) {
      throw StateError(
        'No iOS device is attached. Connect one by cable, or '
        'pair it for network debugging in Xcode > Window > Devices and '
        'Simulators.',
      );
    }
    if (available.length > 1) {
      throw StateError(
        'More than one iOS device is attached; say which one '
        'with -d ios:<udid>.${_availableSuffix(available)}',
      );
    }
    return _info = available.single;
  }

  static String _availableSuffix(List<IOSDeviceInfo> available) =>
      available.isEmpty
      ? ''
      : '\nAttached devices:\n'
            '${available.map((d) => '  ${d.udid}  ${d.name} (${d.transport.name})').join('\n')}';

  /// Installs, launches, attaches the debugger, and finds the VM service —
  /// tearing down whatever it started if any of that fails.
  ///
  /// A launch on this platform starts three long-lived helpers before it can
  /// return: the `devicectl --console` launcher, `lldb`, and (over a cable)
  /// `iproxy`. [stop] reaps all three, but `stop` takes the [AppInstance] a
  /// successful launch produced, so a launch that throws never reaches it —
  /// leaving the app up on the phone behind lldb and iproxy holding its host
  /// port. There are five throw sites past the first helper: a missing pid,
  /// three lldb commands, mDNS discovery giving up, and a forward that never
  /// binds.
  ///
  /// Guarding here rather than at each site: the set to reap is "whatever this
  /// launch got as far as starting", which is exactly what the fields say, and
  /// a per-site version would have to be repeated at every future one.
  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    try {
      return await _launchAndAttach(appPath, onLog: onLog);
    } catch (_) {
      await _reapLaunchHelpers();
      rethrow;
    }
  }

  Future<AppInstance> _launchAndAttach(
    String appPath, {
    AppLogListener? onLog,
  }) async {
    final info = await _resolveInfo();

    // Extract .app from .ipa if needed — devicectl install requires .app.
    String installPath = appPath;
    Directory? unpacked;
    if (appPath.endsWith('.ipa')) {
      final extracted = await _extractAppFromIpa(appPath);
      installPath = extracted.appPath;
      unpacked = extracted.dir;
    }

    // Install with JSON output to capture installationURL — the only handle on
    // the process this launch goes on to attach a debugger to.
    final installationUrl = await withTempDir('flutter_install_', (
      installJsonDir,
    ) async {
      final installJsonPath = p.join(installJsonDir.path, 'install.json');

      final installResult = await _runProcess('xcrun', [
        'devicectl',
        'device',
        'install',
        'app',
        '--device',
        info.udid,
        '--json-output',
        installJsonPath,
        installPath,
      ]);
      if (installResult.exitCode != 0) {
        throw StateError('devicectl install failed: ${installResult.stderr}');
      }

      return _readInstallationUrl(installJsonPath, installPath);
    });

    // Extract bundle ID from .app/Info.plist if not provided.
    final bundleId = _bundleId ?? await _extractBundleId(installPath);

    // iOS debug apps require a debugger (ptrace) to be attached before the
    // Flutter engine will start. This matches what `flutter run` does:
    //   1. Launch paused via devicectl --console --start-stopped
    //   2. Get PID from process list
    //   3. Attach lldb (which starts debugserver / ptrace)
    //   4. Set JIT page notification breakpoint
    //   5. Resume
    //   6. Discover the VM service by its mDNS advertisement

    final logs = _newAppLogs(onLog);

    // Step 1: Launch paused with --console to capture the app's output.
    //
    // flutter_tools wraps this in `script -t 0 /dev/null` "to convince
    // devicectl it has a terminal attached in order to redirect stdout"
    // (`ios/core_devices.dart`). That is unnecessary here: devicectl writes
    // the app's console output to these pipes without a pty.
    _consoleLauncherProcess = await _startProcess('xcrun', [
      'devicectl',
      'device',
      'process',
      'launch',
      '--device',
      info.udid,
      '--start-stopped',
      '--console',
      '--environment-variables',
      '{"OS_ACTIVITY_DT_MODE": "enable"}',
      bundleId,
      '--enable-dart-profiling',
      '--enable-checked-mode',
      if (startPaused) '--start-paused',
      // A wireless device is dialed at its own address, so the VM service must
      // not bind to the device's loopback the way it does by default. Matches
      // flutter_tools' `DebuggingOptions.buildLaunchArguments`, which adds this
      // exactly when the connection interface is wireless.
      if (info.transport == IOSDeviceTransport.wireless)
        '--vm-service-host=0.0.0.0',
    ]);

    // devicectl sends its own progress banners on one channel and the app's
    // console output on the other, so both feed the app log stream.
    //
    // stderr is deliberately *not* flagged as an error channel: devicectl
    // routes the app's ordinary console output there, so treating that channel
    // as errors would mark every `print()` as one.
    final consolePump = pumpProcessLines(
      _consoleLauncherProcess!,
      logs,
      stderrIsError: false,
    );

    final launchCompleter = Completer<void>();
    // Cancelled below once the launch resolves: an uncancelled 30s timer keeps
    // the isolate alive for its full duration after the work is done.
    final launchTimeout = Timer(const Duration(seconds: 30), () {
      if (!launchCompleter.isCompleted) launchCompleter.complete();
    });

    // devicectl's own launch banners are progress reporting, not app output.
    bool isDevicectlBanner(String line) =>
        line.contains('Waiting for the application to terminate') ||
        line.contains('Launched application with');

    // Another reader of the same stream, like discovery below.
    final bannerSub = logs.lines.listen((line) {
      if (!launchCompleter.isCompleted && isDevicectlBanner(line.text)) {
        launchCompleter.complete();
      }
    });
    // A launch that dies before ever printing a banner stops the wait
    // immediately rather than sitting out the timeout. This watches devicectl
    // itself rather than the shared log stream, which outlives it.
    unawaited(
      consolePump.done.then((_) {
        if (!launchCompleter.isCompleted) launchCompleter.complete();
      }),
    );

    await launchCompleter.future;
    launchTimeout.cancel();
    await bannerSub.cancel();

    // Step 2: Get PID from running process list.
    final processId = await _findAppProcessId(installationUrl);

    // Step 3-5: Attach lldb debugger, set breakpoint, resume.
    // Matches flutter_tools LLDB._selectDevice, _setBreakpoint,
    // _attachToAppProcess, _resumeProcess.
    final lldb = await _startProcess('lldb', []);
    _lldbProcess = lldb;
    // lldb is a log source, not just a control channel — see [_startLldbOutput].
    final lldbDone = _startLldbOutput(lldb, appLogs: logs);

    // Both sources are now known, so the stream's life can be settled in one
    // place. They are not ordered — devicectl exits when the app terminates,
    // which is exactly when lldb starts reporting why — so the stream outlives
    // whichever ends first.
    logs.closeWhen([consolePump.done, lldbDone]);
    await _lldbCommand(lldb, 'device select ${info.udid}');
    final bpOutput = await _lldbCommand(
      lldb,
      r"breakpoint set --func-regex '^NOTIFY_DEBUGGER_ABOUT_RX_PAGES$'",
      waitFor: RegExp(r'Breakpoint (\d+):'),
      returnMatch: true,
    );
    final bpId =
        RegExp(r'Breakpoint (\d+):').firstMatch(bpOutput ?? '')?.group(1) ??
        '1';
    // The script-input lines take [_lldbCommand]'s no-`waitFor` path: lldb
    // reads its stdin in order, and the `device process attach` below waits on
    // its own output, which is what actually orders the sequence. No delay
    // between them is needed; flutter_tools writes these three the same way
    // (`ios/lldb.dart` `_setBreakpoint`).
    await _lldbCommand(
      lldb,
      'breakpoint command add --script-type python $bpId',
    );
    await _lldbCommand(lldb, _jitBreakpointScript);
    await _lldbCommand(lldb, 'DONE');
    await _lldbCommand(
      lldb,
      'device process attach --pid $processId',
      waitFor: RegExp(r'Process \d+ stopped'),
    );
    await _lldbCommand(
      lldb,
      'process continue',
      waitFor: RegExp(r'Process \d+ resuming'),
    );

    // Step 6: Find the VM service by its mDNS advertisement.
    //
    // Not by reading the log stream, the way every other platform does. A
    // wirelessly attached device has no console channel at all, and the one a
    // wired device has is `devicectl --console`, which dies with the launch it
    // reports on. The advertisement is the one channel both connections share,
    // and it is already provisioned: the debug/profile Info.plist declares
    // `_dartVmService._tcp` under NSBonjourServices
    // (`flutter/private/runners/ios/DartVmServiceMdns.plist`).
    //
    // Minutes, not seconds — see [applyTimeout] for why a debug launch here is
    // this slow. The budget is a backstop for a run that will never succeed,
    // not an estimate; [onSlow] is what tells the user a long wait is expected
    // rather than a hang. flutter_tools splits the same two concerns, warning
    // at 60s/75s while its mDNS query runs for ten minutes
    // (`ios/devices.dart`).
    final record = await _mdns.discover(
      bundleId: bundleId,
      hostnames: info.hostnames,
      resolveAddress: info.transport == IOSDeviceTransport.wireless,
      timeout: switch (info.transport) {
        IOSDeviceTransport.wired => const Duration(minutes: 5),
        IOSDeviceTransport.wireless => const Duration(minutes: 15),
      },
      // Sized well above a healthy host's launch: the trigger exists to
      // reassure someone on a slow host that the wait is expected, and one
      // sized for a fast host would fire on every ordinary launch. The message
      // says what is outstanding and what is worth checking, and quotes no
      // duration — the cost varies by host by more than an order of magnitude,
      // so any figure here would be wrong for most readers.
      slowAfter: const Duration(seconds: 45),
      onSlow: (elapsed) => logs.add(
        'Still waiting (${elapsed.inSeconds}s) for the app to advertise its '
        'Dart VM service over mDNS — the only channel an iOS device has for '
        'it. Until then the JIT is still trapping to the debugger for every '
        'executable page it allocates, which is the bulk of an iOS debug '
        'start. If this is taking far longer than your other launches on '
        'this host, check that Xcode has finished copying symbols for this '
        'device: a copy stranded part-way leaves lldb without the on-disk '
        'shared cache, and every one of those traps then costs a read off '
        'the device.',
      ),
    );

    final Uri vmServiceUri;
    switch (info.transport) {
      case IOSDeviceTransport.wired:
        // The advertised port is a device-side port on the device's loopback.
        final iproxy = await _startProcess('iproxy', [
          '${record.port}:${record.port}',
          '-u',
          info.udid,
        ]);
        _iproxyProcess = iproxy;

        // iproxy runs for the whole session and reports what it is doing on
        // both channels, so both have to be drained — an unread pipe blocks
        // the writer, and here the writer is the only route to the device.
        final iproxyOutput = AppLogStream();
        iproxyOutput.closeWhen([pumpProcessLines(iproxy, iproxyOutput).done]);

        // Process.start returns at spawn time, before iproxy has bound its
        // local listener. DDS dials this forward immediately after launch()
        // returns; an unbound listener means ECONNREFUSED and the session
        // loses its VM service. Return only once the forward actually accepts.
        try {
          await waitForLocalTcpPort(
            record.port,
            what: 'iproxy forward for the iOS VM service',
          );
        } on StateError catch (e) {
          final said = iproxyOutput
              .read(0)
              .lines
              .map((l) => l.text)
              .where((t) => t.trim().isNotEmpty);
          throw StateError(
            '${e.message}\n'
            'iproxy said: ${said.isEmpty ? '(nothing)' : said.join('; ')}',
          );
        }
        vmServiceUri = record.uriFor(host: '127.0.0.1', port: record.port);
      case IOSDeviceTransport.wireless:
        // No cable to forward through. `discover(resolveAddress: true)` throws
        // rather than returning a record without an address, so this is set.
        vmServiceUri = record.uriFor(
          host: record.address!.address,
          port: record.port,
        );
    }

    return AppInstance(
      process: lldb,
      vmServiceUri: vmServiceUri,
      logs: logs,
      scratchDirs: [if (unpacked != null) unpacked],
    );
  }

  /// Python script for the JIT page notification breakpoint.
  /// Matches flutter_tools' LLDB._pythonScript.
  static const _jitBreakpointScript = '''
"""Intercept NOTIFY_DEBUGGER_ABOUT_RX_PAGES and touch the pages."""
base = frame.register["x0"].GetValueAsAddress()
page_len = frame.register["x1"].GetValueAsUnsigned()
data = bytearray(page_len)
data[0:8] = b'IHELPED!'
error = lldb.SBError()
frame.GetThread().GetProcess().WriteMemory(base, data, error)
if not error.Success():
    print(f'Failed to write into {base}[+{page_len}]', error)
    return
return False
''';

  /// Every line lldb has written, live and replayable.
  ///
  /// lldb outlives `launch()` — it holds the debugserver that keeps the app's
  /// JIT alive — so **something must keep reading its pipes for as long as it
  /// runs**. It is also chatty: it forwards the app's own logs and any crash
  /// report. Left unread, its stdout pipe fills, lldb blocks on write, and a
  /// blocked lldb never services the process it is controlling — the app hangs
  /// on device and only springs to life when the dev tool is killed and the
  /// pipes are closed.
  ///
  /// Backed by an [AppLogStream] rather than an ad-hoc broadcast stream: a
  /// broadcast stream drops events while nobody is listening, so lldb output
  /// arriving between two commands — including the pattern the *next* command
  /// is about to wait for — would be discarded. Replay makes the wait
  /// race-free.
  ///
  /// Mirrors flutter_tools' `LLDBLogForwarder`, which exists for these reasons.
  AppLogStream? _lldbOutput;

  /// Start draining [lldb] into [_lldbOutput]. Both channels are captured:
  /// lldb reports real failures (a breakpoint that resolved nowhere, a refused
  /// attach) on stderr, and dropping that channel turns an explainable failure
  /// into a 30-second timeout with no reason attached.
  ///
  /// [appLogs], when given, additionally receives everything lldb prints that
  /// is not lldb's own command chatter. Current flutter_tools treats
  /// `devicectl` **and lldb** as one combined log source on CoreDevices under
  /// Xcode 26+ (`ios/devices.dart` `logSources` → `devicectlAndLldb`), because
  /// the debugger carries output the console stream may not.
  ///
  /// Returns when lldb has finished feeding [appLogs] — the caller pairs it
  /// with the console channel's to settle when the shared stream closes.
  Future<void> _startLldbOutput(Process lldb, {AppLogStream? appLogs}) {
    final out = AppLogStream();
    _lldbOutput = out;
    final pump = pumpProcessLines(lldb, out, stderrIsError: true);
    out.closeWhen([pump.done]);

    if (appLogs == null) return pump.done;

    // Completed from the bridge's own `onDone`, not from [pump], so the last
    // lines lldb wrote are in [appLogs] before it is reported finished.
    final forwarded = Completer<void>();
    out.lines.listen(
      (line) {
        if (_isLldbCommandEcho(line.text)) return;
        appLogs.add(_stripDeviceLogPrefix(line.text), isError: line.isError);
      },
      onDone: forwarded.complete,
    );
    return forwarded.future;
  }

  /// lldb's own prompt/echo and disassembly, as opposed to app output.
  ///
  /// Only unambiguous markers are filtered; anything unrecognised is treated as
  /// app output, since losing a real line is worse than showing a noisy one.
  static bool _isLldbCommandEcho(String line) {
    final t = line.trim();
    if (t.isEmpty) return true;
    if (t.startsWith('(lldb)') ||
        t.startsWith('Breakpoint ') ||
        t.startsWith('Target ') ||
        t == 'DONE' ||
        t.startsWith('Available devices:') ||
        t.startsWith('Enter your Python command')) {
      return true;
    }
    if (t.startsWith('Process ') &&
        (t.contains(' stopped') ||
            t.contains(' resuming') ||
            t.contains(' exited') ||
            t.contains(' launched'))) {
      return true;
    }
    // Disassembly and frame dumps from a breakpoint stop.
    return t.startsWith('* thread #') ||
        t.startsWith('frame #') ||
        t.startsWith('->') ||
        RegExp(r'^0x[0-9a-f]+ <\+\d+>:').hasMatch(t) ||
        RegExp(r'^\d+ location(s)? added to breakpoint').hasMatch(t);
  }

  /// Native/engine logs arrive prefixed with a timestamp and process metadata:
  ///
  ///     2020-09-15 19:15:10.931434-0700 Runner[541:226276] Did finish launching.
  ///
  /// Dart `print()` output has no such prefix. Strip it so both read alike —
  /// same handling as flutter_tools' `_debuggerLineHandler`.
  static final _deviceLogPrefix = RegExp(r'^\S* \S* \S*\[[0-9:]*\] (.*)');

  static String _stripDeviceLogPrefix(String line) =>
      _deviceLogPrefix.firstMatch(line)?.group(1) ?? line;

  /// Send a command to lldb stdin and optionally wait for expected output.
  /// If [returnMatch] is true, returns the matched line; otherwise returns null.
  Future<String?> _lldbCommand(
    Process lldb,
    String command, {
    RegExp? waitFor,
    bool returnMatch = false,
  }) async {
    final output = _lldbOutput;
    if (output == null) {
      throw StateError(
        'lldb output is not being drained; '
        'call _startLldbOutput before issuing commands.',
      );
    }

    if (waitFor == null) {
      // Fire-and-forget commands (`device select`, the breakpoint script
      // lines) produce no distinctive output to wait on. Yield rather than
      // sleeping a fixed interval: the following command's own wait is what
      // actually orders this sequence, and lldb reads its stdin in order.
      lldb.stdin.writeln(command);
      await Future<void>.delayed(Duration.zero);
      return null;
    }

    // Subscribe before writing so a fast reply cannot land first — and because
    // the stream replays, output already buffered still counts.
    final completer = Completer<String>();
    final sub = output.lines.listen((line) {
      if (!completer.isCompleted && waitFor.hasMatch(line.text)) {
        completer.complete(line.text);
      }
    });

    try {
      lldb.stdin.writeln(command);
      final matched = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError(
          'lldb did not answer "$command" within 30s (waiting for '
          '${waitFor.pattern}).\nlldb said:\n'
          '${output.read(-40).lines.map((l) => '  ${l.text}').join('\n')}',
        ),
      );
      return returnMatch ? matched : null;
    } finally {
      await sub.cancel();
    }
  }

  /// The `installationURL` `devicectl install` reported, from its JSON output.
  ///
  /// Fatal when it is not there, because it is the *only* thing that can name
  /// the launched process afterwards. It is a `file://` URL of the installed
  /// bundle — `file:///private/var/containers/Bundle/Application/<uuid>/
  /// Runner.app/` — and every running process's `executable` under that bundle
  /// is that string plus a suffix. The bundle id appears in neither, so there
  /// is nothing else to match on.
  String _readInstallationUrl(String installJsonPath, String installedPath) {
    final file = File(installJsonPath);
    if (!file.existsSync()) {
      throw StateError(
        'devicectl install reported success for $installedPath on $name but '
        'wrote no JSON to $installJsonPath, so there is no installationURL '
        'to find the launched process by.',
      );
    }
    final contents = file.readAsStringSync();
    final Object? decoded;
    try {
      decoded = json.decode(contents);
    } on FormatException catch (e) {
      throw StateError(
        'devicectl install wrote JSON this could not read ($e), so there is '
        'no installationURL to find the launched process by. It wrote:\n'
        '$contents',
      );
    }
    String? url;
    if (decoded is Map<String, dynamic>) {
      final apps = decoded['result']?['installedApplications'] as List?;
      final first = (apps == null || apps.isEmpty) ? null : apps.first;
      if (first is Map) url = first['installationURL'] as String?;
    }
    if (url == null || url.isEmpty) {
      throw StateError(
        'devicectl install named no installationURL for $installedPath on '
        '$name, so there is nothing to find the launched process by. It '
        'wrote:\n$contents',
      );
    }
    return url;
  }

  /// The process id of the app just installed and launched.
  ///
  /// Matched on the install step's `installationURL` and nothing else: an iOS
  /// executable path is `file://…/<uuid>/Runner.app/Runner`, which contains
  /// the installation URL and never the bundle id, so a bundle-id match behind
  /// it would be dead code that made a broken URL match look recoverable.
  Future<int> _findAppProcessId(String installationUrl) {
    return withTempDir('flutter_proc_', (jsonDir) async {
      final jsonPath = p.join(jsonDir.path, 'processes.json');

      final result = await _runProcess('xcrun', [
        'devicectl',
        'device',
        'info',
        'processes',
        '--device',
        _addressedUdid,
        '--json-output',
        jsonPath,
      ]);
      if (result.exitCode != 0) {
        throw StateError(
          'devicectl could not list the processes running on '
          '$name, so the launched app cannot be attached to: '
          '${result.stderr}',
        );
      }

      final jsonFile = File(jsonPath);
      if (!jsonFile.existsSync()) {
        throw StateError(
          'devicectl reported the processes on $name but wrote '
          'no JSON to $jsonPath.',
        );
      }

      final Object? decoded;
      try {
        decoded = json.decode(jsonFile.readAsStringSync());
      } on FormatException catch (e) {
        throw StateError(
          'devicectl wrote a process list this could not read '
          '($e), so the launched app cannot be attached to.',
        );
      }
      final processes = decoded is Map<String, dynamic>
          ? (decoded['result']?['runningProcesses'] as List?) ?? const []
          : const [];

      for (final proc in processes) {
        if (proc is! Map) continue;
        final executable = proc['executable'] as String? ?? '';
        final pid = proc['processIdentifier'] as int?;
        if (pid == null) continue;
        if (!executable.contains(installationUrl)) continue;
        // App extensions live *inside* the bundle, so a widget extension's
        // executable contains the installation URL too — and attaching the
        // debugger to one leaves the app itself waiting forever for a
        // debugger that went elsewhere. Upstream hit exactly this:
        // flutter/flutter#183263.
        if (executable.contains('.appex')) continue;
        return pid;
      }

      throw StateError(
        'None of the ${processes.length} process(es) running on $name is the '
        'app installed at $installationUrl. It was launched stopped, so it '
        'should be among them; an app that crashed on launch will not be.',
      );
    });
  }

  /// Kill every helper [launch] started, and forget them.
  ///
  /// Its own method because a launch has two ends, not one: [stop] when it
  /// succeeded, and the rethrow path in [launch] when it did not. A helper a
  /// failed launch leaves running keeps forwarding to a phone nobody is using
  /// and holds its TCP ports, with nothing holding a handle to it.
  ///
  /// Each is killed by the handle this launch holds, never by matching a
  /// command line: `pkill -f iproxy` matches the caller's own arguments as
  /// readily as its target, and would in any case take out a concurrent
  /// session's forward.
  Future<void> _reapLaunchHelpers() async {
    final iproxy = _iproxyProcess;
    if (iproxy != null) {
      await _stopProcess('iproxy', iproxy, teardownBound);
      _iproxyProcess = null;
    }
    final consoleLauncher = _consoleLauncherProcess;
    if (consoleLauncher != null) {
      await _stopProcess(
        'iOS console launcher',
        consoleLauncher,
        teardownBound,
      );
      _consoleLauncherProcess = null;
    }
    // Killing lldb terminates the debugserver, which kills the app.
    final lldb = _lldbProcess;
    if (lldb != null) {
      await _stopProcess('lldb', lldb, teardownBound);
      _lldbProcess = null;
    }
    await _lldbOutput?.close();
    _lldbOutput = null;
  }

  @override
  Future<void> stop(AppInstance instance) async {
    await _reapLaunchHelpers();
    await _stopProcess('iOS app', instance.process, teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  /// iOS physical device screenshot via pymobiledevice3 DVT service.
  ///
  /// `_flutter.screenshot` does not work on iOS because the Impeller renderer
  /// (always enabled on iOS) does not implement compressed image capture.
  /// Instead, we use pymobiledevice3's DVT screenshot, which captures via
  /// Apple's Developer Tools service (same mechanism as Xcode).
  ///
  /// The screenshot binary is bundled as a Bazel py_binary and resolved from
  /// runfiles. Requires building via `bazel build //tools/dev_tool:flutter_bazel`.
  ///
  /// Prerequisites:
  ///   sudo flutter_bazel ios-tunnel  # in a separate terminal
  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      await vmClient.waitForFirstFrame();
    }

    final resolved = resolveRunfileWithManifest(
      'rules_flutter/tools/ios_screenshot/screenshot',
    );
    if (resolved == null) {
      throw StateError(
        'iOS device screenshot requires the bundled screenshot tool.\n'
        'Build via: bazel build //tools/dev_tool:flutter_bazel',
      );
    }

    // The py_binary needs RUNFILES_MANIFEST_FILE to find its venv and
    // bootstrap scripts within the dart_binary's runfiles.
    final result = await Process.run(
      resolved.path,
      [
        outputPath,
        '--udid',
        _addressedUdid,
      ],
      environment: {
        if (resolved.manifestPath != null)
          'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
      },
    );
    if (result.exitCode != 0) {
      final err = result.stderr as String;
      if (err.contains('Unable to connect to Tunneld') ||
          err.contains('no devices found')) {
        throw StateError(
          'iOS device screenshot requires a running tunnel daemon.\n'
          'Start in a separate terminal:\n'
          '  sudo flutter_bazel ios-tunnel',
        );
      }
      throw StateError('iOS screenshot failed: $err');
    }
  }

  Future<String> _extractBundleId(String appPath) async {
    final result = await _runProcess('defaults', [
      'read',
      '$appPath/Info.plist',
      'CFBundleIdentifier',
    ]);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
    throw StateError('Could not extract bundle ID from $appPath');
  }

  /// Extract the .app directory from an .ipa archive.
  ///
  /// Returns the directory alongside the bundle so the caller can hold it for
  /// exactly as long as the launch needs it — see [AppInstance.scratchDirs].
  Future<({String appPath, Directory dir})> _extractAppFromIpa(
    String ipaPath,
  ) async {
    final tempDir = await createTempDir('flutter_ipa_');
    try {
      final result = await _runProcess('unzip', [
        '-oq',
        ipaPath,
        '-d',
        tempDir.path,
      ]);
      if (result.exitCode != 0) {
        throw StateError('Failed to extract IPA: ${result.stderr}');
      }
      final payloadDir = Directory(p.join(tempDir.path, 'Payload'));
      if (!payloadDir.existsSync()) {
        throw StateError('No Payload directory found in IPA');
      }
      final apps = payloadDir
          .listSync()
          .where((e) => e.path.endsWith('.app'))
          .toList();
      if (apps.isEmpty) {
        throw StateError('No .app found in IPA Payload directory');
      }
      return (appPath: apps.first.path, dir: tempDir);
    } catch (_) {
      // Nothing usable came out of the archive; the half-unpacked copy is only
      // going to sit there.
      await deleteTempDir(tempDir);
      rethrow;
    }
  }
}

/// NSPredicate selecting an app's own log output on the iOS Simulator.
///
/// Ported from flutter_tools' `launchDeviceUnifiedLogging`
/// (`ios/simulators.dart`). Scoped to the app's process, then narrowed to
/// messages from the Flutter engine, the Swift runtime, or the app image
/// itself, then stripped of known-irrelevant noise.
///
/// This is *only* an app-output predicate. VM-service discovery uses its own
/// stream with a content match — see [IOSSimulatorDevice.launch] for why the
/// two are not merged.
String iosSimulatorLogPredicate(String appName) {
  String orP(List<String> clauses) => '(${clauses.join(" OR ")})';
  String andP(List<String> clauses) => clauses.join(' AND ');
  String notP(String clause) => 'NOT($clause)';

  return andP(<String>[
    'eventType = logEvent',
    'processImagePath ENDSWITH "$appName"',
    // From Flutter, from Swift (assertions/fatal errors), or from the app.
    orP(<String>[
      'senderImagePath ENDSWITH "/Flutter"',
      'senderImagePath ENDSWITH "/libswiftCore.dylib"',
      'processImageUUID == senderImageUUID',
    ]),
    notP(
      'eventMessage CONTAINS ": could not find icon for representation -> com.apple."',
    ),
    notP('eventMessage BEGINSWITH "assertion failed: "'),
    notP('eventMessage CONTAINS " libxpc.dylib "'),
  ]);
}

/// `"eventMessage" : "flutter: 21",` — one field of `log stream --style json`.
final _unifiedLoggingEventMessage = RegExp(r'.*"eventMessage" : (".*")');

/// Extract the message from a `log stream --style json` output line, or null
/// if the line carries no message (the format is pretty-printed across many
/// lines, most of which are other fields).
///
/// The predicate does the filtering, so every message that reaches here is
/// meant to be shown. Mirrors flutter_tools'
/// `_IOSSimulatorLogReader._onUnifiedLoggingLine`.
String? parseUnifiedLoggingLine(String line) {
  final match = _unifiedLoggingEventMessage.firstMatch(line);
  if (match == null) return null;
  try {
    final decoded = json.decode(match.group(1)!);
    return decoded is String ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Watch a log-emitting helper process for the VM-service announcement.
///
/// For sources where the helper process exists *only* to find the URI (the iOS
/// Simulator's discovery stream); app output comes from a separate stream. Like
/// [discoverVmServiceUri], this owns only its own subscription.
Future<Uri?> discoverVmServiceUriFromProcess(
  Process log, {
  Duration timeout = _vmServiceDiscoveryTimeout,
}) async {
  final logs = AppLogStream();
  final pump = pumpProcessLines(log, logs);
  // The helper is this stream's only source, so a helper that dies takes the
  // stream with it and discovery gives up at once instead of waiting out its
  // timeout on a process that will never say anything again.
  logs.closeWhen([pump.done]);
  try {
    return await discoverVmServiceUri(logs, timeout: timeout);
  } finally {
    await pump.dispose();
    await logs.close();
  }
}

/// Chrome launch flags matching Flutter's defaults for web dev mode.
///
/// These ensure predictable behavior during development:
/// - No extensions/popups that could interfere with the app
/// - Background timer throttling disabled for accurate async behavior
/// - No first-run/default-browser prompts
const chromeDebugFlags = [
  '--disable-extensions',
  '--disable-popup-blocking',
  '--bwsi',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-default-apps',
  '--disable-translate',
  '--disable-search-engine-choice-screen',
  '--disable-background-timer-throttling',
];

/// One launched Chrome, owned end to end: the process, the throwaway profile
/// it runs against, its diagnostics, and the choice of which page target the
/// dev tool drives.
///
/// Both web launch paths (DDC module server and static/WASM) go through here,
/// so a flag, a profile cleanup or a timeout is fixed in one place rather than
/// in two copies where a change to one silently misses the other.
class ChromeSession {
  final Process process;

  /// The fresh, empty Chrome profile this launch runs against.
  ///
  /// A throwaway profile is what makes a run reproducible — no extensions, no
  /// restored tabs, no saved sign-ins. The cost is a real directory Chrome
  /// fills with caches, so on success it goes into the instance's
  /// [AppInstance.scratchDirs] and dies with the launch, and a failed launch
  /// deletes it before rethrowing. Left behind they are not inert: a stale
  /// profile belongs to a browser a `--user-data-dir` scan can still find, and
  /// an orphaned window can serve a screenshot that makes a broken run look
  /// fine.
  final Directory userDataDir;

  /// The CDP debugging port announced on Chrome's stderr.
  final int cdpPort;

  /// The localhost URL the launched tab serves the app from — the URL every
  /// page-target lookup matches against.
  final String appUrl;

  ChromeSession._({
    required this.process,
    required this.userDataDir,
    required this.cdpPort,
    required this.appUrl,
  });

  /// The command line a launch on [url] with [options] runs.
  ///
  /// Pulled out so the argument order can be asserted without a browser: the
  /// user's own switches go last, immediately before the URL, which is where
  /// upstream puts them and therefore how a switch Chrome resolves by position
  /// behaves. The switches this tool owns are refused at flag-resolution time
  /// rather than being allowed to collide here.
  static List<String> launchArgs(
    String url,
    BrowserLaunchOptions options, {
    required String userDataDir,
  }) => [
    // 0 means "any free port"; either way the port is learned from the
    // browser's own announcement, never assumed.
    '--remote-debugging-port=${options.debugPort ?? 0}',
    ...chromeDebugFlags,
    '--user-data-dir=$userDataDir',
    if (options.headless) ...BrowserLaunchOptions.headlessFlags,
    ...options.scaleFlags,
    ...options.browserFlags,
    url,
  ];

  /// Launch Chrome on [url] and wait until it is observably up: debugging
  /// port announced *and* the tab navigated to the app. A failed launch
  /// leaves nothing behind — no browser, no profile directory.
  static Future<ChromeSession> launch({
    required String url,
    required ProcessStarter startProcess,
    BrowserLaunchOptions options = const BrowserLaunchOptions(),
    String? chromePath,
    Duration portTimeout = const Duration(seconds: 15),
    Duration pageTimeout = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 50),
  }) async {
    final exe = chromePath ?? findChrome();
    if (exe == null) {
      throw StateError(
        'Chrome not found. Install Chrome or use -d macos for desktop.',
      );
    }
    final userDataDir = await createTempDir('flutter_chrome_');
    final Process chrome;
    try {
      chrome = await startProcess(
        exe,
        launchArgs(url, options, userDataDir: userDataDir.path),
      );
    } catch (_) {
      await deleteTempDir(userDataDir);
      rethrow;
    }

    // Chrome's own process output — browser diagnostics, not app output.
    // Kept drained for the browser's lifetime so its pipes can never fill
    // (an unread stderr on a browser this chatty is the likeliest place for
    // a full-pipe stall), and read once for the CDP port announcement.
    // Deliberately *not* surfaced as app output: the app's console lives
    // inside the page, and Chrome's own chatter would bury it.
    final diagnostics = AppLogStream(capacity: 200);
    diagnostics.closeWhen([pumpProcessLines(chrome, diagnostics).done]);

    try {
      final cdpPort = await _discoverCdpPort(
        diagnostics,
        timeout: portTimeout,
        requestedPort: options.debugPort,
      );
      // The announcement is the readiness signal, not merely the number, so
      // it is awaited even when the port was dictated. A browser that takes a
      // different one than it was given is a state nothing here can drive:
      // every CDP consumer would dial the port that was asked for.
      if (options.debugPort != null && cdpPort != options.debugPort) {
        chrome.kill();
        await chrome.exitCode;
        await deleteTempDir(userDataDir);
        throw StateError(
          'Chrome was asked for --web-browser-debug-port '
          '${options.debugPort} and announced $cdpPort instead.',
        );
      }
      final session = ChromeSession._(
        process: chrome,
        userDataDir: userDataDir,
        cdpPort: cdpPort,
        appUrl: url,
      );
      await session.resolveAppPage(
        timeout: pageTimeout,
        pollInterval: pollInterval,
      );
      final viewport = options.viewport;
      if (viewport != null) await session.applyViewport(viewport);
      return session;
    } catch (_) {
      // A launch with no debugging port or no app page produced nothing
      // usable; don't leave the browser and its throwaway profile running
      // behind the error.
      chrome.kill();
      await chrome.exitCode;
      await deleteTempDir(userDataDir);
      rethrow;
    }
  }

  /// Wait until the launched tab is serving [appUrl] and return its CDP
  /// WebSocket debugger URL.
  ///
  /// Right after launch the tab is still an `about:blank` that has not
  /// navigated, and `/json` can list nothing at all, so this waits rather than
  /// failing on the first look — see [pickCdpPageTarget] for why nothing less
  /// than the app's own page will do. [launch] awaits it before declaring the
  /// browser up: a session whose app page never appeared is a failed launch,
  /// not a running one that every CDP consumer — screenshots, page reloads,
  /// the console — then mis-drives.
  ///
  /// The waiting itself is [resolveCdpPageTarget]'s, not a second copy of it:
  /// the states this rides out at launch are the same ones those consumers hit
  /// mid-session.
  Future<String> resolveAppPage({
    Duration timeout = const Duration(seconds: 15),
    Duration pollInterval = const Duration(milliseconds: 50),
  }) => resolveCdpPageTarget(
    cdpPort,
    appUrl: appUrl,
    timeout: timeout,
    pollInterval: pollInterval,
  );

  /// Lay the app out at [viewport], and prove that it did.
  ///
  /// `Emulation.setDeviceMetricsOverride` is sent once, right after the page
  /// is first resolved. Once applied it stays applied — it survives both
  /// closing the CDP socket that set it and the `Page.reload` a web hot
  /// restart performs — so there is no connection to hold open and no
  /// re-application to schedule.
  ///
  /// **Read the result back on a *fresh* connection.** While the setting
  /// client is still attached the page reports metrics it has not settled at,
  /// so a verification folded into that socket to save a round trip would fail
  /// against a browser that is behaving correctly.
  ///
  /// Verified rather than assumed because the failure it guards is invisible:
  /// an override that did not take leaves every later screenshot and layout
  /// measurement quietly describing the wrong viewport.
  Future<void> applyViewport(WebViewport viewport) => applyViewportOverCdp(
    cdpPort: cdpPort,
    appUrl: appUrl,
    viewport: viewport,
    asked: '--web-viewport',
  );
}

/// Web device — serves build output via HTTP and launches Chrome.
class WebDevice extends Device {
  final ProcessStarter _startProcess;

  /// CDP debugging port discovered from Chrome stderr.
  int? _cdpPort;

  /// The localhost URL serving the app (used to find the correct CDP tab).
  String? _appUrl;

  /// Module server for DDC dev mode. Set by RunCommand before launch.
  WebModuleServer? _moduleServer;

  /// What this run's web flags resolved to. Set by [RunPlan.resolve], which is
  /// where the flags are read — the device itself is built from a `-d` string,
  /// before there are any.
  ///
  /// The DDC path reads only the browser half here: its server is the module
  /// server, which the assembler builds from `server` of this same value.
  /// Both paths are therefore configured by one object, which is what stops a
  /// web flag from meaning something on one and nothing on the other.
  WebOptions? webOptions;

  /// Forwards the page's console when there is no DWDS to do it (WASM and
  /// production JS builds). Null in DDC dev mode, where `run_command` wires
  /// the DWDS VM service instead — see the one-source-per-platform note in the
  /// library docs.
  CdpConsoleClient? _consoleClient;

  WebDevice({ProcessStarter? startProcess})
    : _startProcess = startProcess ?? Process.start;

  @override
  String get name => 'Chrome';

  @override
  Future<List<HostTool>> requiredHostTools() async => [chromeTool()];

  /// Set the DDC module server for dev mode (hot restart support).
  void setModuleServer(WebModuleServer server) => _moduleServer = server;

  /// The CDP debugging port, if discovered.
  int? get cdpPort => _cdpPort;

  /// The localhost URL serving the app, if launched.
  String? get appUrl => _appUrl;

  @override
  CompilerConfig? createCompilerConfig(
    ToolchainPaths toolchain, {
    WebToolchainPaths? webToolchain,
    List<String> fileSystemRoots = const [],
    String fileSystemScheme = '',
    List<String> dartDefines = const [],
    String dartPluginRegistrantUri = '',
    List<String> enableExperiments = const [],
  }) {
    // Web builds its own filesystem roots (synthetic entrypoint dir + workspace)
    // in run_command; the native roots/scheme args are not used here. The
    // registrant URI is ignored too — the web synthetic main calls
    // registerPlugins() directly and re-runs on page-reload restart.
    if (webToolchain == null) return null;
    return WebCompilerConfig(
      webToolchain: webToolchain,
      dartDefines: dartDefines,
      enableExperiments: enableExperiments,
    );
  }

  /// Refused, rather than answered.
  ///
  /// [Device.createReloadStrategy] is asked by `NativePipelineAssembler` and
  /// by nothing else, and that assembler is only built for a native run — so
  /// this is unreachable. What it must not do is *inherit*: the base answer is
  /// [VmServiceReloadStrategy], and a browser run given the native strategy
  /// would send every reload looking for a VM service the browser does not
  /// have and report its absence as the fault. That is what
  /// `ReloadPipeline.strategy` is non-defaulting to prevent.
  ///
  /// A browser's strategy is built by the assembler that owns the run's shape:
  /// `WebPipelineAssembler` (DWDS, from the module server it just started) or
  /// `WasmPipelineAssembler` (CDP, from the port Chrome announced). Neither is
  /// derivable from a device that has not been told which run it is in.
  @override
  ReloadStrategy createReloadStrategy() {
    throw StateError(
      'A Chrome run does not get its reload strategy from the device: '
      'WebPipelineAssembler builds the DWDS one from the module server, and '
      'WasmPipelineAssembler the CDP one from the browser\'s debugging '
      'port. Reaching here means a native assembler was pointed at a web '
      'device.',
    );
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    if (_moduleServer != null) {
      return _launchWithModuleServer(onLog);
    }
    return _launchStaticServer(appPath, onLog);
  }

  /// What this run's web flags resolved to, or a failure naming what was
  /// never wired.
  ///
  /// Not a default: a `WebDevice` launching without them would run the browser
  /// with none of the flags the user typed, which is the exact silence these
  /// options exist to prevent.
  WebOptions get _webOptions {
    final options = webOptions;
    if (options == null) {
      throw StateError(
        'This WebDevice was never told how to serve or how to launch a '
        'browser (RunPlan.resolve sets webOptions). Without it none of the '
        'web flags would apply to this run.',
      );
    }
    return options;
  }

  /// Launch using DDC module server (dev mode with hot restart).
  Future<AppInstance> _launchWithModuleServer(AppLogListener? onLog) async {
    final options = _webOptions;
    // `--web-launch-url` if given, the server's own URL otherwise — and
    // checked against the server that actually bound, which is the first
    // moment its port is known.
    final url = options.launchUrlFor(_moduleServer!.uri!).toString();
    _appUrl = url;

    final session = await ChromeSession.launch(
      url: url,
      startProcess: _startProcess,
      options: options.browser,
    );
    _cdpPort = session.cdpPort;

    // No CDP console client here: DDC mode gets the app's output from the DWDS
    // VM service, and running both would print every line twice.
    return AppInstance(
      process: session.process,
      vmServiceUri: null,
      // The app's own output has its own source — DWDS, wired by the caller —
      // so it does not close with the browser process.
      logs: _newAppLogs(onLog),
      scratchDirs: [session.userDataDir],
    );
  }

  /// Launch using static file server (production/WASM mode).
  Future<AppInstance> _launchStaticServer(
    String appPath,
    AppLogListener? onLog,
  ) async {
    final options = _webOptions;
    final staticServer = StaticWebServer(
      rootPath: appPath,
      options: options.server,
    );
    final serverBase = await staticServer.start();

    final String url;
    final ChromeSession session;
    try {
      url = _appUrl = options.launchUrlFor(serverBase).toString();
      session = await ChromeSession.launch(
        url: url,
        startProcess: _startProcess,
        options: options.browser,
      );
    } catch (_) {
      // The session cleans up after its own failures; this path additionally
      // owns the static file server.
      await staticServer.stop();
      rethrow;
    }
    _cdpPort = session.cdpPort;
    final logs = _newAppLogs(onLog);

    // No DWDS on this path (WASM / production JS), so CDP is the only source
    // of the app's console output.
    _consoleClient = CdpConsoleClient(
      cdpPort: _cdpPort!,
      appUrl: _appUrl,
      logs: logs,
      // Its own default sink writes straight to stderr, which a `--machine`
      // client reading JSON lines cannot parse. The give-up warning already
      // says what is lost; this only gives it a level and an envelope.
      warn: (message) => _logger.warning({
        'message': 'browser_console_forwarding_stopped',
        'text': message,
      }),
    );
    try {
      await _consoleClient!.start();
    } catch (e) {
      // Console forwarding is not worth failing a launch over, but a silent
      // loss of all app output would be worse than the noise.
      _logger.warning({
        'message': 'browser_console_attach_failed',
        'text':
            'Could not attach to the browser console ($e). The app runs, '
            'but nothing it prints will appear in this run.',
        'error': '$e',
      });
      _consoleClient = null;
    }

    return AppInstance(
      process: session.process,
      vmServiceUri: null,
      server: staticServer.server,
      logs: logs,
      scratchDirs: [session.userDataDir],
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    // Unbounded on purpose. A client-side `WebSocket.close()` returns the
    // *outbound* sink's future and never waits for the peer's answering close
    // frame, so neither a peer that never answers nor one wedged so hard it
    // reads nothing can hold it. The one shape that does hang is a wedged peer
    // with a full send buffer, and this client writes a single small
    // `Runtime.enable` per connection, so it cannot build that backlog. The
    // SDK's own 5s close timer does NOT rescue that shape, so this decision
    // expires if the client ever grows chatty outbound traffic.
    await _consoleClient?.close();
    _consoleClient = null;
    final moduleServer = _moduleServer;
    if (moduleServer != null) {
      // dwds is third-party and its `stop()` reaches peer-dependent awaits —
      // `DebugService.close()` waits on a DDS shutdown, `DwdsVmClient.close()`
      // on a VM-service client dispose. This sits *before* the kill, so an
      // unbounded wait here means the browser is never even asked to exit.
      await boundedTeardownStep(
        'the web module server to shut down',
        moduleServer.stop(),
        teardownBound,
      );
    }
    // Unbounded: `HttpServer.close(force: false)` returns promptly against an
    // idle keep-alive connection, a held streaming response and an open
    // WebSocket upgrade alike.
    await instance.server?.close();
    // Before the profile goes: a browser that is still shutting down is still
    // writing its caches, and deleting the tree under it leaves a half-removed
    // directory and an error naming a file nobody asked about.
    await _stopProcess('browser', instance.process, teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  @override
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (_cdpPort == null) {
      throw StateError('CDP port not discovered — cannot capture screenshot');
    }
    await _cdpScreenshot(_cdpPort!, outputPath, appUrl: _appUrl);
  }

  /// Re-lay the running app out at [viewport] — what `app.setViewport` does.
  ///
  /// The same override `--web-viewport` applies at launch, sent again to the
  /// page that is already up, so a caller sweeping form factors does not have
  /// to relaunch between them.
  Future<void> setViewport(WebViewport viewport) async {
    final port = _cdpPort;
    final url = _appUrl;
    if (port == null || url == null) {
      throw StateError(
        'This web run has no browser to resize yet: its CDP port has not been '
        'discovered, so the page cannot be reached.',
      );
    }
    await applyViewportOverCdp(
      cdpPort: port,
      appUrl: url,
      viewport: viewport,
      asked: 'app.setViewport',
    );
  }
}

/// Chrome's announcement of its debugging port, printed to stderr when
/// launched with `--remote-debugging-port=0`:
/// `DevTools listening on ws://127.0.0.1:PORT/devtools/browser/...`
final cdpPortPattern = RegExp(r'DevTools listening on ws://\S+?:(\d+)/');

/// Discover the CDP debugging port from Chrome's own diagnostic output.
///
/// Reads [browserDiagnostics] rather than subscribing to Chrome's pipes
/// directly, so finding the port doesn't stop those pipes being drained — an
/// unread stderr on a browser as chatty as Chrome is the likeliest place for a
/// full-pipe stall.
///
/// Throws a [StateError] rather than returning null when the port never
/// arrives. It is not optional equipment: DDC dev mode dials CDP to give DWDS
/// its Chrome connection, and every web path uses it for screenshots and page
/// reloads, so accepting null here would buy a run with none of that and no
/// message. Upstream tool-exits in the same situation (`chrome.dart`'s "Unable to
/// connect to Chrome debug port"). The two causes are reported separately
/// because they call for different fixes.
Future<int> _discoverCdpPort(
  AppLogStream browserDiagnostics, {
  Duration timeout = const Duration(seconds: 15),
  int? requestedPort,
}) async {
  final completer = Completer<int>();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) {
      completer.completeError(
        StateError(
          'Chrome did not announce a DevTools debugging port within '
          '${timeout.inSeconds}s of launch. Without it there is no debugging '
          'connection: no DWDS VM service, no hot restart, no screenshots.'
          // A dictated port is the one thing about this launch that can be
          // wrong before Chrome even starts, and Chrome says nothing when it
          // cannot take one.
          '${requestedPort == null ? '' : ' --web-browser-debug-port '
                    '$requestedPort may already be in use.'}',
        ),
      );
    }
  });

  final sub = browserDiagnostics.lines.listen(
    (line) {
      if (completer.isCompleted) return;
      final match = cdpPortPattern.firstMatch(line.text);
      if (match != null) completer.complete(int.parse(match.group(1)!));
    },
    onDone: () {
      // Chrome's output is this stream's only source, so it ending means the
      // browser is gone — a different failure from a browser that is up and
      // silent, and worth saying so.
      //
      // With Chrome's own last words attached, because on its own that
      // sentence names a symptom and no cause. The causes that actually occur
      // are all things Chrome says on the way out — a sandbox it will not run
      // under, a profile directory it cannot write, a missing shared library —
      // and on a CI runner the alternative to quoting them here is reproducing
      // the failure somewhere the log can be reached.
      if (!completer.isCompleted) {
        completer.completeError(
          StateError(
            'Chrome exited before announcing a DevTools debugging port. '
            '${_browserLastWords(browserDiagnostics)}',
          ),
        );
      }
    },
  );

  try {
    return await completer.future;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}

/// The tail of what the browser printed, phrased for the end of an error.
///
/// Read back off [AppLogStream] rather than accumulated by the listener above:
/// the buffer survives the stream closing, so the lines are still there at the
/// moment the launch is known to have failed, and there is no second copy of
/// the same output to keep in step with the first.
///
/// Says so explicitly when there is nothing to quote. "Chrome exited and
/// printed nothing" is a real and different diagnosis from "Chrome exited" —
/// it rules out every cause that announces itself, and says the search belongs
/// somewhere other than the browser's output. An empty tail rendered as
/// nothing at all would instead read as if the quoting had been forgotten.
String _browserLastWords(AppLogStream browserDiagnostics, {int lines = 20}) {
  final tail = browserDiagnostics.read(-lines).lines;
  if (tail.isEmpty) {
    return 'It printed nothing at all on the way out, so its own output does '
        'not hold the reason.';
  }
  return 'It last said:\n${tail.map((l) => '  ${l.text}').join('\n')}';
}

/// Lay the app's page out at [viewport], and prove that it did.
///
/// Shared by the two things that set a viewport: `--web-viewport` at launch
/// ([ChromeSession.applyViewport]) and the `app.setViewport` command
/// mid-session ([WebDevice.setViewport]). [asked] names whichever one it was,
/// so the failure says which input was not honoured.
///
/// `Emulation.setDeviceMetricsOverride` is sent once and stays applied: the
/// override survives both closing the CDP socket that set it and the
/// `Page.reload` a web hot restart performs, so there is no connection to hold
/// open and nothing to re-apply.
///
/// **The read-back needs its own connection.** While the setting client is
/// still attached the page reports metrics it has not settled at, so folding
/// the check into that socket to save a round trip would fail against a
/// browser behaving correctly — each `_sendCdpToPage` below deliberately opens
/// its own.
///
/// Verified rather than assumed because the failure it guards is invisible: an
/// override that did not take leaves every later screenshot and layout
/// measurement quietly describing the wrong viewport.
Future<void> applyViewportOverCdp({
  required int cdpPort,
  required String appUrl,
  required WebViewport viewport,
  required String asked,
}) async {
  await _sendCdpToPage(cdpPort, appUrl, 'Emulation.setDeviceMetricsOverride', {
    'width': viewport.width,
    'height': viewport.height,
    // 0 means "keep the browser's own ratio" — see WebViewport.
    'deviceScaleFactor': viewport.deviceScaleFactor ?? 0,
    'mobile': true,
  });
  final got = await _sendCdpToPage(cdpPort, appUrl, 'Runtime.evaluate', {
    'expression':
        '({w: window.innerWidth, h: window.innerHeight, '
        'r: window.devicePixelRatio})',
    'returnByValue': true,
  });
  final value = got['result']?['result']?['value'];
  final width = value is Map ? value['w'] : null;
  final height = value is Map ? value['h'] : null;
  if (width != viewport.width || height != viewport.height) {
    throw StateError(
      'The browser did not take the viewport $asked asked for. Wanted '
      '${viewport.width}x${viewport.height}, and the page reports '
      '${width}x$height (devicePixelRatio ${value is Map ? value['r'] : '?'}).\n'
      'Every screenshot and every layout measurement taken from here on would '
      'describe a viewport nobody asked for.',
    );
  }
}

/// Send one CDP command to the page serving [appUrl] and return its reply.
///
/// A connection per command, and the page target re-resolved each time rather
/// than cached, because the target listing is not a settled fact — see
/// [pickCdpPageTarget].
Future<Map<String, dynamic>> _sendCdpToPage(
  int cdpPort,
  String appUrl,
  String method,
  Map<String, dynamic> params,
) async {
  final ws = await WebSocket.connect(
    await resolveCdpPageTarget(cdpPort, appUrl: appUrl),
  );
  try {
    final reply = Completer<Map<String, dynamic>>();
    ws.listen((data) {
      final msg = json.decode(data as String) as Map<String, dynamic>;
      if (msg['id'] == 1 && !reply.isCompleted) reply.complete(msg);
    });
    ws.add(json.encode({'id': 1, 'method': method, 'params': params}));
    final response = await reply.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError('CDP $method did not answer'),
    );
    final error = response['error'];
    if (error != null) throw StateError('CDP $method failed: $error');
    return response;
  } finally {
    await ws.close();
  }
}

/// Capture a screenshot via Chrome DevTools Protocol.
///
/// Connects to `http://127.0.0.1:<port>/json` to discover the app tab's
/// WebSocket URL, then sends `Page.captureScreenshot` over CDP.
/// If [appUrl] is provided, selects the tab matching that URL.
Future<void> _cdpScreenshot(
  int cdpPort,
  String outputPath, {
  String? appUrl,
}) async {
  // Same target selection every CDP consumer uses — see `cdp_console.dart`.
  final wsUrl = await resolveCdpPageTarget(cdpPort, appUrl: appUrl);

  // Connect WebSocket and send Page.captureScreenshot.
  final ws = await WebSocket.connect(wsUrl);
  try {
    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      final msg = json.decode(data as String) as Map<String, dynamic>;
      if (msg['id'] == 1 && !responseCompleter.isCompleted) {
        responseCompleter.complete(msg);
      }
    });

    ws.add(
      json.encode({
        'id': 1,
        'method': 'Page.captureScreenshot',
        'params': {'format': 'png'},
      }),
    );

    final response = await responseCompleter.future.timeout(
      const Duration(seconds: 10),
    );

    final result = response['result'] as Map<String, dynamic>?;
    if (result == null || result['data'] == null) {
      throw StateError('CDP screenshot returned no data');
    }

    // Decode base64 PNG and write to file.
    final bytes = base64.decode(result['data'] as String);
    await File(outputPath).writeAsBytes(bytes);
  } finally {
    await ws.close();
  }
}

/// Find the Chrome executable path, or null if not found.
///
/// One definition of where Chrome lives, shared with the preflight that reports
/// its absence — see [chromeTool].
String? findChrome() => chromeTool().find();
