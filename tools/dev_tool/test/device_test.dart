import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:flutter_bazel_dev_tool/web_module_server.dart';
import 'package:flutter_bazel_dev_tool/web_options.dart';
import 'package:flutter_bazel_dev_tool/mdns_vm_service_discovery.dart';
import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

/// The announcement every desktop launch waits for.
const _vmServiceLine =
    'The Dart VM service is listening on http://127.0.0.1:12345/test=/';

/// What `devicectl list devices` reports for one paired device.
String devicesJson(String transportType) => json.encode({
  'result': {
    'devices': [
      {
        'identifier': 'TEST-COREDEVICE-ID',
        'hardwareProperties': {'udid': 'TEST-UDID'},
        'deviceProperties': {'name': 'Test iPhone'},
        'connectionProperties': {
          'transportType': transportType,
          'pairingState': 'paired',
          'localHostnames': ['Test-iPhone.coredevice.local'],
        },
      },
    ],
  },
});

void main() {
  group('vmServiceUriPattern', () {
    test('matches "Dart VM service is listening on http://..."', () {
      final line =
          'The Dart VM service is listening on http://127.0.0.1:9999/xyz/';
      final match = vmServiceUriPattern.firstMatch(line);
      expect(match, isNotNull);
      expect(match!.group(1), 'http://127.0.0.1:9999/xyz/');
    });

    test('does not match unrelated stdout', () {
      final line = 'Starting Flutter application...';
      final match = vmServiceUriPattern.firstMatch(line);
      expect(match, isNull);
    });

    test('does not match partial prefix', () {
      final line = 'Something listening on http://localhost:1234/';
      final match = vmServiceUriPattern.firstMatch(line);
      expect(match, isNull);
    });
  });

  group('detectDevice', () {
    test('returns a device for current platform', () {
      if (Platform.isMacOS || Platform.isLinux) {
        final device = detectDevice();
        expect(device, isNotNull);
      }
    });

    test('MacOSDevice has correct name', () {
      final device = MacOSDevice();
      expect(device.name, 'macOS');
    });

    test('LinuxDevice has correct name', () {
      final device = LinuxDevice();
      expect(device.name, 'Linux');
    });

    test('AndroidDevice name includes deviceId when provided', () {
      final device = AndroidDevice(deviceId: 'emulator-5554');
      expect(device.name, 'Android (emulator-5554)');
    });

    test('AndroidDevice name is "Android" when no deviceId', () {
      final device = AndroidDevice();
      expect(device.name, 'Android');
    });
  });

  group('resolveDevices', () {
    test('returns auto-detected device when no IDs given', () {
      final devices = resolveDevices([]);
      expect(devices, hasLength(1));
    });

    test('resolves macos to MacOSDevice', () {
      final devices = resolveDevices(['macos']);
      expect(devices.single, isA<MacOSDevice>());
    });

    test('resolves linux to LinuxDevice', () {
      final devices = resolveDevices(['linux']);
      expect(devices.single, isA<LinuxDevice>());
    });

    test('resolves windows to WindowsDevice', () {
      final devices = resolveDevices(['windows']);
      expect(devices.single, isA<WindowsDevice>());
    });

    test('resolves chrome to WebDevice', () {
      final devices = resolveDevices(['chrome']);
      expect(devices.single, isA<WebDevice>());
    });

    test('resolves ios-simulator to IOSSimulatorDevice', () {
      final devices = resolveDevices(['ios-simulator']);
      expect(devices.single, isA<IOSSimulatorDevice>());
    });

    test('resolves ios-simulator:UDID to IOSSimulatorDevice with udid', () {
      final devices = resolveDevices(['ios-simulator:ABC-123']);
      final device = devices.single as IOSSimulatorDevice;
      expect(device.udid, 'ABC-123');
    });

    test('resolves unknown ID as Android serial', () {
      final devices = resolveDevices(['emulator-5554']);
      expect(devices.single, isA<AndroidDevice>());
    });

    test('resolves multiple device IDs', () {
      final devices = resolveDevices(['macos', 'chrome']);
      expect(devices, hasLength(2));
      expect(devices[0], isA<MacOSDevice>());
      expect(devices[1], isA<WebDevice>());
    });
  });

  group('buildArgs', () {
    test('MacOSDevice returns empty buildArgs', () {
      expect(MacOSDevice().buildArgs, isEmpty);
    });

    test('LinuxDevice returns platform flag when not on Linux', () {
      final device = LinuxDevice();
      if (!Platform.isLinux) {
        expect(device.buildArgs, [
          '--platforms=@rules_flutter//flutter/platforms:linux_x64',
        ]);
      } else {
        expect(device.buildArgs, isEmpty);
      }
    });

    test('WindowsDevice returns platform flag when not on Windows', () {
      final device = WindowsDevice();
      if (!Platform.isWindows) {
        expect(device.buildArgs, [
          '--platforms=@rules_flutter//flutter/platforms:windows_x64',
        ]);
      } else {
        expect(device.buildArgs, isEmpty);
      }
    });

    test('IOSSimulatorDevice returns ios_multi_cpus=sim_arm64', () {
      final device = IOSSimulatorDevice(udid: 'TEST');
      expect(device.buildArgs, ['--ios_multi_cpus=sim_arm64']);
    });

    test('AndroidDevice defaults to arm64 platform', () {
      final device = AndroidDevice();
      expect(device.buildArgs, [
        '--platforms=@rules_flutter//flutter/platforms:android_arm64',
      ]);
    });

    test('AndroidDevice respects custom abi', () {
      final device = AndroidDevice(abi: 'x64');
      expect(device.buildArgs, [
        '--platforms=@rules_flutter//flutter/platforms:android_x64',
      ]);
    });

    test('WebDevice returns empty buildArgs', () {
      expect(WebDevice().buildArgs, isEmpty);
    });
  });

  group('IOSSimulatorDevice', () {
    test('has correct name with udid', () {
      final device = IOSSimulatorDevice(udid: 'ABC-123');
      expect(device.name, 'iOS Simulator (ABC-123)');
    });

    test('calls simctl install and launch', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLog;
        },
      );

      unawaited(fakeLog.outputAttached.then((_) => fakeLog.complete(0)));

      await device.launch('/path/to/MyApp.app');

      // Should have: boot, install, log stream spawn, launch.
      final xcrunCalls = calls.where((c) => c.$1 == 'xcrun').toList();
      expect(xcrunCalls.length, greaterThanOrEqualTo(4));

      final bootCall = xcrunCalls.firstWhere((c) => c.$2.contains('boot'));
      expect(bootCall.$2, contains('TEST-UDID'));

      final installCall = xcrunCalls.firstWhere(
        (c) => c.$2.contains('install'),
      );
      expect(installCall.$2, contains('TEST-UDID'));
      expect(installCall.$2, contains('/path/to/MyApp.app'));

      final launchCall = xcrunCalls.firstWhere((c) => c.$2.contains('launch'));
      expect(launchCall.$2, contains('com.example.test'));
    });

    test('throws on simctl install failure', () async {
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if ((args as List).contains('install')) {
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(() => device.launch('/path/to/MyApp.app'), throwsStateError);
    });

    test('stop calls simctl terminate when bundleId is set', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLog,
      );

      final instance = AppInstance(process: fakeLog);
      await device.stop(instance);

      final terminateCall = calls.firstWhere((c) => c.$2.contains('terminate'));
      expect(terminateCall.$2, contains('com.example.test'));
    });

    test('extracts .app from .ipa before install', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          if (exe == 'unzip') {
            // Simulate unzip by creating Payload/app.app directory.
            final dest = args.last;
            Directory('$dest/Payload/app.app').createSync(recursive: true);
            File('$dest/Payload/app.app/Info.plist').writeAsStringSync('');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLog;
        },
      );

      unawaited(fakeLog.outputAttached.then((_) => fakeLog.complete(0)));

      await device.launch('/path/to/app.ipa');

      // Should have called unzip.
      final unzipCall = calls.firstWhere((c) => c.$1 == 'unzip');
      expect(unzipCall.$2, contains('/path/to/app.ipa'));

      // simctl install should receive the extracted .app, not the .ipa.
      final installCall = calls.firstWhere(
        (c) => c.$1 == 'xcrun' && c.$2.contains('install'),
      );
      expect(installCall.$2.last, endsWith('.app'));
      expect(installCall.$2.last, isNot(endsWith('.ipa')));
    });

    test('discovers VM service URI from log stream', () async {
      // launch() starts two `log stream` processes: a discovery stream
      // matching only the VM-service announcement, then the app's own output
      // stream (`--style json`). They need separate fakes. The announcement
      // has to be written once the *discovery* pump is reading — a single
      // shared fake signals "attached" when the output-log pump subscribes,
      // which happens first, and FakeProcess's controllers are broadcast, so
      // the line would be delivered to the log drain and dropped for
      // discovery.
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async {
          final p = FakeProcess();
          if (!args.contains('--style')) {
            unawaited(
              p.outputAttached.then(
                (_) => p.emitStdout(
                  'The Dart VM service is listening on '
                  'http://127.0.0.1:54321/abc=/',
                ),
              ),
            );
          }
          return p;
        },
      );

      final instance = await device.launch('/path/to/MyApp.app');
      expect(instance.vmServiceUri, isNotNull);
      expect(instance.vmServiceUri.toString(), 'http://127.0.0.1:54321/abc=/');
    });
  });

  group('WebDevice', () {
    test('has correct name', () {
      final device = WebDevice();
      expect(device.name, 'Chrome');
    });

    test('refuses to hand out a reload strategy', () {
      // A browser's strategy is built by the web assemblers from the run's
      // module server, never from the device. Inheriting `Device`'s answer
      // would hand a web run `VmServiceReloadStrategy` — the native one — and
      // every reload would go looking for a VM service the browser does not
      // have and blame it for being absent. Refused by name instead.
      expect(
        () => WebDevice().createReloadStrategy(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('WebPipelineAssembler'), contains('Chrome')),
          ),
        ),
      );
    });
  });

  group('findChrome', () {
    test('returns a string or null', () {
      // Just verifies it doesn't throw.
      final result = findChrome();
      expect(result, anyOf(isNull, isA<String>()));
    });
  });

  group('ChromeSession', () {
    const appUrl = 'http://localhost:8080';

    /// A CDP `/json` endpoint whose listing is scripted per request, so a
    /// test can play out "nothing yet → unnavigated tab → app page".
    Future<HttpServer> serveCdpJson(
      List<dynamic> Function(int call) listing,
    ) async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));
      var calls = 0;
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(json.encode(listing(calls++)));
        await request.response.close();
      });
      return server;
    }

    /// Chrome's port announcement for [server], as the real browser prints it.
    String devToolsLine(HttpServer server) =>
        'DevTools listening on ws://127.0.0.1:${server.port}/devtools/browser/x\n';

    Map<String, Object?> appPage(HttpServer server) => {
      'type': 'page',
      'url': '$appUrl/index.html',
      'webSocketDebuggerUrl': 'ws://127.0.0.1:${server.port}/page',
    };

    const blankPage = {
      'type': 'page',
      'url': 'about:blank',
      'webSocketDebuggerUrl': 'ws://blank',
    };

    const extensionPage = {
      'type': 'background_page',
      'url': 'chrome-extension://x/bg.html',
      'webSocketDebuggerUrl': 'ws://bg',
    };

    /// The profile directory a launch created, recovered from its argv.
    Directory profileDirOf(List<String> args) => Directory(
      args
          .firstWhere((a) => a.startsWith('--user-data-dir='))
          .substring('--user-data-dir='.length),
    );

    test(
      'launches with the debug flags, a fresh profile, and the app URL',
      () async {
        late final HttpServer cdp;
        cdp = await serveCdpJson(
          (_) => [extensionPage, blankPage, appPage(cdp)],
        );

        final proc = FakeProcess();
        late List<String> args;
        final launch = ChromeSession.launch(
          url: appUrl,
          chromePath: '/fake/chrome',
          startProcess: (exe, a) async {
            expect(exe, '/fake/chrome');
            args = a;
            return proc;
          },
        );
        await proc.outputAttached;
        proc.emitStderr(devToolsLine(cdp));

        final session = await launch;
        addTearDown(() async {
          session.process.kill();
          await profileDirOf(args).delete(recursive: true);
        });

        expect(args.first, '--remote-debugging-port=0');
        expect(args, containsAll(chromeDebugFlags));
        expect(
          args.last,
          appUrl,
          reason: 'the app URL is what the launched tab must navigate to',
        );
        expect(
          await profileDirOf(args).exists(),
          isTrue,
          reason: 'the launch owns a real, fresh profile directory',
        );
        expect(session.cdpPort, cdp.port);
        expect(session.appUrl, appUrl);
      },
    );

    test('polls until the tab has navigated to the app page', () async {
      late final HttpServer cdp;
      var calls = 0;
      cdp = await serveCdpJson((call) {
        calls = call + 1;
        // The two states a just-launched browser really passes through
        // before the app page exists.
        if (call == 0) return const <dynamic>[];
        if (call == 1) return [extensionPage, blankPage];
        return [extensionPage, blankPage, appPage(cdp)];
      });

      final proc = FakeProcess();
      late List<String> args;
      final launch = ChromeSession.launch(
        url: appUrl,
        chromePath: '/fake/chrome',
        pollInterval: const Duration(milliseconds: 10),
        startProcess: (exe, a) async {
          args = a;
          return proc;
        },
      );
      await proc.outputAttached;
      proc.emitStderr(devToolsLine(cdp));

      final session = await launch;
      addTearDown(() async {
        session.process.kill();
        await profileDirOf(args).delete(recursive: true);
      });

      expect(
        calls,
        greaterThanOrEqualTo(3),
        reason:
            'the launch must poll through the not-yet states, '
            'not fail on the first look',
      );
      expect(await session.resolveAppPage(), 'ws://127.0.0.1:${cdp.port}/page');
    });

    test(
      'fails the launch when the app page never appears, and cleans up',
      () async {
        // A tab that never navigates: only the extension and about:blank ever
        // show up. Falling back to either is exactly the bug — drive them and
        // screenshots and the console silently watch the wrong page.
        final cdp = await serveCdpJson((_) => [extensionPage, blankPage]);

        final proc = FakeProcess();
        late List<String> args;
        final launch = ChromeSession.launch(
          url: appUrl,
          chromePath: '/fake/chrome',
          pageTimeout: const Duration(milliseconds: 100),
          pollInterval: const Duration(milliseconds: 10),
          startProcess: (exe, a) async {
            args = a;
            return proc;
          },
        );
        await proc.outputAttached;
        proc.emitStderr(devToolsLine(cdp));

        await expectLater(
          launch,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains(appUrl),
                // What was there instead is the fact someone debugs from.
                contains('chrome-extension://x/bg.html'),
                contains('about:blank'),
              ),
            ),
          ),
        );
        expect(
          await proc.exitCode,
          isNotNull,
          reason: 'the failed launch must not leave the browser running',
        );
        expect(
          await profileDirOf(args).exists(),
          isFalse,
          reason: 'the failed launch must not leave its profile behind',
        );
      },
    );

    test('fails the launch when Chrome exits without announcing a port, '
        'quoting what it said, and cleans up', () async {
      final proc = FakeProcess();
      late List<String> args;
      final launch = ChromeSession.launch(
        url: appUrl,
        chromePath: '/fake/chrome',
        startProcess: (exe, a) async {
          args = a;
          return proc;
        },
      );
      await proc.outputAttached;
      // The shape this actually takes on a CI runner: Chrome refuses its
      // sandbox, says why, and exits. The reason exists only on stderr — the
      // exit status is a bare 1 — so an error that does not carry it forward
      // reports a symptom and destroys the cause.
      proc.emitStderr('Running as root without --no-sandbox is not supported.');
      proc.complete(1);

      await expectLater(
        launch,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('exited'),
              contains('debugging port'),
              contains('Running as root without --no-sandbox'),
            ),
          ),
        ),
      );
      expect(await profileDirOf(args).exists(), isFalse);
    });

    test('says so when Chrome exits having printed nothing', () async {
      // The other half: silence is a diagnosis too — it rules out every cause
      // that announces itself. Rendering an empty tail as nothing at all would
      // read as if the quoting had been forgotten.
      final proc = FakeProcess();
      late List<String> args;
      final launch = ChromeSession.launch(
        url: appUrl,
        chromePath: '/fake/chrome',
        startProcess: (exe, a) async {
          args = a;
          return proc;
        },
      );
      await proc.outputAttached;
      proc.complete(1);

      await expectLater(
        launch,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('printed nothing at all'),
          ),
        ),
      );
      expect(await profileDirOf(args).exists(), isFalse);
    });

    test(
      'fails the launch when Chrome never announces a port, and cleans up',
      () async {
        final proc = FakeProcess();
        late List<String> args;
        final launch = ChromeSession.launch(
          url: appUrl,
          chromePath: '/fake/chrome',
          portTimeout: const Duration(milliseconds: 100),
          startProcess: (exe, a) async {
            args = a;
            return proc;
          },
        );
        await proc.outputAttached;
        // The browser stays up but says nothing.

        await expectLater(
          launch,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('did not announce'),
            ),
          ),
        );
        expect(await proc.exitCode, isNotNull);
        expect(await profileDirOf(args).exists(), isFalse);
      },
    );

    group('browser launch options', () {
      // Asserted on the argv rather than by launching a real browser: what a
      // flag does here IS the command line, and a mis-ordered or missing
      // switch is the whole failure mode.

      List<String> argsFor(BrowserLaunchOptions options) =>
          ChromeSession.launchArgs(appUrl, options, userDataDir: '/tmp/p');

      // Capture resolution follows the launch switch, not the CDP override: a
      // `deviceScaleFactor` in the override alone is lost once the CDP client
      // detaches, so the scale has to reach the command line. Width and height
      // must not — those stay the CDP override's, since --window-size cannot
      // express them.
      test('a viewport scale becomes --force-device-scale-factor', () {
        final args = argsFor(
          const BrowserLaunchOptions(
            viewport: WebViewport(
              width: 393,
              height: 660,
              deviceScaleFactor: 3,
            ),
          ),
        );
        expect(args, contains('--force-device-scale-factor=3.0'));
        expect(args.where((a) => a.startsWith('--window-size')), isEmpty);
      });

      test('a viewport without a scale leaves the command line alone', () {
        final args = argsFor(
          const BrowserLaunchOptions(
            viewport: WebViewport(width: 393, height: 660),
          ),
        );
        expect(
          args.where((a) => a.startsWith('--force-device-scale-factor')),
          isEmpty,
        );
      });

      test('--web-run-headless adds headless and a real window size', () {
        final args = argsFor(const BrowserLaunchOptions(headless: true));
        expect(args, contains('--headless'));
        expect(args, contains('--window-size=2400,1800'));
      });

      test('headless does not turn the sandbox off', () {
        // Upstream bundles `--no-sandbox` with headless. A launch that
        // quietly drops a security boundary is not what the flag says it
        // does; --web-browser-flag=--no-sandbox is how a run that needs it
        // asks.
        expect(
          argsFor(const BrowserLaunchOptions(headless: true)),
          isNot(contains('--no-sandbox')),
        );
        expect(
          argsFor(const BrowserLaunchOptions()),
          isNot(contains('--headless')),
        );
      });

      test('--web-browser-flag lands last, just before the URL', () {
        // Chrome resolves a repeated switch by position, so a user switch
        // that fights one of the tool's defaults has to come after it to
        // mean anything at all.
        final args = argsFor(
          const BrowserLaunchOptions(
            browserFlags: ['--mute-audio', '--lang=fr'],
          ),
        );
        expect(args.last, appUrl);
        expect(args[args.length - 3], '--mute-audio');
        expect(args[args.length - 2], '--lang=fr');
        for (final own in chromeDebugFlags) {
          expect(
            args.indexOf(own),
            lessThan(args.indexOf('--mute-audio')),
            reason: 'a user switch must be able to override $own',
          );
        }
      });

      test('--web-browser-debug-port is the port asked for', () {
        expect(
          argsFor(const BrowserLaunchOptions(debugPort: 9222)).first,
          '--remote-debugging-port=9222',
        );
        // Unset still asks explicitly, for any free port.
        expect(
          argsFor(const BrowserLaunchOptions()).first,
          '--remote-debugging-port=0',
        );
      });

      test(
        'a fixed debug port is still awaited, and taken from the browser',
        () async {
          // The announcement is the readiness signal, not merely the number: a
          // launch that trusted the flag and skipped the wait would hand every
          // CDP consumer a port before anything was listening on it.
          late final HttpServer cdp;
          cdp = await serveCdpJson(
            (_) => [extensionPage, blankPage, appPage(cdp)],
          );

          final proc = FakeProcess();
          late List<String> args;
          final launch = ChromeSession.launch(
            url: appUrl,
            chromePath: '/fake/chrome',
            options: BrowserLaunchOptions(debugPort: cdp.port),
            startProcess: (exe, a) async {
              args = a;
              return proc;
            },
          );
          await proc.outputAttached;
          expect(args.first, '--remote-debugging-port=${cdp.port}');
          proc.emitStderr(devToolsLine(cdp));

          final session = await launch;
          addTearDown(() async {
            session.process.kill();
            await profileDirOf(args).delete(recursive: true);
          });
          expect(session.cdpPort, cdp.port);
        },
      );

      test('a browser that takes a different port fails the launch', () async {
        // Nothing here could drive that browser: every CDP consumer dials the
        // port that was asked for.
        late final HttpServer cdp;
        cdp = await serveCdpJson(
          (_) => [extensionPage, blankPage, appPage(cdp)],
        );

        final proc = FakeProcess();
        late List<String> args;
        final launch = ChromeSession.launch(
          url: appUrl,
          chromePath: '/fake/chrome',
          options: BrowserLaunchOptions(debugPort: cdp.port + 1),
          startProcess: (exe, a) async {
            args = a;
            return proc;
          },
        );
        await proc.outputAttached;
        proc.emitStderr(devToolsLine(cdp));

        await expectLater(
          launch,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('--web-browser-debug-port'),
                contains('${cdp.port + 1}'),
                contains('${cdp.port}'),
              ),
            ),
          ),
        );
        expect(await proc.exitCode, isNotNull);
        expect(await profileDirOf(args).exists(), isFalse);
      });

      test('a launch URL with a route still finds the app page', () async {
        // The tab's URL and the launch URL are not the same string once the
        // app routes, so the page is matched on origin. Here the launched URL
        // carries a fragment the listed target does not.
        late final HttpServer cdp;
        cdp = await serveCdpJson(
          (_) => [extensionPage, blankPage, appPage(cdp)],
        );

        final proc = FakeProcess();
        late List<String> args;
        final launch = ChromeSession.launch(
          url: '$appUrl/#/settings',
          chromePath: '/fake/chrome',
          startProcess: (exe, a) async {
            args = a;
            return proc;
          },
        );
        await proc.outputAttached;
        proc.emitStderr(devToolsLine(cdp));

        final session = await launch;
        addTearDown(() async {
          session.process.kill();
          await profileDirOf(args).delete(recursive: true);
        });
        expect(args.last, '$appUrl/#/settings');
        expect(session.cdpPort, cdp.port);
      });
    });
  });

  group('AndroidDevice.launch', () {
    test('calls adb install with -r and device flag', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        deviceId: 'emulator-5554',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLogcat;
        },
      );

      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      final runCalls = calls.where((c) => c.$1 == 'adb').toList();
      expect(runCalls.length, greaterThanOrEqualTo(3));

      final installCall = runCalls.firstWhere((c) => c.$2.contains('install'));
      expect(installCall.$2, contains('-s'));
      expect(installCall.$2, contains('emulator-5554'));
      expect(installCall.$2, contains('-r'));
      expect(installCall.$2, contains('/path/to/app.apk'));
    });

    test(
      '--start-paused rides on the launch intent as a boolean extra',
      () async {
        // `--ez start-paused true` is where the Android embedder reads it; the
        // activity is started by an intent, so there is no argv to put it on.
        final calls = <(String, List<String>)>[];
        final fakeLogcat = FakeProcess();
        final device = AndroidDevice(
          packageName: 'com.example.app',
          activityName: '.FlutterActivity',
          adbPath: 'adb',
          runProcess: (exe, args) async {
            calls.add((exe, args));
            return ProcessResult(0, 0, '', '');
          },
          startProcess: (exe, args) async => fakeLogcat,
        )..startPaused = true;
        unawaited(
          fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)),
        );

        await device.launch('/path/to/app.apk');

        final startCall = calls.firstWhere((c) => c.$2.contains('am'));
        expect(
          startCall.$2,
          containsAllInOrder(['--ez', 'start-paused', 'true']),
        );
      },
    );

    test('an ordinary launch carries no start-paused extra', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();
      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );
      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere((c) => c.$2.contains('am'));
      expect(startCall.$2, isNot(contains('start-paused')));
    });

    test('calls adb shell am start with package/activity', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        packageName: 'com.example.app',
        activityName: '.FlutterActivity',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere((c) => c.$2.contains('am'));
      expect(startCall.$2, contains('shell'));
      expect(startCall.$2, contains('am'));
      expect(startCall.$2, contains('start'));
      expect(startCall.$2, contains('-n'));
      expect(startCall.$2, contains('com.example.app/.FlutterActivity'));
    });

    test('defaults activityName to .MainActivity', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere((c) => c.$2.contains('am'));
      expect(startCall.$2, contains('com.example.app/.MainActivity'));
    });

    test('throws on adb install failure', () async {
      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          return ProcessResult(0, 1, '', 'INSTALL_FAILED');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsStateError,
      );
    });

    /// `INSTALL_FAILED_INSUFFICIENT_STORAGE` is the one install failure a
    /// Flutter developer hits without having done anything wrong: a debug APK
    /// carries the whole debug engine, and a stock AVD's 6 GB data partition
    /// cannot take it. adb's own message — `Failure
    /// [INSTALL_FAILED_INSUFFICIENT_STORAGE: Failed to override installation
    /// location]` — names neither size, so it reads as a bug in the tool
    /// rather than as a device that is out of room.
    group('insufficient storage', () {
      late Directory sandbox;
      late String apkPath;

      setUp(() {
        sandbox = Directory.systemTemp.createTempSync('android_storage_test');
        apkPath = p.join(sandbox.path, 'app.apk');
        // Size is read off the real file, so the message can only ever quote
        // a number that is true of the APK being installed.
        File(apkPath).writeAsBytesSync(List.filled(3 * 1024 * 1024, 0));
      });

      tearDown(() => sandbox.deleteSync(recursive: true));

      /// A device whose `adb install` fails for want of space, whose `df`
      /// reports [availableKb] free, and whose `pm path` says the package is
      /// installed only when [alreadyInstalled].
      AndroidDevice outOfSpace({
        required int availableKb,
        bool alreadyInstalled = false,
      }) => AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          if (args.contains('install')) {
            return ProcessResult(
              0,
              1,
              '',
              'adb: failed to install $apkPath: '
                  'Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE: Failed to '
                  'override installation location]',
            );
          }
          if (args.contains('df')) {
            return ProcessResult(0, 0, '''
Filesystem       1K-blocks    Used Available Use% Mounted on
/dev/block/dm-54   6082144 3266184   $availableKb  55% /data/user/0
''', '');
          }
          if (args.contains('path')) {
            return alreadyInstalled
                ? ProcessResult(0, 0, 'package:/data/app/base.apk\n', '')
                : ProcessResult(0, 1, '', '');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      test('reports the APK size, the free space and how to get room', () async {
        await expectLater(
          outOfSpace(availableKb: 2673748).launch(apkPath),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                // The two numbers adb never prints, which are the whole
                // diagnosis: 3 MB of APK against 2.5 GB free.
                contains('3.0 MB'),
                contains('2.5 GB'),
                // The remedy is a larger data partition, and the message names
                // the APK it measured rather than making a flat claim about
                // debug APKs in general.
                contains('640 MB debug APK'),
                contains('disk.dataPartition.size'),
                contains('config.ini'),
                // `-partition-size` is a no-op on userdata, so it appears only
                // as the trap it is — never as the remedy.
                contains('-partition-size flag does not resize userdata'),
              ),
            ),
          ),
        );
      });

      test('offers uninstall only when a copy is already installed', () async {
        await expectLater(
          outOfSpace(availableKb: 2673748, alreadyInstalled: true).launch(
            apkPath,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('adb uninstall com.example.app'),
            ),
          ),
        );
        await expectLater(
          outOfSpace(availableKb: 2673748).launch(apkPath),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                isNot(contains('uninstall')),
                // Nothing to remove is itself worth saying: it rules out the
                // reading that a stale copy is holding the space.
                contains('not currently installed'),
              ),
            ),
          ),
        );
      });

      test('every other install failure keeps adb\'s own words', () async {
        // The diagnosis above is specific to running out of room. Anything
        // else — a bad signature, an ABI mismatch — is passed through
        // unembellished rather than dressed up as a storage problem.
        final device = AndroidDevice(
          packageName: 'com.example.app',
          adbPath: 'adb',
          runProcess: (exe, args) async => args.contains('install')
              ? ProcessResult(0, 1, '', 'Failure [INSTALL_FAILED_INVALID_APK]')
              : fail('nothing else should be asked of adb'),
          startProcess: (exe, args) async => FakeProcess(),
        );
        await expectLater(
          device.launch(apkPath),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('INSTALL_FAILED_INVALID_APK'),
                isNot(contains('data partition')),
              ),
            ),
          ),
        );
      });
    });

    /// A logcat launch whose `adb forward` behaves as [onForward] says.
    /// Everything else adb is asked to do succeeds with no output.
    AndroidDevice launchableDevice(
      FakeProcess logcat,
      ProcessResult Function() onForward,
    ) => AndroidDevice(
      packageName: 'com.example.app',
      adbPath: 'adb',
      runProcess: (exe, args) async =>
          args.contains('forward') ? onForward() : ProcessResult(0, 0, '', ''),
      startProcess: (exe, args) async => logcat,
    );

    /// The announcement a debug app writes to logcat. Its port is the
    /// *device's*, which is the whole reason a forward exists.
    void announceVmService(FakeProcess logcat) {
      unawaited(
        logcat.outputAttached.then(
          (_) => logcat.emitStdout(
            '01-02 03:04:05.678 I/flutter ( 1234): The Dart VM service is '
            'listening on http://127.0.0.1:12345/abc=/',
          ),
        ),
      );
    }

    test('dials the discovered VM service through the adb forward', () async {
      final fakeLogcat = FakeProcess();
      final device = launchableDevice(
        fakeLogcat,
        () => ProcessResult(0, 0, '41234\n', ''),
      );
      announceVmService(fakeLogcat);

      final instance = await device.launch('/path/to/app.apk');
      // 41234, not the announced 12345: the announced port is device-local and
      // the host reaches it only through the port adb allocated.
      expect(instance.vmServiceUri.toString(), 'http://127.0.0.1:41234/abc=/');
    });

    test('throws naming adb when the forward fails', () async {
      final fakeLogcat = FakeProcess();
      final device = launchableDevice(
        fakeLogcat,
        () => ProcessResult(0, 1, '', 'error: device offline'),
      );
      announceVmService(fakeLogcat);

      await expectLater(
        device.launch('/path/to/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('adb forward'), contains('device offline')),
          ),
        ),
      );
    });

    test(
      'throws when the forward reports success but allocates no port',
      () async {
        final fakeLogcat = FakeProcess();
        final device = launchableDevice(
          fakeLogcat,
          () => ProcessResult(0, 0, '', ''),
        );
        announceVmService(fakeLogcat);

        // Exit 0 with nothing on stdout is adb breaking its own contract for
        // `tcp:0`. Handing the device-local URI on instead would have turned it
        // into a connect timeout against whatever the host has on port 12345.
        await expectLater(
          device.launch('/path/to/app.apk'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('no port to reach the VM service on'),
            ),
          ),
        );
      },
    );

    test('stop calls force-stop when packageName is set', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      final instance = AppInstance(process: fakeLogcat);
      await device.stop(instance);

      final stopCall = calls.firstWhere((c) => c.$2.contains('force-stop'));
      expect(stopCall.$2, contains('com.example.app'));
    });

    /// A launchable device that records every adb argument list it is given,
    /// and answers `adb forward tcp:0` with [hostPort].
    ///
    /// `--remove` also contains 'forward', and answering it with a port would
    /// be nonsense, so the two are told apart on `--remove` rather than by
    /// the substring the existing helper matches on.
    (AndroidDevice, List<List<String>>) recordingDevice(
      FakeProcess logcat, {
      String hostPort = '41234',
    }) {
      final calls = <List<String>>[];
      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add(args);
          return args.contains('forward') && !args.contains('--remove')
              ? ProcessResult(0, 0, '$hostPort\n', '')
              : ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => logcat,
      );
      return (device, calls);
    }

    test(
      'stop removes the forward this launch created, by its host port',
      () async {
        final fakeLogcat = FakeProcess();
        final (device, calls) = recordingDevice(fakeLogcat);
        announceVmService(fakeLogcat);

        final instance = await device.launch('/path/to/app.apk');
        await device.stop(instance);

        // `adb forward` writes a rule into the adb server, not into any process
        // this tool owns, so a run that does not remove it leaves a host port
        // bound to the device until the server restarts.
        expect(calls, anyElement(equals(['forward', '--remove', 'tcp:41234'])));
      },
    );

    test('stop never clears another session\'s forwards', () async {
      final fakeLogcat = FakeProcess();
      final (device, calls) = recordingDevice(fakeLogcat);
      announceVmService(fakeLogcat);

      await device.stop(await device.launch('/path/to/app.apk'));

      // Every forward on the host lives in the same adb server and nothing in
      // a rule says which run created it, so the wholesale removal would take
      // a concurrent session's VM service down with this one's.
      expect(calls.expand((args) => args), isNot(contains('--remove-all')));
    });

    test('stop removes nothing when the launch forwarded nothing', () async {
      final fakeLogcat = FakeProcess();
      final (device, calls) = recordingDevice(fakeLogcat);
      // No announcement: a release or profile launch has no VM service, so
      // `launch` never reaches the forward. Discovery gives up on its own.
      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.stop(await device.launch('/path/to/app.apk'));

      expect(calls.expand((args) => args), isNot(contains('--remove')));
    });
  });

  // The dev tool drives programs it does not own. Each device declares which
  // ones its launch needs, so a misconfigured host is reported by name before
  // any work happens — and so no device is made to install another platform's
  // toolchain.
  group('requiredHostTools', () {
    Future<List<String>> namesFor(Device device) async => [
      for (final tool in await device.requiredHostTools()) tool.name,
    ];

    test('a desktop run needs nothing installed', () async {
      expect(await namesFor(MacOSDevice()), isEmpty);
      expect(await namesFor(LinuxDevice()), isEmpty);
      expect(await namesFor(WindowsDevice()), isEmpty);
    });

    test('an Android run needs adb, plus aapt2 to read the APK', () async {
      expect(await namesFor(AndroidDevice()), ['adb', 'aapt2']);
    });

    test('aapt2 is not needed when the package is already known', () async {
      expect(await namesFor(AndroidDevice(packageName: 'com.example.app')), [
        'adb',
      ]);
    });

    test('an explicitly located tool is not searched for', () async {
      expect(
        await namesFor(
          AndroidDevice(adbPath: '/sdk/adb', aapt2Path: '/sdk/aapt2'),
        ),
        isEmpty,
      );
    });

    // Asked per device: a web run must not be refused for want of an Android
    // SDK.
    test('a Chrome run needs Chrome and nothing else', () async {
      expect(await namesFor(WebDevice()), ['Chrome']);
    });

    test('preflight names a tool that is not installed', () async {
      final device = _ToolsDevice([
        HostTool(
          name: 'nonexistent-tool',
          purpose: 'prove the point',
          remedy: 'Install nonexistent-tool.',
          environment: const {'PATH': ''},
        ),
      ]);

      await expectLater(
        device.preflight(),
        throwsA(
          isA<MissingHostToolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('nonexistent-tool'),
              contains('Install nonexistent-tool.'),
            ),
          ),
        ),
      );
    });

    test('preflight passes when every tool is present', () async {
      final device = _ToolsDevice([
        HostTool(
          name: 'dart',
          purpose: 'prove the point',
          remedy: 'unreachable',
          candidates: [Platform.resolvedExecutable],
        ),
      ]);
      await device.preflight();
    });
  });

  // A cabled device's VM service is reached through an iproxy forward; a
  // wireless one is dialed at its own address. Requiring iproxy for the latter
  // would refuse a run that works.
  group('IOSDevice.requiredHostTools', () {
    IOSDevice deviceOn(String transportType) => IOSDevice(
      udid: 'TEST-UDID',
      runProcess: (exe, args) async {
        final out = args[args.indexOf('--json-output') + 1];
        File(out).writeAsStringSync(devicesJson(transportType));
        return ProcessResult(0, 0, '', '');
      },
      startProcess: (exe, args) async => FakeProcess(),
    );

    Future<List<String>> namesFor(Device device) async => [
      for (final tool in await device.requiredHostTools()) tool.name,
    ];

    test('a cabled device needs lldb and a port forwarder', () async {
      expect(await namesFor(deviceOn('wired')), ['lldb', 'iproxy']);
    });

    test('a wireless device needs no port forwarder', () async {
      expect(await namesFor(deviceOn('localNetwork')), ['lldb']);
    });

    // Resolving the device is part of the preflight, so "no phone attached" is
    // also reported before a build rather than after one.
    test('reports an unattached device', () async {
      final device = IOSDevice(
        udid: 'OTHER-UDID',
        runProcess: (exe, args) async {
          final out = args[args.indexOf('--json-output') + 1];
          File(out).writeAsStringSync(devicesJson('wired'));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      await expectLater(
        device.preflight(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('No attached iOS device with UDID OTHER-UDID'),
          ),
        ),
      );
    });
  });

  group('AndroidDevice launch preconditions', () {
    test(
      'fails loudly when aapt2 cannot read the APK, and installs nothing',
      () async {
        final calls = <String>[];
        final device = AndroidDevice(
          adbPath: 'adb',
          aapt2Path: 'aapt2',
          runProcess: (exe, args) async {
            calls.add(exe);
            return ProcessResult(0, 1, '', 'ERROR: dump failed');
          },
          startProcess: (exe, args) async {
            calls.add(exe);
            return FakeProcess();
          },
        );

        await expectLater(
          device.launch('/path/to/app.apk'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('aapt2'), contains('ERROR: dump failed')),
            ),
          ),
        );
        // An app that cannot be named cannot be started, so nothing after the
        // aapt2 dump runs.
        expect(calls, ['aapt2']);
      },
    );

    test(
      'fails when the artifact is not an APK and no package was given',
      () async {
        final device = AndroidDevice(
          adbPath: 'adb',
          aapt2Path: 'aapt2',
          runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
          startProcess: (exe, args) async => FakeProcess(),
        );

        await expectLater(
          device.launch('/path/to/app_deploy.jar'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('app_deploy.jar'), contains('not an APK')),
            ),
          ),
        );
      },
    );

    test(
      'reads the package and activity out of the APK when not given',
      () async {
        final calls = <(String, List<String>)>[];
        final fakeLogcat = FakeProcess();
        final device = AndroidDevice(
          adbPath: 'adb',
          aapt2Path: 'aapt2',
          runProcess: (exe, args) async {
            calls.add((exe, args));
            if (exe == 'aapt2') {
              return ProcessResult(
                0,
                0,
                "package: name='com.example.myapp' versionCode='1'\n"
                    "launchable-activity: name='com.example.myapp.Main'\n",
                '',
              );
            }
            return ProcessResult(0, 0, '', '');
          },
          startProcess: (exe, args) async => fakeLogcat,
        );

        unawaited(
          fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)),
        );
        await device.launch('/path/to/app.apk');

        final start = calls.firstWhere((c) => c.$2.contains('am'));
        expect(start.$2, contains('com.example.myapp/com.example.myapp.Main'));
      },
    );
  });

  group('AndroidDevice INTERNET preflight', () {
    // Realistic `dumpsys package <pkg>` excerpt. The requested-permissions
    // section is omitted entirely when the APK requests no permissions.
    String dumpsysOutput({
      required String package,
      required List<String> requestedPermissions,
    }) {
      final buf = StringBuffer()
        ..writeln('Packages:')
        ..writeln('  Package [$package] (5b7a1c2):')
        ..writeln('    userId=10190')
        ..writeln('    codePath=/data/app/~~q3zA==/$package-r7Yw==');
      if (requestedPermissions.isNotEmpty) {
        buf.writeln('    requested permissions:');
        for (final perm in requestedPermissions) {
          buf.writeln('      $perm');
        }
      }
      buf
        ..writeln('    install permissions:')
        ..writeln('      android.permission.VIBRATE: granted=true')
        ..writeln('    User 0: ceDataInode=73543 installed=true');
      return buf.toString();
    }

    AndroidDevice makeDevice({
      required List<(String, List<String>)> calls,
      required Future<ProcessResult> Function(List<String> args) onDumpsys,
      required FakeProcess logcat,
    }) {
      return AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          if (args.contains('dumpsys')) return onDumpsys(args);
          // `tcp:0` makes adb allocate the host port and print it; a launch
          // that reaches the forward at all needs one to go on with.
          if (args.contains('forward'))
            return ProcessResult(0, 0, '41234\n', '');
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return logcat;
        },
      )..expectsVmService = true;
    }

    test('proceeds when the installed package requests INTERNET', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();
      final device = makeDevice(
        calls: calls,
        logcat: fakeLogcat,
        onDumpsys: (args) async => ProcessResult(
          0,
          0,
          dumpsysOutput(
            package: 'com.example.app',
            requestedPermissions: [
              'android.permission.INTERNET',
            ],
          ),
          '',
        ),
      );

      unawaited(
        fakeLogcat.outputAttached.then(
          (_) => fakeLogcat.emitStdout(
            '01-02 03:04:05.678 I/flutter ( 1234): The Dart VM service is '
            'listening on http://127.0.0.1:12345/abc=/',
          ),
        ),
      );

      final instance = await device.launch('/path/to/app.apk');
      expect(instance.vmServiceUri, isNotNull);

      final dumpsysCall = calls.firstWhere((c) => c.$2.contains('dumpsys'));
      expect(
        dumpsysCall.$2,
        containsAllInOrder(['shell', 'dumpsys', 'package', 'com.example.app']),
      );
      // The activity was started (check passed, launch proceeded).
      expect(calls.any((c) => c.$2.contains('am')), isTrue);
    });

    test('fails fast with diagnostic when INTERNET is missing', () async {
      final calls = <(String, List<String>)>[];
      final device = makeDevice(
        calls: calls,
        logcat: FakeProcess(),
        onDumpsys: (args) async => ProcessResult(
          0,
          0,
          dumpsysOutput(
            package: 'com.example.app',
            requestedPermissions: [
              'android.permission.VIBRATE',
            ],
          ),
          '',
        ),
      );

      Object? caught;
      try {
        await device.launch('/path/to/app.apk');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      final message = caught.toString();
      expect(message, contains('com.example.app'));
      expect(message, contains('/path/to/app.apk'));
      expect(message, contains('android.permission.INTERNET'));
      expect(message, contains('Dart VM service'));
      expect(message, contains('android/app/src/debug/AndroidManifest.xml'));
      expect(message, contains('debug_manifest'));

      // Failed before starting the activity or tailing logcat.
      expect(calls.any((c) => c.$2.contains('am')), isFalse);
      expect(calls.any((c) => c.$2.contains('logcat')), isFalse);
    });

    test('fails when the package requests no permissions at all', () async {
      final device = makeDevice(
        calls: [],
        logcat: FakeProcess(),
        onDumpsys: (args) async => ProcessResult(
          0,
          0,
          dumpsysOutput(
            package: 'com.example.app',
            requestedPermissions: const [],
          ),
          '',
        ),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('android.permission.INTERNET'),
          ),
        ),
      );
    });

    test('surfaces dumpsys query failure instead of skipping', () async {
      final device = makeDevice(
        calls: [],
        logcat: FakeProcess(),
        onDumpsys: (args) async =>
            ProcessResult(0, 1, '', 'error: device offline'),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('dumpsys'), contains('error: device offline')),
          ),
        ),
      );
    });

    test('surfaces missing package record as an error', () async {
      final device = makeDevice(
        calls: [],
        logcat: FakeProcess(),
        onDumpsys: (args) async =>
            ProcessResult(0, 0, 'Unable to find package: com.example.app', ''),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('dumpsys'), contains('com.example.app')),
          ),
        ),
      );
    });

    test('does not run when the launch expects no VM service', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();
      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );
      expect(device.expectsVmService, isFalse);

      unawaited(fakeLogcat.outputAttached.then((_) => fakeLogcat.complete(0)));

      await device.launch('/path/to/app.apk');

      expect(calls.any((c) => c.$2.contains('dumpsys')), isFalse);
      expect(calls.any((c) => c.$2.contains('am')), isTrue);
    });
  });

  group('MacOSDevice.launch', () {
    test('extracts .app from .zip before launching', () async {
      final calls = <(String, List<String>)>[];
      final fakeAppProcess = FakeProcess();

      final device = MacOSDevice(
        runProcess: (exe, args) async {
          calls.add((exe, args));
          if (exe == 'unzip') {
            // Simulate unzip by creating an .app directory.
            final dest = args.last;
            Directory(
              '$dest/MyApp.app/Contents/MacOS',
            ).createSync(recursive: true);
            File('$dest/MyApp.app/Contents/MacOS/MyApp').writeAsStringSync('');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeAppProcess;
        },
      );

      // Emit VM service URI then complete the process so launch doesn't hang.
      unawaited(
        fakeAppProcess.outputAttached.then(
          (_) => fakeAppProcess.emitStdout(
            'The Dart VM service is listening on '
            'http://127.0.0.1:12345/test=/',
          ),
        ),
      );

      await device.launch('/path/to/app.zip');

      // Should have called unzip.
      final unzipCall = calls.firstWhere((c) => c.$1 == 'unzip');
      expect(unzipCall.$2, contains('/path/to/app.zip'));

      // Should have started the extracted executable.
      final startCalls = calls
          .where((c) => c.$1 != 'unzip' && c.$1 != 'xcrun')
          .toList();
      expect(startCalls, isNotEmpty);
      expect(startCalls.last.$1, contains('MyApp'));
    });

    test('launches .app bundle directly', () async {
      final calls = <(String, List<String>)>[];
      final fakeAppProcess = FakeProcess();

      final device = MacOSDevice(
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeAppProcess;
        },
      );

      // Emit VM service URI so launch doesn't hang waiting for it.
      unawaited(
        fakeAppProcess.outputAttached.then(
          (_) => fakeAppProcess.emitStdout(
            'The Dart VM service is listening on '
            'http://127.0.0.1:12345/test=/',
          ),
        ),
      );

      await device.launch('/path/to/MyApp.app');

      expect(calls, hasLength(1));
      expect(calls[0].$1, '/path/to/MyApp.app/Contents/MacOS/MyApp');
    });
  });

  // The app's stdout and stderr keep flowing after `_discoverVmServiceUri`
  // matches the VM-service announcement, and the OS pipes stay drained.
  // Parameterised over the three desktop devices, which share the launch path.
  group('desktop app output forwarding', () {
    // A real bundle on disk: WindowsDevice copies it out of bazel-out before
    // launching, so a made-up path would fail there for reasons that have
    // nothing to do with log forwarding.
    late Directory bundleRoot;
    setUp(() {
      bundleRoot = Directory.systemTemp.createTempSync('desktop_launch_test');
      Directory(p.join(bundleRoot.path, 'MyApp.app')).createSync();
      File(
        p.join(bundleRoot.path, 'MyApp.app', 'MyApp.app.exe'),
      ).writeAsStringSync('exe');
    });
    tearDown(() => bundleRoot.deleteSync(recursive: true));

    /// Builds [device] with an injected [FakeProcess], drives it through a
    /// launch, and hands the test the live instance.
    Future<(AppInstance, FakeProcess)> launchWith(
      Device Function(ProcessStarter) build, {
      List<AppLogLine>? sink,
    }) async {
      final proc = FakeProcess();
      final device = build((exe, args) async => proc);
      final pending = device.launch(
        p.join(bundleRoot.path, 'MyApp.app'),
        onLog: sink == null ? null : sink.add,
      );
      // The launch must be listening before the announcement is emitted;
      // FakeProcess streams are live, not replayed.
      await proc.outputAttached;
      proc.emitStdout(_vmServiceLine);
      final instance = await pending;
      return (instance, proc);
    }

    final devices = <String, Device Function(ProcessStarter)>{
      'MacOSDevice': (start) => MacOSDevice(
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: start,
      ),
      'LinuxDevice': (start) => LinuxDevice(
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: start,
      ),
      // Staged inside `bundleRoot` so the tearDown takes it: these tests never
      // reach `stop()`, and the default staging directory lands in the system
      // temp root.
      'WindowsDevice': (start) => WindowsDevice(
        startProcess: start,
        makeStagingDir: () =>
            Directory(p.join(bundleRoot.path, 'staged')).absolute
              ..createSync(recursive: true),
      ),
    };

    devices.forEach((name, build) {
      group(name, () {
        test(
          'keeps forwarding stdout after the VM service is discovered',
          () async {
            final (instance, proc) = await launchWith(build);
            expect(
              instance.vmServiceUri,
              isNotNull,
              reason: 'discovery itself must still work',
            );

            proc.emitStdout('flutter: after discovery');
            proc.emitStdout('flutter: still going');
            await pumpEventQueue();

            final texts = instance.logs.read(0).lines.map((l) => l.text);
            expect(texts, contains('flutter: after discovery'));
            expect(texts, contains('flutter: still going'));
          },
        );

        test(
          'keeps forwarding stderr after the VM service is discovered',
          () async {
            final (instance, proc) = await launchWith(build);

            proc.emitStderr('NSLog-style native message\n');
            await pumpEventQueue();

            final line = instance.logs
                .read(0)
                .lines
                .firstWhere((l) => l.text.contains('NSLog-style'));
            expect(
              line.isError,
              isTrue,
              reason: 'stderr output must be flagged as an error channel',
            );
          },
        );

        test('delivers output emitted before discovery completes', () async {
          final sink = <AppLogLine>[];
          final proc = FakeProcess();
          final device = build((exe, args) async => proc);
          final pending = device.launch(
            p.join(bundleRoot.path, 'MyApp.app'),
            onLog: sink.add,
          );
          await proc.outputAttached;

          // A startup print that lands before the announcement — the case that
          // matters most when an app dies before ever binding a VM service.
          proc.emitStdout('flutter: early startup line');
          await pumpEventQueue();
          expect(
            sink.map((l) => l.text),
            contains('flutter: early startup line'),
            reason:
                'output must reach the sink during launch, not be held '
                'until launch() returns',
          );

          proc.emitStdout(_vmServiceLine);
          await pending;
        });

        test('onLog receives post-discovery lines exactly once', () async {
          final sink = <AppLogLine>[];
          final (_, proc) = await launchWith(build, sink: sink);

          proc.emitStdout('flutter: only once');
          await pumpEventQueue();

          expect(
            sink.where((l) => l.text == 'flutter: only once'),
            hasLength(1),
          );
        });

        test(
          'buffers output so a late reader still sees startup lines',
          () async {
            final (instance, proc) = await launchWith(build);
            proc.emitStdout('flutter: printed before anyone read');
            await pumpEventQueue();

            // A consumer attaching now (the HTTP /logs endpoint, say) still sees
            // everything from the beginning of the run.
            final texts = instance.logs.read(0).lines.map((l) => l.text);
            expect(texts, contains(_vmServiceLine));
            expect(texts, contains('flutter: printed before anyone read'));
          },
        );

        test('stop() closes the log stream', () async {
          final (instance, _) = await launchWith(build);
          final device = build((exe, args) async => FakeProcess());

          await device.stop(instance);
          expect(instance.logs.isClosed, isTrue);
        });
      });
    });
  });

  // `adb logcat` carries the whole device's logging, so the dev tool filters
  // host-side (as flutter_tools does). An adb-level `flutter:I *:S` filter
  // hides Java crashes and VM messages entirely.
  group('androidLogFilter', () {
    String? filter(String line) => androidLogFilter(line);

    test('keeps Dart print output', () {
      expect(
        filter('01-02 03:04:05.678 I/flutter ( 1234): hello'),
        'I/flutter ( 1234): hello',
      );
    });

    test('strips the -v time timestamp prefix', () {
      expect(
        filter('01-02 03:04:05.678 I/flutter ( 1234): hello'),
        isNot(startsWith('01-02')),
      );
    });

    test('keeps the VM-service announcement, so discovery still works', () {
      const announcement =
          'The Dart VM service is listening on http://127.0.0.1:1234/abc=/';
      final kept = filter(
        '01-02 03:04:05.678 I/flutter ( 1234): $announcement',
      );
      expect(kept, isNotNull);
      expect(vmServiceUriPattern.hasMatch(kept!), isTrue);
    });

    test('keeps uncaught Java exceptions', () {
      expect(
        filter('01-02 03:04:05.678 E/AndroidRuntime( 1234): FATAL EXCEPTION'),
        'E/AndroidRuntime( 1234): FATAL EXCEPTION',
        reason: 'a fatal-exception line must survive the filter',
      );
    });

    test('keeps DartVM messages', () {
      expect(
        filter('01-02 03:04:05.678 I/DartVM  ( 1234): vm message'),
        isNotNull,
      );
    });

    test('keeps Java stderr', () {
      expect(
        filter('01-02 03:04:05.678 W/System.err( 1234): trace line'),
        isNotNull,
      );
    });

    test('keeps any fatal log regardless of tag', () {
      expect(
        filter('01-02 03:04:05.678 F/libc    ( 1234): Fatal signal 11'),
        isNotNull,
      );
    });

    test('drops unrelated system logging', () {
      expect(
        filter('01-02 03:04:05.678 I/WifiService( 999): scan results'),
        isNull,
      );
      expect(
        filter('01-02 03:04:05.678 D/SensorManager( 42): reading'),
        isNull,
      );
    });

    test('drops logcat boundary banners', () {
      expect(filter('--------- beginning of main'), isNull);
    });

    test('drops known-inactionable noise that would otherwise match', () {
      expect(
        filter(
          '01-02 03:04:05.678 F/SurfaceSyncer( 22636): '
          'Failed to find sync for id=9',
        ),
        isNull,
      );
    });

    test('is case-insensitive on the flutter tag', () {
      expect(filter('01-02 03:04:05.678 I/Flutter ( 1234): hi'), isNotNull);
    });

    test('keeps ActivityManager lines only when they mention the app', () {
      expect(
        filter(
          '01-02 03:04:05.678 W/ActivityManager( 42): '
          'Force stopping com.example.flutter app',
        ),
        isNotNull,
      );
      expect(
        filter(
          '01-02 03:04:05.678 W/ActivityManager( 42): '
          'Unrelated service churn',
        ),
        isNull,
      );
    });

    test('drops informational lines from allowlisted crash tags', () {
      // AndroidRuntime is only interesting at W/E/F.
      expect(
        filter('01-02 03:04:05.678 I/AndroidRuntime( 1): starting'),
        isNull,
      );
    });
  });

  group('parseLogcatLine', () {
    test('splits level, tag and message from a -v time record', () {
      final line = parseLogcatLine(
        '01-02 03:04:05.678 E/AndroidRuntime( 1234): boom',
      )!;
      expect(line.level, 'E');
      expect(line.tag, 'AndroidRuntime');
      expect(line.message, 'boom');
    });

    test('handles a space-padded pid', () {
      final line = parseLogcatLine('01-02 03:04:05.678 I/flutter (  987): hi')!;
      expect(line.tag, 'flutter');
      expect(line.message, 'hi');
    });

    test('handles a dotted tag', () {
      expect(
        parseLogcatLine('01-02 03:04:05.678 W/System.err( 1): x')!.tag,
        'System.err',
      );
    });

    test('display drops the timestamp but keeps level, tag and pid', () {
      expect(
        parseLogcatLine('01-02 03:04:05.678 I/flutter ( 1234): hello')!.display,
        'I/flutter ( 1234): hello',
      );
    });

    test('returns null for a banner', () {
      expect(parseLogcatLine('--------- beginning of main'), isNull);
    });

    test('returns null for an unparseable line', () {
      expect(parseLogcatLine('garbage'), isNull);
    });
  });

  group('iOS Simulator log capture', () {
    test('the output predicate scopes to the app process', () {
      final predicate = iosSimulatorLogPredicate('MyApp');
      expect(predicate, contains('processImagePath ENDSWITH "MyApp"'));
      expect(predicate, contains('eventType = logEvent'));
    });

    test('the output predicate filters known noise', () {
      final predicate = iosSimulatorLogPredicate('MyApp');
      expect(
        predicate,
        contains('NOT(eventMessage BEGINSWITH "assertion failed: ")'),
      );
      expect(predicate, contains('libxpc.dylib'));
    });

    test('the output predicate admits Flutter engine messages', () {
      expect(
        iosSimulatorLogPredicate('MyApp'),
        contains('senderImagePath ENDSWITH "/Flutter"'),
      );
    });

    test('parseUnifiedLoggingLine extracts the message', () {
      expect(
        parseUnifiedLoggingLine('  "eventMessage" : "flutter: 21",'),
        'flutter: 21',
      );
    });

    test('parseUnifiedLoggingLine unescapes JSON string content', () {
      expect(
        parseUnifiedLoggingLine(r'  "eventMessage" : "a \"quoted\" word",'),
        'a "quoted" word',
      );
    });

    test('parseUnifiedLoggingLine ignores other JSON fields', () {
      expect(
        parseUnifiedLoggingLine('  "processImagePath" : "/x/MyApp",'),
        isNull,
      );
      expect(parseUnifiedLoggingLine('{'), isNull);
    });

    test('parseUnifiedLoggingLine survives malformed JSON', () {
      expect(
        parseUnifiedLoggingLine('  "eventMessage" : "unterminated'),
        isNull,
      );
    });

    test('launch spawns a second log stream for app output', () async {
      final started = <(String, List<String>)>[];
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async {
          started.add((exe, args));
          return FakeProcess()..complete(0);
        },
      );

      await device.launch('/path/to/MyApp.app');

      final logStreams = started.where((c) => c.$2.contains('stream')).toList();
      expect(
        logStreams,
        hasLength(2),
        reason: 'one narrow stream for discovery, one for app output',
      );

      // Discovery keeps its content match; output gets the process-scoped
      // predicate. Merging them would make discovery depend on the output
      // predicate's NOT(...) clauses.
      expect(
        logStreams.any((c) => c.$2.any((a) => a.contains('Dart VM service'))),
        isTrue,
      );
      expect(
        logStreams.any((c) => c.$2.any((a) => a.contains('processImagePath'))),
        isTrue,
      );
    });

    test('--start-paused is passed to the app, after the bundle id', () async {
      // simctl treats everything after the bundle id as the app's argv, which
      // is where the iOS embedder reads engine switches from.
      final runs = <(String, List<String>)>[];
      final spawned = <FakeProcess>[];
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          runs.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          final p = FakeProcess();
          spawned.add(p);
          // Ending the discovery stream is what lets launch return.
          unawaited(p.outputAttached.then((_) => p.complete(0)));
          return p;
        },
      )..startPaused = true;

      await device.launch('/path/to/MyApp.app');

      final launchCall = runs.firstWhere(
        (c) => c.$2.contains('launch') && c.$2.contains('simctl'),
      );
      expect(launchCall.$2.last, '--start-paused');
      expect(launchCall.$2[launchCall.$2.length - 2], 'com.example.test');
    });

    test('the app-output stream is killed on stop', () async {
      final spawned = <FakeProcess>[];
      // The launch spawns the discovery stream first and the app-output
      // stream second, and only subscribes to discovery after the simctl
      // launch call — so the test has to wait for both to exist *and* both to
      // be listening before it emits anything into these broadcast streams.
      final bothSpawned = Completer<void>();
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async {
          final p = FakeProcess();
          spawned.add(p);
          if (spawned.length == 2 && !bothSpawned.isCompleted) {
            bothSpawned.complete();
          }
          return p;
        },
      );

      final pending = device.launch('/path/to/MyApp.app');
      await bothSpawned.future;
      await Future.wait([for (final p in spawned) p.outputAttached]);
      // Complete the discovery stream so launch returns.
      for (final p in spawned) {
        p.emitStdout('  "eventMessage" : "$_vmServiceLine",');
      }
      final instance = await pending;

      expect(
        instance.auxiliaryProcesses,
        isNotEmpty,
        reason: 'the second stream must be tracked so stop() can kill it',
      );

      await device.stop(instance);
      for (final aux in instance.auxiliaryProcesses) {
        await expectLater(aux.exitCode, completes);
      }
    });
  });

  group('MacOSDevice.screenshot', () {
    test(
      'throws structured error when bundled helper binary is missing',
      () async {
        // The macOS native screenshot path invokes a bundled Swift binary via
        // runfiles (analogous to WindowsDevice). Under unit-test runfiles the
        // binary isn't reachable, so the observable contract is the error that
        // points at the build target.
        final device = MacOSDevice();
        Object? caught;
        try {
          await device.screenshot(
            AppInstance(process: FakeProcess()),
            '/tmp/macos.png',
          );
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<StateError>());
        expect(
          caught.toString(),
          contains('bazel build //tools/dev_tool:flutter_bazel'),
        );
      },
    );
  });

  group('runProcessBounded', () {
    test(
      'kills a helper that never answers, and quotes what it did say',
      () async {
        // The capture runs inside an HTTP handler, so a helper that never exits
        // is a request held open forever — the caller learns nothing at all,
        // which is worse than any error it could have been told. `Process.run`
        // could not express this: no bound, and no handle to kill through.
        final helper = FakeProcess();
        final started = <(String, List<String>, Map<String, String>)>[];

        final pending = runProcessBounded(
          (exe, args, env) async {
            started.add((exe, args, env));
            return helper;
          },
          '/bundled/screenshot',
          const ['--pid', '4242'],
          environment: const {'RUNFILES_MANIFEST_FILE': '/manifest'},
          bound: const Duration(milliseconds: 50),
          what: 'The bundled macOS screenshot helper',
        );

        // Said before the wedge, and only reachable because both streams are
        // drained from the moment the process exists: a read started after the
        // deadline would have lost this.
        await helper.outputAttached;
        helper.emitStderr('enumerating windows');

        await expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('The bundled macOS screenshot helper'),
                contains('did not answer within 50ms and was killed'),
                contains('enumerating windows'),
              ),
            ),
          ),
        );
        expect(helper.signals, [ProcessSignal.sigkill]);
        expect(started.single.$1, '/bundled/screenshot');
        expect(started.single.$3['RUNFILES_MANIFEST_FILE'], '/manifest');
      },
    );

    test('says so plainly when the helper wedged without a word', () async {
      final helper = FakeProcess();

      await expectLater(
        runProcessBounded(
          (exe, args, env) async => helper,
          '/bundled/screenshot',
          const [],
          environment: const {},
          bound: const Duration(milliseconds: 50),
          what: 'The bundled macOS screenshot helper',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('on stderr: (nothing)'),
          ),
        ),
      );
    });

    test('a helper that answers in time is reported whole', () async {
      final helper = FakeProcess();

      final pending = runProcessBounded(
        (exe, args, env) async => helper,
        '/bundled/screenshot',
        const [],
        environment: const {},
        bound: const Duration(seconds: 30),
        what: 'The bundled macOS screenshot helper',
      );

      await helper.outputAttached;
      helper.emitStdout('wrote /tmp/shot.png');
      helper.emitStderr('skipped one zero-sized window');
      helper.complete(0);

      final result = await pending;
      expect(result.exitCode, 0);
      expect(result.stdout, contains('wrote /tmp/shot.png'));
      expect(result.stderr, contains('skipped one zero-sized window'));
      expect(helper.killed, isFalse);
    });
  });

  group('LinuxDevice.screenshot', () {
    test('uses scrot when no vmClient', () async {
      final calls = <(String, List<String>)>[];

      final device = LinuxDevice(
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/linux.png');

      expect(calls, hasLength(1));
      expect(calls[0].$1, 'scrot');
      expect(calls[0].$2, ['/tmp/linux.png']);
    });
  });

  group('WindowsDevice.launch staging', () {
    // Windows keeps an exclusive lock on a running executable image, so an app
    // launched straight out of `bazel-out` makes the next bundling action fail
    // with "failed to delete output files ... app.exe (Permission denied)" —
    // which is every `app.restart` that follows a real source edit. The launch
    // must therefore come from a copy.
    late Directory sandbox;
    late Directory bundle;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('win_stage_test');
      bundle = Directory(p.join(sandbox.path, 'bazel-out', 'app'))
        ..createSync(recursive: true);
      File(p.join(bundle.path, 'app.exe')).writeAsStringSync('exe');
      Directory(
        p.join(bundle.path, 'data', 'flutter_assets'),
      ).createSync(recursive: true);
      File(
        p.join(bundle.path, 'data', 'flutter_assets', 'AssetManifest.json'),
      ).writeAsStringSync('{}');
    });

    tearDown(() => sandbox.deleteSync(recursive: true));

    /// A device whose staging directories are numbered, so a relaunch is
    /// distinguishable from a reuse.
    ({WindowsDevice device, List<String> launched, List<FakeProcess> procs})
    makeDevice() {
      final launched = <String>[];
      final procs = <FakeProcess>[];
      var n = 0;
      final device = WindowsDevice(
        makeStagingDir: () =>
            Directory(p.join(sandbox.path, 'staged${n++}'))..createSync(),
        startProcess: (exe, args) async {
          launched.add(exe);
          final proc = FakeProcess();
          procs.add(proc);
          Future<void>(() => proc.emitStdout(_vmServiceLine));
          return proc;
        },
      );
      return (device: device, launched: launched, procs: procs);
    }

    test('launches a copy, never the path bazel will rewrite', () async {
      final h = makeDevice();
      await h.device.launch(bundle.path);

      expect(
        p.isWithin(bundle.path, h.launched.single),
        isFalse,
        reason: 'must not run from bazel-out: ${h.launched.single}',
      );
      expect(File(h.launched.single).existsSync(), isTrue);
    });

    test('copies the whole bundle, not just the executable', () async {
      // The runner resolves `data/flutter_assets` relative to its own
      // executable, so a lone .exe copy renders nothing.
      final h = makeDevice();
      await h.device.launch(bundle.path);

      final asset = p.join(
        p.dirname(h.launched.single),
        'data',
        'flutter_assets',
        'AssetManifest.json',
      );
      expect(File(asset).existsSync(), isTrue);
    });

    test('a relaunch stages afresh and drops the previous copy', () async {
      // `app.restart` relaunches when native libraries changed. Reusing the
      // old directory would run the previous build's assets.
      final h = makeDevice();
      await h.device.launch(bundle.path);
      final first = h.launched.single;

      File(
        p.join(bundle.path, 'data', 'flutter_assets', 'AssetManifest.json'),
      ).writeAsStringSync('{"new":true}');
      await h.device.launch(bundle.path);
      final second = h.launched.last;

      expect(second, isNot(first));
      expect(
        File(first).existsSync(),
        isFalse,
        reason: 'the superseded copy must not be left behind',
      );
      final asset = p.join(
        p.dirname(second),
        'data',
        'flutter_assets',
        'AssetManifest.json',
      );
      expect(File(asset).readAsStringSync(), '{"new":true}');
    });

    test('stop removes the copy it made', () async {
      final h = makeDevice();
      await h.device.launch(bundle.path);
      final launched = h.launched.single;

      h.procs.single.complete(0);
      await h.device.stop(AppInstance(process: h.procs.single));

      expect(File(launched).existsSync(), isFalse);
    });
  });

  group('WindowsDevice.screenshot', () {
    test(
      'throws structured error when bundled dxcam binary is missing',
      () async {
        // The implementation uses `resolveRunfileWithManifest` to locate
        // the bundled dxcam `py_binary` and shells to it directly via
        // `Process.run`; it doesn't go through the injected `runProcess`
        // hook. Under unit-test runfiles the tool isn't reachable, so the
        // observable contract is the actionable error that points at the
        // build target.
        final device = WindowsDevice();
        Object? caught;
        try {
          await device.screenshot(
            AppInstance(process: FakeProcess()),
            r'C:\tmp\win.png',
          );
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<StateError>());
        expect(
          caught.toString(),
          contains('bazel build //tools/dev_tool:flutter_bazel'),
        );
      },
    );
  });

  group('AndroidDevice.screenshot', () {
    test('uses adb screencap when no vmClient', () async {
      final calls = <(String, List<String>)>[];

      final device = AndroidDevice(
        deviceId: '58051JEBF01271',
        adbPath: 'adb',
        startScreenshotProcess: (exe, args) async {
          calls.add((exe, args));
          final adb = FakeProcess();
          // Answer only once the bounded runner is reading both channels;
          // output emitted before that is dropped by a broadcast controller.
          unawaited(adb.outputAttached.then((_) => adb.complete(0)));
          return adb;
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/android.png');

      final adbCalls = calls.where((c) => c.$1 == 'adb').toList();
      expect(adbCalls.length, 3); // screencap, pull, rm
    });

    // The capture's only caller is an HTTP handler with no bound of its own
    // (`http_control_channel.dart`, `_handleNativeScreenshot`), so an `adb`
    // that never returns is a request held open forever — the caller is left
    // with nothing to act on, which is worse than any error it could be told.
    // `Process.run` cannot express the bound: no deadline, and no handle to
    // kill through.
    test(
      'kills an adb that never answers rather than holding the request',
      () async {
        final wedged = FakeProcess();
        final device = AndroidDevice(
          deviceId: '58051JEBF01271',
          adbPath: 'adb',
          startScreenshotProcess: (exe, args) async => wedged,
        )..screenshotBound = const Duration(milliseconds: 50);

        await expectLater(
          device.screenshot(AppInstance(process: FakeProcess()), '/tmp/a.png'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('adb screencap'), contains('was killed')),
            ),
          ),
        );
        expect(wedged.signals, [ProcessSignal.sigkill]);
      },
    );

    /// On an emulator `adb screencap` can report success and return nothing,
    /// while the emulator console returns the real image.
    ///
    /// How much of the screen goes blank varies with the AVD and the GPU mode
    /// and is deliberately not relied on — see `AndroidDevice.screenshot`. The
    /// invariant these tests pin is only that an emulator is captured through
    /// its console and a physical device through `screencap`, decided by which
    /// kind of device it is rather than by looking at the pixels.
    group('on an emulator', () {
      late Directory captured;

      setUp(() {
        captured = Directory.systemTemp.createTempSync('emu_shot_test');
      });
      tearDown(() => captured.deleteSync(recursive: true));

      /// An emulator whose console capture writes [files] into the directory
      /// it is handed — the emulator names the file itself, so a caller can
      /// only look for what turned up.
      AndroidDevice emulator(List<String> files) => AndroidDevice(
        deviceId: 'emulator-5554',
        adbPath: 'adb',
        startScreenshotProcess: (exe, args) async {
          final dir = args.last;
          for (final f in files) {
            File(p.join(dir, f)).writeAsStringSync('png-bytes-$f');
          }
          final adb = FakeProcess();
          // `adb emu` answers OK even when it wrote nothing at all, so the
          // exit code says nothing; every case here completes 0 on purpose.
          unawaited(adb.outputAttached.then((_) => adb.complete(0)));
          return adb;
        },
      );

      test('captures through the emulator console, not screencap', () async {
        final out = p.join(captured.path, 'shot.png');
        await emulator(['Screenshot_1788460401.png']).screenshot(
          AppInstance(process: FakeProcess()),
          out,
        );
        expect(File(out).readAsStringSync(), contains('png-bytes'));
      });

      test('passes the console command a directory of its own', () async {
        final calls = <List<String>>[];
        final device = AndroidDevice(
          deviceId: 'emulator-5554',
          adbPath: 'adb',
          startScreenshotProcess: (exe, args) async {
            calls.add(args);
            File(p.join(args.last, 'Screenshot_1.png')).writeAsStringSync('p');
            final adb = FakeProcess();
            unawaited(adb.outputAttached.then((_) => adb.complete(0)));
            return adb;
          },
        );
        await device.screenshot(
          AppInstance(process: FakeProcess()),
          p.join(captured.path, 'shot.png'),
        );
        expect(calls.single.take(5), [
          '-s',
          'emulator-5554',
          'emu',
          'screenrecord',
          'screenshot',
        ]);
        // A fresh directory per capture is what makes "exactly one PNG"
        // mean "the one this call produced" rather than "whatever is lying
        // around from the last one".
        expect(Directory(calls.single.last).existsSync(), isFalse);
      });

      // `adb emu screenrecord screenshot /nonexistent/dir` prints OK and
      // exits 0, so neither the exit code nor the console's own word can be
      // trusted. What turned up on disk is the only evidence the capture
      // happened.
      test('fails when the console wrote no PNG despite saying OK', () async {
        await expectLater(
          emulator([]).screenshot(
            AppInstance(process: FakeProcess()),
            p.join(captured.path, 'shot.png'),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('no PNG'), contains('emulator-5554')),
            ),
          ),
        );
      });

      test('fails rather than guess between several PNGs', () async {
        await expectLater(
          emulator(['Screenshot_1.png', 'Screenshot_2.png']).screenshot(
            AppInstance(process: FakeProcess()),
            p.join(captured.path, 'shot.png'),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('2 PNGs'),
            ),
          ),
        );
      });
    });

    test('the bound covers the whole capture, not each adb call', () async {
      // A capture is three adb calls. One deadline across all three is what
      // bounds what the caller actually waits for; a bound per call would let
      // the endpoint hold its request for three times the number written down.
      const budget = Duration(milliseconds: 500);
      final started = <FakeProcess>[];
      final device = AndroidDevice(
        deviceId: '58051JEBF01271',
        adbPath: 'adb',
        startScreenshotProcess: (exe, args) async {
          final adb = FakeProcess();
          started.add(adb);
          // The first two answer, but slowly enough to eat most of the
          // budget; only the third wedges.
          if (started.length < 3) {
            unawaited(
              adb.outputAttached
                  .then(
                    (_) =>
                        Future<void>.delayed(const Duration(milliseconds: 150)),
                  )
                  .then((_) => adb.complete(0)),
            );
          }
          return adb;
        },
      )..screenshotBound = budget;

      await expectLater(
        device.screenshot(AppInstance(process: FakeProcess()), '/tmp/a.png'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('adb rm of the captured file'),
              // The number the third call was killed on is what separates the
              // two designs: with one deadline it is whatever the first two
              // left, and it can never be the whole budget.
              isNot(contains('within ${budget.inMilliseconds}ms')),
            ),
          ),
        ),
      );
      expect(started, hasLength(3));
      expect(started.last.signals, [ProcessSignal.sigkill]);
    });
  });

  group('IOSSimulatorDevice.screenshot', () {
    test('calls simctl io screenshot', () async {
      final calls = <(String, List<String>)>[];

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/ios.png');

      expect(calls, hasLength(1));
      expect(calls[0].$1, 'xcrun');
      expect(calls[0].$2, [
        'simctl',
        'io',
        'TEST-UDID',
        'screenshot',
        '/tmp/ios.png',
      ]);
    });

    test('throws on simctl screenshot failure', () async {
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async {
          if ((args as List).contains('screenshot')) {
            return ProcessResult(0, 1, '', 'SCREENSHOT_FAILED');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      expect(
        () => device.screenshot(instance, '/tmp/shot.png'),
        throwsStateError,
      );
    });
  });

  group('Device.screenshot', () {
    test('throws UnsupportedError when no vmClient provided', () {
      final device = _MinimalDevice();
      final instance = AppInstance(process: FakeProcess());
      expect(
        () => device.screenshot(instance, '/tmp/shot.png'),
        throwsUnsupportedError,
      );
    });
  });

  // The physical-device launch is a six-step dance (devicectl --console →
  // pid lookup → lldb attach → resume → mDNS discovery), and the app's console
  // output rides the same devicectl process throughout. Faking the whole
  // sequence is the only way to prove output survives it.
  group('IOSDevice.launch', () {
    final sockets = <ServerSocket>[];
    tearDown(() async {
      for (final s in sockets) {
        await s.close();
      }
      sockets.clear();
    });

    /// The bundle `devicectl install` reports installing. Every process
    /// running inside that bundle has an `executable` beginning with this
    /// string, which is the only handle a launch has on the app's pid: an iOS
    /// executable path is `…/<uuid>/Runner.app/Runner` and never contains the
    /// bundle id. Shaped after the fixtures in flutter_tools'
    /// `test/general.shard/ios/core_devices_test.dart`.
    const installationUrl =
        'file:///private/var/containers/Bundle/Application/'
        '12345E6A-7F89-0C12-345E-F6A7E890CFF1/Runner.app/';

    /// What `devicectl install --json-output` writes when it works.
    const installedJson =
        '{"result":{"installedApplications":'
        '[{"installationURL":"$installationUrl"}]}}';

    /// One entry of what `devicectl info processes --json-output` writes.
    Map<String, Object?> runningProcess({
      required int pid,
      String executable = '${installationUrl}Runner',
    }) => {'processIdentifier': pid, 'executable': executable};

    /// Everything one faked launch hands back to the test.
    ///
    /// [args] records every argument list passed to [Process.start], so a test
    /// can assert on what the launch actually asked devicectl to do.
    ///
    /// [installJson] is what `devicectl install` writes to its `--json-output`
    /// path; passing `null` makes it write nothing at all, which is one of the
    /// ways a launch can end up with no installationURL. [runningProcesses] is
    /// the list `info processes` answers with.
    Future<
      ({
        AppInstance instance,
        FakeProcess devicectl,
        FakeProcess lldb,
        List<List<String>> starts,
      })
    >
    launchFaked({
      String transportType = 'wired',
      List<String> deviceAddresses = const [],
      bool consoleExitsAtLaunch = false,
      String? installJson = installedJson,
      List<Map<String, Object?>>? runningProcesses,
      bool forwardBinds = true,
      FakeProcess? devicectlProcess,
      FakeProcess? lldbProcess,
      FakeProcess? iproxyProcess,
    }) async {
      final devicectl = devicectlProcess ?? FakeProcess();
      final lldb = lldbProcess ?? FakeProcess();
      final iproxy = iproxyProcess ?? FakeProcess();
      final starts = <List<String>>[];

      // A wired launch port-forwards the advertised VM-service port through
      // iproxy and waits for that forward to accept connections before
      // returning. Stand a real listener up on the port the advertisement
      // names, so the test exercises the whole launch rather than stopping at
      // a missing iproxy.
      final forward = await ServerSocket.bind('127.0.0.1', 0);
      // The probe connects to confirm the forward is live; drop each
      // connection rather than leaving it queued in the accept backlog, which
      // would stall `close()` in tearDown.
      forward.listen((socket) => socket.destroy());
      final forwardPort = forward.port;
      if (forwardBinds) {
        sockets.add(forward);
      } else {
        // A forward that never binds — what a launch sees when iproxy cannot
        // take the port. Closing the listener the OS just handed out is the
        // way to name a port with nothing behind it; if something else claims
        // it in the gap the launch succeeds and the test fails loudly, rather
        // than passing on a wait that never happened.
        await forward.close();
      }

      final mdns = MdnsVmServiceDiscovery(
        clientFactory: FakeMDnsClientFactory(
          records: dartVmServiceRecords(
            instance: 'com.example.test',
            host: 'Test-iPhone.local',
            port: forwardPort,
            authCode: 'test=',
            addresses: deviceAddresses,
          ),
        ).call,
      );

      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        mdns: mdns,
        runProcess: (exe, args) async {
          final out = args.contains('--json-output')
              ? args[args.indexOf('--json-output') + 1]
              : null;
          // `list devices`, `install app` and `info processes` all write their
          // answer to the file named by --json-output.
          if (args.contains('devices') && out != null) {
            File(out).writeAsStringSync(devicesJson(transportType));
          } else if (args.contains('install') && out != null) {
            if (installJson != null) File(out).writeAsStringSync(installJson);
          } else if (args.contains('processes') && out != null) {
            File(out).writeAsStringSync(
              json.encode({
                'result': {
                  'runningProcesses':
                      runningProcesses ?? [runningProcess(pid: 4242)],
                },
              }),
            );
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          starts.add([exe, ...args.cast<String>()]);
          // A distinct fake per helper: a launch owns three of them at once,
          // and one shared fake cannot say which of them a teardown reached.
          return switch (exe) {
            'lldb' => lldb,
            'iproxy' => iproxy,
            _ => devicectl,
          };
        },
      );

      // Script the lldb side: each command the launch issues gets the reply
      // its `waitFor` pattern is looking for.
      lldb.stdinLines.listen((line) {
        if (line.startsWith('breakpoint set')) {
          lldb.emitStdout('Breakpoint 1: where = Foo`NOTIFY...');
        } else if (line.startsWith('device process attach')) {
          lldb.emitStdout('Process 4242 stopped');
        } else if (line.startsWith('process continue')) {
          lldb.emitStdout('Process 4242 resuming');
        }
      });

      final pending = device.launch('/path/to/MyApp.app', onLog: null);
      // A launch that fails at the install step never starts devicectl at all,
      // so waiting on its output alone would hang out the test timeout on
      // exactly the failures these tests assert. Whichever settles first wins,
      // and a launch that threw rethrows here.
      await Future.any<Object?>([devicectl.outputAttached, pending]);

      if (consoleExitsAtLaunch) {
        // The console channel ends without ever printing a banner. The launch
        // gate is released by `onDone` instead.
        devicectl.complete(0);
      } else {
        // devicectl's banner releases the launch gate.
        devicectl.emitStdout('Launched application with com.example.test');
      }

      return (
        instance: await pending,
        devicectl: devicectl,
        lldb: lldb,
        starts: starts,
      );
    }

    // The engine's announcement never reaches this host on a physical device,
    // so the URI has to come from the app's mDNS advertisement — including the
    // auth code, without which the VM service refuses the connection.
    test('takes the VM service from the mDNS advertisement', () async {
      final r = await launchFaked();
      expect(r.instance.vmServiceUri, isNotNull);
      expect(r.instance.vmServiceUri!.host, '127.0.0.1');
      expect(r.instance.vmServiceUri!.path, '/test=/');
    });

    // The installationURL is what names the launched process, so a launch
    // that loses it has no way to recognise the app's pid and must fail at
    // the install step rather than search on.
    test('fails on install when devicectl writes no JSON at all', () async {
      await expectLater(
        launchFaked(installJson: null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('wrote no JSON'),
          ),
        ),
      );
    });

    test('fails on install when the JSON names no installationURL', () async {
      await expectLater(
        launchFaked(
          installJson:
              '{"result":{"installedApplications":[{"bundleID":'
              '"com.example.test"}]}}',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('named no installationURL'),
          ),
        ),
      );
    });

    test('fails on install when devicectl writes unreadable JSON', () async {
      await expectLater(
        launchFaked(installJson: 'not json at all'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('could not read'),
          ),
        ),
      );
    });

    // An app extension's executable lives inside the app bundle, so it
    // contains the installationURL too. Attaching the debugger to a widget
    // extension leaves the app itself stopped forever, waiting for a debugger
    // that went somewhere else — flutter/flutter#183263.
    test('skips app extensions when matching the launched process', () async {
      final r = await launchFaked(
        runningProcesses: [
          runningProcess(
            pid: 111,
            executable: '${installationUrl}PlugIns/Widget.appex/Widget',
          ),
          runningProcess(pid: 4242),
        ],
      );
      // The pid on the attach command is the only thing that says which
      // process the debugger went to. The scripted lldb answers *any* attach
      // with the same `Process 4242 stopped`, so a launch that merely reaches
      // a VM service proves nothing.
      expect(
        r.lldb.stdinBuffer.toString(),
        contains('device process attach --pid 4242'),
      );
      expect(
        r.lldb.stdinBuffer.toString(),
        isNot(contains('device process attach --pid 111')),
      );
      expect(r.instance.vmServiceUri, isNotNull);
    });

    test(
      'fails when no running process belongs to the installed bundle',
      () async {
        await expectLater(
          launchFaked(
            runningProcesses: [
              runningProcess(pid: 1, executable: 'file:///sbin/launchd'),
            ],
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('is the app installed at'),
            ),
          ),
        );
      },
    );

    // `stop` reaps every helper a launch starts, but it takes the AppInstance
    // a *successful* launch produced — so a launch that threw never reached it
    // and left whatever it had started running, with no handle anywhere to
    // reach them by.
    test(
      'a launch that fails before lldb still kills its console launcher',
      () async {
        final devicectl = FakeProcess();

        await expectLater(
          launchFaked(
            devicectlProcess: devicectl,
            runningProcesses: [
              runningProcess(pid: 1, executable: 'file:///sbin/launchd'),
            ],
          ),
          throwsA(isA<StateError>()),
        );

        // Left running, this keeps the app up on the phone and holds the only
        // channel its console output arrives on.
        expect(devicectl.killed, isTrue);
      },
    );

    // A forward that never binds is the likeliest way for a wired launch to
    // fail this late, and it is the one failure that happens *after* all three
    // helpers are up — so every one of them has to be reaped.
    test('a wired launch whose forward never binds kills every helper', () async {
      final devicectl = FakeProcess();
      final lldb = FakeProcess();
      final iproxy = FakeProcess();

      // Real elapsed time: `waitForLocalTcpPort` polls its 10s budget out, the
      // same wait a user sits through. There is no shorter failure past iproxy
      // — the lldb commands ahead of it wait 30s each.
      await expectLater(
        launchFaked(
          forwardBinds: false,
          devicectlProcess: devicectl,
          lldbProcess: lldb,
          iproxyProcess: iproxy,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('iproxy forward for the iOS VM service'),
          ),
        ),
      );

      expect(
        iproxy.killed,
        isTrue,
        reason: 'a surviving iproxy holds its host port indefinitely',
      );
      expect(
        lldb.killed,
        isTrue,
        reason: 'lldb holds the app itself, stopped, on the device',
      );
      expect(devicectl.killed, isTrue);
    });

    // Wired: the VM service binds to the device's loopback, so it is only
    // reachable through a forward.
    test('port-forwards the advertised port when wired', () async {
      final r = await launchFaked(transportType: 'wired');
      final iproxy = r.starts.where((a) => a.first == 'iproxy');
      expect(iproxy, hasLength(1));
      expect(iproxy.single, contains('TEST-UDID'));
      expect(r.instance.vmServiceUri!.host, '127.0.0.1');
    });

    // devicectl lists a CoreDevice UUID as `identifier` and the hardware UDID
    // separately. usbmuxd — which iproxy and lldb both go through — only knows
    // the hardware one; addressing it with the CoreDevice UUID yields a
    // forward that binds locally and then resets every connection, so the run
    // looks like it worked right up until DDS fails.
    test('addresses iproxy and lldb with the hardware UDID', () async {
      final r = await launchFaked(transportType: 'wired');
      expect(
        r.starts.firstWhere((a) => a.first == 'iproxy'),
        contains('TEST-UDID'),
      );
      expect(
        r.starts.firstWhere((a) => a.first == 'iproxy'),
        isNot(contains('TEST-COREDEVICE-ID')),
      );
    });

    test('does not bind the VM service to all interfaces when wired', () async {
      final r = await launchFaked(transportType: 'wired');
      final launch = r.starts.firstWhere((a) => a.contains('launch'));
      expect(launch, isNot(contains('--vm-service-host=0.0.0.0')));
    });

    // Wireless: there is no cable to forward through, so the VM service has to
    // listen on all interfaces and gets dialed at the device's own address.
    // The two halves must agree or the session silently has no VM service.
    test('binds the VM service to all interfaces when wireless', () async {
      final r = await launchFaked(
        transportType: 'localNetwork',
        deviceAddresses: ['192.168.1.244'],
      );
      final launch = r.starts.firstWhere((a) => a.contains('launch'));
      expect(launch, contains('--vm-service-host=0.0.0.0'));
    });

    test('dials the device address directly when wireless', () async {
      final r = await launchFaked(
        transportType: 'localNetwork',
        deviceAddresses: ['192.168.1.244'],
      );
      expect(r.instance.vmServiceUri!.host, '192.168.1.244');
      expect(
        r.starts.where((a) => a.first == 'iproxy'),
        isEmpty,
        reason: 'there is no cable to forward through',
      );
    });

    test(
      'keeps forwarding console output after VM-service discovery',
      () async {
        final r = await launchFaked();
        expect(
          r.instance.vmServiceUri,
          isNotNull,
          reason: 'discovery must still work',
        );

        r.devicectl.emitStderr('flutter: printed well after launch\n');
        await pumpEventQueue();

        expect(
          r.instance.logs.read(0).lines.map((l) => l.text),
          contains('flutter: printed well after launch'),
        );
      },
    );

    test('does not flag devicectl stderr as error output', () async {
      final r = await launchFaked();

      // devicectl routes the app's ordinary console output to stderr, so
      // flagging that channel would mark every print() as an error.
      r.devicectl.emitStderr('flutter: an ordinary print\n');
      await pumpEventQueue();

      final line = r.instance.logs
          .read(0)
          .lines
          .firstWhere((l) => l.text.contains('an ordinary print'));
      expect(line.isError, isFalse);
    });

    test('keeps draining lldb after launch returns', () async {
      // lldb outlives launch() and holds the debugserver that keeps the app's
      // JIT alive. Stop reading its pipes and it blocks on write once its
      // stdout buffer fills; a blocked lldb never services the process it
      // controls, so the app hangs on device until the dev tool is killed.
      final r = await launchFaked();

      // Far more than a pipe buffer would hold. If nothing is draining, a
      // real lldb would be blocked by now.
      for (var i = 0; i < 2000; i++) {
        r.lldb.emitStdout('lldb chatter line $i with padding ${'x' * 200}');
      }
      await pumpEventQueue();

      // The fake cannot block, so assert the property that matters: a live
      // reader is still attached to both channels.
      expect(
        r.lldb.stdoutHasListener,
        isTrue,
        reason: 'lldb stdout must stay drained for the process lifetime',
      );
      expect(
        r.lldb.stderrHasListener,
        isTrue,
        reason: 'lldb stderr carries the reason for real lldb failures',
      );
    });

    test('lldb output reaches the app log stream', () async {
      // Upstream treats devicectl and lldb as one combined log source on a
      // CoreDevice under Xcode 26+, because the debugger carries output the
      // console stream may not.
      final r = await launchFaked();

      r.lldb.emitStdout('flutter: hello from the app');
      await pumpEventQueue();

      expect(
        r.instance.logs.read(0).lines.map((l) => l.text),
        contains('flutter: hello from the app'),
      );
    });

    test('lldb output survives devicectl exiting', () async {
      // devicectl --console exits when the app terminates, which is precisely
      // when lldb produces the output that explains why, so the shared stream
      // must outlive the first source to finish.
      final r = await launchFaked();

      r.devicectl.complete(0);
      await pumpEventQueue();

      r.lldb.emitStdout('flutter: Fatal error: index out of range');
      await pumpEventQueue();

      expect(
        r.instance.logs.read(0).lines.map((l) => l.text),
        contains('flutter: Fatal error: index out of range'),
        reason: 'the crash report arrives after the console channel is gone',
      );
    });

    test(
      'lldb output survives a console channel that ends before the attach',
      () async {
        // `devicectl --console` normally runs for the app's lifetime, but it can
        // end during the launch — the app was already running, or devicectl
        // detached — while the app itself stays up and `_findAppProcessId` still
        // answers. lldb attaches after that point, so if the console channel
        // being the only registered producer is enough to close the shared log
        // stream, every line for the rest of the run goes nowhere: mDNS
        // discovery does not read this stream, so nothing else fails and the run
        // proceeds in silence.
        final r = await launchFaked(consoleExitsAtLaunch: true);

        expect(
          r.instance.logs.isClosed,
          isFalse,
          reason: 'lldb is attached and is still a live source of output',
        );

        r.lldb.emitStdout('flutter: hello from the app');
        await pumpEventQueue();

        expect(
          r.instance.logs.read(0).lines.map((l) => l.text),
          contains('flutter: hello from the app'),
        );
      },
    );

    test(
      'the log stream closes once devicectl and lldb have both ended',
      () async {
        final r = await launchFaked();
        expect(r.instance.logs.isClosed, isFalse);

        r.devicectl.complete(0);
        await pumpEventQueue();
        expect(
          r.instance.logs.isClosed,
          isFalse,
          reason: 'lldb is still attached and still reporting',
        );

        r.lldb.complete(0);
        await pumpEventQueue();
        expect(
          r.instance.logs.isClosed,
          isTrue,
          reason: 'a reader must learn the run is over rather than hang',
        );
      },
    );
  });

  // `devicectl list devices` lists every device that has ever been paired,
  // including ones that are not attached now.
  group('parseDevicectlDevices', () {
    String devicesJson(List<Map<String, Object?>> devices) => json.encode({
      'result': {'devices': devices},
    });

    test('reads udid, name, transport and hostnames', () {
      final devices = parseDevicectlDevices(
        devicesJson([
          {
            'identifier': 'CORE-1',
            'hardwareProperties': {'udid': 'UDID-1'},
            'deviceProperties': {'name': 'Test iPhone'},
            'connectionProperties': {
              'transportType': 'wired',
              'localHostnames': [
                'Test-iPhone.coredevice.local',
                'UDID-1.coredevice.local',
              ],
            },
          },
        ]),
      );

      expect(devices, hasLength(1));
      expect(devices.single.udid, 'UDID-1');
      expect(devices.single.coreDeviceId, 'CORE-1');
      expect(devices.single.name, 'Test iPhone');
      expect(devices.single.transport, IOSDeviceTransport.wired);
      expect(
        devices.single.hostnames,
        contains('Test-iPhone.coredevice.local'),
      );
    });

    test('maps localNetwork to wireless', () {
      final devices = parseDevicectlDevices(
        devicesJson([
          {
            'identifier': 'CORE-1',
            'hardwareProperties': {'udid': 'UDID-1'},
            'connectionProperties': {'transportType': 'localNetwork'},
          },
        ]),
      );
      expect(devices.single.transport, IOSDeviceTransport.wireless);
    });

    // A device paired once and now sitting in a drawer still appears, with no
    // transport and `tunnelState: unavailable`. Choosing it produces a launch
    // that installs nothing and then waits out every timeout.
    test('drops a paired but unattached device', () {
      final devices = parseDevicectlDevices(
        devicesJson([
          {
            'identifier': 'CORE-GONE',
            'hardwareProperties': {'udid': 'GONE'},
            'connectionProperties': {
              'pairingState': 'paired',
              'tunnelState': 'unavailable',
            },
          },
          {
            'identifier': 'CORE-HERE',
            'hardwareProperties': {'udid': 'HERE'},
            'connectionProperties': {'transportType': 'wired'},
          },
        ]),
      );
      expect(devices.map((d) => d.udid), ['HERE']);
    });

    test('falls back to potentialHostnames when there are no local ones', () {
      final devices = parseDevicectlDevices(
        devicesJson([
          {
            'identifier': 'CORE-1',
            'hardwareProperties': {'udid': 'UDID-1'},
            'connectionProperties': {
              'transportType': 'wired',
              'potentialHostnames': ['Some-iPhone.coredevice.local'],
            },
          },
        ]),
      );
      expect(devices.single.hostnames, ['Some-iPhone.coredevice.local']);
    });
  });

  group('IOSDevice device selection', () {
    IOSDevice deviceListing(
      List<Map<String, Object?>> devices, {
      String? udid,
    }) => IOSDevice(
      udid: udid,
      bundleId: 'com.example.test',
      runProcess: (exe, args) async {
        if (args.contains('devices') && args.contains('--json-output')) {
          File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
            json.encode({
              'result': {'devices': devices},
            }),
          );
          return ProcessResult(0, 0, '', '');
        }
        // Selection is what these tests are about, so stop the launch at
        // the next step rather than driving the whole device dance.
        return ProcessResult(0, 1, '', 'INSTALL_FAILED');
      },
      startProcess: (exe, args) async => FakeProcess(),
    );

    test(
      'ignores a paired but unattached device when auto-detecting',
      () async {
        final device = deviceListing([
          {
            'identifier': 'CORE-GONE',
            'hardwareProperties': {'udid': 'GONE'},
            'connectionProperties': {'tunnelState': 'unavailable'},
          },
        ]);

        await expectLater(
          device.launch('/path/to/MyApp.app'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('No iOS device is attached'),
            ),
          ),
        );
      },
    );

    // Picking one silently would look like a working run against the wrong
    // phone.
    test('refuses to guess between two attached devices', () async {
      final device = deviceListing([
        {
          'identifier': 'CORE-ONE',
          'hardwareProperties': {'udid': 'ONE'},
          'connectionProperties': {'transportType': 'wired'},
        },
        {
          'identifier': 'CORE-TWO',
          'hardwareProperties': {'udid': 'TWO'},
          'connectionProperties': {'transportType': 'localNetwork'},
        },
      ]);

      await expectLater(
        device.launch('/path/to/MyApp.app'),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('-d ios:<udid>'))
              .having((e) => e.message, 'message', contains('ONE')),
        ),
      );
    });

    // `devicectl list devices` prints the CoreDevice UUID, so that is what a
    // user copying from it will pass; Xcode shows the hardware UDID. Both name
    // the same device.
    test(
      'accepts either the hardware UDID or the CoreDevice identifier',
      () async {
        for (final requested in ['UDID-1', 'CORE-1']) {
          final device = deviceListing([
            {
              'identifier': 'CORE-1',
              'hardwareProperties': {'udid': 'UDID-1'},
              'connectionProperties': {'transportType': 'wired'},
            },
          ], udid: requested);

          // Gets past selection and stops at the faked install.
          await expectLater(
            device.launch('/path/to/MyApp.app'),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                contains('INSTALL_FAILED'),
              ),
            ),
          );
        }
      },
    );

    test(
      'says which devices are attached when the requested one is not',
      () async {
        final device = deviceListing([
          {
            'identifier': 'CORE-OTHER',
            'hardwareProperties': {'udid': 'OTHER'},
            'connectionProperties': {'transportType': 'wired'},
          },
        ], udid: 'MISSING');

        await expectLater(
          device.launch('/path/to/MyApp.app'),
          throwsA(
            isA<StateError>()
                .having((e) => e.message, 'message', contains('MISSING'))
                .having((e) => e.message, 'message', contains('OTHER')),
          ),
        );
      },
    );
  });

  group('IOSDevice', () {
    test('has correct name with udid', () {
      final device = IOSDevice(udid: 'TEST-UDID');
      expect(device.name, 'iOS (TEST-UDID)');
    });

    test('buildArgs is arm64 for physical device', () {
      final device = IOSDevice(udid: 'TEST-UDID');
      expect(device.buildArgs, ['--ios_multi_cpus=arm64']);
    });

    test('throws on devicectl install failure', () async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if ((args as List).contains('install')) {
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          }
          if (args.contains('devices') && args.contains('--json-output')) {
            File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
              json.encode({
                'result': {
                  'devices': [
                    {
                      'identifier': 'TEST-COREDEVICE-ID',
                      'hardwareProperties': {'udid': 'TEST-UDID'},
                      'connectionProperties': {'transportType': 'wired'},
                    },
                  ],
                },
              }),
            );
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(() => device.launch('/path/to/MyApp.app'), throwsStateError);
    });

    test('stop kills iproxy and devicectl', () async {
      final fakeDevicectl = FakeProcess();

      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => fakeDevicectl,
      );

      final instance = AppInstance(process: fakeDevicectl);
      await device.stop(instance);

      // Process should have been killed.
      expect(await fakeDevicectl.exitCode, -1);
    });
  });

  group('Device.applyTimeout', () {
    /// An [IOSDevice] that has resolved a device of the given transport.
    Future<IOSDevice> launchedDevice(String transportType) async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if (args.contains('devices') && args.contains('--json-output')) {
            File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
              json.encode({
                'result': {
                  'devices': [
                    {
                      'identifier': 'TEST-COREDEVICE-ID',
                      'hardwareProperties': {'udid': 'TEST-UDID'},
                      'connectionProperties': {'transportType': transportType},
                    },
                  ],
                },
              }),
            );
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 1, '', 'INSTALL_FAILED');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );
      // Resolution happens on the way to the faked install failure.
      await expectLater(device.launch('/path/to/MyApp.app'), throwsStateError);
      return device;
    }

    // A hot restart on hardware re-JITs the app through the lldb breakpoint,
    // which is minutes-scale work. The host default would abandon the RPC and
    // force-close the VM-service connection mid-restart, reporting "timed out"
    // for a restart that was going to succeed.
    test('is far longer on a physical iOS device than on a host', () {
      expect(
        IOSDevice(udid: 'X').applyTimeout,
        greaterThan(MacOSDevice().applyTimeout),
      );
      expect(
        IOSDevice(udid: 'X').applyTimeout,
        greaterThanOrEqualTo(const Duration(minutes: 1)),
      );
    });

    // Re-JITing the app over Wi-Fi costs several times what it costs over a
    // cable (see `IOSDevice.applyTimeout`), so a budget that fits a wired
    // restart abandons a wireless one mid-flight.
    test('is longer again when the device is on the network', () async {
      final wired = await launchedDevice('wired');
      final wireless = await launchedDevice('localNetwork');
      expect(wireless.applyTimeout, greaterThan(wired.applyTimeout));
    });

    test(
      'reports the hardware UDID once resolved, whatever was asked for',
      () async {
        final device = IOSDevice(
          udid: 'CORE-1',
          bundleId: 'com.example.test',
          runProcess: (exe, args) async {
            if (args.contains('devices') && args.contains('--json-output')) {
              File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
                json.encode({
                  'result': {
                    'devices': [
                      {
                        'identifier': 'CORE-1',
                        'hardwareProperties': {'udid': 'UDID-1'},
                        'connectionProperties': {'transportType': 'wired'},
                      },
                    ],
                  },
                }),
              );
              return ProcessResult(0, 0, '', '');
            }
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          },
          startProcess: (exe, args) async => FakeProcess(),
        );

        expect(device.udid, 'CORE-1', reason: 'nothing resolved yet');
        await expectLater(
          device.launch('/path/to/MyApp.app'),
          throwsStateError,
        );
        expect(
          device.udid,
          'UDID-1',
          reason: 'usbmuxd-backed tools cannot use the CoreDevice UUID',
        );
      },
    );

    test('a simulator keeps the host budget', () {
      expect(
        IOSSimulatorDevice(udid: 'X').applyTimeout,
        MacOSDevice().applyTimeout,
      );
    });
  });

  group('IOSDevice.screenshot', () {
    test('throws when not running in Bazel runfiles', () async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
      );

      final instance = AppInstance(process: FakeProcess());
      // Without runfiles, should throw telling user to build with bazel.
      expect(
        () => device.screenshot(instance, '/tmp/ios.png'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('bazel build'),
          ),
        ),
      );
    });
  });

  group('resolveRunfile', () {
    test('returns null when not in Bazel runfiles', () {
      final result = resolveRunfile('_main/some/nonexistent/path');
      expect(result, isNull);
    });
  });

  group('resolveDevices ios', () {
    test('resolves ios to IOSDevice', () {
      final devices = resolveDevices(['ios']);
      expect(devices.single, isA<IOSDevice>());
    });

    test('resolves ios:UDID to IOSDevice with udid', () {
      final devices = resolveDevices(['ios:ABC-123']);
      final device = devices.single as IOSDevice;
      expect(device.udid, 'ABC-123');
    });
  });

  group('extractPackageInfo', () {
    test('parses aapt2 dump badging output', () async {
      final info = await extractPackageInfo(
        '/fake/app.apk',
        aapt2Path: '/fake/aapt2',
        runProcess: (exe, args) async {
          return ProcessResult(
            0,
            0,
            "package: name='com.example.myapp' versionCode='1'\n"
                "launchable-activity: name='com.example.myapp.MainActivity'\n",
            '',
          );
        },
      );
      expect(info.packageName, 'com.example.myapp');
      expect(info.activityName, 'com.example.myapp.MainActivity');
    });

    test('throws naming the command that failed', () {
      expect(
        () => extractPackageInfo(
          '/fake/app.apk',
          aapt2Path: '/fake/aapt2',
          runProcess: (exe, args) async =>
              ProcessResult(0, 1, '', 'not a valid APK'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('/fake/aapt2 dump badging /fake/app.apk'),
              contains('not a valid APK'),
            ),
          ),
        ),
      );
    });
  });

  group('waitForLocalTcpPort', () {
    test('returns once a listener accepts', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(server.close);
      await waitForLocalTcpPort(server.port, what: 'test listener');
    });

    test('waits for a listener that binds late', () async {
      // Grab a free port, then release it so nothing is listening when the
      // wait starts; bind for real shortly after.
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close();

      ServerSocket? server;
      addTearDown(() => server?.close());
      final lateBind = Future<void>.delayed(
        const Duration(milliseconds: 300),
        () async => server = await ServerSocket.bind('127.0.0.1', port),
      );
      await waitForLocalTcpPort(port, what: 'late listener');
      await lateBind;
      expect(server, isNotNull);
    });

    test('throws a StateError naming the forward when nothing binds', () async {
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close();

      await expectLater(
        waitForLocalTcpPort(
          port,
          what: 'iproxy forward',
          budget: const Duration(milliseconds: 400),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('iproxy forward'),
          ),
        ),
      );
    });
  });

  group('desktopLaunchEnvironment', () {
    test('always asks the embedder for an ephemeral VM service port', () {
      // A fixed port collides across a multi-device run, and without one the
      // app binds no VM service at all — no hot reload, no DevTools.
      expect(
        desktopLaunchEnvironment(base: const {})['FLUTTER_VM_SERVICE_PORT'],
        '0',
      );
    });

    test('declares no engine switches when none were asked for', () {
      // FLUTTER_ENGINE_SWITCHES is a count the embedder iterates. Setting it
      // to 0 and setting nothing at all are the same to the engine, but the
      // absent form is what an unmodified launch has always looked like.
      final env = desktopLaunchEnvironment(base: const {});

      expect(env.keys, isNot(contains('FLUTTER_ENGINE_SWITCHES')));
      expect(
        env.keys.where((k) => k.startsWith('FLUTTER_ENGINE_SWITCH_')),
        isEmpty,
      );
    });

    test('passes start-paused as a counted engine switch', () {
      // The desktop embedders read switches from the environment and nowhere
      // else — the runner's argv goes to the Dart entrypoint, not the engine.
      final env = desktopLaunchEnvironment(startPaused: true, base: const {});

      expect(env['FLUTTER_ENGINE_SWITCHES'], '1');
      expect(env['FLUTTER_ENGINE_SWITCH_1'], 'start-paused=true');
    });

    test('inherits the environment the app is launched from', () {
      final env = desktopLaunchEnvironment(base: const {'HOME': '/home/dev'});

      expect(env['HOME'], '/home/dev');
    });
  });

  group('bounded teardown', () {
    /// Every log record the code under test emits while [body] runs.
    Future<List<LogRecord>> recording(Future<void> Function() body) async {
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      try {
        await body();
      } finally {
        await sub.cancel();
      }
      return records;
    }

    test('an app that ignores SIGTERM is escalated to SIGKILL, not waited on '
        'forever', () async {
      final process = FakeProcess()..ignoresSigterm = true;
      final device = MacOSDevice()
        ..teardownBound = const Duration(milliseconds: 50);

      // The bound is what makes this return at all: without it `stop` awaits
      // an `exitCode` that a SIGTERM-trapping process never completes, and
      // `flutter_bazel` never comes back.
      final records = await recording(
        () => device
            .stop(AppInstance(process: process))
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail(
                'stop() never returned: the teardown is '
                'still unbounded',
              ),
            ),
      );

      expect(
        process.signals,
        [ProcessSignal.sigterm, ProcessSignal.sigkill],
        reason:
            'SIGTERM is a request a wedged process can refuse; SIGKILL '
            'is the only escalation that is not refusable',
      );
      expect(await process.exitCode, -9);
      expect(
        records.where((r) => r.message.contains('process_kill_escalated')),
        isNotEmpty,
        reason:
            'escalating past a refused SIGTERM is degradation, and this '
            'project does not degrade silently',
      );
    });

    test('an app that exits on SIGTERM is never escalated', () async {
      final process = FakeProcess();
      // Deliberately enormous: if this test passes it is because the process
      // exited, not because a short bound expired.
      final device = MacOSDevice()..teardownBound = const Duration(seconds: 30);

      final records = await recording(
        () => device
            .stop(AppInstance(process: process))
            .timeout(const Duration(seconds: 5)),
      );

      expect(
        process.signals,
        [ProcessSignal.sigterm],
        reason: 'a process that stops when asked must not also be SIGKILLed',
      );
      expect(
        records.where((r) => r.message.contains('process_kill')),
        isEmpty,
        reason: 'an ordinary stop is not worth a warning',
      );
    });

    test(
      'a real process that traps SIGTERM is escalated and actually dies',
      () async {
        // The one place the escalation meets a real kernel rather than a fake,
        // which is what keeps FakeProcess honest if the platform ever stops
        // behaving this way.
        final real = await Process.start('/bin/sh', [
          '-c',
          'trap "" TERM; echo ready; while true; do sleep 0.05; done',
        ]);
        final ready = Completer<void>();
        real.stdout.listen((data) {
          if (String.fromCharCodes(data).contains('ready') &&
              !ready.isCompleted) {
            ready.complete();
          }
        });
        real.stderr.listen((_) {});
        await ready.future.timeout(const Duration(seconds: 10));
        addTearDown(() => real.kill(ProcessSignal.sigkill));

        final device = MacOSDevice()
          ..teardownBound = const Duration(milliseconds: 200);
        final sw = Stopwatch()..start();
        await device
            .stop(AppInstance(process: real))
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => fail(
                'stop() never returned against a real '
                'SIGTERM-trapping process',
              ),
            );
        sw.stop();

        expect(
          await real.exitCode,
          -9,
          reason:
              'SIGKILL is what this process can be killed by, and -9 is '
              'what dart:io reports for it',
        );
        expect(
          sw.elapsed,
          lessThan(const Duration(seconds: 3)),
          reason: 'the wait is bounded, not merely eventual',
        );
      },
    );

    test('a web module server that never finishes stopping does not hold the '
        'browser hostage', () async {
      final process = FakeProcess();
      final device = WebDevice()
        ..teardownBound = const Duration(milliseconds: 50)
        ..setModuleServer(_HangingModuleServer());

      final records = await recording(
        () => device
            .stop(AppInstance(process: process))
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => fail(
                'stop() never returned: a wedged module '
                'server still blocks the teardown',
              ),
            ),
      );

      expect(
        process.signals,
        contains(ProcessSignal.sigterm),
        reason:
            'the kill sits AFTER the module server in the chain, so an '
            'unbounded stop() there means the browser is never even asked '
            'to exit',
      );
      expect(
        records.where((r) => r.message.contains('teardown_step_timed_out')),
        isNotEmpty,
      );
    });
  });
}

