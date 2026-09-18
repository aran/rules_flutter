/// Maps an absolute source-file path to the URI the frontend_server keys that
/// library by.
///
/// This is the single, authoritative path → URI inversion used by every reload
/// path (snapshot diff, machine-protocol invalidation, the filesystem watcher).
/// It is driven by what the build declares in `_dev_config.json` — NOT by
/// heuristics about the entrypoint scheme or the app's own `lib/`:
///
///  * `sourcePackages` (`{name, libRoot}` per first-party package): a file under
///    a package's `lib/` is `package:<name>/<rel>`. That is what lets an edit in
///    a dependency package, an assembled (codegen) package, or the app resolve
///    to the right library.
///  * `appSources` (`{path, uri}`): the files outside every package that the app
///    compiles under the app scheme — a `main` outside its package's `lib/`, as
///    `flutter run -t test_driver/app.dart` allows, and the sources beside it.
///
/// Anything else (a pub dep under `external/`, a tool script) resolves to null
/// and is skipped rather than invalidated with a URI the compiler never used.
library;

import 'package:path/path.dart' as p;

class SourceUriResolver {
  /// Package lib directories, longest-path-first for longest-prefix matching.
  final List<({String libDir, String packageName})> _entries;

  /// [appSources] by normalized absolute path.
  final Map<String, String> _appSourceUris;

  /// [appSources] by URI, for the snapshot to stat.
  final Map<String, String> _appSourcePaths;

  SourceUriResolver({
    required String workspaceRoot,
    required List<({String name, String libRoot})> sourcePackages,
    List<({String path, String uri})> appSources = const [],
  }) : _entries = _build(workspaceRoot, sourcePackages),
       _appSourceUris = {
         for (final s in appSources)
           p.normalize(p.join(workspaceRoot, s.path)): s.uri,
       },
       _appSourcePaths = {
         for (final s in appSources)
           s.uri: p.normalize(p.join(workspaceRoot, s.path)),
       };

  static List<({String libDir, String packageName})> _build(
    String workspaceRoot,
    List<({String name, String libRoot})> sourcePackages,
  ) {
    final entries = [
      for (final pkg in sourcePackages)
        (
          libDir: p.normalize(
            pkg.libRoot.isEmpty
                ? p.join(workspaceRoot, 'lib')
                : p.join(workspaceRoot, pkg.libRoot, 'lib'),
          ),
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

  /// The app's sources outside every package, as `{uri → absolute path}`.
  ///
  /// Listed by the build rather than found by a scan: they sit in whatever
  /// directory the `main` does, which may hold many files the app never reads.
  Map<String, String> get appSourceFiles => _appSourcePaths;

  /// The URI the compiler keys [absPath] by, or null when the app compiles
  /// no library from it.
  String? uriFor(String absPath) {
    final norm = p.normalize(absPath);
    for (final e in _entries) {
      if (p.isWithin(e.libDir, norm)) {
        final rel = p.split(p.relative(norm, from: e.libDir)).join('/');
        return 'package:${e.packageName}/$rel';
      }
    }
    return _appSourceUris[norm];
  }
}
