/// Read-only view of a build's first-party Dart source tree.
///
/// `Workspace.snapshot()` is a fresh FS scan of every source package's `lib/`
/// (resolved via [PackageUriResolver]) plus any registered generated files;
/// `SourceVersions` is the resulting immutable `{packageUri → Version}` map.
import 'dart:io';

import 'package_uri_resolver.dart';

/// A point-in-time identity for a file's content.
///
/// `(mtime, size)` rather than mtime alone: identical mtime with changed size
/// catches a write that completes within the FS's mtime resolution.
///
/// Not a content digest, and not because hashing is too slow — digesting a
/// first-party `lib/` costs a fraction of a millisecond against a reload that
/// costs seconds ([resolver] enumerates first-party packages only, never the
/// pub cache). The asset tracker digests for exactly that reason — see
/// `AssetTracker._scanDirs`.
///
/// What separates them is reachability. `FileStat.modified` is truncated to
/// whole milliseconds, so a same-length write can hide behind an identical
/// stamp — which is the asset tracker's case, where a rebuild rewrites the tree
/// programmatically. Hiding from *this* snapshot additionally requires the
/// snapshot to be cut between the two writes, and every path that cuts one is
/// spaced far wider than a millisecond:
///
///   - the watcher batches everything within a 200 ms debounce into one
///     `SourceChange` and only then reloads, so two writes a snapshot can land
///     between are ≥200 ms apart, and writes closer than that are one event
///     whose snapshot reads the later content;
///   - a reload asked for over HTTP or the machine protocol has a round trip
///     between the write and the scan;
///   - `generatedFiles` are rewritten by a multi-second bazel build, which
///     stamps a fresh mtime on a same-length content change.
///
/// A reload trigger that can fire within a millisecond of a write would
/// reopen this, and digesting is affordable if one ever does.
class Version {
  final DateTime mtime;
  final int size;

  Version({required this.mtime, required this.size});

  @override
  bool operator ==(Object other) =>
      other is Version && other.mtime == mtime && other.size == size;

  @override
  int get hashCode => Object.hash(mtime, size);

  @override
  String toString() => 'Version(mtime=${mtime.toIso8601String()}, size=$size)';
}

/// Immutable snapshot of every tracked source file's `Version`.
class SourceVersions {
  final Map<String, Version> _versions;

  const SourceVersions(this._versions);

  /// File URIs known to this snapshot.
  Iterable<String> get fileUris => _versions.keys;

  /// `Version` of [fileUri], or null if not in this snapshot.
  Version? versionOf(String fileUri) => _versions[fileUri];

  /// Number of files in this snapshot.
  int get length => _versions.length;
}

/// Read-only handle on a build's first-party source tree.
class Workspace {
  /// Resolves an absolute source path to its `package:` URI and enumerates the
  /// source package `lib/` directories to scan.
  final PackageUriResolver resolver;

  /// Generated files outside any scanned `lib/` (codegen outputs in bazel-out),
  /// as `{package: URI → absolute path}`. They live in the build tree, not the
  /// source tree, so they aren't found by the `lib/**` scan — but they ARE part
  /// of the app's library set, so `snapshot()` stats them too. After a rebuild
  /// refreshes a generated file, this lets the normal diff pick it up and
  /// invalidate the right library. Empty for non-codegen apps.
  final Map<String, String> generatedFiles;

  Workspace({
    required this.resolver,
    this.generatedFiles = const {},
  });

  /// Scan every source package's `lib/**/*.dart` (plus any [generatedFiles])
  /// and return a fresh snapshot, keyed by the frontend_server `package:` URI.
  SourceVersions snapshot() {
    final versions = <String, Version>{};
    for (final libDir in resolver.sourceLibDirs) {
      final dir = Directory(libDir);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final uri = resolver.toPackageUri(entity.path);
        if (uri == null) continue;
        final stat = entity.statSync();
        versions[uri] = Version(mtime: stat.modified, size: stat.size);
      }
    }
    for (final entry in generatedFiles.entries) {
      final f = File(entry.value);
      if (!f.existsSync()) continue;
      final stat = f.statSync();
      versions[entry.key] = Version(mtime: stat.modified, size: stat.size);
    }
    return SourceVersions(versions);
  }
}
