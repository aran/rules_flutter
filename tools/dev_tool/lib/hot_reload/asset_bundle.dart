/// The built `flutter_assets` tree, and what an edit changed in it.
///
/// The Bazel asset action keys every asset by its `short_path`, which for a
/// main-repo source file is exactly its workspace-relative path. That makes the
/// built bundle its own source map: an archive entry with a file of the same
/// relative path in the workspace names the file the user edits. Nothing here
/// parses `assets = glob(...)` or a pubspec to work out which files matter —
/// the build already answered that, and the answer is on disk.
///
/// Assets from elsewhere (`packages/<pkg>/…` from a pub dependency,
/// `fonts/MaterialIcons-Regular.otf` from the SDK, the generated manifests)
/// have no workspace file at their archive path, so they are not watched. They
/// still take part in the diff: a rebuild that changes one is applied like any
/// other.
import 'dart:io';

import 'package:path/path.dart' as p;

/// Archive path of the manifest naming every font family in the bundle.
///
/// Its bytes change when a family is added, removed, or repointed — which is
/// the event the engine's font collection has to be told about.
const String kFontManifest = 'FontManifest.json';

/// Extensions the engine registers as fonts.
const _fontExtensions = {'.ttf', '.otf', '.ttc'};

/// Whether [changed] contains anything the engine's font collection caches.
///
/// `FontManifest.json` is the manifest itself. The binaries are here too, and
/// that is a deliberate divergence from upstream: `flutter run` only reloads
/// fonts when the *manifest* changes, so re-exporting a `.ttf` in place is
/// silently ignored there until a restart. Re-registering costs one RPC, and
/// the engine re-reads every family from the asset manager when it happens.
bool touchesFonts(Set<String> changed) => changed.any(
  (path) =>
      path == kFontManifest || _fontExtensions.contains(p.extension(path)),
);

/// A built `flutter_assets` directory.
///
/// Immutable and stateless — [scan] is a fresh filesystem read every time.
/// [AssetTracker] is what remembers.
class AssetBundle {
  /// Absolute path of the built tree (`bazel-bin/…/<app>_flutter_assets`).
  final String directory;

  /// Absolute path of the source workspace, for resolving archive paths back
  /// to the files a user edits.
  final String workspaceRoot;

  const AssetBundle({required this.directory, required this.workspaceRoot});

  /// Every file in the bundle, keyed by archive path, valued by a digest of
  /// its contents.
  ///
  /// Archive paths are bundle-relative and always `/`-separated: that is the
  /// form the engine's asset manager uses, and the form `ext.flutter.evict`
  /// expects. Returns empty when the tree does not exist, which is what a
  /// bundle that failed to build looks like — the caller reports nothing
  /// changed rather than reporting every asset as deleted.
  ///
  /// Contents, not `(mtime, size)` as the source tree is tracked by. The whole
  /// bundle is one Bazel action producing one tree artifact, so touching a
  /// single PNG reruns it and rewrites every file in the tree with a fresh
  /// mtime. Under mtime the diff would name every asset in the app on every
  /// edit — evicting the world, and reporting a font change whenever the
  /// bundle happens to contain a font. Reading the tree costs one pass over
  /// bytes that were just written, and only ever after a build the caller had
  /// already decided to run.
  Map<String, int> scan() {
    final dir = Directory(directory);
    if (!dir.existsSync()) return const {};
    final digests = <String, int>{};
    for (final entity in dir.listSync(recursive: true, followLinks: true)) {
      if (entity is! File) continue;
      digests[archivePathOf(entity.path)] = _digest(entity.readAsBytesSync());
    }
    return digests;
  }

  /// The archive path of a file inside this bundle.
  String archivePathOf(String absolutePath) =>
      p.url.joinAll(p.split(p.relative(absolutePath, from: directory)));

  /// The workspace file that feeds [archivePath], or null when nothing in the
  /// source tree does.
  String? sourceOf(String archivePath) {
    final candidate = p.join(
      workspaceRoot,
      p.joinAll(p.url.split(archivePath)),
    );
    return File(candidate).existsSync() ? candidate : null;
  }

  /// FNV-1a over [bytes].
  ///
  /// Not a cryptographic hash, and it does not need to be: the value never
  /// leaves this process, is never written down, and is only ever compared for
  /// equality with another digest computed the same way in the same run. What
  /// it has to be is fast over the whole bundle, which it is.
  static int _digest(List<int> bytes) {
    var hash = 0xcbf29ce484222325;
    for (final byte in bytes) {
      hash ^= byte;
      hash *= 0x100000001b3;
    }
    return hash;
  }
}