/// A [WebModuleServer] whose `stop()` never completes.
///
/// Not a hypothetical: `stop()` awaits `dwds.stop()`, which reaches
/// `DebugService.close()` → `dds.shutdown()` and `DwdsVmClient.close()` →
/// `client.dispose()` — peer-dependent awaits in a third-party package this
/// repo does not control.
class _HangingModuleServer extends WebModuleServer {
  _HangingModuleServer()
    : super(
        webToolchain: WebToolchainPaths(
          ddcOutlineDill: '/nonexistent',
          librariesSpec: '/nonexistent',
          dartSdkJs: '/nonexistent',
          ddcModuleLoaderJs: '/nonexistent',
          stackTraceMapperJs: '/nonexistent',
          dartSdkRoot: '/nonexistent',
        ),
        buildOutputDir: '/nonexistent',
        entrypointFilename: 'main.dart',
        flutterBootstrapJsPath: '/nonexistent',
        dartExecutable: '/nonexistent',
        options: const WebServerOptions(crossOriginIsolation: false),
      );

  @override
  Future<void> stop() => Completer<void>().future;
}

/// A device whose only interesting property is what it demands of the host.
class _ToolsDevice extends Device {
  final List<HostTool> _tools;

  _ToolsDevice(this._tools);

  @override
  Future<List<HostTool>> requiredHostTools() async => _tools;

  @override
  String get name => 'Tools';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnimplementedError();

  @override
  Future<void> stop(AppInstance instance) => throw UnimplementedError();
}

class _MinimalDevice extends Device {
  @override
  String get name => 'Minimal';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnimplementedError();

  @override
  Future<void> stop(AppInstance instance) => throw UnimplementedError();
}
