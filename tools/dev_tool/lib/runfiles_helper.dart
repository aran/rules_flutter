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

/// Pin what this process knows about where it runs from, while the path it
/// was launched through still leads there. Called first thing in `main`.
///
/// Launched as `./bazel-bin/.../flutter_bazel` — the usual build-then-run
/// form — that path goes through the `bazel-bin` convenience symlink, and the
/// run's own `-c dbg` app build repoints `bazel-bin` at a tree with no
/// flutter_bazel in it. Two things read the launch path lazily, and both broke
/// once it had moved:
///
///  * `Platform.resolvedExecutable`, which dart:io resolves on first read and
///    keeps only once a read succeeds. DDS reads it for every websocket client
///    it accepts (the debug adapter it hosts per client), so its first read
///    came after the repoint and threw `type 'Null' is not a subtype of type
///    'String'` inside DDS's error zone, which swallows it. Every client hung,
///    this tool's own VM service connection first: five 30-second attempts,
///    then "No VM service connection on macOS".
///  * The runfiles lookups below, which probed next to `Platform.executable`
///    on every call and found nothing once it had moved: "Could not find
///    bundled macOS screenshot tool".
///
/// Both are read here once and kept. Each has to be found before the move,
/// because finding it goes through the launch path; once found, each is held
/// by its real path, so it keeps working after the move: the runfiles
/// directory by `Runfiles.create` itself, the manifest by
/// [_activeManifestPath].
void pinProcessLocation() {
  Platform.resolvedExecutable.length;
  _runfiles;
  _manifestPath;
}

/// This process's runfiles, created once: on the first lookup, or in
/// [pinProcessLocation] before anything can move. Null outside a runfiles tree
/// (`dart run` from a source checkout).
final Runfiles? _runfiles = () {
  try {
    return Runfiles.create(sourceRepository: _runfilesSourceRepository);
  } on StateError {
    return null;
  }
}();

/// [_activeManifestPath], found once for the same reason as [_runfiles].
final String? _manifestPath = _activeManifestPath();

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

/// Whether this process is running inside a Bazel runfiles tree at all.
///
/// [resolveRunfile] returns null for two different situations, and a caller
/// that must fail loudly on one of them needs to tell them apart:
///
///  * **No runfiles tree.** The tool was launched by `dart run` from a source
///    checkout — a supported contributor workflow. Bundled data simply is not
///    part of that world, and its absence is not an error.
///  * **Runfiles present, entry missing.** A declared `data` dependency did
///    not make it into the tree. That is a build defect and should be fatal.
bool get hasRunfilesContext => _runfiles != null;

/// Resolve a runfile path and return both the resolved path and the
/// manifest path (when one is in use). The manifest path is needed when
/// spawning a `py_binary` subprocess so it can find its own runfiles via
/// `RUNFILES_MANIFEST_FILE`.
ResolvedRunfile? resolveRunfileWithManifest(String path) {
  // On Windows, Bazel py_binary produces .exe — try both the given key and
  // key.exe so callers don't need to hardcode platform-specific extensions.
  //
  // `.exe` FIRST, because a `py_binary` emits *both* launchers side by side:
  // `screenshot` (the POSIX shell wrapper) and `screenshot.exe`. The bare key
  // resolves to the shell script, which exists, so resolution succeeds and the
  // spawn fails instead — `ProcessException: %1 is not a valid Win32
  // application`, which reads as a corrupt binary rather than the wrong one.
  final keys = Platform.isWindows && !path.endsWith('.exe')
      ? ['$path.exe', path]
      : [path];

  // Null when not running inside a Bazel runfiles tree (e.g. `dart run`).
  final r = _runfiles;
  if (r == null) return null;

  final manifestPath = _manifestPath;
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
///
/// The two probe candidates mirror `Runfiles.create` in
/// `@rules_dart//dart/runfiles`, which cannot be reused here because it
/// returns a resolver rather than the manifest path this needs to forward.
/// If rules_dart's candidates change, this copy has to change with them —
/// there is nothing that would report the drift.
String? _activeManifestPath() {
  final env = Platform.environment['RUNFILES_MANIFEST_FILE'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) return env;

  final exe = Platform.executable;
  for (final candidate in [
    '$exe.runfiles_manifest',
    '$exe.exe.runfiles_manifest',
  ]) {
    // Resolved for the same reason `Runfiles.create` resolves the runfiles
    // directory: the probe went through the launch path, which can move, and
    // this path is forwarded to helpers that read it later.
    if (File(candidate).existsSync()) {
      return File(candidate).resolveSymbolicLinksSync();
    }
  }
  return null;
}
