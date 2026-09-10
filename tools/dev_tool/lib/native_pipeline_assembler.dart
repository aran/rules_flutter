/// Builds a native [ReloadPipeline]: the frontend server, the source view, the
/// orchestrator, and the rebuilds each of them needs.
///
/// Runs *after* the app is up, on both routes in. `run` has launched it and
/// hands over a [NativeLaunch]; `attach` found it already running and hands over
/// nothing — that difference is the whole of what separates them here, and it
/// costs three conditionals. Everything else — which target to cquery for the
/// flutter_application, how to read `_dev_config.json`, what to compile, how to
/// seed the applied versions — is the same work.
///
/// Ordering here is load-bearing in four places:
/// the app's [BuildInfo] is read before the first build, because every flag list
/// below is derived from it — the dev build's defines included; `teardown.add`
/// sits immediately against the construction of what it disposes;
/// `start → add → compile → accept` stays in that order, so a `daemon.shutdown`
/// racing the initial compile still shuts the compiler down; and
/// [ReloadPipeline.ready] is signalled as the very last statement of the success
/// path, never before it.
library;

import 'dart:async';

import 'bazel.dart';
import 'build_info.dart';
import 'compiler_config.dart';
import 'dev_tool_exception.dart';
import 'device.dart';
import 'frontend_server.dart';
import 'hot_reload/app_instance.dart' as hr;
import 'hot_reload/applied_versions.dart';
import 'hot_reload/asset_bundle.dart';
import 'hot_reload/compiler.dart' as hot_reload;
import 'hot_reload/package_uri_resolver.dart';
import 'hot_reload/reload_orchestrator.dart';
import 'hot_reload/session_reloader.dart';
import 'hot_reload/workspace.dart';
import 'logging.dart';
import 'native_libs_fingerprint.dart';
import 'native_libs_relauncher.dart';
import 'package_roots.dart';
import 'reload_pipeline.dart';
import 'session.dart';
import 'session_host.dart';
import 'temp_dir.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';

/// What the assembler can only know when this command launched the app itself.
///
/// Its presence turns on the one thing that needs a launch artifact: the
/// native-libs [Relauncher], which fingerprints the bundle it launched so a
/// changed `.dylib` relaunches the process instead of restarting the isolate.
///
/// It carries no build flags. Those would describe what `run` was *told* to
/// do, which is not the same as what the app ended up being built as, and
/// attach has no equivalent at all. The app reports its own configuration
/// ([BuildInfo]), which works on both routes in and cannot disagree with the
/// binary that is running.
class NativeLaunch {
  /// The artifact the app was launched from.
  final String appFile;

  const NativeLaunch({required this.appFile});
}

class NativePipelineAssembler {
  final String workspace;
  final ToolchainPaths toolchain;

  /// The target the user named. Also what gets rebuilt for assets and for a
  /// relaunch — never the flutter_application, whose own outputs live in a
  /// different configuration.
  final String target;

  /// The device whose compiler config and build args apply. `run` passes the
  /// device it launched on; `attach` passes its pseudo-device, whose base
  /// implementations produce the native config and the [VmServiceReloadStrategy]
  /// attach needs.
  final Device configDevice;

  /// The user's `--build-arg` values.
  ///
  /// These reach every bazel invocation of the session, dev build included.
  /// They cannot be recovered from the running app — a build arg is not
  /// recorded anywhere in the binary — so on `attach` the user has to pass the
  /// same ones the run used. Omitting them changes the configuration, which
  /// the assets-tree check then reports by name.
  final List<String> userBuildArgs;

  final SessionHost host;
  final ReloadPipeline pipeline;
  final Logger logger;

  /// When the source that produced the running app was last knowably intact.
  ///
  /// `run` captures it before building the launch target; `attach` at command
  /// start. Everything older than this is what the app is running, and is
  /// seeded as already-applied; anything newer arrived while this command was
  /// working and has to reach the app through a reload. See
  /// [AppliedVersions.seedFromBuild].
  final DateTime builtBefore;

  /// Null when the app was not launched by this command (attach).
  final NativeLaunch? launch;

  NativePipelineAssembler({
    required this.workspace,
    required this.toolchain,
    required this.target,
    required this.configDevice,
    this.userBuildArgs = const [],
    required this.host,
    required this.pipeline,
    required this.logger,
    required this.builtBefore,
    this.launch,
  });

  /// What the running app says about the build it came from.
  ///
  /// Read at the top of [_assemble], because every flag list below is derived
  /// from it — the dev build included. `late final` rather than nullable: it is
  /// resolved before anything reads it, and a read that got there first would
  /// be a bug to fix, not a case to fall back from.
  late final BuildInfo _info;

