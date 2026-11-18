/// The packages an app compiles from local repositories: source the user
/// edits that Bazel reaches as an external repository.
///
/// A `local_path_override` module (or an `--override_module`, or a
/// `local_repository`) is a directory on disk, often a sibling checkout, that
/// Bazel mounts at `external/<repo>`. The build lists only the main
/// repository's packages as editable (the dev config's `sourcePackages`),
/// because nothing a build can see tells a local repository from a fetched one.
/// Bazel can: `bazel mod show_repo` names the rule behind each repository, and
/// for a local one the directory it points at.
///
/// So this reads the dev package config for packages under `external/<repo>`,
/// asks Bazel which of those repositories are local, and answers each such
/// package's root in the directory the user edits. Those join the main
/// repository's packages wherever an edit is looked for: the snapshot a reload
/// diffs, and the directories `--watch` watches. Fetched repositories are left
/// out, as `flutter run` leaves out the pub cache: their files cannot change
/// under a run, and stat'ing them on every reload would cost time for nothing.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'dev_tool_exception.dart';

/// A package of the dev package config whose root lies in an external
/// repository: [repo] is the repository's canonical name and [subpath] the
/// package root inside it (empty for a package at the repository's root).
typedef ExternalPackage = ({String name, String repo, String subpath});

/// Every package in the dev package config at [packageConfigPath] whose root is
/// in an external repository, in the order the config lists them.
List<ExternalPackage> externalPackages(String packageConfigPath) {
  final decoded = json.decode(File(packageConfigPath).readAsStringSync());
  final packages = (decoded as Map<String, dynamic>)['packages'] as List;
  return [
    for (final entry in packages.cast<Map<String, dynamic>>())
      if (_inExternalRepo(entry['rootUri'] as String) case final at?)
        (name: entry['name'] as String, repo: at.repo, subpath: at.subpath),
  ];
}

/// The repository and the path inside it of a package [rootUri], or null for a
/// root in the main repository.
///
/// Two spellings reach a repository: a relative root through the execroot's
/// `external/<repo>`, and a source-assembled package's root in the app's
/// filesystem scheme, which names the package by its short path,
/// `../<repo>/…`. Split as written rather than through [Uri.parse], which
/// would fold that `..` away.
({String repo, String subpath})? _inExternalRepo(String rootUri) {
  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):///?').firstMatch(rootUri);
  final inScheme = scheme != null && scheme.group(1) != 'file';
  final path = scheme == null ? rootUri : rootUri.substring(scheme.end);
  final segments = [
    for (final s in path.split('/'))
      if (s.isNotEmpty && s != '.') s,
  ];
  final int repoAt;
  if (inScheme) {
    if (segments.length < 2 || segments.first != '..') return null;
    repoAt = 1;
  } else {
    // `external` only where the path reaches the execroot: the first segment
    // after the `..`s that climb to it. Further in, it is a directory of the
    // main repository's own (`third_party/external/pkg`).
    final external = segments.indexWhere((s) => s != '..');
    if (external < 0 ||
        segments[external] != 'external' ||
        external + 1 >= segments.length) {
      return null;
    }
    repoAt = external + 1;
  }
  return (
    repo: segments[repoAt],
    subpath: p.posix.joinAll(segments.sublist(repoAt + 1)),
  );
}

/// The `bazel` arguments that describe [repos], for [parseLocalRepositories].
///
/// [moduleGraphFlags] are the options that decided the module graph of the
/// build the app came from (see `moduleGraphFlagsFromBuildEvents`), so the
/// answer is about the repositories that build used: an `--override_module`
/// passed as a `--build-arg`, or one a `--config` turns on, makes a module
/// local that is fetched without it. They are passed as Bazel expanded them,
/// never as a `--config`, which `bazel mod` refuses when the config has only
/// `build` lines.
List<String> showRepoArgs(
  Iterable<String> repos, {
  List<String> moduleGraphFlags = const [],
}) => [
  'mod',
  'show_repo',
  for (final r in repos) '@@$r',
  '--output=streamed_jsonproto',
  ...moduleGraphFlags,
];

/// The rules that make a repository out of a directory already on disk.
const _localRules = {'local_repository', 'new_local_repository'};

/// From `bazel mod show_repo --output=streamed_jsonproto`, the directory of
/// each local repository, by canonical name.
///
/// A relative `path` is relative to the main repository, [workspace], as Bazel
/// reads it.
Map<String, String> parseLocalRepositories(
  String stdout, {
  required String workspace,
}) {
  final local = <String, String>{};
  for (final line in const LineSplitter().convert(stdout)) {
    if (line.trim().isEmpty) continue;
    final repo = json.decode(line) as Map<String, dynamic>;
    if (!_localRules.contains(repo['repoRuleName'])) continue;
    final attributes = (repo['attribute'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final path = attributes
        .where((a) => a['name'] == 'path')
        .map((a) => a['stringValue'] as String?)
        .firstOrNull;
    if (path == null || path.isEmpty) {
      throw DevToolException(
        'bazel mod show_repo describes ${repo['canonicalName']} as a '
        '${repo['repoRuleName']} with no path:\n$line',
      );
    }
    local[repo['canonicalName'] as String] = p.normalize(
      p.isAbsolute(path) ? path : p.join(workspace, path),
    );
  }
  return local;
}

/// Each of [packages] whose repository is in [localRepositories], with its
/// root in that repository's directory: the root the user edits.
List<({String name, String packageRoot})> localPackageRoots(
  List<ExternalPackage> packages,
  Map<String, String> localRepositories,
) => [
  for (final pkg in packages)
    if (localRepositories[pkg.repo] case final dir?)
      (
        name: pkg.name,
        // The subpath is a URI's, `/`-separated; the root is the host's.
        packageRoot: p.joinAll([dir, ...p.posix.split(pkg.subpath)]),
      ),
];

/// The packages of the dev package config at [packageConfigPath] that live in
/// local repositories, rooted where the user edits them; [localRepositories]
/// is `Bazel.localRepositories` for the run's workspace.
Future<List<({String name, String packageRoot})>> localSourcePackages(
  String packageConfigPath, {
  required Future<Map<String, String>> Function(Iterable<String> repos)
  localRepositories,
}) async {
  final external = externalPackages(packageConfigPath);
  final local = await localRepositories({for (final e in external) e.repo});
  return localPackageRoots(external, local);
}
