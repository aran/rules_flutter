/// Fails when the copies of a file differ across the e2e workspaces.
///
/// Each e2e workspace is its own Bazel project, so it carries its own copy of
/// what it cannot name in another project:
///
/// * the upstream-fix patches it applies (rules_android, protobuf, rules_go,
///   rules_android_ndk). A fix made to one copy and not the others leaves the
///   workspaces testing different code. A patch name found in only one
///   workspace is not a copy and is not checked.
/// * the files listed in `mirrored.bzl`, and `.bazelversion`.
/// * the `--incompatible_*` flags of the `.bazelrc`, which the root and every
///   workspace set alike: the rules are tested under the same Bazel defaults
///   everywhere. The rest of a `.bazelrc` differs by workspace.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The `--incompatible_*` options of [bazelrc], one per line as written
/// (`common --incompatible_x`), sorted: the order they come in is no copy.
List<String> incompatibleFlags(String bazelrc) => [
  for (final line in bazelrc.split('\n'))
    if (RegExp(r'^\s*\S+\s+--(no)?incompatible_\w+').hasMatch(line))
      line.trim().replaceAll(RegExp(r'\s+'), ' '),
]..sort();

void main() {
  group('incompatibleFlags', () {
    test('takes the incompatible options, whatever their order or spacing', () {
      expect(
        incompatibleFlags(
          '# common --incompatible_comment\n'
          'common   --incompatible_b\n'
          'build:ci --noincompatible_c=false\n'
          'common --other=incompatible_d\n'
          'common --incompatible_a\n',
        ),
        [
          'build:ci --noincompatible_c=false',
          'common --incompatible_a',
          'common --incompatible_b',
        ],
      );
    });
  });

  final runfiles = Runfiles.create(
    sourceRepository: Platform.environment['RUNFILES_SOURCE_REPO'] ?? '',
  );
  final repo =
      Platform.environment['E2E_COPIES_REPO'] ??
      (throw StateError('E2E_COPIES_REPO is not set: use bazel test'));

  List<String> lines(String index) => File(
    runfiles.rlocation('$repo/$index'),
  ).readAsLinesSync().where((l) => l.isNotEmpty).toList();

  String read(String path) =>
      File(runfiles.rlocation('$repo/$path')).readAsStringSync();

  /// Describes the differing copies in [copies] (label to contents).
  String? drift(
    String name,
    Map<String, String> copies,
    String Function(String) where,
  ) {
    if (copies.values.toSet().length <= 1) return null;
    final groups = <String, List<String>>{};
    copies.forEach((label, text) => (groups[text] ??= []).add(where(label)));
    return '$name differs: ${groups.values.map((g) => g.join(', ')).join(' vs ')}';
  }

  test('same-named patches are byte-identical across e2e workspaces', () {
    final entries = lines('index.txt');
    expect(entries, isNotEmpty, reason: 'no e2e patches were found at all');

    // patch file name -> workspace -> contents
    final byName = <String, Map<String, String>>{};
    for (final entry in entries) {
      final slash = entry.indexOf('/');
      final workspace = entry.substring(0, slash);
      final name = entry.substring(slash + 1);
      byName.putIfAbsent(name, () => {})[workspace] = read(entry);
    }

    final drifted = [
      for (final MapEntry(:key, :value) in byName.entries)
        ?drift(key, value, (ws) => 'e2e/$ws/patches'),
    ];
    expect(drifted, isEmpty, reason: drifted.join('\n'));
  });

  test('mirrored files are byte-identical across their copies', () {
    final entries = lines('mirrored.txt');
    expect(entries, isNotEmpty, reason: 'no mirrored files were found at all');

    // group -> path -> contents
    final byGroup = <String, Map<String, String>>{};
    for (final entry in entries) {
      final tab = entry.indexOf('\t');
      final group = entry.substring(0, tab);
      final path = entry.substring(tab + 1);
      byGroup.putIfAbsent(group, () => {})[path] = read('mirrored/$path');
    }

    for (final MapEntry(:key, :value) in byGroup.entries) {
      expect(
        value.length,
        greaterThan(1),
        reason: 'mirrored group "$key" has fewer than two copies',
      );
    }
    final drifted = [
      for (final MapEntry(:key, :value) in byGroup.entries)
        ?drift(key, value, (path) => path),
    ];
    expect(drifted, isEmpty, reason: drifted.join('\n'));
  });

  test('the incompatible flags are the same in every .bazelrc', () {
    final paths = lines('bazelrcs.txt');
    expect(paths, contains('.bazelrc'));
    expect(paths.length, greaterThan(1), reason: 'no e2e .bazelrc was found');

    final root = incompatibleFlags(read('bazelrc/.bazelrc'));
    expect(root, isNotEmpty, reason: 'the root .bazelrc sets none');
    final drifted = [
      for (final path in paths)
        if (incompatibleFlags(read('bazelrc/$path')).join('\n') !=
            root.join('\n'))
          '$path: ${_difference(root, incompatibleFlags(read('bazelrc/$path')))}',
    ];
    expect(
      drifted,
      isEmpty,
      reason:
          'the --incompatible_* flags of each e2e .bazelrc must be the root '
          '.bazelrc\'s; change them together:\n${drifted.join('\n')}',
    );
  });
}

/// What [other] lacks of [root] and what it adds, for the message.
String _difference(List<String> root, List<String> other) {
  final missing = root.where((f) => !other.contains(f));
  final extra = other.where((f) => !root.contains(f));
  return [
    for (final f in missing) 'lacks `$f`',
    for (final f in extra) 'adds `$f`',
  ].join(', ');
}
