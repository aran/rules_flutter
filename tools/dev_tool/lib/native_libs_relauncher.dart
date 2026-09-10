/// Replaces the running process when a hot restart cannot do the job.
///
/// A hot restart re-runs `main()` in a fresh isolate, but the *process* is the
/// same one — and it keeps every library it has already `dlopen`ed. An app
/// bundling loose native libraries (`native_deps`) that rebuilds one of them
/// therefore restarts into the old machine code, silently and with a success
/// message. The only fix is a new process.
///
/// So `app.restart` asks here first. A fingerprint of the launched bundle's
/// loose native libraries is recorded at assembly; on each restart the bundle is
/// rebuilt and re-fingerprinted, and only a difference buys a relaunch. Apps
/// with no loose native libraries never construct one of these at all and keep
/// the instant restart path.
library;

import 'dart:async';

import 'app_log_sink.dart';
import 'hot_reload/app_instance.dart' as hr;
import 'hot_reload/reload_orchestrator.dart';
import 'logging.dart';
import 'machine_protocol.dart';
import 'native_libs_fingerprint.dart';
import 'relaunch_outcome.dart';
import 'session.dart';
import 'vm_service_client.dart';

class Relauncher {
  /// The launch artifact, both to relaunch from and to fingerprint.
  final String appFile;

  /// Rebuilds the launch target. Injected rather than called directly so this
  /// is testable without bazel — and because the *launch* target is what has to
  /// be rebuilt, not the flutter_application: a platform rule reaches the
  /// flutter_application through a transition, so building it alone writes a
  /// different configuration's outputs and leaves the running bundle untouched.
  final Future<bool> Function() rebuild;

  /// The run's live session list — the same instance the rest of the run holds,
  /// because [DeviceSession.relaunch] swaps each session's app instance in
  /// place and everything else must see the replacement.
  final List<DeviceSession> sessions;

  final MachineProtocol protocol;

  /// The orchestrator whose units are pointed at the replacement processes.
  /// The same units, deliberately: rebuilding the orchestrator would leave
  /// the pipeline pointing at the old one.
  final ReloadOrchestrator orchestrator;

  /// The app's `flutter_assets` directory, or empty when the build produced
  /// none. Re-applied to each reconnected VM client, since a hot restart is
  /// what re-reads it.
  final String assetsDir;

  final Logger logger;

  /// The fingerprint of what the running processes actually launched with.
  /// Advanced only after a successful relaunch, so a rebuild that fails leaves
  /// the next restart still knowing it has stale libraries.
  Map<String, String> _live;

  Relauncher({
    required this.appFile,
    required this.rebuild,
    required this.sessions,
    required this.protocol,
    required this.orchestrator,
    required this.assetsDir,
    required this.logger,
    required Map<String, String> liveFingerprint,
  }) : _live = liveFingerprint;