  /// The bazel flags that produce the *dev* outputs: the dev config, the dev
  /// package config, the regenerated codegen sources.
  ///
  /// The defines come from the app rather than from a flag the user repeats,
  /// which is what makes them right on both routes in: the dev config's
  /// `dartDefines` are what the resident frontend_server replays as `-D` on
  /// every recompile, so a dev build that did not know the app's defines
  /// produces an app that loses them at the first reload.
  ///
  /// Deliberately not [BuildInfo.buildArgs]: the platform flags that value
  /// carries put a build in the app's *launch* configuration, and these outputs
  /// are read from the configuration this command builds them in.
  List<String> get _devArgs => [
    ...configDevice.buildArgs,
    ...dartDefineFlags(_info.dartDefines),
    ...userBuildArgs,
  ];

  /// The flags the running app says produced it, used by every bazel
  /// invocation that has to reach the app's own configuration.
  ///
  /// Distinct from [_devArgs], which builds the *dev* outputs — dev config,
  /// dev package config, regenerated codegen sources — in the top-level
  /// configuration. Keeping one list per purpose is what stops the tracked
  /// tree and the rebuilt tree from drifting apart when a user passes
  /// `--build-arg`.
  List<String> get _launchArgs => _info.buildArgs(extra: userBuildArgs);

  /// Assemble, or settle [ReloadPipeline.ready] with the reason it could not be.
  ///
  /// Never throws: a run whose reload pipeline failed still has a running app,
  /// and the failure belongs in the gate — where the next `app.hotReload` reads
  /// it — rather than unwinding a session that is otherwise fine.
  Future<void> assemble() async {
    // Cleared at the top of every attempt and re-armed only by the one failure
    // below that another attempt can get past, so `awaitingAssembly` never
    // outlives the state it describes — a pipeline that assembled would
    // otherwise go on telling the watcher it owed a build for the rest of the
    // run.
    pipeline.reassemble = null;
    try {
      await _assemble();
    } catch (e) {
      // A `daemon.shutdown` is answered the moment it lands, and the teardown
      // it runs disconnects the VM service this is in the middle of reading.
      // The failure that produces describes the shutdown, not the pipeline, so
      // it is settled as one: reporting a broken frontend server here names the
      // wrong cause, at a severity the run does not have — it is ending anyway.
      //
      // `teardown.hasRun`, not the shutdown signal: `performCleanup` disposes
      // first and signals after, so the signal is still unset in exactly the
      // window this is about — the one where the disposal already broke the
      // thing being read.
      if (host.teardown.hasRun) {
        pipeline.frontendServer = null;
        pipeline.ready.signalUnavailable(
          'The session shut down before the reload pipeline was assembled.',
        );
        return;
      }
      // The other way the VM service this was reading disappears, and the one
      // nothing on this side asked for: the app died. `attach` is where it
      // lands — it did not launch the app, so there is no process exit to
      // notice it by — and the window is real, between `app.started` and the
      // gate opening.
      //
      // Blaming the frontend server here is not merely vague, it is wrong in a
      // way the user can act on: the failure this catches is usually
      // `_readBuildInfo`'s, whose words are "an app that reaches its VM service
      // without one is not a build this pipeline can be assembled for" — so an
      // app that simply died is reported as one built the wrong way, and the
      // reader goes to fix a build that was fine.
      //
      // The client's own verdict, not a guess from the failure's text: it is
      // the thing that watched the socket close and re-dialled, and it kept the
      // cause. `isGone` false does not mean the app is alive — a re-dial can
      // still be deciding — so this only ever adds evidence for the death.
      final client = _firstVmClient();
      if (client != null && client.isGone) {
        pipeline.frontendServer = null;
        pipeline.ready.signalUnavailable(
          'The app went away while the reload pipeline was being assembled: '
          '${client.goneReason}',
        );
        return;
      }
      // A bazel command the pipeline needed, which bazel rejected. Reported as
      // itself rather than through the line below, which names the frontend
      // server — a component that is working, and in this case one that was
      // never even started. The reader's next move is their own build error,
      // not this tool.
      if (e is BazelInvocationFailure) {
        _reportDevBuildFailed(e);
        return;
      }
      logger.severe({
        'message': 'frontend_server_failed',
        'text':
            'The hot-reload pipeline could not be assembled: $e. Hot reload '
            'and hot restart are unavailable for this run; the app keeps '
            'running the code it launched with.',
        'error': '$e',
      });
      pipeline.frontendServer = null;
      pipeline.ready.signalUnavailable(
        'The hot-reload pipeline could not be assembled: $e',
      );
    }
  }

