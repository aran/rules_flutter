/// What a `flutter_bazel run` invocation resolves to, before anything happens.
///
/// Every question a run has to answer up front — which devices, which
/// compilation mode, which bazel flags, where the workspace and toolchain are —
/// is answered once, here, and the answers do not change afterwards.
///
/// [resolve] mutates the devices it resolved (`startPaused`, `expectsVmService`).
/// That is deliberately part of planning rather than of launching: both switches
/// travel as launch-time engine arguments, so there is no moment after launch at
/// which they could be applied.
library;

import 'dart:async';

import 'package:args/args.dart';

import 'bazel.dart';
import 'dev_tool_exception.dart';
import 'device.dart';
import 'logging.dart';
import 'toolchain_info.dart';
import 'web_mode.dart';
import 'web_options.dart';

/// Refuses a compilation mode no device in [devices] can actually run.
///
/// Only one combination qualifies, and it is the one that fails quietly: an AOT
/// bundle on an iOS simulator. The simulator slice of the Flutter engine is JIT
/// and looks for `flutter_assets/kernel_blob.bin`, which a `-c opt` bundle does
/// not contain — but `simctl install` and `simctl launch` both return 0, the
/// process stays alive, nothing crashes, the screen stays blank white, and the
/// reason appears only in the simulator's system log. A build is deliberately
/// not refused: `bazel build -c opt` for the simulator is a legitimate thing to
/// do, and the default iOS configuration *is* the simulator, so failing there
/// would break every release build. It is running it that cannot work.
void assertModeCanRun(String? compilationMode, List<Device> devices) {
  if (compilationMode != 'opt') return;
  for (final simulator in devices.whereType<IOSSimulatorDevice>()) {
    throw DevToolException(
      'Cannot run an AOT build on ${simulator.name}: the simulator\'s '
      'Flutter engine is JIT-only and needs '
      'flutter_assets/kernel_blob.bin, which a `-c opt` bundle does not '
      'contain. It would install, launch, stay alive and render blank.\n'
      'Run it in JIT (drop --profile, or build -c dbg), or use `-d ios` to '
      'observe a release build on a physical device.',
    );
  }
}

class RunPlan {
  final String target;

  /// Every extra bazel argument, platform flags included. One list, because a
  /// build and the cquery that reads its outputs have to agree exactly.
  ///
  /// The `--dart-define` flags live here and nowhere else. This is the build
  /// that bakes them into the app; every later invocation of the run reads them
  /// back off the running app instead of being told a second time.
  final List<String> extraArgs;

  /// The user's raw `--build-arg` values.
  ///
  /// Kept apart from [extraArgs] because the dev-loop builds need them without
  /// the device flags: a bare build of the flutter_application resolves in the
  /// host configuration, while these change it wherever they are applied. Only
  /// the user knows they were passed, and nothing in the app records them.
  final List<String> userBuildArgs;

  /// `opt` in profile mode, `dbg` with hot reload, else whatever `-c` said.
  /// An explicit `-c` naming any other mode is refused, not overridden.
  final String? compilationMode;

  final List<Device> devices;
  final String workspace;
  final ToolchainPaths toolchain;

  final bool hotReloadEnabled;
  final bool profileMode;
  final String? initialRoute;
  final bool traceStartup;
  final bool startPaused;
  final bool isMachine;
  final bool watchEnabled;
  final bool wasmMode;
  final bool devToolsEnabled;
  final bool httpChannelEnabled;
  final bool allowNoVmService;

  /// Which of the three shapes this web run takes, or null for a native run.
  /// The one derivation — every question about the run's web shape is asked
  /// of this, never re-derived from the raw flags.
  final WebMode? webMode;

  /// What the web flags resolved to, or null for a native run. Null and
  /// [webMode] null are the same fact.
  final WebOptions? webOptions;

  final Logger logger;