  /// Rebuild, and relaunch if the native libraries moved.
  ///
  /// Answers with facts rather than a response: [RelaunchNotNeeded] leaves the
  /// caller to run the ordinary isolate restart, and the other two are what the
  /// restart's reply is built from. The words are the renderers' job.
  Future<RelaunchOutcome> relaunchIfNeeded() async {
    if (!await rebuild()) {
      return const RelaunchBuildFailed(
        'bazel build failed during restart; see build output.',
      );
    }
    final fingerprint = await nativeLibsFingerprint(appFile);
    if (fingerprintsEqual(fingerprint, _live)) return const RelaunchNotNeeded();
    final changed = changedLibs(_live, fingerprint);
    logger.info({
      'message': 'native_libs_changed',
      'text': 'Native libraries changed (${changed.join(', ')}); relaunching.',
      'libs': changed,
    });

    final relaunched = <DeviceSession>[];
    // Whether every relaunched app reported a first frame, i.e. can take an
    // `app.*` command now. Reported rather than assumed: a caller that gets
    // `ready: false` knows to wait instead of reading a `Method not found` as a
    // broken agent surface.
    var allReady = true;
    for (final session in sessions) {
      if (session.appInstance.vmServiceUri == null) continue;
      // The session owns the swap: between the old process's death and the
      // replacement's arrival it must not look like the app ended, or the run's
      // transports (the HTTP control channel included) would be torn down under
      // a driver that is mid-restart.
      await session.relaunch(() async {
        await session.vmClient?.disconnect();
        // Stopping closes the old instance's log stream, so the sink attached
        // below is the only live one — the relaunched app's output never
        // doubles up with the previous instance's.
        await session.device.stop(session.appInstance);
        return session.device.launch(
          appFile,
          onLog: appLogSinkFor(
            protocol: protocol,
            appId: session.appId,
            deviceName: session.device.name,
            multiDevice: sessions.length > 1,
          ),
        );
      });
      relaunched.add(session);
      allReady &= await _reconnect(session);
      protocol.appStarted(session.appId);
    }

    // Point the units at the processes that came back. A session whose VM
    // service did not return is marked disconnected, so a request naming it is
    // told why instead of failing to apply a kernel to a closed socket.
    orchestrator.syncLiveApps(_appInstances());
    _live = fingerprint;

    return Relaunched(
      changedLibs: changed,
      ready: allReady,
      launches: {
        for (final session in relaunched) session.appId: session.launch,
      },
    );
  }

  /// Reconnect [session] to its replacement process's VM service.
  ///
  /// Returns whether the app is ready to take commands. Connecting only proves
  /// the process is up; the caller's next move is an `app.*` command, which
  /// needs the app's service extensions registered — so this waits for the
  /// first rasterized frame, the observable that says the framework got that
  /// far. Answering before that turns the driver's first call after a relaunch
  /// into `-32601 Method not found`.
  Future<bool> _reconnect(DeviceSession session) async {
    final uri = session.appInstance.vmServiceUri;
    VmServiceClient? client;
    Object? lastConnectFailure;
    if (uri != null) {
      for (var attempt = 0; attempt < 5; attempt++) {
        client = VmServiceClient();
        try {
          await client.connect(uri);
          break;
        } catch (e) {
          lastConnectFailure = e;
          client = null;
          if (attempt < 4) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
      }
    }
    session.vmClient = client;
    if (client == null || uri == null) {
      // Without this a session comes back `disconnected` with nothing anywhere
      // saying why, while the relaunch it belongs to still reports success,
      // just `ready: false`. The last failure is the one worth keeping: the
      // earlier ones are the socket not being up yet, which is the relaunch
      // working.
      logger.warning({
        'message': 'relaunch_vm_service_unreachable',
        'text': uri == null
            ? 'The relaunched ${session.appId} announced no VM service, so '
                  'there was nothing to reconnect to. The session is marked '
                  'disconnected, so commands naming it are refused rather than '
                  'applied to a closed socket.'
            : 'Reconnecting to ${session.appId} at $uri failed on all 5 '
                  'attempts; the last said: $lastConnectFailure. The session is '
                  'marked disconnected, so commands naming it are refused '
                  'rather than applied to a closed socket.',
        'appId': session.appId,
        if (uri != null) 'uri': uri.toString(),
        if (lastConnectFailure != null) 'error': '$lastConnectFailure',
      });
      return false;
    }

    protocol.appDebugPort(
      session.appId,
      uri.replace(
        scheme: uri.scheme == 'https' ? 'wss' : 'ws',
        path: '${uri.path}ws',
      ),
      uri,
    );
    if (assetsDir.isNotEmpty) {
      client.assetDirectory = assetsDir;
      client.devicePathsAreWindows = session.device.usesWindowsPaths;
    }
    return client.waitForFirstFrame();
  }

  List<hr.AppInstance> _appInstances() => [
    for (final session in sessions)
      if (session.vmClient != null)
        hr.VmServiceAppInstance(
          id: session.appId,
          client: session.vmClient!,
          rpcTimeout: session.device.applyTimeout,
        ),
  ];
}
