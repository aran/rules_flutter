@Tags(['e2e'])
/// End-to-end screenshot tests for `e2e/plugin_example`.
///
/// Validates that the demonstrator app launches and renders a non-blank
/// frame across every platform `rules_flutter` supports. The screenshot is
/// the dispositive end-to-end gate: if plugin auto-wiring is broken,
/// `MissingPluginException` blanks the screen; if Native Assets are
/// broken, the app crashes before drawing anything — both fail the
/// non-blank check.
///
/// macOS / iOS-Simulator / Android subtests share the same dev_tool
/// screenshot pipeline (`Device.screenshot` → HTTP control channel →
/// captured PNG). Each runs `:plugin_app` on a different platform; the
/// non-blank PNG is dispositive evidence that the build pipeline
/// produced a working app for that platform.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// PNG signature: 89 50 4E 47 0D 0A 1A 0A.
const _pngHeader = <int>[0x89, 0x50, 0x4E, 0x47];

/// Common screenshot assertion: launch [target] on [device], wait one
/// frame, capture via the HTTP control channel, and assert the PNG is
/// well-formed and non-blank. Keeping this in a helper means the
/// per-platform subtests differ only in `device`/`target`/skip
/// predicate. Each platform points the dev_tool at its launchable
/// bundle target (`:plugin_macos`, `:plugin_ios`, `:plugin_android`),
/// not the underlying `:plugin_app` flutter_application — the dev_tool
/// resolves the first build output and expects a runnable artifact.
Future<void> _runScreenshotTest({
  required String workspace,
  required String target,
  required String device,
  required String outputBasename,
}) async {
  final dt = await startDevTool(
    workspace: workspace,
    target: target,
    device: device,
  );

  await dt.waitForEvent('app.started');
  final http = await dt.waitForHttpControl();
  expect(http, isNotNull);

  // Wait for first frame.
  await Future<void>.delayed(const Duration(seconds: 3));

  final outputPath = '${Directory.systemTemp.path}/$outputBasename.png';
  await dt.httpScreenshotToFile(dt.appId!, outputPath);

  final file = File(outputPath);
  expect(
    file.existsSync(),
    isTrue,
    reason: 'screenshot file should exist at $outputPath',
  );

  final bytes = file.readAsBytesSync();
  expect(
    bytes.sublist(0, 4),
    _pngHeader,
    reason: 'screenshot is not a valid PNG',
  );
  // Read the pixels, not the byte count: a size threshold passes a fully
  // transparent 1080x2400 emulator capture, which is over 10 KB.
  expectRendered(bytes, what: '$outputBasename ($target on $device)');

  file.deleteSync();
  await dt.sendCommand(1, 'daemon.shutdown');
}