  /// Report a bazel command the pipeline needed and could not get, and leave
  /// the run able to ask for it again.
  ///
  /// This build reads the working tree, and the working tree can be broken:
  /// the app was launched from a build that succeeded seconds ago, and a
  /// developer who saves a typo while it is still coming up lands exactly here.
  /// Nothing about that is a verdict on the run — the same typo saved a minute
  /// later costs one failed reload, because `refreshGenerated`'s build failure
  /// is a `ReloadCompileFailed` and the next reload builds again.
  ///
  /// So it is armed rather than settled: [ReloadPipeline.reassemble] holds one
  /// more attempt, and the next reload request runs it. Nothing retries on its
  /// own, and nothing polls — the recovery event is a user event, the same one
  /// that drives every compile.
  ///
  /// `recoverable` is a field of its own, not a turn of phrase in `text`,
  /// because `--machine` mode drops `text` outright (see `logging.dart`): an
  /// IDE or agent driving this run would otherwise be told a build failed and
  /// never told whether the session it is holding is worth keeping. That is the
  /// same question a human reads the prose for.
  void _reportDevBuildFailed(BazelInvocationFailure failure) {
    logger.severe({
      'message': 'dev_build_failed',
      'text':
          'The Bazel build that hot reload needs — `bazel '
          '${failure.command}` — failed, so this run has no incremental '
          'compiler yet. The app keeps running the code it launched with. Fix '
          'the error below: the next hot reload builds again, and under '
          '`--watch` a saved Dart file is one.'
          '${failure.diagnostics.isEmpty ? '' : '\n${failure.diagnostics}'}',
      'command': failure.command,
      'diagnostics': failure.diagnostics,
      'recoverable': true,
    });
    pipeline.frontendServer = null;
    pipeline.reassemble = _assembleAgain;
    pipeline.ready.signalRetryable(
      'The Bazel build that hot reload needs (`bazel ${failure.command}`) '
      'failed, so there is no incremental compiler yet. Fix the error and '
      'reload again.',
    );
  }

  /// One more attempt, on an assembler of its own.
  ///
  /// A fresh instance because [_info] is `late final`: this one has already
  /// resolved the app's build record and cannot resolve it again. Every input
  /// is the same, [builtBefore] included — it describes the build the app is
  /// running, which is exactly as true now as it was then, and the file the
  /// user just fixed is stamped after it and so stays unseeded and pending.
  Future<void> _assembleAgain() async {
    await NativePipelineAssembler(
      workspace: workspace,
      toolchain: toolchain,
      target: target,
      configDevice: configDevice,
      userBuildArgs: userBuildArgs,
      host: host,
      pipeline: pipeline,
      logger: logger,
      builtBefore: builtBefore,
      launch: launch,
    ).assemble();
    // `_assemble` has two early returns that settle nothing — no session with a
    // VM service, and a device with no compiler config — and on the first
    // attempt the command's own backstop covers them. That backstop ran long
    // ago by the time this does, so the guarantee has to be made here: a gate
    // reopened for an attempt and left unsettled makes every later request wait
    // out the full timeout before answering "still starting up".
    if (!pipeline.ready.isSettled) {
      pipeline.ready.signalUnavailable(
        'Rebuilding the hot-reload inputs finished with nothing to reload: '
        'this run has no app with a VM service, or no incremental compiler '
        'for its device.',
      );
    }
  }

