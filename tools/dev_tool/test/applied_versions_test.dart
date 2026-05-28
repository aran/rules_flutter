import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/applied_versions.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AppliedVersions', () {
    late Directory tmp;
    late Workspace workspace;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('applied_versions_test_');
      Directory(p.join(tmp.path, 'lib')).createSync();
      workspace = Workspace(
        root: tmp.path,
        entrypoint: 'package:app/main.dart',
      );
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    void writeFile(String relPath, String content) {
      final f = File(p.join(tmp.path, 'lib', relPath));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    String uriFor(String relPath) => 'package:app/$relPath';

    test('findChangedFrom returns files whose disk version differs from applied version',
        () async {
      writeFile('a.dart', 'v1');
      final v1 = workspace.snapshot();
      final applied = AppliedVersions()..markApplied(v1, files: {uriFor('a.dart')});

      // Mutate the file: Dart's mtime stamping is monotonic per write on
      // APFS, but write a different content to bump size as well so the
      // Version compares unequal even on coarse-resolution filesystems.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('a.dart', 'v2 longer content');
      final v2 = workspace.snapshot();

      expect(applied.findChangedFrom(v2), {uriFor('a.dart')});
    });

    test('findChangedFrom returns files present on disk but not yet applied', () {
      writeFile('a.dart', 'v1');
      final v1 = workspace.snapshot();
      final applied = AppliedVersions();

      expect(applied.findChangedFrom(v1), {uriFor('a.dart')});
    });

    test('markApplied advances per-file — marking file A does not affect file B',
        () async {
      writeFile('a.dart', 'a-v1');
      writeFile('b.dart', 'b-v1');
      final v1 = workspace.snapshot();
      final applied = AppliedVersions();

      applied.markApplied(v1, files: {uriFor('a.dart')});

      // Only b.dart is unapplied; a.dart was just marked.
      expect(applied.findChangedFrom(v1), {uriFor('b.dart')});

      // Now edit a.dart — it should appear changed even though b.dart is
      // also un-applied (per-file state, not a global timestamp).
      await Future<void>.delayed(const Duration(milliseconds: 10));
      writeFile('a.dart', 'a-v2 longer');
      final v2 = workspace.snapshot();
      expect(
        applied.findChangedFrom(v2),
        {uriFor('a.dart'), uriFor('b.dart')},
      );
    });

    test('clear() makes every disk file appear changed on the next findChangedFrom',
        () {
      writeFile('a.dart', 'a-v1');
      writeFile('b.dart', 'b-v1');
      final v1 = workspace.snapshot();
      final applied = AppliedVersions()
        ..markApplied(v1, files: {uriFor('a.dart'), uriFor('b.dart')});

      expect(applied.findChangedFrom(v1), isEmpty);

      applied.clear();
      expect(applied.findChangedFrom(v1),
          {uriFor('a.dart'), uriFor('b.dart')});
    });

    test('a file declared by a caller but absent from the snapshot is silently ignored on markApplied',
        () {
      // Agents may pass invalidatedFiles for URIs that don't exist on disk
      // (e.g. about-to-be-flushed editor buffer). markApplied with such
      // a file should not crash; the file simply doesn't get recorded
      // until it appears in a real snapshot.
      writeFile('a.dart', 'a-v1');
      final v1 = workspace.snapshot();
      final applied = AppliedVersions();

      applied.markApplied(v1, files: {uriFor('phantom.dart'), uriFor('a.dart')});
      expect(applied.length, 1);
      expect(applied.versionOf(uriFor('a.dart')), isNotNull);
    });

    test('sub-second mtime precision is preserved on macOS APFS', () async {
      // If FileStat.modified truncates to seconds, two writes within the
      // same wall-second would produce identical Versions and AppliedVersions
      // would silently miss the second edit. macOS APFS supports nanosecond
      // mtime; Dart's FileStat.modified should carry it. This test pins that.
      if (!Platform.isMacOS) return; // APFS-specific assertion.
      writeFile('a.dart', 'v1');
      final t1 = File(p.join(tmp.path, 'lib', 'a.dart')).statSync().modified;
      // Write again with different content so size differs (covers the case
      // where FS resolution is coarser than the test sleep). Then assert that
      // mtime *also* differs — i.e. APFS sub-second precision is in effect.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      writeFile('a.dart', 'v2');
      final t2 = File(p.join(tmp.path, 'lib', 'a.dart')).statSync().modified;
      expect(t2.isAfter(t1), isTrue,
          reason: 'mtime should differ after a 5ms-apart rewrite on APFS');
    });
  });

  group('Workspace.snapshot', () {
    late Directory tmp;
    late Workspace workspace;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('workspace_test_');
      workspace = Workspace(
        root: tmp.path,
        entrypoint: 'package:app/main.dart',
      );
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('returns empty when lib/ does not exist', () {
      expect(workspace.snapshot().length, 0);
    });

    test('recurses into nested lib/ subdirectories', () {
      Directory(p.join(tmp.path, 'lib', 'a', 'b')).createSync(recursive: true);
      File(p.join(tmp.path, 'lib', 'a', 'b', 'c.dart'))
          .writeAsStringSync('// c');

      final snap = workspace.snapshot();
      expect(snap.fileUris, contains('package:app/a/b/c.dart'));
    });

    test('ignores non-dart files in lib/', () {
      Directory(p.join(tmp.path, 'lib')).createSync();
      File(p.join(tmp.path, 'lib', 'README.md')).writeAsStringSync('# notes');
      File(p.join(tmp.path, 'lib', 'a.dart')).writeAsStringSync('// a');

      final snap = workspace.snapshot();
      expect(snap.fileUris, ['package:app/a.dart']);
    });

    test('uses org-dartlang-app: scheme when entrypoint is web DDC', () {
      Directory(p.join(tmp.path, 'lib')).createSync();
      File(p.join(tmp.path, 'lib', 'a.dart')).writeAsStringSync('// a');

      final ddc = Workspace(
        root: tmp.path,
        entrypoint: 'org-dartlang-app:/web_entrypoint.dart',
      );
      final snap = ddc.snapshot();
      expect(snap.fileUris, contains('org-dartlang-app:/lib/a.dart'));
    });
  });
}
