/// Tooling that loads a whole workspace works without the workspace naming the
/// Android engine of every ABI.
///
/// `flutter_android_engine` picks the engine of the platform it is built for
/// with a `select()` over one repository per ABI. A build resolves only the
/// chosen branch, but `bazel query 'deps(//...)'` (and the IDE and
/// dependency-graph tooling built on it) loads every branch, so a repository
/// that only the user's own `use_repo` made visible fails the query with "No
/// repository visible as '@flutter_android_engine_x64'". The engine
/// repositories belong to rules_flutter's extension: rules_flutter resolves
/// them itself, and a user's `use_repo` of them is never required.
///
/// The workspace downloads its Android SDK, as every Android workspace here
/// does: without an SDK, rules_android declares no `androidsdk` targets and a
/// query fails for that reason instead.
///
/// This runs the query in `e2e/hello_world`, whose `MODULE.bazel` must not
/// name every ABI's engine (the guard below), so a query that passes proves
/// the labels resolve from somewhere other than the user's module.
@Tags(['e2e'])
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// The app under test.
const _app = E2eApp('hello_world');

const _abis = ['arm64', 'x64'];

void main() {
  final workspace = _app.moduleRoot;

  test('hello_world names fewer than every ABI engine in use_repo', () {
    final module = File(p.join(workspace, 'MODULE.bazel')).readAsStringSync();
    final named = [
      for (final abi in _abis)
        if (module.contains('"flutter_android_engine_$abi"')) abi,
    ];
    expect(
      named.length,
      lessThan(_abis.length),
      reason:
          'The query below proves labels resolve without the user, and only '
          'does so while this workspace leaves an ABI out of use_repo.',
    );
  });

  test('bazel query deps(//...) loads every package', () async {
    final result = await Process.run('bazel', [
      'query',
      'deps(//...)',
      '--output=label',
      '--noshow_progress',
      '--curses=no',
      '--color=no',
    ], workingDirectory: workspace);
    expect(
      result.exitCode,
      0,
      reason: '${result.stderr}'.split('\n').take(20).join('\n'),
    );
    // The engine of the ABI the workspace never names is part of the graph.
    expect(
      '${result.stdout}',
      matches(RegExp(r'flutter_android_engine_x64[^\n]*//:stripped')),
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
