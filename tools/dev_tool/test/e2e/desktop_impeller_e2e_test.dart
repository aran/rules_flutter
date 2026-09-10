@Tags(['e2e'])
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart' as vm_io;

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// What the three desktop platforms owe under Impeller, asserted the same way
/// on each so a difference between them is visible.
///
/// Impeller is on by default in all three desktop embedders (macOS
/// `FlutterDartProject.enableImpeller`, Linux `FlDartProject.enable_impeller`,
/// Windows `FlutterWindowsEngine` resolving its `Default` switch to enabled),
/// and Impeller cannot encode a compressed screenshot — which is why
/// `Device.supportsFlutterScreenshot` is false for every device. This file
/// checks that against each platform rather than against the embedder sources.
///
/// Four things per platform, in the order a reader would want them:
///
///  1. **`screenshot/native` works.** The endpoint that must keep working,
///     because it is now the only one. Platform capture, no VM service.
///  2. **`screenshot/flutter` refuses.** A `501` naming `screenshot/native`,
///     which is what `supportsFlutterScreenshot => false` buys: a caller is
///     told a retry cannot help instead of getting a `500` that reads as
///     transient.
///  3. **The refusal is honest.** The raw `_flutter.screenshot` RPC, called
///     straight over the VM service so nothing in the dev tool can intercept
///     it, still fails. Without this the declaration would be self-fulfilling:
///     the endpoint refuses because we said to, and nobody checks whether the
///     engine would in fact have refused too. If this test starts failing,
///     the engine can serve the RPC again and the declaration should come off —
///     that is a real result, not a broken test.
///
///     macOS and Linux both answer `(-32000) Could not capture image
///     screenshot.` — the handler is there and Impeller declines to encode. The
///     message is printed rather than matched, so a platform that starts
///     answering differently says so.
///
///     Two things this must not do. `_flutter.*` are engine service-protocol
///     RPCs, not isolate `extensionRPCs`, so an isolate's extension list says
///     nothing about them — gating on it reports "never registered" everywhere,
///     macOS included. And asked too early the engine answers "no running
///     service protocol handlers", which is an empty handler set rather than a
///     verdict, and reads as a different mechanism per platform when it is the
///     same one.
///  4. **Hot reload lands.** An edit to the app bar title, an `app.hotReload`,
///     and the new title read back off the running widget tree. Reload
///     correctness is otherwise manual (see docs/TESTING.md) and covered
///     nowhere else on Linux or Windows.
void main() {
  _desktop(
    platform: 'macOS',
    workspace: 'macos_example',
    device: 'macos',
    title: 'macOS Example',
    runs: Platform.isMacOS,
  );
  _desktop(
    platform: 'Linux',
    workspace: 'linux_example',
    device: 'linux',
    title: 'Linux Example',
    runs: Platform.isLinux,
  );
  _desktop(
    platform: 'Windows',
    workspace: 'windows_example',
    device: 'windows',
    title: 'Windows Example',
    runs: Platform.isWindows,
  );
}

