/// Runfiles resolution helper.
///
/// Thin wrapper over `package:runfiles` that returns null (instead of
/// throwing) when not running inside a Bazel runfiles tree — useful for
/// call sites that want a friendly error message rather than a stack
/// trace.
///
/// Runfile keys must use the **apparent repo name** (e.g.
/// `rules_flutter/tools/macos_screenshot/screenshot`), not the canonical
/// name (e.g. `_main/...` or `rules_flutter+/...`). `package:runfiles`
/// consults `_repo_mapping` to translate apparent → canonical, so the
/// same key works whether rules_flutter is the main module or a Bzlmod
/// dep of a downstream project.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Canonical Bazel repo name of the binary this code is compiled into,
/// e.g. `_main` when rules_flutter is the main module or `rules_flutter+`
/// when it's a Bzlmod dep. Threaded in at compile time via a `-D` define
/// set by the `dart_binary` BUILD target — `Label(":target").workspace_name`
/// is evaluated at load time, then passed through `defines`.
///
/// Defaults to the empty string under plain `dart test` / `dart pub`, which
/// is fine because those workflows don't reach runfiles lookups.
const String _runfilesSourceRepository = String.fromEnvironment(
  'RUNFILES_SOURCE_REPO',
  defaultValue: '',
);

/// Result of resolving a runfile alongside the manifest path used to
/// resolve it.
class ResolvedRunfile {
  final String path;
  final String? manifestPath;

  ResolvedRunfile(this.path, {this.manifestPath});
}

/// Resolve a runfile path, returning null if runfiles are not available
/// or the entry is missing.
String? resolveRunfile(String path) => resolveRunfileWithManifest(path)?.path;

/// Resolve a runfile path and return both the resolved path and the
/// manifest path (when one is in use). The manifest path is needed when
/// spawning a `py_binary` subprocess so it can find its own runfiles via
/// `RUNFILES_MANIFEST_FILE`.
ResolvedRunfile? resolveRunfileWithManifest(String path) {
  // On Windows, Bazel py_binary produces .exe — try both the given key and
  // key.exe so callers don't need to hardcode platform-specific extensions.
  final keys = Platform.isWindows && !path.endsWith('.exe')
      ? [path, '$path.exe']
      : [path];

  final Runfiles r;
  try {
    r = Runfiles.create(sourceRepository: _runfilesSourceRepository);
  } on StateError {
    // Not running inside a Bazel runfiles tree (e.g. `dart run`).
    return null;
  }

  final manifestPath = _activeManifestPath();
  for (final key in keys) {
    final resolved = r.rlocation(key);
    if (File(resolved).existsSync()) {
      return ResolvedRunfile(resolved, manifestPath: manifestPath);
    }
  }
  return null;
}

/// Return the path Bazel set via `RUNFILES_MANIFEST_FILE`, or probe for a
/// manifest next to the running executable. Returns null when only a
/// runfiles directory is in use (Unix default) — callers that spawn a
/// `py_binary` subprocess should treat that as "no manifest needs
/// forwarding"; the directory tree will be inherited via `RUNFILES_DIR`.
String? _activeManifestPath() {
  final env = Platform.environment['RUNFILES_MANIFEST_FILE'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) return env;

  final exe = Platform.executable;
  for (final candidate in [
    '$exe.runfiles_manifest',
    '$exe.exe.runfiles_manifest',
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