  RunPlan._({
    required this.target,
    required this.extraArgs,
    required this.userBuildArgs,
    required this.compilationMode,
    required this.devices,
    required this.workspace,
    required this.toolchain,
    required this.hotReloadEnabled,
    required this.profileMode,
    required this.initialRoute,
    required this.traceStartup,
    required this.startPaused,
    required this.isMachine,
    required this.watchEnabled,
    required this.wasmMode,
    required this.devToolsEnabled,
    required this.httpChannelEnabled,
    required this.allowNoVmService,
    required this.webMode,
    required this.webOptions,
    required this.logger,
  });

  /// Whether this run targets a browser.
  bool get isWebDevice => devices.first is WebDevice;

  /// Whether this is the DDC dev loop: a browser, in debug, not WASM. The only
  /// configuration with a module server and a DWDS VM service.
  ///
  /// Read off [webMode] rather than recombined from the flags, which is what
  /// [resolveWebMode] exists for.
  bool get isDdcWeb => webMode is DdcWebMode;

  /// The web serving options, for a run that has them. Asking a native run is
  /// a caller bug, not a state to paper over with a default.
  WebServerOptions get webServer {
    final options = webOptions;
    if (options == null) {
      throw StateError(
        'This run has no web server options: it is not a web run.',
      );
    }
    return options.server;
  }

  /// How the mode reads in a log line.
  String get modeName =>
      profileMode ? 'profile' : (compilationMode ?? 'default');

  /// Whether this run's app carries the `rules_flutter.build_info` record
  /// `app.buildInfo` answers from.
  ///
  /// `flutter_compile_kernel` bakes it in as a dart define, so it exists on a
  /// `-c dbg` native build and nowhere else: the web pipelines compile with
  /// DDC or dart2wasm and never see it, and a profile run is AOT. Deciding it
  /// here rather than letting the command be advertised and fail is what keeps
  /// the command list a statement about this run.
  bool get carriesBuildInfo => carriesBuildInfoFor(
    isWebDevice: isWebDevice,
    compilationMode: compilationMode,
  );

  /// Whether this run's app carries the `ext.rules_flutter.*` extensions the
  /// `app.*` agent surface proxies to.
  ///
  /// They are registered with `dart:developer` and reached over a VM service,
  /// so a native run has them and, on a browser, only the DDC dev loop does —
  /// see [DdcWebMode], which is where that fact is written down. A `--wasm` or
  /// `--profile` web run serves a bundle compiled by dart2wasm or dart2js,
  /// where `registerExtension` is a no-op stub, to a page with no VM service
  /// behind it. Decided here so such a run stops advertising commands it can
  /// only refuse.
  bool get hasAgentSurface =>
      hasAgentSurfaceFor(isWebDevice: isWebDevice, isDdcWeb: isDdcWeb);

  /// The same run, in the vocabulary upstream's daemon protocol uses for
  /// `app.start`'s `mode` field.
  ///
  /// Everything that is not `dbg` is `release`, because that is what the rules
  /// actually do: every engine select reads `//flutter/private:dbg` -> debug
  /// and `//conditions:default` -> release, so a `fastbuild` run is running
  /// the release engine however its bazel mode reads. Derived rather than
  /// passed through so the field cannot say `fastbuild` at a client that only
  /// knows the three upstream names.
  String get daemonMode => profileMode
      ? 'profile'
      : (compilationMode == 'dbg' ? 'debug' : 'release');