void _desktop({
  required String platform,
  required String workspace,
  required String device,
  required String title,
  required bool runs,
}) {
  group('$platform desktop', () {
    test(
      'native capture works, the engine one does not, and reload lands',
      () async {
        final ws = await editableWorkspace(workspace);
        final main = ws.file('lib/main.dart');
        final original = main.readAsStringSync();
        expect(
          original,
          contains("const Text('$title')"),
          reason:
              'this test edits the app bar title, so it has to be there to '
              'start with — $workspace/lib/main.dart changed shape',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':app',
          device: device,
        );
        // The dev tool builds the app itself, so this wait covers a Bazel
        // build, not just a launch. The harness's 120s default is a launch
        // budget: a cold Windows build of the runner (MSVC, and the Flutter
        // Windows engine to fetch) runs well past it, and the timeout then
        // reports "app.started never arrived", which sounds like the app
        // failed rather than that it was still compiling.
        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 15),
        );
        final appId = dt.appId!;
        expect(await dt.waitForHttpControl(), isNotNull);

        // 1. The endpoint that has to keep working.
        final native = await dt.nativeScreenshotWhenOnScreen(appId);
        expect(
          native.sublist(0, 4),
          [0x89, 0x50, 0x4E, 0x47],
          reason: 'screenshot/native must return a PNG on $platform',
        );

        // 2. The endpoint that has to refuse, and say where to go instead.
        final refusal = await dt.httpFlutterScreenshotReply(appId);
        expect(
          refusal.statusCode,
          HttpStatus.notImplemented,
          reason:
              'screenshot/flutter must refuse with 501 on $platform, not pass '
              'an engine error back as a 500: ${refusal.body}',
        );
        expect(refusal.body, contains('screenshot/native'));

        // 3. The refusal has to be true, not merely declared. Straight to the
        //    VM service, so the dev tool is not in the path at all.
        final debugPort = await dt.waitForEvent('app.debugPort');
        final wsUri = (debugPort['params'] as Map)['wsUri'] as String;
        final engineError = await _flutterScreenshotError(wsUri);
        expect(
          engineError,
          isNotNull,
          reason:
              '_flutter.screenshot SUCCEEDED on $platform. Impeller can encode '
              'a compressed screenshot now, or this app is not on Impeller — '
              'either way Device.supportsFlutterScreenshot should stop '
              'reporting false, and .bazelrc/README/TESTING.md say it does.',
        );
        // Printed rather than kept for a failure message: what the engine
        // says is the measurement this test exists to produce, and it differs
        // per platform.
        // ignore: avoid_print
        print('$platform raw _flutter.screenshot: $engineError');

        // 4. Hot reload, read off the running tree rather than an image.
        //
        // `app.waitFor` before each read, not a bare `getText`: the agent
        // answers as soon as the extensions are up, which is before the first
        // frame has necessarily built the tree, and a `getText` that lands in
        // that window returns an error whose `result` is absent — surfacing as
        // a bare `null` against the expected string, naming nothing.
        final ready = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'type': 'AppBar',
        });
        expect(ready['error'], isNull, reason: 'app.waitFor(AppBar): $ready');

        final before = await dt.httpCommand('app.getText', {
          'appId': appId,
          'type': 'AppBar',
        });
        expect(
          before['result']?['text'],
          title,
          reason: 'reading the app bar before any edit: $before',
        );

        main.writeAsStringSync(
          original.replaceFirst(
            "const Text('$title')",
            "const Text('$title RELOADED')",
          ),
        );
        final reload = await dt.sendCommand(
          1,
          'app.hotReload',
          params: {'appId': appId},
        );
        expect(
          reload['result']?['error'],
          isNull,
          reason: 'app.hotReload on $platform: $reload',
        );

        // Waiting for the new text *is* the assertion that the reload landed
        // in the running app; the `getText` below only reports what it found.
        final repainted = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'text': '$title RELOADED',
        });
        expect(
          repainted['error'],
          isNull,
          reason:
              'the reload answered but "$title RELOADED" never appeared in the '
              'running app, which is the failure mode a smoke assertion '
              'misses: $repainted',
        );

        final after = await dt.httpCommand('app.getText', {
          'appId': appId,
          'type': 'AppBar',
        });
        expect(after['result']?['text'], '$title RELOADED', reason: '$after');

        await dt.sendCommand(2, 'app.stop', params: {'appId': appId});
      },
      timeout: const Timeout(Duration(minutes: 20)),
    );
  }, skip: runs ? null : 'runs on $platform only');
}

/// The error `_flutter.screenshot` fails with, or null if it succeeded.
///
/// Called directly on the VM service rather than through the control channel,
/// which refuses before reaching the engine.
Future<String?> _flutterScreenshotError(String wsUri) async {
  final service = await vm_io.vmServiceConnectUri(wsUri);
  try {
    final isolate = await _mainIsolate(service);
    // Retry past "no running service protocol handlers", which is the engine
    // saying its handler set is still empty (`service_protocol.cc`) — not a
    // verdict on whether it can capture. Taken as the answer, it reports a
    // platform as failing for a reason that is only its startup timing.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (true) {
      try {
        final response = await service.callServiceExtension(
          '_flutter.screenshot',
          isolateId: isolate.id,
        );
        return response.json?['screenshot'] == null
            ? 'returned no screenshot data'
            : null;
      } on vm.RPCError catch (e) {
        final message = '(${e.code}) ${e.message}';
        if (!message.contains('no running service protocol handlers') ||
            !DateTime.now().isBefore(deadline)) {
          return message;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  } finally {
    await service.dispose();
  }
}

/// The app's main isolate, waited for rather than assumed.
///
/// `app.started` says the dev tool has a session, not that a second client
/// connecting to the same VM service sees an isolate yet: on Linux under Xvfb
/// `getVM()` can answer with an empty list. Polled rather than slept past: the
/// wait ends on the isolate existing.
Future<vm.IsolateRef> _mainIsolate(
  vm.VmService service, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  var delay = const Duration(milliseconds: 50);
  while (true) {
    final isolates =
        (await service.getVM()).isolates ?? const <vm.IsolateRef>[];
    if (isolates.isNotEmpty) {
      return isolates.firstWhere(
        (i) => i.name == 'main',
        orElse: () => isolates.first,
      );
    }
    if (!DateTime.now().isBefore(deadline)) {
      throw StateError(
        'the VM service reported no isolates within ${timeout.inSeconds}s, so '
        'there was nothing to ask for a screenshot',
      );
    }
    await Future<void>.delayed(delay);
    delay = delay * 2 > const Duration(seconds: 2)
        ? const Duration(seconds: 2)
        : delay * 2;
  }
}