  Future<void> _assemble() async {
    final client = _firstVmClient();
    // No VM service is no app to reload, so there is nothing here to assemble
    // — the same condition [_appInstances] is empty under, decided before a
    // build is spent on it. The caller's gate fallback reports it.
    if (client == null) return;

    // Before the dev build, not after it: that build's flags come out of this.
    // The app's defines reach the dev config, whose `dartDefines` the resident
    // frontend_server replays on every recompile — read any later and the first
    // reload compiles against defines the app does not have.
    _info = await _readBuildInfo(client);

    // Build the flutter_application target directly to materialize its
    // DefaultInfo — the hot-reload `_dev_config.json` + dev
    // `package_config.json`. The platform wrapper (`:app_macos`) consumes the
    // flutter_application via providers, not files, so building it alone never
    // produces these. Using the app target's own outputs also keeps the dev
    // config's config-specific paths self-consistent.
    //
    // `info`, not `fine`: the root logger sits at `INFO`, so a `fine` record is
    // dropped before anything can read it — leaving the several seconds of
    // cquery and bazel build below completely silent, in a run that has already
    // said the app started. It is also the last thing logged before the build,
    // which makes it the event a test can edit the tree on.
    logger.info({
      'message': 'resolving_toolchain',
      'text': 'Building the hot-reload inputs for $target...',
      'target': target,
    });
    final devAppLabel = await bazelCqueryFlutterAppLabel(
      target,
      workspace: workspace,
      compilationMode: 'dbg',
      extraArgs: _devArgs,
    );
    if (devAppLabel == null) {
      throw DevToolException(
        'No flutter_application found in deps of $target.',
      );
    }
    // Checked, not discarded. A failed build otherwise flows on as an empty
    // output list, which `findDevConfig` reports as a missing
    // `_dev_config.json` and tells the user to "build with -c dbg" — a wrong
    // answer for a source file that simply did not compile. The build result is
    // the only place that distinguishes them.
    final devBuild = await bazelBuild(
      devAppLabel,
      workspace: workspace,
      compilationMode: 'dbg',
      extraArgs: _devArgs,
    );
    if (!devBuild.success) {
      throw devBuild.asFailure('build $devAppLabel');
    }
    final flutterAppOutputs = devBuild.outputFiles;
    // The build tells us the entrypoint + hot-reload layout via
    // _dev_config.json; we never infer them from package_config rootUri shapes.
    final devConfigPath = findDevConfig(flutterAppOutputs);
    if (devConfigPath == null) {
      throw DevToolException(
        'No _dev_config.json in flutter_application outputs '
        '(build with -c dbg).\nOutputs: $flutterAppOutputs',
      );
    }
    final devConfig = parseDevConfig(devConfigPath);
    // Everything below drives a compiler off these paths. A path the build
    // declared and did not write fails here, naming the file, rather than as
    // a frontend_server exit 255 several steps later.
    requireDeclaredFilesExist(devConfig);
    // The dev package_config points a source-assembled app package at the live
    // source + generated roots via filesystemScheme; for non-codegen apps it
    // equals the build config.
    //
    // Always the dev one, named rather than discovered among the build outputs.
    // The app's DefaultInfo carries two outputs ending in `package_config.json`
    // — the build's `<name>.package_config.json` and the dev
    // `<name>.dev_package_config.json` — so a suffix match picks between them
    // by list order. The build one maps `package:` URIs into the frozen
    // `.pkgsrcs` tree the bundle was assembled from, so a compiler pointed at
    // it reads a copy of the source instead of the source: every edit compiles
    // cleanly, reports a successful reload, and changes nothing on screen.
    //
    // The empty case below cannot arise on native: `flutter_application.bzl`
    // writes this `_dev_config.json` only inside `if is_debug and
    // compilation.dev_package_config != None`, and the value it writes there is
    // a `File.path`, which is never the empty string. Web is the path where the
    // empty state is real — its rule emits the dev config whether or not the
    // file exists and writes `""` for the absent case
    // (`flutter_web_application.bzl`) — which is why the equivalent check there
    // guards a value this one cannot produce.
    if (devConfig.devPackageConfig.isEmpty) {
      throw DevToolException(
        'The build emitted a dev config at $devConfigPath with no '
        'devPackageConfig. Without it this run has no package config that '
        'resolves to live sources, and every hot reload would recompile the '
        'copy of the tree the bundle was assembled from.',
      );
    }
    final packageConfig = await _stablePackageConfig(
      devConfig.devPackageConfig,
    );

    // The registrant filtered for the platform the app is RUNNING on, not
    // for the host platform this dev build resolved in — the two differ on
    // an iOS run driven from a macOS host, and feeding the host's registers
    // the wrong plugin set after a hot restart, silently.
    final registrant = devConfig.registrantFor(_info.targetPlatform);
    final compilerConfig = configDevice.createCompilerConfig(
      toolchain,
      fileSystemRoots: devConfig.filesystemRoots,
      fileSystemScheme: devConfig.filesystemScheme,
      // The app's own record travels with them. `flutter_compile_kernel` bakes
      // it into the launch build only, and this compiler produces every dill
      // the app runs after a hot restart — so without it a restart is where the
      // app stops being able to say which build it came from. It comes from the
      // running app rather than from `devConfig.dartDefines`, which the
      // host-configured dev build wrote: replaying that value would have the app
      // report the dev pipeline's configuration as its launch truth.
      dartDefines: [...devConfig.dartDefines, _info.defineAssignment],
      // A `file://` URI, deliberately, where the build's own kernel compile
      // names its registrant `org-dartlang-root:///<exec path>`
      // (`flutter_compile.bzl`). The two never have to agree. The engine reads
      // `flutter.dart_plugin_registrant` out of whichever dill is *running* and
      // looks that exact string up as a library, so each kernel only has to be
      // internally consistent — and after a hot restart the running dill is
      // always one this compiler produced.
      //
      // `file://` is the one spelling valid in both configurations this
      // compiler starts in. A source-assembled (codegen) app mounts
      // `filesystemRoots` under the `org-dartlang-app` scheme; a plain app has
      // none — `e2e/macos_example`'s dev config carries `filesystemRoots: []`,
      // and `NativeCompilerConfig` gates the scheme flag on that list — so a
      // scheme URI would resolve to nothing there. The build's
      // `org-dartlang-root` is never mounted in this process, so matching the
      // build is not an option either.
      //
      // The front end does not rewrite a `--source` URI into the mounted
      // scheme, so `--source` and the `-D` stay one string and the engine's
      // lookup matches. Upstream converts here (`flutter_tools`'
      // `toMultiRootPath`), trying a `package:` URI first, which keeps every
      // reference to a file under a single URI identity in the incremental
      // compiler's state. Nothing else refers to the registrant — no import, no
      // invalidation, and it sits outside every package's `libRoot`, so it is
      // not reachable as a `package:` URI — leaving no second identity to
      // collide with.
      dartPluginRegistrantUri: registrant.isEmpty
          ? ''
          : Uri.file(registrant).toString(),
      enableExperiments: devConfig.enableExperiments,
    );
    // A device with no compiler config has no incremental compiler, so there is
    // nothing to assemble. The gate's fallback in the caller reports it.
    if (compilerConfig == null) return;

    pipeline.entrypoint = devConfig.appEntrypoint;

    // Seed the per-file applied state. The resolver keys every source file by
    // its `package:` URI — which is how the frontend_server keys those
    // libraries — so an invalidation actually hits them, and seeding is what
    // makes the first reload send only what has changed since.
    //
    // What it has to describe is the source the running app was built from,
    // which is not the same as whatever is on disk right now. This runs while
    // the app is already up and answering agent commands, so a driver can edit
    // a file between `app.started` and here — and this snapshot would contain
    // that edit. Hence [builtBefore]: anything stamped after it is left
    // unseeded, so the first reload picks it up.
    final resolver = pipeline.resolver = PackageUriResolver(
      workspaceRoot: workspace,
      sourcePackages: devConfig.sourcePackages,
    );
    final workspaceView = pipeline.workspaceView = Workspace(
      resolver: resolver,
      generatedFiles: devConfig.generatedFileUris,
    );
    final initialSnapshot = workspaceView.snapshot();
    pipeline.appliedVersions.seedFromBuild(
      initialSnapshot,
      builtBefore: builtBefore,
      generated: devConfig.generatedFileUris.keys.toSet(),
    );

    // A `recompile` is a delta against a compile that has to have happened.
    //
    // An entrypoint the dev config left empty is reported here rather than
    // thrown, because a run that cannot hot reload should still be a run: it
    // keeps DevTools, the keyboard, the watcher and the app's output, and 'r'
    // answers out of the gate with the reason below.
    if (pipeline.entrypoint.isEmpty) {
      _reportNoCompiler(
        configDevice,
        'The dev config named no entrypoint, so there is nothing to compile '
        'against.',
      );
      return;
    }

    // One compiler per app, never one shared between them.
    //
    // A `frontend_server` decides which *dependent* libraries to re-emit by
    // comparing against its own accepted state. Share one between two apps that
    // can be reloaded independently and the first app's reload teaches it that
    // those dependents are current, after which no invalidation can make it
    // re-derive them for the app that never got that delta — and no per-file
    // source record can even name them, because their own bytes never changed.
    // See [SessionReloader]. Each unit copies the seeded baseline and diverges
    // from there.
    //
    // Spawned concurrently: they are separate processes and their initial
    // compiles genuinely run in parallel. Within each unit the order
    // `start → teardown.add → compile → accept` is preserved, so a
    // `daemon.shutdown` racing assembly still shuts down every compiler that
    // has started.
    final units = await Future.wait([
      for (final session in host.sessions)
        if (session.vmClient != null)
          _assembleUnit(session, compilerConfig, packageConfig),
    ]);
    // Null means the compiler itself is gone — not that the source failed to
    // compile, which is a state the unit carries and recovers from. All or
    // nothing on that one: every unit gets identical inputs, so a compiler
    // that could not survive its first compile is a property of the toolchain
    // rather than of one device, and a pipeline that could reload some devices
    // and silently not others is the very thing this shape exists to prevent.
    if (units.any((u) => u == null)) {
      await Future.wait([
        for (final u in units)
          if (u != null) u.shutdown(),
      ]);
      pipeline.ready.signalUnavailable(
        'The incremental compiler stopped running during the first compile, '
        'so this run has no hot reload. The app keeps running the code it '
        'launched with; restart the run to get hot reload back.',
      );
      pipeline.strategy = configDevice.createReloadStrategy();
      return;
    }

    final assetsDir = await _wireAssets();

    // For codegen apps, rebuild the flutter_application via bazel before each
    // reload/restart so edits to codegen inputs are regenerated. Null for
    // non-codegen apps → no bazel build on a Dart edit (today's instant path).
    if (devConfig.generatedSourceUris.isNotEmpty) {
      pipeline.refreshGenerated = () async => (await bazelBuild(
        devAppLabel,
        workspace: workspace,
        compilationMode: 'dbg',
        extraArgs: _devArgs,
      )).success;
    }

    // Never empty: a session with no VM client is exactly the case the top of
    // this method already returned on, and nothing between the two adds or
    // clears one.
    final orchestrator = pipeline.orchestrator = ReloadOrchestrator(
      workspace: workspaceView,
      units: [for (final u in units) u!],
      entrypoint: pipeline.entrypoint,
      refreshGenerated: pipeline.refreshGenerated,
    );

    await _wireRelauncher(orchestrator, assetsDir);

    pipeline.strategy = configDevice.createReloadStrategy();
    // What is true, not what was hoped for. A unit whose first compile failed
    // has a running compiler and a reload path, and saying "ready for
    // incremental compilation" over the top of the failure reported seconds
    // earlier is how a user concludes the failure was harmless.
    final unbaselined = [
      for (final u in units)
        if (u!.baselineFailure != null) u,
    ];
    logger.info({
      'message': 'frontend_server_ready',
      'text': unbaselined.isEmpty
          ? 'Frontend server ready for incremental compilation.'
          : 'Frontend server ready, but the first compile of the working tree '
                'failed for ${unbaselined.map((u) => u.id).join(', ')}. Fix the '
                'error above and save: the next reload compiles again.',
      if (unbaselined.isNotEmpty)
        'unbaselined': [for (final u in unbaselined) u.id],
    });
    // Last statement of the success path, on purpose: a gate opened with
    // anything still to run answers the next reload out of a half-built
    // pipeline, and names the wrong thing when it fails.
    pipeline.ready.signalReady();
  }