  /// The compilation mode a set of flags implies.
  ///
  /// Not a preference — a fact about what each mode needs. Profile is AOT, so
  /// `opt`; hot reload needs a JIT kernel, so `dbg`; with neither asked for, the
  /// user's own `-c` stands (and null means "whatever the workspace defaults
  /// to", which is not the same as `fastbuild`).
  ///
  /// Because those are facts, an explicit `-c` naming a different one is
  /// refused rather than corrected. `--hot` defaults to true, so overriding
  /// instead would consult the user's own `-c` only when `--no-hot` was passed,
  /// and `run -c opt` would build `dbg` and say nothing about it. Only a
  /// contradiction is an error — a `-c` that agrees is silent, and no `-c` at
  /// all is not a contradiction, so the default path is unchanged.
  ///
  /// The required mode is exact: `fastbuild` contradicts hot reload just as
  /// `opt` does. Every engine select in the rules reads
  /// `//flutter/private:dbg` -> debug, `//conditions:default` -> release, and
  /// only `dbg` compiles with `--enable-asserts`, so a `fastbuild` build has
  /// no JIT kernel to reload into either.
  ///
  /// Pulled out of [resolve] so it can be tested at all: [resolve] does real
  /// I/O — `bazel info`, toolchain resolution, device preflight — which a test
  /// of a three-way conditional has no business standing up.
  static String? compilationModeFor(ArgResults results) {
    final config = results['config'] as String?;
    final profileMode = results['profile'] as bool;
    final hotReloadEnabled = results['hot'] as bool;

    // Nothing requires a mode, so there is nothing to contradict: the user's
    // `-c` stands, whatever it says, and no `-c` stays null.
    if (!profileMode && !hotReloadEnabled) return config;

    final (required, asked, why, optOut) = profileMode
        ? ('opt', '--profile', 'profile mode is AOT', 'Drop `--profile`')
        : (
            'dbg',
            'hot reload',
            'hot reload needs a JIT kernel and the debug engine',
            'Pass `--no-hot`',
          );

    // Only an explicit `-c` can contradict anything. `wasParsed` is what
    // separates one from the default, and so is what makes refusing possible
    // at all rather than silently substituting.
    if (results.wasParsed('config') && config != required) {
      throw DevToolException(
        '`-c $config` contradicts $asked: $why, which only `-c $required` '
        'produces.\n'
        '$optOut to build `-c $config`, or drop `-c` to build '
        '`-c $required`.',
      );
    }
    return required;
  }

  /// Why this run will not hot reload, or null when it intends to.
  ///
  /// One answer for every surface the flags govern — the reload keys, the
  /// watcher, whether a native pipeline is assembled at all, and the
  /// `supportsRestart` an IDE reads. Consulted separately by each, `--no-hot
  /// -c dbg` (a combination [compilationModeFor] deliberately allows) would
  /// assemble a full pipeline whose 'r' hot reloads an app the user asked it
  /// not to.
  ///
  /// Deliberately about *intent*, not about whether the machinery came up.
  /// `ReadinessGate` answers the second, and they need different words: "you
  /// asked me not to" is not "it was meant to work and did not".
  String? get hotReloadOff =>
      hotReloadOffReason(profileMode: profileMode, hotFlag: hotReloadEnabled);

  /// [hotReloadOff] over the raw flags, so it can be tested without standing a
  /// workspace up — the same reason [compilationModeFor] and [watchEnabledFor]
  /// are functions.
  ///
  /// Profile wins when both apply: `--hot` defaults to true and `--profile`
  /// never clears it, so a profile run arrives here with both set, and "this
  /// build is AOT" is the stronger fact — there was no hot reload to switch
  /// off.
  static String? hotReloadOffReason({
    required bool profileMode,
    required bool hotFlag,
  }) {
    if (profileMode) {
      return 'profile mode builds AOT, which has no hot reload — drop '
          '`--profile` for a debug run';
    }
    if (!hotFlag) {
      return '`--no-hot` was passed — drop it to get the reload keys back';
    }
    return null;
  }

  /// Whether the filesystem watcher runs.
  ///
  /// Terminal mode drives reloads from the filesystem. Machine mode has a
  /// client doing it, and a watcher underneath would reload twice for one edit
  /// — so the default flips, and an explicit `--watch`/`--no-watch` beats both.
  static bool watchEnabledFor(ArgResults results, {required bool isMachine}) =>
      results.wasParsed('watch') ? results['watch'] as bool : !isMachine;

