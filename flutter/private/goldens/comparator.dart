// Golden-file comparator for tests run by the `flutter_test` rule.
//
// Flutter installs `TrivialComparator` as a sentinel meaning "no tool has
// bootstrapped this test": its `compare()` prints "Golden file comparison
// requested ...; skipping..." and returns true unconditionally. Without a real
// comparator installed, every golden assertion passes while comparing
// nothing.
//
// `flutter test` never leaves it in place. The tool writes a bootstrap and
// installs the real comparator there — `flutter_tools`'
// `test/flutter_platform.dart` emits, inside the `RemoteListener.start`
// callback and only when the suite depends on `package:flutter_test`:
//
//     goldenFileComparator = LocalFileComparator(Uri.parse('$testUrl'));
//     autoUpdateGoldenFiles = $updateGoldens;
//
// `flutter_test` generates its own bootstrap, so the same two lines go in at
// the same point — see `make_bootstrap_content` in
// `flutter/private/flutter_test.bzl`. `flutter_test_config.dart` is upstream's
// *user override* hook, applied after the tool has installed a default; it is
// not the install mechanism, and using it as one would leave the silent skip
// as the default for anyone who forgot to wire it.
//
// Four things differ under Bazel, and this subclass is exactly those four:
//
//   1. **Diffs must land in the undeclared-outputs dir.** A sandboxed test's
//      working tree is deleted when it exits, so upstream's
//      `<basedir>/failures/` is gone before anyone can look. Bazel archives
//      `TEST_UNDECLARED_OUTPUTS_DIR` to `bazel-testlogs/<target>/test.outputs/`
//      instead, so the bytes go there and the "Failure feedback can be found
//      at" hint names that path rather than the dead sandbox one.
//   2. **`update()` must reach the source tree.** A test action cannot write
//      to it, so regeneration is a `bazel run` and the destination comes from
//      `BUILD_WORKSPACE_DIRECTORY`, which only `bazel run` sets.
//   3. **Update mode arrives by environment, not by codegen.** Upstream bakes
//      `autoUpdateGoldenFiles = true` into a bootstrap it regenerates per run;
//      here the bootstrap is a build artifact shared by every run of the
//      target, so the flag has to cross the process boundary at runtime.
//   4. **A golden may be listed in a runfiles manifest, not present in a
//      tree.** Bazel on Windows makes no tree by default, so a declared golden
//      is found by its runfiles path in `RUNFILES_MANIFEST_FILE` instead.
//
// Everything else — the basedir convention, the "non-existent file" failure,
// the four diff PNGs, the pixel-percentage message — is inherited unchanged,
// so `matchesGoldenFile('goldens/x.png')` means the same thing it means under
// `flutter test`.
//
// Imports only `package:flutter_test` and `dart:*`. Staged next to the
// generated bootstrap by `flutter_test` and imported from it by basename, the
// same way `dev_tool_support/agent.dart` reaches an application's kernel. The
// integration test runner's golden service (`service.dart`) imports it by path,
// to compare for a test that runs in an app: see `BazelGoldenFileComparator.forTest`.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Installs the comparator, and sets `autoUpdateGoldenFiles` from the
/// environment.
///
/// Called from the generated bootstrap inside `RemoteListener.start`, which is
/// where `flutter test` installs its own — before the user's `main` registers
/// any test, and before a `flutter_test_config.dart`-style hook would run, so
/// a test that replaces `goldenFileComparator` itself still wins.
void installBazelGoldenFileComparator() {
  final env = Platform.environment;

  // Whoever starts the process sets these two: Bazel's test rule for a
  // `flutter_test`, the integration test's host for its golden service (which
  // is a `flutter_test` comparing for another test, so the comparator a
  // `flutter_test_config.dart` finds installed is rooted at that test).
  final testPath = env['FLUTTER_TEST_PATH'];
  if (testPath == null || testPath.isEmpty) {
    throw StateError(
      'flutter_test: FLUTTER_TEST_PATH is not set, so the golden comparator '
      'has no test file to root itself at. The rule always sets it; this '
      'means the test was launched by something other than the flutter_test '
      'runner.',
    );
  }

  final update = env['FLUTTER_TEST_UPDATE_GOLDENS'] == '1';
  goldenFileComparator = BazelGoldenFileComparator.forTest(
    testPath,
    environment: env,
    update: update,
  );
  autoUpdateGoldenFiles = update;
}

/// The runfiles manifest the test runs with, as runfiles path to real path, or
/// null when there is none: Bazel then made a tree, and the working directory
/// is its root.
Map<String, String>? _manifestOf(Map<String, String> env) {
  final path = env['RUNFILES_MANIFEST_FILE'];
  if (path == null || path.isEmpty) return null;
  final file = File(path);
  if (!file.existsSync()) return null;
  final manifest = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final space = line.indexOf(' ');
    if (space > 0)
      manifest[line.substring(0, space)] = line.substring(space + 1);
  }
  return manifest;
}

