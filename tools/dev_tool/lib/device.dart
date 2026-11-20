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
/// [discoverVmServiceUri]). Android's logcat and the iOS Simulator's log
/// stream carry every app on the device, not just this one, so there an
/// announcement counts only when this launch's app process made it
/// ([discoverOwnVmServiceUri]).
///
/// A physical iOS device is the one exception. A wirelessly attached device
/// takes the URI from the app's `_dartVmService._tcp` mDNS advertisement
/// ([MdnsVmServiceDiscovery]), the only channel it has. A wired one races the
/// announcement in its console against the advertisement, as flutter_tools
/// does, and forwards the device port over USB: the announcement does not
/// wait on iOS letting the app onto the local network, and the advertisement
/// does.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'browser_extension_channel.dart';
import 'build_mode.dart';
import 'cdp_app_page.dart';
import 'cdp_console.dart';
import 'child_processes.dart';
import 'chrome_profile.dart';
import 'compiler_config.dart';
import 'devicectl_screens.dart';
import 'host_tools.dart';
import 'key_press.dart';
import 'launch_bundle_parts.dart';
import 'logging.dart';
import 'mdns_vm_service_discovery.dart';
import 'native_patch_delivery.dart';
import 'reload_strategy.dart';
import 'runfiles_helper.dart';
import 'screen.dart';
import 'simulator_log_stream.dart';
import 'simulator_terminations.dart';
import 'temp_dir.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'teardown.dart';
import 'web_module_server.dart';
import 'web_options.dart';
import 'x11_screenshot.dart';

export 'app_log.dart' show AppLogLine, AppLogStream, LogPage;
export 'build_mode.dart' show BuildMode;
export 'host_tools.dart' show HostTool, MissingHostToolException;

final _logger = Logger('dev_tool.device');

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
/// Neither `kill`'s return value is read. `false` is what it reports for a
/// process that has already exited, which is the outcome being asked for: a
/// Ctrl-C in a terminal reaches the app along with this tool, so by the time
/// teardown asks, the app has often gone. Whether a stop worked is settled by
/// the process exiting, which is what the bound waits for.
Future<void> _stopProcess(String what, Process process, Duration bound) async {
  process.kill();
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
    throw HelperTimedOut(
      '$what (pid ${process.pid}) did not answer within '
      '${bound.inMilliseconds}ms and was killed. What it had written by then, '
      'on stderr: ${err.isEmpty ? '(nothing)' : err}',
    );
  }
  await drained;
  return ProcessResult(process.pid, exitCode, out.toString(), err.toString());
}

/// What [runProcessBounded] throws for a helper it killed at its bound.
///
/// A [StateError], as it always was to the callers that report any failure
/// alike; its own type for a caller that answers a timeout differently.
class HelperTimedOut extends StateError {
  HelperTimedOut(super.message);
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

  /// Readers of [process]'s output pipes that must not outlive the run.
  ///
  /// A pipe reaches end-of-file only when *every* holder of its write end has
  /// closed it, and a process can leave a descendant behind that still holds
  /// one (a browser's helper process outliving the browser, say). A reader that
  /// waits for that end-of-file is then a live handle, and a Dart VM with a live
  /// handle does not exit: the tool answers `daemon.shutdown` and keeps
  /// running. These are cancelled in `stop()`, which is the point at which
  /// nothing further the process writes matters.
  final List<AppLogPump> outputPumps;

  AppInstance({
    required this.process,
    this.vmServiceUri,
    this.server,
    AppLogStream? logs,
    this.auxiliaryProcesses = const [],
    this.scratchDirs = const [],
    this.outputPumps = const [],
  }) : logs = logs ?? AppLogStream();

  /// Cancel every [outputPumps] reader, so no pipe subscription outlives the
  /// run. Safe to call more than once.
  Future<void> disposeOutputPumps() async {
    await Future.wait(outputPumps.map((pump) => pump.dispose()));
  }

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

/// A temp folder that a launch in flight owns: the unpacked app it installs
/// or runs.
///
/// A launch that returns hands the folder to its [AppInstance], whose `stop`
/// deletes it. Until then the launch must delete it on every way out: a throw,
/// and an abandon from a teardown that may end the tool before the launch
/// unwinds. Otherwise each failed launch leaves a copy of the app in TMPDIR.
class _LaunchScratch {
  Directory? _dir;

  void hold(Directory dir) => _dir = dir;

  /// Gives the folder to the [AppInstance] being returned, which deletes it
  /// from then on.
  List<Directory> handOver() {
    final dir = _dir;
    _dir = null;
    return [?dir];
  }

  /// Deletes the folder, unless it was handed over.
  Future<void> release() async {
    final dir = _dir;
    _dir = null;
    if (dir != null) await deleteTempDir(dir);
  }
}

/// How an app the tool was connected to ended, as its platform tells it.
class AppExit {
  /// The app ended because someone asked it to (it was closed, or quit), or it
  /// ended itself with code 0: what upstream calls "Application finished."
  const AppExit.closed(this.account) : closed = true;

  /// The app ended without being asked to: a crash, a kill, a failing exit.
  const AppExit.crashed(this.account) : closed = false;

  /// The platform's account of the end, for the user.
  final String account;

  /// Whether the end was asked for rather than a crash.
  final bool closed;
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

  /// Why [instance] is no longer running, once its VM service could not be
  /// reached: null while it runs, or on a device that cannot tell.
  Future<String?> whyAppExited(AppInstance instance) async => null;

  /// How [instance] ended, once its VM service could not be reached: null
  /// while it runs, or on a device that cannot tell.
  ///
  /// Every end [whyAppExited] reports is a crash unless the device says
  /// otherwise: a device whose platform can tell a close from a crash, when
  /// the tool does not hold the app's exit status itself, overrides this.
  Future<AppExit?> howAppExited(AppInstance instance) async {
    final account = await whyAppExited(instance);
    return account == null ? null : AppExit.crashed(account);
  }

  /// Release what a launch left running when no session took ownership of it.
  ///
  /// The launcher gives this to the run's teardown before it calls [launch],
  /// because a session's own disposer is registered only once the launch and
  /// the VM-service connect after it have both finished — minutes, on a
  /// physical device. A teardown in that window (SIGTERM, `daemon.shutdown`)
  /// otherwise reaches nothing on the device, and helpers that outlive this
  /// process keep ports and apps up with nothing left to stop them. A launch
  /// still in flight must fail rather than start anything more.
  ///
  /// Called after the session's own [stop] when there is one, so it must be a
  /// no-op on anything that is already released.
  Future<void> abandonLaunch() async {}

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

  /// The screens this device draws to.
  ///
  /// One, for every device but a few iOS simulators and phones: asked anew each
  /// time, because what a multi-screen device reports changes as it is folded
  /// and unfolded and its screens' ids change on every boot. Within [deadline]
  /// when it is part of a screenshot; on its own, within [screenshotBound].
  Future<List<Screen>> screens({ScreenshotDeadline? deadline}) async => [
    Screen.only(name),
  ];

  /// How long a screenshot gets, from the moment the app can be captured to
  /// the moment the PNG is written: listing the screens, asking again while a
  /// device with several built-in screens has not reported which is active, and
  /// the capture itself, all out of this one budget.
  ///
  /// Taken once, as a [ScreenshotDeadline], and handed to each step to spend
  /// what is left. The capture runs inside an HTTP handler, so what has to be
  /// bounded is what the caller waits for. A device whose capture is a helper
  /// bounds the helper by this too.
  ///
  /// Settable so a test can drive the expiry in milliseconds.
  Duration screenshotBound = const Duration(seconds: 30);

  /// The pause between two asks of [screens] while a device has not reported.
  Duration screenPollInterval = const Duration(milliseconds: 500);

  /// The screen [screenshot] captures for [requested]: the one screen named,
  /// or, with none named, the one the app is on. Throws
  /// [ScreenSelectionException] when that cannot be settled — see
  /// [chooseScreen] — and [ScreenshotTimeout] when [deadline] runs out first.
  Future<Screen> resolveScreen(
    String? requested,
    ScreenshotDeadline deadline,
  ) => resolveScreenOf(
    (deadline) => screens(deadline: deadline),
    requested,
    deadline: deadline,
    interval: screenPollInterval,
  );

  /// Capture a screenshot of the running app.
  ///
  /// [screen] names a screen of [screens] by id or name; without it, the screen
  /// the app is on (see [chooseScreen]). [window] selects a window *within* a
  /// screen on a device that has windows; a window is not a screen.
  ///
  /// Waits for the app to be capturable ([prepareScreenshot]), then takes one
  /// [ScreenshotDeadline] of [screenshotBound], resolves the screen and has
  /// the device capture it ([captureScreen]). The wait for the first frame is
  /// the app's, not the device's, and is not part of that budget.
  Future<void> screenshot(
    AppInstance instance,
    String outputPath, {
    VmServiceClient? vmClient,
    String? window,
    String? screen,
  }) async {
    await prepareScreenshot(vmClient);
    final deadline = ScreenshotDeadline(screenshotBound);
    final target = await resolveScreen(screen, deadline);
    await captureScreen(
      instance,
      outputPath,
      target,
      deadline,
      vmClient: vmClient,
      window: window,
    );
  }

  /// Wait for whatever has to be true before a capture shows the app, ahead of
  /// choosing the screen: a multi-screen device's active screen follows its
  /// posture and is read as late as it can be.
  Future<void> prepareScreenshot(VmServiceClient? vmClient) async {}

