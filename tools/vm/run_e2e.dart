/// Runs the rules_flutter e2e suites on a VM over SSH, with overhead's runner
/// (`@overhead//vm`, `lib/e2e.dart`):
///
///     bazel run //tools/vm:run_e2e -- <vm-name> [--windows] \
///         [--folders=.,e2e/hello_world] [--keep-going] [--rules-dart=../rules_dart]
///
/// The VM gets the committed tree (commit first), and each folder runs what
/// `.github/workflows/ci.yaml` runs there, which `tools/ci_matrix/e2e_matrix.dart`
/// says. See `e2e_items.dart`. With `--rules-dart`, that checkout's committed
/// HEAD goes over too and every folder builds against it.
library;

import 'dart:io';

import 'package:overhead_vm/e2e.dart';

import 'e2e_items.dart';

Future<void> main(List<String> args) => runE2e(
  args,
  repo: 'rules_flutter',
  options: const {
    'rules-dart': 'a rules_dart checkout whose committed HEAD every folder builds against',
  },
  usage:
      'Runs what CI runs on that system, as ci.yaml does: the root module on '
      'Linux, and every e2e workspace the matrix gives that system.',
  items: (options, root) => flutterItems(
    options,
    root,
    rulesDart: options.repoOptions.containsKey('rules-dart'),
  ),
  setup: (vm, options) async {
    final given = options.repoOptions['rules-dart'];
    if (given == null) return;
    // `bazel run` starts in the runfiles, so a relative path is the caller's.
    final cwd = Platform.environment['BUILD_WORKING_DIRECTORY'];
    final checkout = cwd != null && !given.startsWith('/')
        ? '$cwd/$given'
        : given;
    final bundle =
        '${Directory.systemTemp.createTempSync('rd_').path}/rd.bundle';
    final dirty = Process.runSync('git', [
      '-C',
      checkout,
      'status',
      '--porcelain',
      '--untracked-files=no',
    ]);
    if (dirty.stdout.toString().trim().isNotEmpty) {
      stderr.writeln(
        'WARNING: changes not committed in $checkout are NOT included.',
      );
    }
    final made = Process.runSync('git', [
      '-C',
      checkout,
      'bundle',
      'create',
      bundle,
      'HEAD',
    ]);
    if (made.exitCode != 0)
      throw Exception('git bundle failed:\n${made.stderr}');
    if (vm.windows) {
      await vm.copyTo(bundle, 'C:/rules_dart.bundle');
      await vm.exec(r'rmdir /s /q C:\rules_dart');
      // autocrlf off: the build must see the committed bytes.
      await vm.run(
        r'git -c core.autocrlf=false clone C:\rules_dart.bundle C:\rules_dart',
      );
    } else {
      await vm.copyTo(bundle, '/tmp/rules_dart.bundle');
      await vm.run(
        "bash -lc 'rm -rf /tmp/rules_dart && "
        "git clone /tmp/rules_dart.bundle /tmp/rules_dart'",
      );
    }
    File(bundle).parent.deleteSync(recursive: true);
  },
);
