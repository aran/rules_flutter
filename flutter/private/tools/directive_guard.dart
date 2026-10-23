// Flutter's half of the directive-URI check: the whole-program kernel compile
// (`frontend_server` behind `flutter_kernel_compile_action`) resolves its
// inputs through the app multi-root scheme across its `--filesystem-root`
// values, so the shared staged-source check cannot confine it. Only that
// Flutter-specific entry point lives here (`findDisallowedFlutterDirectives`,
// run by `kernel_filter.dart` over every declared source before the compiler
// runs); the prologue scanner, the scheme classifiers and the staged-path
// resolution it builds on come from rules_dart's public guard library
// (`@rules_dart//dart/guard:directive_guard`,
// `package:rules_dart_guard/directive_guard.dart`).
//
// The front end behind `flutter_kernel_compile_action` (`frontend_server`)
// loads `file:` URIs straight off the host filesystem, outside every
// `--filesystem-root`, so a compile that mounts the exec root embeds
// undeclared bytes and Bazel caches the stale result. `kernel_filter.dart`
// runs this check over every declared source before the compiler runs, and
// the action mounts only its staging root, so an undeclared file is not there
// to be read whatever its spelling.
//
// Like the shared check, a directive with an empty path segment (`a//b.dart`)
// is refused: the front end does not resolve every such spelling the way
// skipping the segment would (a `package:` doubled slash resolves as an
// absolute path), so such URIs fail before the compiler runs.

import 'dart:convert';
import 'dart:io';

import 'package:rules_dart_guard/directive_guard.dart';

/// The multi-root scheme a whole-program Flutter kernel compile resolves its
/// inputs through (see `APP_SCHEME` in `app_entrypoint.bzl`).
const flutterMultiRootPrefix = 'org-dartlang-app:///';

/// The multi-root key naming the declared input source [path]: the
/// exec-root-relative path with its longest `--filesystem-root` prefix
/// stripped, then with a generated file's `bazel-out/<config>/bin/` prefix
/// stripped to the workspace-relative path it is staged at. Mirrors the
/// derivation in rules_dart's whole-program `gen_kernel` wrapper (whose
/// filesystem roots include the bin root, so the same strip falls out of its
/// prefix loop): the compile runs with the exec root as its working directory,
/// so an absolute declared path under it becomes relative, a staged file's key
/// drops the staging-root prefix, and a generated file's key drops the
/// bin-directory prefix. A relative directive URI resolved against one
/// declared source's key therefore names the same key the front end looks up
/// whether the target lives in the source tree or in `bazel-out` — a `part`
/// and its `part of` meet in either direction, in the app's own package and in
/// dependency packages.
///
/// Every key in the comparison uses this function, so the strip cannot admit
/// an undeclared file: a stale output in `bazel-out` that no target declares
/// holds a key no declared source holds, and a `file:` URI naming it is
/// refused by the scheme check before keys are compared. The front end finds
/// each key where it is — every kernel entrypoint compiles under a `package:`
/// or app-scheme URI routed across the staging root — so a generated sibling
/// staged beside its importer reads a declared input, not the host. Paths
/// already relative, or absolute but under no root and outside the working
/// directory (tests), keep the [stripFsRootPrefix] spelling, which stays
/// consistent because every key in the comparison uses this function.
String flutterSourceKey(String path, List<String> fsRoots) {
  var slash = path.replaceAll(r'\', '/');
  final cwd = Directory.current.path
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  if (slash == cwd) {
    slash = '';
  } else if (slash.startsWith('$cwd/')) {
    slash = slash.substring(cwd.length + 1);
  }
  slash = slash.replaceFirst(RegExp(r'^(?:\./)+'), '');
  String? best;
  for (final rawRoot in fsRoots) {
    final root = rawRoot
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'^(?:\./)+'), '');
    if (root.isEmpty || root == '.') continue;
    if ((slash == root || slash.startsWith('$root/')) &&
        (best == null || root.length > best.length)) {
      best = root;
    }
  }
  if (best != null) {
    slash = slash == best ? '' : slash.substring(best.length + 1);
  }
  // A generated file's exec path names it under `bazel-out/<config>/bin/`;
  // its key is the workspace-relative path it is staged at (see above).
  // Sources never live under `bazel-out/`, so the prefix cannot collide with
  // one. Both sides of every comparison use this function, so whatever
  // spelling a repository's generated files arrive under, their keys meet the
  // importers' keys exactly when the files are staged as siblings — the same
  // condition under which the front end resolves the import.
  final bin = RegExp('^bazel-out/[^/]+/bin/').firstMatch(slash);
  if (bin != null) {
    slash = slash.substring(bin[0]!.length);
  }
  return slash;
}

