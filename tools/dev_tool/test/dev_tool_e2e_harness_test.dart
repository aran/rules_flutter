/// What the e2e harness reports when a wait expires.
///
/// A bound that expires is the harness's *only* output in the case it exists
/// for — the dev tool alive and silent — so the text of that failure is the
/// whole product. A bare `Timed out after 60s waiting for a response to
/// app.stop (id 1)` says what did not happen and nothing about the run that
/// failed to make it happen.
///
/// Driven by a [FakeProcess] rather than a real dev tool: every case here has
/// to *reach* a timeout, and scripting a silent run is the only way to do that
/// in a second instead of a minute. That also makes this a plain unit test, so
/// `bazel test //...` covers it — the same reason `test_lifetime.dart`, the
/// harness's other helper, has a target of its own.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'e2e/dev_tool_e2e_harness.dart';
import 'fakes.dart';

/// One machine-protocol line, in the `[{…}]` envelope the dev tool writes.
String _envelope(Map<String, dynamic> message) => json.encode([message]);

/// Stand-in for a captured PNG. Only its identity matters: every screenshot
/// case here asks which endpoint the bytes came from.
const _nativePng = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x6e];
const _flutterPng = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x66];

/// An `app.progress` record, shaped as `SessionHost` emits it: the paired
/// `id` identifies the command and `message` carries its method.
Map<String, dynamic> _progress(String method, {required bool finished}) => {
  'event': 'app.progress',
  'params': {
    'appId': 'app-1',
    'id': 'cmd_0',
    'message': method,
    'finished': finished,
  },
};

