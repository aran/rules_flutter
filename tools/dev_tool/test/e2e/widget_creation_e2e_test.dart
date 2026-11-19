@Tags(['e2e', 'macos'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart' as vm_io;

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The app under test.
const _app = E2eApp('macos_example');

/// A debug app tells the widget inspector where each widget was created, and
/// still does after the libraries it edits are recompiled by the dev tool.
///
/// The build compiles with `--track-widget-creation` and reports so in its
/// `rules_flutter.build_info`; the dev tool's resident frontend_server has to
/// pass the same flag, or a hot reload or restart swaps in a library whose
/// widgets carry no creation location. What is read is the widget tree off the
/// running app (`ext.flutter.inspector.getRootWidgetTree`, the call DevTools
/// makes), looking for the `Text` the edit changed.
void main() {
  group('widget creation tracking in the dev loop', () {
    test(
      'survives a hot reload and a hot restart',
      () async {
        final ws = await editableWorkspace(_app);
        final appMain = ws.file('lib/main.dart');
        final original = appMain.readAsStringSync();
        expect(
          original,
          contains(" v1'"),
          reason: 'fixture marker present in macos_example main.dart',
        );

        final dt = await startDevTool(
          workspace: ws.root,
          target: ':app',
          device: 'macos',
        );
        final start = await dt.waitForEvent(
          'app.start',
          timeout: const Duration(minutes: 4),
        );
        final appId = start['params']?['appId'] as String? ?? dt.appId!;
        await dt.waitForHttpControl(timeout: const Duration(seconds: 90));
        final wsUri =
            (await dt.waitForEvent('app.debugPort'))['params']['wsUri']
                as String;
        final service = await vm_io.vmServiceConnectUri(wsUri);
        addTearDown(service.dispose);

        await _awaitText(dt, appId, 'v1');
        expect(
          await _creationFile(service, 'v1'),
          endsWith('main.dart'),
          reason: 'the launch build records where its widgets were created',
        );

        appMain.writeAsStringSync(original.replaceFirst(" v1'", " v2'"));
        final reload = await dt.sendCommand(
          1,
          'app.hotReload',
          params: {'appId': appId},
          timeout: const Duration(minutes: 4),
        );
        expect(reload['error'], isNull, reason: 'app.hotReload: $reload');
        await _awaitText(dt, appId, 'v2');
        expect(
          await _creationFile(service, 'v2'),
          endsWith('main.dart'),
          reason:
              'a library the dev tool recompiled on hot reload keeps its '
              'widgets\' creation locations',
        );

        appMain.writeAsStringSync(original.replaceFirst(" v1'", " v3'"));
        final restart = await dt.sendCommand(
          2,
          'app.restart',
          params: {'appId': appId, 'fullRestart': true},
          timeout: const Duration(minutes: 4),
        );
        expect(restart['error'], isNull, reason: 'app.restart: $restart');
        await _awaitText(dt, appId, 'v3');
        expect(
          await _creationFile(service, 'v3'),
          endsWith('main.dart'),
          reason:
              'and so does the kernel a hot restart compiles, which the '
              'launch build does not produce',
        );
      },
      timeout: const Timeout(Duration(minutes: 8)),
      skip: !Platform.isMacOS ? 'macOS only' : null,
    );
  });
}

/// Waits for the `e2e_define_label` text to end in [suffix], by the agent
/// surface rather than a sleep.
Future<void> _awaitText(DevToolProcess dt, String appId, String suffix) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  Object? last;
  while (DateTime.now().isBefore(deadline)) {
    final reply = await dt.httpCommand('app.getText', {
      'appId': appId,
      'key': 'e2e_define_label',
    });
    last = reply;
    final text = reply['result']?['text'] as String?;
    if (text != null && text.endsWith(suffix)) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  fail('the label never ended in "$suffix"; last answer: $last');
}

/// The file of the creation location the running app records for the `Text`
/// keyed `e2e_define_label`, failing when it records none. [label] only names
/// the build in a failure message.
Future<String> _creationFile(vm.VmService service, String label) async {
  const key = 'e2e_define_label';
  final isolates = (await service.getVM()).isolates ?? const <vm.IsolateRef>[];
  final isolate = isolates.firstWhere(
    (i) => i.name == 'main',
    orElse: () => isolates.first,
  );
  final response = await service.callServiceExtension(
    'ext.flutter.inspector.getRootWidgetTree',
    isolateId: isolate.id,
    args: {
      'groupName': 'widget_creation_e2e',
      'isSummaryTree': 'false',
      'withPreviews': 'false',
      'fullDetails': 'true',
    },
  );
  final tree = response.json?['result'];
  final node = _find(
    tree,
    (n) =>
        n['widgetRuntimeType'] == 'Text' &&
        (n['description'] as String? ?? '').contains(key),
  );
  expect(
    node,
    isNotNull,
    reason: 'no Text keyed $key for the "$label" build in ${jsonEncode(tree)}',
  );
  final location = node!['creationLocation'];
  expect(
    location,
    isA<Map<String, dynamic>>(),
    reason: 'the Text has no creation location: ${jsonEncode(node)}',
  );
  return (location as Map<String, dynamic>)['file'] as String;
}

Map<String, dynamic>? _find(
  Object? node,
  bool Function(Map<String, dynamic>) test,
) {
  if (node is! Map<String, dynamic>) return null;
  if (test(node)) return node;
  final children = node['children'];
  if (children is List) {
    for (final child in children) {
      final found = _find(child, test);
      if (found != null) return found;
    }
  }
  return null;
}
