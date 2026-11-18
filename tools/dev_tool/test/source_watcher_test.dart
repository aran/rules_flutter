import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/source_uri_resolver.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/source_watcher.dart';
import 'package:test/test.dart';
import 'package:watcher/watcher.dart';

import 'fakes.dart';

void main() {
  group('SourceWatcher', () {
    // A local repository's package lives outside the workspace, and is learnt
    // of only once the run has built: its edits must arrive all the same.
    test(
      'watchAlso delivers edits from a directory outside the root',
      () async {
        final outside = Directory.systemTemp.createTempSync('watch_also_');
        addTearDown(() => outside.deleteSync(recursive: true));
        final fakes = <String, FakeDirectoryWatcher>{};
        final watcher = SourceWatcher(
          root: '/root',
          watcherFactory: (dir) => fakes[dir] = FakeDirectoryWatcher(dir),
        );
        await watcher.start();
        await watcher.watchAlso(outside.path);
        // Under a directory already watched, and absent: neither is watched.
        await watcher.watchAlso('/root/lib');
        await watcher.watchAlso('/does/not/exist');
        expect(fakes.keys, ['/root', outside.path]);

        // Both in one debounce window, so the one change that flushes says
        // whether the second was let through. The outside directory's own path
        // may say `bazel-`; only what is below it is judged.
        final change = watcher.changes.first;
        fakes[outside.path]!.emit(
          WatchEvent(ChangeType.MODIFY, '${outside.path}/bazel-bin/x.dart'),
        );
        fakes[outside.path]!.emit(
          WatchEvent(ChangeType.MODIFY, '${outside.path}/src/label.dart'),
        );
        expect((await change).paths, {'${outside.path}/src/label.dart'});

        await watcher.stop();
        for (final f in fakes.values) {
          await f.closeStream();
        }
      },
    );

    // `watchAlso` runs after the build, and the run can end while it looks
    // for the directory. A watcher started then is one nothing cancels, and it
    // keeps the process alive.
    test('watchAlso starts no watcher once stop() has run', () async {
      final outside = Directory.systemTemp.createTempSync('watch_also_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final fakes = <String, FakeDirectoryWatcher>{};
      final watcher = SourceWatcher(
        root: '/root',
        watcherFactory: (dir) => fakes[dir] = FakeDirectoryWatcher(dir),
      );
      await watcher.start();

      final also = watcher.watchAlso(outside.path);
      await watcher.stop();
      await also;

      expect(fakes.keys, ['/root']);
      await fakes['/root']!.closeStream();
    });

    test('a root whose own path says bazel- still delivers edits', () async {
      final fake = FakeDirectoryWatcher('/work/bazel-thing');
      final watcher = SourceWatcher(
        root: '/work/bazel-thing',
        watcherFactory: (_) => fake,
      );
      await watcher.start();
      final change = watcher.changes.first;
      fake.emit(WatchEvent(ChangeType.MODIFY, '/work/bazel-thing/lib/a.dart'));
      expect((await change).paths, {'/work/bazel-thing/lib/a.dart'});
      await watcher.stop();
      await fake.closeStream();
    });

    test(
      'debounces multiple file changes within the debounce window into one event',
      () async {
        final fake = FakeDirectoryWatcher('/root');
        final watcher = SourceWatcher(
          root: '/root',
          debounce: const Duration(milliseconds: 30),
          watcherFactory: (_) => fake,
        );
        await watcher.start();
        final events = <SourceChange>[];
        final first = Completer<void>();
        final sub = watcher.changes.listen((change) {
          events.add(change);
          if (!first.isCompleted) first.complete();
        });

        fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/a.dart'));
        fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/b.dart'));
        fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/c.dart'));

        // Wait for the flush itself, not for a wall-clock guess at when it
        // lands: under load the debounce timer can fire well after its 30ms.
        await first.future.timeout(const Duration(seconds: 10));
        // A second event would follow one debounce window later. Waiting a
        // few windows for it can only miss a split, never fail a correct run.
        await Future<void>.delayed(const Duration(milliseconds: 90));

        expect(events, hasLength(1));
        expect(events.first.paths, {
          '/root/lib/a.dart',
          '/root/lib/b.dart',
          '/root/lib/c.dart',
        });

        await sub.cancel();
        await watcher.stop();
        await fake.closeStream();
      },
    );

    // `start()` happens before the app launches; the consumer only subscribes
    // once the reload pipeline is wired, which on native is after the
    // compiler's first full compile. A change in that gap has to arrive when
    // the consumer shows up, not be dropped.
    test('delivers a change that landed before anyone subscribed', () async {
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(
        root: '/root',
        debounce: const Duration(milliseconds: 20),
        watcherFactory: (_) => fake,
      );
      await watcher.start();

      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/early.dart'));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // Only now does the pipeline exist and subscribe.
      final events = <SourceChange>[];
      final sub = watcher.changes.listen(events.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(events, hasLength(1));
      expect(events.first.paths, {'/root/lib/early.dart'});

      await sub.cancel();
      await watcher.stop();
      await fake.closeStream();
    });

    test('events arriving after the window flush separately', () async {
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(
        root: '/root',
        debounce: const Duration(milliseconds: 20),
        watcherFactory: (_) => fake,
      );
      await watcher.start();
      final events = <SourceChange>[];
      final sub = watcher.changes.listen(events.add);

      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/a.dart'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/b.dart'));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(events, hasLength(2));
      expect(events[0].paths, {'/root/lib/a.dart'});
      expect(events[1].paths, {'/root/lib/b.dart'});

      await sub.cancel();
      await watcher.stop();
      await fake.closeStream();
    });

    test('ignores non-.dart files', () async {
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(
        root: '/root',
        debounce: const Duration(milliseconds: 20),
        watcherFactory: (_) => fake,
      );
      await watcher.start();
      final events = <SourceChange>[];
      final sub = watcher.changes.listen(events.add);

      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/a.dart'));
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/README.md'));
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/foo.yaml'));

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(events, hasLength(1));
      expect(events.first.paths, {'/root/lib/a.dart'});

      await sub.cancel();
      await watcher.stop();
      await fake.closeStream();
    });

    test('a custom filter widens what reaches the pipeline', () async {
      // Assets have no extension in common and no fixed location — which
      // directories feed the bundle is something the build knows and the
      // watcher is told. The default filter would drop every one of them.
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(
        root: '/root',
        debounce: const Duration(milliseconds: 20),
        watcherFactory: (_) => fake,
        accepts: (path) =>
            isDartSource(path) || path.startsWith('/root/assets/'),
      );
      await watcher.start();
      final events = <SourceChange>[];
      final sub = watcher.changes.listen(events.add);

      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/a.dart'));
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/assets/logo.png'));
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/README.md'));

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(events.single.paths, {
        '/root/lib/a.dart',
        '/root/assets/logo.png',
      });

      await sub.cancel();
      await watcher.stop();
      await fake.closeStream();
    });

    test('a widened filter still never sees the build tree', () async {
      // `bazel-bin` holds copies of the assets, written by the very build a
      // reload runs — accepting them would make each reload trigger the next.
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(
        root: '/root',
        debounce: const Duration(milliseconds: 20),
        watcherFactory: (_) => fake,
        accepts: (_) => true,
      );
      await watcher.start();
      final events = <SourceChange>[];
      final sub = watcher.changes.listen(events.add);

      fake.emit(
        WatchEvent(
          ChangeType.MODIFY,
          '/root/bazel-bin/app_flutter_assets/logo.png',
        ),
      );
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/assets/logo.png'));

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(events.single.paths, {'/root/assets/logo.png'});

      await sub.cancel();
      await watcher.stop();
      await fake.closeStream();
    });

    test('ignores files inside bazel-* directories', () async {
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(
        root: '/root',
        debounce: const Duration(milliseconds: 20),
        watcherFactory: (_) => fake,
      );
      await watcher.start();
      final events = <SourceChange>[];
      final sub = watcher.changes.listen(events.add);

      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/bazel-out/x.dart'));
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/bazel-bin/y.dart'));
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/keep.dart'));

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(events, hasLength(1));
      expect(events.first.paths, {'/root/lib/keep.dart'});

      await sub.cancel();
      await watcher.stop();
      await fake.closeStream();
    });

    test('stop() cancels pending debounce and closes the stream', () async {
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(
        root: '/root',
        debounce: const Duration(milliseconds: 100),
        watcherFactory: (_) => fake,
      );
      await watcher.start();
      final events = <SourceChange>[];
      final sub = watcher.changes.listen(events.add);

      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/a.dart'));
      // Stop before the debounce fires.
      await watcher.stop();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        events,
        isEmpty,
        reason: 'pending debounce should not fire after stop()',
      );

      await sub.cancel();
      await fake.closeStream();
    });

    test(
      'SourceChange.paths convert to package: URIs via the resolver',
      () async {
        // Documentation test: pinning that the consumer pattern
        // (watcher → SourceUriResolver.uriFor) yields the expected URIs.
        final resolver = SourceUriResolver(
          workspaceRoot: '/root',
          sourcePackages: const [(name: 'app', packageRoot: '')],
        );
        final change = SourceChange({'/root/lib/foo/bar.dart'});
        final uris = change.paths.map(resolver.uriFor).toSet();
        expect(uris, {'package:app/foo/bar.dart'});
      },
    );
  });

  /// A watcher that has stopped seeing edits must say so.
  ///
  /// package:watcher's macOS implementation closes itself permanently on a
  /// post-ready stream end and on any error. With no handler for either,
  /// `--watch` goes on claiming to watch while every subsequent edit vanishes —
  /// the failure mode a dev tool can least afford, because it looks exactly
  /// like working.
  group('SourceWatcher failure', () {
    test('reports an error from the underlying watcher', () async {
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(root: '/root', watcherFactory: (_) => fake);
      await watcher.start();

      fake.emitError(StateError('FSEvents died'));

      final failure = await watcher.failed.timeout(const Duration(seconds: 5));
      expect(failure.error, isA<StateError>());
      expect(failure.reason, contains('error'));
    });

    test('reports a stream that ends after ready', () async {
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(root: '/root', watcherFactory: (_) => fake);
      await watcher.start();

      await fake.closeStream();

      final failure = await watcher.failed.timeout(const Duration(seconds: 5));
      expect(failure.error, isNull, reason: 'an end is not an error');
      expect(failure.reason, isNotEmpty);
    });

    test(
      'drops a pending debounce rather than flushing the death throes',
      () async {
        // package:watcher emits a REMOVE for every known file before it closes.
        // Flushing those would hand the pipeline one enormous spurious change
        // and then fall silent, which is worse than either alone.
        final fake = FakeDirectoryWatcher('/root');
        final watcher = SourceWatcher(
          root: '/root',
          debounce: const Duration(milliseconds: 50),
          watcherFactory: (_) => fake,
        );
        await watcher.start();

        final seen = <SourceChange>[];
        watcher.changes.listen(seen.add);

        fake.emit(WatchEvent(ChangeType.REMOVE, '/root/lib/a.dart'));
        await fake.closeStream();
        await watcher.failed.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(
          seen,
          isEmpty,
          reason: 'the pending window belonged to a watcher that has died',
        );
      },
    );

    test('a deliberate stop is not a failure', () async {
      final fake = FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(root: '/root', watcherFactory: (_) => fake);
      await watcher.start();

      await watcher.stop();

      var reported = false;
      unawaited(watcher.failed.then((_) => reported = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        reported,
        isFalse,
        reason:
            'shutting the watcher down on purpose must not look like it '
            'dying underneath the run',
      );
    });
  });
}
