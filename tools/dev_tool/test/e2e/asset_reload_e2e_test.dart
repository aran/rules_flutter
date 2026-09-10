@Tags(['e2e'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// End-to-end: editing an asset while the app runs changes what it shows.
///
/// The macos_example UI reads `assets/message.txt` on every build and renders
/// it in a keyed Text. Getting a new value on screen exercises the chain an
/// *explicit* reload drives: the tracker deciding a build is warranted, the
/// bazel rebuild of the `flutter_assets` tree,
/// `_flutter.setAssetBundlePath` re-rooting the engine at that tree, and
/// `ext.flutter.evict` dropping the framework's cached copy.
///
/// Not the filesystem watcher. Every case here launches `--machine` without
/// `--watch`, which leaves the watcher off, so each one issues `app.hotReload`
/// itself and the watcher's accept-this-path predicate is never even built.
/// Watch-driven asset delivery has no e2e anywhere; that predicate's parts are
/// unit-covered instead — `source_watcher_test.dart`'s 'a custom filter widens
/// what reaches the pipeline', and the `watches()` cases in
/// `asset_bundle_test.dart`.
///
/// The app must not restart along the way.
void main() {
  group('asset reload e2e', () {
    test(
      'an edited asset reaches the running app',
      () async {
        final ws = await editableWorkspace('macos_example');
        final asset = ws.file('assets/message.txt');
        final original = asset.readAsStringSync();
        expect(
          original.trim(),
          'asset v1',
          reason: 'fixture marker present in macos_example assets',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':app',
          device: 'macos',
        );
        final start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 240),
        );
        final appId = start['params']?['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 60));

        final ready = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'key': 'e2e_asset_label',
          'timeoutMs': '15000',
        });
        expect(
          ready['error'],
          isNull,
          reason: 'e2e_asset_label: ${ready['error']}',
        );

        var label = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_asset_label',
        });
        expect(
          label['result']?['text'],
          'asset v1',
          reason: 'the launched bundle must carry the asset',
        );

        // Edit the asset and reload. No Dart source changed, so everything that
        // happens next is the asset path doing its job.
        asset.writeAsStringSync('asset v2\n');
        final reload = await dt.sendCommand(
          1,
          'app.hotReload',
          params: {'appId': appId},
        );
        expect(
          reload['error'],
          isNull,
          reason: 'app.hotReload: ${reload['error']}',
        );
        expect(
          reload['result']?['assetsChanged'],
          1,
          reason:
              'the reload must report that it delivered assets, not '
              'silently report "no changes detected"',
        );
        expect(
          reload['result']?['message'],
          isNot(contains('no changes')),
          reason:
              'an asset-only edit IS a change; saying otherwise in the '
              'same line that reports the reload is a contradiction',
        );

        label = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_asset_label',
        });
        expect(
          label['result']?['text'],
          'asset v2',
          reason: 'the running app must show the edited asset',
        );

        // Still the same app: an asset reload that quietly restarted would lose
        // every bit of state the user had built up, which is the thing hot
        // reload exists to avoid.
        final define = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_define_label',
        });
        expect(
          define['error'],
          isNull,
          reason: 'the app must still be the one that was launched',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'an edited asset reaches the running browser app',
      () async {
        // Web delivers assets by a different route entirely: the module server
        // reads `assets/` off the build tree on every request, so the new bytes
        // are already on the wire and all that is left is convincing the page to
        // stop trusting its caches.
        final ws = await editableWorkspace('web_example');
        final asset = ws.file('assets/message.txt');
        final original = asset.readAsStringSync();
        expect(
          original.trim(),
          'web asset v1',
          reason: 'fixture marker present in web_example assets',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          // The `flutter_web_app` target, not `:app_js`: that one carries a
          // `base_href` the dev server does not serve from, so the page comes up
          // blank and DWDS never attaches.
          target: ':app_wasm',
          device: 'chrome',
        );
        final start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 240),
        );
        final appId = start['params']?['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 120));
        // `app.started` fires when Chrome launches; the page only reaches DWDS
        // later, and nothing below can be asked before it does.
        await dt.waitForStderr(
          'dwds_vm_service',
          timeout: const Duration(seconds: 120),
        );
        final moduleServer = Uri.parse(
          json.decode(await dt.waitForStderr('frontend_server_ready'))['uri']
              as String,
        );

        /// The asset as the page would fetch it. Flutter web keys assets under
        /// `assets/`, and the bundle's own key is `assets/message.txt`, so the
        /// request path doubles up.
        Future<String> served() async {
          final client = HttpClient();
          try {
            final response = await (await client.getUrl(
              moduleServer.resolve('assets/assets/message.txt'),
            )).close();
            return (await utf8.decoder.bind(response).join()).trim();
          } finally {
            client.close();
          }
        }

        expect(await served(), 'web asset v1');

        asset.writeAsStringSync('web asset v2\n');
        final reload = await dt.sendCommand(
          1,
          'app.hotReload',
          params: {'appId': appId},
        );
        expect(
          reload['error'],
          isNull,
          reason: 'app.hotReload: ${reload['error']}',
        );
        expect(
          reload['result']?['assetsChanged'],
          1,
          reason: 'the reload must notice the edit and rebuild the bundle',
        );
        expect(
          reload['result']?['assetsProblem'],
          isNull,
          reason:
              'the page must have taken the eviction: '
              '${reload['result']?['assetsProblem']}',
        );

        // The rebuilt bundle is what the server now hands out — the delivery
        // half, which on web is the whole transport.
        expect(await served(), 'web asset v2');

        // And the render half: what the page is actually showing, read out of its
        // widget tree. A CDP screenshot diff cannot stand in for this: two CDP
        // captures of this web canvas are never byte-identical, so such a check
        // passes even with delivery disabled entirely. Reading the label is the
        // difference between "the bytes were served" and "the app took them".
        final label = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_asset_label',
        });
        expect(
          label['error'],
          isNull,
          reason: 'app.getText after the asset reload: ${label['error']}',
        );
        expect(
          label['result']?['text'],
          'web asset v2',
          reason:
              'the page must be showing the edited asset, not the '
              'bytes it started with',
        );
      },
      timeout: const Timeout(Duration(minutes: 6)),
    );

    /// The same edit, on the platform where the tracked tree can diverge from
    /// the one the app actually runs.
    ///
    /// `flutter_ios_application` reaches the `flutter_application` through a
    /// rules_apple split transition, so the running app's `flutter_assets`
    /// tree lives in a configuration — `…-ST-<hash>` — that no command line
    /// can name. Tracking the tool's own bare build of the application instead
    /// lands in the host configuration, and everything then reports success:
    /// the rebuild writes a real tree, the tracker diffs a real tree, they are
    /// different trees, and the edit never leaves the machine.
    ///
    /// macOS cannot catch this. Its wrapper transitions too, but only over
    /// Apple bundling flags, so both trees hold identical bytes and watching
    /// the wrong one is invisible. iOS is where the contents actually differ.
    test(
      'an edited asset reaches a running iOS simulator app',
      () async {
        final ws = await editableWorkspace('ios_example');
        final asset = ws.file('assets/message.txt');
        final original = asset.readAsStringSync();
        expect(
          original.trim(),
          'asset v1',
          reason: 'fixture marker present in ios_example assets',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':app',
          device: 'ios-simulator',
        );
        final start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(seconds: 300),
        );
        final appId = start['params']?['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 60));

        final ready = await dt.httpCommand('app.waitFor', {
          'appId': appId,
          'key': 'e2e_asset_label',
          'timeoutMs': '30000',
        });
        expect(
          ready['error'],
          isNull,
          reason: 'e2e_asset_label: ${ready['error']}',
        );

        var label = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_asset_label',
        });
        expect(
          label['result']?['text'],
          'asset v1',
          reason: 'the installed bundle must carry the asset',
        );

        asset.writeAsStringSync('asset v2\n');
        final reload = await dt.sendCommand(
          1,
          'app.hotReload',
          params: {'appId': appId},
        );
        expect(
          reload['error'],
          isNull,
          reason: 'app.hotReload: ${reload['error']}',
        );
        // Under a tree mismatch the rebuild still succeeds and the reload still
        // returns cleanly — it just reports nothing changed, because the
        // directory it diffed is not the one the rebuild wrote.
        expect(
          reload['result']?['assetsChanged'],
          1,
          reason: 'the reload must report it delivered the edited asset',
        );

        label = await dt.httpCommand('app.getText', {
          'appId': appId,
          'key': 'e2e_asset_label',
        });
        expect(
          label['result']?['text'],
          'asset v2',
          reason: 'the simulator app must be showing the edited asset',
        );
      },
      timeout: const Timeout(Duration(minutes: 8)),
      skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
    );
  });
}
