/// Path-spoke hermeticity guard: a `flutter.pub` path-spoke fetch must
/// never write, create, delete, or chmod anything outside the spoke's own
/// repository directory.
///
/// The `path_probe` fixture package carries everything that used to break
/// that rule: an `android/` directory with a user-owned `BUILD.bazel`
/// holding a sentinel, a declared shader, an `example/` app holding a
/// `.plugin_symlinks` cycle back to the package root and a stale
/// `example/build/` shader, plus `build/` and `.dart_tool/` state.
/// `path_probe_no_build` is the same shape with an `android/` directory
/// but no user `BUILD.bazel` in it, so a write-through fetch creates one.
///
/// The `data` deps on `@deps//:path_probe` and `@deps//:path_probe_no_build`
/// force both spokes to fetch and load before this test runs: on a broken
/// spoke the run fails there (the cycle breaks the whole-tree shader glob,
/// or the fetch writes through). This test then pins the source tree
/// itself: the sentinel still intact, and no `BUILD.bazel` created where
/// the user had none. It also pins the danger files present, so a deleted
/// fixture fails loudly instead of passing vacuously.
///
/// Like the repo's static guards, this test discovers its inputs at runtime
/// from the workspace root (found through `BUILD_WORKSPACE_DIRECTORY` when
/// set, else the test's own anchor in `data` resolved through the runfiles
/// library, hence no-sandbox), and
/// is tagged `external` so Bazel re-runs it on every invocation instead of
/// replaying a cached pass after an untracked source file changed.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Sentinel carried by `path_probe/android/BUILD.bazel`, the user-owned
/// file a write-through fetch overwrites.
const _sentinel = 'PATH-PROBE-USER-ANDROID-SENTINEL';

/// Whether [root] is the hello_world workspace root.
bool _looksLikeRoot(String root) =>
    File('$root/MODULE.bazel').existsSync() &&
    File('$root/path_probe/pubspec.yaml').existsSync();

/// Workspace root the test walks: `BUILD_WORKSPACE_DIRECTORY` when set,
/// otherwise the test's own anchor in `data` resolved through the runfiles
/// library (an unsandboxed runfiles tree symlinks it into the source tree;
/// the root is the first ancestor that looks like the workspace). Null when
/// neither resolves, so the test fails loudly instead of checking the wrong
/// tree or silently passing.
String? _workspaceRoot() {
  final fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  if (anchor != null && anchor.isNotEmpty) {
    // Resolve the anchor through the runfiles library rather than
    // guessing paths: that works under both the Unix symlink tree and
    // the Windows manifest (windows-latest runs with --noenable_runfiles,
    // so no TEST_SRCDIR directory exists). The manifest maps the anchor
    // to the source path; elsewhere resolve the symlink the same way.
    // An unresolvable anchor throws here, loudly, instead of checking
    // the wrong tree.
    final resolved = Runfiles.create().rlocation(anchor);
    try {
      var dir = File(File(resolved).resolveSymbolicLinksSync()).parent;
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

/// Any filesystem entity at [path]: file, directory, link, or dangling
/// link. `File.existsSync` follows links, so only this sees a dangling
/// `BUILD.bazel` symlink a fetch could leave behind.
bool _entityExists(String path) =>
    FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

void main() {
  late String root;

  setUpAll(() {
    final found = _workspaceRoot();
    if (found == null) {
      throw StateError(
        'hello_world workspace root not found: set BUILD_WORKSPACE_DIRECTORY '
        'or run unsandboxed with the test source in data',
      );
    }
    root = found;
  });

  test('user android BUILD keeps its sentinel (no overwrite)', () {
    final userBuild = File('$root/path_probe/android/BUILD.bazel');
    expect(
      userBuild.existsSync(),
      isTrue,
      reason: 'fixture file missing: $userBuild',
    );
    expect(
      userBuild.readAsStringSync(),
      contains(_sentinel),
      reason:
          'path_probe/android/BUILD.bazel lost its sentinel: the spoke '
          'fetch wrote its generated file through the symlinked android/ '
          'directory into the source tree',
    );
  });

  test('no android BUILD is created where the user had none', () {
    final created = '$root/path_probe_no_build/android/BUILD.bazel';
    expect(
      _entityExists(created),
      isFalse,
      reason:
          '$created exists: the spoke fetch created its generated '
          'android/BUILD.bazel inside the source tree, adding a main-repo '
          'package whose rules_kotlin load breaks bazel query //...',
    );
  });

  test('danger files are present (the checks are not vacuous)', () {
    final danger = [
      // .plugin_symlinks cycle back to the package root, as `flutter pub
      // get` leaves it in example/.
      '$root/path_probe/example/.plugin_symlinks/path_probe',
      '$root/path_probe_no_build/example/.plugin_symlinks/path_probe_no_build',
      // Stale example/build shader output matching the old "**" glob.
      '$root/path_probe/example/build/stale.frag',
      '$root/path_probe_no_build/example/build/stale.frag',
      // Machine-local state the spoke must not descend into.
      '$root/path_probe/.dart_tool/package_config.json',
      '$root/path_probe/build/output.txt',
    ];
    for (final path in danger) {
      expect(
        _entityExists(path),
        isTrue,
        reason: 'fixture danger file missing, checks are vacuous: $path',
      );
    }
  });
}