/// What the app has been told about the asset bundle, and what has changed
/// since.
///
/// Two views are tracked, because they answer different questions at different
/// costs. The *source* view — the workspace directories that feed the bundle —
/// answers "is a build even worth running?" from a handful of directory
/// listings. The *bundle* view answers "what do I have to evict?", but only
/// after a build has refreshed the tree.
class AssetTracker {
  final AssetBundle bundle;

  /// Last committed state of the built tree: `{archive path: content digest}`.
  Map<String, int> _bundleState;

  /// Last committed state of the workspace directories that feed the bundle,
  /// as `{directory: {filename: content digest}}`.
  ///
  /// Whole directories rather than just the files that are assets today, so a
  /// *newly added* file is noticed. Upstream gets the same effect from
  /// pubspec's wildcard-directory declarations; here the built bundle says
  /// which directories those are.
  Map<String, Map<String, int>> _sourceState;

  /// [builtBefore] is when the build that produced this bundle started.
  ///
  /// A source file stamped after it is left out of the initial baseline, so
  /// the first reload sees it as stale. This tracker is constructed during
  /// assembly, which runs while the app is already up and answering commands —
  /// an edit landing in that window would otherwise be scanned in as the
  /// unchanged state, and the first reload would report nothing to deliver
  /// while the app kept showing the bytes it launched with.
  ///
  /// [takeBundleChanges] takes the same guard for the same window, against the
  /// start of the rebuild it is committing.
  AssetTracker(this.bundle, {required DateTime builtBefore})
    : _bundleState = const {},
      _sourceState = const {} {
    _bundleState = bundle.scan();
    _sourceState = _scanSourceDirs(_bundleState, builtBefore: builtBefore);
  }

  /// The workspace directories holding files that feed the bundle.
  Iterable<String> get watchedDirectories => _sourceState.keys;

  /// Whether [absolutePath] is somewhere a change could mean an asset change.
  ///
  /// Directory membership rather than an exact file match, so a file that did
  /// not exist at the last build still registers. A false positive costs one
  /// cache-hit build and an empty diff; a false negative loses the edit.
  bool watches(String absolutePath) =>
      _sourceState.containsKey(p.dirname(absolutePath));

  /// Whether anything feeding the bundle has changed on disk.
  ///
  /// Cheap by design — a few directory listings and a pass over the asset
  /// bytes, no build. This is what keeps the instant reload path instant: an
  /// app whose assets are untouched never pays for a `bazel build` on a Dart
  /// edit.
  bool get sourcesAreStale {
    final now = _scanDirs(_sourceState.keys);
    if (now.length != _sourceState.length) return true;
    for (final entry in now.entries) {
      final before = _sourceState[entry.key];
      if (before == null || before.length != entry.value.length) return true;
      for (final file in entry.value.entries) {
        if (before[file.key] != file.value) return true;
      }
    }
    return false;
  }

  /// Archive paths whose bytes differ from what the app was last told about.
  ///
  /// Rescans the built tree — so it is only meaningful after a build has run —
  /// and commits the result: the same change is never reported twice. A
  /// deleted asset is reported like a changed one, because the app has to drop
  /// its cached copy either way.
  ///
  /// [rebuiltBefore] is when the build that just produced this tree started,
  /// and it is the guard [AssetTracker.new] takes, for the same reason: a save
  /// landing while bazel was running is not in the tree bazel produced, so
  /// recording it as the state the app now holds loses the edit silently.
  ///
  /// It covers edits, not every mutation: a file *deleted* while the build ran
  /// has no stamp to compare, so it is recorded as absent and the bundle keeps
  /// serving it until some later edit forces a rebuild. And a source stamped
  /// ahead of the clock — an archive extraction, a clock-skewed sync — is
  /// omitted from every commit, so every reload reads stale and pays a build.
  /// That one announces itself: each pass reports `rebuiltIdentical`.
  ///
  /// Required, and required non-null, like [AssetTracker.new]'s: a cutoff that
  /// could be left off would be left off, and its absence is not visible in
  /// anything the caller sees afterwards. A caller that means "everything on
  /// disk is delivered" says so with an instant later than the tree.
  Set<String> takeBundleChanges({required DateTime rebuiltBefore}) {
    final now = bundle.scan();
    final changed = <String>{
      for (final entry in now.entries)
        if (_bundleState[entry.key] != entry.value) entry.key,
      for (final path in _bundleState.keys)
        if (!now.containsKey(path)) path,
    };
    _bundleState = now;
    _sourceState = _scanSourceDirs(now, builtBefore: rebuiltBefore);
    return changed;
  }

