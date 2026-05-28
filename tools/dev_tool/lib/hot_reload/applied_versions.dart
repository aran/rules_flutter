/// Per-file record of "what's currently live in the running app."
///
/// The reload pipeline asks `findChangedFrom(currentSnapshot)` to decide
/// what to recompile, and calls `markApplied(snapshot, files: ...)` after
/// a successful apply. Per-file state — never a single global timestamp.
import 'workspace.dart';

class AppliedVersions {
  final Map<String, Version> _applied = {};

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

  /// Forget every applied version. Next `findChangedFrom` returns the
  /// full disk snapshot. Used by hot restart.
  void clear() => _applied.clear();

  /// For diagnostics/tests.
  Version? versionOf(String fileUri) => _applied[fileUri];

  /// Number of files we currently consider applied.
  int get length => _applied.length;
}