  /// Resolve everything, validate it, and prepare the devices for launch.
  ///
  /// Throws [DevToolException] for anything that makes the run impossible: a
  /// misconfigured host, devices that cannot share one build, a mode a device
  /// cannot run. All of it before a build is spent on it.
  static Future<RunPlan> resolve(ArgResults results, Logger logger) async {
    final target = results['target'] as String;
    final defineFlags = dartDefineFlags(results['dart-define'] as List<String>);
    final isMachine = results['machine'] as bool;
    final hotReloadEnabled = results['hot'] as bool;
    final profileMode = results['profile'] as bool;
    final initialRoute = results['route'] as String?;
    final traceStartup = results['trace-startup'] as bool;
    final startPaused = results['start-paused'] as bool;
    final allowNoVmService = results['allow-no-vm-service'] as bool;

    // Reads nothing but the flags, so it comes before any I/O: a `-c` that
    // contradicts the run is a typo to report at once, not after two `bazel
    // info` spawns and a toolchain resolution have been spent on it.
    final compilationMode = compilationModeFor(results);

    // Resolve the workspace root once rather than per callsite: it avoids
    // redundant `bazel info` spawns and gives every consumer the same answer.
    final workspace = await findWorkspaceRoot();
    // The native pipeline needs the frontend server and dartaotruntime out of
    // this, and DevTools needs the toolchain's `dart` on every platform —
    // including web, which otherwise never resolves a toolchain at all.
    final toolchain = await resolveToolchainPaths(target, workspace: workspace);

    // Devices FIRST — they dictate the platform build flags.
    final devices = resolveDevices(results['device'] as List<String>);

    // What shape of web run this is, and what the web flags mean for it —
    // both before the host is probed, because a `--web-port` that is not a
    // number is a typo to report at once rather than after a preflight.
    // `resolveWebMode` refuses `--wasm` and `--hot` combinations that cannot
    // hold; `WebOptions.resolve` refuses every web flag on a native run.
    final webMode = resolveWebMode(
      isWebDevice: devices.first is WebDevice,
      wasmMode: results['wasm'] as bool,
      profileMode: profileMode,
      hotReloadEnabled: hotReloadEnabled,
      hotExplicit: results.wasParsed('hot'),
    );
    final webOptions = WebOptions.resolve(results, webMode);

    logger.fine({
      'message': 'resolved_devices',
      'text': 'Resolved devices: ${devices.map((d) => d.name).toList()}',
      'devices': devices.map((d) => d.name).toList(),
    });

    // All devices must agree on platform build args: one invocation is one
    // build, and a build cannot be for two platforms at once.
    final distinctBuildArgs = devices.map((d) => d.buildArgs.join(' ')).toSet();
    if (distinctBuildArgs.length > 1) {
      final details = devices
          .where((d) => d.buildArgs.isNotEmpty)
          .map((d) => '  ${d.name}: ${d.buildArgs.join(' ')}')
          .join('\n');
      throw DevToolException(
        'Cannot build for multiple platforms in one invocation.\n$details',
      );
    }

    // Fail on a misconfigured host before spending a build on it. Each device
    // names the external programs its launch drives, so a missing `aapt2` or an
    // unattached phone is reported here, by name, instead of surfacing later as
    // an app that never started and a VM service that never appeared.
    for (final device in devices) {
      try {
        await device.preflight();
      } on StateError catch (e) {
        throw DevToolException('Cannot run on ${device.name}: ${e.message}');
      }
    }

    assertModeCanRun(compilationMode, devices);

    // Debug (JIT) launches await the app's Dart VM service. On Android that
    // service can only bind if the APK holds android.permission.INTERNET —
    // enforcement is kernel-level (AID_INET group) and applies even to
    // 127.0.0.1 — so tell Android devices to preflight the installed package.
    // --allow-no-vm-service opts out of requiring a VM service, so it also skips
    // the preflight (mirroring the post-launch no-VM-service abort).
    if (compilationMode == 'dbg' && !allowNoVmService) {
      for (final device in devices.whereType<AndroidDevice>()) {
        device.expectsVmService = true;
      }
    }

    // Before launch, because every platform delivers this as a launch-time
    // engine argument — an intent extra, an env switch, a trailing argv entry.
    // There is no way to pause an app that has already started.
    for (final device in devices) {
      device.startPaused = startPaused;
    }
    // Same reason, same moment: a browser's static-bundle server is built
    // inside `launch`, so this is the last point at which it can be told how
    // to serve. The DDC path's server is built by the assembler from the same
    // options, so the two cannot disagree.
    if (webOptions != null) {
      for (final device in devices.whereType<WebDevice>()) {
        device.webOptions = webOptions;
      }
    }
    if (startPaused && (initialRoute != null || traceStartup)) {
      logger.warning({
        'message': 'start_paused_skips_startup_calls',
        'text':
            'A paused app has no framework yet, so '
            '${[if (initialRoute != null) '--route', if (traceStartup) '--trace-startup'].join(' and ')} '
            'cannot be applied at launch and are skipped for this run.',
      });
    }

    return RunPlan._(
      target: target,
      extraArgs: [
        ...(results['build-arg'] as List<String>),
        ...defineFlags,
        ...devices.first.buildArgs,
      ],
      userBuildArgs: results['build-arg'] as List<String>,
      compilationMode: compilationMode,
      devices: devices,
      workspace: workspace,
      toolchain: toolchain,
      hotReloadEnabled: hotReloadEnabled,
      profileMode: profileMode,
      initialRoute: initialRoute,
      traceStartup: traceStartup,
      startPaused: startPaused,
      isMachine: isMachine,
      // Terminal: watch by default. Machine: don't — a client that drives
      // reloads itself does not want the filesystem doing it too.
      watchEnabled: watchEnabledFor(results, isMachine: isMachine),
      wasmMode: results['wasm'] as bool,
      devToolsEnabled: results['devtools'] as bool,
      httpChannelEnabled: results['http-control-channel'] as bool,
      allowNoVmService: allowNoVmService,
      webMode: webMode,
      webOptions: webOptions,
      logger: logger,
    );
  }

