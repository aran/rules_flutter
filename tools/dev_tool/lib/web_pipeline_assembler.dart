/// Builds the DDC dev loop: the module server, DWDS, the web frontend server,
/// and the browser connection that turns into a VM service.
///
/// All of it before Chrome launches, and in that order for a reason. The module
/// server has to exist for Chrome to be pointed at it; the frontend server has
/// to exist before DWDS, because the debugger's expression evaluation *is* that
/// compiler and DWDS is handed it at construction; DWDS has to be initialised
/// for the injected client to have something to connect to; and the
/// `connectedApps` listener has to be attached before the browser can connect,
/// because it is a broadcast stream and anything it emits with no listener is
/// dropped. A browser that connects fast does exactly that — losing the
/// AppConnection, never sending `runMain()`, and leaving DWDS holding `main()`
/// back: a blank page forever with no diagnostics.
///
/// The session the listener needs does not exist yet when the listener is
/// attached, so it is handed a [Completer] the launch loop completes rather
/// than searching a list that would still be empty.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart'
    show ChromeConnection;

import 'bazel.dart';
import 'command_report.dart';
import 'compiler_config.dart';
import 'dev_tool_exception.dart';
import 'device.dart';
import 'frontend_server.dart';
import 'hot_reload/asset_bundle.dart';
import 'hot_reload/package_uri_resolver.dart';
import 'hot_reload/workspace.dart';
import 'logging.dart';
import 'outcome_renderer.dart';
import 'package_roots.dart';
import 'reload_pipeline.dart';
import 'reload_strategy.dart';
import 'run_plan.dart';
import 'session.dart';
import 'session_host.dart';
import 'temp_dir.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'vm_service_logs.dart';
import 'web_bootstrap.dart';
import 'web_expression_compiler.dart';
import 'web_module_server.dart';

/// The http form of a DDS websocket URI.
///
/// DDS advertises `ws://host:port/<authCode>/ws`; `VmServiceClient.connect`
/// wants the http root and appends `ws` itself. Mirrors flutter_tools'
/// `_httpUriFromWebsocketUri`.
Uri httpUriFromWebSocketUri(Uri wsUri) {
  const wsPath = '/ws';
  final path = wsUri.path.endsWith(wsPath)
      ? wsUri.path.substring(0, wsUri.path.length - 2)
      : wsUri.path;
  return wsUri.replace(
    scheme: wsUri.scheme == 'wss' ? 'https' : 'http',
    path: path,
  );
}

class WebPipelineAssembler {
  final RunPlan plan;
  final SessionHost host;
  final ReloadPipeline pipeline;

  /// The browser's session, completed by the launch loop. Awaited rather than
  /// looked up: the `connectedApps` listener is attached before that loop runs.
  final Completer<DeviceSession> webSession;

  /// Reports a failure found after the run is already live. A throw inside the
  /// `connectedApps` listener is an unhandled async error and the run carries on
  /// regardless, so it has to be recorded instead.
  final void Function(DevToolException) fail;

  /// The module server, once started. Nulled on the failure path, which is what
  /// makes the run's `finally` a no-op for it.
  WebModuleServer? moduleServer;

  /// Holds the generated web entrypoint (and the staged plugin registrant and
  /// agent extensions it imports) for the life of the run: it is the compiler's
  /// first `--filesystem-root`, so every recompile resolves
  /// `org-dartlang-app:/web_entrypoint.dart` out of it. Removed by the run on
  /// the way out, which is the only point at which nothing needs it.
  Directory? syntheticDirectory;

  /// When the build that produced this bundle started. See
  /// [AssetTracker.new] — an asset edited after it must not be baselined as
  /// what the app is already showing.
  final DateTime builtBefore;

  WebPipelineAssembler({
    required this.plan,
    required this.host,
    required this.pipeline,
    required this.webSession,
    required this.fail,
    required this.builtBefore,
  });