/// The runfiles path of the test source whose `short_path` is [testPath]:
/// `../repo/x` is `repo/x`, and anything else is under [workspace], the main
/// repository's name (`TEST_WORKSPACE`). Null when that name is not known.
String? _runfilesPathOf(String? workspace, String testPath) {
  if (testPath.startsWith('../')) return testPath.substring(3);
  if (workspace == null || workspace.isEmpty) return null;
  return '$workspace/$testPath';
}

/// `TEST_TARGET` (`//pkg:name`) as `bazel-testlogs/pkg/name/test.outputs/`.
///
/// Display only: it is the path a developer types after the run, once Bazel
/// has archived the undeclared outputs out of the sandbox. Null when
/// `TEST_TARGET` is unset — `bazel run` on a test target is not obliged to set
/// it — in which case the hint falls back to the real directory.
Uri? _failureHintDirOf(String? testTarget) {
  if (testTarget == null || testTarget.isEmpty) return null;
  final label = testTarget.startsWith('//')
      ? testTarget.substring(2)
      : testTarget;
  final segments = label.split(':').where((s) => s.isNotEmpty);
  if (segments.isEmpty) return null;
  return Uri.parse('bazel-testlogs/${segments.join('/')}/test.outputs/');
}

/// A directory path from the environment as a directory `Uri`, or null.
///
/// `Directory.uri` is what makes this platform-correct: it appends the
/// trailing slash `Uri.resolve` needs and turns a Windows `C:\x` into
/// `file:///C:/x/`, so every join below is plain URI arithmetic.
Uri? _dirUri(String? path) {
  if (path == null || path.isEmpty) return null;
  return Directory(path).uri;
}

/// Where `update()` writes: the test file's directory in the *source* tree.
///
/// The same relative position the comparator reads from, but rooted at the
/// workspace instead of at runfiles, so a regenerated PNG lands beside the
/// test where the next build will pick it up from `data`.
Uri _updateDirOf(Map<String, String> env, String testPath) {
  final workspace = env['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null || workspace.isEmpty) {
    throw StateError(
      'flutter_test: golden update was requested but BUILD_WORKSPACE_DIRECTORY '
      'is not set, so there is no source tree to write to. Regenerate goldens '
      'with `bazel run //<pkg>:<target> -- --update-goldens`.',
    );
  }
  if (testPath.startsWith('../')) {
    throw StateError(
      'flutter_test: cannot update goldens for a test in an external '
      'repository ($testPath). Its sources are not in this workspace, so '
      'there is nowhere here to write them.',
    );
  }
  // `resolve(testPath)` lands on the test file; `resolve('.')` steps back to
  // its directory, which is the basedir goldens are relative to.
  return Directory(workspace).uri.resolve(testPath).resolve('.');
}

/// `LocalFileComparator` with Bazel's three differences and nothing else.
///
/// Deliberately a subclass rather than a reimplementation: `compare()`'s
/// decode-and-diff logic, the "non-existent file" failure, and the message
/// format all stay upstream's, so a Flutter developer reads the same output
/// here that they read from `flutter test`.
class BazelGoldenFileComparator extends LocalFileComparator {
  /// Creates a comparator rooted at [testFile]'s directory in runfiles.
  ///
  /// [outputsDir] is `TEST_UNDECLARED_OUTPUTS_DIR`, where diff PNGs are
  /// written; [failureHintDir] is the archived location to *name* in the
  /// failure message; [updateDir] is the source-tree directory `update()`
  /// writes to, and null when not regenerating. All three fall back to
  /// upstream's behaviour when null.
  BazelGoldenFileComparator(
    super.testFile, {
    Uri? outputsDir,
    Uri? failureHintDir,
    Uri? updateDir,
    Map<String, String>? manifest,
    String? testRunfilesPath,
  }) : _outputsDir = outputsDir,
       _failureHintDir = failureHintDir,
       _updateDir = updateDir,
       _manifest = manifest,
       _testRunfilesPath = testRunfilesPath;

