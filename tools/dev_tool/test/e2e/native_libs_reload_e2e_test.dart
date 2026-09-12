@Tags(['e2e'])
/// What a hot reload does when its own rebuild moved a native library, in both
/// directions: delivered when the bindings are unchanged, withheld when they are
/// not.
///
/// The gap this covers is silent by construction, which is why it needs a real
/// app. A codegen app's hot reload runs a `bazel build` of the
/// `flutter_application` to regenerate its sources, and that build also
/// recompiles the app's loose native libraries (`native_deps`) — the images the
/// running process has already `dlopen`ed and can never replace. Nothing stopped
/// the increment from being injected on top of them, and nothing said so: the edit
/// went in, the reply said success, and the machine code the app ran was from
/// before the edit.
///
/// `codegen` is the only workspace where both halves are true at once — it is
/// source-assembled (so a reload rebuilds through bazel) and `//:app` bundles
/// `//native_add:native_add_shared` through a `flutter_native_library` wrapper
/// that declares the C header as its binding contract. A header *is* the contract
/// of a C library: the signatures live there, so editing the `.c` moves the
/// library alone and editing the `.h` moves both. That is what makes both
/// directions drivable from one fixture.
///
/// ## What each assertion is for
///
/// Case A — library moved, contract unchanged:
///  1. The reload **succeeds** and the app shows the new Dart. A reload that
///     refused here would make a pending native edit block the Dart loop for the
///     rest of the run, which is a worse tool than the bug it came from.
///  2. `nativeLibsStale` names the library anyway, on a successful command: the
///     edit to the function's body is live in every sense except the one that
///     matters, and a reply that said only "successful" is how someone spends an
///     afternoon on it.
///  3. A restart relaunches, and then the reload after it is clean — the watch is
///     re-baselined by the relaunch, and one that was not would report the library
///     stale forever.
///
/// Case B — contract moved too:
///  4. The reload is **withheld**, and the window still shows case A's Dart. The
///     Dart half of the same edit is what makes that checkable: `runningCode:
///     unchanged` is a claim about the whole command, and an app showing the new
///     string would prove the increment went in after all.
library;

import 'dart:async';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