  /// The directories holding the workspace files behind [bundleState].
  Map<String, Map<String, int>> _scanSourceDirs(
    Map<String, int> bundleState, {
    DateTime? builtBefore,
  }) {
    final dirs = <String>{};
    for (final archivePath in bundleState.keys) {
      final source = bundle.sourceOf(archivePath);
      if (source != null) dirs.add(p.dirname(source));
    }
    return _scanDirs(dirs, builtBefore: builtBefore);
  }

  /// `{directory: {filename: content digest}}` for each of [dirs].
  ///
  /// Non-recursive: a resolution-variant subdirectory (`assets/2.0x/`) holds
  /// assets of its own, so it is already a directory in its own right here.
  /// Dotfiles are skipped — `.DS_Store` is rewritten by the Finder often
  /// enough to make every reload look like an asset change.
  ///
  /// Contents, not `(mtime, size)` as the Dart source tree is tracked by.
  /// A stamp has no resolution worth relying on — the SDK truncates it and the
  /// filesystem underneath sets its own floor — so two saves close enough
  /// together carry the same stamp, and a same-length edit (a version string,
  /// a feature flag, one character) carries the same size. That pair leaves a
  /// third state alive: not "unchanged", but "changed in a way I cannot see",
  /// reported to the user as a successful reload with nothing to deliver while
  /// the app keeps the bytes it launched with. Reading the bytes has no such
  /// state, and the bytes are what a rebuild would key on anyway.
  ///
  /// It is affordable because an asset set is not the Dart source tree:
  /// digesting it costs a fraction of a reload, and a bundle rescan
  /// ([AssetBundle.scan]) already reads every one of these bytes back out of
  /// the built tree after each build.
  ///
  /// A file stamped at or after [builtBefore] is omitted rather than recorded,
  /// which makes the directory's file count differ and so reads as stale. Null
  /// means record everything, which is what a post-delivery re-commit wants.
  /// mtime is the right question there and only there: it asks when the file
  /// was written relative to the build, which no digest can answer. The guard
  /// covers an edit landing in that window; a *deletion* has no stamp to cut
  /// off, and is caught instead by the file simply not being there next time.
  ///
  /// A file that cannot be read is omitted too, by the same rule and for the
  /// same reason: it is not a file the app can be shown, and the diff already
  /// reports an absence as a change. Reading the bytes has a failure mode
  /// statting them does not — `statSync` answers a vanished file with a
  /// `notFound` sentinel while `readAsBytesSync` throws, and this runs on the
  /// watcher's callback, where an escaping exception is an unhandled async
  /// error that ends the run. Deleting an asset is something users do.
  static Map<String, Map<String, int>> _scanDirs(
    Iterable<String> dirs, {
    DateTime? builtBefore,
  }) {
    final cutoff = builtBefore == null
        ? null
        : _floorToMillisecond(builtBefore);
    final out = <String, Map<String, int>>{};
    for (final path in dirs) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      final files = <String, int>{};
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        if (cutoff != null && !entity.statSync().modified.isBefore(cutoff)) {
          continue;
        }
        try {
          files[name] = AssetBundle._digest(entity.readAsBytesSync());
        } on FileSystemException {
          continue;
        }
      }
      out[path] = files;
    }
    return out;
  }

  /// [when] with its sub-millisecond part dropped.
  ///
  /// The cutoff is a `DateTime.now()`, which carries microseconds, and it is
  /// compared against a `FileStat.modified`, whose resolution is whatever the
  /// SDK and the filesystem happen to give. Where that is coarser than the
  /// cutoff, a file written *after* the cutoff and inside the same tick carries
  /// a stamp that reads as *before* it — a hole in the one guard against
  /// baselining an edit the build never saw.
  ///
  /// Flooring only ever errs toward treating a file as written after the build:
  /// that costs a rebuild whose diff is empty, where the other direction loses
  /// the edit silently.
  ///
  /// Subtracting the remainder rather than dividing and re-multiplying: `~/`
  /// truncates toward zero, which rounds a pre-epoch instant the wrong way,
  /// while Dart's `%` is Euclidean and so floors on both sides of 1970.
  static DateTime _floorToMillisecond(DateTime when) {
    final us = when.microsecondsSinceEpoch;
    return DateTime.fromMicrosecondsSinceEpoch(
      us - us % 1000,
      isUtc: when.isUtc,
    );
  }
}
