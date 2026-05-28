/// Read-only view of the workspace's `lib/**/*.dart` source tree.
///
/// `Workspace.snapshot()` is a fresh FS scan; `SourceVersions` is the
/// resulting immutable `{fileUri → Version}` map.
import 'dart:io';

import 'package:path/path.dart' as p;

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

/// Immutable snapshot of every workspace source file's `Version`.
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

/// Read-only handle on a workspace's Dart source tree.
class Workspace {
  /// Filesystem root of the workspace.
  final String root;

  /// Frontend-server entrypoint URI (e.g. `package:foo/main.dart` or
  /// `org-dartlang-app:/web_entrypoint.dart`). Determines the URI scheme
  /// used for source files in `snapshot()`.
  final String entrypoint;

  Workspace({required this.root, required this.entrypoint});

  /// Scan `<root>/lib/**/*.dart` and return a fresh snapshot.
  ///
  /// Returns an empty snapshot if `lib/` does not exist.
  SourceVersions snapshot() {
    final libDir = Directory(p.join(root, 'lib'));
    if (!libDir.existsSync()) return const SourceVersions({});
    final versions = <String, Version>{};
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final stat = entity.statSync();
      versions[toFrontendServerUri(entity.path)] =
          Version(mtime: stat.modified, size: stat.size);
    }
    return SourceVersions(versions);
  }

  /// Convert an absolute file path to the URI scheme the frontend_server
  /// expects, given this workspace's [entrypoint].
  String toFrontendServerUri(String filePath) =>
      frontendServerUriFor(filePath, entrypoint: entrypoint, root: root);
}

/// Free-function form of [Workspace.toFrontendServerUri], used by callers
/// that don't have a Workspace handle yet (legacy session.dart paths).
///
/// For `package:` entrypoints: files in `lib/` → `package:app/foo.dart`.
/// For `org-dartlang-app:` entrypoints (DDC web mode): files under root
/// → `org-dartlang-app:/lib/foo.dart` (matching the filesystem-root
/// scheme).
///
/// Falls back to `file:///` URI if the path can't be mapped.
String frontendServerUriFor(
  String filePath, {
  required String entrypoint,
  required String root,
}) {
  if (entrypoint.startsWith('package:')) {
    final libDir = p.join(root, 'lib');
    if (p.isWithin(libDir, filePath)) {
      // URI path segments are always '/'-separated, regardless of the host
      // OS path separator; rebuild the relative path from its components.
      final relativePath =
          p.split(p.relative(filePath, from: libDir)).join('/');
      final packageName =
          entrypoint.split('/').first.substring('package:'.length);
      return 'package:$packageName/$relativePath';
    }
  }
  if (entrypoint.startsWith('org-dartlang-app:') &&
      p.isWithin(root, filePath)) {
    final relativePath = p.split(p.relative(filePath, from: root)).join('/');
    return 'org-dartlang-app:/$relativePath';
  }
  return Uri.file(filePath).toString();
}
