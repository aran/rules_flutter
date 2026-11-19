/// What rules_flutter runs on a VM: the folders CI runs on that system, from
/// `tools/ci_matrix/e2e_matrix.dart`, as items for overhead's runner
/// (`@overhead//vm`, `lib/e2e.dart`).
library;

import 'dart:io';

import 'package:overhead_vm/e2e.dart';

import '../ci_matrix/e2e_matrix.dart';

/// How long one folder may run: the `e2e` job's `timeout-minutes` in
/// `.github/workflows/ci.yaml`, as a folder here is one of those jobs. Every
/// folder starts cold (its own output base) and fetches the Flutter SDK,
/// engine and toolchains, and a cold Windows Android workspace takes most of
/// an hour.
const folderTimeout = Duration(minutes: 120);

/// Where `--rules-dart`'s checkout is on the VM.
String rulesDartOnVm({required bool windows}) =>
    windows ? 'C:/rules_dart' : '/tmp/rules_dart';

/// On Linux the root module (CI's `unit-tests` job), then every workspace the
/// e2e matrix runs on the VM's system, each with the targets CI gives it there; or, with
/// `--folders=`, those named (a workspace the matrix runs on this system gets
/// its matrix targets, any other folder `//...`).
///
/// With [rulesDart], every folder builds against the rules_dart checkout there
/// (`--override_module`, and for the root its `overhead` too), as a local
/// `.bazelrc.user` does; the lock stays as committed.
List<E2eItem> flutterItems(
  E2eOptions options,
  String repoRoot, {
  required bool rulesDart,
}) {
  final os = options.windows ? Os.windows : Os.linux;
  E2eItem item(String folder) {
    var targets = const ['//...'];
    for (final workspace in e2eWorkspaces) {
      if (folder == 'e2e/${workspace.name}' && workspace.runs.containsKey(os)) {
        final build = File('$repoRoot/$folder/BUILD.bazel');
        targets = workspace.targetsOn(
          os,
          build.existsSync() ? build.readAsStringSync() : '',
        );
      }
    }
    final rd = rulesDartOnVm(windows: options.windows);
    return E2eItem.bazel(
      folder,
      [
        'test',
        '--test_output=errors',
        if (rulesDart) ...[
          '--override_module=rules_dart=$rd',
          if (folder == '.') '--override_module=overhead=$rd/overhead',
          '--lockfile_mode=off',
        ],
        ...targets,
      ],
      passExitCodes: const {0, 4}, // 4: no test targets
      timeout: folderTimeout,
    );
  }

  final folders =
      options.folders ??
      [
        // CI runs the root module's tests on Linux only.
        if (!options.windows) '.',
        for (final workspace in e2eWorkspaces)
          if (workspace.runs.containsKey(os)) 'e2e/${workspace.name}',
      ];
  return [for (final folder in folders) item(folder)];
}
