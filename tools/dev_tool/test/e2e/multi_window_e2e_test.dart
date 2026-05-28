@Tags(['e2e'])
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  final workspace = e2eWorkspace('multi_window_example');

  group('multi_window macOS e2e', () {
    test('native screenshot composites both planner windows by default',
        () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_macos',
        device: 'macos',
        useBazelBuiltBinary: true,
      );

      try {
        await dt.waitForEvent('app.started');
        expect(await dt.waitForHttpControl(), isNotNull);

        // Both NSWindows take a beat to be on screen after launch.
        await Future<void>.delayed(const Duration(seconds: 4));

        final composite = await dt.httpNativeScreenshot(dt.appId!);
        expect(composite.length, greaterThan(0));
        expect(composite.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });

    test('?window= selects a single planner window by exact title', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_macos',
        device: 'macos',
        useBazelBuiltBinary: true,
      );

      try {
        await dt.waitForEvent('app.started');
        expect(await dt.waitForHttpControl(), isNotNull);
        await Future<void>.delayed(const Duration(seconds: 4));

        final tasks = await dt.httpNativeScreenshot(
          dt.appId!,
          window: 'Planner — Tasks',
        );
        final calendar = await dt.httpNativeScreenshot(
          dt.appId!,
          window: 'Planner — Calendar',
        );

        expect(tasks.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        expect(calendar.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

        // Distinct windows must produce distinct bitmaps. Same window pair
        // would otherwise pass the PNG-header check trivially.
        expect(tasks, isNot(equals(calendar)),
            reason: 'Tasks and Calendar windows should yield different PNGs');

        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });

    test('?window= with unknown title returns a 500 with available titles',
        () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_macos',
        device: 'macos',
        useBazelBuiltBinary: true,
      );

      try {
        await dt.waitForEvent('app.started');
        expect(await dt.waitForHttpControl(), isNotNull);
        await Future<void>.delayed(const Duration(seconds: 4));

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

        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });
  }, skip: !Platform.isMacOS ? 'macOS only' : null);
}
