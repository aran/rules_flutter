/// Launches the app on one device and turns it into a [DeviceSession].
///
/// The per-device half of a run: start the process, own a DDS on its VM service,
/// connect a client through that DDS, apply the launch-time options that could
/// only be applied now, and register the session's disposer the moment the
/// session exists.
///
/// Owning the DDS is what lets DevTools and this tool hold the VM service at the
/// same time — DDS multiplexes clients, where the raw service evicts the
/// previous one.
library;

import 'dart:async';

import 'package:dds/dds.dart';

import 'app_log_sink.dart';
import 'dev_tool_exception.dart';
import 'device.dart';
import 'run_plan.dart';
import 'session.dart';
import 'session_host.dart';
import 'vm_service_client.dart';

class DeviceLauncher {
  final RunPlan plan;
  final SessionHost host;

  /// The artifact to launch, from [RunPlan.buildApp].
  final String appFile;

  DeviceLauncher({
    required this.plan,
    required this.host,
    required this.appFile,
  });

  /// Launch on [device], appending the session to [SessionHost.sessions].
  ///
  /// Throws [DevToolException] when the launch itself fails, and when a debug
  /// native launch produced no VM service connection — that session has no hot
  /// reload, no DevTools and no agent control, which is broken rather than
  /// merely degraded. `--allow-no-vm-service` opts into continuing anyway.
  Future<DeviceSession> launch(Device device) async {
    final appId = '${plan.target}_${device.name}'.replaceAll(
      RegExp(r'[^a-zA-Z0-9]'),
      '_',
    );
    // Profile mode builds AOT/optimized output with no reload pipeline on
    // any platform, and `--no-hot` asks for the same thing explicitly — both
    // via the run's one derivation, so this cannot answer an IDE something
    // the reload keys and the readiness gate disagree with.
    host.protocol.appStart(
      appId,
      device.name,
      supportsRestart: plan.hotReloadOff == null,
      directory: plan.workspace,
      launchMode: 'run',
      mode: plan.daemonMode,
    );
    plan.logger.info({
      'message': 'launching',
      'text': 'Launching on ${device.name}...',
      'device': device.name,
    });

    // Attached before the launch so startup output — including whatever an
    // app prints on its way to crashing before it ever binds a VM service —
    // is visible as it happens rather than after discovery gives up.
    final logSink = appLogSinkFor(
      protocol: host.protocol,
      appId: appId,
      deviceName: device.name,
      multiDevice: plan.devices.length > 1,
    );

    final AppInstance appInstance;
    try {
      appInstance = await device.launch(appFile, onLog: logSink);
    } on StateError catch (e) {
      throw DevToolException('Launch failed on ${device.name}: ${e.message}');
    }

    // The served URL, the moment it exists — before the VM-service connect
    // below, which on a browser can take a cold Chrome's worth of seconds, and
    // before `app.started`.
    //
    // Announced because nothing else names the address: this tool launches
    // Chrome with its own scratch profile, and `--web-run-headless` launches
    // one with no window. Both renderings
    // matter: the log line is what a terminal user reads, and the protocol
    // event is what a `--machine` client reads, since the JSON log format
    // drops `text` by design.
    if (device is WebDevice) {
      // Not a nullable read to skip past: both of `WebDevice.launch`'s branches
      // set the URL before returning, so a null here is a device that launched
      // without serving anything.
      final url = device.appUrl;
      if (url == null) {
        throw DevToolException(
          'The browser launched on ${device.name} but the run does not know '
          'what URL it was pointed at, so nothing can say where the app is '
          'served or find its tab over CDP.',
        );
      }
      plan.logger.info({
        'message': 'web_app_url',
        'text': 'App served at $url (${device.name})',
        'url': url,
        'device': device.name,
      });
      host.protocol.appWebLaunchUrl(appId, url, launched: true);
    }

    // Connect to VM service (native devices only; web has no VM service).
    //
    // We OWN DDS: start a Dart Development Service on the app's raw VM
    // service and route both our vmClient and DevTools through it. DDS
    // multiplexes clients, so DevTools does not evict our connection.
    VmServiceClient? vmClient;
    DartDevelopmentService? dds;
    String? vmFailureReason;
    if (appInstance.vmServiceUri != null) {
      final rawUri = appInstance.vmServiceUri!;
      try {
        dds = await DartDevelopmentService.startDartDevelopmentService(
          rawUri,
          ipv6: rawUri.host.contains(':'),
        );
      } catch (e) {
        vmFailureReason = 'DDS failed to start on $rawUri: $e';
        plan.logger.severe({
          'message': 'dds_start_failed',
          'text':
              'Could not start the Dart Development Service on '
              '${device.name}: $e. Hot reload, DevTools, and agent control '
              'will be unavailable.',
          'device': device.name,
          'uri': rawUri.toString(),
          'error': '$e',
        });
      }

      if (dds != null) {
        final serviceUri = dds.uri!;
        plan.logger.info({
          'message': 'vm_service',
          'text': 'VM service (via DDS) at $serviceUri (${device.name})',
          'uri': serviceUri.toString(),
          'device': device.name,
        });
        host.protocol.appDebugPort(
          appId,
          serviceUri.replace(
            scheme: serviceUri.scheme == 'https' ? 'wss' : 'ws',
            path: '${serviceUri.path}ws',
          ),
          serviceUri,
        );
        for (var attempt = 0; attempt < 5; attempt++) {
          vmClient = VmServiceClient();
          try {
            await vmClient.connect(serviceUri);
            plan.logger.info({
              'message': 'vm_service_connected',
              'text': 'Connected to VM service (${device.name}).',
              'device': device.name,
            });
            break;
          } catch (e) {
            if (attempt < 4) {
              plan.logger.fine({
                'message': 'vm_service_retry',
                'text': 'VM service connect attempt ${attempt + 1} failed: $e',
                'attempt': attempt + 1,
                'error': '$e',
              });
              await Future<void>.delayed(const Duration(seconds: 1));
            } else {
              vmFailureReason =
                  'could not connect to the VM service at $serviceUri '
                  'after 5 attempts: $e';
              plan.logger.severe({
                'message': 'vm_service_connect_failed',
                'text':
                    'Could not connect to the VM service on ${device.name} '
                    'after 5 attempts: $e. Hot reload, DevTools, and agent '
                    'control will be unavailable.',
                'device': device.name,
                'uri': serviceUri.toString(),
                'error': '$e',
              });
              vmClient = null;
            }
          }
        }
      }
    } else if (!plan.isWebDevice) {
      vmFailureReason = 'no VM service URI was discovered at launch';
      plan.logger.severe({
        'message': 'vm_service_uri_not_found',
        'text':
            'No VM service URI was discovered on ${device.name}. Hot '
            'reload, DevTools, and agent control will be unavailable.',
        'device': device.name,
      });
    }

    // A native session without a vmClient has no hot reload, no DevTools,
    // and no agent control — it is broken, not merely degraded. Abort by
    // default; --allow-no-vm-service opts into continuing anyway. Release
    // and profile builds where no VM service URI was ever discovered are
    // exempt (there may legitimately be none to connect to); a debug build
    // must always produce one.
    if (vmClient == null &&
        !plan.isWebDevice &&
        (appInstance.vmServiceUri != null || plan.compilationMode == 'dbg')) {
      if (plan.allowNoVmService) {
        plan.logger.warning({
          'message': 'no_vm_service_continuing',
          'text':
              'Continuing without a VM service connection on '
              '${device.name} (--allow-no-vm-service): hot reload, DevTools, '
              'and agent control stay unavailable for this run.',
          'device': device.name,
          'reason': vmFailureReason ?? 'unknown failure',
        });
      } else {
        try {
          await device.stop(appInstance);
        } catch (e) {
          plan.logger.warning({
            'message': 'stop_during_abort_failed',
            'text':
                'Could not stop the app on ${device.name} while aborting '
                'the run: $e. It may still be running — stop it by hand '
                'before the next run.',
            'device': device.name,
            'error': '$e',
          });
        }
        throw DevToolException(
          'No VM service connection on ${device.name}: '
          '${vmFailureReason ?? 'unknown failure'}. '
          'Hot reload, DevTools, and agent control would all be '
          'unavailable. Pass --allow-no-vm-service to run anyway.',
        );
      }
    }

    // Push initial route if specified. Not while paused: the extension is
    // registered by the framework's binding, which has not run, so the call
    // would fail and the message would blame the route.
    if (plan.initialRoute != null && vmClient != null && !plan.startPaused) {
      try {
        await vmClient.callServiceExtension(
          'ext.flutter.pushRoute',
          args: {'route': plan.initialRoute!},
        );
      } catch (e) {
        plan.logger.severe({
          'message': 'push_route_failed',
          'text':
              'Could not push the initial route "${plan.initialRoute}" on '
              '${device.name}: $e. The app stays on the route its own '
              'main() opened.',
          'device': device.name,
          'route': plan.initialRoute,
          'error': '$e',
        });
      }
    }

    // Trace startup if requested. Same reason as the route above.
    if (plan.traceStartup && vmClient != null && !plan.startPaused) {
      try {
        await vmClient.callServiceExtension(
          'ext.flutter.traceAlloc',
          args: {'enabled': 'true'},
        );
      } catch (e) {
        plan.logger.warning({
          'message': 'trace_startup_failed',
          'text':
              'Could not enable startup tracing on ${device.name}: $e. '
              'The run continues without allocation traces.',
          'device': device.name,
          'error': '$e',
        });
      }
    }

    // Say it is paused only after seeing it paused. The switch travels a
    // different way on every platform — an intent extra, an env variable, a
    // trailing argv entry — and a target that ignored it would otherwise
    // leave the user waiting at a debugger for an app that already ran.
    if (plan.startPaused && vmClient != null) {
      switch (await vmClient.waitUntilPausedAtStart()) {
        case StartPausedState.pausedAtStart:
          plan.logger.info({
            'message': 'start_paused',
            'text':
                'The app on ${device.name} is paused at the start of '
                'main(). Attach a debugger and resume it — until then there '
                'is no first frame, no screenshot, and no app.* command.',
            'device': device.name,
          });
        case StartPausedState.running:
          plan.logger.severe({
            'message': 'start_paused_ignored',
            'text':
                '--start-paused did not take on ${device.name}: the main '
                'isolate is running. Whatever a debugger attaches to now has '
                'already executed main().',
            'device': device.name,
          });
        // Reported apart from `running` because the two send the user
        // somewhere different, and only one of them is something we saw. The
        // isolate may well be holding as asked; nothing here can say.
        case StartPausedState.unknown:
          plan.logger.severe({
            'message': 'start_paused_unverified',
            'text':
                'Could not read the main isolate on ${device.name}, so '
                'whether --start-paused took is unknown. If a debugger '
                'attaches to a running app, that is the answer.',
            'device': device.name,
          });
      }
    }

    host.protocol.appStarted(appId);
    final deviceSession = DeviceSession(
      device: device,
      appInstance: appInstance,
      vmClient: vmClient,
      appId: appId,
      dds: dds,
    );
    host.sessions.add(deviceSession);

    // Started here and deliberately not awaited. `app.started` has just gone
    // out and it means what upstream means by it — the app's process is up and
    // its debug link answers — but the app has not necessarily painted, and on
    // a physical device it will not for another minute. Commands wait on the
    // gate this settles; the run itself must not, or every launch would sit
    // out that minute before the session loop existed.
    unawaited(deviceSession.waitUntilDrivable(host.protocol));

    await host.teardown.add(() => deviceSession.shutdown(host.protocol));
    return deviceSession;
  }
}
