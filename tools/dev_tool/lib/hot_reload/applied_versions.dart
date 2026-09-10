/// Per-file record of "what's currently live in the running app."
///
/// The reload pipeline asks `findChangedFrom(currentSnapshot)` to decide
/// what to recompile, and calls `markApplied(snapshot, files: ...)` after
/// a successful apply. Per-file state — never a single global timestamp.
import 'workspace.dart';

class AppliedVersions {
  final Map<String, Version> _applied = {};

  AppliedVersions();

  /// A copy of [other]'s record at this moment.
  ///
  /// How per-app state is seeded from a shared baseline: each app starts out
  /// knowing exactly what the baseline knew, and diverges from there.
  AppliedVersions.from(AppliedVersions other) {
    _applied.addAll(other._applied);
  }

  /// Files in [disk] whose `Version` differs from the version we last
  /// marked applied (or for which we have no record).
  ///
  /// A file present on disk but not yet applied counts as changed.
  Set<String> findChangedFrom(SourceVersions disk) {
    final changed = <String>{};
    for (final uri in disk.fileUris) {
      if (_applied[uri] != disk.versionOf(uri)) {
        changed.add(uri);
      }
    }
    return changed;
  }

  /// Record that [files] are now live at the versions captured in [snapshot].
  ///
  /// Files in [files] but missing from [snapshot] are ignored — they were
  /// declared by a caller (agent/IDE hint) without backing FS state, and
  /// we have nothing to record. Subsequent disk-based comparisons will
  /// correctly treat them as unknown until they reappear in a snapshot.
  void markApplied(SourceVersions snapshot, {required Set<String> files}) {
    for (final f in files) {
      final v = snapshot.versionOf(f);
      if (v != null) _applied[f] = v;
    }
  }

  /// Seed the baseline from the source the running app was built from.
  ///
  /// The distinction from `markApplied(snapshot, files: everything)`: assembly
  /// runs a bazel build and starts a frontend server while the app is already
  /// up and answering commands, so disk can move under it. A file whose content
  /// arrived after [builtBefore] cannot be what
  /// the app is running, and seeding it would record an edit as already-live —
  /// the first reload would then find nothing to do and the app would go on
  /// running the version it launched with.
  ///
  /// [builtBefore] is captured before the build that produced the app: `run`
  /// takes it before building the launch target, `attach` at command start. An
  /// edit made between an attached app's real build and that moment is not
  /// knowable from here, and is not treated as one.
  ///
  /// [generated] — the build-emitted sources, by `package:` URI — is seeded
  /// whatever its mtime says. Those files are written by the dev build *inside*
  /// assembly, so they are always newer than any cutoff, and the initial
  /// compile consumed exactly the versions in [snapshot].
  void seedFromBuild(
    SourceVersions snapshot, {
    required DateTime builtBefore,
    required Set<String> generated,
  }) {
    final files = <String>{};
    for (final uri in snapshot.fileUris) {
      // `isBefore`, not `!isAfter`: a file stamped exactly at the cutoff is
      // ambiguous, and the two ways of being wrong are not equal. Treating it
      // as changed costs a recompile of content the app already has; treating
      // it as applied drops the user's edit silently.
      if (generated.contains(uri) ||
          snapshot.versionOf(uri)!.mtime.isBefore(builtBefore)) {
        files.add(uri);
      }
    }
    markApplied(snapshot, files: files);
  }

  /// Forget every applied version. Next `findChangedFrom` returns the
  /// full disk snapshot. Used by hot restart.
  void clear() => _applied.clear();

  /// For diagnostics/tests.
  Version? versionOf(String fileUri) => _applied[fileUri];

  /// Number of files we currently consider applied.
  int get length => _applied.length;
}
