@Tags(['e2e', 'macos'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dtd/dtd.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The app under test.
const _app = E2eApp('macos_example');

/// A run is found through the Dart Tooling Daemon the way `flutter run` is.
///
/// The Dart MCP server finds DTDs with `dart tooling-daemon --list`, reads the
/// apps from each one's `ConnectedApp` service, and hot reloads by calling the
/// `reloadSources` service registered on the VM service DTD hands out. Each of
/// those steps is taken here as that client takes it, and the reload is
/// checked on screen: an unregistered or raw `reloadSources` answers success
/// without compiling the edit, so only the app's own text tells them apart.
void main() {
  test(
    'DTD lists the app, and a reload through its VM service shows the edit',
    () async {
      final ws = await editableWorkspace(_app);
      final appMain = ws.file('lib/main.dart');
      final original = appMain.readAsStringSync();
      expect(original, contains(" v1'"), reason: 'fixture marker present');

      final dt = await startDevTool(
        workspace: ws.root,
        target: ':app',
        device: 'macos',
      );
      final dtdEvent = await dt.waitForEvent(
        'app.dtd',
        timeout: const Duration(seconds: 240),
      );
      final appId = dtdEvent['params']!['appId'] as String;
      final dtdUri = Uri.parse(dtdEvent['params']!['uri'] as String);
      await dt.waitForEvent('app.started');
      await dt.waitForHttpControl(timeout: const Duration(seconds: 60));

      // How the MCP server finds it with no URI given.
      final listed = await Process.run(Platform.resolvedExecutable, [
        'tooling-daemon',
        '--list',
        '--machine',
      ]);
      expect(listed.exitCode, 0, reason: '${listed.stderr}');
      final instances = (jsonDecode(listed.stdout as String) as List)
          .cast<Map<String, dynamic>>();
      expect(
        instances.map((i) => i['wsUri']),
        contains(dtdUri.toString()),
        reason: '`dart tooling-daemon --list` must list the run\'s DTD',
      );

      final dtd = await DartToolingDaemon.connect(dtdUri);
      addTearDown(dtd.close);
      final apps = (await dtd.getVmServices()).vmServicesInfos;
      expect(apps, hasLength(1));
      expect(
        apps.single.name,
        allOf(
          startsWith('Kind: Flutter - Device: macOS - Package: '),
          endsWith(':app'),
        ),
      );

      final ready = await dt.httpCommand('app.waitFor', {
        'appId': appId,
        'key': 'e2e_define_label',
        'timeoutMs': '15000',
      });
      expect(ready['error'], isNull, reason: '${ready['error']}');

      // The MCP server's `hot_reload`: the `reloadSources` some client
      // registered, called on the first isolate.
      final vm = await vmServiceConnectUri(apps.single.uri);
      addTearDown(vm.dispose);
      final registered = vm.onServiceEvent
          .where(
            (e) =>
                e.kind == EventKind.kServiceRegistered &&
                e.service == 'reloadSources',
          )
          .first;
      await vm.streamListen(EventStreams.kService);
      final method = (await registered.timeout(
        const Duration(seconds: 10),
      )).method!;

      final cursor = dt.events.length;
      appMain.writeAsStringSync(original.replaceFirst(" v1'", " v2'"));
      final isolate = (await vm.getVM()).isolates!.first.id!;
      final reply = await vm.callMethod(method, isolateId: isolate);
      expect(reply.json?['type'], 'Success', reason: '${reply.json}');

      // The rest of the run is told too.
      final announced = await dt.waitForEventWhere(
        'app.reloadResult',
        after: cursor,
        what: 'the reload a VM service client asked for',
        timeout: const Duration(seconds: 60),
        test: (_) => true,
      );
      expect(
        (announced['params']!['result'] as Map)['succeeded'],
        isTrue,
        reason: '${announced['params']}',
      );

      final label = await dt.httpCommand('app.getText', {
        'appId': appId,
        'key': 'e2e_define_label',
      });
      expect(
        label['result']?['text'],
        endsWith(' v2'),
        reason: 'the reload must compile and apply the edit: $label',
      );

      await dt.sendCommand(1, 'daemon.shutdown');
      final code = await dt.exitCodeWithin(
        const Duration(seconds: 30),
        stillRunning: 'daemon.shutdown was answered but the tool did not exit',
      );
      expect(code, 0);

      // The run's DTD goes with it.
      final after = await Process.run(Platform.resolvedExecutable, [
        'tooling-daemon',
        '--list',
        '--machine',
      ]);
      expect(
        (jsonDecode(after.stdout as String) as List).map(
          (i) => (i as Map)['wsUri'],
        ),
        isNot(contains(dtdUri.toString())),
      );
    },
    timeout: const Timeout(Duration(minutes: 6)),
    skip: !Platform.isMacOS ? 'macOS only' : null,
  );
}
