@Tags(['e2e'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('multi_window_example');

  group('multi_window macOS e2e', () {
    test(
      'native screenshot composites both planner windows by default',
      () async {
        final dt = await startDevTool(
          workspace: workspace,
          target: ':app_macos',
          device: 'macos',
        );

        await dt.waitForEvent('app.started');
        expect(await dt.waitForHttpControl(), isNotNull);

        // Both NSWindows take a beat to be on screen after launch, and no event
        // reports when they are — so the endpoint itself is the condition,
        // polled rather than slept past.
        final composite = await dt.nativeScreenshotWhenOnScreen(dt.appId!);
        expect(composite.length, greaterThan(0));
        expect(composite.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

        await dt.sendCommand(1, 'daemon.shutdown');
      },
    );

    test('?window= selects a single planner window by exact title', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_macos',
        device: 'macos',
      );

      await dt.waitForEvent('app.started');
      expect(await dt.waitForHttpControl(), isNotNull);
      // Each window is its own barrier: polling per title waits out exactly
      // the window that answer needs, and the bytes the poll returns are the
      // ones asserted on.
      final tasks = await dt.nativeScreenshotWhenOnScreen(
        dt.appId!,
        window: 'Planner — Tasks',
      );
      final calendar = await dt.nativeScreenshotWhenOnScreen(
        dt.appId!,
        window: 'Planner — Calendar',
      );

      expect(tasks.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(calendar.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

      // Distinct windows must produce distinct bitmaps. Same window pair
      // would otherwise pass the PNG-header check trivially.
      expect(
        tasks,
        isNot(equals(calendar)),
        reason: 'Tasks and Calendar windows should yield different PNGs',
      );

      await dt.sendCommand(1, 'daemon.shutdown');
    });

    test(
      '?window= with unknown title returns a 500 with available titles',
      () async {
        final dt = await startDevTool(
          workspace: workspace,
          target: ':app_macos',
          device: 'macos',
        );

        await dt.waitForEvent('app.started');
        expect(await dt.waitForHttpControl(), isNotNull);
        // The barrier and the assertion cannot be the same call here: this test
        // wants the 500 an unknown title earns, so polling until success would
        // never return. Poll the composite instead — once that answers, the
        // app's windows are on screen and enumerable, which is the only reason
        // a `NoSuchWindow` 500 could otherwise have been premature.
        await dt.nativeScreenshotWhenOnScreen(dt.appId!);

        Object? caught;
        try {
          await dt.httpNativeScreenshot(
            dt.appId!,
            window: 'NoSuchWindow',
          );
        } catch (e) {
          caught = e;
        }
        expect(caught, isA<StateError>());
        expect(
          caught.toString(),
          contains('No window titled'),
          reason: 'error should name the missing title',
        );

        await dt.sendCommand(1, 'daemon.shutdown');
      },
    );
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}