  /// The comparator for the test whose source has the `short_path` [testPath],
  /// as a test run by Bazel with [environment] needs it, regenerating goldens
  /// into the source tree when [update].
  ///
  /// [environment] is the test's own: where its undeclared outputs go, which
  /// runfiles it has and, under `bazel run`, the source tree. The process that
  /// compares need not be the test: the integration test runner's golden
  /// service compares for a test that runs in an app, with the environment of
  /// the Bazel test it serves.
  factory BazelGoldenFileComparator.forTest(
    String testPath, {
    required Map<String, String> environment,
    required bool update,
  }) {
    final env = environment;
    return BazelGoldenFileComparator(
      // `Uri.base` is the runfiles workspace root (the runner leaves the
      // tester's working directory there) and `FLUTTER_TEST_PATH` is the test
      // source's `short_path`, so this resolves to the test file — and
      // `LocalFileComparator` roots goldens at its *directory*. That is
      // upstream's whole convention: `matchesGoldenFile('goldens/x.png')` reads
      // `<dir of the test file>/goldens/x.png`.
      //
      // Under the sandbox that directory holds only what the target declared, so
      // a golden that exists in the source tree but was never added to `data`
      // fails as "non-existent" rather than being read behind Bazel's back. That
      // is the property that keeps a cached result honest, and it is why no
      // "find the workspace and read from there" shortcut belongs here.
      Uri.base.resolve(testPath),
      outputsDir: _dirUri(env['TEST_UNDECLARED_OUTPUTS_DIR']),
      failureHintDir: _failureHintDirOf(env['TEST_TARGET']),
      updateDir: update ? _updateDirOf(env, testPath) : null,
      manifest: _manifestOf(env),
      testRunfilesPath: _runfilesPathOf(env['TEST_WORKSPACE'], testPath),
    );
  }

  /// The path of the golden `update()` wrote last, or null if it has written
  /// none: what a caller that is not the test can report.
  String? lastWritten;

  final Uri? _outputsDir;
  final Uri? _failureHintDir;
  final Uri? _updateDir;

  /// The runfiles manifest, when Bazel made one and no tree: golden paths are
  /// listed in it, relative to [_testRunfilesPath], and exist only at the real
  /// paths it names.
  final Map<String, String>? _manifest;
  final String? _testRunfilesPath;

  /// A golden's bytes, wherever the runfiles put it.
  ///
  /// The file under the basedir when there is one. Failing that, the file the
  /// manifest names for it. A golden found by neither is upstream's
  /// "non-existent file" failure, which this passes through to unchanged.
  @override
  Future<List<int>> getGoldenBytes(Uri golden) {
    final manifest = _manifest;
    final test = _testRunfilesPath;
    if (manifest != null &&
        test != null &&
        !File.fromUri(basedir.resolveUri(golden)).existsSync()) {
      final key = Uri.parse(
        'file:///$test',
      ).resolve('.').resolveUri(golden).path.substring(1);
      final real = manifest[key];
      if (real != null && File(real).existsSync()) {
        return File(real).readAsBytes();
      }
    }
    return super.getGoldenBytes(golden);
  }

  /// Redirects the failure *message* to the archived output location.
  ///
  /// `generateFailureOutput` uses its `basedir` argument for exactly two
  /// things: the "Failure feedback can be found at ..." hint, and the argument
  /// it hands `getFailureFile`. `getFailureFile` is overridden below to ignore
  /// it, so passing the display path here changes only the text — which is the
  /// point. Left as the real basedir when there is no undeclared-outputs dir
  /// to redirect to, because then upstream's answer is already right.
  @override
  Future<String> generateFailureOutput(
    ComparisonResult result,
    Uri golden,
    Uri basedir, {
    String key = '',
  }) => super.generateFailureOutput(
    result,
    golden,
    _outputsDir == null ? basedir : (_failureHintDir ?? _outputsDir!),
    key: key,
  );

  /// Writes diff PNGs under `TEST_UNDECLARED_OUTPUTS_DIR/failures/`.
  ///
  /// Bazel archives that directory to `bazel-testlogs/<target>/test.outputs/`
  /// after the test exits. Upstream's default — `<basedir>/failures/` — is
  /// inside the sandbox, which is deleted before anyone can read it.
  @override
  File getFailureFile(String failure, Uri golden, Uri basedir) {
    final outputs = _outputsDir;
    if (outputs == null) return super.getFailureFile(failure, golden, basedir);
    final name = golden.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    return File.fromUri(outputs.resolve('failures/${stem}_$failure.png'));
  }

  /// Writes a regenerated golden into the source tree.
  ///
  /// Reached only when `autoUpdateGoldenFiles` is set, which only
  /// `--update-goldens` under `bazel run` does. `LocalFileComparator.update`
  /// would write into runfiles, where the file is an input Bazel replaces on
  /// the next build — the update would appear to work and change nothing.
  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {
    final dir = _updateDir;
    if (dir == null) {
      throw StateError(
        'flutter_test: a golden update reached the comparator without an '
        'update destination. Regenerate goldens with '
        '`bazel run //<pkg>:<target> -- --update-goldens`.',
      );
    }
    final target = File.fromUri(dir.resolveUri(golden));
    await target.parent.create(recursive: true);
    await target.writeAsBytes(imageBytes, flush: true);
    lastWritten = target.path;
    // Named on stderr because the run is otherwise silent about it: a golden
    // update reports as a passing test, and "which files did that rewrite" is
    // the one thing the developer needs before committing.
    stderr.writeln('flutter_test: wrote golden ${target.path}');
  }
}