  /// Capture [screen], one of [screens], to the PNG at [outputPath], within
  /// what is left of [deadline].
  ///
  /// For native platforms, uses the VM service `_flutter.screenshot` extension
  /// (pass [vmClient]). For web, subclasses override with CDP.
  /// Throws [UnsupportedError] if no VM client is available.
  ///
  /// [window] is an optional, platform-specific selector for which window to
  /// capture (e.g. on macOS, the exact window title). Devices that don't
  /// support window selection ignore it.
  Future<void> captureScreen(
    AppInstance instance,
    String outputPath,
    Screen screen,
    ScreenshotDeadline deadline, {
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

  /// The build mode of the app this device will launch.
  ///
  /// Set before [preflight], because it changes which host tools a launch
  /// needs as well as how it launches. Debug until told otherwise, which is
  /// what every launch did before any device needed to know.
  BuildMode buildMode = BuildMode.debug;

  /// Whether filesystem paths on this device are Windows-shaped.
  ///
  /// The device answers, not the host: a devFS path comes back from the target
  /// VM, and converting it with `Platform.isWindows` is right only while the
  /// two happen to agree. Driving an Android phone from a Windows desktop is
  /// where they do not.
  bool get usesWindowsPaths => false;

  /// Whether the app runs on this machine's filesystem, so a directory the app
  /// made (its devFS) can be deleted from here once the app has exited.
  bool get sharesHostFilesystem => false;

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

  /// How a restart reads the launch bundle's native libraries and assets
  /// without building the launch artifact, or null for a device with no
  /// artifact to avoid building (the web).
  ///
  /// A restart should not pay for the artifact: an APK is dexed, linked, zipped
  /// and signed, and an Apple debug bundle's `App.framework` and a desktop
  /// debug bundle carry the app's kernel, so building one recompiles the whole
  /// program on every Dart edit. None of it is needed to learn that only Dart
  /// changed.
  LaunchBundleParts? get launchBundleParts => null;

  /// Learn whatever [buildArgs] depends on that only the device can say.
  ///
  /// Called once, before anything reads [buildArgs]. Most devices' flags are
  /// fixed by their kind; an Android device's are its ABI's.
  Future<void> resolveBuildArgs() async {}

  /// Create the compiler config for hot reload on this platform.
  ///
  /// [patchedSdkRoot] is the patched SDK the app's build compiled against,
  /// from its dev config.
  ///
  /// Returns null if this device does not support hot reload.
  CompilerConfig? createCompilerConfig(
    String patchedSdkRoot, {
    WebToolchainPaths? webToolchain,
    List<String> fileSystemRoots = const [],
    String fileSystemScheme = '',
    List<String> dartDefines = const [],
    String dartPluginRegistrantUri = '',
    bool trackWidgetCreation = false,
    List<String> enableExperiments = const [],
  }) => NativeCompilerConfig(
    patchedSdkRoot: patchedSdkRoot,
    fileSystemRoots: fileSystemRoots,
    fileSystemScheme: fileSystemScheme,
    dartDefines: dartDefines,
    dartPluginRegistrantUri: dartPluginRegistrantUri,
    trackWidgetCreation: trackWidgetCreation,
    enableExperiments: enableExperiments,
  );

  /// Create the reload strategy for this platform.
  ///
  /// Every device that gets here has one: a device this cannot answer for
  /// refuses by name (see [WebDevice.createReloadStrategy]) rather than
  /// returning null.
  ReloadStrategy createReloadStrategy() => VmServiceReloadStrategy();

  /// How a native hot patch reaches the app this device launched, or null where
  /// none can: a device no delivery has been written for, or one that has not
  /// launched the app it would need to know about.
  NativePatchDelivery? get nativePatchDelivery => null;
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

  /// Starts `osascript` for [_bringToFront], when a test supplies one.
  final ProcessStarter? _injectedActivationStart;

  MacOSDevice({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
    ProcessStarter? startScreenshotProcess,
    ProcessStarter? startActivationProcess,
  }) : _runProcess = runProcess ?? Process.run,
       _injectedStart = startProcess,
       _injectedScreenshotStart = startScreenshotProcess,
       _injectedActivationStart = startActivationProcess;

  /// How long activation through System Events gets before it is killed.
  ///
  /// With the Automation permission undecided the AppleEvent does not fail, it
  /// blocks, so without a bound every launch on a machine that has not granted
  /// it would hang there. Settable so a test can drive the expiry.
  Duration activationBound = const Duration(seconds: 10);

  Future<Process> _startProcess(String exe, List<String> args) =>
      (_injectedStart ?? _defaultStart)(exe, args);

  /// Start the app with the engine switches this launch asked for.
  ///
  /// An instance method because the switches depend on [startPaused], which is
  /// set on the device after it is constructed. The
  /// injected [_startProcess] bypasses this entirely, which is why the
  /// environment it builds lives in [desktopLaunchEnvironment] where a test
  /// can reach it.
  Future<Process> _defaultStart(String exe, List<String> args) =>
      startChildProcess(
        exe,
        args,
        environment: desktopLaunchEnvironment(startPaused: startPaused),
      );

  @override
  NativePatchDelivery? get nativePatchDelivery => const MacOSPatchDelivery();

  @override
  LaunchBundleParts? get launchBundleParts => const LaunchBundleParts(
    aspect: macosBundlePartsAspect,
    assetsGroup: macosBundlePartsOutputGroup,
    nativeLibsGroup: macosNativeLibsOutputGroup,
  );

  @override
  String get name => 'macOS';

  @override
  bool get sharesHostFilesystem => true;

  final _scratch = _LaunchScratch();

  /// The app a launch in flight has started, until the launch returns it.
  Process? _launching;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    try {
      return await _launch(appPath, onLog: onLog);
    } catch (_) {
      await _releaseLaunch();
      rethrow;
    }
  }

  @override
  Future<void> abandonLaunch() => _releaseLaunch();

  /// Undo a launch that did not return: the app it started, which runs out of
  /// the extracted copy, and then that copy.
  Future<void> _releaseLaunch() async {
    final process = _launching;
    _launching = null;
    if (process != null) {
      await _stopProcess('macOS app', process, teardownBound);
    }
    await _scratch.release();
  }

  Future<AppInstance> _launch(String appPath, {AppLogListener? onLog}) async {
    // Extract .app from .zip if needed (Bazel macOS bundles are zipped).
    String resolvedPath = appPath;
    if (appPath.endsWith('.zip')) {
      final unpacked = await _extractAppFromZip(appPath);
      resolvedPath = unpacked.appPath;
      _scratch.hold(unpacked.dir);
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

    final process = _launching = await _startProcess(
      executable,
      [],
    );

    final logs = _startProcessLogs(process, onLog);
    final vmServiceUri = await discoverVmServiceUri(logs);
    if (resolvedPath.endsWith('.app')) {
      await _bringToFront(resolvedPath, process.pid);
    }

    _launching = null;
    return AppInstance(
      process: process,
      vmServiceUri: vmServiceUri,
      logs: logs,
      // The app runs out of this directory, so it goes only once the process
      // has exited — which `stop` awaits before disposing it.
      scratchDirs: _scratch.handOver(),
    );
  }

  @override
  Future<String?> whyAppExited(AppInstance instance) =>
      _desktopAppExit(name, instance, posix: true);

  /// Bring the launched app's window to the front.
  ///
  /// The app is started as a bare executable, not through LaunchServices, and
  /// a process started that way is not made frontmost. On a Mac with Stage
  /// Manager its window then sits in the strip as a thumbnail, about 113x138 pt
  /// and not on screen at the size the app asked for, and a screenshot of it is
  /// of that — or black, once another app has come forward.
  ///
  /// Two ways, in this order, because neither works everywhere:
  ///
  /// 1. `open` on the running bundle activates that same process, starts no
  ///    second one and needs no permission. It needs LaunchServices to know
  ///    the process, which it does in a desktop session and does not over ssh:
  ///    there it fails with error -600 (procNotFound).
  /// 2. System Events sets the process frontmost by its pid, which does not
  ///    depend on LaunchServices. It needs the Automation permission, and with
  ///    that undecided it blocks, so it is the second resort and is bounded
  ///    ([activationBound]).
  ///
  /// A failure of both is reported and the launch carries on: the app is
  /// running and drivable, only its window may not be on screen at full size.
  /// Everything each step said goes on the record as fields, because a JSON log
  /// keeps fields and drops the prose.
  Future<void> _bringToFront(String bundlePath, int pid) async {
    final failure = <String, Object?>{'bundle': bundlePath, 'pid': pid};
    try {
      final opened = await _runProcess('open', [bundlePath]);
      if (opened.exitCode == 0) return;
      failure['openExitCode'] = opened.exitCode;
      failure['openStderr'] = '${opened.stderr}'.trim();
    } on ProcessException catch (e) {
      failure['openError'] = '$e';
    }
    try {
      final result = await runProcessBounded(
        (exe, args, _) =>
            (_injectedActivationStart ?? startChildProcess)(exe, args),
        'osascript',
        [
          '-e',
          'tell application "System Events" to set frontmost of '
              '(first process whose unix id is $pid) to true',
        ],
        environment: const {},
        bound: activationBound,
        what: 'Activating the app through System Events',
      );
      if (result.exitCode == 0) return;
      failure['systemEventsExitCode'] = result.exitCode;
      failure['systemEventsStderr'] = '${result.stderr}'.trim();
    } on ProcessException catch (e) {
      failure['systemEventsError'] = '$e';
    } on StateError catch (e) {
      failure['systemEventsError'] = e.message;
    }
    _logger.warning({
      'message': 'macos_app_not_activated',
      ...failure,
      'text':
          'Could not bring the app to the front: $failure. It is running, but '
          'its window may not be on screen at full size. Activation through '
          'System Events needs the Automation permission for the terminal '
          'that runs this tool.',
    });
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
  @override
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
  Future<void> captureScreen(
    AppInstance instance,
    String outputPath,
    Screen screen,
    ScreenshotDeadline deadline, {
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
      : startChildProcess(exe, args, environment: environment);

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
  final X11Capture _captureX11;
  final ProcessStarter? _injectedStart;

  LinuxDevice({X11Capture? captureX11, ProcessStarter? startProcess})
    : _captureX11 =
          captureX11 ??
          ((outputPath, {required environment}) =>
              captureX11Screen(outputPath, environment: environment)),
      _injectedStart = startProcess;

  /// The whole environment the app starts in, or null for this process's.
  ///
  /// Set by an integration test, whose app runs with the libraries of a pinned
  /// runtime and on a display of the test's own: nothing of the host's
  /// environment is added to it.
  Map<String, String>? environment;

  Future<Process> _startProcess(String exe, List<String> args) =>
      (_injectedStart ?? _defaultStart)(exe, args);

  /// What the app starts with: [environment], or this process's, with the
  /// engine switches this launch asked for.
  ///
  /// A getter because the switches depend on [startPaused], which is set on
  /// the device after it is constructed. The injected [_startProcess] bypasses
  /// it, which is why a test reads it here.
  Map<String, String> get launchEnvironment =>
      desktopLaunchEnvironment(startPaused: startPaused, base: environment);

  Future<Process> _defaultStart(String exe, List<String> args) =>
      startChildProcess(
        exe,
        args,
        environment: launchEnvironment,
        includeParentEnvironment: environment == null,
      );

  @override
  LaunchBundleParts? get launchBundleParts => const LaunchBundleParts(
    aspect: linuxBundlePartsAspect,
    assetsGroup: linuxBundlePartsOutputGroup,
    nativeLibsGroup: linuxNativeLibsOutputGroup,
  );

  @override
  String get name => 'Linux';

  @override
  bool get sharesHostFilesystem => true;

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

    try {
      final process = _launching = await _startProcess(executable, []);
      final logs = _startProcessLogs(process, onLog);
      final vmServiceUri = await discoverVmServiceUri(logs);
      _launching = null;
      return AppInstance(
        process: process,
        vmServiceUri: vmServiceUri,
        logs: logs,
      );
    } catch (_) {
      await _releaseLaunch();
      rethrow;
    }
  }

  /// The app a launch in flight has started, until the launch returns it.
  Process? _launching;

  @override
  Future<void> abandonLaunch() => _releaseLaunch();

  /// Stops the app of a launch that did not return. A launch that returned its
  /// app has handed it to [stop], and this leaves it.
  Future<void> _releaseLaunch() async {
    final process = _launching;
    _launching = null;
    if (process != null) {
      await _stopProcess('Linux app', process, teardownBound);
    }
  }

  @override
  Future<String?> whyAppExited(AppInstance instance) =>
      _desktopAppExit(name, instance, posix: true);

  @override
  Future<void> stop(AppInstance instance) async {
    await _stopProcess('Linux app', instance.process, teardownBound);
    await instance.logs.close();
  }

  @override
  Future<void> captureScreen(
    AppInstance instance,
    String outputPath,
    Screen screen,
    ScreenshotDeadline deadline, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    // The display the app draws on: the integration runtime's own, or the
    // desktop's. The tool speaks to it itself, so the host needs no
    // screenshot program.
    return deadline.within(
      'capturing the X display',
      () => _captureX11(
        outputPath,
        environment: environment ?? Platform.environment,
      ),
    );
  }
}

/// Writes a PNG of the X display `environment['DISPLAY']` names.
typedef X11Capture = Future<void> Function(
  String outputPath, {
  required Map<String, String> environment,
});

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
  Future<Process> _defaultStart(String exe, List<String> args) =>
      startChildProcess(
        exe,
        args,
        environment: desktopLaunchEnvironment(startPaused: startPaused),
      );

  @override
  bool get usesWindowsPaths => true;

  @override
  bool get sharesHostFilesystem => true;

  @override
  LaunchBundleParts? get launchBundleParts => const LaunchBundleParts(
    aspect: windowsBundlePartsAspect,
    assetsGroup: windowsBundlePartsOutputGroup,
    nativeLibsGroup: windowsNativeLibsOutputGroup,
  );

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
    _launchInFlight = true;
    final launchPath = _stage(appPath);
    try {
      return await _launch(launchPath, onLog: onLog);
    } catch (_) {
      await _releaseLaunch();
      rethrow;
    }
  }

  /// Whether a launch has begun and not yet returned its app.
  bool _launchInFlight = false;

  /// The app a launch in flight has started, until the launch returns it.
  Process? _launching;

  @override
  Future<void> abandonLaunch() => _releaseLaunch();

  /// Undo a launch that did not return: the app it started, which runs out of
  /// the staged copy and holds it open, and then that copy. A launch that
  /// returned its app has handed both to [stop], and this leaves them.
  Future<void> _releaseLaunch() async {
    if (!_launchInFlight) return;
    _launchInFlight = false;
    final process = _launching;
    _launching = null;
    if (process != null) {
      await _stopProcess('Windows app', process, teardownBound);
    }
    _clearStaging();
  }

  Future<AppInstance> _launch(
    String launchPath, {
    AppLogListener? onLog,
  }) async {
    // Bundle directories contain the executable at <dir>/<name>.exe.
    String executable = launchPath;
    if (FileSystemEntity.isDirectorySync(launchPath)) {
      final dirName = p.basename(launchPath);
      executable = p.join(launchPath, '$dirName.exe');
    }

    final process = _launching = await _startProcess(executable, []);
    final logs = _startProcessLogs(process, onLog);
    final vmServiceUri = await discoverVmServiceUri(logs);
    _launching = null;
    _launchInFlight = false;
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
  Future<String?> whyAppExited(AppInstance instance) =>
      _desktopAppExit(name, instance, posix: false);

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
  @override
  Duration screenshotBound = const Duration(seconds: 30);

  /// Captures the screen with the bundled DXGI Desktop Duplication helper.
  ///
  /// Bounded by [screenshotBound]: see there for why an unbounded capture is
  /// the one failure this path must not have.
  @override
  Future<void> captureScreen(
    AppInstance instance,
    String outputPath,
    Screen screen,
    ScreenshotDeadline deadline, {
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
      : startChildProcess(exe, args, environment: environment);
}

/// Signature for running a process and returning its result (allows test injection).
typedef ProcessRunSync = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Signature for starting a streaming process (allows test injection).
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// [ProcessStarter] for a helper whose environment the caller assembles.
///
/// The bundled screenshot helpers need `RUNFILES_MANIFEST_FILE` forwarded to
/// find their own runfiles, and that path is only known at the call site.
typedef ProcessStarterWithEnvironment = Future<Process> Function(
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
/// [aapt2Path] names the binary to run: the workspace's SDK's.
Future<({String packageName, String? activityName})> extractPackageInfo(
  String apkPath, {
  ProcessRunSync? runProcess,
  required String aapt2Path,
}) async {
  final run = runProcess ?? Process.run;
  final result = await run(aapt2Path, ['dump', 'badging', apkPath]);
  if (result.exitCode != 0) {
    throw StateError(
      '`$aapt2Path dump badging $apkPath` failed '
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

/// The ABIs rules_flutter builds an Android app for.
const androidBuildableAbis = ['arm64-v8a', 'x86_64', 'armeabi-v7a'];

/// The ABI to build for, given a device's `ro.product.cpu.abilist` (a
/// comma-separated list, the device's own ABI first).
///
/// Throws a [StateError] naming the list when none of it is an ABI
/// rules_flutter builds for.
String androidAbiFromAbiList(String abiList, {required String deviceName}) {
  final abis = abiList
      .trim()
      .split(',')
      .map((abi) => abi.trim())
      .where((abi) => abi.isNotEmpty)
      .toList();
  for (final abi in abis) {
    if (androidBuildableAbis.contains(abi)) return abi;
  }
  throw StateError(
    '$deviceName runs ${abis.isEmpty ? 'no ABI it reported' : abis.join(', ')}, '
    'and rules_flutter builds Android apps for ${androidBuildableAbis.join(', ')}.',
  );
}

/// Android device (via adb).
class AndroidDevice extends Device {
  final String? deviceId;
  String? _packageName;
  String? _activityName;
  String? _abi;

  /// The `adb` to run: the workspace's SDK's (see `android_sdk.dart`), or
  /// the one an integration test's runner names.
  final String adbPath;

  /// The `aapt2` that reads the APK's package name and launchable activity,
  /// from the same SDK. Only a launch that has to read the APK's manifest
  /// runs it.
  final String aapt2Path;

  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  /// Starts the `adb` a capture shells to, when a test supplies one.
  ///
  /// Separate from [_startProcess], which is the launch's own logcat: a test
  /// that fakes a launch must not thereby fake every capture too.
  final ProcessStarter? _injectedScreenshotStart;

  /// Starts the `adb shell am force-stop` before a launch, when a test
  /// supplies one. Separate from [_startProcess] for the same reason
  /// [_injectedScreenshotStart] is.
  final ProcessStarter? _injectedForceStopStart;

  /// How long the stop before a launch may take: flutter_tools' `stopApp`
  /// bound. A parameter so tests can drive the expiry.
  final Duration forceStopBound;

  /// The host port `adb forward tcp:0` allocated for this launch, if any.
  ///
  /// Held so [stop] can remove exactly the forward this launch created. The
  /// forward is not a process: it is state inside the adb *server*, which
  /// outlives every dev tool run and every device disconnect, so nothing
  /// reclaims it on its own. Clearing all forwards instead would take out
  /// another session's on the same host.
  int? _forwardedHostPort;

  /// The logcat [launch] started, until [launch] returns it in its
  /// [AppInstance]. A child process, so a launch that fails or is abandoned
  /// part way has to stop it: nothing else would.
  Process? _launchLogcat;

  /// Whether the upcoming launch expects the app to host a Dart VM service
  /// (debug/JIT builds). Set by the run command before [launch]; enables the
  /// INTERNET-permission preflight, which release/profile launches skip.
  bool expectsVmService = false;

  AndroidDevice({
    this.deviceId,
    String? packageName,
    String? activityName,
    String? abi,
    required this.adbPath,
    required this.aapt2Path,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
    ProcessStarter? startScreenshotProcess,
    ProcessStarter? startForceStopProcess,
    this.forceStopBound = const Duration(seconds: 30),
  }) : _packageName = packageName,
       _activityName = activityName,
       _abi = abi,
       _runProcess = runProcess ?? Process.run,
       _startProcess = startProcess ?? startChildProcess,
       _injectedScreenshotStart = startScreenshotProcess,
       _injectedForceStopStart = startForceStopProcess;

  @override
  NativePatchDelivery? get nativePatchDelivery {
    final packageName = _packageName;
    if (packageName == null) return null;
    return AndroidPatchDelivery(
      packageName: packageName,
      adb: adbPath,
      adbPrefix: _adbArgs(const []),
      run: _runProcess,
    );
  }

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

  /// The Android ABI this device runs apps as: `arm64-v8a`, `x86_64` or
  /// `armeabi-v7a`.
  ///
  /// The platform the app is built for, so that its engine, `libapp.so` and
  /// native libraries are the ones this device loads. Known once
  /// [resolveBuildArgs] has asked the device, or when the constructor was told.
  String get abi =>
      _abi ??
      (throw StateError(
        'The ABI of $name is not known yet: resolveBuildArgs() asks the device.',
      ));

  /// Asks the device its ABI, unless it was told.
  ///
  /// The first ABI in the device's preference order (`ro.product.cpu.abilist`)
  /// that rules_flutter builds for. An emulator on an x86_64 host lists
  /// `x86_64` first, though it can translate arm64 code, and a phone lists its
  /// own `arm64-v8a`; the first is the one the device runs natively.
  @override
  Future<void> resolveBuildArgs() async {
    if (_abi != null) return;
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'getprop', 'ro.product.cpu.abilist']),
    );
    if (result.exitCode != 0) {
      throw StateError(
        _adbFailure('shell getprop ro.product.cpu.abilist', result.stderr),
      );
    }
    _abi = androidAbiFromAbiList('${result.stdout}', deviceName: name);
  }

  @override
  List<String> get buildArgs => [
    '--@rules_android//flags:android_platforms=@rules_android//:$abi',
  ];

  @override
  LaunchBundleParts? get launchBundleParts => LaunchBundleParts(
    aspect: androidBundlePartsAspect,
    assetsGroup: androidBundlePartsOutputGroup,
    nativeLibsGroup: androidNativeLibsOutputGroup,
  );

  /// Build the common adb prefix args (includes -s <deviceId> if set).
  List<String> _adbArgs(List<String> args) {
    if (deviceId != null) return ['-s', deviceId!, ...args];
    return args;
  }

  /// What adb said, plus which device this asked it about.
  ///
  /// adb's own errors name neither the serial nor the flag that carried it, and
  /// some of them are *about* the serial — `unknown host service
  /// '<tail>:features'` is what it answers when the `-s` value has a colon in it
  /// and the server splits on that colon. A reader who cannot see the serial the
  /// tool used has nothing to compare against the one they would have typed.
  ///
  /// Omitted entirely when no device was named, because there is then no serial
  /// to doubt: adb chose, and its message says so.
  /// The time of the last record in the device's log, in the form `logcat -T`
  /// takes, or null when the log is empty (and so can be read whole).
  ///
  /// adb passes each argument on to the device's shell quoted, so the time,
  /// which has a space in it, goes as one argument as it is.
  Future<String?> _lastLogcatTimestamp() async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['logcat', '-v', 'time', '-t', '1']),
    );
    if (result.exitCode != 0) {
      throw StateError(_adbFailure('logcat -t 1', result.stderr));
    }
    return _logcatRecordTime.firstMatch('${result.stdout}')?.group(0);
  }

  static final _logcatRecordTime = RegExp(
    r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}',
    multiLine: true,
  );

  String _adbFailure(String what, Object? stderr) => deviceId == null
      ? 'adb $what failed: $stderr'
      : 'adb $what failed (adb -s $deviceId): $stderr';

  /// `am force-stop` [packageName], reporting rather than throwing when it
  /// fails or does not answer within [forceStopBound]. See [launch].
  ///
  /// Started rather than run, so that an `adb` that does not answer is killed
  /// at the bound: one left running holds the tool open after the run ends.
  Future<void> _forceStopBeforeLaunch(String packageName) async {
    String? failure;
    try {
      final stopped = await runProcessBounded(
        (exe, args, environment) => _injectedForceStopStart != null
            ? _injectedForceStopStart(exe, args)
            : startChildProcess(exe, args, environment: environment),
        adbPath,
        _adbArgs(['shell', 'am', 'force-stop', packageName]),
        environment: const {},
        bound: forceStopBound,
        what: 'adb shell am force-stop',
      );
      if (stopped.exitCode != 0) {
        failure = _adbFailure('am force-stop', '${stopped.stderr}'.trim());
      }
    } on HelperTimedOut catch (e) {
      failure = e.message;
    } on ProcessException catch (e) {
      failure = _adbFailure('am force-stop', e.message);
    }
    if (failure == null) return;
    _logger.warning({
      'message': 'android_force_stop_failed',
      'text':
          'Could not stop $packageName on $name before launching it '
          '($failure). Launching anyway: the install stops a running copy.',
      'device': name,
      'error': failure,
    });
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    final packageName = _packageName ?? await _readPackageName(appPath);

    // Step 0: Stop the app first, as `flutter run` does (flutter_tools'
    // `AndroidDevice.startApp`), and the way it does: within 30 s, and a stop
    // that fails or does not answer is reported and the launch goes on. The
    // install below stops a running copy of the app itself (the package
    // manager kills it on a package update), so nothing here depends on this
    // step, and a launch is not held up or ended by it.
    await _forceStopBeforeLaunch(packageName);

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
      throw StateError(_adbFailure('install', stderr));
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
    //
    // Read from the last record already in the log, not from wherever the log
    // has got to once logcat starts reading it (`-T 1`): the app is launched
    // straight after this, and a logcat slow to start (a busy host, a busy
    // adb) would miss the VM-service announcement and wait for it for good.
    // The device keeps its log, so every record after that one is read
    // whenever logcat gets to it. flutter_tools' AdbLogReader does the same.
    final since = await _lastLogcatTimestamp();
    final logcat = _launchLogcat = await _startProcess(
      adbPath,
      _adbArgs([
        'logcat',
        '-v',
        'time',
        if (since != null) ...['-T', since],
      ]),
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
    try {
      final instance = await _launchWithLogcat(packageName, logcat, logs);
      _launchLogcat = null;
      return instance;
    } catch (_) {
      // Nothing else holds this logcat: the [AppInstance] that [stop] would
      // end it through is never made.
      await _stopLaunchLogcat();
      await logs.close();
      rethrow;
    }
  }

  /// The rest of [launch], once its logcat is reading: start the activity,
  /// wait for its VM service and forward it.
  Future<AppInstance> _launchWithLogcat(
    String packageName,
    Process logcat,
    AppLogStream logs,
  ) async {
    // Step 3: Launch the activity. `-W` makes `am` wait for the launch to
    // complete and say how it went (`Status`, `LaunchState`), which is what
    // tells a process that started from one that never did. It is not awaited
    // here: it returns once the first frame is drawn, and an app started
    // paused (or a debug app on a busy host) announces its VM service well
    // before that, which is all the wait below is for.
    final activity = _activityName ?? '.MainActivity';
    final launched = _runProcess(
      adbPath,
      _adbArgs([
        'shell', 'am', 'start', '-W',
        // `--ez <key> <bool>` is an intent extra; the embedder reads
        // `start-paused` off the launch intent.
        if (startPaused) ...['--ez', 'start-paused', 'true'],
        '-n', '$packageName/$activity',
      ]),
    ).then(_readAmStart, onError: (Object e) => _AmStart.failed('$e'));

    // Step 4: Discover VM service URI from logcat — the announcement this
    // app's process made. logcat is the whole device's log, so another Flutter
    // app starting meanwhile announces its own there too. A release app
    // announces nothing, so there is nothing to wait for.
    final Uri? deviceUri;
    if (buildMode.servesVmService) {
      deviceUri = await _awaitVmService(logs, packageName, launched);
    } else {
      final result = await launched;
      if (result.failure case final failure?) {
        throw StateError(_adbFailure('am start', failure));
      }
      deviceUri = null;
    }

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

  /// Wait for the VM-service announcement of [packageName]'s process, for as
  /// long as that process is there to make one.
  ///
  /// Logcat does not end when the app does, so what bounds the wait is the app
  /// itself, asked every [_androidAppLivenessInterval] through `pidof`: a slow
  /// start (a first launch, a busy host) is not a failed one, and it says so
  /// every [_vmServiceSlowStartNotice] while it waits. The wait ends on the
  /// announcement, or with a [StateError] naming what became of the app:
  ///
  ///  * `am start -W` ([launched]) reported the launch failed, or that the app
  ///    was already running (so nothing will announce);
  ///  * the process had been started, which `am` reported or `pidof` saw, and
  ///    is gone — it crashed or exited, and the log's last lines are quoted.
  ///
  /// A process that has not been seen is not judged by a clock: `am` says
  /// whether the launch completed, and until it does the wait goes on.
  ///
  /// Null when logcat itself ends first: the device went away, or the run is
  /// being torn down.
  Future<Uri?> _awaitVmService(
    AppLogStream logs,
    String packageName,
    Future<_AmStart> launched,
  ) async {
    final gone = Completer<String>();
    var seen = false;
    var asking = false;
    var failing = false;
    unawaited(
      launched.then((result) {
        if (gone.isCompleted) return;
        final failure = result.failure;
        if (failure != null) {
          gone.complete(_adbFailure('am start', failure));
        } else if (result.newProcess) {
          seen = true;
        }
      }),
    );
    final liveness = Timer.periodic(_androidAppLivenessInterval, (_) async {
      if (gone.isCompleted || asking) return;
      asking = true;
      try {
        final running = (await _pidsOf(packageName)).isNotEmpty;
        failing = false;
        if (running) {
          seen = true;
        } else if (seen && !gone.isCompleted) {
          gone.complete(
            '$packageName exited before announcing a VM service on $name.',
          );
        }
      } on StateError catch (e) {
        // Liveness is unknown while adb will not answer, which is not the app
        // having died. Said once per spell of failure, not every poll.
        if (!failing) {
          _logger.warning({
            'message': 'android_liveness_check_failed',
            'text':
                'Cannot tell whether $packageName is still running on $name, '
                'so its VM service is waited for regardless: ${e.message}',
            'device': name,
          });
        }
        failing = true;
      } finally {
        asking = false;
      }
    });
    try {
      final uri = await discoverOwnVmServiceUri(
        logs,
        parse: parseLogcatAnnouncement,
        isOwnProcess: (pid) => _isProcessOf(packageName, pid),
        appGone: gone.future,
      );
      if (uri == null && gone.isCompleted) {
        throw StateError('${await gone.future} ${_deviceLogTail(logs)}');
      }
      return uri;
    } finally {
      liveness.cancel();
    }
  }

  /// The end of the device log, for a failure to quote.
  String _deviceLogTail(AppLogStream logs) {
    final tail = logs.read(-20).lines;
    return tail.isEmpty
        ? 'The device log had nothing in it.'
        : 'The end of the device log, which other apps write to as '
              'well:\n${tail.map((l) => '  ${l.text}').join('\n')}';
  }

  /// A process that announced its VM service and then died (an exception
  /// after the engine started, say) leaves a service address nothing answers,
  /// and the connection to it fails; this says the app is gone instead, with
  /// the log's last words. Null while the process is there.
  @override
  Future<String?> whyAppExited(AppInstance instance) async {
    final packageName = _packageName;
    if (packageName == null) return null;
    final List<int> pids;
    try {
      pids = await _pidsOf(packageName);
    } on StateError catch (e) {
      _logger.warning({
        'message': 'android_liveness_check_failed',
        'text':
            'Cannot tell whether $packageName is still running on $name: '
            '${e.message}',
        'device': name,
      });
      return null;
    }
    if (pids.isNotEmpty) return null;
    return '$packageName exited after announcing its VM service on $name. '
        '${_deviceLogTail(instance.logs)}';
  }

  /// The pids of [packageName]'s main process: none when it is not running.
  ///
  /// `pidof` names an app's processes by its package name, and a service
  /// declared `android:process=":x"` has another name.
  Future<List<int>> _pidsOf(String packageName) async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'pidof', packageName]),
    );
    // `pidof` exits 1, saying nothing, when no process has the name.
    final stderr = '${result.stderr}'.trim();
    if (result.exitCode != 0 && stderr.isNotEmpty) {
      throw StateError(_adbFailure('shell pidof $packageName', stderr));
    }
    return [
      for (final pid in '${result.stdout}'.trim().split(RegExp(r'\s+')))
        if (int.tryParse(pid) case final parsed?) parsed,
    ];
  }

