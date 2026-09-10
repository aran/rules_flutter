import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/package_roots.dart';
import 'package:test/test.dart';

/// The rewrite runs on real directories — it asks whether each result exists,
/// which is the check that turns a wrong path into an error instead of a
/// compile that fails on every library in the package. So the fixtures here are
/// real trees, laid out the way Bazel lays out an output base.
void main() {
  late Directory root;

  /// `<root>/execroot/_main/bazel-out/<config>/bin`, where a build-emitted dev
  /// package_config lives, plus the repository tree and its per-command forest.
  late Directory bin;
  late Directory repoTree;

  setUp(() {
    root = Directory.systemTemp.createTempSync('package_roots_test_');
    bin = Directory('${root.path}/execroot/_main/bazel-out/darwin-dbg/bin')
      ..createSync(recursive: true);
    repoTree = Directory('${root.path}/external/deps__flutter')
      ..createSync(recursive: true);
    // The execroot entry is a symlink into the repository tree, exactly as
    // Bazel plants it. Its presence is what the relative root resolves
    // through; its absence mid-command is what the rewrite exists to survive.
    Directory(
      '${root.path}/execroot/_main/external',
    ).createSync(recursive: true);
    Link(
      '${root.path}/execroot/_main/external/deps__flutter',
    ).createSync(repoTree.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// Write a dev package_config into [bin] and rewrite it into a fresh dir.
  StabilizedPackageConfig stabilize(List<Map<String, Object?>> packages) {
    final source = File('${bin.path}/app.dev_package_config.json')
      ..writeAsStringSync(
        json.encode({'configVersion': 2, 'packages': packages}),
      );
    final into = Directory('${root.path}/out')..createSync(recursive: true);
    return stabilizePackageRoots(source.path, into: into);
  }

  List<Map<String, dynamic>> packagesOf(String path) =>
      (json.decode(File(path).readAsStringSync())['packages'] as List)
          .cast<Map<String, dynamic>>();

  test(
    'moves a root off the per-command execroot onto the repository tree',
    () {
      final result = stabilize([
        {
          'name': 'flutter',
          'rootUri': '../../../external/deps__flutter',
          'packageUri': 'lib/',
        },
      ]);

      final rewritten = packagesOf(result.path).single['rootUri'] as String;
      expect(
        Uri.parse(rewritten).toFilePath(),
        repoTree.resolveSymbolicLinksSync(),
        reason: 'the repository tree is the copy Bazel does not re-plant',
      );
      expect(rewritten, isNot(contains('execroot')));
      expect(result.repointed, ['flutter']);
    },
  );

  test('leaves the app filesystem scheme untouched', () {
    // These address live source through the compiler's `--filesystem-root`
    // machinery. Rewriting one to a path would break the mixed-scheme
    // resolution a source-assembled app depends on.
    final result = stabilize([
      {'name': 'dep_lib', 'rootUri': 'org-dartlang-app:///dep_lib'},
    ]);

    expect(
      packagesOf(result.path).single['rootUri'],
      'org-dartlang-app:///dep_lib',
    );
    expect(result.repointed, isEmpty);
  });

  test('absolutizes a relative root that never touches an execroot', () {
    // The rewritten config is written to a DIFFERENT directory, so a relative
    // root copied over verbatim silently re-anchors to that directory.
    final appRoot = Directory('${bin.path}/app.pkgsrcs')..createSync();
    // Resolved, because the rewrite resolves the config's own directory first
    // and macOS puts the system temp root behind a `/var` -> `/private/var`
    // symlink.
    final expected = appRoot.resolveSymbolicLinksSync();
    final result = stabilize([
      {'name': 'hello_world', 'rootUri': 'app.pkgsrcs', 'packageUri': 'lib/'},
    ]);

    final rewritten = packagesOf(result.path).single['rootUri'] as String;
    expect(Uri.parse(rewritten).toFilePath(), expected);
    expect(result.repointed, ['hello_world']);
  });

  test('a root that resolves nowhere is an error, not a silent pass-through', () {
    // A package whose root does not exist fails on every library in it, and the
    // compiler reports that as a wall of missing-file errors naming the
    // libraries rather than the root. Saying it once here is the difference.
    expect(
      () => stabilize([
        {'name': 'ghost', 'rootUri': '../../../external/deps__absent'},
      ]),
      throwsA(
        isA<DevToolException>().having(
          (e) => e.toString(),
          'message',
          contains('deps__absent'),
        ),
      ),
    );
  });

  test('does not modify the build-emitted file', () {
    final source = File('${bin.path}/app.dev_package_config.json');
    stabilize([
      {'name': 'flutter', 'rootUri': '../../../external/deps__flutter'},
    ]);

    expect(
      json.decode(source.readAsStringSync())['packages'][0]['rootUri'],
      '../../../external/deps__flutter',
      reason: 'the build owns that file; a later build compares against it',
    );
  });

  test('rewrites every root in one pass', () {
    final result = stabilize([
      {'name': 'flutter', 'rootUri': '../../../external/deps__flutter'},
      {'name': 'dep_lib', 'rootUri': 'org-dartlang-app:///dep_lib'},
      {'name': 'app', 'rootUri': '.'},
    ]);

    expect(result.repointed, ['flutter', 'app']);
    final roots = {
      for (final p in packagesOf(result.path))
        p['name']: p['rootUri'] as String,
    };
    expect(roots['dep_lib'], 'org-dartlang-app:///dep_lib');
    expect(roots['flutter'], isNot(contains('execroot')));
    final resolvedBin = bin.resolveSymbolicLinksSync();
    expect(
      Uri.parse(roots['app']!).toFilePath(),
      anyOf(resolvedBin, '$resolvedBin/'),
    );
  });
}
