/// Repoints a dev `package_config.json` at Bazel's repository tree.
///
/// A build-emitted dev package_config names third-party packages relatively:
///
/// ```json
/// {"name": "flutter", "rootUri": "../../../external/rules_flutter++flutter+deps__flutter"}
/// ```
///
/// Resolved from where that file lives (`bazel-out/<config>/bin/`), those three
/// `..` steps land on `<output_base>/execroot/_main/external/<repo>` — an entry
/// in the symlink forest Bazel plants per command, holding only the
/// repositories *that* command needed. Bazel re-plants the forest on every
/// command, so any concurrent Bazel invocation deletes those symlinks while a
/// live frontend_server is reading through them, and the compile fails on a
/// source file that is not missing at all.
///
/// Every repository the forest points *at* lives at `<output_base>/external/`,
/// and that tree is not per-command — Bazel neither prunes nor re-plants it
/// between builds. So each `file:` root is rewritten to name the repository
/// tree directly. The rewrite is pure path arithmetic — deleting an
/// `execroot/<name>/` pair from the middle of an already-resolved path —
/// rather than reading the symlink, because reading it is the very thing that
/// races: a `resolveSymbolicLinks` at session start can land in the same
/// window and throw.
///
/// Roots in the app's own `--filesystem-scheme` (`org-dartlang-app:///…`) are
/// left exactly as they are. They address live source through the compiler's
/// multi-root machinery, not the filesystem, and rewriting one would break the
/// mixed-scheme resolution the source-assembled dev loop is built on.
///
/// This covers third-party sources only. The app's own generated sources are
/// read out of `bazel-out`, which Bazel deletes before re-running the action
/// that writes them, and there is no second copy of those to point at.
///
/// One residual race is known and left: resolving the config's own directory
/// traverses the workspace `bazel-out` convenience symlink, which Bazel also
/// rewrites per command. A peer command landing on exactly that instant makes
/// this throw.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'dev_tool_exception.dart';

/// Where [stabilizePackageRoots] wrote its copy, and what it changed.
class StabilizedPackageConfig {
  /// Absolute path of the rewritten package_config to hand the compiler.
  final String path;

  /// Package names whose root was rewritten: made absolute, and moved off the
  /// per-command execroot where it ran through one. Empty is a legitimate
  /// outcome — a config whose roots are all `org-dartlang-app:` has nothing to
  /// rewrite — so callers report this rather than treating it as a failure.
  final List<String> repointed;

  const StabilizedPackageConfig({required this.path, required this.repointed});
}

/// Write a copy of [packageConfigPath] into [into] whose `file:` package roots
/// name Bazel's repository tree rather than the per-command execroot forest.
///
/// The build-emitted original is never modified.
StabilizedPackageConfig stabilizePackageRoots(
  String packageConfigPath, {
  required Directory into,
}) {
  final source = File(packageConfigPath);
  if (!source.existsSync()) {
    throw DevToolException(
      'The build-emitted dev package config is missing: $packageConfigPath',
    );
  }
  final decoded = json.decode(source.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw DevToolException(
      'Expected a JSON object in $packageConfigPath, got ${decoded.runtimeType}.',
    );
  }
  final packages = decoded['packages'];
  if (packages is! List) {
    throw DevToolException('Expected a "packages" list in $packageConfigPath.');
  }

  // The directory the relative roots resolve against, with its own symlinks
  // already followed. This is `bazel-out/<config>/bin`, which is an ordinary
  // directory inside the output base — resolving it does not touch the forest,
  // and doing it once here is what makes the per-package work pure arithmetic.
  final base = Directory(
    p.dirname(packageConfigPath),
  ).resolveSymbolicLinksSync();

  final repointed = <String>[];
  for (final entry in packages) {
    if (entry is! Map<String, dynamic>) continue;
    final rootUri = entry['rootUri'];
    if (rootUri is! String) continue;
    final moved = _repointRoot(rootUri, base: base);
    if (moved == null) continue;
    entry['rootUri'] = moved;
    repointed.add(entry['name'] as String? ?? '<unnamed>');
  }

  final out = File(p.join(into.path, 'dev_package_config.json'));
  out.writeAsStringSync(json.encode(decoded));
  return StabilizedPackageConfig(path: out.path, repointed: repointed);
}

/// The rewritten form of [rootUri], or null to leave it exactly as it is.
///
/// Null means one thing only: a root in the app's own filesystem scheme
/// (`org-dartlang-app:///…`), which addresses live source through the
/// compiler's multi-root machinery rather than the filesystem.
///
/// Every other root comes back **absolute**, whether or not it ran through an
/// execroot. That is not incidental. The rewritten config is written to a
/// different directory from the build-emitted one, so a relative root carried
/// over unchanged would silently re-anchor to the new directory.
String? _repointRoot(String rootUri, {required String base}) {
  final parsed = Uri.parse(rootUri);
  if (parsed.hasScheme && parsed.scheme != 'file') return null;

  final asPath = parsed.scheme == 'file' ? parsed.toFilePath() : rootUri;
  // `..` in a package root is resolved by the OS against real directories, so
  // normalizing against the already-resolved [base] gives the same answer the
  // compiler would have reached — without following the symlink at the end.
  final resolved = p.normalize(
    p.isAbsolute(asPath) ? asPath : p.join(base, asPath),
  );
  final stable = _dropExecroot(resolved) ?? resolved;

  if (!Directory(stable).existsSync()) {
    throw DevToolException(
      'The package root $rootUri in the build-emitted dev package config '
      'resolves to $stable, which does not exist. The dev loop reads package '
      'sources through this path, so a compile against it would fail on '
      'every library in that package.',
    );
  }
  return p.toUri(stable).toString();
}

/// `<output_base>/execroot/<name>/external/<repo>` → `<output_base>/external/<repo>`.
///
/// Null when [path] has no `execroot/<name>/external/` in it. Both segments are
/// required together: `external/` alone is not evidence of the forest, and it
/// is the pairing that makes the repository tree the thing being named.
String? _dropExecroot(String path) {
  final parts = p.split(path);
  for (var i = 0; i + 2 < parts.length; i++) {
    if (parts[i] == 'execroot' && parts[i + 2] == 'external') {
      return p.joinAll([...parts.sublist(0, i), ...parts.sublist(i + 2)]);
    }
  }
  return null;
}