  /// Assemble, or — with `--allow-no-vm-service` — record why there is no dev
  /// loop and let the run serve the last build statically.
  Future<void> assemble(List<String> outputFiles) async {
    try {
      // Find dev config in build outputs (emitted by flutter_web_bundle in -c dbg).
      final devConfigPath = findDevConfig(outputFiles);
      if (devConfigPath == null) {
        throw DevToolException(
          'No _dev_config.json found in build outputs.\n'
          'Ensure you are building with -c dbg (debug mode).',
        );
      }

      plan.logger.fine({
        'message': 'parsing_dev_config',
        'text': 'Parsing dev config from $devConfigPath...',
        'path': devConfigPath,
      });
      final devConfig = parseDevConfig(devConfigPath);
      requireDeclaredFilesExist(devConfig);

      // Build web toolchain paths and find web output dir from build outputs.
      final webToolchain = buildWebToolchainFromOutputs(
        outputFiles,
        devConfig,
      );
      final webOutputDir = findWebOutputDir(outputFiles);

      // The page's boot path comes from the build, not from here. A dev config
      // without it is a rules/dev-tool version skew, and the alternative to
      // saying so is generating a bootstrap that ignores the target's template
      // and every `web_defines` entry in it.
      if (devConfig.flutterBootstrapJs.isEmpty) {
        throw DevToolException(
          'The dev config at $devConfigPath names no flutter_bootstrap.js.\n'
          'The build substitutes that file from the target\'s bootstrap '
          'template; without it the page has nothing to boot. The app and this '
          'dev tool were built from different revisions of rules_flutter.',
        );
      }

      // The BUILD package_config, named by the build rather than picked out of
      // the outputs by filename. Two of them end in `package_config.json` — the
      // build's and the dev one — and matching on the suffix would choose
      // between them by the order `bazel cquery --output=files` happens to
      // print, which is the dev one. For a source-assembled (codegen) app that
      // is the wrong answer for this consumer: its `rootUri`s are
      // `<filesystemScheme>:///<lib_root>`, and DWDS resolves a `package:` URI
      // through this config only to open the result as a file —
      // `Uri.toFilePath()` throws `Cannot extract a file path from a
      // org-dartlang-app URI`, so every first-party library shows a blank
      // source pane in the debugger.
      //
      // The compiler below wants the opposite config, and gets it by name too.
      // Neither is "the" package config, which is exactly why neither is
      // discovered.
      if (devConfig.buildPackageConfig.isEmpty) {
        throw DevToolException(
          'The dev config at $devConfigPath names no buildPackageConfig.\n'
          'DWDS resolves every package: URI through it to read the source off '
          'disk; without it the debugger can show no source at all. The app '
          'and this dev tool were built from different revisions of '
          'rules_flutter.',
        );
      }
      final packageConfig = devConfig.buildPackageConfig;

      // Generate synthetic web_entrypoint.dart with bootstrapEngine() + plugin registrant.
      final syntheticDir = syntheticDirectory = await createTempDir(
        'flutter_ddc_',
      );
      final syntheticMain = File(
        p.join(syntheticDir.path, 'web_entrypoint.dart'),
      );

      // Stage the build's web plugin registrant next to the synthetic
      // entrypoint and import it relatively — exactly what Flutter's
      // `resident_web_runner` does (`web_plugin_registrant.dart` written
      // into the same generated-entrypoint directory). `syntheticDir` is the
      // first `--filesystem-root`, so `org-dartlang-app:/web_entrypoint.dart`
      // resolves the sibling import there. The registrant's own
      // `package:` imports resolve through the frontend server's
      // package_config like any other library.
      //
      // The path is named explicitly by the build in `_dev_config.json`;
      // nothing here derives or searches for a filename.
      String? pluginRegistrantImport;
      if (devConfig.webPluginRegistrant.isNotEmpty) {
        const stagedName = 'web_plugin_registrant.dart';
        File(p.join(syntheticDir.path, stagedName)).writeAsStringSync(
          File(devConfig.webPluginRegistrant).readAsStringSync(),
        );
        pluginRegistrantImport = stagedName;
      }

      // The agent extensions ride in the same way, and for the same reason:
      // the entrypoint that imports them is generated here, so the file has
      // to be somewhere that entrypoint can name. Native gets this from the
      // engine's pre-main registrant hook instead — there is no such hook on
      // web, so registration happens inside the generated `main()`.
      String? agentExtensionsImport;
      if (devConfig.agentExtensions.isNotEmpty) {
        const stagedName = 'agent_extensions.dart';
        File(
          p.join(syntheticDir.path, stagedName),
        ).writeAsStringSync(File(devConfig.agentExtensions).readAsStringSync());
        agentExtensionsImport = stagedName;
      }

      syntheticMain.writeAsStringSync(
        generateSyntheticMainDart(
          appEntrypoint: devConfig.appEntrypoint,
          pluginRegistrantEntrypoint: pluginRegistrantImport,
          agentExtensionsEntrypoint: agentExtensionsImport,
        ),
      );

      pipeline.entrypoint = 'org-dartlang-app:/web_entrypoint.dart';

      // Create the module server with workspace root and package config
      // for DWDS source resolution. Held in a non-null local as well: the
      // browser-connection listener wired below outlives this block, and the
      // captured field is nulled on the failure path.
      final moduleServer = WebModuleServer(
        webToolchain: webToolchain,
        buildOutputDir: webOutputDir,
        entrypointFilename: 'web_entrypoint.dart',
        flutterBootstrapJsPath: devConfig.flutterBootstrapJs,
        dartExecutable: plan.toolchain.dart,
        workspaceRoot: plan.workspace,
        packageConfigPath: packageConfig,
        nativeNullAssertions: devConfig.nativeNullAssertions,
        options: plan.webServer,
      );
      this.moduleServer = moduleServer;

      // Write first-upload bootstrap files to in-memory server.
      moduleServer.writeFile(
        'manifest.json',
        '{"info":"manifest not generated in run mode."}',
      );
      moduleServer.writeFile(
        'flutter_service_worker.js',
        '// Service worker not loaded in run mode.',
      );

      // Start HTTP server first (without DWDS) to get the server URI.
      final serverUri = await moduleServer.start();

      // Set up frontend server with web compiler config + filesystem roots.
      // For a source-assembled (codegen) app, add the dev multi-root dirs
      // (live source + generated bazel-out) so package: URIs resolve to live
      // edits + regenerated parts. devConfig roots are empty for non-codegen
      // apps.
      //
      // Always the dev package_config, never the build's. The build's maps
      // `package:` URIs into the frozen `.pkgsrcs` tree the bundle was
      // assembled from, so a dev loop compiling through it would read a copy of
      // the source instead of the source: every edit would compile cleanly,
      // report a successful reload, and change nothing on screen. A fallback to
      // it when `devPackageConfig` is empty cannot fire — the rule declares and
      // writes the file under the same `is_debug` condition that decides
      // whether this `_dev_config.json` is emitted at all — and would be silent
      // if it ever did.
      if (devConfig.devPackageConfig.isEmpty) {
        throw DevToolException(
          'The build emitted a dev config at $devConfigPath with no '
          'devPackageConfig. Without it the dev loop has no package config '
          'that resolves to live sources, and every hot reload would '
          'recompile the copy of the tree the bundle was assembled from.',
        );
      }
      // Repointed off Bazel's per-command execroot forest, so a concurrent build
      // cannot delete the package roots this compiler reads. See
      // [stabilizePackageRoots]; the build-emitted file is left untouched.
      // Its own directory, deliberately not [syntheticDir]: that one is a
      // `--filesystem-root`, so anything written into it becomes addressable as
      // `org-dartlang-app:///<name>` and would collide with the live source tree.
      final packageConfigDir = await createTempDir('flutter_pkgcfg_');
      await host.teardown.add(() => deleteTempDir(packageConfigDir));
      final stabilized = stabilizePackageRoots(
        devConfig.devPackageConfig,
        into: packageConfigDir,
      );
      plan.logger.info({
        'message': 'package_roots_stabilized',
        'text':
            'Repointed ${stabilized.repointed.length} package root(s) off '
            "Bazel's per-command execroot so a concurrent build cannot delete "
            'them mid-compile.',
        'packages': stabilized.repointed,
        'packageConfig': stabilized.path,
      });
      final webPackageConfig = stabilized.path;
      final compilerConfig = WebCompilerConfig(
        webToolchain: webToolchain,
        fileSystemRoots: [
          syntheticDir.path,
          plan.workspace,
          ...devConfig.filesystemRoots,
        ],
        dartDefines: devConfig.dartDefines,
        enableExperiments: devConfig.enableExperiments,
      );
      final fs = pipeline.frontendServer = FrontendServer(
        dartaotruntimePath: devConfig.dartaotruntime,
        frontendServerPath: devConfig.frontendServer,
        config: compilerConfig,
        packageConfig: webPackageConfig,
      );
      await fs.start();
      await host.teardown.add(fs.shutdown);

      // DWDS after the compiler, not before: the debugger's expression
      // evaluation is that same compiler, asked a different question, and
      // handing it over at construction is what makes the flag real rather than
      // a value nobody reads. Nothing in DWDS's setup needs the compiler to have
      // compiled anything yet, and nothing in the compiler needs DWDS.
      //
      // Chrome has not launched either — the connection callback is lazy.
      final webDevice = plan.devices.first as WebDevice;
      await moduleServer.initDwds(
        chromeConnection: () async {
          final cdpPort = webDevice.cdpPort;
          if (cdpPort == null) {
            throw StateError('Chrome CDP port not yet discovered');
          }
          return ChromeConnection('localhost', cdpPort);
        },
        serverUri: serverUri,
        expressionCompiler: plan.webOptions!.enableExpressionEvaluation
            ? FrontendServerExpressionCompiler(fs)
            : null,
      );

      // What the page is about to be running, read BEFORE the compile that
      // produces it — which is the whole of the ordering here.
      //
      // The resolver keys every source file (app + deps) by its `package:` URI
      // — which is how the frontend_server keys those libraries (the synthetic
      // web entrypoint imports them via `package:` through the dev
      // package_config), so an invalidation actually hits them.
      //
      // Deliberately NOT [AppliedVersions.seedFromBuild], which native uses.
      // The two are answering the same question about different moments. On
      // native the app is already running the bazel-built kernel and the
      // compiler's first compile is only a baseline for deltas, so the truth is
      // the bazel build and `builtBefore` is the cutoff. Here the page has not
      // launched — Chrome starts after this whole assembly — and what it first
      // loads is exactly `initialResult.dillPath` below. The truth is therefore
      // this compile, and the compile reads live sources: the dev package
      // config resolves `package:` URIs to the live tree, not to the frozen
      // `.pkgsrcs` the bundle was assembled from.
      //
      // Which is why the snapshot is cut here rather than after the compile.
      // Taken afterwards it would record the *post-edit* version of a file
      // edited while the compiler was reading — the compile may well have
      // missed it, and nothing would say so: the first reload would find no
      // change, and no watch event would cover it either, because the watcher
      // is started later still. Cut beforehand, the worst case is a file the
      // compile did pick up being re-sent once. `builtBefore` is not the cutoff
      // for any of this; it governs the asset tree below, which really is
      // bazel-built.
      final res = pipeline.resolver = PackageUriResolver(
        workspaceRoot: plan.workspace,
        sourcePackages: devConfig.sourcePackages,
      );
      final ws = pipeline.workspaceView = Workspace(
        resolver: res,
        generatedFiles: devConfig.generatedFileUris,
      );
      final initialSnap = ws.snapshot();

      // Compile the synthetic entrypoint.
      //
      // A failure here is not different in kind from any later compile: it
      // reads the working tree, and the working tree can be broken — mid-save,
      // mid-`bazel build`, or simply wrong. Native treats it the same way, on
      // the same reasoning: a compile that failed can be asked again, a
      // compiler that is gone cannot.
      //
      // What web does NOT share is what the failure costs. Native's app is
      // already running the build it launched with, so the session keeps a
      // working app; here Chrome has not opened yet and what it will load is this
      // compile's own output, so the page comes up with nothing on it. That is
      // why the recovery is a restart rather than a reload, and why it navigates
      // the page — see [ReloadPipeline.webBaselineFailure] and
      // [DwdsReloadStrategy.loadFirstProgram].
      final initialResult = await fs.compile(pipeline.entrypoint);
      if (!initialResult.success) {
        // The one failure here that nothing later can undo. `recoverable` is a
        // field of its own rather than a turn of phrase in `text`, because JSON
        // mode drops `text` outright (see `logging.dart`) — an IDE or agent
        // driving this run would otherwise be told a compile failed and never
        // told whether the session it is holding is worth keeping.
        if (!fs.isRunning) {
          plan.logger.severe({
            'message': 'initial_compile_failed',
            'text':
                'The incremental compiler stopped running during the first '
                'compile, so this run has no hot reload or hot restart and the '
                'browser has no app to show. Restart the run.'
                '${initialResult.diagnostics.isEmpty ? '' : '\n${initialResult.diagnostics}'}',
            'diagnostics': initialResult.diagnostics,
            'recoverable': false,
          });
          throw DevToolException(
            'The compiler stopped running during the initial DDC compile.\n'
            '${initialResult.diagnostics}',
          );
        }
        // The verdict a failed compile is owed, and the same one a failed reload
        // compile gets: accept only what the page can be said to be running,
        // which is nothing.
        await fs.reject();
        plan.logger.severe({
          'message': 'initial_compile_failed',
          'text':
              'The first compile of the working tree failed, so the browser '
              'page has no app on it yet. The session keeps its compiler: fix '
              'the error below and save, and the next reload compiles the whole '
              'program and loads it.'
              '${initialResult.diagnostics.isEmpty ? '' : '\n${initialResult.diagnostics}'}',
          'diagnostics': initialResult.diagnostics,
          'recoverable': true,
        });
        // What every later request reads to know the page holds no program.
        // `appliedVersions` is deliberately left empty alongside it, so every
        // file is still pending and the recovering compile reads all of them.
        pipeline.webBaselineFailure =
            'The first compile of the working tree failed and the page has been '
            'showing nothing since.'
            '${initialResult.diagnostics.isEmpty ? '' : '\n${initialResult.diagnostics}'}';
      } else {
        fs.accept();
        // The first compile produces every module, so it defines the
        // program rather than adding to one.
        moduleServer.updateModules(initialResult.dillPath, full: true);
        // Committed only now: the baseline describes code the page can actually
        // load, and until `updateModules` there is none.
        pipeline.appliedVersions.markApplied(
          initialSnap,
          files: initialSnap.fileUris.toSet(),
        );
      }
      // One rebuild of the web bundle, shared by the two reasons to want
      // one: regenerating a codegen app's sources, and refreshing the asset
      // tree. Both produce the same outputs from the same target, so they
      // must not be two builds that can disagree.
      //
      // `plan.extraArgs`, which includes `--build-arg`: the *initial* build
      // passes it, so the output directory the tracker watches lives in that
      // configuration, and rebuilding without it writes a different one — a
      // build that reports success, a diff that finds nothing, and a dropped
      // edit. The native `_rebuildBundle` comment describes the same family of
      // mistake.
      Future<bool> rebuildWebBundle() async {
        final r = await bazelBuild(
          plan.target,
          workspace: plan.workspace,
          compilationMode: 'dbg',
          extraArgs: plan.extraArgs,
        );
        return r.success;
      }

      // Codegen apps: rebuild generated sources via bazel before each web
      // reload (regenerates `.g.dart`, keeps the execroot forest intact).
      if (devConfig.generatedSourceUris.isNotEmpty) {
        pipeline.refreshGenerated = rebuildWebBundle;
      }

      // The module server serves `assets/` straight off this directory on
      // every request, so a rebuilt asset is on the wire the moment it is on
      // disk. Tracking it is what turns that into a reload: it says whether
      // a build is worth running, and which archive paths the page has to be
      // told to stop trusting its caches for.
      pipeline.assetTracker = AssetTracker(
        AssetBundle(
          directory: p.join(webOutputDir, 'assets'),
          workspaceRoot: plan.workspace,
        ),
        builtBefore: builtBefore,
      );
      pipeline.rebuildAssets = rebuildWebBundle;
      plan.logger.info({
        'message': 'frontend_server_ready',
        'text':
            'DDC frontend server ready. Module server at ${moduleServer.uri}',
        // Structured as well as prose: this is the base URL every web
        // asset is served from, so a client driving the tool (or a test)
        // can address the server without parsing the sentence above.
        'uri': moduleServer.uri.toString(),
      });

      // Set module server on WebDevice before launch.
      webDevice.setModuleServer(moduleServer);

      // Wire the browser connection BEFORE Chrome launches. `connectedApps`
      // is a broadcast stream, so anything it emits with no listener
      // attached is dropped on the floor — and a browser that connects fast
      // does exactly that, losing the AppConnection, never sending `runMain()`,
      // and leaving DWDS holding `main()` back: a blank page forever with no
      // diagnostics. Nothing here needs Chrome to exist yet.
      final connectedApps = moduleServer.connectedApps;
      if (connectedApps == null) {
        // `initDwds` either wires DWDS up or throws, so a live module server
        // always has this stream. Reaching here means that invariant broke.
        // Skipping the block instead would leave the run with no reload
        // strategy, no VM service and no `markDebugReady`, and say nothing
        // about any of it.
        throw StateError(
          'The web module server is running but DWDS exposes no '
          'connectedApps stream: DWDS initialization did not complete.',
        );
      }
      // Set up the VM service on EVERY browser connection — not just the
      // first. Hot restart preserves the page, but a genuine navigation (the
      // user hitting reload, a crash) still tears down the page's isolate and
      // VM service; re-attaching on each (re)connection lets the next hot
      // reload use the live connection instead of a dead one. Matches
      // Flutter's resident_web_runner, which re-attaches per connection.
      final dwdsReload = DwdsReloadStrategy(
        moduleServer: moduleServer,
        // Read at call time, not now: this runs before Chrome launches, so there
        // is no debugging port to capture yet. The listener above is what makes
        // the navigation safe — it re-wires the VM service, the session and the
        // log forwarder on the reconnection, exactly as it does for a user
        // pressing reload.
        loadFirstProgram: () async {
          final cdpPort = webDevice.cdpPort;
          if (cdpPort == null) {
            throw StateError(
              'the browser announced no debugging port, so the page cannot be '
              'told to load the program it never got',
            );
          }
          await cdpPageReload(cdpPort, appUrl: webDevice.appUrl);
        },
      );
      pipeline.strategy = dwdsReload;
      VmServiceLogForwarder? webLogForwarder;

      connectedApps.listen((appConnection) async {
        plan.logger.info({
          'message': 'dwds_connected',
          'text':
              'DWDS: Browser connected (app: ${appConnection.request.appId})',
        });
        try {
          final debugConnection = await moduleServer.debugConnection(
            appConnection,
          );
          // Awaited, not searched for: the listener is attached before the
          // launch loop runs, so on a fast connection the session may not
          // exist yet and `sessions.firstWhere` would throw.
          final session = await webSession.future;

          // DWDS runs the DDS, so `debugConnection.uri` already *is* the DDS
          // websocket. Everything — our client, DevTools, DWDS's own client —
          // attaches there, and DDS multiplexes them.
          final wsUri = Uri.parse(debugConnection.uri);
          final webClient = VmServiceClient();
          await webClient.connect(
            httpUriFromWebSocketUri(wsUri),
            createDevFS: false,
          );
          session.vmClient = webClient;
          final webVmService = webClient.service!;
          await dwdsReload.attachVmService(webVmService);
          // Announced on web too: the event exists to say where a run's VM
          // service is, and a `--machine` client has no other way to find a
          // browser run's.
          host.protocol.appDebugPort(
            session.appId,
            wsUri,
            httpUriFromWebSocketUri(wsUri),
          );

          // Claim hot reload on the DDS, as flutter_tools does. Without it a
          // DevTools-initiated reload bypasses us and calls DWDS's raw
          // `reloadSources` directly — no recompile from our frontend
          // server, and a second concurrent reload that DWDS does not
          // serialise. Registering does not capture our own raw call: DDS
          // resolves only namespaced (`sN.`) names against registrations.
          await webVmService.registerService(
            'reloadSources',
            'rules_flutter dev_tool',
          );

          // DevTools comes from the DDS that DWDS started, already carrying
          // the VM service URI — no separate `dart devtools` process, and no
          // URL for the user to wire up by hand. Setting it before
          // `markDebugReady` is what tells the session not to launch one.
          session.devToolsUrl = debugConnection.devToolsUri;
          session.markDebugReady();

          // A handover is the app starting, not the app painted. Web takes the
          // same first-frame wait native does.
          unawaited(session.waitUntilDrivable(host.protocol));

          // A browser page has no process pipes, so the VM service is the
          // app's log source here. Re-attached on every connection because a
          // page that navigates replaces the isolate and its VM service;
          // without this, output stops after the first such reload.
          await webLogForwarder?.dispose();
          webLogForwarder = await forwardVmServiceLogs(
            webVmService,
            session.appInstance.logs,
          );

          plan.logger.info({
            'message': 'dwds_vm_service',
            'text': 'DWDS VM service ready — hot reload enabled.',
          });
        } catch (e) {
          // The same rule as the native abort in the launch loop below,
          // applied where web can apply it. `!isWebDevice` guards that check
          // because a browser's VM service arrives asynchronously, so the
          // decision cannot be made inline at launch — it belongs here, at
          // the one moment web knows the answer.
          //
          // A browser that has not connected *yet* never reaches this: the
          // listener only fires on a connection that arrived. Upstream makes
          // the same distinction deliberately — an unconnected client is
          // `Recompile complete. No client connected.`, not an error —
          // and so does this. What is fatal is a connection that arrived and
          // then failed to wire: no VM service, no hot reload, no DevTools,
          // no app console.
          if (plan.allowNoVmService) {
            plan.logger.warning({
              'message': 'dwds_vm_service_error',
              'text':
                  'Continuing without a DWDS VM service connection '
                  '(--allow-no-vm-service): $e',
              'error': '$e',
            });
          } else {
            fail(
              DevToolException(
                'No VM service connection for the browser session: $e\n'
                'Hot reload, DevTools, and the app console would all be '
                'unavailable. Pass --allow-no-vm-service to run anyway.',
              ),
            );
            return;
          }
        }
        // Tell the browser to run main() — sends RunRequest via SSE. Must
        // happen after debug setup so DWDS can set breakpoints.
        //
        // With --start-paused it is held back instead. There is no engine
        // switch to pass a browser: DWDS is what gates `main()`, so pausing
        // means simply not sending the request until a debugger resumes the
        // isolate. `pause_isolates_on_start` is set alongside it so isolates
        // the app spawns later stop too, matching what the flag does
        // everywhere else.
        if (!plan.startPaused) {
          appConnection.runMain();
          return;
        }
        // Holding a browser app is not an engine switch — DWDS is what gates
        // `main()`, so pausing is simply not sending the run request. What
        // releases it is DWDS itself: its `resume` handler runs `main()` when
        // the app has not started yet, so a debugger's resume button is the
        // resume, with nothing here to relay it.
        final webVm = (await webSession.future).vmClient?.service;
        if (webVm == null) {
          // Nothing can resume it, so holding main() back would be a hang
          // with no way out. Run, and say why it is not paused.
          plan.logger.severe({
            'message': 'start_paused_unavailable',
            'text':
                'Could not hold the browser app at main(): this run has '
                'no VM service to resume it from. Starting it normally.',
          });
          appConnection.runMain();
          return;
        }
        // Not what withholds `main()` — that is the missing `runMain()`
        // above. This is what makes the state legible: with the flag set,
        // DWDS reports the isolate as paused at start, so a debugger shows a
        // stopped app with a resume button instead of a running one that
        // renders nothing.
        try {
          await webVm.setFlag('pause_isolates_on_start', 'true');
        } catch (e) {
          plan.logger.warning({
            'message': 'pause_isolates_flag_failed',
            'text':
                'The browser VM would not take pause_isolates_on_start '
                '($e); main() is still held back and a resume still starts '
                'it, but a debugger will show the app as running.',
            'error': '$e',
          });
        }
        plan.logger.info({
          'message': 'start_paused',
          'text':
              'Holding the browser app at main(). Attach a debugger and '
              'resume — nothing renders until then.',
        });
      });

      // Last statement in the block on purpose: signalled any earlier, a throw
      // in between leaves the gate open while `frontendServer` is reset to
      // null, and the next reload answers `No frontend server available` —
      // naming the wrong thing entirely.
      pipeline.ready.signalReady();
    } catch (e) {
      // Cleanup, then out. A debug web run whose DDC/DWDS setup failed has
      // no VM service, no hot reload, no DevTools and no app console.
      // Serving the stale bazel bundle statically instead would hide all of
      // that behind a Chrome window that looks healthy, and swallow the four
      // DevToolExceptions this block raises deliberately (no
      // `_dev_config.json`, no `package_config.json`, a failed initial compile,
      // and DWDS's own).
      //
      // --allow-no-vm-service is the one way through, the same flag and the
      // same shape as the native abort below: say which flag is keeping the
      // run alive, record why the pipeline is unavailable, carry on. On web
      // that fallback is static serving, asked for rather than chosen here.
      await moduleServer?.stop();
      moduleServer = null;
      await pipeline.frontendServer?.shutdown();
      pipeline.frontendServer = null;
      if (!plan.allowNoVmService) rethrow;
      plan.logger.warning({
        'message': 'web_dev_server_failed',
        'text':
            'Continuing without a DDC dev server on Chrome '
            '(--allow-no-vm-service): $e\n'
            'Serving the last build statically — no hot reload, no '
            'DevTools, no app console.',
        'error': '$e',
        // Named as a field as well as in the prose: JSON mode drops `text`,
        // so this is how a machine consumer learns the run is only still
        // alive because someone asked for it to be.
        'flag': '--allow-no-vm-service',
      });
      pipeline.ready.signalUnavailable(
        'DDC dev server failed; hot reload unavailable: $e',
      );
    }
  }
}

