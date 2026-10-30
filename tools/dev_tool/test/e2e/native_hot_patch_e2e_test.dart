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
///  4. **A new callable is withheld**, with the app left exactly as it was —
///     and withheld by the *builder*, which is what the dev tool asks once a
///     moved contract has a builder to ask. A contract that moved without
///     changing what a caller may call is delivered (4b), which is the case the
///     dev tool used to refuse before anyone was asked.
///  5. **An undone edit goes back to the launched code**, which the builder
///     answers as `unchanged` and only the dev tool knows is still patched.
///  6. **A library with no patch builder is reported, not ignored.** `add` has
///     neither a `hot_patch` nor a binding contract, and nothing rebuilds it
///     between reloads, so an edit to `native/add.c` is visible only through the
///     sources the build declared — the gap that let a reload report success
///     over machine code from before the edit.
///  7. **A library delivered as a code asset patches the same way.** `sub`
///     reaches the app on a plain `dart_library`'s `code_assets`, from a rule
///     that is not rules_dart's, and is called through `@Native`. The
///     `flutter_native_library` wrapper in those `code_assets` is the only place
///     its contract and patch builder are declared: without the contract, the
///     sources the build declares for it make every edit a reload withheld over
///     a library nothing describes, and without the builder nothing is armed.
///  8. **One library serving two asset ids patches once, and keeps its state.**
///     `counter` serves `package:count_a` and `package:count_b` from one image,
///     through one wrapper per id that all name one `hot_patch`. The builder is
///     armed once for it, an edit to `native/counter.c` is one patch, and a bump
///     through either id then runs the new code on the count the launched code
///     left, still shared. That holds because the count lives in the launched
///     image and is passed to the body; a patch is a second image, so a static
///     in the patched source would be a fresh count of its own. The builder
///     withholds the two edits that would fork state that way: the body
///     defining storage, and the state's layout moving.
///  9. **The advice works.** Edits 4 and 6 kept rather than undone: the reload
///     names a restart, the restart goes through though no bundled byte moved,
///     and the reload after it is clean.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

