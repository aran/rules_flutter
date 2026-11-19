import 'dart:js_interop';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:web/web.dart' as web;
import 'package:web_example/main.dart' as app;

/// The render check of docs/TESTING.md § 5, run in headless Chrome by
/// `:render_test`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app draws its screen from the framework', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    // Text read back out of the widget tree: the engine booted, the framework
    // built the tree, and what it built is the app's.
    expect(
      find.text('You have pushed the button this many times:'),
      findsOneWidget,
    );
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('the app resolved its asset bundle', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    // `FutureBuilder` over `assets/message.txt`: a bundle that boots and paints
    // but cannot resolve its assets shows an empty label here, and so does an
    // asset the build left out.
    final label = tester.widget<Text>(
      find.byKey(const ValueKey('e2e_asset_label')),
    );
    expect(label.data, 'web asset v1');
  });

  testWidgets('the build described the app and the SDK to the program', (
    tester,
  ) async {
    // Compile-time defines `flutter build web` adds: the app's version, which
    // is `flutter create`'s here (this target sets none), and the Flutter
    // release that compiled it. Null means the build left them out.
    expect(appBuildName, '1.0.0');
    expect(appBuildNumber, '1');
    expect(FlutterVersion.version, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(FlutterVersion.channel, 'stable');
    expect(FlutterVersion.gitUrl, 'https://github.com/flutter/flutter.git');
    expect(
      FlutterVersion.frameworkRevision,
      matches(RegExp(r'^[0-9a-f]{10}$')),
    );
    expect(FlutterVersion.engineRevision, matches(RegExp(r'^[0-9a-f]{10}$')));
    expect(FlutterVersion.dartVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

  testWidgets('the renderer came from the app, not the CDN', (tester) async {
    // A test that loads the renderer from www.gstatic.com fails whenever the
    // CDN is out of reach, so the test bundle serves its own. The browser's
    // own record of what it fetched says where the renderer came from.
    final entries = web.window.performance.getEntriesByType('resource').toDart;
    final renderer =
        [
          for (final entry in entries) Uri.parse(entry.name),
        ].where(
          (uri) => uri.pathSegments.lastOrNull?.startsWith('skwasm') ?? false,
        );
    expect(renderer, isNotEmpty, reason: 'the page fetched no renderer');
    for (final uri in renderer) {
      expect(uri.origin, Uri.base.origin, reason: '$uri');
    }
  });

  testWidgets('a tap reaches the app', (tester) async {
    app.main();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Increment'));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
  });
}
