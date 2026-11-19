/// Finds the Bazel workspaces under `e2e/`.
library;

import 'dart:io';

/// The directories under [e2e] that are Bazel workspaces: each holds a
/// `MODULE.bazel`. Found by walking, so a workspace added tomorrow is checked
/// tomorrow, whatever its depth.
///
/// The walk stops at a workspace — its subdirectories are the app's own
/// (`ios/`, `macos/`, `lib/`) and a `MODULE.bazel` there would belong to a
/// vendored dependency, not to the e2e suite — and skips Bazel's `bazel-*`
/// output symlinks and `node_modules`. Paths come back relative to [e2e]'s
/// parent, sorted, with `/` separators.
List<String> findWorkspaces(Directory e2e) {
  final root = e2e.parent.path;
  final found = <String>[];
  void walk(Directory dir) {
    if (File('${dir.path}/MODULE.bazel').existsSync()) {
      found.add(_relative(dir.path, root));
      return;
    }
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (name.startsWith('bazel-') ||
          name.startsWith('.') ||
          name == 'node_modules') {
        continue;
      }
      walk(entry);
    }
  }

  walk(e2e);
  found.sort();
  return found;
}

String _relative(String path, String root) =>
    path.substring(root.length + 1).replaceAll(Platform.pathSeparator, '/');

/// The text of every BUILD file in [workspace], at any depth: `BUILD` and
/// `BUILD.bazel`. Bazel's `bazel-*` output links, `node_modules` and hidden
/// directories are skipped, and links are not followed.
List<String> readBuildFiles(Directory workspace) {
  final found = <String>[];
  void walk(Directory dir) {
    for (final entry in dir.listSync(followLinks: false)) {
      final name = entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (entry is File && (name == 'BUILD' || name == 'BUILD.bazel')) {
        found.add(entry.readAsStringSync());
      } else if (entry is Directory &&
          !name.startsWith('bazel-') &&
          !name.startsWith('.') &&
          name != 'node_modules') {
        walk(entry);
      }
    }
  }

  walk(workspace);
  return found;
}
