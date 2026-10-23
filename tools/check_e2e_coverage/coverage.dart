/// The e2e workspace coverage check, shared by the `check_e2e_coverage`
/// binary (run by CI) and its unit test.
///
/// Modules are keyed by workspace-relative path (`e2e/foo`,
/// `e2e/_overlay_tests/link_hooks`), never by leaf name: two nested modules
/// may share a leaf name, and keying by leaf would let one shadow the other.
/// Workflow references are leaf names (`working-directory: e2e/<leaf>`, a
/// `workspace: <leaf>` matrix entry, a `WORKSPACES:` token); a module counts
/// as covered when its leaf is referenced.
library;

import 'dart:io';

/// Workspace-relative paths whose modules have no workflow, with one line
/// each saying why. A reason for a module that IS covered is an error, so
/// the table cannot go stale.
const Map<String, String> uncoveredReasons = {
  'e2e/ios_example':
      'Apple-only; the iOS simulator signal is covered by hello_world\'s '
      'ios_bundle_build_test, the full app awaits a macOS runner slot.',
  'e2e/macos_example':
      'Apple-only; the macOS bundle signal is covered by hello_world\'s '
      'macos_bundle_build_test, the full app awaits a macOS runner slot.',
  'e2e/windows_example':
      'Windows-only; the Windows runner signal is covered by hello_world, '
      'the full app exceeds the windows-latest runner\'s commit limit.',
  'e2e/multi_window_example':
      'Apple-only (macOS bundles + iOS scenes); no macOS slot is left in '
      'push CI under the 2-job budget shared with rules_dart.',
  'e2e/_overlay_tests/link_hooks':
      'Local-only overlay fixture; runs by hand with its sibling override '
      'of rules_flutter, which push CI never checks out.',
  'e2e/_overlay_tests/native_assets_synthetic':
      'Local-only overlay fixture; runs by hand with its sibling override '
      'of rules_flutter, which push CI never checks out.',
};

final RegExp _workspaceRef = RegExp(
  r'working-directory:\s*e2e/([A-Za-z0-9_./-]+)',
);
final RegExp _matrixRef = RegExp(r'workspace:\s*([A-Za-z0-9_-]+)');
final RegExp _workspacesRef = RegExp(r'WORKSPACES:\s*(.+)');

/// Drops `#` comments; workflows carry no `#` inside quoted strings.
String stripComments(String text) =>
    text.split('\n').map((line) => line.split('#').first).join('\n');

/// The leaf directory name of a workspace-relative module path.
String leafName(String modulePath) =>
    modulePath.split(Platform.pathSeparator).last;

/// Workspace-relative paths of every module directory: any directory holding
/// a `MODULE.bazel`, at `e2e/*/` or one level deeper.
///
/// Symlinks are never followed. A built workspace contains `bazel-*`
/// convenience links pointing into the output base, which carries a
/// `MODULE.bazel`; descending into them would invent phantom modules such as
/// `e2e/android_example/bazel-android_example`. As a second guard, `bazel-*`
/// names are skipped outright.
Set<String> findE2eModules(Directory e2eDir, String rootPath) {
  final modules = <String>{};
  Iterable<Directory> childDirs(Directory dir) => dir
      .listSync(followLinks: false)
      .whereType<Directory>()
      .where((d) => !FileSystemEntity.isLinkSync(d.path))
      .where(
        (d) => !d.path.split(Platform.pathSeparator).last.startsWith('bazel-'),
      );
  final top = childDirs(e2eDir).toList();
  final nested = top.expand(childDirs);
  for (final dir in [...top, ...nested]) {
    if (File('${dir.path}/MODULE.bazel').existsSync()) {
      modules.add(_relativeTo(dir.path, rootPath));
    }
  }
  return modules;
}

/// Leaf module names referenced by any workflow outside of comments.
Set<String> findCoveredModules(Directory workflowsDir) {
  final covered = <String>{};
  final entries = workflowsDir
      .listSync(followLinks: false)
      .whereType<File>()
      .where(
        (f) => f.path.endsWith('.yaml') || f.path.endsWith('.yml'),
      );
  for (final file in entries) {
    final text = stripComments(file.readAsStringSync());
    for (final match in _workspaceRef.allMatches(text)) {
      covered.add(match.group(1)!.split('/').last);
    }
    for (final match in _matrixRef.allMatches(text)) {
      covered.add(match.group(1)!);
    }
    for (final match in _workspacesRef.allMatches(text)) {
      for (final token in match.group(1)!.trim().split(RegExp(r'\s+'))) {
        final bare = token.replaceAll(RegExp('^["\']+|["\']+\$'), '');
        if (bare.isNotEmpty && bare != r'$WORKSPACES') covered.add(bare);
      }
    }
  }
  return covered;
}

/// Error strings for the coverage check: a module in no workflow without a
/// recorded reason, a reason for a module that is covered, a reason naming
/// no module, and a workflow reference naming no module. Empty when the tree
/// is fully covered or reasoned.
List<String> checkCoverage({
  required Set<String> modules,
  required Set<String> covered,
  required Map<String, String> reasons,
}) {
  final leafNames = modules.map(leafName).toSet();
  final errors = <String>[];
  for (final module in modules.toList()..sort()) {
    final inWorkflow = covered.contains(leafName(module));
    final hasReason = reasons.containsKey(module);
    if (inWorkflow && hasReason) {
      errors.add(
        "e2e module '$module' is covered by a workflow but still has an "
        'uncovered-reasons entry; remove the stale reason',
      );
    } else if (!inWorkflow && !hasReason) {
      errors.add(
        "e2e module '$module' is in no workflow and has no "
        'uncovered-reasons entry; add it to a workflow or record why it '
        'has none',
      );
    }
  }
  for (final name in reasons.keys.toList()..sort()) {
    if (!modules.contains(name)) {
      errors.add(
        "uncovered-reasons names '$name', which is no e2e module; remove it",
      );
    }
  }
  for (final name in covered.toList()..sort()) {
    if (!leafNames.contains(name)) {
      errors.add(
        "workflow references e2e module '$name', which does not exist; "
        'fix the typo or add the module',
      );
    }
  }
  return errors;
}

/// [path] relative to [rootPath] with the separator stripped, or [path]
/// unchanged when it is not under [rootPath].
String _relativeTo(String path, String rootPath) {
  final prefix = '$rootPath${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}
