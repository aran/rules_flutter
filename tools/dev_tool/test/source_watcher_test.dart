import 'dart:async';

import 'package:flutter_bazel_dev_tool/hot_reload/source_watcher.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:test/test.dart';
import 'package:watcher/watcher.dart';

/// Programmable [DirectoryWatcher] for deterministic tests.
class _FakeDirectoryWatcher implements DirectoryWatcher {
  @override
  final String path;

  final StreamController<WatchEvent> _events =
      StreamController<WatchEvent>.broadcast();

  _FakeDirectoryWatcher(this.path);

  @override
  Stream<WatchEvent> get events => _events.stream;

  @override
  Future<void> get ready async {}

  @override
  bool get isReady => true;

  @override
  String get directory => path;

  void emit(WatchEvent event) => _events.add(event);

  Future<void> closeStream() => _events.close();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  group('SourceWatcher', () {
    test('debounces multiple file changes within the debounce window into one event',
        () async {
      final fake = _FakeDirectoryWatcher('/root');
      final watcher = SourceWatcher(
        root: '/root',
        debounce: const Duration(milliseconds: 30),
        watcherFactory: (_) => fake,
      );
      await watcher.start();
      final events = <SourceChange>[];
      final sub = watcher.changes.listen(events.add);

      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/a.dart'));
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/b.dart'));
      fake.emit(WatchEvent(ChangeType.MODIFY, '/root/lib/c.dart'));

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(events, hasLength(1));
      expect(events.first.paths, {
        '/root/lib/a.dart',
        '/root/lib/b.dart',
        '/root/lib/c.dart',
      });

      await sub.cancel();
      await watcher.stop();
      await fake.closeStream();
    });

    test('events arriving after the window flush separately', () async {
      final fake = _FakeDirectoryWatcher('/root');
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
      final fake = _FakeDirectoryWatcher('/root');
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

    test('ignores files inside bazel-* directories', () async {
      final fake = _FakeDirectoryWatcher('/root');
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
      final fake = _FakeDirectoryWatcher('/root');
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

      expect(events, isEmpty,
          reason: 'pending debounce should not fire after stop()');

      await sub.cancel();
      await fake.closeStream();
    });

    test('SourceChange.paths convert to frontend-server URIs via Workspace',
        () async {
      // Documentation test: pinning that the consumer pattern
      // (watcher → workspace.toFrontendServerUri) yields the expected URIs.
      final workspace = Workspace(
        root: '/root',
        entrypoint: 'package:app/main.dart',
      );
      final change = SourceChange({'/root/lib/foo/bar.dart'});
      final uris =
          change.paths.map(workspace.toFrontendServerUri).toSet();
      expect(uris, {'package:app/foo/bar.dart'});
    });
  });
}