void main() {
  // Every case waits one of these out, so it is as short as the work allows.
  // Nothing races it: each test first waits — through the harness's own public
  // waiters — for the traffic its assertion reads, so the bound is only ever
  // spent on the silence that follows.
  const bound = Duration(seconds: 1);

  late FakeProcess process;
  late DevToolProcess tool;

  setUp(() async {
    process = FakeProcess();
    tool = DevToolProcess(process);
    // The fake's output streams are broadcast, so anything emitted before the
    // harness subscribes would be dropped.
    await process.outputAttached;
  });

  tearDown(() async {
    // Ends the run before disposing. `dispose` asks for `app.stop` first and
    // then waits for an exit, which a fake driven by nothing will never
    // produce on its own.
    process.complete(0);
    await tool.dispose();
  });

  group('sendCommand, when the response never comes,', () {
    test('reports that nothing at all came back', () async {
      final pending = tool.sendCommand(1, 'app.stop', timeout: bound);

      await expectLater(
        pending,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(
                'Timed out after 1s waiting for a response to app.stop (id 1)',
              ),
              contains(
                'Nothing at all arrived on the protocol stream after the '
                'request was sent.',
              ),
            ),
          ),
        ),
      );
      expect(
        process.stdinBuffer.toString(),
        contains('"method":"app.stop"'),
        reason: 'the command must actually have been written',
      );
    });

    test('names a command that started and never finished, and quotes what '
        'the tool was printing', () async {
      final pending = tool.sendCommand(
        2,
        'app.hotReload',
        params: {'appId': 'app-1'},
        timeout: bound,
      );

      process.emitStdout(
        _envelope(_progress('app.hotReload', finished: false)),
      );
      process.emitStdout(
        _envelope({
          'event': 'app.log',
          'params': {'appId': 'app-1', 'log': 'tick'},
        }),
      );
      process.emitStderr('frontend server: compiling lib/main.dart\n');

      await tool.waitForEvent('app.log');
      await tool.waitForStderr('frontend server');

      await expectLater(
        pending,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('a response to app.hotReload (id 2)'),
              contains('Saw 2 message(s) since the request was sent'),
              contains('1 app.progress[app.hotReload] started'),
              contains('1 app.log'),
              // The command was received and never returned; saying it finished
              // would point the reader at the wrong half of the pipeline.
              isNot(contains('app.progress[app.hotReload] finished')),
              contains('stderr (last 1 of 1)'),
              contains('frontend server: compiling lib/main.dart'),
            ),
          ),
        ),
      );
    });

    test(
      'distinguishes a handler that returned from one still running',
      () async {
        final pending = tool.sendCommand(
          3,
          'app.restart',
          params: {'appId': 'app-1'},
          timeout: bound,
        );

        process.emitStdout(
          _envelope(_progress('app.restart', finished: false)),
        );
        process.emitStdout(_envelope(_progress('app.restart', finished: true)));
        // A response — to somebody else's command, which is why this wait is
        // still going. Id 999000 is dispose's own `daemon.shutdown`.
        process.emitStdout(
          _envelope({
            'id': 999000,
            'result': {'message': 'shutdown'},
          }),
        );

        await tool.waitForEventWhere(
          'app.progress',
          test: (params) => params['finished'] == true,
          what: 'the finished half of the progress pair',
        );

        await expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('a response to app.restart (id 3)'),
                contains('1 app.progress[app.restart] started'),
                contains('1 app.progress[app.restart] finished'),
                contains('1 response to id 999000'),
              ),
            ),
          ),
        );
      },
    );
  });

  test(
    'a wait that expires quotes the stdout the protocol could not parse',
    () async {
      process.emitStdout(
        "Can't load Kernel binary: Invalid kernel binary format",
      );
      process.emitStdout(
        _envelope({'event': 'daemon.connected', 'params': {}}),
      );

      // Same stream, so the unparseable line above is already recorded once this
      // returns.
      await tool.waitForEvent('daemon.connected');

      await expectLater(
        tool.waitForEvent('app.started', timeout: bound),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Timed out after 1s waiting for the app.started event'),
              contains('Saw 1 event(s): daemon.connected'),
              contains('stdout (non-protocol) (last 1 of 1)'),
              contains("Can't load Kernel binary"),
            ),
          ),
        ),
      );
    },
  );

  group('the HTTP control channel,', () {
    late HttpServer server;

    setUp(() async {
      // The IPv4 loopback, addressed by literal rather than by name: this
      // fixture is one server, and a `localhost` URL would let the client pick
      // a family and reach whatever else holds that port number on the other.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      process.emitStderr(
        '${json.encode({
          'message': 'http_control_channel',
          'uri': 'http://127.0.0.1:${server.port}',
          'token': 'fixture-token',
        })}\n',
      );
      await tool.waitForHttpControl();
    });

    tearDown(() async {
      // `force: true` because most cases here hold a request open on purpose,
      // and a graceful close waits for exactly those. A teardown that can hang
      // hangs the whole suite — `test_lifetime.dart` measures that teardowns
      // are awaited without any bound — so the socket is severed outright.
      await server.close(force: true);
    });

    group('when a request never completes,', () {
      test('names the handler that took the command and never returned', () async {
        // Accepted and held: the header is what the dev tool writes when its
        // handler returns, so a request that never sees one is a command that
        // was delivered and is still inside the tool.
        server.listen((request) {});

        final pending = tool.httpCommand(
          'app.getText',
          {'appId': 'app-1'},
          timeout: bound,
        );

        process.emitStdout(
          _envelope({
            'event': 'app.log',
            'params': {'appId': 'app-1', 'log': 'tick'},
          }),
        );
        process.emitStdout(
          _envelope(_progress('app.hotReload', finished: false)),
        );
        process.emitStderr('frontend server: compiling lib/main.dart\n');
        await tool.waitForEvent('app.progress');
        await tool.waitForStderr('frontend server');

        await expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains(
                  'Timed out after 1s waiting for the app.getText '
                  'command over the HTTP control channel',
                ),
                contains(
                  'no response header arrived within the 1s it was given',
                ),
                // The observation is that the header did not arrive inside the
                // bound. Concluding the handler "never returned" from that
                // would read a working endpoint as a wedged one.
                isNot(contains('never returned.')),
                // The command surface is serialized through a one-slot pool, so
                // a reload that started and never finished is the answer to why
                // this one is still waiting.
                contains('Saw 2 message(s) since the request was sent'),
                contains('1 app.progress[app.hotReload] started'),
                contains('frontend server: compiling lib/main.dart'),
              ),
            ),
          ),
        );
      });

      test(
        'a sub-second bound is reported whole, not truncated to zero',
        () async {
          // `inSeconds` truncates, so a request given a fraction of a polling
          // deadline would report "Timed out after 0s" — indistinguishable from
          // one given no time at all, and read as a handler that never answers.
          server.listen((request) {});

          await expectLater(
            tool.httpCommand('app.getText', {
              'appId': 'app-1',
            }, timeout: const Duration(milliseconds: 200)),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('Timed out after 200ms'),
                  contains('within the 200ms it was given'),
                  isNot(contains('after 0s')),
                ),
              ),
            ),
          );
        },
      );

      test(
        'names the status that did arrive when the body never ends',
        () async {
          server.listen((request) async {
            request.response.bufferOutput = false;
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"result":');
            await request.response.flush();
          });

          await expectLater(
            tool.httpCommand('app.getText', {'appId': 'app-1'}, timeout: bound),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('waiting for the app.getText command'),
                  contains('response header arrived (status 200)'),
                  contains('the body never ended'),
                ),
              ),
            ),
          );
        },
      );

      test('a connection that is refused says so, and quotes the run', () async {
        // Nothing is listening on that port from here on, so the request stops
        // before it is ever sent.
        await server.close(force: true);
        process.emitStderr('dev tool: the session is still up\n');
        await tool.waitForStderr('the session is still up');

        await expectLater(
          tool.httpCommand('app.getText', {'appId': 'app-1'}, timeout: bound),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains(
                  'The HTTP control channel request for the app.getText '
                  'command did not complete',
                ),
                contains('never established a connection'),
                contains('dev tool: the session is still up'),
              ),
            ),
          ),
        );
      });

      test('the on-screen poll reports the endpoint, not the clock', () async {
        // The endpoint answers immediately and says what is wrong, so every
        // attempt fails fast and the poll runs its bound out. What it reports
        // must be that answer: bounding each attempt by what is left of the
        // deadline would give the final attempt roughly none, so it would
        // expire in its connect phase and become the "last error" — burying the
        // diagnosis this helper exists to surface.
        server.listen((request) async {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.headers.contentType = ContentType.json;
          request.response.add(
            utf8.encode(
              json.encode({
                'error':
                    "pid 4242 owns 1 window(s), and ScreenCaptureKit's "
                    'on-screen set — the only windows it can capture — contains '
                    'none of them: "Flutter App" 800x632 at (585,926).',
              }),
            ),
          );
          await request.response.close();
        });

        await expectLater(
          tool.nativeScreenshotWhenOnScreen('app-1', timeout: bound),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('never presented an on-screen window within 1s'),
                contains('owns 1 window(s)'),
                isNot(contains('never established a connection')),
              ),
            ),
          ),
        );
      });

      test('the on-screen poll keeps the diagnosis a later attempt could not '
          'reach', () async {
        // The case above answers every attempt instantly, which is the one
        // shape that cannot tell a *sufficient* budget from *any* budget: an
        // answer that costs no time fits in whatever is left. A real endpoint
        // costs time, so a later attempt can be handed a slice of the deadline
        // shorter than one answer takes and expire in transport. Recording that
        // as "the last error" would overwrite the diagnosis with a sentence
        // saying the handler never returned, reporting a working endpoint as
        // one that hangs.
        //
        // Counted rather than timed: the first request answers and every one
        // after it is held open forever, so the ordering holds under any load
        // instead of depending on a margin the next reader cannot see.
        var answered = 0;
        server.listen((request) async {
          if (answered++ > 0) return;
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.headers.contentType = ContentType.json;
          request.response.add(
            utf8.encode(
              json.encode({
                'error':
                    "pid 4242 owns 1 window(s), and ScreenCaptureKit's "
                    'on-screen set — the only windows it can capture — contains '
                    'none of them: "Flutter App" 800x632 at (585,926).',
              }),
            ),
          );
          await request.response.close();
        });

        await expectLater(
          tool.nativeScreenshotWhenOnScreen('app-1', timeout: bound),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('never presented an on-screen window within 1s'),
                contains('owns 1 window(s)'),
              ),
            ),
          ),
        );
      });

      test(
        'the on-screen poll gives up even when a single capture hangs',
        () async {
          // A deadline checked only between attempts would let one request that
          // never answers outlive the bound it is polling under.
          //
          // Nothing here ever answers, so "no attempt reached an answer" is the
          // whole truth and must be what gets reported. This is the world the
          // case above must not swallow: preferring an endpoint answer over a
          // transport failure would hide a genuinely wedged handler if it were
          // done unconditionally.
          server.listen((request) {});

          await expectLater(
            tool.nativeScreenshotWhenOnScreen('app-1', timeout: bound),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('never presented an on-screen window within 1s'),
                  contains('No attempt ever reached an answer'),
                ),
              ),
            ),
          );
        },
      );
    });

    group('httpScreenshot', () {
      /// Paths the fixture was asked for, in order.
      late List<String> asked;

      void serve(int flutterStatus, Object flutterBody) {
        asked = [];
        server.listen((request) async {
          asked.add(request.uri.path);
          final isFlutter = request.uri.path.endsWith('/screenshot/flutter');
          request.response.statusCode = isFlutter
              ? flutterStatus
              : HttpStatus.ok;
          if (isFlutter) {
            request.response.headers.contentType =
                flutterStatus == HttpStatus.ok
                ? ContentType('image', 'png')
                : ContentType.json;
            request.response.add(
              flutterBody is String
                  ? utf8.encode(flutterBody)
                  : (flutterBody as List<int>),
            );
          } else {
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(_nativePng);
          }
          await request.response.close();
        });
      }

      test('takes the engine capture when the endpoint serves one', () async {
        serve(HttpStatus.ok, _flutterPng);

        expect(await tool.httpScreenshot('app-1'), _flutterPng);
        expect(asked, ['/sessions/app-1/screenshot/flutter']);
      });

      test('routes to the native endpoint on the 501 that names it', () async {
        serve(
          HttpStatus.notImplemented,
          json.encode({
            'error':
                '_flutter.screenshot cannot capture on iPhone 16 ... Use '
                'GET /sessions/app-1/screenshot/native, which captures the '
                'same app through the platform.',
          }),
        );

        expect(await tool.httpScreenshot('app-1'), _nativePng);
        expect(asked, [
          '/sessions/app-1/screenshot/flutter',
          '/sessions/app-1/screenshot/native',
        ]);
      });

      test(
        'lets any other failure through instead of capturing something else',
        () async {
          // A 500 is the endpoint failing, not refusing. Retrying it against the
          // other endpoint would discard this error and hand back a native
          // capture, so a device that should serve `_flutter.screenshot` and
          // stopped would never be noticed.
          serve(
            HttpStatus.internalServerError,
            json.encode({'error': 'Could not capture image screenshot'}),
          );

          await expectLater(
            tool.httpScreenshot('app-1'),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('(500)'),
                  contains('Could not capture image screenshot'),
                ),
              ),
            ),
          );
          expect(asked, [
            '/sessions/app-1/screenshot/flutter',
          ], reason: 'the native endpoint must not have been asked');
        },
      );
    });
  });

  /// The gate that decides whether the `Android e2e` group runs.
  ///
  /// Every case drives a stub `adb` rather than the host's, because the whole
  /// question is what the gate does when `adb` misbehaves — and a host with a
  /// working SDK and a plugged-in phone can only ever demonstrate the one
  /// branch that was never in doubt.
  ///
  /// The environment is injected too. `Platform.environment` cannot be mutated
  /// in-process, so reading it directly would let whatever `$ANDROID_SERIAL`
  /// the developer has exported decide these verdicts.
  group('AndroidDeviceProbe', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('adb_probe_');
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    /// An executable standing in for `adb`, printing [stdout] on stdout and
    /// [stderr] on stderr and exiting [exitCode].
    String stubAdb({
      String stdout = '',
      String stderr = '',
      int exitCode = 0,
    }) {
      final path = p.join(dir.path, 'adb');
      File(path).writeAsStringSync(
        '#!/bin/sh\n'
        "cat <<'STDOUT_EOF'\n$stdout\nSTDOUT_EOF\n"
        "cat >&2 <<'STDERR_EOF'\n$stderr\nSTDERR_EOF\n"
        'exit $exitCode\n',
      );
      Process.runSync('chmod', ['+x', path]);
      return path;
    }

    AndroidDeviceProbe detect(
      String adb, {
      Map<String, String> env = const {},
    }) => AndroidDeviceProbe.detect(environment: env, adbPath: adb);

    test('an authorized device is the one the run uses', () {
      final probe = detect(
        stubAdb(stdout: 'List of devices attached\nemulator-5554\tdevice\n'),
      );
      expect(probe, isA<AndroidDeviceFound>());
      expect((probe as AndroidDeviceFound).serial, 'emulator-5554');
      expect(probe.skipReason, isNull);
    });

    // The one legitimate skip: adb worked, and there is nothing plugged in.
    test('an empty bench skips, and the reason says the list was empty', () {
      final probe = detect(stubAdb(stdout: 'List of devices attached\n'));
      expect(probe, isA<NoAndroidDevice>());
      expect(probe.skipReason, contains('no Android device attached'));
    });

    // Each of the next four cases has to be told apart from the empty bench
    // above: answering the same `null` skips the whole Android group and
    // reports the run green.
    test('an adb that cannot be run fails, naming the path that was tried', () {
      final missing = p.join(dir.path, 'not-adb');
      final probe = detect(missing);
      expect(probe, isA<AndroidProbeFailed>());
      expect((probe as AndroidProbeFailed).reason, contains(missing));
      expect(
        probe.skipReason,
        isNull,
        reason:
            'a broken detector must not present itself as an empty '
            'bench — the group has to run so the failure is reported',
      );
    });

    test('an adb that exits non-zero fails, carrying what it said', () {
      final probe = detect(
        stubAdb(
          stderr: 'cannot connect to daemon',
          exitCode: 1,
        ),
      );
      expect(probe, isA<AndroidProbeFailed>());
      expect(
        (probe as AndroidProbeFailed).reason,
        allOf(contains('exited 1'), contains('cannot connect to daemon')),
      );
      expect(probe.skipReason, isNull);
    });

    test(
      'a device present but unauthorized fails, naming it and its state',
      () {
        final probe = detect(
          stubAdb(
            stdout: 'List of devices attached\n58051JEBF01271\tunauthorized\n',
          ),
        );
        expect(probe, isA<AndroidProbeFailed>());
        expect(
          (probe as AndroidProbeFailed).reason,
          allOf(contains('58051JEBF01271'), contains('unauthorized')),
        );
        expect(probe.skipReason, isNull);
      },
    );

    // adb reports states that contain spaces. Reading only the first word
    // would quote this one as `no`, which reads like a state of its own.
    test('a multi-word state is reported whole', () {
      final probe = detect(
        stubAdb(
          stdout:
              'List of devices attached\n'
              '1234\tno permissions (missing udev rules?)\n',
        ),
      );
      expect(
        (probe as AndroidProbeFailed).reason,
        contains('no permissions (missing udev rules?)'),
      );
    });

    test(
      'an unusable device beside a usable one still yields the usable one',
      () {
        final probe = detect(
          stubAdb(
            stdout:
                'List of devices attached\n'
                '58051JEBF01271\tunauthorized\n'
                'emulator-5554\tdevice\n',
          ),
        );
        expect((probe as AndroidDeviceFound).serial, 'emulator-5554');
      },
    );

    // adb interleaves this ahead of its own header. Parsing from the second
    // line would read `* daemon started successfully` as a device named `*`
    // in state `daemon`, and a bench with nothing on it would report one.
    test('daemon chatter ahead of the header is not read as a device', () {
      final probe = detect(
        stubAdb(
          stdout:
              '* daemon not running; starting now at tcp:5037\n'
              '* daemon started successfully\n'
              'List of devices attached\n',
        ),
      );
      expect(probe, isA<NoAndroidDevice>());
    });

    test('output with no header at all fails rather than reading as empty', () {
      final probe = detect(stubAdb(stdout: 'adb: usage: unknown command'));
      expect(probe, isA<AndroidProbeFailed>());
      expect(
        (probe as AndroidProbeFailed).reason,
        contains('List of devices attached'),
      );
    });

    group(r'when $ANDROID_SERIAL names a device,', () {
      const env = {'ANDROID_SERIAL': 'emulator-5554'};

      test('it is used even though another is listed first', () {
        final probe = detect(
          stubAdb(
            stdout:
                'List of devices attached\n'
                '58051JEBF01271\tdevice\n'
                'emulator-5554\tdevice\n',
          ),
          env: env,
        );
        expect((probe as AndroidDeviceFound).serial, 'emulator-5554');
      });

      // Naming a device is an instruction. Running a different one, or
      // quietly skipping, both ignore it.
      test('its absence fails and lists what was attached instead', () {
        final probe = detect(
          stubAdb(stdout: 'List of devices attached\n58051JEBF01271\tdevice\n'),
          env: env,
        );
        expect(probe, isA<AndroidProbeFailed>());
        expect(
          (probe as AndroidProbeFailed).reason,
          allOf(contains('emulator-5554'), contains('58051JEBF01271')),
        );
        expect(probe.skipReason, isNull);
      });

      test('its being listed unusable fails, naming the state', () {
        final probe = detect(
          stubAdb(stdout: 'List of devices attached\nemulator-5554\toffline\n'),
          env: env,
        );
        expect((probe as AndroidProbeFailed).reason, contains('offline'));
      });
    });
  });
}

/// A second *process* that takes the same lock, in the two modes the cases
/// above need: `hold` takes it and sits on it until killed, `try` reports
/// whether it could take it at all.
///
/// Written out at run time rather than shipped as a `srcs` file so it stays
/// beside the test that explains it; it imports nothing but `dart:io`, so the
