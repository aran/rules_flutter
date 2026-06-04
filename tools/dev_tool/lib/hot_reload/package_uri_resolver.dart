/// Maps an absolute source-file path to the `package:` URI the frontend_server
/// keys that library by.
///
/// This is the single, authoritative path → URI inversion used by every reload
/// path (snapshot diff, machine-protocol invalidation, the filesystem watcher).
/// It is driven by the build-emitted `sourcePackages` map (`{name, libRoot}` per
/// first-party package) carried in `_dev_config.json` — NOT by heuristics about
/// the entrypoint scheme or the app's own `lib/`. That is what lets an edit in a
/// dependency package, an assembled (codegen) package, or the app resolve to the
/// correct `package:<name>/<rel>` URI; anything the frontend_server doesn't key
/// by `package:` (a pub dep under `external/`, a tool script) resolves to null
/// and is skipped rather than invalidated with a bogus `file://` URI.
import 'package:path/path.dart' as p;

class PackageUriResolver {
  /// Package lib directories, longest-path-first for longest-prefix matching.
  final List<({String libDir, String packageName})> _entries;

  PackageUriResolver({
    required String workspaceRoot,
    required List<({String name, String libRoot})> sourcePackages,
  }) : _entries = _build(workspaceRoot, sourcePackages);

  static List<({String libDir, String packageName})> _build(
    String workspaceRoot,
    List<({String name, String libRoot})> sourcePackages,
  ) {
    final entries = [
      for (final pkg in sourcePackages)
        (
          libDir: p.normalize(pkg.libRoot.isEmpty
              ? p.join(workspaceRoot, 'lib')
              : p.join(workspaceRoot, pkg.libRoot, 'lib')),
          packageName: pkg.name,
        ),
    ];
    // Longest libDir first so a nested package claims its files before an
    // ancestor package would.
    entries.sort((a, b) => b.libDir.length.compareTo(a.libDir.length));
    return entries;
  }

  /// The lib directory of each source package, in declared order.
  Iterable<String> get sourceLibDirs {
    final byDeclared = [..._entries]
      ..sort((a, b) => a.libDir.length.compareTo(b.libDir.length));
    return byDeclared.map((e) => e.libDir);
  }

  /// The `package:<name>/<rel>` URI for [absPath], or null when it belongs to
  /// no first-party source package.
  String? toPackageUri(String absPath) {
    final norm = p.normalize(absPath);
    for (final e in _entries) {
      if (p.isWithin(e.libDir, norm)) {
        final rel = p.split(p.relative(norm, from: e.libDir)).join('/');
        return 'package:${e.packageName}/$rel';
      }
    }
    return null;
  }
}