  /// Build the target and pick the artifact to launch from.
  Future<({String appFile, List<String> outputFiles})> buildApp() async {
    logger.fine({
      'message': 'compilation_config',
      'text': 'Compilation mode: $compilationMode, extra args: $extraArgs',
      'compilationMode': compilationMode,
      'extraArgs': extraArgs,
    });
    logger.info({
      'message': 'building',
      'text': 'Building $target ($modeName mode)...',
      'target': target,
      'mode': modeName,
    });

    final result = await bazelBuild(
      target,
      workspace: workspace,
      compilationMode: compilationMode,
      extraArgs: extraArgs,
    );
    if (!result.success) {
      throw DevToolException(
        'Build failed with exit code ${result.exitCode}',
        exitCode: result.exitCode,
      );
    }
    if (result.outputFiles.isEmpty) {
      throw DevToolException(
        'Build succeeded but cquery returned no output files for $target.',
      );
    }
    final appFile = devices.first.pickArtifact(result.outputFiles);
    logger.fine({
      'message': 'build_outputs',
      'text': 'Launch artifact: $appFile',
      'outputs': result.outputFiles,
    });
    return (appFile: appFile, outputFiles: result.outputFiles);
  }
}

/// Whether a run with these properties carries the `rules_flutter.build_info`
/// record.
///
/// Pulled out of [RunPlan] for the same reason `compilationModeFor` and
/// `watchEnabledFor` are: a plan cannot be constructed in a test, and a
/// predicate that decides what the command surface advertises is worth
/// checking without standing a workspace up.
bool carriesBuildInfoFor({
  required bool isWebDevice,
  required String? compilationMode,
}) => !isWebDevice && compilationMode == 'dbg';

/// Whether a run with these properties can answer the `app.*` agent surface.
///
/// Pulled out of [RunPlan] for the same reason [carriesBuildInfoFor] is.
bool hasAgentSurfaceFor({
  required bool isWebDevice,
  required bool isDdcWeb,
}) => !isWebDevice || isDdcWeb;