  /// Any one session's VM service, which is the one this asks about the build.
  ///
  /// One answer stands for all of them: a multi-device run launches every
  /// device from a single build, so they cannot disagree about what produced
  /// them. Null when no session has a VM service at all.
  VmServiceClient? _firstVmClient() {
    for (final session in host.sessions) {
      final client = session.vmClient;
      if (client != null) return client;
    }
    return null;
  }

  /// Ask the app which build it came from, and refuse the ones no reload
  /// pipeline can be built for.
  ///
  /// Both refusals are the app's own report, not a guess about it: an app with
  /// no record leaves no way to tell which tree backs it, and an app that is
  /// not `-c dbg` has no JIT kernel to send a delta to. `assemble` turns either
  /// into an unavailable gate, so the run continues without hot reload rather
  /// than with a pipeline aimed at the wrong build.
  Future<BuildInfo> _readBuildInfo(VmServiceClient client) async {
    // Waited for, not assumed: this runs the moment the VM service answers,
    // which on an iOS simulator is before the app's own `main()` has reached
    // `registerRulesFlutterAgentExtensions`. Calling straight through gets
    // `-32601 Unknown method`, which `assemble` turns into a permanently
    // unavailable gate — every later reload in the run reporting a frontend
    // server that could not start, with the app running fine beside it.
    if (!await client.waitForServiceExtension(buildInfoExtension)) {
      throw DevToolException(
        'the running app never registered $buildInfoExtension. A -c dbg '
        'flutter_application registers it before `main()`, so an app that '
        'reaches its VM service without one is not a build this pipeline '
        'can be assembled for.',
      );
    }
    // An app that HAS no record says so itself, and `readBuildInfo` throws
    // carrying the app's own words, which are more specific than anything this
    // side could compose.
    // Null is the other thing: the extension answered, and answered with no
    // payload at all. No app the rules build does that, so it is a protocol
    // fault rather than a missing record, and claiming the latter would name
    // the wrong cause.
    final info = await readBuildInfo(client);
    if (info == null) {
      throw DevToolException(
        'the running app answered $buildInfoExtension with an empty payload. '
        'That is not an app without a record — one of those refuses by name '
        '— so the connection or the app is misbehaving rather than being the '
        'wrong kind of build.',
      );
    }
    if (info.compilationMode != 'dbg') {
      throw DevToolException(
        'the running app reports compilationMode "${info.compilationMode}". '
        'Hot reload needs a -c dbg build.',
      );
    }
    return info;
  }

