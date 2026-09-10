@Tags(['e2e'])
library;

import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'dev_tool_e2e_harness.dart';

/// End-to-end: `--start-paused` really holds the app at `main()`.
///
/// The switch travels a different way on every platform — an environment
/// variable on desktop, an intent extra on Android, trailing argv on iOS — so
/// unit tests can only prove the argument was formed. Whether the engine acted
/// on it is a question about a running app, and the answer is the main
/// isolate's own `pauseEvent`.
///
/// The second half matters as much as the first: an app that pauses and can
/// never be resumed is a hang, not a debugging aid.
void main() {
  group('start-paused e2e', () {
    test(
      'holds main() until a debugger resumes it',
      () async {
        final dt = await startDevTool(
          workspace: e2eWorkspace('macos_example'),
          target: ':app',
          device: 'macos',
          extraArgs: ['--start-paused'],
        );

        final start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 240),
        );
        final appId = start['params']?['appId'] as String? ?? dt.appId!;
        final debugPort = await dt.waitForEvent(
          'app.debugPort',
          timeout: const Duration(seconds: 120),
        );
        final wsUri = debugPort['params']?['wsUri'] as String;

        // The tool says it observed the pause rather than assuming the switch
        // took — this is that observation, made independently.
        await dt.waitForStderr(
          'start_paused',
          timeout: const Duration(seconds: 60),
        );

        final service = await vmServiceConnectUri(wsUri);
        addTearDown(service.dispose);
        final vm = await service.getVM();
        final main = vm.isolates!.firstWhere((i) => i.name == 'main');
        final isolate = await service.getIsolate(main.id!);
        expect(
          isolate.pauseEvent?.kind,
          EventKind.kPauseStart,
          reason: 'the engine must be holding the root isolate before main()',
        );

        // Nothing that needs the framework can work yet — the binding has not
        // run, so the agent's extensions are not registered. It has to *answer*,
        // though: the extension runs on the isolate that is paused, so
        // dispatching it would block the control channel for the rest of the
        // run.
        await dt.waitForHttpControl(timeout: const Duration(seconds: 60));
        final tooEarly = await dt
            .httpCommand('app.getText', {
              'appId': appId,
              'key': 'e2e_define_label',
            })
            .timeout(
              const Duration(seconds: 20),
              onTimeout: () => throw StateError(
                'app.getText never answered on a paused app — the control '
                'channel is wedged behind an isolate that cannot run',
              ),
            );
        expect(
          tooEarly['error'],
          contains('--start-paused'),
          reason:
              'a paused app has no widget tree to read, and the reason '
              'must name the pause rather than the widget',
        );

        // Resume, exactly as a debugger would, and the app comes up.
        await service.resume(main.id!);

        final ready = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'key': 'e2e_define_label',
          'timeoutMs': '30000',
        });
        expect(
          ready['error'],
          isNull,
          reason:
              'resuming must let the app run to a rendered frame: '
              '${ready['error']}',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'holds the browser app until a debugger resumes it',
      () async {
        // There is no engine switch to pass a browser. DWDS is what gates
        // `main()`, so pausing means withholding the run request — a different
        // mechanism reaching the same observable.
        final dt = await startDevTool(
          workspace: e2eWorkspace('web_example'),
          // The `flutter_web_app` target, not `:app_js`: that one is a
          // `flutter_web_bundle` with `base_href = "/web_example_js/"` while the
          // dev server serves at `/`, so the page comes up blank and DWDS never
          // attaches — nothing to pause.
          target: ':app_wasm',
          device: 'chrome',
          extraArgs: ['--start-paused'],
        );

        await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 240),
        );
        final debugPort = await dt.waitForEvent(
          'app.debugPort',
          timeout: const Duration(seconds: 180),
        );
        await dt.waitForStderr(
          'start_paused',
          timeout: const Duration(seconds: 60),
        );

        final service = await vmServiceConnectUri(
          debugPort['params']!['wsUri'] as String,
        );
        addTearDown(service.dispose);
        final vm = await service.getVM();
        final isolate = vm.isolates!.first;

        // The widget inspector answers only once the framework is up, which
        // only happens once `main()` has run — a check that goes through the
        // tool's own control channel rather than guessing at what DWDS reports.
        Future<bool> frameworkIsUp() async {
          final tree = await dt.httpCommand('app.dumpWidgetTree', {
            'appId': dt.appId!,
          });
          return tree['error'] == null;
        }

        await dt.waitForHttpControl(timeout: const Duration(seconds: 60));
        expect(
          await frameworkIsUp(),
          isFalse,
          reason: 'main() must not have run before a debugger resumed it',
        );

        // DWDS runs `main()` when a client resumes an app that has not started,
        // so this is exactly what pressing resume in a debugger does.
        await service.resume(isolate.id!);

        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (!await frameworkIsUp()) {
          expect(
            DateTime.now().isBefore(deadline),
            isTrue,
            reason: 'resuming must release main(); the app never started',
          );
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );
  });
}
