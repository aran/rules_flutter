/// Release-archive guard: every e2e workspace except e2e/smoke is ignored.
///
/// `.gitattributes` keeps development-only workspaces out of the release
/// archive, but names each `e2e/` workspace by hand. This test fails when an
/// e2e workspace (any directory under `e2e/` holding a `MODULE.bazel`) is
/// neither export-ignored nor `e2e/smoke` — the one workspace the archive
/// must keep (`.bcr/presubmit.yml` names it as `module_path`, resolved
/// inside the extracted archive). It also fails when `e2e/smoke` itself
/// stops shipping.
///
/// Like the download digest guard, this test discovers its inputs at
/// runtime from the workspace root (the test's own source file in `data`,
/// or `BUILD_WORKSPACE_DIRECTORY` when set) and is tagged `external`, so a
/// new workspace is checked with no other change and never hidden behind a
/// stale pass.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Whether [root] is the rules_flutter workspace root.
bool _looksLikeRoot(String root) =>
    Directory('$root/e2e').existsSync() &&
    File('$root/.gitattributes').existsSync();

/// Workspace root the test walks: `BUILD_WORKSPACE_DIRECTORY` when set,
/// otherwise the source file behind the test's own anchor in `data` (an
/// unsandboxed runfiles tree symlinks it into the source tree; the root is
/// the first ancestor that looks like the workspace). Null when neither
/// resolves, so the test fails loudly instead of scanning the wrong tree
/// or silently passing.
String? _workspaceRoot() {
  final fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    try {
      var dir = File(
        File('$srcdir/$anchor').resolveSymbolicLinksSync(),
      ).parent;
      for (var i = 0; i < 8; i++) {
        if (_looksLikeRoot(dir.path)) return dir.path;
        dir = dir.parent;
      }
    } on FileSystemException {
      // Fall through to the loud failure below.
    }
  }
  return null;
}

/// Relative paths of every directory under `e2e/` holding a `MODULE.bazel`.
List<String> _findWorkspaces(String root) {
  final found = <String>[];
  final stack = <Directory>[Directory('$root/e2e')];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    List<FileSystemEntity> children;
    try {
      children = current.listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    var hasModule = false;
    final subdirs = <Directory>[];
    for (final child in children) {
      if (child is Directory) {
        if (child.path.split(Platform.pathSeparator).last == 'node_modules') {
          continue;
        }
        subdirs.add(child);
      } else if (child is File &&
          child.path.split(Platform.pathSeparator).last == 'MODULE.bazel') {
        hasModule = true;
      }
    }
    if (hasModule) {
      found.add(current.path.substring(root.length + 1));
    }
    stack.addAll(subdirs);
  }
  found.sort();
  return found;
}

/// Directories named by `/path/ export-ignore` lines in `.gitattributes`.
Set<String> _ignoredDirs(String root) {
  final ignored = <String>{};
  for (final line in File('$root/.gitattributes').readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length != 2) continue;
    if (parts[1] != 'export-ignore') continue;
    var pattern = parts[0];
    if (!pattern.startsWith('/')) continue;
    pattern = pattern.substring(1);
    if (pattern.endsWith('/')) {
      pattern = pattern.substring(0, pattern.length - 1);
    }
    // A file pattern (no trailing slash originally, naming a file) cannot
    // cover a workspace directory; keep only directory patterns.
    if (!parts[0].endsWith('/')) continue;
    ignored.add(pattern);
  }
  return ignored;
}

/// Whether workspace [dir] ships in the archive: it is ignored when it or
/// any ancestor directory is export-ignored.
bool _isIgnored(String dir, Set<String> ignored) {
  var current = dir;
  while (current.isNotEmpty) {
    if (ignored.contains(current)) return true;
    final slash = current.lastIndexOf('/');
    if (slash < 0) break;
    current = current.substring(0, slash);
  }
  return false;
}

void main() {
  final root = _workspaceRoot();
  if (root == null) {
    test('export-ignore guard discovers the workspace', () {
      fail(
        'BUILD_WORKSPACE_DIRECTORY does not point at the rules_flutter '
        'workspace; run this test unsandboxed (it is tagged no-sandbox) via '
        'bazel test //flutter/tests:e2e_export_ignore_guard_test',
      );
    });
    return;
  }

  test('every e2e workspace except e2e/smoke is export-ignored', () {
    final workspaces = _findWorkspaces(root);
    expect(
      workspaces,
      contains('e2e/smoke'),
      reason: 'the walk under e2e/ missed e2e/smoke itself',
    );
    final ignored = _ignoredDirs(root);
    final problems = <String>[];
    for (final workspace in workspaces) {
      if (workspace == 'e2e/smoke') continue;
      if (!_isIgnored(workspace, ignored)) {
        problems.add(
          '$workspace: e2e workspace ships in the release archive; add '
          "'/$workspace/ export-ignore' to .gitattributes",
        );
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('e2e/smoke still ships in the release archive', () {
    final ignored = _ignoredDirs(root);
    expect(
      _isIgnored('e2e/smoke', ignored),
      isFalse,
      reason:
          'e2e/smoke is export-ignored but the BCR presubmit resolves '
          'it inside the release archive',
    );
  });
}