/// The WASM dev loop, which is not a dev loop: `dart2wasm` has no incremental
/// compiler and no VM service, so "hot restart" is a bazel rebuild plus a CDP
/// page reload, and hot reload does not exist at all.
///
/// Its handlers deliberately shadow the pipeline-backed ones, so this must be
/// assembled *after* [SessionHost.registerReloadCommands] — `CommandRunner`
/// registration replaces, and the later registration is the one that answers.
/// That shadowing is what every route in reaches: a keypress and the file
/// watcher both dispatch through `commandRunner.run`, not around it.
/// It also runs after the launch loop, because the CDP port is discovered by
/// launching Chrome.
///
/// Takes what it uses rather than the whole [RunPlan], the way
/// `NativePipelineAssembler` does. Two reasons, neither of them a test: the
/// plan is a god object this used six fields of, and reaching the browser
/// through it meant an unchecked `plan.devices.first as WebDevice` — a cast
/// the caller can make correctly because it is the caller that decided this is
/// a web run at all. What is left is a port and a build, which is all a WASM
/// restart is.
class WasmPipelineAssembler {
  /// The debugging port Chrome announced, or null when it announced none.
  ///
  /// The one thing this assembly cannot do without: a WASM restart *is* a
  /// page reload over CDP.
  final int? cdpPort;