/// The exec-root-relative path of [path] with its longest `--filesystem-root`
/// prefix stripped (`<root>/` only; a bare `<root>` without the slash is not a
/// prefix). Mirrors rules_dart's whole-program `gen_kernel` wrapper.
String stripFsRootPrefix(String path, List<String> fsRoots) {
  final slashPath = path.replaceAll(r'\', '/');
  var bestRootLen = -1;
  String? bestRel;
  for (final rawRoot in fsRoots) {
    final root = rawRoot.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '');
    if (root.isEmpty || root == '.') continue;
    final prefix = '$root/';
    if (slashPath.startsWith(prefix) && root.length > bestRootLen) {
      bestRootLen = root.length;
      bestRel = slashPath.substring(prefix.length);
    }
  }
  return bestRel ?? slashPath.replaceFirst(RegExp(r'^(?:\./)+'), '');
}

/// The multi-root key a schemeless relative directive URI in the declared
/// source with key [fromKey] refers to: the front end resolves the URI against
/// the importing file's key and finds each key where it is, whether in the
/// source tree or in the staging root, so a generated sibling staged beside
/// its importer names a declared input. `\` separates and escapes decode once,
/// as in [resolveStagedRelativeTarget]; a `..` climbing above the key root
/// drops away, the way the front end's own resolution stays inside the
/// multi-root space, and the caller accepts the result only when some declared
/// source holds that key. Mirrors rules_dart's whole-program wrapper.
///
/// Null when [uri] is not a relative URI (any scheme, a fragment, a
/// `//`-prefixed authority, or a `/`-absolute path, which names a host file
/// outside every root) or when a decoded `/` names no file. An empty path
/// segment also yields null: the front end resolves some such spellings
/// absolutely, so the key lookup fails and the guard refuses the directive
/// instead of confining the wrong file. A `?...` query is dropped and the
/// path part resolved instead: an empty reference names the importing file
/// itself. Null never means "declared": the caller refuses it unless the
/// filesystem-path check already accepted it.
String? resolveFlutterKeyRelativeTarget(String uri, String fromKey) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it. A query names no file either: the front end reads the
  // file the path part names, so the path part alone is resolved below.
  if (text.contains('#')) return null;
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//') || path.startsWith('/')) return null;
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return fromKey;
  final stack = <String>[];
  for (final part in fromKey.split('/')) {
    if (part.isNotEmpty) stack.add(part);
  }
  // Drop the file name: the URI resolves against its directory.
  if (stack.isNotEmpty) stack.removeLast();
  for (final raw in path.split('/')) {
    // An empty segment is not skipped: the front end resolves some such
    // spellings absolutely, so the key lookup fails and the guard refuses the
    // directive instead of confining the wrong file.
    if (raw.isEmpty) return null;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    if (seg.contains('/')) return null;
    stack.add(seg);
  }
  return stack.join('/');
}

/// Reads every existing source in [sources] for the directive scan.
///
/// The front end decodes malformed UTF-8 instead of reporting it, so the
/// guard scans what it can rather than skipping the file. Missing or
/// unreadable files stay out of the map; the compiler reports those itself.
Map<String, String> _readDeclaredSourceContents(List<String> sources) {
  final contents = <String, String>{};
  for (final path in sources) {
    try {
      contents[path] = utf8.decode(
        File(path).readAsBytesSync(),
        allowMalformed: true,
      );
    } on FileSystemException {
      // Missing or unreadable here; the compiler reports it.
    }
  }
  return contents;
}

/// The refusal diagnostic for a directive that names no declared input.
/// Every refusal in [findDisallowedFlutterDirectives] shares this shape so
/// each names the file, the directive and the URI the same way.
String _refuseFlutterDirective(
  String tool,
  String path,
  String kind,
  String uri,
) => "$tool: $path $kind '$uri' is not a declared input.";

