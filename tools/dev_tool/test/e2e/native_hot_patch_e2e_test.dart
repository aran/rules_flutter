@Tags(['e2e'])
/// A native edit delivered into a running app by a hot reload, end to end.
///
/// `ffi_example`'s `mul` is declared with `flutter_native_library.hot_patch`:
/// `native/mul_hot_patch.c` routes every call through a pointer a patch can
/// move, and `//:mul_hot_patch` builds a patch — a second build of
/// `native/mul.c` — and a tool that decides what a reload may do with it. The C
/// fixture is deliberately crude; what is under test is everything between the
/// edit and the running code, which is the same for any patch builder:
///
///  1. **Noticed without a Dart change or a codegen rebuild.** `ffi_example` is
///     not source-assembled, so its hot reload runs no bazel of its own; the only
///     thing that can see an edit to `mul.c` is the patcher's stat of the sources
///     the manifest declared.
///  2. **Built, delivered, loaded, and visible.** The reply names the library and
///     what was patched, and a widget that calls `mul` on every build shows the
///     new answer — which also pins the reassemble a reload with no Dart delta
///     needs, since nothing else would rebuild it.
///  3. **State kept.** The value `main` computed at launch is still on screen:
///     this was not a restart.
///  4. **A signature change is withheld**, with the app left exactly as it was.
///  5. **An undone edit goes back to the launched code**, which the builder
///     answers as `unchanged` and only the dev tool knows is still patched.
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

void main() {
  group('native hot patch', () {
    test(
      'a C edit reaches the running app on a hot reload, and a header edit '
      'is withheld',
      () async {
        final ws = await editableWorkspace('ffi_example');
        final mulSource = ws.file('native/mul.c');
        final mulHeader = ws.file('native/mul.h');
        final sourceOriginal = mulSource.readAsStringSync();
        final headerOriginal = mulHeader.readAsStringSync();
        expect(
          sourceOriginal,
          contains('return a * b;'),
          reason: 'fixture marker',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':ffi_macos',
          device: 'macos',
        );
        try {
          await dt.waitForEvent(
            'app.started',
            timeout: const Duration(minutes: 6),
          );
        } on TimeoutException {
          fail(
            'no app.started within 6m.\nstderr:\n'
            '${dt.stderrLines.join('\n')}\n'
            'stdout (non-protocol):\n'
            '${dt.nonProtocolStdoutLines.join('\n')}',
          );
        }
        final appId = dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 120));
        // Armed before edited: the snapshot is taken at assembly, and an edit
        // inside that window would become the baseline.
        await dt.waitForStderr(
          'native_hot_patch_armed',
          timeout: const Duration(minutes: 6),
        );
        await dt.waitForStderr(
          'frontend_server_ready',
          timeout: const Duration(minutes: 6),
        );
        await _expectRendered(dt, appId, 'live 3 × 4 = 12');

        // ---- 1–3: a body edit, delivered -------------------------------------
        mulSource.writeAsStringSync(
          sourceOriginal.replaceFirst('return a * b;', 'return a * b + 1000;'),
        );
        final patched = await _reload(dt, appId);
        expect(patched['succeeded'], isTrue, reason: '$patched');
        expect(patched['runningCode'], 'updated', reason: '$patched');
        expect(patched['nativePatched'], {
          'libmul.dylib': ['mul_body'],
        });
        await _expectRendered(dt, appId, 'live 3 × 4 = 1012');
        // Computed once in `main`, before the patch: still there, because this
        // was not a restart.
        final tree = await dt.httpCommand('app.dumpWidgetTree', {
          'appId': appId,
        });
        final sqlite = RegExp(
          r'sqlite3 ([0-9.]+)',
        ).firstMatch(tree['result'].toString());
        expect(
          sqlite,
          isNotNull,
          reason: 'the widget tree shows no sqlite label',
        );
        await _expectRendered(
          dt,
          appId,
          '3 + 4 = 7\n3 × 4 = 12\nsqlite3 ${sqlite!.group(1)}',
        );

        // A reload with nothing new is free again, and says nothing native.
        final quiet = await _reload(dt, appId);
        expect(quiet['nativePatched'], isNull, reason: '$quiet');

        // ---- 4: a header edit, withheld --------------------------------------
        mulHeader.writeAsStringSync('$headerOriginal// a new declaration\n');
        final withheld = await _reload(dt, appId);
        expect(withheld['succeeded'], isFalse, reason: '$withheld');
        expect(withheld['runningCode'], 'unchanged', reason: '$withheld');
        expect(withheld['message'], contains('withheld'));
        await _expectRendered(dt, appId, 'live 3 × 4 = 1012');
        mulHeader.writeAsStringSync(headerOriginal);

        // ---- 5: the edit undone ----------------------------------------------
        mulSource.writeAsStringSync(sourceOriginal);
        final reverted = await _reload(dt, appId);
        expect(reverted['succeeded'], isTrue, reason: '$reverted');
        expect(reverted['nativeReverted'], ['libmul.dylib']);
        await _expectRendered(dt, appId, 'live 3 × 4 = 12');
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}

Future<Map<String, dynamic>> _reload(DevToolProcess dt, String appId) async {
  final response = await dt.httpCommand('app.hotReload', {'appId': appId});
  final result = response['result'] as Map<String, dynamic>?;
  expect(result, isNotNull, reason: 'app.hotReload: ${response['error']}');
  return result!;
}

/// Require the running app to be displaying [text], exactly.
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
