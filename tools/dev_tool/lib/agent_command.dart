/// AI-agent command surface registered on [CommandRunner].
///
/// Exposes `app.*` for an external agent (e.g. Claude Code) to drive a
/// running Flutter app over the dev_tool's HTTP control channel. Most
/// commands proxy to `ext.rules_flutter.*` service extensions registered by
/// the generated plugin registrant the engine invokes before main() (see
/// `flutter/private/agent_extensions/agent.dart`). `app.dumpWidgetTree`
/// goes to the built-in inspector RPC and works against any debug Flutter
/// app without app-side cooperation.
library;

import 'command_runner.dart';
import 'session.dart';

/// Register the `app.*` AI-agent commands on [cr].
void setUpAgentCommands(
  CommandRunner cr,
  DeviceSession? Function(String? appId) findSession,
) {
  cr.register('app.dumpWidgetTree', (params) => _call(
        findSession,
        params,
        'ext.flutter.inspector.getRootWidgetTree',
        extraArgs: const {
          'groupName': 'rules_flutter_agent',
          'isSummaryTree': 'false',
          'withPreviews': 'true',
        },
      ));
  for (final method in const [
    'app.tap',
    'app.longPress',
    'app.doubleTap',
    'app.drag',
    'app.scrollIntoView',
    'app.enterText',
    'app.getText',
    'app.getRect',
    'app.waitFor',
    'app.waitForAbsent',
    'app.pageBack',
  ]) {
    final extensionMethod = 'ext.rules_flutter.${method.substring('app.'.length)}';
    cr.register(method, (params) => _call(findSession, params, extensionMethod));
  }
}

/// Resolve the session, invoke [extensionMethod], strip framework noise
/// from the response, and return the agent payload. The extension itself
/// validates required params; callers pass everything-but-`appId` through
/// untouched (plus any [extraArgs] for inspector RPCs).
Future<Map<String, dynamic>> _call(
  DeviceSession? Function(String?) findSession,
  Map<String, dynamic> params,
  String extensionMethod, {
  Map<String, String> extraArgs = const {},
}) async {
  final session = findSession(params['appId'] as String?);
  if (session == null) {
    return {'error': 'unknown appId: ${params['appId']}'};
  }
  final vm = session.vmClient;
  if (vm == null) return {'error': 'no VM service for ${session.appId}'};
  final args = <String, String>{
    for (final entry in params.entries)
      if (entry.key != 'appId' && entry.value != null)
        entry.key: entry.value.toString(),
    ...extraArgs,
  };
  final json = await vm.callServiceExtension(extensionMethod, args: args);
  if (json == null) return {'error': '$extensionMethod returned no payload'};
  // The Dart VM service appends `type` and `method` to every extension
  // response. Strip them so the AI sees only the agent's own fields and
  // gets a consistent shape across agent extensions and inspector RPCs.
  return Map<String, dynamic>.from(json)
    ..remove('type')
    ..remove('method');
}
