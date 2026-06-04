/// Read-only view of a build's first-party Dart source tree.
///
/// `Workspace.snapshot()` is a fresh FS scan of every source package's `lib/`
/// (resolved via [PackageUriResolver]) plus any registered generated files;
/// `SourceVersions` is the resulting immutable `{packageUri → Version}` map.
import 'dart:io';

import 'package_uri_resolver.dart';

/// A point-in-time identity for a file's content.
///
/// We track `(mtime, size)` rather than mtime alone: identical mtime with
/// changed size catches the rare case where a write completes within the
/// FS's mtime resolution. We don't hash — that would defeat the speed
/// reason we use mtime in the first place.
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
  String toString() =>
      'Version(mtime=${mtime.toIso8601String()}, size=$size)';
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