  /// Whether [pid] is a running process of [packageName].
  ///
  /// Asked when an announcement arrives, so a process that made one is still
  /// there to be found.
  Future<bool> _isProcessOf(String packageName, int pid) async =>
      (await _pidsOf(packageName)).contains(pid);

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
    await _releaseApp();
    await _stopProcess('Android logcat', instance.process, teardownBound);
    await instance.logs.close();
  }

  /// A logcat started by a launch still in flight: the app, the forward and
  /// that logcat are all this run's to release.
  @override
  Future<void> abandonLaunch() async {
    await _releaseApp();
    await _stopLaunchLogcat();
  }

  /// Stop the logcat of a launch that has not returned, if there is one.
  Future<void> _stopLaunchLogcat() async {
    final logcat = _launchLogcat;
    _launchLogcat = null;
    if (logcat != null) {
      await _stopProcess('Android logcat', logcat, teardownBound);
    }
  }

  /// Stop the app and remove the forward this launch created.
  Future<void> _releaseApp() async {
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
  @override
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
  Future<void> captureScreen(
    AppInstance instance,
    String outputPath,
    Screen screen,
    ScreenshotDeadline deadline, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    if (_isEmulator) return _consoleScreenshot(outputPath);
    const remotePath = '/sdcard/flutter_screenshot.png';
    final giveUpAt = DateTime.now().add(screenshotBound);
    Future<ProcessResult> step(List<String> args, String what) =>
        runProcessBounded(
          _startScreenshotProcess,
          adbPath,
          _adbArgs(args),
          environment: const {},
          bound: giveUpAt.difference(DateTime.now()),
          what: what,
        );

    final capResult = await step([
      'shell',
      'screencap',
      '-p',
      remotePath,
    ], 'adb screencap');
    if (capResult.exitCode != 0) {
      throw StateError(_adbFailure('screencap', capResult.stderr));
    }
    final pullResult = await step(['pull', remotePath, outputPath], 'adb pull');
    if (pullResult.exitCode != 0) {
      throw StateError(_adbFailure('pull', pullResult.stderr));
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
      : startChildProcess(exe, args, environment: environment);
}

/// Where a wired iOS launch finds iproxy, and the environment it runs it with.
typedef IproxyLocator =
    ({String executable, Map<String, String> environment}) Function();

/// The iproxy the dev tool carries, located when a launch needs it.
({String executable, Map<String, String> environment}) _carriedIproxy() {
  final executable = iproxyTool().require();
  return (executable: executable, environment: iproxyEnvironment(executable));
}

/// How an iOS device launch found the app's VM service.
sealed class _FoundVmService {}

/// From the app's own announcement on its console: the device-side address.
final class _LoggedVmService extends _FoundVmService {
  final Uri uri;
  _LoggedVmService(this.uri);
}

/// From the app's mDNS advertisement.
final class _AdvertisedVmService extends _FoundVmService {
  final MdnsVmServiceRecord record;
  _AdvertisedVmService(this.record);
}

/// One attempt to reach a local TCP listener: completes when it accepts,
/// throws when it does not. The seam [waitForLocalTcpPort] takes so a test can
/// answer without a socket.
typedef TcpProbe = Future<void> Function(int port);

Future<void> _connectToLocalPort(int port) async {
  final probe = await Socket.connect(
    '127.0.0.1',
    port,
    timeout: const Duration(seconds: 1),
  );
  probe.destroy();
}

/// Wait until a local TCP listener on 127.0.0.1:[port] accepts connections.
///
/// Port forwarders (iproxy, adb forward) bind their local listener
/// asynchronously after `Process.start` returns; dialing the forward before
/// it is bound gets ECONNREFUSED. Calls [probe] (a real connect that destroys
/// its socket, by default) with exponential backoff. Throws [StateError]
/// naming [what] if the listener never accepts within [budget].
///
/// The budget is read from the ambient `package:clock` and the backoff is the
/// zone's timer, so a test under `fakeAsync` drives the whole wait with
/// `elapse`.
Future<void> waitForLocalTcpPort(
  int port, {
  required String what,
  Duration budget = const Duration(seconds: 10),
  TcpProbe probe = _connectToLocalPort,
}) async {
  final deadline = clock.now().add(budget);
  var delay = const Duration(milliseconds: 50);
  while (true) {
    try {
      await probe(port);
      return;
    } catch (e) {
      if (clock.now().isAfter(deadline)) {
        // The last attempt's own words: a refusal, a firewall and a wrong
        // address all read as "did not accept connections".
        throw StateError(
          '$what on 127.0.0.1:$port did not accept connections within '
          '${budget.inSeconds}s of starting. The last attempt failed with: $e',
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

  /// The process that logged the record.
  final int pid;
  final String message;

  /// The record without its timestamp — what gets shown.
  final String display;

  const LogcatLine({
    required this.level,
    required this.tag,
    required this.pid,
    required this.message,
    required this.display,
  });
}

const _logcatTimestamp = r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\s+';
const _logcatRecord = r'([VDIWEF])/(.*?)\(\s*(\d+)\):\s?(.*)$';
final _logcatTimestampPrefix = RegExp(_logcatTimestamp);
final _logcatTimeFormat = RegExp('$_logcatTimestamp$_logcatRecord');

/// A record as [LogcatLine.display] shows it: no timestamp.
final _logcatDisplayFormat = RegExp('^$_logcatRecord');

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
  return LogcatLine(
    level: match.group(1)!,
    tag: match.group(2)!.trim(),
    pid: int.parse(match.group(3)!),
    message: match.group(4)!,
    display: rawLine.replaceFirst(_logcatTimestampPrefix, ''),
  );
}

/// The VM-service announcement in a logcat record as [androidLogFilter] passes
/// it on (`I/flutter ( 1234): The Dart VM service is listening on ...`), with
/// the pid that logged it; null for any other line.
VmServiceAnnouncement? parseLogcatAnnouncement(String displayLine) {
  final record = _logcatDisplayFormat.firstMatch(displayLine);
  if (record == null) return null;
  final match = vmServiceUriPattern.firstMatch(record.group(4)!);
  if (match == null) return null;
  return (pid: int.parse(record.group(3)!), uri: Uri.parse(match.group(1)!));
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

/// How often an Android launch asks, while awaiting the VM service, whether
/// the app's process is still there.
const _androidAppLivenessInterval = Duration(seconds: 2);

/// What `am start -W` reported of a launch.
class _AmStart {
  /// Why the launch failed, or null when it did not.
  final String? failure;

  /// Whether the launch created the app's process (`LaunchState: COLD`, or an
  /// `ok` status from an `am` that names no state).
  final bool newProcess;

  const _AmStart({this.newProcess = false}) : failure = null;

  const _AmStart.failed(String this.failure) : newProcess = false;
}

/// Reads the output of `am start -W`.
///
/// `Status: ok` says the activity launched, and `LaunchState` how: `COLD` is a
/// new process, the only kind whose VM service has not been announced already.
/// `WARM` and `HOT` found the app running, so no announcement can follow and
/// waiting for one would never end. Any other `Status` (`canceled`, `error`)
/// and any `Error:` line is a launch that failed, said in `am`'s words. `Status:
/// timeout` is `am` giving up on the first frame, which a loaded host causes
/// and which says nothing about whether a process exists, so it is no verdict.
/// Output with no `Status` line (an `am` older than the flag) is none either.
///
/// Read off a Pixel: a healthy cold start prints `Status: ok` and `LaunchState:
/// COLD`; an app that threw in `onCreate` prints `Status: ok` and `LaunchState:
/// UNKNOWN (0)` (the activity launched, and the process died before `am` could
/// say how); an app that held the main thread past `am`'s ten seconds prints
/// `Status: timeout` and `LaunchState: UNKNOWN (-1)`, its process alive. So an
/// `ok` status of any state but `WARM` and `HOT` is a process that was
/// started, alive or not, and the liveness check tells which.
_AmStart _readAmStart(ProcessResult result) {
  final output = '${result.stdout}${result.stderr}'.trim();
  if (result.exitCode != 0) {
    return _AmStart.failed(output.isEmpty ? 'exit ${result.exitCode}' : output);
  }
  String? field(String name) => RegExp(
    '^$name:\\s*(.*)\$',
    multiLine: true,
  ).firstMatch(output)?.group(1)?.trim();
  final errors = [
    for (final line in output.split('\n'))
      if (line.startsWith('Error')) line.trim(),
  ];
  if (errors.isNotEmpty) return _AmStart.failed(errors.join(' '));
  final status = field('Status');
  if (status == null || status == 'timeout') return const _AmStart();
  if (status != 'ok') return _AmStart.failed('Status: $status\n$output');
  final state = field('LaunchState');
  if (state == 'WARM' || state == 'HOT') {
    return _AmStart.failed(
      'the app was already running (LaunchState: $state), so its VM service '
      'was announced before this launch and nothing will announce it again',
    );
  }
  return const _AmStart(newProcess: true);
}

/// How often a launch that is still waiting for the VM-service announcement
/// says so.
const _vmServiceSlowStartNotice = Duration(seconds: 30);

/// How often a launched simulator app's process is checked for being alive
/// while its VM service is awaited.
const _simulatorAppLivenessInterval = Duration(seconds: 2);

/// Watch [logs] for the VM-service announcement.
///
/// The Flutter engine prints a line like:
///   "The Dart VM service is listening on http://127.0.0.1:XXXXX/..."
///
/// Only for a log the app's own process writes and nothing else does: its
/// stdout and stderr. A log other processes write to as well needs
/// [discoverOwnVmServiceUri], or another app's announcement is taken for this
/// one's.
///
/// This is a pure *reader*: it owns only its own subscription to [logs] and
/// cancels only that, leaving whatever feeds the stream running for the app's
/// lifetime. Cancelling the app's own stdout/stderr subscriptions here would
/// kill all subsequent output and leave the OS pipes unread — see the library
/// docs.
///
/// There is no deadline: a slow start (a loaded host, a first launch) is not a
/// failed one. The wait ends on the announcement, when the stream ends (the
/// app's process exited, closing its stdout and stderr), or when the run is
/// torn down and closes the stream. After each [_vmServiceSlowStartNotice]
/// without one it logs that it is still waiting. Returns null if the stream
/// ended first.
Future<Uri?> discoverVmServiceUri(AppLogStream logs) =>
    _watchForVmService(logs, null, null, (line) {
      final match = vmServiceUriPattern.firstMatch(line);
      return match == null ? null : Uri.parse(match.group(1)!);
    });

/// A VM-service announcement read off a log several processes write to, with
/// the process that made it.
typedef VmServiceAnnouncement = ({int pid, Uri uri});

/// Watch [logs], which other processes write to as well, for the VM-service
/// announcement made by this launch's own app.
///
/// [parse] reads an announcement and the pid that made it out of one line, or
/// returns null for any other line. [isOwnProcess] says whether a pid is this
/// launch's app. An announcement from any other process is passed over: on a
/// shared simulator or device, another Flutter app starting while this one
/// launches announces its VM service on the same log, and taking it attaches
/// this session to that app.
///
/// Lines are checked in the order they arrive, one at a time, so an
/// announcement is never chosen over an earlier one of this app's.
///
/// Waits for the announcement, the stream ending, [appGone] completing (the
/// app exited; the caller knows how to tell), or [timeout] if one is given.
/// With no [timeout] there is no deadline, and the wait says every
/// [_vmServiceSlowStartNotice] that it is still going. Returns null when the
/// wait ended any other way than an announcement.
Future<Uri?> discoverOwnVmServiceUri(
  AppLogStream logs, {
  required VmServiceAnnouncement? Function(String line) parse,
  required Future<bool> Function(int pid) isOwnProcess,
  Duration? timeout,
  Future<void>? appGone,
}) => _watchForVmService(logs, timeout, appGone, (line) async {
  final announcement = parse(line);
  if (announcement == null) return null;
  return await isOwnProcess(announcement.pid) ? announcement.uri : null;
});

/// The URI [accept] takes from the first line it accepts, read off [logs] in
/// order; null on [timeout] (when given), when [appGone] completes, or when the
/// stream ends first.
Future<Uri?> _watchForVmService(
  AppLogStream logs,
  Duration? timeout,
  Future<void>? appGone,
  FutureOr<Uri?> Function(String line) accept,
) async {
  final completer = Completer<Uri?>();
  final timer = timeout == null
      ? null
      : Timer(timeout, () {
          if (!completer.isCompleted) completer.complete(null);
        });
  final sinceLaunch = Stopwatch()..start();
  final notice = timeout != null
      ? null
      : Timer.periodic(_vmServiceSlowStartNotice, (_) {
          _logger.warning({
            'message': 'vm_service_slow_to_announce',
            'text':
                'The app has not announced its VM service '
                '${sinceLaunch.elapsed.inSeconds}s after launch; still waiting.',
            'elapsedMs': sinceLaunch.elapsedMilliseconds,
          });
        });
  unawaited(
    appGone?.then((_) {
      if (!completer.isCompleted) completer.complete(null);
    }),
  );

  // Each line waits for the one before it, so an asynchronous [accept] cannot
  // let a later line win.
  var checked = Future<void>.value();
  final sub = logs.lines.listen(
    (line) {
      checked = checked
          .then((_) async {
            if (completer.isCompleted) return;
            final uri = await accept(line.text);
            if (uri != null && !completer.isCompleted) completer.complete(uri);
          })
          .catchError((Object error, StackTrace stack) {
            if (!completer.isCompleted) completer.completeError(error, stack);
          });
    },
    onDone: () {
      checked.then((_) {
        if (!completer.isCompleted) completer.complete(null);
      });
    },
  );

  try {
    return await completer.future;
  } finally {
    timer?.cancel();
    notice?.cancel();
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
  logs.own(pump);
  return logs;
}

/// How long a connection failure waits for an exit it may be the first sign of.
///
/// A process that dies right after announcing its VM service refuses the
/// connection a moment before the operating system reports the exit to this
/// tool, so asking "has it exited" at that instant can say no to a process that
/// is already dead. The wait ends the moment the exit arrives; only a process
/// that is really running spends all of it, on a launch that is failing anyway.
const _exitReportSettle = Duration(seconds: 2);

/// [process]'s exit code if it exits within [bound], else null.
Future<int?> _exitCodeWithin(Process process, Duration bound) {
  final result = Completer<int?>();
  final timer = Timer(bound, () {
    if (!result.isCompleted) result.complete(null);
  });
  process.exitCode.then((code) {
    timer.cancel();
    if (!result.isCompleted) result.complete(code);
  });
  return result.future;
}

/// Why a desktop app's VM service is unreachable when the app is the process
/// this tool started and that process is gone: its exit, and its last output.
/// Null while it runs.
///
/// A native desktop app has no state beyond its process, and the exit status
/// the operating system reported for the child is the platform's own word on
/// whether it is still there. [posix] says a negative code is a signal's
/// number, which is what `dart:io` reports for a child killed by one.
Future<String?> _desktopAppExit(
  String name,
  AppInstance instance, {
  required bool posix,
}) async {
  final code = await _exitCodeWithin(instance.process, _exitReportSettle);
  if (code == null) return null;
  final how = posix && code < 0
      ? 'was killed by signal ${-code}'
      : 'exited with code $code';
  return 'The $name app $how after announcing its VM service. '
      '${_browserLastWords(instance.logs)}';
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

/// Reads the bundle identifier out of an extracted .app's Info.plist.
Future<String> _extractBundleId(
  String appPath,
  ProcessRunSync runProcess,
) async {
  final result = await runProcess('defaults', [
    'read',
    '$appPath/Info.plist',
    'CFBundleIdentifier',
  ]);
  if (result.exitCode == 0) {
    return (result.stdout as String).trim();
  }
  throw StateError('Could not extract bundle ID from $appPath');
}

/// Extracts the .app directory from an .ipa archive, ready to install on an
/// iOS simulator or device.
///
/// Returns the directory alongside the bundle so the caller can hold it for
/// exactly as long as the launch needs it — see [AppInstance.scratchDirs].
Future<({String appPath, Directory dir})> _extractAppFromIpa(
  String ipaPath,
  ProcessRunSync runProcess,
) async {
  final tempDir = await createTempDir('flutter_ipa_');
  try {
    final result = await runProcess('unzip', [
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
    // Bazel writes every archived file with the same fixed 1980 mtime, and
    // both `simctl install` and `devicectl device install app` keep an
    // installed file whose size and mtime both match the new one. A rebuilt
    // native library or AOT App.framework that kept its size would install as
    // the old machine code, so stamp everything now.
    final now = DateTime.now();
    await for (final entity in tempDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) await entity.setLastModified(now);
    }
    return (appPath: apps.first.path, dir: tempDir);
  } catch (_) {
    // Nothing usable came out of the archive; the half-unpacked copy is only
    // going to sit there.
    await deleteTempDir(tempDir);
    rethrow;
  }
}

/// iOS Simulator device (via xcrun simctl).
class IOSSimulatorDevice extends Device {
  /// The simulator every `simctl` command of this device addresses.
  String get udid => _udid;
  final String _udid;

  final String? _bundleId;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  /// The bundle the last launch started — [_bundleId] when one was named,
  /// otherwise the one read out of the app's Info.plist.
  ///
  /// [stop] terminates this. Reading [_bundleId] there instead skipped the
  /// terminate for the usual device, which names none, and the app outlived
  /// the run.
  String? _launchedBundleId;

  /// The process `simctl launch` started, which is what the simulator's
  /// liveness is asked of.
  int? _launchedPid;

  /// The simulator's records of how the last launch's app processes ended.
  SimulatorTerminations? _terminations;

  /// How long [howAppExited] waits for the simulator's record of an app's end
  /// once the tool lost it, before asking whether the process is there at all.
  /// The record is logged as the process goes; this bounds the wait for one
  /// when the app has not gone. Settable so tests do not wait it out.
  Duration terminationRecordBound = _exitReportSettle;

  /// How long [howAppExited] waits for the record of a process known to be
  /// gone. RunningBoard logs every app's end, but a host under load delivers
  /// the log late: seconds, where the process check answers at once. Settable
  /// so tests do not wait it out.
  Duration goneRecordBound = const Duration(seconds: 30);

  IOSSimulatorDevice({
    required String udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) : _udid = udid,
       _bundleId = bundleId,
       _runProcess = runProcess ?? Process.run,
       _startProcess = startProcess ?? startChildProcess;

  /// Create a device targeting the first booted simulator.
  factory IOSSimulatorDevice.booted({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) {
    final run = runProcess ?? Process.run;
    return _IOSSimulatorDeviceBooted(
      runProcess: run,
      startProcess: startProcess ?? startChildProcess,
    );
  }

  @override
  NativePatchDelivery? get nativePatchDelivery =>
      IOSSimulatorPatchDelivery(run: _runProcess);

  @override
  LaunchBundleParts? get launchBundleParts => const LaunchBundleParts(
    aspect: iosBundlePartsAspect,
    assetsGroup: iosBundlePartsOutputGroup,
    nativeLibsGroup: iosNativeLibsOutputGroup,
  );

  @override
  String get name => 'iOS Simulator ($udid)';

  @override
  List<String> get buildArgs => const ['--ios_multi_cpus=sim_arm64'];

  final _scratch = _LaunchScratch();

  /// The `log stream` helpers a launch in flight has started, until the launch
  /// hands them to its [AppInstance].
  final _launchHelpers = <Process>[];

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    try {
      return await _launch(appPath, onLog: onLog);
    } catch (_) {
      await _releaseLaunch();
      rethrow;
    }
  }

  @override
  Future<void> abandonLaunch() => _releaseLaunch();

  /// Undo a launch that did not return: its log helpers and its unpacked app.
  /// `simctl install` copies the app, so nothing runs out of the unpacked one.
  Future<void> _releaseLaunch() async {
    final helpers = [..._launchHelpers];
    _launchHelpers.clear();
    await Future.wait(
      helpers.map((h) => _stopProcess('iOS Simulator log', h, teardownBound)),
    );
    await _scratch.release();
  }

  Future<Process> _startHelper(String executable, List<String> args) async {
    final process = await _startProcess(executable, args);
    _launchHelpers.add(process);
    return process;
  }

  /// A `log stream` of the simulator's records matching [predicate], in
  /// [style], that also admits [marker] (see simulator_log_stream.dart).
  Future<SimulatorLogStream> _startLogStream(
    String style,
    String predicate,
    String marker,
  ) async {
    final helper = await _startHelper('xcrun', [
      'simctl',
      'spawn',
      udid,
      'log',
      'stream',
      '--style',
      style,
      '--predicate',
      listeningPredicate(predicate, marker),
    ]);
    return SimulatorLogStream(
      helper,
      marker: marker,
      messageOf: style == 'ndjson'
          ? ndjsonEventMessage
          : parseUnifiedLoggingLine,
    );
  }

  Future<AppInstance> _launch(String appPath, {AppLogListener? onLog}) async {
    // Extract .app from .ipa if needed — simctl install requires .app.
    String installPath = appPath;
    if (appPath.endsWith('.ipa')) {
      final extracted = await _extractAppFromIpa(appPath, _runProcess);
      installPath = extracted.appPath;
      _scratch.hold(extracted.dir);
    }

    // Boot it if it is not booted, and wait for the boot to finish: `install`
    // on a device that is still booting fails, and so does everything after
    // it. `bootstatus -b` is one command for both, blocks on the boot rather
    // than a clock, and exits nonzero when the boot fails, which is then the
    // launch's failure and says so.
    final boot = await _runProcess('xcrun', [
      'simctl',
      'bootstatus',
      udid,
      '-b',
    ]);
    if (boot.exitCode != 0) {
      throw StateError(
        'Booting the iOS Simulator $udid failed (simctl bootstatus -b exited '
        '${boot.exitCode}): ${'${boot.stderr}'.trim()}${'${boot.stdout}'.trim()}',
      );
    }

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

    // Three log streams, deliberately.
    //
    // Discovery matches on message content and nothing else. App output needs
    // a process-scoped predicate with several NOT(...) noise filters
    // ([iosSimulatorLogPredicate]). Folding the two together would make
    // VM-service discovery — which hot reload, screenshots and agent control
    // all depend on — contingent on those exclusion clauses continuing to
    // spare the announcement. Two narrow streams fail independently and
    // visibly; one broad stream fails silently. The third is for how the app
    // ends: the simulator's record of it is what tells a close from a crash
    // (see simulator_terminations.dart).
    //
    // The discovery stream is the whole simulator's, so every Flutter app on
    // it announces there. ndjson puts each record's pid on the record's own
    // line, which is how discovery keeps to the pid `simctl launch` reports.
    //
    // Each also admits a marker this launch logs, and the app is launched only
    // once every stream has delivered it: a stream not yet listening when the
    // app announces its VM service never sees the announcement, and the run
    // would wait for good. See simulator_log_stream.dart.
    final marker = newListeningMarker();
    final discovery = await _startLogStream(
      'ndjson',
      'eventMessage contains "Observatory" or eventMessage contains "Dart VM service"',
      marker,
    );
    final discoveryLog = discovery.process;

    final appName = p.basename(installPath).replaceAll('.app', '');
    final output = await _startLogStream(
      'json',
      iosSimulatorLogPredicate(appName),
      marker,
    );
    final outputLog = output.process;

    // Unified logging carries no stdout/stderr split, so nothing is flagged as
    // an error channel here.
    final logs = _startProcessLogs(
      outputLog,
      onLog,
      stderrIsError: false,
      transform: parseUnifiedLoggingLine,
    );

    final bundleId = _launchedBundleId =
        _bundleId ?? await _extractBundleId(installPath, _runProcess);

    final termination = await _startLogStream(
      'ndjson',
      simulatorTerminationPredicate(bundleId),
      marker,
    );
    final terminationLog = termination.process;
    _terminations = SimulatorTerminations(
      terminationLog.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
    terminationLog.stderr.drain<void>().ignore();

    await waitUntilListening([discovery, output, termination], () async {
      final logged = await _runProcess('xcrun', [
        'simctl',
        'spawn',
        udid,
        'syslog',
        '-s',
        '-l',
        'notice',
        marker,
      ]);
      if (logged.exitCode != 0) {
        throw StateError(
          'Could not log a message on the iOS Simulator $udid to tell when '
          'its log streams are listening (syslog exited ${logged.exitCode}): '
          '${'${logged.stderr}'.trim()}',
        );
      }
    });

    // Launch app.
    final launchResult = await _runProcess('xcrun', [
      'simctl', 'launch', udid, bundleId,
      // Anything after the bundle id is passed to the app as argv, which is
      // where the iOS embedder looks for engine switches.
      if (startPaused) '--start-paused',
    ]);
    if (launchResult.exitCode != 0) {
      throw StateError(
        'simctl launch $bundleId failed: ${launchResult.stderr}',
      );
    }
    final pid = simctlLaunchedPid('${launchResult.stdout}', bundleId);
    if (pid == null) {
      throw StateError(
        'simctl launch $bundleId did not say which process it started, so '
        "this app's VM service cannot be told apart from another app's. It "
        'printed: "${'${launchResult.stdout}'.trim()}"',
      );
    }

    _launchedPid = pid;

    // Waits for the app, not a clock: a first launch after a boot, or a host
    // busy with a build, is slow, not failed. It ends on the announcement, on
    // the app's process going away, or on the run's teardown killing the helper.
    final exited = Completer<void>();
    final liveness = Timer.periodic(_simulatorAppLivenessInterval, (_) async {
      if (exited.isCompleted) return;
      final alive = await _runProcess('kill', ['-0', '$pid']);
      if (alive.exitCode != 0 && !exited.isCompleted) exited.complete();
    });
    final Uri? uri;
    try {
      uri = await discoverVmServiceUriFromProcess(
        discoveryLog,
        parse: parseUnifiedLoggingAnnouncement,
        isOwnProcess: (announcer) async => announcer == pid,
        appGone: exited.future,
      );
    } finally {
      liveness.cancel();
    }
    if (uri == null && exited.isCompleted) {
      throw StateError(
        '$bundleId (pid $pid) exited before announcing a VM service on '
        'the iOS Simulator $udid. ${_browserLastWords(logs, silence: 'It printed nothing.')}',
      );
    }

    _launchHelpers.clear();
    return AppInstance(
      process: discoveryLog,
      vmServiceUri: uri,
      logs: logs,
      auxiliaryProcesses: [outputLog, terminationLog],
      scratchDirs: _scratch.handOver(),
    );
  }

  /// An app that announced its VM service and then died (an exception once the
  /// engine was up, say) leaves an address nothing answers; this says the app
  /// is gone instead, with the end of its log. Null while the process is there.
  @override
  Future<String?> whyAppExited(AppInstance instance) async =>
      (await howAppExited(instance))?.account;

  /// The simulator's record of the app's end says how it went, and whether it
  /// was closed or crashed.
  ///
  /// Without a record within [terminationRecordBound], the process is asked
  /// after directly: the simulator's processes are the host's, so signal 0 to
  /// the pid `simctl launch` named is the platform's own test for it. Only "No
  /// such process" is a verdict, and then the record is waited for again, up
  /// to [goneRecordBound]; with none, the app is taken to have crashed, since
  /// nothing recorded a close. A refusal (EPERM) says the check could not be
  /// made.
  @override
  Future<AppExit?> howAppExited(AppInstance instance) async {
    final pid = _launchedPid;
    final bundleId = _launchedBundleId;
    if (pid == null || bundleId == null) return null;
    Future<SimulatorTermination?> record(Duration bound) async =>
        await _terminations
            ?.of(pid)
            .then<SimulatorTermination?>((t) => t)
            .timeout(bound, onTimeout: () => null);
    AppExit told(SimulatorTermination ended) {
      final account = '$bundleId (pid $pid) ${ended.how} on $name.';
      return ended.closed
          ? AppExit.closed(account)
          : AppExit.crashed(
              '$account ${_browserLastWords(instance.logs, silence: 'It printed nothing.')}',
            );
    }

    final ended = await record(terminationRecordBound);
    if (ended != null) return told(ended);
    final alive = await _runProcess('kill', ['-0', '$pid']);
    if (alive.exitCode == 0) return null;
    if ('${alive.stderr}'.contains('No such process')) {
      final late = await record(goneRecordBound);
      if (late != null) return told(late);
    }
    if (!'${alive.stderr}'.contains('No such process')) {
      _logger.warning({
        'message': 'ios_simulator_liveness_check_failed',
        'text':
            'Cannot tell whether $bundleId (pid $pid) is still running on '
            '$name: kill -0 said "${'${alive.stderr}'.trim()}".',
        'device': name,
        'pid': pid,
      });
      return null;
    }
    return AppExit.crashed(
      '$bundleId (pid $pid) exited after announcing its VM service on '
      '$name, and the simulator recorded no termination for it. '
      '${_browserLastWords(instance.logs, silence: 'It printed nothing.')}',
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    // Read into a local rather than null-asserting the field: whether the
    // field promotes across the check depends on the language version the
    // analyzer is given, and a local is what every version accepts.
    final bundleId = _launchedBundleId ?? _bundleId;
    if (bundleId != null) {
      await _runProcess('xcrun', ['simctl', 'terminate', udid, bundleId]);
    }
    await _stopProcess('iOS Simulator app', instance.process, teardownBound);
    await instance.disposeAuxiliaryProcesses(teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  late final _devicectl = DevicectlScreens(
    run: _runProcess,
    device: () => udid,
    deviceName: () => name,
    isSimulator: true,
  );

  /// The simulator's displays: one, or on an iPhone Duo two built-in ones, of
  /// which the app is drawing on the one the posture turns on.
  @override
  Future<List<Screen>> screens({ScreenshotDeadline? deadline}) =>
      _devicectl.list(deadline ?? ScreenshotDeadline(screenshotBound));

  /// iOS Simulator is captured with `devicectl device capture screenshot`
  /// because `_flutter.screenshot` returns "Could not capture image
  /// screenshot" on the Simulator rendering pipeline, and `simctl io
  /// screenshot` cannot choose between a multi-screen simulator's displays.
  /// Waits for the first frame via VM service first.
  @override
  Future<void> prepareScreenshot(VmServiceClient? vmClient) async {
    if (vmClient != null) {
      await vmClient.waitForFirstFrame();
    }
  }

  @override
  Future<void> captureScreen(
    AppInstance instance,
    String outputPath,
    Screen screen,
    ScreenshotDeadline deadline, {
    VmServiceClient? vmClient,
    String? window,
  }) => _devicectl.capture(screen, outputPath, deadline);
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

  /// The simulator this run launched on, once it has; `booted` before.
  ///
  /// A getter every `simctl` command reads, rather than a device made for the
  /// launch alone: `simctl`'s own `booted` means whichever booted simulator it
  /// finds first, so with two booted a screenshot or a stop addressed that way
  /// reached a different simulator from the one the app was running on —
  /// measured, a screenshot of another app on a booted iPad.
  @override
  String get udid => _resolvedUdid ?? super.udid;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    await _resolveBootedUdid();
    return super.launch(appPath, onLog: onLog);
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
  /// one first, but `lldb device select` and `iproxy -u` go through usbmuxd,
  /// which has never heard of it —
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

  /// Its iOS version and build, `27.2 24B119`, when `devicectl` reports it.
  final String? osVersion;

  IOSDeviceInfo({
    required this.udid,
    required this.coreDeviceId,
    required this.name,
    required this.transport,
    required this.hostnames,
    this.osVersion,
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
        osVersion: switch ((
          properties['osVersionNumber'],
          properties['osBuildUpdate'],
        )) {
          (final String version, final String build) => '$version $build',
          (final String version, _) => version,
          _ => null,
        },
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

  /// Starts every launch helper. The environment is added to this process's
  /// own, which is how the caller's `DEVICECTL_CHILD_*` variables still reach
  /// `devicectl` alongside the one the launch sets.
  final ProcessStarterWithEnvironment _startProcess;
  final MdnsVmServiceDiscovery _mdns;
  final TcpProbe _forwardProbe;
  final IproxyLocator _locateIproxy;

  /// Filled in by the first [_resolveInfo].
  IOSDeviceInfo? _info;

  /// iproxy process for port forwarding (killed on stop).
  Process? _iproxyProcess;

  /// devicectl --console process for stdout capture (killed on stop).
  Process? _consoleLauncherProcess;

  /// lldb process for debugger attachment (killed on stop).
  Process? _lldbProcess;

  /// The launched app's pid on the device, once the launch has found it.
  ///
  /// Killing lldb does not end the app on a physical device — debugserver
  /// detaches and the app keeps running — so this is what [stop] terminates.
  int? _appPid;

  /// The installed bundle's `installationURL`, which names the app's process
  /// in the device's process list.
  String? _installationUrl;

  /// What the current launch's lldb does with a stop, once the app runs.
  _LldbStops? _lldbStops;

  /// Set by [abandonLaunch]: the launch in flight must start nothing more.
  bool _launchAbandoned = false;

  /// How long a launch looks for the VM service, over a cable and over the
  /// network. A backstop for a launch that will never succeed, not an
  /// estimate: see [applyTimeout] for why a debug launch here is this slow.
  /// Settable so a test can drive the expiry.
  Duration wiredVmServiceBudget = const Duration(minutes: 5);
  Duration wirelessVmServiceBudget = const Duration(minutes: 15);

  IOSDevice({
    String? udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarterWithEnvironment? startProcess,
    MdnsVmServiceDiscovery? mdns,

    /// How a wired launch checks that the iproxy forward accepts connections;
    /// a real connect by default.
    TcpProbe? forwardProbe,

    /// Where a wired launch's iproxy is, and its environment; the one the dev
    /// tool carries by default.
    IproxyLocator? locateIproxy,
  }) : requestedUdid = udid,
       _bundleId = bundleId,
       _runProcess = runProcess ?? Process.run,
       _startProcess =
           startProcess ??
           ((exe, args, env) => startChildProcess(exe, args, environment: env)),
       _mdns = mdns ?? MdnsVmServiceDiscovery(),
       _forwardProbe = forwardProbe ?? _connectToLocalPort,
       _locateIproxy = locateIproxy ?? _carriedIproxy;

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

  /// The bundle and the installed `.app` of the last launch, which a patch is
  /// signed and addressed by.
  String? _launchedBundleId;
  String? _launchedAppPath;

  @override
  NativePatchDelivery? get nativePatchDelivery {
    final bundleId = _launchedBundleId;
    final appPath = _launchedAppPath;
    final resolved = udid;
    if (bundleId == null || appPath == null || resolved == null) return null;
    return IOSDevicePatchDelivery(
      udid: resolved,
      bundleId: bundleId,
      appPath: appPath,
      run: _runProcess,
    );
  }

  @override
  LaunchBundleParts? get launchBundleParts => const LaunchBundleParts(
    aspect: iosBundlePartsAspect,
    assetsGroup: iosBundlePartsOutputGroup,
    nativeLibsGroup: iosNativeLibsOutputGroup,
  );

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
      // Only a debug app is run under the debugger.
      if (buildMode == BuildMode.debug) lldbTool(),
      // Only a cabled device is reached through a port forward; a wireless one
      // is dialed at its own address, so demanding iproxy there would refuse a
      // run that works. A release app has no VM service to forward to. `xcrun`
      // is not listed: it is part of macOS, and a missing or misconfigured
      // Xcode is already reported by [_resolveInfo], with devicectl's own
      // explanation attached.
      if (info.transport == IOSDeviceTransport.wired &&
          buildMode != BuildMode.release)
        iproxyTool(),
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
    } on MdnsDiscoveryException catch (e) {
      // A launch failure like any other, so the launcher reports it: its own
      // type escaped as an unhandled exception and took the tool down.
      await _abandonLaunch();
      throw StateError(e.message);
    } catch (_) {
      await _abandonLaunch();
      rethrow;
    }
  }

  @override
  Future<void> abandonLaunch() async {
    _launchAbandoned = true;
    await _abandonLaunch();
  }

  void _throwIfAbandoned() {
    if (_launchAbandoned) {
      throw StateError(
        'The launch on $name was abandoned because the run is ending.',
      );
    }
  }

  /// Start a launch helper, unless the launch has been abandoned; one started
  /// just as it was abandoned is killed rather than left to outlive the run.
  Future<Process> _startHelper(
    String executable,
    List<String> args, {
    Map<String, String> environment = const {},
  }) async {
    _throwIfAbandoned();
    final process = await _startProcess(executable, args, environment);
    if (_launchAbandoned) {
      process.kill(ProcessSignal.sigkill);
      _throwIfAbandoned();
    }
    return process;
  }

  /// Undo a launch that did not complete: every helper it started, then the
  /// app it may have resumed.
  Future<void> _abandonLaunch() async {
    _lldbStops?.stopping = true;
    // Helpers first: see [_terminateApp] for why the debugger must be gone.
    await _reapLaunchHelpers();
    await _terminateApp();
    // `devicectl install` copies the app, so nothing runs out of this.
    await _scratch.release();
  }

  final _scratch = _LaunchScratch();

  Future<AppInstance> _launchAndAttach(
    String appPath, {
    AppLogListener? onLog,
  }) async {
    _launchAbandoned = false;
    final info = await _resolveInfo();

    // Extract .app from .ipa if needed — devicectl install requires .app.
    String installPath = appPath;
    if (appPath.endsWith('.ipa')) {
      final extracted = await _extractAppFromIpa(appPath, _runProcess);
      installPath = extracted.appPath;
      _scratch.hold(extracted.dir);
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
    final bundleId =
        _bundleId ?? await _extractBundleId(installPath, _runProcess);
    _launchedBundleId = bundleId;
    _launchedAppPath = installPath;
    _installationUrl = installationUrl;

    // An iOS debug app needs a debugger (ptrace) attached before the Flutter
    // engine will start, because its JIT has to be given executable pages.
    // An AOT app needs none, and flutter_tools attaches one only in debug
    // (`shouldAttachLLDBDebugger` in `ios/devices.dart`). So:
    //   1. Launch via devicectl --console; stopped, in debug
    //   2. Get PID from process list
    //   3. In debug only: attach lldb (which starts debugserver / ptrace), set
    //      the JIT page notification breakpoint, and resume
    //   4. Find the VM service, if there is one: over a cable by what the app
    //      logs or its mDNS advertisement, whichever comes first; wirelessly
    //      by the advertisement
    final debug = buildMode == BuildMode.debug;

    final logs = _newAppLogs(onLog);

    // Step 1: Launch with --console to capture the app's output.
    //
    // flutter_tools wraps this in `script -t 0 /dev/null` "to convince
    // devicectl it has a terminal attached in order to redirect stdout"
    // (`ios/core_devices.dart`). That is unnecessary here: devicectl writes
    // the app's console output to these pipes without a pty.
    //
    // The app's environment goes in as `DEVICECTL_CHILD_*` variables, which
    // devicectl passes on with the prefix removed, rather than as
    // `--environment-variables`: devicectl lets that flag replace them, so
    // using it would drop every variable the caller set the same way, the
    // device's counterpart of the simulator's `SIMCTL_CHILD_*`.
    _consoleLauncherProcess = await _startHelper('xcrun', [
      'devicectl',
      'device',
      'process',
      'launch',
      '--device',
      info.udid,
      if (debug) '--start-stopped',
      '--console',
      bundleId,
      '--enable-dart-profiling',
      // flutter_tools passes this whenever debugging is enabled, which is
      // debug and profile (`getIOSLaunchArguments`).
      if (buildMode != BuildMode.release) '--enable-checked-mode',
      if (startPaused) '--start-paused',
      // A wireless device is dialed at its own address, so the VM service must
      // not bind to the device's loopback the way it does by default. Matches
      // flutter_tools' `DebuggingOptions.buildLaunchArguments`, which adds this
      // exactly when the connection interface is wireless.
      if (info.transport == IOSDeviceTransport.wireless)
        '--vm-service-host=0.0.0.0',
    ], environment: _launchEnvironment);

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

    // Step 2: Get PID from running process list. [stop] terminates the app by
    // it, debugger or not.
    final processId = await _findAppProcessId(installationUrl);
    _appPid = processId;

    // Step 3: In debug, attach lldb. Otherwise devicectl, which runs until the
    // app exits, is both the log source and the process the run watches.
    final Process process;
    if (debug) {
      process = await _attachDebugger(
        info: info,
        processId: processId,
        logs: logs,
        consoleDone: consolePump.done,
      );
    } else {
      logs.closeWhen([consolePump.done]);
      process = _consoleLauncherProcess!;
    }

    // Step 4: Find the VM service.
    final vmServiceUri = await _findVmService(
      info: info,
      bundleId: bundleId,
      installPath: installPath,
      logs: logs,
    );

    return AppInstance(
      process: process,
      vmServiceUri: vmServiceUri,
      logs: logs,
      scratchDirs: _scratch.handOver(),
    );
  }

  /// Attach lldb to the stopped app, set the JIT page breakpoint, and resume.
  ///
  /// Matches flutter_tools LLDB._selectDevice, _setBreakpoint,
  /// _attachToAppProcess, _resumeProcess.
  Future<Process> _attachDebugger({
    required IOSDeviceInfo info,
    required int processId,
    required AppLogStream logs,
    required Future<void> consoleDone,
  }) async {
    final lldb = await _startHelper('lldb', []);
    _lldbProcess = lldb;
    // lldb is a log source, not just a control channel — see [_startLldbOutput].
    final lldbDone = _startLldbOutput(lldb, appLogs: logs);

    // Both sources are now known, so the stream's life can be settled in one
    // place. They are not ordered — devicectl exits when the app terminates,
    // which is exactly when lldb starts reporting why — so the stream outlives
    // whichever ends first.
    logs.closeWhen([consoleDone, lldbDone]);
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
    // Synchronous, and every breakpoint stop resumed by [_LldbStops] rather
    // than by lldb itself. Letting lldb auto-continue the JIT breakpoint loses
    // hits when two threads allocate code at once (llvm/llvm-project#190956):
    // the app then runs a page the debugger never wrote and stops on
    // EXC_BAD_ACCESS (code=50). flutter_tools made the same change for the
    // same reason (af06e99a29, flutter/flutter#190307).
    await _lldbCommand(lldb, 'script lldb.debugger.SetAsync(False)');
    // The whole stop block, so the stop handling below starts after it and
    // never reads the attach's own SIGSTOP as a stop of the running app.
    await _lldbCommand(
      lldb,
      'device process attach --pid $processId',
      waitFor: _lldbTargetStopped,
    );
    _throwIfAbandoned();
    _lldbStops = _LldbStops(
      from: _lldbOutput!.nextCursor,
      lldb: lldb,
      appLogs: logs,
      deviceName: name,
    );
    // A debug app hits the JIT breakpoint as soon as it runs, and lldb in
    // synchronous mode then reports that stop instead of the resume.
    await _lldbCommand(
      lldb,
      'process continue',
      waitFor: RegExp(r'location added to breakpoint|Process \d+ resuming'),
    );
    return lldb;
  }

  /// The app's VM service, found and made reachable from here; or null for an
  /// AOT app that has none.
  ///
  /// A release app never has one, and flutter_tools does not look. A profile
  /// app has one only if it was built on the profile engine, and then its
  /// Info.plist declares `_dartVmService._tcp`: iOS lets an app advertise only
  /// the Bonjour services it declares, so an app that does not declare it has
  /// nothing this could find. A `-c opt` build without the profile flag is on
  /// the release engine and leaves the declaration out
  /// (`flutter_ios_info_plist`), so without this check a run built that way
  /// would wait out the whole discovery budget.
  Future<Uri?> _findVmService({
    required IOSDeviceInfo info,
    required String bundleId,
    required String installPath,
    required AppLogStream logs,
  }) async {
    switch (buildMode) {
      case BuildMode.debug:
        break;
      case BuildMode.release:
        return null;
      case BuildMode.profile:
        if (!await _declaresVmService(installPath)) {
          logs.add(
            'This build declares no Dart VM service (its Info.plist has no '
            '$_vmServiceBonjourType in NSBonjourServices), so the run has '
            'nothing to attach to. A -c opt build without '
            '--@rules_flutter//flutter:profile runs the release engine, which '
            'serves none.',
          );
          return null;
        }
    }

    // Two channels, and the first to answer wins, as in flutter_tools
    // (`_discoverDartVMForCoreDevice` in `ios/devices.dart`):
    //
    //  * The app's own output, over a cable only. The engine logs where the
    //    VM service listens, on the device's loopback, and `devicectl
    //    --console` and lldb carry that here; iproxy forwards the port over
    //    USB. This needs nothing from the local network, so it is what
    //    attaches to an app iOS has not yet let onto it: the first debug
    //    launch of a bundle id, whose Local Network question nobody has
    //    answered.
    //  * The app's mDNS advertisement (`_dartVmService._tcp`, which the
    //    debug/profile Info.plist declares under NSBonjourServices,
    //    `flutter/private/runners/ios/DartVmServiceMdns.plist`). The only
    //    channel a wireless device has: it gives the address to dial as well.
    //
    // The app still advertises over a cable, so nothing anyone else can see
    // of it changes; this only stops waiting on the advertisement.
    //
    // Minutes, not seconds — see [applyTimeout] for why a debug launch here is
    // this slow. The budget is a backstop for a run that will never succeed,
    // not an estimate; the "still waiting" note tells the user a long wait is expected
    // rather than a hang. flutter_tools splits the same two concerns, warning
    // at 60s/75s while its mDNS query runs for ten minutes
    // (`ios/devices.dart`).
    final wired = info.transport == IOSDeviceTransport.wired;
    final budget = wired ? wiredVmServiceBudget : wirelessVmServiceBudget;
    final elapsed = clock.stopwatch()..start();
    final found = Completer<_FoundVmService>();
    final stopAsking = Completer<void>();

    // The app's output also says what neither channel can: that iOS refused
    // the advertisement. The engine logs it when the app has not been allowed
    // onto the local network, whether the question went unanswered or was
    // answered Don't Allow, and only a person at the phone can change that.
    // Said plainly rather than left to the timeout, unless the log has already
    // found the service, when the refusal costs this run nothing.
    var refused = false;
    final watch = logs.lines.listen((line) {
      if (found.isCompleted) return;
      if (wired) {
        final match = vmServiceUriPattern.firstMatch(line.text);
        if (match != null) {
          found.complete(_LoggedVmService(Uri.parse(match.group(1)!)));
          return;
        }
      }
      if (!refused && line.text.contains(_registrationRefused)) {
        refused = true;
        logs.add(_localNetworkRefused(bundleId));
      }
    });

    // Over a cable an mDNS failure on this host does not end the wait: the
    // console and the forward go through devicectl, lldb and usbmuxd, none of
    // which the failure touches. It is said at once, and the wait goes on to
    // the end of the budget, which only then reports it. A failure after the
    // race is decided is moot, like the result.
    //
    // Only that case has a timer of its own. Otherwise mDNS's own deadline,
    // the same budget, ends the wait, with the explanation its failure gives.
    Timer? outOfTime;
    Timer? stillWaiting;
    void slow() {
      if (refused || found.isCompleted) return;
      logs.add(
        'Still waiting (${elapsed.elapsed.inSeconds}s) for the app\'s Dart VM '
        'service to appear.${buildMode == BuildMode.debug ? _slowJitStart : ''}'
        '${wired ? '' : _wirelessLocalNetwork(bundleId)}',
      );
    }

    void consoleOnly(MdnsDiscoveryException failure, StackTrace trace) {
      logs.add(
        'mDNS cannot run on this Mac, so this launch waits for the app to '
        'print its Dart VM service address on its console instead.\n'
        '${failure.message}',
      );
      final left = budget - elapsed.elapsed;
      outOfTime = Timer(left.isNegative ? Duration.zero : left, () {
        if (found.isCompleted) return;
        found.completeError(
          MdnsDiscoveryException(
            failure.failure,
            'The app printed no Dart VM service address within '
            '${budget.inSeconds}s, and mDNS could not look for it.\n'
            '${failure.message}',
          ),
          trace,
        );
      });
      final toSlow = _vmServiceSlowAfter - elapsed.elapsed;
      if (!toSlow.isNegative) stillWaiting = Timer(toSlow, slow);
    }

    unawaited(
      _mdns
          .discover(
            bundleId: bundleId,
            hostnames: info.hostnames,
            resolveAddress: !wired,
            timeout: budget,
            until: stopAsking.future,
            slowAfter: _vmServiceSlowAfter,
            onSlow: (_) => slow(),
          )
          .then(
            (record) {
              if (record != null && !found.isCompleted) {
                found.complete(_AdvertisedVmService(record));
              }
            },
            onError: (Object e, StackTrace trace) {
              if (found.isCompleted) return;
              if (wired &&
                  e is MdnsDiscoveryException &&
                  e.failure != MdnsDiscoveryFailure.notFound) {
                consoleOnly(e, trace);
              } else {
                found.completeError(e, trace);
              }
            },
          ),
    );

    final _FoundVmService service;
    try {
      service = await found.future;
    } on MdnsDiscoveryException catch (e) {
      if (!refused || e.failure != MdnsDiscoveryFailure.notFound) rethrow;
      throw MdnsDiscoveryException(
        e.failure,
        '${_localNetworkRefused(bundleId)}\n${e.message}',
      );
    } finally {
      outOfTime?.cancel();
      stillWaiting?.cancel();
      stopAsking.complete();
      await watch.cancel();
    }

    switch (service) {
      case _LoggedVmService(:final uri):
        // The logged address is the device's loopback: the port is the
        // device's, and the path carries the auth code.
        await _forward(info, uri.port);
        return uri.replace(host: '127.0.0.1');
      case _AdvertisedVmService(:final record) when wired:
        // The advertised port is a device-side port on the device's loopback.
        await _forward(info, record.port);
        return record.uriFor(host: '127.0.0.1', port: record.port);
      case _AdvertisedVmService(:final record):
        // No cable to forward through. `discover(resolveAddress: true)` throws
        // rather than returning a record without an address, so this is set.
        return record.uriFor(
          host: record.address!.address,
          port: record.port,
        );
    }
  }

  /// Forward [port] on this host to the same port on the device's loopback,
  /// through iproxy over USB, for the rest of the session: [stop], or a launch
  /// that fails after this, ends it (see [_reapLaunchHelpers]).
  Future<void> _forward(IOSDeviceInfo info, int port) async {
    final iproxyCommand = _locateIproxy();
    final iproxy = await _startHelper(
      iproxyCommand.executable,
      ['$port:$port', '-u', info.udid],
      environment: iproxyCommand.environment,
    );
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
        port,
        what: 'iproxy forward for the iOS VM service',
        probe: _forwardProbe,
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
  }

  /// Sized well above a healthy host's launch: the "still waiting" note
  /// exists to reassure someone on a slow host that the wait is expected, and
  /// one sized for a fast host would fire on every ordinary launch. The note
  /// says what is outstanding and what is worth checking, and quotes no
  /// duration — the cost varies by host by more than an order of magnitude,
  /// so any figure would be wrong for most readers.
  static const _vmServiceSlowAfter = Duration(seconds: 45);

  /// What the engine logs when iOS refuses to let it advertise the VM service
  /// (`kDNSServiceErr_PolicyDenied`, in `FlutterDartVMServicePublisher.mm`).
  static const _registrationRefused =
      'Could not register as server for FlutterDartVMServicePublisher, '
      'permission denied';

  /// What a launch says when iOS has refused the app the local network.
  static String _localNetworkRefused(String bundleId) =>
      '$bundleId is running, but iOS has not let it onto the local network, '
      'where it announces the Dart VM service this tool connects to. iOS '
      'asks once per app, with "Allow ... to find devices on local '
      'networks?" on the phone. Someone has to tap Allow there; this run '
      'keeps waiting. If it was answered Don\'t Allow, or the run still '
      'waits after the tap, turn the app on in Settings > Privacy & Security '
      '> Local Network and run again.';

  /// The Local Network question, for a wireless launch's "still waiting" note.
  ///
  /// Over a cable the app's console carries the engine's report of the
  /// refusal, which is how [_localNetworkRefused] knows to speak, and a cabled
  /// launch does not wait on the advertisement anyway. Without one that
  /// report may never arrive, so a slow start and a refusal look alike.
  static String _wirelessLocalNetwork(String bundleId) =>
      '\nIf this is the first launch of $bundleId on this device, look at the '
      'phone too: iOS asks once per app, with "Allow ... to find devices on '
      'local networks?", and nothing is announced until someone taps Allow.';

  /// Why a debug launch can be slow to advertise, for the "still waiting"
  /// note. An AOT app has no JIT trapping to the debugger.
  static const _slowJitStart =
      ' Until then the JIT is still trapping to the debugger for every '
      'executable page it allocates, which is the bulk of an iOS debug '
      'start. If this is taking far longer than your other launches on '
      'this host, check that Xcode has finished copying symbols for this '
      'device: a copy stranded part-way leaves lldb without the on-disk '
      'shared cache, and every one of those traps then costs a read off '
      'the device.';

  /// What the launch adds to devicectl's environment for the app.
  ///
  /// `OS_ACTIVITY_DT_MODE` sends the app's NSLog and os_log output to stderr,
  /// where `--console` picks it up; flutter_tools sets it for the same reason
  /// (`ios/core_devices.dart`).
  static const _launchEnvironment = {
    'DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE': 'enable',
  };

  /// The Bonjour service type the engine advertises its VM service as.
  static const _vmServiceBonjourType = '_dartVmService._tcp';

  /// Whether the app at [appPath] declares [_vmServiceBonjourType] in its
  /// Info.plist's NSBonjourServices.
  Future<bool> _declaresVmService(String appPath) async {
    final result = await _runProcess('plutil', [
      '-extract',
      'NSBonjourServices',
      'json',
      '-o',
      '-',
      p.join(appPath, 'Info.plist'),
    ]);
    // plutil exits 1 when the key is not there: an app with no Bonjour
    // services at all.
    if (result.exitCode != 0) return false;
    final Object? services;
    try {
      services = json.decode('${result.stdout}');
    } on FormatException catch (e) {
      throw StateError(
        'plutil printed NSBonjourServices from $appPath/Info.plist as JSON '
        'this could not read ($e): ${result.stdout}',
      );
    }
    return services is List && services.contains(_vmServiceBonjourType);
  }

  /// Python script for the JIT page notification breakpoint.
  ///
  /// Matches flutter_tools' `LLDB._pythonScript`. It returns nothing, so lldb
  /// stops after running it and [_LldbStops] resumes the app.
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
''';

  /// The last line of every stop lldb reports: `Target 0: (Runner) stopped.`
  static final _lldbTargetStopped = RegExp(r'^Target \d+: .* stopped\.$');

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
        final stops = _lldbStops;
        if (stops != null && stops.lldb == lldb && stops.consume(line)) return;
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
    _throwIfAbandoned();
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

    // Subscribe before writing so a fast reply cannot land first. The stream
    // replays everything buffered, so only lines from here on can answer: a
    // stop or a breakpoint id lldb printed for an earlier command matches the
    // same pattern and would otherwise be taken for this one's reply.
    final from = output.nextCursor;
    final completer = Completer<String>();
    final sub = output.lines.listen(
      (line) {
        if (line.index < from) return;
        if (!completer.isCompleted && waitFor.hasMatch(line.text)) {
          completer.complete(line.text);
        }
      },
      // lldb exited, or the launch was abandoned and reaped it: no answer is
      // coming, so say so now rather than after the timeout.
      onDone: () {
        if (completer.isCompleted) return;
        completer.completeError(
          StateError(
            _launchAbandoned
                ? 'The launch on $name was abandoned because the run is ending.'
                : 'lldb exited before answering "$command".\nlldb said:\n'
                      '${output.read(-40).lines.map((l) => '  ${l.text}').join('\n')}',
          ),
        );
      },
    );

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
  Future<int> _findAppProcessId(String installationUrl) async {
    final found = await _appProcessIdOnDevice(installationUrl);
    final pid = found.pid;
    if (pid != null) return pid;
    throw StateError(
      'None of the ${found.listed} process(es) running on $name is the '
      'app installed at $installationUrl. devicectl reported launching it, '
      'so it should be among them; an app that crashed on launch will not '
      'be.',
    );
  }

  /// The process id of the app installed at [installationUrl] among the
  /// processes `devicectl` lists on the device (null when none is running),
  /// and how many processes were listed.
  Future<({int? pid, int listed})> _appProcessIdOnDevice(
    String installationUrl,
  ) {
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
        return (pid: pid, listed: processes.length);
      }

      return (pid: null, listed: processes.length);
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

  /// An app that announced its VM service and then died (an exception once the
  /// engine was up, say) leaves an address nothing answers; this says the app
  /// is gone instead, with what lldb and devicectl last printed. Null while
  /// the device lists the app's process, and when the device cannot be asked:
  /// an unanswered question is not a verdict.
  ///
  /// The device's own process list is the platform's word on what runs there,
  /// matched the way the launch found the app: by its bundle's installation
  /// URL, so another process that has taken the pid does not stand in for it.
  @override
  Future<String?> whyAppExited(AppInstance instance) async {
    final url = _installationUrl;
    final pid = _appPid;
    final bundleId = _launchedBundleId;
    if (url == null || pid == null || bundleId == null) return null;
    final ({int? pid, int listed}) found;
    try {
      found = await _appProcessIdOnDevice(url);
    } on StateError catch (e) {
      return _livenessUnknown(bundleId, e.message);
    } on ProcessException catch (e) {
      return _livenessUnknown(bundleId, '$e');
    }
    if (found.pid == pid) return null;
    return '$bundleId (pid $pid) exited after announcing its VM service on '
        '$name. ${_browserLastWords(instance.logs)}';
  }

  /// The "cannot tell" answer of [whyAppExited]: on the record, and no verdict.
  String? _livenessUnknown(String bundleId, String why) {
    _logger.warning({
      'message': 'ios_liveness_check_failed',
      'text': 'Cannot tell whether $bundleId is still running on $name: $why',
      'device': name,
    });
    return null;
  }

  @override
  Future<void> stop(AppInstance instance) async {
    _lldbStops?.stopping = true;
    // Helpers first: see [_terminateApp] for why the debugger must be gone.
    await _reapLaunchHelpers();
    await _terminateApp();
    await _stopProcess('iOS app', instance.process, teardownBound);
    await instance.logs.close();
    await instance.disposeScratchDirs();
  }

  /// End the launched app on the device, if this launch got as far as
  /// finding it.
  ///
  /// Its own step because nothing else ends it: killing lldb detaches
  /// debugserver and the app keeps running, holding its VM service port.
  ///
  /// Only once lldb is gone. While it is attached, debugserver intercepts the
  /// SIGTERM `devicectl` sends and holds the app stopped instead; killing lldb
  /// then resumes it with the signal swallowed. Measured on an iOS 27 iPhone:
  /// terminate-then-detach left the app running every time.
  Future<void> _terminateApp() async {
    final pid = _appPid;
    if (pid == null) return;
    _appPid = null;
    final ProcessResult result;
    try {
      result = await _runProcess('xcrun', [
        'devicectl',
        'device',
        'process',
        'terminate',
        '--device',
        _addressedUdid,
        '--pid',
        '$pid',
      ]).timeout(teardownBound);
    } on TimeoutException {
      _logger.warning({
        'message': 'ios_app_terminate_timed_out',
        'text':
            'devicectl did not terminate the app (pid $pid) on $name within '
            '${teardownBound.inSeconds}s. It may still be running on the '
            'device.',
        'device': name,
        'pid': pid,
      });
      return;
    }
    // An app that already exited — it crashed, or the user closed it — is
    // the outcome this was after, not a failure.
    if (result.exitCode != 0 &&
        !'${result.stderr}'.contains('No such process')) {
      _logger.warning({
        'message': 'ios_app_terminate_failed',
        'text':
            'devicectl could not terminate the app (pid $pid) on $name, so it '
            'may still be running: ${result.stderr}',
        'device': name,
        'pid': pid,
        'error': '${result.stderr}',
      });
    }
  }

  late final _devicectl = DevicectlScreens(
    run: _runProcess,
    device: () => _addressedUdid,
    deviceName: () => name,
  );

  /// The device's screens as `devicectl device info displays` reports them.
  ///
  /// An iPhone reports its own screen and may report a wireless display
  /// beside it. The wireless one is listed and can be named, and is never the
  /// default.
  @override
  Future<List<Screen>> screens({ScreenshotDeadline? deadline}) =>
      _devicectl.list(deadline ?? ScreenshotDeadline(screenshotBound));

  /// `_flutter.screenshot` does not work on iOS: Impeller, always on there,
  /// cannot encode a compressed capture. devicectl captures the whole display,
  /// the way Xcode does.
  ///
  /// `device capture` and `device info displays` first shipped in Xcode 27's
  /// devicectl. An older one does not know the subcommands, and its answer is
  /// what is detected: devicectl's version numbers are not documented against
  /// its commands.
  @override
  Future<void> prepareScreenshot(VmServiceClient? vmClient) async {
    if (vmClient != null) {
      await vmClient.waitForFirstFrame();
    }
  }

  @override
  Future<void> captureScreen(
    AppInstance instance,
    String outputPath,
    Screen screen,
    ScreenshotDeadline deadline, {
    VmServiceClient? vmClient,
    String? window,
  }) => _devicectl.capture(screen, outputPath, deadline);
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

/// The pid `simctl launch` reports for [bundleId] in its [stdout]
/// (`com.example.app: 12345`), or null if it reports none.
int? simctlLaunchedPid(String stdout, String bundleId) {
  final match = RegExp(
    '^${RegExp.escape(bundleId)}: (\\d+)\$',
    multiLine: true,
  ).firstMatch(stdout.trim());
  return match == null ? null : int.parse(match.group(1)!);
}

/// The VM-service announcement in one record of `log stream --style ndjson`,
/// with the pid that logged it; null for any other line.
VmServiceAnnouncement? parseUnifiedLoggingAnnouncement(String line) {
  // `log stream` also prints a plain-text banner naming its filter, which
  // quotes the predicate and so contains the very words looked for.
  if (!line.startsWith('{')) return null;
  final Object? record;
  try {
    record = json.decode(line);
  } on FormatException {
    return null;
  }
  if (record is! Map) return null;
  final pid = record['processID'];
  final message = record['eventMessage'];
  if (pid is! int || message is! String) return null;
  final match = vmServiceUriPattern.firstMatch(message);
  if (match == null) return null;
  return (pid: pid, uri: Uri.parse(match.group(1)!));
}

/// Watch a log-emitting helper process for the VM-service announcement of the
/// app [isOwnProcess] accepts — see [discoverOwnVmServiceUri].
///
/// For sources where the helper process exists *only* to find the URI (the iOS
/// Simulator's discovery stream); app output comes from a separate stream. Like
/// [discoverVmServiceUri], this owns only its own subscription.
Future<Uri?> discoverVmServiceUriFromProcess(
  Process log, {
  required VmServiceAnnouncement? Function(String line) parse,
  required Future<bool> Function(int pid) isOwnProcess,
  Duration? timeout,
  Future<void>? appGone,
}) async {
  final logs = AppLogStream();
  final pump = pumpProcessLines(log, logs);
  // The helper is this stream's only source, so a helper that dies takes the
  // stream with it and discovery gives up at once instead of waiting out its
  // timeout on a process that will never say anything again.
  logs.closeWhen([pump.done]);
  try {
    return await discoverOwnVmServiceUri(
      logs,
      parse: parse,
      isOwnProcess: isOwnProcess,
      timeout: timeout,
      appGone: appGone,
    );
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
  /// fills with caches, so a failed launch releases it before rethrowing and
  /// [WebDevice.stop] releases it with the browser. Left behind they are not
  /// inert: a stale profile belongs to a browser a `--user-data-dir` scan can
  /// still find, and an orphaned window can serve a screenshot that makes a
  /// broken run look fine. A run killed too hard to release its profile
  /// leaves it for [ChromeProfiles.reapAbandoned].
  final ChromeProfile profile;

  Directory get userDataDir => profile.directory;

  /// The CDP debugging port announced on Chrome's stderr.
  final int cdpPort;

  /// The reader of the browser's stdout and stderr.
  ///
  /// Held so that it can be let go of: Chrome's helper processes inherit those
  /// pipes and can outlive the browser, and a reader still waiting for their
  /// end-of-file keeps this tool's process from exiting after a clean
  /// `daemon.shutdown`. The caller that takes over the session cancels it when
  /// the browser is stopped ([AppInstance.outputPumps]).
  final AppLogPump outputPump;

  /// The localhost URL the launched tab serves the app from — the URL every
  /// page-target lookup matches against.
  final String appUrl;

  /// The app page's CDP WebSocket URL as it was listed when the launch
  /// finished — what the run announces so a client can drive the page itself.
  ///
  /// A snapshot, not a handle anything here keeps using: every consumer in
  /// this tool re-resolves the target per use, because the listing is not a
  /// settled fact (see [resolveCdpPageTarget]).
  final String pageWebSocketDebuggerUrl;

  ChromeSession._({
    required this.process,
    required this.outputPump,
    required this.profile,
    required this.cdpPort,
    required this.appUrl,
    required this.pageWebSocketDebuggerUrl,
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
  ///
  /// Neither wait has a deadline: each ends on something Chrome does (it says
  /// the port is open, shows the page, exits, or closes its debugging
  /// connection) or on [abandoned]. [abandoned] completing means the run is
  /// ending: the launch stops waiting, and fails after releasing what it
  /// started. It is the only way the waits end other than Chrome acting — see
  /// [_discoverCdpPort] and [waitForAppPage]. After [slowStartNotice] in
  /// either wait a warning says Chrome is slow; it changes nothing about the
  /// wait.
  ///
  /// [stopBound] is how long a browser being ended gets to exit on SIGTERM
  /// before it is sent SIGKILL.
  static Future<ChromeSession> launch({
    required String url,
    required ProcessStarter startProcess,
    BrowserLaunchOptions options = const BrowserLaunchOptions(),
    String? chromePath,
    ChromeProfiles? profiles,
    Future<void>? abandoned,
    Duration slowStartNotice = const Duration(seconds: 10),
    NoticeTimer startNotice = Timer.new,
    Duration stopBound = const Duration(seconds: 5),
  }) async {
    final exe = chromePath ?? findChrome();
    if (exe == null) {
      throw StateError(
        'Chrome not found. Install Chrome or use -d macos for desktop.',
      );
    }
    // A rejection to race every wait against, so that an abandoned launch
    // fails where it stands rather than when that wait would have ended.
    const abandonedMessage =
        'The Chrome launch was abandoned because the run is ending.';
    var isAbandoned = false;
    final Future<Never>? abandonment = abandoned?.then<Never>((_) {
      isAbandoned = true;
      throw StateError(abandonedMessage);
    });
    // Raced, so it may lose; its rejection is then nobody's to report.
    abandonment?.ignore();
    Future<T> unlessAbandoned<T>(Future<T> wait) =>
        abandonment == null ? wait : Future.any([wait, abandonment]);

    final profile = await (profiles ?? ChromeProfiles()).create();
    // Checked once more before starting anything: a browser window that
    // flashes up only to be killed is the one thing worse than not launching.
    if (isAbandoned) {
      await profile.release();
      throw StateError(abandonedMessage);
    }
    final Process chrome;
    try {
      chrome = await startProcess(
        exe,
        launchArgs(url, options, userDataDir: profile.directory.path),
      );
    } catch (_) {
      await profile.release();
      rethrow;
    }
    profile.browserStarted(chrome.pid);

    // Chrome's own process output — browser diagnostics, not app output.
    // Kept drained for the browser's lifetime so its pipes can never fill
    // (an unread stderr on a browser this chatty is the likeliest place for
    // a full-pipe stall), and read once for the CDP port announcement.
    // Deliberately *not* surfaced as app output: the app's console lives
    // inside the page, and Chrome's own chatter would bury it.
    final diagnostics = AppLogStream(capacity: 200);
    final outputPump = pumpProcessLines(chrome, diagnostics);
    diagnostics.closeWhen([outputPump.done]);

    try {
      final announced = await unlessAbandoned(
        _discoverCdpPort(
          diagnostics,
          slowStartNotice: slowStartNotice,
          startNotice: startNotice,
          requestedPort: options.debugPort,
        ),
      );
      final cdpPort = announced.port;
      // The announcement is the readiness signal, not merely the number, so
      // it is awaited even when the port was dictated. A browser that takes a
      // different one than it was given is a state nothing here can drive:
      // every CDP consumer would dial the port that was asked for.
      if (options.debugPort != null && cdpPort != options.debugPort) {
        throw StateError(
          'Chrome was asked for --web-browser-debug-port '
          '${options.debugPort} and announced $cdpPort instead.',
        );
      }
      // Done before the session exists so the page it found can be part of
      // it. A session whose app page never appeared is a failed launch, not a
      // running one that every CDP consumer — screenshots, page reloads, the
      // console — then mis-drives.
      final page = await unlessAbandoned(
        waitForAppPage(
          browserEndpoint: announced.browserEndpoint,
          appUrl: url,
          browserExit: chrome.exitCode,
          lastWords: () => _browserLastWords(diagnostics),
          slowNotice: slowStartNotice,
          startNotice: startNotice,
        ),
      );
      final session = ChromeSession._(
        process: chrome,
        outputPump: outputPump,
        profile: profile,
        cdpPort: cdpPort,
        appUrl: url,
        pageWebSocketDebuggerUrl: page,
      );
      final viewport = options.viewport;
      if (viewport != null) await session.applyViewport(viewport);
      return session;
    } catch (_) {
      // A launch with no debugging port or no app page produced nothing
      // usable; don't leave the browser and its throwaway profile running
      // behind the error.
      // Bounded and escalated like every other stop: a browser that is wedged
      // is the one most likely to be why the launch failed, and one that
      // ignores SIGTERM would otherwise hold the failure — and with it the
      // teardown waiting on this launch — for good.
      await _stopProcess('browser', chrome, stopBound);
      await outputPump.dispose();
      await profile.release();
      rethrow;
    }
  }

  /// Lay the app out at [viewport], and prove that it did.
  ///
  /// `Emulation.setDeviceMetricsOverride` is sent once, right after the page
  /// is first resolved, on a connection that then stays open in
  /// [viewportHold] for as long as the browser runs: Chrome 154 scopes the
  /// override to the CDP session that set it and clears it the moment that
  /// socket closes. It does survive the `Page.reload` a web hot restart
  /// performs, so nothing has to be re-applied while the connection lives.
  ///
  /// **Read the result back on a *fresh* connection.** While the setting
  /// client is still attached the page reports metrics it has not settled at,
  /// so a verification folded into that socket to save a round trip would fail
  /// against a browser that is behaving correctly.
  ///
  /// Verified rather than assumed because the failure it guards is invisible:
  /// an override that did not take leaves every later screenshot and layout
  /// measurement quietly describing the wrong viewport.
  Future<void> applyViewport(WebViewport viewport) async {
    viewportHold = await applyViewportOverCdp(
      cdpPort: cdpPort,
      appUrl: appUrl,
      viewport: viewport,
      asked: '--web-viewport',
      hold: viewportHold,
    );
  }

  /// The CDP connection that set this launch's viewport, kept open for as long
  /// as the browser runs, or null when no viewport was asked for. The caller
  /// that takes over the session owns closing it. See [applyViewportOverCdp]
  /// for why it cannot be closed early.
  CdpPageConnection? viewportHold;
}

/// Web device — serves build output via HTTP and launches Chrome.
class WebDevice extends Device {
  final ProcessStarter _startProcess;

  /// Where this device's browser profiles live.
  final ChromeProfiles _profiles;

  /// The profile of the browser this device launched, until [stop] releases
  /// it.
  ChromeProfile? _profile;

  /// CDP debugging port discovered from Chrome stderr.
  int? _cdpPort;

  /// The localhost URL serving the app (used to find the correct CDP tab).
  String? _appUrl;

  /// The app page's CDP WebSocket URL as listed at launch. See
  /// [ChromeSession.pageWebSocketDebuggerUrl].
  String? _pageWebSocketDebuggerUrl;

  /// The CDP connection holding this run's viewport override open — see
  /// [applyViewportOverCdp]. Null until a viewport is set, and again after
  /// [stop], which closes it.
  CdpPageConnection? _viewportHold;

  /// Takes over [hold], watching it so that losing the viewport is loud: the
  /// override goes with the connection, and nothing else would say so.
  void _holdViewport(CdpPageConnection? hold) {
    // The same connection again, as `app.setViewport` reuses it: already
    // watched.
    if (identical(_viewportHold, hold)) return;
    _viewportHold = hold;
    if (hold == null) return;
    hold.done.then((_) {
      if (_viewportHold != hold) return;
      _viewportHold = null;
      _logger.severe({
        'message': 'web_viewport_lost',
        'text':
            'The browser closed the CDP connection that held the viewport, '
            'and the viewport went with it: screenshots from here on show the '
            'browser window\'s own size. Call app.setViewport to set it '
            'again, or relaunch.',
      });
    });
  }

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

  /// How the `app.*` agent commands reach the page's extensions when there is
  /// no VM service to reach them through: a bundled debug build (`--wasm`, or
  /// a debug `--no-hot` run), whose generated main installs a JavaScript
  /// bridge. Null for the DDC dev loop, which has a VM service, and for a
  /// bundle that is not a debug build, which compiles the extensions out.
  BrowserExtensionChannel? browserChannel;

  /// The browser to launch, or null to use the one [findChrome] finds on this
  /// host. A test run names its own: the pinned browser it was given is the one
  /// that runs, never another found on the host in its place.
  final String? _chromePath;

  WebDevice({
    ProcessStarter? startProcess,
    ChromeProfiles? profiles,
    String? chromePath,
  }) : _startProcess = startProcess ?? startChildProcess,
       _profiles = profiles ?? ChromeProfiles(),
       _chromePath = chromePath;

  @override
  String get name => 'Chrome';

  @override
  Future<List<HostTool>> requiredHostTools() async {
    final given = _chromePath;
    if (given == null) return [chromeTool()];
    // Only the browser that was named: were it missing, falling back to the
    // host's own would run the test in a browser nobody chose.
    return [
      HostTool(
        name: 'Chrome ($given)',
        purpose: 'run the app in the browser this run was configured with',
        candidates: [given],
        pathNames: const [],
        remedy:
            'This run names its browser itself and does not look for another, '
            'so the file is missing from where it was said to be.',
      ),
    ];
  }

  /// The bundle directory of a web app's build outputs: the `<name>_web`
  /// directory, which holds the page, and not the files built beside it (its
  /// `.serving.json`, the debug build's dev files). The output order is not the
  /// choice.
  @override
  String pickArtifact(List<String> outputs) => findWebOutputDir(outputs);

  /// Why the page is unreachable when the browser this tool started is gone: its
  /// exit, and its last words. Null while it runs, since a browser that is up
  /// and a page that is not is something only the page's own connection can
  /// say.
  @override
  Future<String?> whyAppExited(AppInstance instance) async {
    final code = await _exitCodeWithin(instance.process, _exitReportSettle);
    if (code == null) return null;
    final how = code < 0 && !Platform.isWindows
        ? 'was killed by signal ${-code}'
        : 'exited with code $code';
    return 'Chrome $how while the app was running. '
        '${_browserLastWords(instance.logs)}';
  }

  /// Set the DDC module server for dev mode (hot restart support).
  void setModuleServer(WebModuleServer server) => _moduleServer = server;

  /// The CDP debugging port, if discovered.
  int? get cdpPort => _cdpPort;

  /// The localhost URL serving the app, if launched.
  String? get appUrl => _appUrl;

  /// The app page's CDP WebSocket URL as it was listed when the browser came
  /// up, if launched. Announced for clients that drive Chrome themselves;
  /// nothing in this tool dials it, since every consumer here re-resolves the
  /// page per use.
  String? get pageWebSocketDebuggerUrl => _pageWebSocketDebuggerUrl;

  @override
  CompilerConfig? createCompilerConfig(
    String patchedSdkRoot, {
    WebToolchainPaths? webToolchain,
    List<String> fileSystemRoots = const [],
    String fileSystemScheme = '',
    List<String> dartDefines = const [],
    String dartPluginRegistrantUri = '',
    bool trackWidgetCreation = false,
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

  /// Completed by [abandonLaunch]: the run is ending, so a browser launch in
  /// flight stops waiting and releases what it started.
  final _abandoned = Completer<void>();

  /// A launch in flight, until it has returned or finished failing — by
  /// which point it has released everything it did not hand over.
  Future<void>? _launching;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    final settled = Completer<void>();
    _launching = settled.future;
    try {
      await _reapAbandonedProfiles();
      if (_moduleServer != null) {
        return await _launchWithModuleServer(onLog);
      }
      return await _launchStaticServer(appPath, onLog);
    } finally {
      settled.complete();
      _launching = null;
    }
  }

  /// Clear away the profiles of browsers that earlier runs, killed too hard
  /// to clean up after themselves, left behind. Housekeeping: a failure to do
  /// it is reported and does not fail the launch.
  Future<void> _reapAbandonedProfiles() async {
    try {
      await _profiles.reapAbandoned();
    } on FileSystemException catch (e) {
      _logger.warning({
        'message': 'chrome_profile_reap_failed',
        'text':
            'Could not look for Chrome profiles left by earlier runs in '
            '${_profiles.parent.path}: ${e.osError?.message ?? e.message}.',
        'error': '$e',
      });
    } on ProcessException catch (e) {
      _logger.warning({
        'message': 'chrome_profile_reap_failed',
        'text':
            'Could not tell whether the browsers of earlier runs are still '
            'running, so their Chrome profiles were not cleared: $e.',
        'error': '$e',
      });
    }
  }

  /// End a browser launch still in flight and wait until it has let go of
  /// the browser and its profile.
  ///
  /// The wait for Chrome's debugging port has no deadline of its own (see
  /// [_discoverCdpPort]), so this is what ends it when the run is stopped
  /// first. A launch that already returned handed its browser to the
  /// session, whose [stop] releases it.
  @override
  Future<void> abandonLaunch() async {
    if (!_abandoned.isCompleted) _abandoned.complete();
    await _launching;
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
      chromePath: _chromePath,
      options: options.browser,
      profiles: _profiles,
      abandoned: _abandoned.future,
      stopBound: teardownBound,
    );
    _profile = session.profile;
    _cdpPort = session.cdpPort;
    _holdViewport(session.viewportHold);
    _pageWebSocketDebuggerUrl = session.pageWebSocketDebuggerUrl;

    // No CDP console client here: DDC mode gets the app's output from the DWDS
    // VM service, and running both would print every line twice.
    return AppInstance(
      process: session.process,
      vmServiceUri: null,
      // The app's own output has its own source — DWDS, wired by the caller —
      // so it does not close with the browser process.
      logs: _newAppLogs(onLog),
      outputPumps: [session.outputPump],
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
        chromePath: _chromePath,
        options: options.browser,
        profiles: _profiles,
        abandoned: _abandoned.future,
        stopBound: teardownBound,
      );
    } catch (_) {
      // The session cleans up after its own failures; this path additionally
      // owns the static file server.
      await staticServer.stop();
      rethrow;
    }
    _profile = session.profile;
    _cdpPort = session.cdpPort;
    _holdViewport(session.viewportHold);
    _pageWebSocketDebuggerUrl = session.pageWebSocketDebuggerUrl;
    final logs = _newAppLogs(onLog);

    if (buildMode == BuildMode.debug) {
      browserChannel = BrowserExtensionChannel.forPage(
        cdpPort: _cdpPort!,
        appUrl: url,
      );
    }

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
      outputPumps: [session.outputPump],
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    try {
      // Unbounded on purpose. A client-side `WebSocket.close()` returns the
      // *outbound* sink's future and never waits for the peer's answering
      // close frame, so neither a peer that never answers nor one wedged so
      // hard it reads nothing can hold it. The one shape that does hang is a
      // wedged peer with a full send buffer, and this client writes a single
      // small `Runtime.enable` per connection, so it cannot build that
      // backlog. The SDK's own 5s close timer does NOT rescue that shape, so
      // this decision expires if the client ever grows chatty outbound
      // traffic.
      await _consoleClient?.close();
      _consoleClient = null;
      await browserChannel?.close();
      browserChannel = null;
      // Taken off first, so closing it is not reported as the viewport lost.
      final viewportHold = _viewportHold;
      _viewportHold = null;
      await viewportHold?.close();
      final moduleServer = _moduleServer;
      if (moduleServer != null) {
        // dwds is third-party and its `stop()` reaches peer-dependent awaits —
        // `DebugService.close()` waits on a DDS shutdown, `DwdsVmClient.close()`
        // on a VM-service client dispose. The browser is released in the
        // `finally` below, so a step here that throws still ends it.
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
    } finally {
      // However the steps above ended, the browser and its profile go: they
      // are the part of this run that outlives the process if it is missed, so
      // nothing that can throw stands in front of them.
      //
      // The browser first, and the profile once it has exited: a browser that
      // is still shutting down is still writing its caches, and deleting the
      // tree under it leaves a half-removed directory and an error naming a
      // file nobody asked about.
      await _stopProcess('browser', instance.process, teardownBound);
      // The browser has been asked to die; whatever a helper of it still
      // writes is nobody's. Not waiting for its end-of-file is what lets this
      // process exit when that helper is still alive.
      await instance.disposeOutputPumps();
      await instance.logs.close();
      final profile = _profile;
      _profile = null;
      await profile?.release();
    }
  }

  @override
  Future<void> captureScreen(
    AppInstance instance,
    String outputPath,
    Screen screen,
    ScreenshotDeadline deadline, {
    VmServiceClient? vmClient,
    String? window,
  }) async {
    if (_cdpPort == null) {
      throw StateError('CDP port not discovered — cannot capture screenshot');
    }
    await _cdpScreenshot(_cdpPort!, outputPath, appUrl: _appUrl);
  }

  /// Press [chord] in the app's page — `app.pressKey`'s browser route. See
  /// [pressKeyOverCdp].
  Future<BrowserKeyPress> pressKey(
    KeyChord chord, {
    required bool macCommands,
  }) async {
    final port = _cdpPort;
    final url = _appUrl;
    if (port == null || url == null) {
      throw StateError(
        'This web run has no browser to press keys in yet: its DevTools '
        'port has not been discovered, so the page cannot be reached.',
      );
    }
    return pressKeyOverCdp(
      cdpPort: port,
      appUrl: url,
      chord: chord,
      macCommands: macCommands,
    );
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
    _holdViewport(
      await applyViewportOverCdp(
        cdpPort: port,
        appUrl: url,
        viewport: viewport,
        asked: 'app.setViewport',
        hold: _viewportHold,
      ),
    );
  }
}

/// Chrome's announcement of its debugging server, printed to stderr once it
/// is listening: `DevTools listening on ws://127.0.0.1:PORT/devtools/browser/ID`.
/// Groups: the whole endpoint, its host, its port.
final cdpPortPattern = RegExp(
  r'DevTools listening on (ws://(\S+):(\d+)/\S*)',
);

/// What Chrome prints when it cannot open its debugging server on any
/// address. It then carries on running without one, so this line is the only
/// sign that the port will never be announced.
const cdpServerFailedLine = 'Cannot start http server for devtools';

/// Discover the CDP debugging port from Chrome's own diagnostic output.
///
/// Reads [browserDiagnostics] rather than subscribing to Chrome's pipes
/// directly, so finding the port doesn't stop those pipes being drained — an
/// unread stderr on a browser as chatty as Chrome is the likeliest place for a
/// full-pipe stall.
///
/// Ends on something Chrome does, never on a clock: it announces the port, it
/// says it cannot open the server, or it exits. How long a cold browser takes
/// to get there is the machine's business — a loaded CI runner has taken
/// longer than any deadline that is comfortable on a workstation — so a
/// deadline here would turn a slow start into a failed run. A browser that is
/// up and never answers is ended by whoever is waiting on the run (Ctrl-C,
/// `daemon.shutdown`, a client's own patience), which reaches this launch
/// through [ChromeSession.launch]'s `abandoned`. After [slowStartNotice] the
/// person waiting is told, with what Chrome has said so far; that changes
/// nothing about the wait.
///
/// Throws a [StateError] rather than returning null when the port cannot
/// arrive. It is not optional equipment: DDC dev mode dials CDP to give DWDS
/// its Chrome connection, and every web path uses it for screenshots and page
/// reloads, so accepting null here would buy a run with none of that and no
/// message. Upstream tool-exits in the same situation (`chrome.dart`'s "Unable
/// to connect to Chrome debug port").
Future<({int port, Uri browserEndpoint})> _discoverCdpPort(
  AppLogStream browserDiagnostics, {
  required Duration slowStartNotice,
  required NoticeTimer startNotice,
  int? requestedPort,
}) async {
  final completer = Completer<({int port, Uri browserEndpoint})>();
  void fail(String message) {
    if (!completer.isCompleted) completer.completeError(StateError(message));
  }

  final sinceLaunch = Stopwatch()..start();
  var noticeGiven = false;
  final notice = startNotice(slowStartNotice, () {
    noticeGiven = true;
    _logger.warning({
      'message': 'browser_slow_to_start',
      'text':
          'Chrome has not opened its DevTools debugging port '
          '${sinceLaunch.elapsed.inSeconds}s after launch; still waiting. '
          '${_browserLastWords(browserDiagnostics, silence: 'It has printed nothing so far.')}',
      'elapsedMs': sinceLaunch.elapsedMilliseconds,
    });
  });

  // A dictated port is the one thing about this launch that can be wrong
  // before Chrome even starts.
  final portInUse = requestedPort == null
      ? ''
      : ' --web-browser-debug-port $requestedPort may already be in use.';

  final sub = browserDiagnostics.lines.listen(
    (line) {
      if (completer.isCompleted) return;
      final match = cdpPortPattern.firstMatch(line.text);
      if (match != null) {
        final host = match.group(2)!;
        final port = int.parse(match.group(3)!);
        // Chrome tries 127.0.0.1 first and falls back to [::1] when that is
        // taken. Every CDP consumer here dials 127.0.0.1, so a server on any
        // other address is one they would miss — or, on a dictated port, one
        // where they would reach whatever holds 127.0.0.1 instead.
        if (host != '127.0.0.1') {
          fail(
            'Chrome opened its DevTools debugging port on $host:$port '
            'rather than 127.0.0.1, where this tool connects to it, which it '
            'does when 127.0.0.1:$port is taken.$portInUse',
          );
          return;
        }
        completer.complete((
          port: port,
          browserEndpoint: Uri.parse(match.group(1)!),
        ));
      } else if (line.text.contains(cdpServerFailedLine)) {
        fail(
          'Chrome could not open its DevTools debugging server. Without it '
          'there is no debugging connection: no DWDS VM service, no hot '
          'restart, no screenshots.$portInUse '
          '${_browserLastWords(browserDiagnostics)}',
        );
      }
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
      fail(
        'Chrome exited before announcing a DevTools debugging port. '
        '${_browserLastWords(browserDiagnostics)}',
      );
    },
  );

  try {
    final announced = await completer.future;
    final port = announced.port;
    // How long the browser took is what says whether a slow machine is
    // getting slower; worth a line at the default level only when the person
    // waiting was already told it was slow.
    final started = {
      'message': 'browser_debug_port_open',
      'text':
          'Chrome opened its DevTools debugging port $port after '
          '${sinceLaunch.elapsedMilliseconds}ms.',
      'cdpPort': port,
      'elapsedMs': sinceLaunch.elapsedMilliseconds,
    };
    noticeGiven ? _logger.info(started) : _logger.fine(started);
    return announced;
  } finally {
    notice.cancel();
    await sub.cancel();
  }
}

/// The tail of what the browser printed, phrased for the end of a message.
///
/// Read back off [AppLogStream] rather than accumulated by the listener above:
/// the buffer survives the stream closing, so the lines are still there at the
/// moment the launch is known to have failed, and there is no second copy of
/// the same output to keep in step with the first.
///
/// Says so explicitly when there is nothing to quote ([silence]). "Chrome
/// exited and printed nothing" is a real and different diagnosis from "Chrome
/// exited" — it rules out every cause that announces itself, and says the
/// search belongs somewhere other than the browser's output. An empty tail
/// rendered as nothing at all would instead read as if the quoting had been
/// forgotten.
String _browserLastWords(
  AppLogStream browserDiagnostics, {
  int lines = 20,
  String silence =
      'It printed nothing at all on the way out, so its own output does not '
      'hold the reason.',
}) {
  final tail = browserDiagnostics.read(-lines).lines;
  if (tail.isEmpty) return silence;
  return 'It last said:\n${tail.map((l) => '  ${l.text}').join('\n')}';
}

/// Lay the app's page out at [viewport], and prove that it did.
///
/// Shared by the two things that set a viewport: `--web-viewport` at launch
/// ([ChromeSession.applyViewport]) and the `app.setViewport` command
/// mid-session ([WebDevice.setViewport]). [asked] names whichever one it was,
/// so the failure says which input was not honoured.
///
/// `Emulation.setDeviceMetricsOverride` is sent on one connection and **that
/// connection is returned, still open, for the caller to keep for as long as
/// the viewport should hold.** Chrome 154 ties the override to the CDP session
/// that set it: when the socket closes the page goes back to the window's own
/// size, and every screenshot and layout read after that describes a viewport
/// nobody asked for. (Earlier Chromes kept it after the socket closed, which is
/// what this used to rely on.) The override does survive the `Page.reload` a
/// web hot restart performs.
///
/// Pass the connection back as [hold] to change the viewport on it, so a
/// sweep across form factors replaces the override rather than stacking
/// sessions; a [hold] that has closed is replaced by a fresh one. On failure a
/// connection this call opened is closed again, and the caller's own is left
/// as it was.
///
/// **The read-back needs its own connection.** While the setting client is
/// still attached the page reports metrics it has not settled at, so folding
/// the check into that socket to save a round trip would fail against a
/// browser behaving correctly — the read below deliberately opens its own,
/// and it sees the override because the held one is still open. It is
/// repeated until the page reports the size or [settleTimeout] runs out.
///
/// Verified rather than assumed because the failure it guards is invisible: an
/// override that did not take leaves every later screenshot and layout
/// measurement quietly describing the wrong viewport.
Future<CdpPageConnection> applyViewportOverCdp({
  required int cdpPort,
  required String appUrl,
  required WebViewport viewport,
  required String asked,
  CdpPageConnection? hold,
  Duration settleTimeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 200),
}) async {
  final reuse = hold != null && !hold.isClosed;
  final connection = reuse
      ? hold
      : await CdpPageConnection.open(cdpPort, appUrl: appUrl);
  try {
    await connection.send('Emulation.setDeviceMetricsOverride', {
      'width': viewport.width,
      'height': viewport.height,
      // 0 means "keep the browser's own ratio" — see WebViewport.
      'deviceScaleFactor': viewport.deviceScaleFactor ?? 0,
      // Not a mobile emulation: Chrome lays a mobile page out at its 980px
      // default until the page declares a viewport, and a Flutter app does
      // that only once its engine has started — after the launch that
      // verifies this. Without it the layout viewport is the size asked for
      // from the first read, whatever the page has or has not run.
      'mobile': false,
    });
    // Polled, because a read straight after the override can still describe
    // the page as it was laid out a moment ago.
    final stopwatch = Stopwatch()..start();
    Object? width;
    Object? height;
    Object? ratio;
    while (true) {
      final got = await _sendCdpToPage(cdpPort, appUrl, 'Runtime.evaluate', {
        'expression':
            '({w: window.innerWidth, h: window.innerHeight, '
            'r: window.devicePixelRatio})',
        'returnByValue': true,
      });
      final value = got['result']?['result']?['value'];
      width = value is Map ? value['w'] : null;
      height = value is Map ? value['h'] : null;
      ratio = value is Map ? value['r'] : '?';
      if (width == viewport.width && height == viewport.height) break;
      if (stopwatch.elapsed >= settleTimeout) {
        throw StateError(
          'The browser did not take the viewport $asked asked for. Wanted '
          '${viewport.width}x${viewport.height}, and after '
          '${settleTimeout.inSeconds}s the page still reports '
          '${width}x$height (devicePixelRatio $ratio).\n'
          'Every screenshot and every layout measurement taken from here on '
          'would describe a viewport nobody asked for.',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  } catch (_) {
    if (!reuse) await connection.close();
    rethrow;
  }
  return connection;
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
  final page = await CdpPageConnection.open(cdpPort, appUrl: appUrl);
  try {
    return await page.send(method, params);
  } finally {
    await page.close();
  }
}

/// One connection to the app page's CDP endpoint, for commands that have to
/// arrive in order on the same session — a key chord's downs and ups.
///
/// The target is resolved when the connection opens and not after, so hold
/// one only for a single operation: see [pickCdpPageTarget].
class CdpPageConnection implements CdpSender {
  final WebSocket _ws;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  var _nextId = 1;
  Object? _closedBy;
  final _done = Completer<void>();
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Whether the socket has closed, from either end.
  @override
  bool get isClosed => _closedBy != null;

  /// Completes when the socket closes, from either end — what a holder of a
  /// long-lived connection waits on to learn it lost the session.
  Future<void> get done => _done.future;

  CdpPageConnection._(this._ws) {
    _ws.listen(
      (data) {
        final msg = json.decode(data as String) as Map<String, dynamic>;
        final id = msg['id'];
        if (id is int) {
          _pending.remove(id)?.complete(msg);
        } else if (msg['method'] is String) {
          _events.add(msg);
        }
      },
      // A page that navigates away or a browser that exits closes the socket;
      // every command still waiting would otherwise spend its whole timeout
      // to report the same thing.
      onDone: () => _fail(StateError('the page\'s CDP connection closed')),
      onError: _fail,
    );
  }

  void _fail(Object error) {
    _closedBy ??= error;
    for (final c in _pending.values) {
      c.completeError(error);
    }
    _pending.clear();
    if (!_done.isCompleted) {
      _done.complete();
      unawaited(_events.close());
    }
  }

  /// Connect to the page serving [appUrl] on [cdpPort].
  static Future<CdpPageConnection> open(
    int cdpPort, {
    required String appUrl,
  }) async => CdpPageConnection._(
    await WebSocket.connect(
      await resolveCdpPageTarget(cdpPort, appUrl: appUrl),
    ),
  );

  /// Send [method] and return the whole reply; a CDP error is a [StateError]
  /// naming the method.
  ///
  /// Bounded: a browser that stops answering would otherwise hold the
  /// command pool's only slot for the rest of the run.
  @override
  Future<Map<String, dynamic>> send(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_closedBy case final error?) throw error;
    final id = _nextId++;
    final reply = _pending[id] = Completer<Map<String, dynamic>>();
    _ws.add(json.encode({'id': id, 'method': method, 'params': params}));
    final response = await reply.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw StateError(
          'CDP $method did not answer within ${timeout.inSeconds}s',
        );
      },
    );
    final error = response['error'];
    if (error != null) throw StateError('CDP $method failed: $error');
    return response;
  }

  @override
  Future<void> close() {
    _fail(StateError('the page\'s CDP connection was closed here'));
    return _ws.close();
  }
}

/// What pressing a key chord in the browser did: the events it sent, and the
/// two facts about the page that decide what they could reach.
class BrowserKeyPress {
  /// The `Input.dispatchKeyEvent` parameters, in the order sent.
  final List<Map<String, Object>> sent;

  /// What had the browser's focus when the keys went in, as the path of tag
  /// names through any shadow roots, e.g. `flutter-view > input`.
  final String focus;

  /// Whether that element takes typed text: an `<input>`, a `<textarea>` or
  /// an editable element. Flutter's web engine gives its focused text field
  /// a real one, so this is what says typing will land.
  final bool focusIsEditable;

  /// Whether the page was visible. A hidden page draws no frames, so what the
  /// keys changed does not repaint until it is shown.
  final bool pageVisible;

  const BrowserKeyPress({
    required this.sent,
    required this.focus,
    required this.focusIsEditable,
    required this.pageVisible,
  });
}

/// Page state [pressKeyOverCdp] reads before dispatching: the focused element
/// through shadow roots, whether it is editable, and the page's visibility.
const _focusProbe = '''
(() => {
  let e = document.activeElement;
  const path = [];
  let editable = false;
  while (e) {
    path.push(e.tagName.toLowerCase());
    editable = e.tagName === 'INPUT' || e.tagName === 'TEXTAREA' ||
        e.isContentEditable;
    e = e.shadowRoot ? e.shadowRoot.activeElement : null;
  }
  return {
    focus: path.join(' > ') || 'nothing',
    editable,
    visible: document.visibilityState === 'visible',
  };
})()''';

/// Press [chord] in the page serving [appUrl]: real, trusted key events,
/// dispatched by the browser to whatever has its focus.
///
/// [macCommands] attaches the Cocoa editing commands a Mac browser would —
/// see [macEditingCommandsFor], and the measurement there: without them
/// Control+K deletes nothing.
///
/// Everything goes over one connection, in order, and the focus and
/// visibility are read on it first. Coordinates are never involved: the
/// browser routes a key to the focused element, which is what makes this safe
/// to run against a page whose size changed since launch.
Future<BrowserKeyPress> pressKeyOverCdp({
  required int cdpPort,
  required String appUrl,
  required KeyChord chord,
  required bool macCommands,
}) async {
  final page = await CdpPageConnection.open(cdpPort, appUrl: appUrl);
  try {
    final probe = await page.send('Runtime.evaluate', {
      'expression': _focusProbe,
      'returnByValue': true,
    });
    final state = probe['result']?['result']?['value'];
    final sent = <Map<String, Object>>[];
    for (final stroke in chord.strokes) {
      final params = stroke.cdpParams(
        macCommands: macCommands ? macEditingCommandsFor(stroke) : const [],
      );
      await page.send('Input.dispatchKeyEvent', params);
      sent.add(params);
    }
    return BrowserKeyPress(
      sent: sent,
      focus: state is Map ? '${state['focus']}' : 'unknown',
      focusIsEditable: state is Map && state['editable'] == true,
      pageVisible: state is! Map || state['visible'] != false,
    );
  } finally {
    await page.close();
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

/// What a physical iOS device launch does with each stop lldb reports once the
/// app is running.
///
/// lldb runs synchronously and the JIT breakpoint does not auto-continue (see
/// the launch), so every page notification arrives as a stop. A stop at a
/// breakpoint is routine: it is resumed and not shown. Any other stop is the
/// app itself stopping — an EXC_BAD_ACCESS, an abort — and left alone it hangs
/// the app under the debugger while the VM service goes silent. So it is
/// reported as app output, backtraced, and the debugger detaches and quits,
/// which ends the session the way an exited app does on every other platform.
class _LldbStops {
  /// The first line of lldb's output that can belong to a stop of the running
  /// app; everything earlier is the launch's own.
  final int from;

  final Process lldb;
  final AppLogStream appLogs;
  final String deviceName;

  /// Set while the tool is ending the app itself, whose stops are not news.
  bool stopping = false;

  final List<String> _stop = [];
  bool _inStop = false;
  bool _reported = false;

  _LldbStops({
    required this.from,
    required this.lldb,
    required this.appLogs,
    required this.deviceName,
  });

  static final _processStopped = RegExp(r'^Process \d+ stopped$');
  static final _processExited = RegExp(r'^Process \d+ exited with status');

  /// Whether [line] was this handler's to deal with, so it is not forwarded as
  /// ordinary output.
  bool consume(AppLogLine line) {
    if (line.index < from) return false;
    final text = line.text;
    if (_reported) {
      // The backtrace and detach that follow a reported stop are the report.
      if (text.trim().isEmpty || text.startsWith('(lldb)')) return true;
      appLogs.add(text, isError: true);
      return true;
    }
    if (!_inStop) {
      if (_processExited.hasMatch(text.trim())) {
        if (stopping) return true;
        // Nothing is left to debug; quitting lldb ends the session.
        _reported = true;
        _logger.info({
          'message': 'ios_app_exited',
          'text': 'The app on $deviceName exited ($text).',
          'device': deviceName,
          'line': text,
        });
        appLogs.add(text);
        lldb.stdin.writeln('quit');
        return true;
      }
      if (!_processStopped.hasMatch(text.trim())) return false;
      _inStop = true;
      _stop.clear();
    }
    _stop.add(text);
    if (!IOSDevice._lldbTargetStopped.hasMatch(text.trim())) return true;

    _inStop = false;
    if (_stop.any((l) => l.contains('stop reason = breakpoint'))) {
      lldb.stdin.writeln('process continue');
      return true;
    }
    if (stopping) return true;

    _reported = true;
    final reason = _stop
        .firstWhere(
          (l) => l.contains('stop reason = '),
          orElse: () => _stop.first,
        )
        .trim();
    _logger.warning({
      'message': 'ios_app_stopped',
      'text':
          'The app stopped under the debugger on $deviceName ($reason). '
          'Reporting its backtrace and detaching.',
      'device': deviceName,
      'reason': reason,
    });
    for (final l in _stop) {
      appLogs.add(l, isError: true);
    }
    lldb.stdin
      ..writeln('thread backtrace all')
      ..writeln('detach')
      ..writeln('quit');
    return true;
  }
}
