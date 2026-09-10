import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/asset_bundle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A workspace with an `assets/` directory, and the bundle a build of it
/// produces.
///
/// Mirrors what `flutter_asset_bundle_action` writes: every first-party asset
/// is copied into the tree under its workspace-relative path, alongside the
/// generated manifests, which have no source file behind them.
class _Fixture {
  final Directory root;
  late final String workspace = p.join(root.path, 'ws');
  late final String bundleDir = p.join(root.path, 'bazel-out', 'app_assets');
  late final AssetBundle bundle = AssetBundle(
    directory: bundleDir,
    workspaceRoot: workspace,
  );

  _Fixture() : root = Directory.systemTemp.createTempSync('asset_bundle_');

  /// Write [content] to a workspace file and copy it into the bundle, the way
  /// a build would.
  void put(String relativePath, String content) {
    _write(p.join(workspace, relativePath), content);
    _write(p.join(bundleDir, relativePath), content);
  }

  /// Write a bundle entry with no workspace file behind it — a generated
  /// manifest, or an asset that came from a pub dependency.
  void putGenerated(String archivePath, String content) =>
      _write(p.join(bundleDir, archivePath), content);

  /// Change a workspace file without rebuilding, i.e. the state right after a
  /// user saves.
  void edit(String relativePath, String content) =>
      _write(p.join(workspace, relativePath), content);

  /// Edit a workspace file to different bytes of the same length, leaving its
  /// `(mtime, size)` exactly as it was.
  ///
  /// `stat.modified` is truncated to whole milliseconds, so a save landing in
  /// the same tick as the previous one carries the same stamp, and a
  /// same-length edit — a version string, a feature flag, one
  /// character — carries the same size. Reproduced by restoring the stat
  /// rather than by racing the clock, so the case is exercised on every run
  /// instead of whenever the machine is fast enough.
  void editInPlace(String relativePath, String content) {
    final file = File(p.join(workspace, relativePath));
    final before = file.statSync();
    final bytes = utf8.encode(content);
    if (bytes.length != before.size) {
      throw ArgumentError(
        'editInPlace needs same-length content: '
        '${bytes.length} bytes replacing ${before.size}',
      );
    }
    file.writeAsBytesSync(bytes);
    file.setLastModifiedSync(before.modified);
  }

  /// Rebuild: copy every workspace file under `assets/` into the bundle.
  void build() {
    final dir = Directory(p.join(workspace, 'assets'));
    if (!dir.existsSync()) return;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File) continue;
      _write(
        p.join(bundleDir, p.relative(entity.path, from: workspace)),
        entity.readAsStringSync(),
      );
    }
  }

  void deleteFromBundle(String archivePath) =>
      File(p.join(bundleDir, archivePath)).deleteSync();

  void dispose() => root.deleteSync(recursive: true);

  static void _write(String path, String content) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
    // Two writes inside one filesystem mtime tick are indistinguishable by
    // mtime alone, and these fixtures write far faster than that. Version
    // also carries size, but a same-length edit would slip through — so
    // stamp a distinct mtime rather than leaving the test to race the clock.
    file.setLastModifiedSync(
      DateTime.now().add(Duration(milliseconds: _tick++ * 1500)),
    );
  }

  static int _tick = 0;
}

/// A cutoff later than anything [_Fixture] has written.
///
/// `_write` deliberately stamps mtimes into the future to dodge filesystem
/// mtime granularity, so "now" would make every fixture file look like it
/// landed after the build. These tests are about a tree the build consumed.
DateTime afterFixtureWrites() => DateTime.now().add(const Duration(hours: 1));

