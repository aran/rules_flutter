/// Fails when an e2e module is in no CI workflow without a recorded reason.
///
/// Run from the repo root with no arguments (CI runs it as a job step):
/// `bazel run //tools/check_e2e_coverage`.
///
/// A module is any directory holding a `MODULE.bazel`, at `e2e/*/` or one
/// level deeper (`e2e/_overlay_tests/*/`). A module counts as covered when a
/// workflow under `.github/workflows/` references its leaf name outside of
/// comments, either as `working-directory: e2e/<leaf>`, a `workspace: <leaf>`
/// matrix entry, or a `WORKSPACES:` list token. Anything else must appear in
/// [uncoveredReasons] with a one-line reason saying why it has no workflow.
/// A reason for a module that IS covered is also an error, so the table
/// cannot go stale: removing a module from every workflow without recording
/// why fails this check.
library;

import 'dart:io';

import 'coverage.dart';

void main() {
  // Locate the repo root. BUILD_WORKSPACE_DIRECTORY is set by `bazel run`.
  final rootPath =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  if (!File('$rootPath/MODULE.bazel').existsSync() ||
      !Directory('$rootPath/e2e').existsSync()) {
    stderr.writeln('error: run //tools/check_e2e_coverage from the repo root');
    exit(2);
  }
  final modules = findE2eModules(Directory('$rootPath/e2e'), rootPath);
  final covered = findCoveredModules(Directory('$rootPath/.github/workflows'));
  final errors = checkCoverage(
    modules: modules,
    covered: covered,
    reasons: uncoveredReasons,
  );
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('error: $error');
    }
    exit(1);
  }
  final coveredCount = modules
      .where((m) => covered.contains(leafName(m)))
      .length;
  print(
    'ok: $coveredCount e2e modules covered by workflows, '
    '${uncoveredReasons.length} with recorded reasons',
  );
}
