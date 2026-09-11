@Tags(['e2e'])
/// A hot reload whose own rebuild moved a native library must withhold the
/// increment, and a restart must then deliver it.
///
/// The gap this closes is silent by construction, which is why it needs a real
/// app. A codegen app's hot reload runs a `bazel build` of the
/// `flutter_application` to regenerate its sources, and that build also
/// recompiles the app's loose native libraries (`native_deps`) — the images the
/// running process has already `dlopen`ed and can never replace. Nothing stopped
/// the increment from being injected on top of them, and nothing said so: the
/// edit went in, the reply said success, and the machine code the app ran was
/// from before the edit.
///
/// `codegen` is the only workspace where both halves are true at once — it is
/// source-assembled (so a reload rebuilds through bazel) and `//:app` bundles
/// `//native_add:native_add_shared`. Unit tests cover the decision; only a run
/// like this one proves the reply, the untouched app, and the way out.
///
/// ## What each assertion is for
///
///  1. The reply is a refusal that names the library (`nativeLibsStale`), in a
///     field rather than prose: `--machine` drops nothing a driver needs, and a
///     test asserting the sentence would assert nothing.
///  2. The app still renders the **old** Dart. The Dart half of the same edit is
///     what makes this checkable: `runningCode: unchanged` is a claim about the
///     whole command, and an app showing the new string would prove the
///     increment went in after all.
///  3. The restart relaunches and the app renders the new Dart. The refusal
///     names a restart as the way out, so the way out is under test too.
///  4. The reload **after** the restart succeeds. The watch is re-baselined by
///     the relaunch; one that was not would withhold every reload for the rest
///     of the run, turning this fix into a worse bug than the one it closes.
library;

import 'dart:async';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

void main() {
  group('native library rebuilt under a hot reload', () {
    test('the increment is withheld, and a restart delivers it', () async {
      final ws = await editableWorkspace('codegen');
      final appMain = ws.file('lib/main.dart');
      final nativeSource = ws.file('native_add/native/native_add.c');
      final mainOriginal = appMain.readAsStringSync();
      final nativeOriginal = nativeSource.readAsStringSync();
      const dartAnchor = "'fields:";
      const nativeAnchor = '(int32_t)((uint32_t)a + (uint32_t)b)';
      expect(
        mainOriginal.contains(dartAnchor),
        isTrue,
        reason: 'fixture marker present in codegen lib/main.dart',
      );
      expect(
        nativeOriginal.contains(nativeAnchor),
        isTrue,
        reason: 'fixture marker present in native_add/native/native_add.c',
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
      // Edit only once the pipeline has assembled, which is what a user doing
      // this does and what the check's baseline depends on. The assembler runs
      // its own `bazel build` of the app target, and the libraries that build
      // writes are what the watch records as the ones the process has. An edit
      // landing *inside* that window is picked up by that very build, so the
      // baseline moves to code the process never loaded and the reload after it
      // sees nothing changed — the startup window documented on
      // `NativeLibsWatch.of`, which a restart recovers from because the
      // relauncher compares the launched bundle itself.
      await dt.waitForStderr(
        'frontend_server_ready',
        timeout: const Duration(minutes: 6),
      );
      await _expectRendered(dt, appId, 'fields:name');

      // Both halves of one edit: the Dart a reload would deliver, and the native
      // source the reload's own rebuild recompiles.
      appMain.writeAsStringSync(
        mainOriginal.replaceFirst(dartAnchor, "'WITHHELD:"),
      );
      nativeSource.writeAsStringSync(
        nativeOriginal.replaceFirst(nativeAnchor, '$nativeAnchor + 1'),
      );

      final reload = await dt.httpCommand('app.hotReload', {'appId': appId});
      final withheld = reload['result'] as Map<String, dynamic>?;
      expect(withheld, isNotNull, reason: 'app.hotReload: ${reload['error']}');
      expect(
        withheld!['succeeded'],
        isFalse,
        reason: 'the edit is not running, so the reply may not say it is',
      );
      expect(
        withheld['nativeLibsStale'],
        contains(contains('libnative_add.dylib')),
        reason: 'the reply must name the library that went stale',
      );
      expect(withheld['runningCode'], 'unchanged');
      expect(withheld['error'], contains('libnative_add.dylib'));
      // (2) The promise that `unchanged` makes, against the screen.
      await _expectRendered(dt, appId, 'fields:name');

      // (3) The way out the refusal names. The relauncher rebuilds the launch
      // bundle, finds the library moved, and replaces the process — which comes
      // up running both halves of the edit.
      final restart = await dt.httpCommand('app.restart', {'appId': appId});
      final relaunched = restart['result'] as Map<String, dynamic>?;
      expect(relaunched, isNotNull, reason: 'app.restart: ${restart['error']}');
      expect(
        relaunched!['relaunched'],
        isTrue,
        reason:
            'a hot restart keeps the process and its mapped images; only a '
            'relaunch can deliver the library',
      );
      expect(relaunched['succeeded'], isTrue);
      await _expectRendered(dt, appId, 'WITHHELD:name');

      // (4) And the run keeps working: the relaunch re-baselined what the
      // process has, so an ordinary Dart edit reloads the way it always did.
      appMain.writeAsStringSync(
        mainOriginal.replaceFirst(dartAnchor, "'RELOADED:"),
      );
      final after = await dt.httpCommand('app.hotReload', {'appId': appId});
      final ordinary = after['result'] as Map<String, dynamic>?;
      expect(ordinary, isNotNull, reason: 'app.hotReload: ${after['error']}');
      expect(
        ordinary!['succeeded'],
        isTrue,
        reason:
            'the process is running the rebuilt library, so nothing is stale: '
            '${ordinary['error']}',
      );
      expect(ordinary.containsKey('nativeLibsStale'), isFalse);
      await _expectRendered(dt, appId, 'RELOADED:name');
    }, timeout: const Timeout(Duration(minutes: 12)));
  });
}

/// Require the running app to be displaying [text].
///
/// `app.waitFor`'s `text` selector is exact equality on the widget's own string,
/// and a miss answers with a top-level `error` and no `result` — so this is a
/// real assertion about what is on screen, not a poll that can pass by finding
/// nothing.
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