void main() {
  late _Fixture fixture;

  setUp(() {
    fixture = _Fixture();
    addTearDown(fixture.dispose);
  });

  group('AssetBundle', () {
    test('keys every entry by its bundle-relative, slash-separated path', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      fixture.put(p.join('assets', '2.0x', 'logo.png'), 'v1-2x');
      fixture.putGenerated('AssetManifest.bin', 'manifest');

      expect(
        fixture.bundle.scan().keys,
        unorderedEquals([
          'assets/logo.png',
          'assets/2.0x/logo.png',
          'AssetManifest.bin',
        ]),
      );
    });

    test('an unbuilt tree scans empty rather than throwing', () {
      // What a bundle that has not been built yet, or whose build failed,
      // looks like. Reporting nothing beats reporting every asset as deleted.
      expect(
        AssetBundle(
          directory: p.join(fixture.root.path, 'nope'),
          workspaceRoot: fixture.workspace,
        ).scan(),
        isEmpty,
      );
    });

    test('resolves an entry back to the workspace file that feeds it', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');

      expect(
        fixture.bundle.sourceOf('assets/logo.png'),
        p.join(fixture.workspace, 'assets', 'logo.png'),
      );
    });

    test('an entry with no workspace file behind it resolves to null', () {
      // Generated manifests, SDK fonts, and pub-package assets all land here.
      // Treating them as editable sources would have the tool watch
      // directories the user never touches.
      fixture.putGenerated('FontManifest.json', '[]');

      expect(fixture.bundle.sourceOf('FontManifest.json'), isNull);
    });
  });

  group('touchesFonts', () {
    test('recognises the manifest and every font binary extension', () {
      expect(touchesFonts({'FontManifest.json'}), isTrue);
      expect(touchesFonts({'assets/fonts/Inter.ttf'}), isTrue);
      expect(touchesFonts({'assets/fonts/Inter.otf'}), isTrue);
      expect(touchesFonts({'assets/fonts/Inter.ttc'}), isTrue);
    });

    // The divergence from upstream, pinned: `flutter run` only reloads fonts
    // when FontManifest.json changes, so re-exporting a .ttf in place is
    // ignored there until a restart.
    test('a font binary alone is enough, with no manifest change', () {
      expect(touchesFonts({'assets/fonts/Inter.ttf'}), isTrue);
    });

    test('ordinary assets are not fonts', () {
      expect(touchesFonts({'assets/logo.png', 'AssetManifest.bin'}), isFalse);
    });
  });

  group('AssetTracker', () {
    test('watches the directories holding asset sources, and nothing else', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      fixture.put(p.join('assets', '2.0x', 'logo.png'), 'v1-2x');
      fixture.putGenerated('AssetManifest.bin', 'manifest');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );

      // A sibling that did not exist at build time still counts: it is in a
      // directory the bundle draws from, which is how a newly added asset
      // gets noticed at all.
      expect(
        tracker.watches(p.join(fixture.workspace, 'assets', 'new.png')),
        isTrue,
      );
      expect(
        tracker.watches(
          p.join(fixture.workspace, 'assets', '2.0x', 'other.png'),
        ),
        isTrue,
      );
      expect(
        tracker.watches(p.join(fixture.workspace, 'lib', 'main.dart')),
        isFalse,
      );
      expect(tracker.watches(p.join(fixture.workspace, 'README.md')), isFalse);
    });

    test('a bundle with no first-party assets watches nothing', () {
      fixture.putGenerated('AssetManifest.bin', 'manifest');
      fixture.putGenerated('fonts/MaterialIcons-Regular.otf', 'sdk font');

      expect(
        AssetTracker(
          fixture.bundle,
          builtBefore: afterFixtureWrites(),
        ).watchedDirectories,
        isEmpty,
      );
    });

    test('a freshly built bundle is not stale', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');

      expect(
        AssetTracker(
          fixture.bundle,
          builtBefore: afterFixtureWrites(),
        ).sourcesAreStale,
        isFalse,
      );
    });

    // The gate that keeps a Dart-only edit off the bazel path: if this said
    // "stale" on an untouched tree, every hot reload would pay for a build.
    test('editing an asset makes the sources stale', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );

      fixture.edit(p.join('assets', 'logo.png'), 'v2');

      expect(tracker.sourcesAreStale, isTrue);
    });

    // The case `(mtime, size)` cannot see: `asset v1` and `asset v2` are both
    // 9 bytes, and a save inside one millisecond of the last one carries the
    // same stamp — so a tracker keyed on the stat pair finds nothing to do and
    // the app goes on showing the old bytes, silently. Reachable by any user
    // editing a version string right after a build.
    test(
      'a same-length edit inside one mtime tick makes the sources stale',
      () {
        fixture.put(p.join('assets', 'message.txt'), 'asset v1\n');
        final tracker = AssetTracker(
          fixture.bundle,
          builtBefore: afterFixtureWrites(),
        );
        expect(tracker.sourcesAreStale, isFalse);

        fixture.editInPlace(p.join('assets', 'message.txt'), 'asset v2\n');

        expect(tracker.sourcesAreStale, isTrue);
      },
    );

    // The other half of the same claim: identity is the bytes, so re-saving a
    // file without changing it is not a change. Without this, "notice
    // everything" could be had by simply always answering true, and every
    // Dart-only reload would pay for a bazel build.
    test(
      'rewriting an asset with identical bytes leaves the sources fresh',
      () {
        fixture.put(p.join('assets', 'message.txt'), 'asset v1\n');
        final tracker = AssetTracker(
          fixture.bundle,
          builtBefore: afterFixtureWrites(),
        );

        fixture.edit(p.join('assets', 'message.txt'), 'asset v1\n');

        expect(tracker.sourcesAreStale, isFalse);
      },
    );

    test(
      'an asset edited while assembly was running is stale from the start',
      () {
        // The tracker is constructed during assembly, which happens while the
        // app is already up and answering commands — so an edit can land before
        // this baseline is taken. Scanned in, it becomes the "unchanged" state
        // and the first reload reports no assets to deliver, with the app still
        // showing the old bytes.
        fixture.put(p.join('assets', 'logo.png'), 'v1');
        final cutoff = DateTime.now();
        File(
          p.join(fixture.workspace, 'assets', 'logo.png'),
        ).setLastModifiedSync(cutoff.add(const Duration(seconds: 1)));

        final tracker = AssetTracker(fixture.bundle, builtBefore: cutoff);

        expect(tracker.sourcesAreStale, isTrue);
      },
    );

    test(
      'an asset stamped in the build’s own millisecond is not baselined',
      () {
        // The cutoff is a `DateTime.now()`, which carries microseconds, while
        // `FileStat.modified` carries whatever the SDK and filesystem give it.
        // Within one millisecond of each other the stamp cannot be trusted to
        // say whether the save came before the build or after it — so assuming
        // "before", as a raw comparison does, baselines an edit the build may
        // never have seen and loses it.
        fixture.put(p.join('assets', 'logo.png'), 'v1');
        final source = File(p.join(fixture.workspace, 'assets', 'logo.png'))
          // A natural write, so the stamp has the resolution a real save has.
          ..writeAsStringSync('v1');

        // Half a millisecond into the millisecond the save landed in, rather
        // than half a millisecond after the stamp itself. `FileStat.modified`
        // carries microseconds, so a stamp more than 500µs into its
        // millisecond pushes the second form into the *next* millisecond,
        // where the floored cutoff is genuinely later than the save and the
        // guard correctly declines to fire.
        final stamp = source.statSync().modified;
        final cutoff = stamp
            .subtract(
              Duration(microseconds: stamp.microsecondsSinceEpoch % 1000),
            )
            .add(const Duration(microseconds: 500));

        expect(
          AssetTracker(fixture.bundle, builtBefore: cutoff).sourcesAreStale,
          isTrue,
        );
      },
    );

    test('adding a file to an asset directory makes the sources stale', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );

      fixture.edit(p.join('assets', 'added.png'), 'brand new');

      expect(tracker.sourcesAreStale, isTrue);
    });

    test('deleting an asset makes the sources stale', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      fixture.put(p.join('assets', 'icon.png'), 'v1');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );

      File(p.join(fixture.workspace, 'assets', 'icon.png')).deleteSync();

      expect(tracker.sourcesAreStale, isTrue);
    });

    test(
      'an asset that cannot be read is a change, not a crash',
      () {
        // Reading the bytes brings a failure mode statting them does not:
        // `statSync` answers a vanished file with a `notFound` sentinel, while
        // `readAsBytesSync` throws. The scan runs on the watcher's callback,
        // where an escaping exception is an unhandled async error and ends the
        // run — and deleting an asset is something users do.
        //
        // Omission is the right answer, not a swallow: a file that cannot be
        // read is not one the app can be shown, and leaving it out is what the
        // map diff already reports a change by.
        fixture.put(p.join('assets', 'logo.png'), 'v1');
        fixture.put(p.join('assets', 'icon.png'), 'v1');
        final tracker = AssetTracker(
          fixture.bundle,
          builtBefore: afterFixtureWrites(),
        );
        final unreadable = File(
          p.join(fixture.workspace, 'assets', 'icon.png'),
        );

        Process.runSync('chmod', ['000', unreadable.path]);
        addTearDown(() => Process.runSync('chmod', ['644', unreadable.path]));

        expect(() => tracker.sourcesAreStale, returnsNormally);
        expect(
          tracker.sourcesAreStale,
          isTrue,
          reason:
              'the app cannot be shown a file this scan cannot read; '
              'reporting it unchanged would leave the old bytes on screen',
        );
      },
      skip: Platform.isWindows
          ? 'chmod 000 does not deny reads on Windows'
          : null,
    );

    test('a dotfile appearing next to an asset does not', () {
      // The Finder rewrites .DS_Store often enough that counting it would make
      // every reload on a macOS workspace run a build.
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );

      fixture.edit(p.join('assets', '.DS_Store'), 'finder junk');

      expect(tracker.sourcesAreStale, isFalse);
    });

    test('reports the archive paths a rebuild changed, once', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      fixture.put(p.join('assets', 'icon.png'), 'v1');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );

      fixture.edit(p.join('assets', 'logo.png'), 'v2');
      fixture.build();

      expect(tracker.takeBundleChanges(rebuiltBefore: afterFixtureWrites()), {
        'assets/logo.png',
      });
      // Committed: the same change must not be re-delivered on the next
      // reload, or every subsequent reload re-evicts the whole history.
      expect(
        tracker.takeBundleChanges(rebuiltBefore: afterFixtureWrites()),
        isEmpty,
      );
    });

    // The bundle is one Bazel action producing one tree artifact, so editing
    // a single asset reruns it and rewrites every file with a fresh mtime.
    // Under an mtime-based identity this would name every asset in the app,
    // evicting the world and claiming a font change on every icon tweak.
    test('a rebuild only reports the entries whose bytes actually differ', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      fixture.put(p.join('assets', 'icon.png'), 'v1');
      fixture.put(p.join('assets', 'fonts', 'Inter.ttf'), 'font bytes');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );

      fixture.edit(p.join('assets', 'logo.png'), 'v2');
      fixture.build();

      final changed = tracker.takeBundleChanges(
        rebuiltBefore: afterFixtureWrites(),
      );
      expect(changed, {'assets/logo.png'});
      expect(touchesFonts(changed), isFalse);
    });

    test('a rebuild that changes nothing reports nothing', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );

      fixture.build();

      expect(
        tracker.takeBundleChanges(rebuiltBefore: afterFixtureWrites()),
        isEmpty,
      );
    });

    test('a removed entry is reported like a changed one', () {
      // The app has it cached either way, and only an evict drops that copy.
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );

      fixture.deleteFromBundle('assets/logo.png');

      expect(tracker.takeBundleChanges(rebuiltBefore: afterFixtureWrites()), {
        'assets/logo.png',
      });
    });

    test('a new asset directory starts being watched after a rebuild', () {
      fixture.put(p.join('assets', 'logo.png'), 'v1');
      final tracker = AssetTracker(
        fixture.bundle,
        builtBefore: afterFixtureWrites(),
      );
      final newDirFile = p.join(
        fixture.workspace,
        'assets',
        '3.0x',
        'logo.png',
      );
      expect(tracker.watches(newDirFile), isFalse);

      fixture.edit(p.join('assets', '3.0x', 'logo.png'), 'v1-3x');
      fixture.build();
      tracker.takeBundleChanges(rebuiltBefore: afterFixtureWrites());

      expect(tracker.watches(newDirFile), isTrue);
    });
  });
}