/// Whether the directive [uri] in the declared source with staged path [from]
/// and multi-root key [fromKey] names a file the compile may read.
///
/// A URI spanning lines is refused however it spells its target: the front
/// end drops a whitespace-only first line of a multi-line string literal and
/// reads a different file than the resolvers see. An empty path segment is
/// refused before resolving: the front end resolves some such spellings
/// absolutely. Otherwise `dart:` is always allowed, the app scheme must name
/// a declared key, `package:` must not climb above its package, `file:` and
/// other unexpected schemes are refused, and a relative URI must resolve to a
/// declared source beside the importing file or to a declared multi-root key.
bool _isAllowedFlutterDirective(
  String uri,
  String from,
  String fromKey,
  Set<String> declared,
  Set<String> declaredKeys, {
  required String multiRootPrefix,
}) {
  if (uri.contains('\n') || uri.contains('\r')) return false;
  if (hasEmptyPathSegment(uri)) return false;
  if (uri.startsWith('dart:')) return true;
  if (uri.startsWith(multiRootPrefix)) {
    // The app scheme resolves only across the compile's `--filesystem-root`
    // values, which name nothing but staged declared inputs: a URI that
    // names no declared key fails the build here instead of at the front
    // end, where the message would name the URI but not the file that
    // reads it.
    final key = resolveDirectiveUri(
      uri,
      '',
      const {},
      multiRootPrefix: multiRootPrefix,
    );
    return key != null && declaredKeys.contains(key);
  }
  if (uri.startsWith('package:')) return !isEscapingPackageUri(uri);
  if (isFileSchemeDirectiveUri(uri) ||
      isDisallowedDirectiveUri(uri, multiRootPrefix: multiRootPrefix)) {
    return false;
  }
  final target = resolveStagedRelativeTarget(uri, from);
  if (target != null && declared.contains(target)) return true;
  final keyTarget = resolveFlutterKeyRelativeTarget(uri, fromKey);
  return keyTarget != null && declaredKeys.contains(keyTarget);
}

/// A diagnostic for every input source with a directive URI that names no
/// file the action can read through its declared inputs: a `file:` URI in any
/// spelling, any other scheme but `dart:`, `package:` and the app scheme, a
/// `package:` URI climbing above its package, an empty path segment (which
/// the front end resolves differently than skipping it would), or a relative
/// URI resolving to no declared input source. The front end reads such a URI
/// off the host, outside every `--filesystem-root`, so the wrapper refuses
/// before compiling. Climbing `..` segments are followed past the declared
/// inputs, never clamped: enough segments name any host path. Empty when
/// clean. Each diagnostic names the file, the directive and the URI.
///
/// A relative URI is accepted when it resolves to a declared source beside the
/// importing file, or when it resolves to a declared source's multi-root key
/// ([resolveFlutterKeyRelativeTarget] over [flutterSourceKey]): the front end
/// finds each key where it is, so a generated sibling in the staging root
/// beside a source-tree importer reads a declared input, not the host.
///
/// [sources] are filesystem paths of the declared Dart sources (read in the
/// compile's working directory; missing or unreadable files are skipped — the
/// compiler reports those itself — while every source that exists is decoded
/// with `allowMalformed` so malformed bytes never skip the check).
/// [fsRoots] are the `--filesystem-root`
/// values the compile forwards to the front end.
List<String> findDisallowedFlutterDirectives(
  List<String> sources,
  List<String> fsRoots, {
  String tool = 'flutter',
  String multiRootPrefix = flutterMultiRootPrefix,
}) {
  final contents = _readDeclaredSourceContents(sources);
  final declared = <String>{
    for (final path in contents.keys) normalizeStagedPath(path),
  };
  final declaredKeys = <String>{
    for (final path in contents.keys) flutterSourceKey(path, fsRoots),
  };
  final errors = <String>[];
  final paths = contents.keys.toList()..sort();
  for (final path in paths) {
    final content = contents[path];
    if (content == null) continue;
    final from = normalizeStagedPath(path);
    final fromKey = flutterSourceKey(path, fsRoots);
    for (final ref in scanAllDirectiveUris(content)) {
      if (_isAllowedFlutterDirective(
        ref.uri,
        from,
        fromKey,
        declared,
        declaredKeys,
        multiRootPrefix: multiRootPrefix,
      )) {
        continue;
      }
      errors.add(_refuseFlutterDirective(tool, path, ref.kind, ref.uri));
    }
  }
  return errors;
}
