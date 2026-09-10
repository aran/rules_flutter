@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// A browser refresh after a hot reload, from the user's side.
///
/// The one navigation the tool never performs: on the DDC path it launches the
/// page once and then only ever swaps code inside it, so every later
/// navigation is the user's — a reflexive F5, a DevTools reload, recovering
/// from a crash, a second tab on the printed URL.
///
/// What makes that fragile: DWDS re-reads the merged metadata on EVERY
/// bootstrap request and embeds the module list it derives into the page, and
/// the DDC loader then loads exactly that list. A server that REPLACES that
/// artifact on each compile while merging the module bytes beside it leaves a
/// refreshed page loading one module of several hundred — the app is gone, a
/// second refresh does not recover it, and `app.restart` answers "Restart
/// successful" over the blank page.
///
/// Nothing else in the suite navigates the page after a reload. The unit test
/// in `web_module_server_test.dart` pins the mechanism; this pins what a person
/// sees.
void main() {
  group('web refresh after reload', () {
    test(
      'the app survives a browser refresh that follows a hot reload',
      () async {
        final ws = await editableWorkspace('web_example');
        final appMain = ws.file('lib/main.dart');
        final original = appMain.readAsStringSync();
        const anchor =
            "const Text('You have pushed the button this many times:')";
        expect(
          original.contains(anchor),
          isTrue,
          reason: 'fixture marker present in web_example lib/main.dart',
        );
        expect(
          original.contains('REFRESH_'),
          isFalse,
          reason:
              'web_example lib/main.dart still carries an edit from an '
              'earlier run; restore it before running this test',
        );

        // Dictated rather than discovered: the refresh below is driven over
        // CDP, and the port has to be known before Chrome launches.
        final probeSocket = await ServerSocket.bind('127.0.0.1', 0);
        final cdpPort = probeSocket.port;
        await probeSocket.close();

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':app_wasm',
          device: 'chrome',
          watch: false,
          extraArgs: [
            '--web-run-headless',
            '--web-browser-debug-port=$cdpPort',
          ],
        );
        await dt.waitForStderr(
          'dwds_vm_service',
          timeout: const Duration(minutes: 5),
        );
        await dt.waitForHttpControl(timeout: const Duration(minutes: 2));
        final appId = dt.appId!;

        Uri? serverUri;
        for (final line in dt.stderrLines) {
          if (!line.contains('frontend_server_ready')) continue;
          final m = RegExp(r'"uri":"(http[^"]+)"').firstMatch(line);
          if (m != null) serverUri = Uri.parse(m.group(1)!);
        }
        expect(
          serverUri,
          isNotNull,
          reason: 'the run has to say where it is serving from',
        );

        Future<void> mustSee(String label, String text) async {
          final found = await dt.httpCommand('app.waitFor', {
            'appId': appId,
            'text': text,
            'timeoutMs': '25000',
          });
          expect(
            found['error'],
            isNull,
            reason: '$label: the page must be showing "$text"',
          );
        }

        await mustSee(
          'baseline',
          'You have pushed the button this many times:',
        );

        final edited = original.replaceFirst(
          anchor,
          "const Text('REFRESH_SURVIVES')",
        );
        if (edited == original) {
          fail(
            'the edit anchor matched nothing in ${appMain.path}, so this run '
            'would assert against an unchanged file: $anchor',
          );
        }
        appMain.writeAsStringSync(edited);

        final reload = await dt.sendCommand(
          1,
          'app.hotReload',
          timeout: const Duration(minutes: 3),
        );
        expect(
          reload['result']?['succeeded'],
          isTrue,
          reason: 'the reload has to work before its aftermath means anything',
        );
        await mustSee('after reload', 'REFRESH_SURVIVES');

        // The user presses F5.
        final cursor = dt.events.length;
        await _refreshPage(cdpPort, serverUri!.port);
        await dt.waitForEventWhere(
          'app.debugPort',
          after: cursor,
          what: 'the refreshed page reconnecting',
          timeout: const Duration(minutes: 2),
          test: (_) => true,
        );

        // THE assertion. Reconnecting is not enough: every tool-side signal
        // stays green while the page loads a fraction of the program, so only
        // the rendered widget settles it.
        await mustSee('after refresh', 'REFRESH_SURVIVES');

        await dt.sendCommand(9, 'daemon.shutdown');
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });
}

/// Reload the app's page through Chrome DevTools Protocol — a real browser
/// navigation, which is the thing under test.
Future<void> _refreshPage(int cdpPort, int serverPort) async {
  final http = HttpClient();
  final List targets;
  try {
    final request = await http.getUrl(
      Uri.parse('http://127.0.0.1:$cdpPort/json'),
    );
    final response = await request.close();
    targets = jsonDecode(await response.transform(utf8.decoder).join()) as List;
  } finally {
    http.close();
  }
  final page = targets.cast<Map<String, dynamic>>().firstWhere(
    (t) => t['type'] == 'page' && '${t['url']}'.contains(':$serverPort'),
    orElse: () => throw StateError(
      'no page target on :$serverPort among $targets',
    ),
  );
  final ws = await WebSocket.connect(page['webSocketDebuggerUrl'] as String);
  try {
    final answered = ws.firstWhere(
      (m) => (jsonDecode(m as String) as Map<String, dynamic>)['id'] == 1,
    );
    ws.add(
      jsonEncode({
        'id': 1,
        'method': 'Page.reload',
        'params': {'ignoreCache': true},
      }),
    );
    await answered.timeout(const Duration(seconds: 30));
  } finally {
    await ws.close();
  }
}
