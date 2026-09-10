@Tags(['e2e'])
/// The CI web smoke test: one `-c dbg` Chrome run, driven through the shipped
/// binary, asserted down to a VM service that answers.
///
/// Deliberately narrow and deliberately separate from `web_e2e_test.dart`,
/// which pays several multi-minute web compiles for its negative controls and
/// adds screenshot flake on top. This is the one web run CI can afford, and
/// `web_example` is in no Bazel e2e matrix, so it is also the only web
/// coverage CI has at all — and the only place CI exercises the binary users
/// install.
///
/// It has no Bazel target on purpose: like every file under `test/e2e/`, it is
/// tagged `e2e`, needs a browser, and is run by `dart test --tags=e2e`. The
/// rule in `tools/dev_tool/BUILD.bazel` about a file without a target going
/// unrun is about the unit tests under `test/`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

void main() {
  test(
    'a Chrome run comes up with a VM service that answers',
    () async {
      final dt = await startDevTool(
        workspace: e2eWorkspace('web_example'),
        // The WASM target's default `--hot` run is the DDC/DWDS dev loop, which
        // is what owns the VM service this asserts on.
        target: ':app_wasm',
        device: 'chrome',
      );

      await dt.waitForEvent('app.started', timeout: const Duration(minutes: 6));

      // `app.started` alone is not health: a web run can report it with no
      // DWDS, no VM service, no hot reload and no console, looking fine and
      // impossible to debug — `web_e2e_test.dart` has a whole group about that
      // failure. The event that says where the VM service *is* is the one
      // worth waiting for.
      final debugPort = await dt.waitForEvent(
        'app.debugPort',
        timeout: const Duration(minutes: 2),
      );
      final wsUri = debugPort['params']?['wsUri'] as String?;
      expect(wsUri, isNotNull, reason: 'app.debugPort carried no wsUri');

      // And then the socket has to actually answer the VM service protocol.
      // Connecting proves DWDS's DDS is listening; `getVersion` proves what is
      // listening is a VM service and not merely an open port.
      final socket = await WebSocket.connect(
        wsUri!,
      ).timeout(const Duration(seconds: 30));
      try {
        socket.add(
          json.encode({
            'jsonrpc': '2.0',
            'id': '1',
            'method': 'getVersion',
          }),
        );
        final reply =
            json.decode(
                  await socket.first.timeout(const Duration(seconds: 30))
                      as String,
                )
                as Map<String, dynamic>;
        expect(reply['error'], isNull, reason: 'getVersion failed: $reply');
        expect(
          reply['result']?['major'],
          isA<int>(),
          reason: 'not a VM service response: $reply',
        );
      } finally {
        await socket.close();
      }

      // A live VM service proves the Dart isolate runs. It does not prove the
      // engine ever painted: the failure this guards is a bundle that boots,
      // answers the protocol, and renders a blank page. Reading text back out
      // of a keyed widget is what separates the two — `e2e_asset_label` only
      // holds this string once the framework has built the tree *and* resolved
      // the asset bundle behind it, so an answer here is the render.
      //
      // This rides the existing run rather than taking a file of its own. The
      // web compile above is the expensive part and this adds two round trips
      // to it; a second web run to assert one string would roughly double the
      // only web coverage CI has, for nothing.
      final appId = dt.appId;
      expect(appId, isNotNull, reason: 'appId from app.start event');

      final ready = await dt.httpCommand('app.waitFor', {
        'appId': appId!,
        'key': 'e2e_asset_label',
        'timeoutMs': '30000',
      });
      expect(
        ready['error'],
        isNull,
        reason: 'e2e_asset_label never appeared — the page did not render',
      );

      final label = await dt.httpCommand('app.getText', {
        'appId': appId,
        'key': 'e2e_asset_label',
      });
      expect(label['error'], isNull, reason: 'getText failed: $label');
      expect(
        label['result']?['text'],
        'web asset v1',
        reason: 'rendered text is not the asset bundle contents: $label',
      );

      await dt.sendCommand(1, 'daemon.shutdown');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
