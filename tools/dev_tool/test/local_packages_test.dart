import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/source_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:flutter_bazel_dev_tool/local_packages.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A `show_repo --output=streamed_jsonproto` line for [repo] made by [rule].
String _repoLine(String repo, String rule, {String? path}) => json.encode({
  'canonicalName': repo,
  'repoRuleName': rule,
  'attribute': [
    if (path != null) {'name': 'path', 'type': 'STRING', 'stringValue': path},
    {'name': 'urls', 'type': 'STRING_LIST', 'stringListValue': <String>[]},
  ],
});

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('local_packages_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String writeConfig(List<Map<String, String>> packages) {
    final f = File(p.join(tmp.path, 'dev_package_config.json'));
    f.writeAsStringSync(
      json.encode({'configVersion': 2, 'packages': packages}),
    );
    return f.path;
  }

  group('externalPackages', () {
    test('reads the repository and path of each external package root', () {
      final config = writeConfig([
        {'name': 'ui_kit', 'rootUri': '../../../external/ui_kit+'},
        {
          'name': 'payments',
          'rootUri': '../../../external/stack+/packages/payments',
        },
        {'name': 'app', 'rootUri': 'org-dartlang-app:///'},
        {'name': 'core', 'rootUri': 'org-dartlang-app:///packages/core'},
        {'name': 'gen', 'rootUri': 'org-dartlang-app:///../kit+/packages/gen'},
        {'name': 'local', 'rootUri': '../../../packages/local'},
      ]);
      expect(externalPackages(config), [
        (name: 'ui_kit', repo: 'ui_kit+', subpath: ''),
        (name: 'payments', repo: 'stack+', subpath: 'packages/payments'),
        (name: 'gen', repo: 'kit+', subpath: 'packages/gen'),
      ]);
    });

    // Read as a repository, it is a `bazel mod show_repo @@pkg` that fails, and
    // a run whose hot reload never comes up.
    test('leaves a main-repository directory named external alone', () {
      final config = writeConfig([
        {'name': 'pkg', 'rootUri': '../../../third_party/external/pkg'},
        {'name': 'deep', 'rootUri': '../../../a/external/b/external/c'},
      ]);
      expect(externalPackages(config), isEmpty);
    });
  });

  group('parseLocalRepositories', () {
    test('keeps local repositories, with their directory', () {
      final out = [
        _repoLine('ui_kit+', 'local_repository', path: '/src/ui_kit'),
        _repoLine('sibling+', 'local_repository', path: '../sibling'),
        _repoLine('vendored+', 'new_local_repository', path: '/v'),
        _repoLine('skylib+', 'http_archive'),
        '',
      ].join('\n');
      // Host paths, normalized.
      expect(parseLocalRepositories(out, workspace: '/work/app'), {
        'ui_kit+': p.normalize('/src/ui_kit'),
        'sibling+': p.normalize('/work/sibling'),
        'vendored+': p.normalize('/v'),
      });
    });

    test('refuses a local repository with no path', () {
      expect(
        () => parseLocalRepositories(
          _repoLine('odd+', 'local_repository'),
          workspace: '/w',
        ),
        throwsA(isA<DevToolException>()),
      );
    });
  });

  test('showRepoArgs names each repository canonically', () {
    expect(showRepoArgs(['a+', 'b+']), [
      'mod',
      'show_repo',
      '@@a+',
      '@@b+',
      '--output=streamed_jsonproto',
    ]);
  });

  test(
    'a local package edit shows in the snapshot under its package URI',
    () async {
      // The directory a local_path_override points at, outside the workspace.
      final kit = Directory(p.join(tmp.path, 'kit', 'packages', 'ui_kit'))
        ..createSync(recursive: true);
      final label = File(p.join(kit.path, 'lib', 'src', 'label.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('const label = 1;');
      final config = writeConfig([
        {'name': 'ui_kit', 'rootUri': '../../../external/kit+/packages/ui_kit'},
        {'name': 'flutter', 'rootUri': '../../../external/flutter_sdk+'},
      ]);

      final asked = <Set<String>>[];
      final local = await localSourcePackages(
        config,
        localRepositories: (repos) async {
          asked.add(repos.toSet());
          return {'kit+': p.join(tmp.path, 'kit')};
        },
      );
      expect(asked, [
        {'kit+', 'flutter_sdk+'},
      ]);
      expect(local, [(name: 'ui_kit', packageRoot: kit.path)]);

      final resolver = SourceUriResolver(
        workspaceRoot: p.join(tmp.path, 'workspace'),
        sourcePackages: local,
      );
      expect(resolver.uriFor(label.path), 'package:ui_kit/src/label.dart');
      final snapshot = Workspace(resolver: resolver).snapshot();
      expect(snapshot.fileUris, ['package:ui_kit/src/label.dart']);
    },
  );
}