  /// Point each app's VM client at the `flutter_assets` tree the running app
  /// was actually assembled from, and start tracking it.
  ///
  /// The path comes from the app, not from a build of our own. A platform
  /// wrapper reaches the `flutter_application` through a split transition, so
  /// the app's tree lives in a configuration (`…-ST-<hash>`) no command line
  /// can name, while the bare dev build this pipeline also does lands in the
  /// top-level one.
  ///
  /// Picking it off the dev build's own output list — the first entry ending
  /// in `flutter_assets` — works only by accident: `bazelBuild` derives its
  /// outputs from `cquery <label> --output=files`, which lists the target in
  /// *every* configuration the Bazel server has analysed, and because a session
  /// builds the wrapper first the transitioned tree usually comes back first.
  /// On a server that has only ever analysed the bare target — attach against a
  /// cold server — the list holds the top-level tree alone, and the pipeline
  /// then rebuilds through the launch target while diffing a directory that
  /// never changes. Nothing reports an error; the edit simply does not arrive.
  /// Skyframe's analysis order is not a contract.
  ///
  /// The cquery through the launch target is the cross-check, not the source.
  /// It answers "is the tree the app claims reachable from the target the user
  /// named, under the flags the app says produced it" — by membership, because
  /// an Android wrapper reaches the application in several configurations at
  /// once and only the app knows which one it is.
  ///
  /// Returns the directory.
  Future<String> _wireAssets() async {
    final candidates = await bazelCqueryFlutterAppFiles(
      target,
      workspace: workspace,
      compilationMode: 'dbg',
      extraArgs: _launchArgs,
    );
    final queried = await bazelCqueryFlutterAppLabel(
      target,
      workspace: workspace,
      compilationMode: 'dbg',
      extraArgs: _launchArgs,
    );
    final resolved = resolveAssetsDir(
      info: _info,
      candidates: candidates,
      queriedLabel: queried,
      target: target,
      appliedArgs: _launchArgs,
    );

    // Absolutized here and nowhere else: the resolved path stays in bazel's
    // workspace-relative forward-slash form for the comparison above, which is
    // the form both sides are written in.
    final assetsDir = '$workspace/$resolved';
    for (final session in host.sessions) {
      session.vmClient?.assetDirectory = assetsDir;
      session.vmClient?.devicePathsAreWindows = session.device.usesWindowsPaths;
    }
    // Pointing the engine at this directory is what makes an asset edit visible
    // without reinstalling the app, so the same path the restart hands to
    // `runInView` is the one the tracker watches. Nothing derives it a second
    // time.
    pipeline.assetTracker = AssetTracker(
      AssetBundle(directory: assetsDir, workspaceRoot: workspace),
      builtBefore: builtBefore,
    );
    pipeline.rebuildAssets = _rebuildBundle;
    return assetsDir;
  }

