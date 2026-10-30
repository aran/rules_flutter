/// Fails when copies of one patch file differ across the e2e workspaces.
///
/// Each e2e workspace is its own Bazel project, so each carries its own copy of
/// the upstream-fix patches it applies (rules_android, protobuf, rules_go,
/// rules_android_ndk). A fix made to one copy and not the others leaves the
/// workspaces testing different code. A patch name found in only one workspace
/// is not a copy and is not checked.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main() {
  test('same-named patches are byte-identical across e2e workspaces', () {
    final runfiles = Runfiles.create(
      sourceRepository: Platform.environment['RUNFILES_SOURCE_REPO'] ?? '',
    );
    final indexKey =
        Platform.environment['E2E_PATCHES_INDEX'] ??
        (throw StateError('E2E_PATCHES_INDEX is not set: use bazel test'));
    final entries = File(runfiles.rlocation(indexKey))
        .readAsLinesSync()
        .where((l) => l.isNotEmpty)
        .toList();
    expect(entries, isNotEmpty, reason: 'no e2e patches were found at all');

    // patch file name -> workspace -> contents
    final byName = <String, Map<String, String>>{};
    for (final entry in entries) {
      final slash = entry.indexOf('/');
      final workspace = entry.substring(0, slash);
      final name = entry.substring(slash + 1);
      final path = runfiles.rlocation(
        '${indexKey.substring(0, indexKey.indexOf('/'))}/$entry',
      );
      byName.putIfAbsent(name, () => {})[workspace] = File(path)
          .readAsStringSync();
    }

    final drifted = <String>[];
    byName.forEach((name, copies) {
      if (copies.values.toSet().length > 1) {
        final groups = <String, List<String>>{};
        copies.forEach((ws, text) => (groups[text] ??= []).add(ws));
        drifted.add(
          '$name differs: '
          '${groups.values.map((g) => g.map((w) => 'e2e/$w/patches').join(', ')).join(' vs ')}',
        );
      }
    });
    expect(drifted, isEmpty, reason: drifted.join('\n'));
  });
}
