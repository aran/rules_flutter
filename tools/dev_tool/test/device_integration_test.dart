import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/chrome_profile.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/web_options.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('WebDevice server cleanup (H9)', () {
    /// A directory with the one file the static server needs, cleaned up with
    /// the test.
    Future<Directory> appDir() async {
      final tmpDir = await Directory.systemTemp.createTemp('web_test_');
      addTearDown(() => tmpDir.delete(recursive: true));
      await File('${tmpDir.path}/index.html').writeAsString('<html></html>');
      return tmpDir;
    }

    test(
      'launch serves the app, drives its page, and stop cleans up',
      () async {
        // Chrome itself is faked, but the launch still resolves the real binary
        // first — an explicit skip rather than a swallowed StateError, which
        // would pass without running any of the assertions.
        if (findChrome() == null) {
          markTestSkipped('Chrome is not installed on this host');
          return;
        }

        // A fake browser debugging endpoint: the browser-level socket reports
        // the tab the fake Chrome was launched on, and a page's own socket is
        // where the console forwarder attaches. A fixed well-known port such
        // as 9222 is a landmine here — a real developer Chrome with debugging
        // enabled commonly sits on it.
        final cdp = await FakeBrowserCdp.start();
        addTearDown(cdp.close);
        final profileRoot = await Directory.systemTemp.createTemp(
          'web_profiles_',
        );
        addTearDown(() => profileRoot.delete(recursive: true));
        List<String>? chromeArgs;
        final enableReceived = Completer<String>();
        cdp.onPageConnection = (socket) => socket.listen((data) {
          if (!enableReceived.isCompleted) {
            enableReceived.complete(data as String);
          }
        });

        final fakeChrome = FakeProcess();
        final device =
            WebDevice(
                startProcess: (exe, args) async {
                  chromeArgs = args;
                  return fakeChrome;
                },
                profiles: ChromeProfiles(parent: profileRoot),
              )
              ..webOptions = const WebOptions(
                server: WebServerOptions(crossOriginIsolation: false),
                browser: BrowserLaunchOptions(),
                enableExpressionEvaluation: false,
              );

        final tmpDir = await appDir();
        final launch = device.launch(tmpDir.path);
        // The launch waits for the debugging port, so the fake has to announce
        // one the way Chrome does — the fake endpoint's real port, never a
        // constant.
        await fakeChrome.outputAttached;
        // The tab the browser was told to open, which it shows once it has
        // navigated there.
        cdp.target('tab', type: 'page', url: chromeArgs!.last);
        fakeChrome.emitStderr(cdp.announcement);

        final instance = await launch;
        expect(instance.server, isNotNull);
        expect(instance.server!.port, greaterThan(0));
        expect(device.cdpPort, cdp.port);
        expect(device.appUrl, 'http://localhost:${instance.server!.port}');

        // The console forwarder attached to the app's page and switched its
        // notifications on — the observable half of "the right tab is driven".
        final firstMessage =
            json.decode(await enableReceived.future) as Map<String, dynamic>;
        expect(firstMessage['method'], 'Runtime.enable');

        final profileDir = Directory(
          chromeArgs!
              .firstWhere((a) => a.startsWith('--user-data-dir='))
              .substring('--user-data-dir='.length),
        );
        expect(await profileDir.exists(), isTrue);

        await device.stop(instance);
        expect(
          await profileDir.exists(),
          isFalse,
          reason:
              'stop must not leave the Chrome profile behind — a stale '
              'one belongs to a browser a --user-data-dir scan can still '
              'find',
        );
      },
    );

    test('launch starts the browser it was given, which no Chrome found on '
        'the host stands in for', () async {
      final cdp = await FakeBrowserCdp.start();
      addTearDown(cdp.close);
      cdp.onPageConnection = (socket) => socket.listen((_) {});
      final profileRoot = await Directory.systemTemp.createTemp(
        'web_profiles_',
      );
      addTearDown(() => profileRoot.delete(recursive: true));
      final fakeChrome = FakeProcess();
      late String started;
      late List<String> chromeArgs;
      final device =
          WebDevice(
              chromePath: '/pinned/chrome-headless-shell',
              startProcess: (exe, args) async {
                started = exe;
                chromeArgs = args;
                return fakeChrome;
              },
              profiles: ChromeProfiles(parent: profileRoot),
            )
            ..webOptions = const WebOptions(
              server: WebServerOptions(crossOriginIsolation: false),
              browser: BrowserLaunchOptions(),
              enableExpressionEvaluation: false,
            );

      final launch = device.launch((await appDir()).path);
      await fakeChrome.outputAttached;
      cdp.target('tab', type: 'page', url: chromeArgs.last);
      fakeChrome.emitStderr(cdp.announcement);
      final instance = await launch;

      expect(started, '/pinned/chrome-headless-shell');
      await device.stop(instance);
    });

    test('stop still ends the browser and clears its profile when a step '
        'before it throws', () async {
      if (findChrome() == null) {
        markTestSkipped('Chrome is not installed on this host');
        return;
      }
      final cdp = await FakeBrowserCdp.start();
      addTearDown(cdp.close);
      final profileRoot = await Directory.systemTemp.createTemp(
        'web_profiles_',
      );
      addTearDown(() => profileRoot.delete(recursive: true));
      final fakeChrome = FakeProcess();
      late List<String> chromeArgs;
      final device =
          WebDevice(
              startProcess: (exe, args) async {
                chromeArgs = args;
                return fakeChrome;
              },
              profiles: ChromeProfiles(parent: profileRoot),
            )
            ..webOptions = const WebOptions(
              server: WebServerOptions(crossOriginIsolation: false),
              browser: BrowserLaunchOptions(),
              enableExpressionEvaluation: false,
            );
      final tmpDir = await appDir();
      final launch = device.launch(tmpDir.path);
      await fakeChrome.outputAttached;
      cdp.target('tab', type: 'page', url: chromeArgs.last);
      fakeChrome.emitStderr(cdp.announcement);
      final instance = await launch;
      addTearDown(() => instance.server!.close(force: true));
      final profileDir = Directory(
        chromeArgs
            .firstWhere((a) => a.startsWith('--user-data-dir='))
            .substring('--user-data-dir='.length),
      );

      // The browser and its profile are what outlive the process if a stop
      // that fails along the way skips them.
      await expectLater(
        device.stop(
          AppInstance(
            process: instance.process,
            server: _ThrowingServer(),
            logs: instance.logs,
          ),
        ),
        throwsStateError,
      );

      expect(fakeChrome.killed, isTrue);
      expect(await profileDir.exists(), isFalse);
    });

    test(
      'stop lets go of the browser\'s output pipes, even when a helper of '
      'the browser still holds the other end',
      () async {
        if (findChrome() == null) {
          markTestSkipped('Chrome is not installed on this host');
          return;
        }
        final cdp = await FakeBrowserCdp.start();
        addTearDown(cdp.close);
        cdp.onPageConnection = (socket) => socket.listen((_) {});
        final profileRoot = await Directory.systemTemp.createTemp(
          'web_profiles_',
        );
        addTearDown(() => profileRoot.delete(recursive: true));
        List<String>? chromeArgs;
        final fakeChrome = FakeProcess();
        final device =
            WebDevice(
                startProcess: (exe, args) async {
                  chromeArgs = args;
                  return fakeChrome;
                },
                profiles: ChromeProfiles(parent: profileRoot),
              )
              ..webOptions = const WebOptions(
                server: WebServerOptions(crossOriginIsolation: false),
                browser: BrowserLaunchOptions(),
                enableExpressionEvaluation: false,
              );

        final launch = device.launch((await appDir()).path);
        await fakeChrome.outputAttached;
        cdp.target('tab', type: 'page', url: chromeArgs!.last);
        fakeChrome.emitStderr(cdp.announcement);
        final instance = await launch;
        expect(
          fakeChrome.stderrHasListener,
          isTrue,
          reason: 'the browser\'s output is drained while it runs',
        );

        await device.stop(instance);

        // A Chrome helper that outlives its parent keeps the write end of
        // these pipes open, so the streams never reach end-of-file, and a Dart
        // VM with a live pipe subscription does not exit: the tool answered
        // `daemon.shutdown` and then sat there. Whether anything is still
        // reading is the part this process controls.
        expect(
          fakeChrome.stdoutHasListener || fakeChrome.stderrHasListener,
          isFalse,
          reason:
              'stop left a reader on the browser\'s stdout/stderr; a process '
              'that still holds those pipes keeps the tool from exiting',
        );
      },
    );

    test(
      'a browser that exits without announcing a debug port fails the launch',
      () async {
        if (findChrome() == null) {
          markTestSkipped('Chrome is not installed on this host');
          return;
        }
        final profileRoot = await Directory.systemTemp.createTemp(
          'web_profiles_',
        );
        addTearDown(() => profileRoot.delete(recursive: true));
        final fakeChrome = FakeProcess();
        final device =
            WebDevice(
                startProcess: (exe, args) async => fakeChrome,
                profiles: ChromeProfiles(parent: profileRoot),
              )
              ..webOptions = const WebOptions(
                server: WebServerOptions(crossOriginIsolation: false),
                browser: BrowserLaunchOptions(),
                enableExpressionEvaluation: false,
              );

        final tmpDir = await appDir();
        final launch = device.launch(tmpDir.path);
        await fakeChrome.outputAttached;
        // Chrome dies having said nothing. Silently accepting a null port
        // leaves the run with no screenshots, no page reload and no console,
        // and says nothing about any of it.
        fakeChrome.complete(1);

        await expectLater(
          launch,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('exited'), contains('debugging port')),
            ),
          ),
        );
      },
    );
  });

  group('AndroidDevice port forwarding (M8)', () {
    test('forwards port after discovering VM service URI', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        startForceStopProcess: exitsAtOnce,
        aapt2Path: 'aapt2',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          // adb forward returns the host port.
          if ((args as List).contains('forward')) {
            return ProcessResult(0, 0, '54321', '');
          }
          // The announcing pid is the app's own.
          if (args.contains('pidof')) return ProcessResult(0, 0, '1234\n', '');
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLogcat;
        },
      );

      // Wait for the launch to actually attach its reader to logcat before
      // announcing. A fixed delay races the install/start steps that run
      // first, and a line emitted before anyone is listening is dropped —
      // which times this test out rather than failing it on an assertion.
      unawaited(
        fakeLogcat.outputAttached.then((_) {
          // A real `adb logcat -v time` record: timestamp, level/tag, padded
          // pid. Anything else is dropped by [parseLogcatLine], and a dropped
          // line hangs this test rather than failing it.
          fakeLogcat.emitStdout(
            '01-01 00:00:00.000 I/flutter ( 1234): '
            'The Dart VM service is listening on http://127.0.0.1:12345/abc=/',
          );
        }),
      );

      final instance = await device.launch('/path/to/app.apk');
      expect(instance.vmServiceUri, isNotNull);
      // Should be the forwarded port, not the device port.
      expect(instance.vmServiceUri!.port, 54321);
      expect(instance.vmServiceUri!.host, '127.0.0.1');

      // Verify adb forward was called.
      final forwardCall = calls
          .where((c) => c.$1 == 'adb' && c.$2.contains('forward'))
          .toList();
      expect(forwardCall, isNotEmpty);
    });
  });

  group('IOSSimulatorDevice.stop awaits process exit', () {
    test('stop awaits process exitCode', () async {
      // Use a process where kill() doesn't auto-complete exitCode,
      // so we can verify that stop() truly awaits the exitCode future.
      final exitCompleter = Completer<int>();
      var killCalled = false;
      final fakeLog = _DelayedExitProcess(
        exitCodeFuture: exitCompleter.future,
        onKill: () => killCalled = true,
      );

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => fakeLog,
      );

      var stopCompleted = false;
      final stopFuture = device.stop(AppInstance(process: fakeLog)).then((_) {
        stopCompleted = true;
      });

      // Give stop() time to call kill and start awaiting exitCode.
      await Future.delayed(Duration(milliseconds: 20));
      expect(killCalled, isTrue);
      expect(
        stopCompleted,
        isFalse,
        reason: 'stop should still be awaiting exitCode',
      );

      // Now complete the process exit.
      exitCompleter.complete(0);
      await stopFuture;
      expect(stopCompleted, isTrue);
    });
  });
}

/// A fake process where kill() does NOT auto-complete exitCode.
class _DelayedExitProcess implements Process {
  final Future<int> exitCodeFuture;
  final void Function() onKill;

  _DelayedExitProcess({required this.exitCodeFuture, required this.onKill});

  @override
  Future<int> get exitCode => exitCodeFuture;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => _NullSink();

  @override
  int get pid => 99999;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    onKill();
    return true;
  }
}

class _NullSink implements IOSink {
  @override
  Encoding encoding = utf8;
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream<List<int>> stream) async {}
  @override
  Future close() async {}
  @override
  Future get done => Future.value();
  @override
  Future flush() => Future.value();
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}

/// A server whose `close` fails, standing for any step of a stop that throws.
class _ThrowingServer implements HttpServer {
  @override
  Future<HttpServer> close({bool force = false}) =>
      throw StateError('the server would not close');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