  /// Rebuild whatever produces the bundle the app is actually running.
  ///
  /// The launch target, not `devAppLabel`: a platform rule reaches the
  /// flutter_application through a transition, so the tree the tracker watches
  /// lives in the *transitioned* configuration. Building the flutter_application
  /// on its own writes the top-level one instead and leaves that directory
  /// exactly as it was, so the rebuild reports success, the diff finds nothing
  /// changed, and the edit is silently dropped. With no launch of our own there
  /// is no transitioned configuration to reproduce, so the dev one is the only
  /// one there is.
  Future<bool> _rebuildBundle() async {
    final r = await bazelBuild(
      target,
      workspace: workspace,
      compilationMode: 'dbg',
      extraArgs: _launchArgs,
    );
    return r.success;
  }

  /// Arm the native-libs relauncher, if this command launched the app and the
  /// bundle carries loose native libraries at all.
  Future<void> _wireRelauncher(
    ReloadOrchestrator orchestrator,
    String assetsDir,
  ) async {
    final launched = launch;
    // Nothing to relaunch that is ours: attach never started the process, and
    // stopping it would be taking away the app the user asked us to observe.
    if (launched == null) return;
    // A hot restart cannot replace dlopened native libraries. Record the
    // launched bundle's fingerprint; app.restart rebuilds and, when it changed,
    // relaunches the process instead of restarting the isolate. Apps with no
    // loose native libraries skip all of this and keep the instant restart path.
    final fingerprint = await nativeLibsFingerprint(launched.appFile);
    if (fingerprint.isEmpty) return;
    final relauncher = Relauncher(
      appFile: launched.appFile,
      rebuild: _rebuildBundle,
      sessions: host.sessions,
      protocol: host.protocol,
      orchestrator: orchestrator,
      assetsDir: assetsDir,
      logger: logger,
      liveFingerprint: fingerprint,
    );
    pipeline.relaunchIfNativeLibsChanged = relauncher.relaunchIfNeeded;
  }

  /// The dev package_config, repointed off Bazel's per-command execroot forest.
  ///
  /// See [stabilizePackageRoots]. Done once per command rather than per device:
  /// every compiler this pipeline starts reads the same packages, and the
  /// rewritten copy is immutable once written.
  Future<String> _stablePackageConfig(String buildEmitted) async {
    final dir = await createTempDir('flutter_pkgcfg_');
    await host.teardown.add(() => deleteTempDir(dir));
    final stabilized = stabilizePackageRoots(buildEmitted, into: dir);
    logger.info({
      'message': 'package_roots_stabilized',
      'text':
          'Repointed ${stabilized.repointed.length} package root(s) off '
          "Bazel's per-command execroot so a concurrent build cannot delete "
          'them mid-compile.',
      'packages': stabilized.repointed,
      'packageConfig': stabilized.path,
    });
    return stabilized.path;
  }