  /// The URL the app is served from, used to pick the app's own tab out of
  /// the browser's target listing.
  final String? appUrl;

  /// The target the user named, and what a restart rebuilds.
  final String target;

  final String workspace;
  final String? compilationMode;

  /// Every bazel argument the run builds with, platform flags included — the
  /// same list the launch build used, so the rebuild writes the tree the
  /// browser is being served from rather than another configuration's.
  final List<String> extraArgs;

  final SessionHost host;
  final ReloadPipeline pipeline;
  final Logger logger;

  WasmPipelineAssembler({
    required this.cdpPort,
    required this.appUrl,
    required this.target,
    required this.workspace,
    required this.compilationMode,
    required this.extraArgs,
    required this.host,
    required this.pipeline,
    required this.logger,
  });

  void assemble() {
    final cdpPort = this.cdpPort;
    // Without a CDP port there is no way to reload the page, so there is no
    // restart to offer. The run's gate fallback answers for it.
    if (cdpPort == null) return;

    final strategy = WasmReloadStrategy(
      cdpPort: cdpPort,
      appUrl: appUrl,
      rebuild: () async {
        logger.info({
          'message': 'wasm_rebuild',
          'text': 'Rebuilding $target (WASM)...',
        });
        final result = await bazelBuild(
          target,
          workspace: workspace,
          compilationMode: compilationMode,
          extraArgs: extraArgs,
        );
        return result.success;
      },
    );
    pipeline.strategy = strategy;

    host.commandRunner.register('app.restart', longRunning: true, (
      params,
    ) async {
      // Never stdout from inside a handler: in machine mode that is the
      // protocol channel. `app.progress` already announces the start.
      logger.info({
        'message': 'wasm_restart_started',
        'text': 'Performing WASM hot restart...',
      });
      final stopwatch = Stopwatch()..start();
      // Dummy CompileResult — WASM doesn't use the frontend server.
      final outcome = await strategy.applyRestart(
        CompileResult(dillPath: '', success: true),
        host.sessions,
      );
      stopwatch.stop();
      // Both arms through the one renderer. This is not a refusal — the page
      // reload was attempted and `outcome` is the strategy's own verdict on
      // it, which is exactly what `CommandReport.strategy` is for. Deciding
      // success here and building two maps by hand would leave the success arm
      // with no `succeeded` key and the failure arm with no `runningCode`: a
      // rejected reload cannot promise the page kept its old code, and only the
      // strategy knows that.
      return toWire(
        CommandReport(
          verb: 'Restart',
          strategy: outcome,
          elapsed: stopwatch.elapsed,
        ),
      );
    });

    host.commandRunner.register('app.hotReload', longRunning: true, (
      params,
    ) async {
      // The one refusal in this file, and the strongest case for `unavailable`
      // there is: dart2wasm has no incremental path at all, so this run can
      // never hot reload — which is precisely what a client is entitled to
      // conclude from the field. It also stops before a compiler or a browser
      // is touched, so `runningCode: unchanged` is provable rather than
      // asserted.
      return toWire(
        CommandReport(
          verb: 'Hot reload',
          unavailable:
              'Hot reload is not supported in WASM mode — use restart (R).',
        ),
      );
    });
  }
}
