/// What [NativeLibsWatch] answers, which is the only thing standing between a
/// rebuilt native library and an increment injected over the machine code the
/// running process actually has.
import 'dart:io';

import 'package:flutter_bazel_dev_tool/native_libs_watch.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('nlw_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File lib(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  test('says nothing moved while the build writes the same bytes', () async {
    final a = lib('liba.dylib', [1, 2, 3]);
    final watch = await NativeLibsWatch.of([a.path]);

    expect(await watch.movedSinceLaunch(), isEmpty);
    // A rebuild that re-ran the native action and produced identical bytes —
    // measured in this repo: editing `a * b` to `a * b + 0` advances the output's
    // mtime, and a `-c dbg` compile can still emit the same image. Reporting it
    // would withhold a reload that was perfectly safe.
    a.writeAsBytesSync([1, 2, 3]);
    expect(await watch.movedSinceLaunch(), isEmpty);
  });

  test('a library bazel did not rewrite is never read', () async {
    // The fast path, pinned by defeating it. A `stat` costs 33µs and hashing a
    // 20MB debug library costs 126ms (both measured), so a reload reads only the
    // libraries whose size or mtime moved. Here the bytes change while the stamp
    // is put back exactly as it was: the watch answers "nothing moved", which is
    // the documented limit of the prefilter and the reason it is safe — bazel
    // advances an output's mtime whenever it re-runs the action that writes it,
    // so the case constructed here is one no build produces.
    final a = lib('liba.dylib', [1, 2, 3]);
    final stamp = a.statSync();
    final watch = await NativeLibsWatch.of([a.path]);

    a.writeAsBytesSync([9, 9, 9]);
    a.setLastModifiedSync(stamp.modified);
    expect(await watch.movedSinceLaunch(), isEmpty);

    // And once the mtime moves the way a real rebuild moves it, the content is
    // read and the change is reported.
    a.setLastModifiedSync(stamp.modified.add(const Duration(seconds: 1)));
    expect(await watch.movedSinceLaunch(), [a.path]);
  });

  test('names the library whose bytes moved', () async {
    final a = lib('liba.dylib', [1, 2, 3]);
    final b = lib('libb.dylib', [4, 5, 6]);
    final watch = await NativeLibsWatch.of([a.path, b.path]);

    // Same length, different bytes: a body-only native edit, which is the
    // case that leaves the generated Dart byte-identical and so has nothing
    // else anywhere to announce it. Measured in this repo on a real C edit —
    // the rebuilt `libmul.dylib` came back at 16992 bytes both times with a
    // different hash — so a size comparison alone would miss exactly this.
    b.writeAsBytesSync([4, 5, 7]);
    expect(await watch.movedSinceLaunch(), [b.path]);
  });

  test('a declared library the build never wrote is loud', () async {
    final a = lib('liba.dylib', [1]);
    final watch = await NativeLibsWatch.of([a.path]);
    a.deleteSync();
    // Not "nothing moved", which would let an increment land on stale machine
    // code, and not "moved", which would blame the app's source for a broken
    // build. The build declared this path and did not write it.
    await expectLater(
      watch.movedSinceLaunch(),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('keeps saying so until the process is replaced', () async {
    final a = lib('liba.dylib', [1]);
    final watch = await NativeLibsWatch.of([a.path]);
    a.writeAsBytesSync([2]);

    expect(await watch.movedSinceLaunch(), [a.path]);
    // Asked again, with nothing having changed in between: the app is still
    // running the old image, so the answer is still yes. A watch that advanced
    // its baseline on merely *reporting* a change would let the next reload
    // inject over stale machine code — the build has moved on, the process has
    // not.
    expect(await watch.movedSinceLaunch(), [a.path]);
  });

  test('a relaunch is what clears it', () async {
    final a = lib('liba.dylib', [1]);
    final watch = await NativeLibsWatch.of([a.path]);
    a.writeAsBytesSync([2]);
    expect(await watch.movedSinceLaunch(), isNotEmpty);

    // The process was replaced, so it launched with the libraries on disk now.
    await watch.markLive();
    expect(await watch.movedSinceLaunch(), isEmpty);

    // And the next change is caught against the new baseline, not the old one.
    a.writeAsBytesSync([3]);
    expect(await watch.movedSinceLaunch(), [a.path]);
  });
}