void main() {
  group('native hot patch', () {
    test(
      'a C edit reaches the running app on a hot reload, and a contract edit '
      'is answered by the builder',
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
        final armed = await dt.waitForStderr(
          'native_hot_patch_armed',
          timeout: const Duration(minutes: 6),
        );
        final armedLibraries = [
          for (final l in (jsonDecode(armed) as Map)['libraries'] as List) '$l',
        ];
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

        // ---- 4: a new callable, withheld -------------------------------------
        //
        // The shape a bridge generator produces when a function is added: the
        // contract gains a declaration. Dart reaches this library by symbol and
        // a patch is loaded beside it rather than into it, so the running image
        // has no way to serve the new one — which is the builder's judgement to
        // make, and it makes it here.
        mulHeader.writeAsStringSync(
          headerOriginal.replaceFirst(
            'FFI_EXAMPLE_EXPORT int32_t mul(int32_t a, int32_t b);',
            'FFI_EXAMPLE_EXPORT int32_t mul(int32_t a, int32_t b);\n'
                'FFI_EXAMPLE_EXPORT int32_t mul_twice(int32_t a);',
          ),
        );
        final withheld = await _reload(dt, appId);
        expect(withheld['succeeded'], isFalse, reason: '$withheld');
        expect(withheld['runningCode'], 'unchanged', reason: '$withheld');
        expect(withheld['message'], contains('withheld'));
        // The builder's sentence, not the dev tool's. The contract moving is
        // what got the builder asked; which part of it moved is the builder's
        // to say, and it is the half of the answer that tells you what to do.
        expect(
          '${withheld['error']}',
          contains('cannot be reached through it'),
          reason: '$withheld',
        );
        expect(withheld['nativePatchRestart'], isNotNull, reason: '$withheld');
        await _expectRendered(dt, appId, 'live 3 × 4 = 1012');
        mulHeader.writeAsStringSync(headerOriginal);

        // ---- 4b: a contract edit the builder can serve, delivered ------------
        //
        // The refusal above used to be the answer to *any* moved contract, with
        // the builder never asked — so an edit that moved the contract and
        // changed nothing a caller may call was undeliverable for the rest of
        // the run, however well the patch carried it. Here the header moves and
        // its declarations do not, and the body moves with it.
        mulHeader.writeAsStringSync(
          '$headerOriginal// A comment. Moves the contract; no caller notices.\n',
        );
        mulSource.writeAsStringSync(
          sourceOriginal.replaceFirst('return a * b;', 'return a * b + 7;'),
        );
        final served = await _reload(dt, appId);
        expect(served['succeeded'], isTrue, reason: '$served');
        expect(served['runningCode'], 'updated', reason: '$served');
        expect(served['nativePatched'], {
          'libmul.dylib': ['mul_body'],
        });
        await _expectRendered(dt, appId, 'live 3 × 4 = 19');

        // And the contract the patch served is settled: the next reload reads
        // the same moved bytes, and must not withhold over an image that caught
        // up an edit ago.
        final after = await _reload(dt, appId);
        expect(after['succeeded'], isTrue, reason: '$after');
        expect(after['nativePatched'], isNull, reason: '$after');
        mulHeader.writeAsStringSync(headerOriginal);

        // ---- 5: the edit undone ----------------------------------------------
        mulSource.writeAsStringSync(sourceOriginal);
        final reverted = await _reload(dt, appId);
        expect(reverted['succeeded'], isTrue, reason: '$reverted');
        expect(reverted['nativeReverted'], ['libmul.dylib']);
        await _expectRendered(dt, appId, 'live 3 × 4 = 12');

        // ---- 6: a library nothing can patch -----------------------------------
        final addSource = ws.file('native/add.c');
        final addOriginal = addSource.readAsStringSync();
        addSource.writeAsStringSync('$addOriginal// edited\n');
        final unverifiable = await _reload(dt, appId);
        expect(unverifiable['succeeded'], isFalse, reason: '$unverifiable');
        expect(unverifiable['runningCode'], 'unchanged');
        expect(
          '${unverifiable['nativeLibsStale']}',
          contains('libadd.dylib'),
          reason: 'the reload must name the library it is about',
        );

        // And undoing it leaves the run where it was.
        addSource.writeAsStringSync(addOriginal);
        expect((await _reload(dt, appId))['succeeded'], isTrue);

        // ---- 7: a library delivered as a code asset ---------------------------
        final subSource = ws.file('native/sub.c');
        final subHeader = ws.file('native/sub.h');
        final subOriginal = subSource.readAsStringSync();
        final subHeaderOriginal = subHeader.readAsStringSync();
        expect(
          subOriginal,
          contains('return a - b;'),
          reason: 'fixture marker',
        );
        await _expectRendered(dt, appId, 'live 9 - 4 = 5');

        subSource.writeAsStringSync(
          subOriginal.replaceFirst('return a - b;', 'return a - b + 100;'),
        );
        final subPatched = await _reload(dt, appId);
        expect(subPatched['succeeded'], isTrue, reason: '$subPatched');
        expect(subPatched['runningCode'], 'updated', reason: '$subPatched');
        expect(subPatched['nativePatched'], {
          'libsub.dylib': ['sub_body'],
        });
        await _expectRendered(dt, appId, 'live 9 - 4 = 105');

        // A moved contract is the builder's question here too, which it can
        // only be if the contract reached the dev config through the asset.
        subHeader.writeAsStringSync(
          subHeaderOriginal.replaceFirst(
            'FFI_EXAMPLE_EXPORT int32_t sub(int32_t a, int32_t b);',
            'FFI_EXAMPLE_EXPORT int32_t sub(int32_t a, int32_t b);\n'
                'FFI_EXAMPLE_EXPORT int32_t sub_twice(int32_t a);',
          ),
        );
        final subWithheld = await _reload(dt, appId);
        expect(subWithheld['succeeded'], isFalse, reason: '$subWithheld');
        expect(
          '${subWithheld['error']}',
          contains('cannot be reached through it'),
          reason: '$subWithheld',
        );
        await _expectRendered(dt, appId, 'live 9 - 4 = 105');
        subHeader.writeAsStringSync(subHeaderOriginal);

        subSource.writeAsStringSync(subOriginal);
        final subReverted = await _reload(dt, appId);
        expect(subReverted['succeeded'], isTrue, reason: '$subReverted');
        expect(subReverted['nativeReverted'], ['libsub.dylib']);
        await _expectRendered(dt, appId, 'live 9 - 4 = 5');

        // ---- 8: one library serving two asset ids, and its state ------------
        final counterSource = ws.file('native/counter.c');
        final counterState = ws.file('native/counter_state.h');
        final counterOriginal = counterSource.readAsStringSync();
        final counterStateOriginal = counterState.readAsStringSync();
        expect(
          counterOriginal,
          contains('count += 1;'),
          reason: 'fixture marker',
        );
        // One builder for the library, however many ids it serves.
        expect(
          armedLibraries.where((l) => l == 'libcounter.dylib'),
          hasLength(1),
          reason: 'armed: $armedLibraries',
        );
        // `main` bumped once through each id; this is the third bump.
        await _expectBump(dt, appId, 'A', 3);

        counterSource.writeAsStringSync(
          counterOriginal.replaceFirst('count += 1;', 'count += 10;'),
        );
        final counterPatched = await _reload(dt, appId);
        expect(counterPatched['succeeded'], isTrue, reason: '$counterPatched');
        expect(counterPatched['runningCode'], 'updated');
        // One patch, for the one library both ids load, not one per id.
        expect(counterPatched['nativePatched'], {
          'libcounter.dylib': ['counter_bump_body'],
        });
        // Dart state kept: the last bump is still on screen.
        await _expectRendered(dt, appId, 'bumped via A: 3');
        // Both ids run the new code, from the count the launched code left,
        // and still share it.
        await _expectBump(dt, appId, 'A', 13);
        await _expectBump(dt, appId, 'B', 23);

        // A patch that would keep state of its own is withheld by the
        // builder: that state would start fresh in the patch's image and be
        // invisible to the one the app launched.
        counterSource.writeAsStringSync(
          counterOriginal
              .replaceFirst('count += 1;', 'count += 10;')
              .replaceFirst(
                'FFI_EXAMPLE_EXPORT int32_t counter_bump_body',
                'static int32_t bumps = 0;\n\n'
                    'FFI_EXAMPLE_EXPORT int32_t counter_bump_body',
              ),
        );
        final forked = await _reload(dt, appId);
        expect(forked['succeeded'], isFalse, reason: '$forked');
        expect(forked['runningCode'], 'unchanged', reason: '$forked');
        expect(
          '${forked['error']}',
          contains('static int32_t bumps = 0;'),
          reason: '$forked',
        );
        await _expectBump(dt, appId, 'A', 33);

        // So is one that changes the shape of the state the running image
        // holds.
        counterSource.writeAsStringSync(
          counterOriginal.replaceFirst('count += 1;', 'count += 10;'),
        );
        counterState.writeAsStringSync(
          counterStateOriginal.replaceFirst(
            'int32_t count;',
            'int32_t count;\n    int32_t bumps;',
          ),
        );
        final reshaped = await _reload(dt, appId);
        expect(reshaped['succeeded'], isFalse, reason: '$reshaped');
        expect(
          '${reshaped['error']}',
          contains('counter_state.h'),
          reason: '$reshaped',
        );
        counterState.writeAsStringSync(counterStateOriginal);

        // Undone: back to the launched code, on the same count.
        counterSource.writeAsStringSync(counterOriginal);
        final counterReverted = await _reload(dt, appId);
        expect(
          counterReverted['succeeded'],
          isTrue,
          reason: '$counterReverted',
        );
        expect(counterReverted['nativeReverted'], ['libcounter.dylib']);
        await _expectBump(dt, appId, 'B', 34);

        // ---- 9: the advice, followed -----------------------------------------
        //
        // Steps 4 and 6 undo their edits; here they are kept and the advice
        // the reload gives is taken. Neither edit moves a bundled byte — a
        // declaration nothing defines, a comment — so the restart has no new
        // process to make, and the process it keeps is what a fresh launch of
        // this tree would be. The restart must go through, and the reload after
        // it must not withhold over the same edits again.
        mulHeader.writeAsStringSync(
          headerOriginal.replaceFirst(
            'FFI_EXAMPLE_EXPORT int32_t mul(int32_t a, int32_t b);',
            'FFI_EXAMPLE_EXPORT int32_t mul(int32_t a, int32_t b);\n'
                'FFI_EXAMPLE_EXPORT int32_t mul_twice(int32_t a);',
          ),
        );
        addSource.writeAsStringSync('$addOriginal// edited\n');
        final advised = await _reload(dt, appId);
        expect(advised['succeeded'], isFalse, reason: '$advised');
        expect('${advised['message']}', contains('restart (R'));
        final restarted = await _restart(dt, appId);
        expect(restarted['succeeded'], isTrue, reason: '$restarted');
        final settled = await _reload(dt, appId);
        expect(settled['succeeded'], isTrue, reason: '$settled');
        expect(settled.containsKey('nativeLibsStale'), isFalse);
        await _expectRendered(dt, appId, 'live 3 × 4 = 12');
        mulHeader.writeAsStringSync(headerOriginal);
        addSource.writeAsStringSync(addOriginal);
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

Future<Map<String, dynamic>> _restart(DevToolProcess dt, String appId) async {
  final response = await dt.httpCommand('app.restart', {'appId': appId});
  final result = response['result'] as Map<String, dynamic>?;
  expect(result, isNotNull, reason: 'app.restart: ${response['error']}');
  return result!;
}

/// Bump the shared counter through asset id [via] (`A` or `B`) and require the
/// bump to answer [count].
Future<void> _expectBump(
  DevToolProcess dt,
  String appId,
  String via,
  int count,
) async {
  final tap = await dt.httpCommand('app.tap', {
    'appId': appId,
    'key': 'bump$via',
  });
  expect(tap['error'], isNull, reason: 'app.tap bump$via: ${tap['error']}');
  final expected = 'bumped via $via: $count';
  final found = await dt.httpCommand('app.waitFor', {
    'appId': appId,
    'text': expected,
    'timeoutMs': '20000',
  });
  if (found['result'] == null) {
    final shown = await dt.httpCommand('app.getText', {
      'appId': appId,
      'key': 'lastBump',
    });
    fail('expected "$expected", the app shows ${shown['result'] ?? shown}');
  }
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
