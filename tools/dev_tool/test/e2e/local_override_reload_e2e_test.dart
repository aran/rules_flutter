@Tags(['e2e', 'ios_sim'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';
import 'editable_workspace.dart';

/// The app under test.
const _app = E2eApp('ios_example');

/// Hot reload of an edit to a package from a `local_path_override` module.
///
/// A module overridden to a local path is source the user edits — often a
/// sibling checkout — but Bazel reaches it as an external repository, so its
/// files sit under `external/<repo>` and no package of the main repository
/// owns them. A reload that only looks at the main repository's packages never
/// sees them change: the app's own edit is recompiled against the package as
/// it was at launch, and a declaration the package just gained is not found.
///
/// The edit is the shape that exposes it: the package gains a class and the
/// app starts using it in the same reload, so the app's library cannot compile
/// unless the package's library is recompiled too. The package sits outside
/// the workspace, beside it, as a sibling checkout would.
void main() {
  test(
    'a reload recompiles an edited package of a local_path_override module',
    () async {
      final ws = await editableWorkspace(_app);
      final kit = _writeUiKitModule(p.join(p.dirname(ws.root), 'ui_kit'));

      final module = ws.file('MODULE.bazel');
      module.writeAsStringSync(
        '${module.readAsStringSync()}\n'
        'bazel_dep(name = "ui_kit", version = "0.0.0")\n'
        'local_path_override(module_name = "ui_kit", path = "$kit")\n',
      );
      final build = ws.file('BUILD.bazel');
      final buildText = build.readAsStringSync();
      const appDep = '"@deps//:material_ui",';
      expect(buildText, contains(appDep), reason: 'fixture marker present');
      build.writeAsStringSync(
        buildText.replaceFirst(appDep, '$appDep\n        "@ui_kit//:ui_kit",'),
      );

      final appMain = ws.file('lib/main.dart');
      // Not const any more: the edit below reads a field, which is not a
      // constant expression.
      const greeting = "const Text(\n                'Hello from Flutter iOS!'";
      final mainText = appMain.readAsStringSync();
      expect(mainText, contains(greeting), reason: 'fixture marker present');
      appMain.writeAsStringSync(
        "import 'package:ui_kit/ui_kit.dart' as kit;\n"
        '${mainText.replaceFirst(greeting, 'Text(\n                kit.label')}',
      );

      final dt = await startDevTool(
        workspace: ws.root,
        target: ':app',
        device: 'ios-simulator',
      );
      final start = await dt.waitForEvent(
        'app.start',
        // A cold output base builds the whole app.
        timeout: const Duration(minutes: 15),
      );
      final appId = start['params']?['appId'] as String? ?? dt.appId!;
      await dt.waitForHttpControl(timeout: const Duration(seconds: 60));
      // An edit inside the assembler's own build window is compiled into its
      // baseline, so nothing is edited before the pipeline is up.
      await dt.waitForStderr(
        'frontend_server_ready',
        timeout: const Duration(minutes: 10),
      );
      await _expectRendered(dt, appId, 'kit v1');

      // The package gains a class with const constructors, and the app uses
      // one, as in the edit that found this.
      File(p.join(kit, 'lib', 'src', 'label.dart')).writeAsStringSync('''
const label = 'kit v1';

class LineLimit {
  const LineLimit() : min = 1, max = 1;
  const LineLimit.range(this.min, this.max);
  const LineLimit.atLeast(this.min) : max = null;

  final int min;
  final int? max;
}
''');
      appMain.writeAsStringSync(
        appMain.readAsStringSync().replaceFirst(
          'kit.label',
          "'lines \${const kit.LineLimit.range(2, 5).max}'",
        ),
      );

      final reload = await dt.sendCommand(
        1,
        'app.hotReload',
        params: {'appId': appId},
        timeout: const Duration(seconds: 120),
      );
      expect(reload['error'], isNull, reason: 'app.hotReload: $reload');
      final result = (reload['result'] as Map).cast<String, dynamic>();
      expect(result['succeeded'], isTrue, reason: 'app.hotReload: $result');
      expect(
        result['filesRecompiled'],
        contains('package:ui_kit/src/label.dart'),
        reason: 'the edited package library must reach the compiler',
      );
      await _expectRendered(dt, appId, 'lines 5');
    },
    timeout: const Timeout(Duration(minutes: 25)),
    skip: !Platform.isMacOS ? 'macOS only (needs Xcode Simulator)' : null,
  );
}

/// A module holding one Flutter package, `ui_kit`, at [dir], whose public
/// library exports a library under `src/` the way a UI kit's does.
String _writeUiKitModule(String dir) {
  final files = {
    'MODULE.bazel':
        'module(name = "ui_kit")\n\n'
        'bazel_dep(name = "rules_flutter", version = "0.0.0")\n',
    'BUILD.bazel': '''
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_library")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "ui_kit",
)

flutter_library(
    name = "ui_kit",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pubspec-metadata",
    visibility = ["//visibility:public"],
)
''',
    'lib/ui_kit.dart': "export 'src/label.dart';\n",
    'lib/src/label.dart': "const label = 'kit v1';\n",
  };
  for (final MapEntry(:key, :value) in files.entries) {
    File(p.join(dir, key))
      ..createSync(recursive: true)
      ..writeAsStringSync(value);
  }
  return dir;
}

/// Require the running app to be displaying [text].
Future<void> _expectRendered(
  DevToolProcess dt,
  String appId,
  String text,
) async {
  final found = await dt.httpCommand('app.waitFor', {
    'appId': appId,
    'text': text,
    'timeoutMs': '30000',
  });
  expect(found['error'], isNull, reason: '"$text" must be on screen: $found');
}