  /// Bring up one app's compiler and hand back the unit that drives it.
  ///
  /// Null only when the compiler is not running by the end — it died, or the
  /// session was torn down under it. A compile that merely *failed* still
  /// yields a unit, carrying the failure as [SessionReloader.baselineFailure].
  ///
  /// A first compile is not different in kind from any later one: it reads the
  /// working tree, and the working tree can be broken — mid-save, mid-`bazel
  /// build`, or simply wrong. The pipeline declines to cache that for every
  /// other compile (`ReloadOrchestrator` discards a failed compile and the next
  /// reload re-derives it), and a failure here is not turned into a permanent
  /// verdict either.
  ///
  /// Nothing retries here. The compiler is kept, the failed compile is
  /// discarded exactly as a failed reload's would be, and the next compile
  /// this unit is asked for is the one that recovers it — driven by the next
  /// reload request, which is the same event that drives every other compile.
  /// After a failed initial `compile`, a `recompile` naming the corrected file
  /// answers with zero errors and a delta carrying the fix, with or without an
  /// intervening `reject`.
  ///
  /// The order inside is load-bearing: `start → teardown.add → compile →
  /// accept`, so a `daemon.shutdown` racing the initial compile still shuts
  /// this compiler down rather than leaving its subprocess and pipes holding
  /// the VM open.
  Future<SessionReloader?> _assembleUnit(
    DeviceSession session,
    CompilerConfig compilerConfig,
    String packageConfig,
  ) async {
    final fs = FrontendServer(
      dartaotruntimePath: toolchain.dartaotruntime,
      frontendServerPath: toolchain.frontendServer,
      config: compilerConfig,
      packageConfig: packageConfig,
    );
    await fs.start();
    await host.teardown.add(fs.shutdown);

    final initialResult = await fs.compile(pipeline.entrypoint);
    if (!initialResult.success) {
      // A compiler that is no longer running cannot be asked again, and that
      // is the only failure here nothing later can undo. Its teardown entry
      // stays registered — shutdown is idempotent — but waiting for
      // end-of-run would leave an idle subprocess for the whole session.
      // `recoverable` is a field of its own, not a turn of phrase in `text`,
      // because JSON mode drops `text` outright (see `logging.dart`) — so an
      // IDE or agent driving this run would otherwise be told a compile
      // failed and never told whether the session it is holding is worth
      // keeping. That is the same question a human reads the prose for.
      if (!fs.isRunning) {
        logger.severe({
          'message': 'initial_compile_failed',
          'text':
              'The incremental compiler stopped running during the first '
              'compile for ${session.appId}, so this run has no hot reload or '
              'hot restart. The app keeps running the code it launched with; '
              'restart the run to get them back.'
              '${initialResult.diagnostics.isEmpty ? '' : '\n${initialResult.diagnostics}'}',
          'diagnostics': initialResult.diagnostics,
          'appId': session.appId,
          'recoverable': false,
        });
        await fs.shutdown();
        return null;
      }
      logger.severe({
        'message': 'initial_compile_failed',
        'text':
            'The first compile of the working tree failed for '
            '${session.appId}. ${session.appId} keeps running the code it was '
            'built with, and hot reload stays available: fix the error below '
            'and save, and the next reload compiles again.'
            '${initialResult.diagnostics.isEmpty ? '' : '\n${initialResult.diagnostics}'}',
        'diagnostics': initialResult.diagnostics,
        'appId': session.appId,
        'recoverable': true,
      });
    }
    // Verdict either way, and the same one a failed *reload* compile gets:
    // accept only what the app can be said to be running. The app is running
    // its launch build, which a successful first compile reproduces and a
    // failed one does not, so a failure is discarded rather than committed —
    // leaving the compiler holding no unanswered verdict.
    if (initialResult.success) {
      fs.accept();
    } else {
      await fs.reject();
    }

    return SessionReloader(
      id: session.appId,
      compiler: hot_reload.FrontendServerCompiler(fs),
      // A copy of the build's baseline: every app starts out knowing exactly
      // what the build produced, and diverges from there as it is reloaded.
      //
      // Right even when the compile above failed: it describes the app, not
      // the compiler, and the app is running the build. The file that broke
      // the compile was edited after [builtBefore], so it was left unseeded
      // and is already pending — which is what makes the fix to it reach the
      // next reload's invalidation set without anything having to remember it.
      applied: AppliedVersions.from(pipeline.appliedVersions),
      app: hr.VmServiceAppInstance(
        id: session.appId,
        client: session.vmClient!,
        rpcTimeout: session.device.applyTimeout,
      ),
      baselineFailure: initialResult.success
          ? null
          : 'The first compile of the working tree failed and nothing has '
                'changed on disk since, so ${session.appId} is still running the '
                'code it was built with.'
                '${initialResult.diagnostics.isEmpty ? '' : '\n${initialResult.diagnostics}'}',
    );
  }

  /// Report that this run has no incremental compiler, and why.
  ///
  /// Always structural — a dev config with no entrypoint, a device with no
  /// compiler config — so `recoverable` is false and says so. It is carried
  /// even though it is constant: `--machine` mode drops `text`, and a client
  /// reading `initial_compile_failed` records has to be able to tell this one
  /// from the two that can come back.
  void _reportNoCompiler(Device configDevice, String reason) {
    logger.severe({
      'message': 'initial_compile_failed',
      'text':
          'Hot reload and hot restart are unavailable for this run.\n'
          '$reason',
      'diagnostics': reason,
      'recoverable': false,
    });
    pipeline.ready.signalUnavailable(reason);
    pipeline.strategy = configDevice.createReloadStrategy();
  }
}