void main() {
  // -- macOS ------------------------------------------------------------
  //
  // Validates Track A's Native Assets pipeline end-to-end: modern
  // path_provider_foundation 2.6.0+ FFI through objective_c.dylib has
  // to actually resolve at runtime for the screen to render.
  group(
    'macOS e2e',
    () {
      test('plugin_macos renders non-blank frame', () async {
        final ws = await editableWorkspace('plugin_example');
        await _runScreenshotTest(
          workspace: ws.root,
          target: ':plugin_macos',
          device: 'macos',
          outputBasename: 'plugin_macos_e2e',
        );
      });

      test(
        'Dart plugin registration survives hot restart',
        () async {
          final ws = await editableWorkspace('plugin_example');
          // The Dart plugin registrant is invoked by the engine's pre-main hook
          // on every root-isolate launch, including the restarted (dev-tool-
          // compiled) dill. A build-generated wrapper main cannot do that — the
          // restart dill lacks it, platform-interface statics reset on restart,
          // and path_provider (et al.) break. The keyed Text renders
          // getApplicationDocumentsDirectory(): a real absolute path means the
          // Dart registration worked.
          final dt = await startDevTool(
            workspace: ws.root,
            target: ':plugin_macos',
            device: 'macos',
          );
          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          final appId = dt.appId!;

          Future<String> documentsPath(String tag) async {
            Map<String, dynamic> resp = const {};
            for (var i = 0; i < 30; i++) {
              resp = await dt.httpCommand('app.getText', {
                'appId': appId,
                'key': 'e2e_documents_path',
              });
              // Retry both extension availability and the async
              // FutureBuilder resolving the plugin results.
              final text = resp['result']?['text'] as String? ?? '';
              if (resp['error'] == null && text.startsWith('/')) return text;
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
            fail(
              'documentsPath never resolved $tag: '
              'error=${resp['error']} text=${resp['result']?['text']}',
            );
          }

          final before = await documentsPath('at launch');
          expect(
            before,
            startsWith('/'),
            reason: 'path_provider must resolve at launch',
          );

          final restart = await dt.sendCommand(
            9,
            'app.restart',
            params: {
              'appId': appId,
            },
          );
          expect(
            restart['error'],
            isNull,
            reason: 'app.restart: ${restart['error']}',
          );

          final after = await documentsPath('after restart');
          expect(
            after,
            before,
            reason:
                'path_provider must still resolve after hot restart '
                '(Dart registrant must re-run)',
          );
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );

      // The dev tool must keep forwarding the app's stdout/stderr after it
      // matches the VM-service announcement; cancelling those subscriptions
      // there drops every line the app prints afterwards. `lib/main.dart`
      // emits `plugin_example_results …` via debugPrint from a FutureBuilder
      // — i.e. well after `app.started` — which is squarely inside that
      // window. `test/verify_macos_app_test.dart` already proves
      // the app emits the line when launched directly, so a failure here
      // isolates to the dev tool's forwarding rather than the app.
      test(
        'app output reaches the client after launch',
        () async {
          final ws = await editableWorkspace('plugin_example');
          // Launched through the Bazel-built binary rather than `dart run`,
          // because this test asserts stdout carries nothing but protocol
          // envelopes. `dart run` prepends its own SDK chatter ("Running build
          // hooks...") to stdout before `main()` is ever reached, which would
          // fail the assertion for a reason that has nothing to do with the dev
          // tool. The compiled binary is also what users actually run.
          final dt = await startDevTool(
            workspace: ws.root,
            target: ':plugin_macos',
            device: 'macos',
          );
          await dt.waitForEvent('app.started');

          final summary = await dt.waitForAppLog(
            'plugin_example_results',
            timeout: const Duration(seconds: 90),
          );
          // Not just "a line arrived" — the right line, with real content.
          expect(summary, contains('appName=Plugin Example'));
          expect(summary, contains('documentsPath=/'));

          // In machine mode stdout is the JSON-RPC stream. App output must
          // travel as app.log events and never as raw text, which would
          // corrupt what an IDE is parsing.
          expect(
            dt.nonProtocolStdoutLines,
            isEmpty,
            reason: 'raw text on the machine-protocol stdout stream',
          );

          await dt.sendCommand(1, 'daemon.shutdown');
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );

      test(
        'app output is readable from the /logs control endpoint',
        () async {
          final ws = await editableWorkspace('plugin_example');
          final dt = await startDevTool(
            workspace: ws.root,
            target: ':plugin_macos',
            device: 'macos',
          );
          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          await dt.waitForAppLog(
            'plugin_example_results',
            timeout: const Duration(seconds: 90),
          );
          final appId = dt.appId!;

          // Default (no cursor) tails, which is what a tool arriving mid-run
          // wants.
          final tail = await dt.httpLogs(appId);
          final tailTexts = [
            for (final l in tail['lines'] as List) (l as Map)['text'] as String,
          ];
          expect(
            tailTexts.any((t) => t.contains('plugin_example_results')),
            isTrue,
            reason:
                'the endpoint must serve the same output the machine '
                'protocol emitted',
          );

          // Resuming from nextCursor must not re-serve what was just read.
          final resumed = await dt.httpLogs(
            appId,
            since: tail['nextCursor'] as int,
          );
          final resumedIndices = [
            for (final l in resumed['lines'] as List)
              (l as Map)['index'] as int,
          ];
          final tailIndices = [
            for (final l in tail['lines'] as List) (l as Map)['index'] as int,
          ];
          expect(
            resumedIndices.toSet().intersection(tailIndices.toSet()),
            isEmpty,
            reason: 'a poll loop must not re-read lines it already has',
          );
          expect(tail['missed'], 0);

          await dt.sendCommand(1, 'daemon.shutdown');
        },
        timeout: const Timeout(Duration(minutes: 4)),
      );
    },
    skip: !Platform.isMacOS ? 'macOS only' : null,
  );

  // -- Web ---------------------------------------------------------------
  //
  // The only place plugin behaviour is verified on web. Each of these
  // plugins takes a different path there than on desktop: package_info_plus
  // reads a generated JS manifest, path_provider has no web implementation
  // at all and must say so rather than throw, url_launcher goes through
  // `window.open`, and `:greeting_plugin` is first-party Dart with no
  // platform channel. Nothing else in the suite would notice any of them
  // regressing on web.
  //
  // The line arrives as app output, so it is read off the machine protocol
  // rather than by scraping browser console messages through a second
  // toolchain.
  group('Web e2e', () {
    test(
      'plugin results are correct on web',
      () async {
        // The in-tree workspace, not an editable copy: this test reads the
        // app's output and changes nothing, and a copy would pay a cold
        // toolchain fetch into a fresh output base for no benefit.
        final dt = await startDevTool(
          workspace: e2eWorkspace('plugin_example'),
          target: ':plugin_web',
          device: 'chrome',
        );
        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 6),
        );

        final summary = await dt.waitForAppLog(
          'plugin_example_results',
          timeout: const Duration(minutes: 2),
        );

        // package_info_plus: the web build reads its own generated manifest,
        // not the macOS bundle Info.plist, so the name differs from the
        // desktop assertion above by design.
        expect(summary, contains('appName=plugin_example'));

        // path_provider ships no web implementation. Saying so is the correct
        // outcome; throwing, or reporting an empty path, is not.
        expect(summary, contains('documentsPath=web: not supported'));
        expect(summary, contains('tempPath=web: not supported'));

        // url_launcher's web implementation.
        expect(summary, contains('launchOk=launch ok'));

        // The curated `ext/` overlay packages: audio_session reaches web
        // through the overlay's own Dart, and record_android is Android-only
        // and must say so rather than throw.
        expect(summary, contains('audioSession=web: not supported'));
        expect(summary, contains('recordHasPermission=not supported'));

        // The hand-written plugin: pure Dart, no platform channel, so this
        // failing on web while passing on macOS would mean the registrant
        // never ran.
        expect(summary, contains('greeting=Hello from GreetingPlugin!'));

        await dt.sendCommand(1, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });

  // -- iOS Simulator ----------------------------------------------------
  //
  // Validates the iOS Apple Native Assets path (different bundle slot,
  // different code-sign target). Requires Xcode with the simulator
  // runtime; test harness boots/uses whatever simulator the dev_tool
  // selects.
  group(
    'iOS Simulator e2e',
    () {
      test('plugin_ios renders non-blank frame', () async {
        final ws = await editableWorkspace('plugin_example');
        await _runScreenshotTest(
          workspace: ws.root,
          target: ':plugin_ios',
          device: 'ios-simulator',
          outputBasename: 'plugin_ios_sim_e2e',
        );
      });

      test(
        'hot restart re-registers the iOS plugin set, not the host\'s',
        () async {
          final ws = await editableWorkspace('plugin_example');
          // The dev tool reads its plugin registrant from a bare build of the
          // flutter_application, which resolves in the HOST configuration —
          // macOS here. The registrant is platform-filtered, so a resident
          // frontend_server handed the host's copy compiles the macOS one into
          // its dills and the first hot restart re-registers UrlLauncherMacOS
          // instead of UrlLauncherIOS. Nothing errors at restart time; the app
          // just answers url_launcher calls with MissingPluginException from
          // then on. url_launcher is the
          // discriminator because its Dart registrant class differs between
          // iOS and macOS, while e.g. path_provider shares one Foundation
          // class across both and stays green either way.
          final appMain = ws.file('lib/main.dart');
          final appMainOrig = appMain.readAsStringSync();
          expect(
            appMainOrig,
            contains("'v1 \${r.launchOk}'"),
            reason: 'fixture marker present in plugin_example main.dart',
          );
          final dt = await startDevTool(
            workspace: ws.root,
            target: ':plugin_ios',
            device: 'ios-simulator',
          );
          await dt.waitForEvent('app.started');
          await dt.waitForHttpControl();
          final appId = dt.appId!;

          Future<String> launchOk(String tag, {required String marker}) async {
            Map<String, dynamic> resp = const {};
            for (var i = 0; i < 30; i++) {
              resp = await dt.httpCommand('app.getText', {
                'appId': appId,
                'key': 'e2e_launch_ok',
              });
              // Retry until the async FutureBuilder resolves AND the text
              // carries the expected marker — right after a restart the old
              // isolate's rendering can still answer the first getText.
              final text = resp['result']?['text'] as String? ?? '';
              if (resp['error'] == null && text.startsWith(marker)) return text;
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
            fail(
              'launchOk never resolved $tag: '
              'error=${resp['error']} text=${resp['result']?['text']}',
            );
          }

          expect(
            await launchOk('at launch', marker: 'v1 '),
            'v1 launch ok',
            reason:
                'url_launcher must resolve at launch (build registrant, '
                'compiled in the iOS configuration)',
          );

          // Edit the marker before restarting: seeing 'v2 ' after the restart
          // proves the restarted UI is the dev-tool-compiled dill — the dill
          // whose registrant this test is about. Without it a restart that
          // silently re-ran the launch kernel would pass vacuously.
          appMain.writeAsStringSync(
            appMainOrig.replaceFirst(
              "'v1 \${r.launchOk}'",
              "'v2 \${r.launchOk}'",
            ),
          );
          final restart = await dt.sendCommand(
            9,
            'app.restart',
            params: {
              'appId': appId,
            },
          );
          expect(
            restart['error'],
            isNull,
            reason: 'app.restart: ${restart['error']}',
          );

          expect(
            await launchOk('after restart', marker: 'v2 '),
            'v2 launch ok',
            reason:
                'url_launcher must still resolve after hot restart — '
                'the dev-tool-compiled dill must carry the iOS-filtered '
                'registrant, not the host platform\'s',
          );
        },
        timeout: const Timeout(Duration(minutes: 8)),
      );
    },
    skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
  );

  // -- Web / Chrome -----------------------------------------------------
  //
  // The web registrant is a build artifact of `flutter_web_bundle`. The
  // bundled build reaches it through the wrapper main it compiles in; DDC
  // dev mode compiles a *synthetic* entrypoint instead, so the registrant
  // has to be staged beside it and imported explicitly. When that wiring
  // is missing the app still launches and renders — it just answers every
  // plugin call with `MissingPluginException` — which is why the assertion
  // here is on the app's own diagnostic line, not on a screenshot.
  // DWDS injects `<script src=".../dwds/src/injected/client.js">` into the
  // page and then has to serve it. A DWDS that reads its own package source off
  // disk via `Isolate.resolvePackageUri` cannot do that from a Bazel-built
  // binary — the VM resolves `package:` URIs by searching upward from
  // `Platform.executable` for `.dart_tool/package_config.json`, and a binary
  // under `bazel-out/` has none — so it throws, and the browser gets a
  // `text/plain` 500 and refuses to execute the script. DWDS 27 compiles the
  // client into a string constant, resolving nothing at runtime.
  //
  // **This test must use the Bazel-built binary.** Under `dart run` the tool
  // sits in a source checkout whose `.dart_tool/` would rescue a package-config
  // lookup, so a resolving DWDS passes there and fails only for users. A
  // launch-style-agnostic version proves nothing.
  group(
    'Web DWDS injected client',
    () {
      test(
        'is served as executable JavaScript by the binary users run',
        () async {
          final ws = await editableWorkspace('plugin_example');
          final dt = await startDevTool(
            workspace: ws.root,
            target: ':plugin_web',
            device: 'chrome',
          );
          await dt.waitForEvent(
            'app.started',
            timeout: const Duration(minutes: 4),
          );

          // Base URL from the structured log rather than parsed out of prose.
          Uri? serverUri;
          for (final line in dt.stderrLines) {
            try {
              final obj = json.decode(line) as Map<String, dynamic>;
              if (obj['message'] == 'frontend_server_ready') {
                serverUri = Uri.parse(obj['uri'] as String);
              }
            } catch (_) {
              // Not JSON — skip.
            }
          }
          expect(
            serverUri,
            isNotNull,
            reason:
                'the DDC module server never reported its URL; '
                'stderr: ${dt.stderrLines.take(20).join(" | ")}',
          );

          final client = HttpClient();
          try {
            final request = await client.getUrl(
              serverUri!.replace(path: '/dwds/src/injected/client.js'),
            );
            final response = await request.close();
            await response.drain<void>();

            expect(
              response.statusCode,
              200,
              reason: 'DWDS injected client must be served',
            );
            expect(
              response.headers.contentType?.mimeType,
              anyOf('application/javascript', 'text/javascript'),
              reason:
                  'Chrome refuses non-JavaScript MIME types for <script>, '
                  'silently leaving the app with no debugger attached',
            );
          } finally {
            client.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 6)),
      );
    },
    skip: !Platform.isMacOS ? 'macOS only' : null,
  );

  group(
    'Web e2e',
    () {
      /// The app's single diagnostic line, forwarded as `app.log`.
      Future<String> pluginResults(
        EditableWorkspace ws,
        List<String> extraArgs,
      ) async {
        final dt = await startDevTool(
          workspace: ws.root,
          target: ':plugin_web',
          device: 'chrome',
          extraArgs: extraArgs,
        );
        return await dt.waitForAppLog(
          'plugin_example_results',
          timeout: const Duration(minutes: 4),
        );
      }

      void expectPluginsRegistered(String line) {
        expect(
          line,
          isNot(contains('MissingPluginException')),
          reason:
              'method-channel web plugins (package_info_plus, '
              'url_launcher) must be registered',
        );
        expect(
          line,
          contains('greeting=Hello from GreetingPlugin!'),
          reason: 'the hand-written web plugin must be registered',
        );
        expect(line, contains('appName=plugin_example'));
        expect(line, contains('launchOk=launch ok'));
      }

      // The DDC synthetic entrypoint has to carry both the registrant import
      // and the `registerPlugins:` callback, which needs the registrant among
      // the target's outputs and a `package:` URI for it that resolves.
      test(
        'web plugins register in DDC dev mode',
        () async {
          final ws = await editableWorkspace('plugin_example');
          expectPluginsRegistered(await pluginResults(ws, const []));
        },
        timeout: const Timeout(Duration(minutes: 6)),
      );

      // WASM dev mode serves the Bazel-built bundle verbatim, so it shares
      // the bundled build's registration path. Asserted so the two web dev
      // modes can never silently diverge.
      test(
        'web plugins register in WASM dev mode',
        () async {
          final ws = await editableWorkspace('plugin_example');
          expectPluginsRegistered(await pluginResults(ws, const ['--wasm']));
        },
        timeout: const Timeout(Duration(minutes: 6)),
      );
    },
  );

  // -- Android ----------------------------------------------------------
  //
  // Operates against whatever `adb devices` exposes — emulator or
  // USB-authorized physical device, whichever the user brought up. The
  // test does not start or stop emulators (mirrors how Bazel Android
  // instrumentation tests behave).
  //
  // Probed exactly once, here, and read by both the group's `skip:` and the
  // test body. Two calls could disagree — a phone unplugged between them —
  // and the one that decided whether to skip would not be the one that
  // decided what to run against.
  final android = AndroidDeviceProbe.detect();
  group(
    'Android e2e',
    () {
      // plugin_example keeps its flutter-create manifests pristine:
      // android.permission.INTERNET lives only in the debug variant
      // manifest, which flutter_android_app merges into -c dbg APKs. A
      // passing run is end-to-end proof of the variant-manifest merge:
      // without it, Android's kernel-level INTERNET enforcement (AID_INET
      // group) blocks the loopback bind the Dart VM service needs and the
      // dev tool's preflight aborts the launch (that fail-fast diagnostic
      // is unit-tested in device_test.dart).
      test('plugin_android renders non-blank frame', () async {
        final ws = await editableWorkspace('plugin_example');
        // dev_tool's -d flag takes an Android serial, not a generic
        // 'android' token. `$ANDROID_SERIAL` picks between an emulator and a
        // connected phone when both are attached; the probe honors it and
        // fails if it names something adb does not offer.
        //
        // The group only skips for a genuinely empty bench, so reaching here
        // with anything but a found device means the probe failed — a broken
        // or missing adb, or hardware in a state nothing can run on. That is
        // a tooling failure and it fails the test, loudly, saying which.
        final probe = android;
        if (probe is! AndroidDeviceFound) {
          fail(
            'Android device detection failed: '
            '${(probe as AndroidProbeFailed).reason}',
          );
        }
        // A phone and an emulator are different test surfaces — different
        // GPU, different ABI path, different timing — so a green run has to
        // name which one it covered rather than leaving it to be inferred from
        // what happened to be plugged in. Printed before the launch so a run
        // that fails names its device too. The runner relays
        // a test's prints into the live stream (`tool/e2e.dart`, `print`
        // event); it is not in the probe itself, which runs at suite load
        // time and under unit tests, neither of which should emit this.
        print('e2e: Android device ${probe.serial} (via ${probe.adb})');
        await _runScreenshotTest(
          workspace: ws.root,
          target: ':plugin_android',
          device: probe.serial,
          outputBasename: 'plugin_android_e2e',
        );
      });
    },
    skip: android.skipReason,
  );
}