void main() {
  group('native library rebuilt under a hot reload', () {
    test('delivered when the bindings hold, withheld when they move', () async {
      final ws = await editableWorkspace('codegen');
      final appMain = ws.file('lib/main.dart');
      final nativeSource = ws.file('native_add/native/native_add.c');
      final nativeHeader = ws.file('native_add/native/native_add.h');
      final mainOriginal = appMain.readAsStringSync();
      final sourceOriginal = nativeSource.readAsStringSync();
      final headerOriginal = nativeHeader.readAsStringSync();
      const dartAnchor = "'fields:";
      const bodyAnchor = '(int32_t)((uint32_t)a + (uint32_t)b)';
      const signature = 'int32_t native_add(int32_t a, int32_t b);';
      expect(
        mainOriginal.contains(dartAnchor),
        isTrue,
        reason: 'fixture marker present in codegen lib/main.dart',
      );
      expect(
        sourceOriginal.contains(bodyAnchor),
        isTrue,
        reason: 'fixture marker present in native_add/native/native_add.c',
      );
      expect(
        headerOriginal.contains(signature),
        isTrue,
        reason: 'fixture marker present in native_add/native/native_add.h',
      );

      final dt = await startDevTool(
        workspace: ws.root,
        target: ':app_macos',
        device: 'macos',
      );
      try {
        await dt.waitForEvent(
          'app.started',
          timeout: const Duration(minutes: 6),
        );
      } on TimeoutException {
        fail(
          'no app.started within 6m.\nstderr:\n${dt.stderrLines.join('\n')}\n'
          'stdout (non-protocol):\n${dt.nonProtocolStdoutLines.join('\n')}',
        );
      }
      final appId = dt.appId!;
      await dt.waitForHttpControl(timeout: const Duration(seconds: 120));
      // Edit only once the pipeline has assembled, which is what a user doing this
      // does and what the check's baseline depends on. The assembler runs its own
      // `bazel build` of the app target, and the libraries that build writes are
      // what the watch records as the ones the process has. An edit landing
      // *inside* that window is picked up by that very build, so the baseline
      // moves to code the process never loaded and the reload after it sees
      // nothing changed — the startup window documented on `NativeLibsWatch.of`,
      // which a restart recovers from because the relauncher compares the launched
      // bundle itself.
      await dt.waitForStderr(
        'frontend_server_ready',
        timeout: const Duration(minutes: 6),
      );
      await _expectRendered(dt, appId, 'fields:name');

      // ---- Case A: the library's code moved, its contract did not ----------
      appMain.writeAsStringSync(
        mainOriginal.replaceFirst(dartAnchor, "'DELIVERED:"),
      );
      nativeSource.writeAsStringSync(
        sourceOriginal.replaceFirst(bodyAnchor, '$bodyAnchor + 1'),
      );

      final delivered = await _command(dt, 'app.hotReload', appId);
      expect(
        delivered['succeeded'],
        isTrue,
        reason:
            'the bindings are unchanged, so the increment is safe over the '
            'library the process has: ${delivered['error']}',
      );
      expect(
        delivered['nativeLibsStale'],
        contains(contains('libnative_add.dylib')),
        reason:
            'the app is running old machine code, and a reply that did not say '
            'so is the silence this whole check exists to break',
      );
      expect(delivered['runningCode'], 'updated');
      await _expectRendered(dt, appId, 'DELIVERED:name');

      // The way out, which the reply names. The relauncher rebuilds the launch
      // bundle, finds the library moved, and replaces the process.
      final relaunched = await _command(dt, 'app.restart', appId);
      expect(
        relaunched['relaunched'],
        isTrue,
        reason:
            'a hot restart keeps the process and its mapped images; only a '
            'relaunch can deliver the library',
      );
      expect(relaunched['succeeded'], isTrue);
      await _expectRendered(dt, appId, 'DELIVERED:name');

      // And the run keeps working: the relaunch re-baselined what the process
      // has, so an ordinary Dart edit reloads with nothing reported stale.
      appMain.writeAsStringSync(
        mainOriginal.replaceFirst(dartAnchor, "'RELOADED:"),
      );
      final ordinary = await _command(dt, 'app.hotReload', appId);
      expect(
        ordinary['succeeded'],
        isTrue,
        reason: 'nothing is stale after the relaunch: ${ordinary['error']}',
      );
      expect(ordinary.containsKey('nativeLibsStale'), isFalse);
      await _expectRendered(dt, appId, 'RELOADED:name');

      // ---- Case B: the contract moved with the library ---------------------
      // A signature change: the header is the declared contract, so this is the
      // case where new bindings over the old image would encode a call it cannot
      // decode.
      appMain.writeAsStringSync(
        mainOriginal.replaceFirst(dartAnchor, "'BLOCKED:"),
      );
      nativeHeader.writeAsStringSync(
        headerOriginal.replaceFirst(
          signature,
          'int32_t native_add(int32_t a, int32_t b, int32_t c);',
        ),
      );
      nativeSource.writeAsStringSync(
        sourceOriginal
            .replaceFirst(
              'int32_t native_add(int32_t a, int32_t b) {',
              'int32_t native_add(int32_t a, int32_t b, int32_t c) {',
            )
            .replaceFirst(bodyAnchor, '$bodyAnchor + c'),
      );

      final withheld = await _command(dt, 'app.hotReload', appId);
      expect(
        withheld['succeeded'],
        isFalse,
        reason: 'the bindings moved, so the edit may not be injected',
      );
      expect(
        withheld['nativeLibsStale'],
        contains(contains('libnative_add.dylib')),
      );
      expect(withheld['runningCode'], 'unchanged');
      // The promise `unchanged` makes, against the screen: the Dart half of the
      // same edit was not delivered either.
      await _expectRendered(dt, appId, 'RELOADED:name');
    }, timeout: const Timeout(Duration(minutes: 15)));
  });
}

/// Send [method] and require a result rather than a transport error.
Future<Map<String, dynamic>> _command(
  DevToolProcess dt,
  String method,
  String appId,
) async {
  final response = await dt.httpCommand(method, {'appId': appId});
  final result = response['result'] as Map<String, dynamic>?;
  expect(result, isNotNull, reason: '$method: ${response['error']}');
  return result!;
}

/// Require the running app to be displaying [text].
///
/// `app.waitFor`'s `text` selector is exact equality on the widget's own string,
/// and a miss answers with a top-level `error` and no `result` — so this is a real
/// assertion about what is on screen, not a poll that can pass by finding nothing.
Future<void> _expectRendered(
  DevToolProcess dt,
  String appId,
  String text,
) async {
  final found = await dt.httpCommand('app.waitFor', {
    'appId': appId,
    'text': text,
    'timeoutMs': '20000',
  });
  expect(
    found['result'],
    isNotNull,
    reason: 'the app is not showing "$text": ${found['error']}',
  );
}
