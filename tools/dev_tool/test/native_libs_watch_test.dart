/// What [NativeLibsWatch] answers, which is the only thing standing between a
/// rebuilt native library and an increment injected over machine code that cannot
/// serve it.
import 'dart:io';

import 'package:flutter_bazel_dev_tool/native_libs_watch.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('nlw_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File file(String name, List<int> bytes) =>
      File('${tmp.path}/$name')..writeAsBytesSync(bytes);

  test('current while the build writes the same bytes', () async {
    final lib = file('liba.dylib', [1, 2, 3]);
    final watch = await NativeLibsWatch.of({lib.path: const []});

    expect(await watch.verdict(), isA<NativeLibsCurrent>());
    // A rebuild that re-ran the native action and produced identical bytes —
    // measured in this repo: editing `a * b` to `a * b + 0` advances the output's
    // mtime, and a `-c dbg` compile can still emit the same image. Reporting it
    // would withhold a reload that was perfectly safe.
    lib.writeAsBytesSync([1, 2, 3]);
    expect(await watch.verdict(), isA<NativeLibsCurrent>());
  });

  test('a library bazel did not rewrite is never read', () async {
    // The fast path, pinned by defeating it. A `stat` costs 33µs and hashing a
    // 20MB debug library costs 126ms (both measured), so a command reads only the
    // files whose size or mtime moved. Here the bytes change while the stamp is
    // put back exactly as it was: the watch answers current, which is the
    // documented limit of the prefilter and the reason it is safe — bazel
    // advances an output's mtime whenever it re-runs the action that writes it,
    // so the case constructed here is one no build produces.
    final lib = file('liba.dylib', [1, 2, 3]);
    final stamp = lib.statSync();
    final watch = await NativeLibsWatch.of({lib.path: const []});

    lib.writeAsBytesSync([9, 9, 9]);
    lib.setLastModifiedSync(stamp.modified);
    expect(await watch.verdict(), isA<NativeLibsCurrent>());

    // And once the mtime moves the way a real rebuild moves it, the content is
    // read and the change is reported.
    lib.setLastModifiedSync(stamp.modified.add(const Duration(seconds: 1)));
    expect(await watch.verdict(), isA<NativeLibsUnverifiable>());
  });

  group('a library with no declared contract', () {
    test(
      'withholds, because nothing says whether its bindings moved',
      () async {
        final lib = file('libsqlite3.dylib', [1]);
        final watch = await NativeLibsWatch.of({lib.path: const []});

        lib.writeAsBytesSync([2]);
        expect(
          await watch.verdict(),
          isA<NativeLibsUnverifiable>().having((v) => v.libs, 'libs', [
            lib.path,
          ]),
        );
      },
    );

    test('withholds even beside a library whose contract held', () async {
      // Unknown beats known-safe: one library nothing describes is enough to
      // make the whole increment unsafe, however many of its neighbours declared
      // a contract.
      final bridge = file('libbridge.dylib', [1]);
      final contract = file('codegen.ir', [10]);
      final other = file('libother.dylib', [2]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
        other.path: const [],
      });

      bridge.writeAsBytesSync([3]);
      other.writeAsBytesSync([4]);
      expect(
        await watch.verdict(),
        isA<NativeLibsUnverifiable>().having((v) => v.libs, 'libs', [
          other.path,
        ]),
      );
    });
  });

  group('a library with a declared contract', () {
    test('delivers when only its code moved', () async {
      final bridge = file('libbridge.dylib', [1, 2, 3]);
      final contract = file('codegen.ir', [10, 11]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      // The body-only edit: the library is rebuilt, the interface it was
      // generated from is byte-identical, so the bindings about to be injected
      // are ones the loaded image can still serve.
      bridge.writeAsBytesSync([1, 2, 4]);
      expect(
        await watch.verdict(),
        isA<NativeCodeStale>().having((v) => v.libs, 'libs', [bridge.path]),
      );
    });

    test('withholds when the contract moved with it', () async {
      final bridge = file('libbridge.dylib', [1]);
      final contract = file('codegen.ir', [10]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      bridge.writeAsBytesSync([2]);
      contract.writeAsBytesSync([11]);
      final verdict = await watch.verdict();
      expect(
        verdict,
        isA<NativeBindingsMoved>()
            .having((v) => v.libs, 'libs', [bridge.path])
            .having((v) => v.contracts, 'contracts', [contract.path]),
      );
    });

    test('withholds on a contract that moved without its library', () async {
      // Not a shape one build produces — the interface and the library come from
      // the same source — so the answer is the safe one rather than a special
      // case. Naming the library rather than only the contract is what makes the
      // reply about something the reader recognises.
      final bridge = file('libbridge.dylib', [1]);
      final contract = file('codegen.ir', [10]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
      });

      contract.writeAsBytesSync([11]);
      expect(
        await watch.verdict(),
        isA<NativeBindingsMoved>().having((v) => v.libs, 'libs', [bridge.path]),
      );
    });
  });

  test('keeps saying so until the process is replaced', () async {
    final lib = file('liba.dylib', [1]);
    final watch = await NativeLibsWatch.of({lib.path: const []});
    lib.writeAsBytesSync([2]);

    expect(await watch.verdict(), isA<NativeLibsUnverifiable>());
    // Asked again with nothing changed in between: the app is still running the
    // old image, so the answer is still the same. A watch that advanced its
    // baseline on merely *reporting* a change would let the next reload inject
    // over stale machine code — the build has moved on, the process has not.
    expect(await watch.verdict(), isA<NativeLibsUnverifiable>());
  });

  test('a relaunch is what clears it', () async {
    final bridge = file('libbridge.dylib', [1]);
    final contract = file('codegen.ir', [10]);
    final watch = await NativeLibsWatch.of({
      bridge.path: [contract.path],
    });
    bridge.writeAsBytesSync([2]);
    contract.writeAsBytesSync([11]);
    expect(await watch.verdict(), isA<NativeBindingsMoved>());

    // The process was replaced, so it launched with the files on disk now.
    await watch.markLive();
    expect(await watch.verdict(), isA<NativeLibsCurrent>());

    // And the next change is caught against the new baseline, not the old one.
    bridge.writeAsBytesSync([3]);
    expect(await watch.verdict(), isA<NativeCodeStale>());
  });

  group('an app whose reload runs no build', () {
    // The silent shape this closes: nothing rebuilds the library between
    // reloads, so comparing libraries alone answered "current" to a native
    // edit and the increment went in over the machine code the app launched
    // with.
    test('reports the libraries when a native source moved', () async {
      final lib = file('libbridge.dylib', [1]);
      final contract = file('bridge.h', [10]);
      final source = file('bridge.c', [20]);
      final watch = await NativeLibsWatch.of(
        {
          lib.path: [contract.path],
        },
        sources: {
          lib.path: [source.path],
        },
      );

      expect(await watch.verdict(), isA<NativeLibsCurrent>());
      source.writeAsBytesSync([21]);
      expect(
        await watch.verdict(),
        isA<NativeCodeStale>().having((v) => v.libs, 'libs', [lib.path]),
        reason: 'the library is not rebuilt, so only its source can say this',
      );
      // And keeps saying it: only a new process, or a patch, changes what the
      // app is running.
      expect(await watch.verdict(), isA<NativeCodeStale>());

      await watch.markLive();
      expect(await watch.verdict(), isA<NativeLibsCurrent>());
    });

    test('a source rewritten with the same bytes is not a change', () async {
      final lib = file('libbridge.dylib', [1]);
      final source = file('bridge.c', [20]);
      final watch = await NativeLibsWatch.of(
        {
          lib.path: const [],
        },
        sources: {
          lib.path: [source.path],
        },
      );

      source.writeAsBytesSync([20]);
      expect(await watch.verdict(), isA<NativeLibsCurrent>());
    });

    test('answers for the library whose source moved, and no other', () async {
      final patched = file('libbridge.dylib', [1]);
      final other = file('libother.dylib', [2]);
      final bridgeSource = file('bridge.c', [20]);
      final otherSource = file('other.c', [30]);
      final watch = await NativeLibsWatch.of(
        {
          patched.path: const [],
          other.path: const [],
        },
        sources: {
          patched.path: [bridgeSource.path],
          other.path: [otherSource.path],
        },
      );

      bridgeSource.writeAsBytesSync([21]);
      expect(
        await watch.verdict(),
        isA<NativeLibsUnverifiable>().having((v) => v.libs, 'libs', [
          patched.path,
        ]),
        reason: 'an edit to one library says nothing about the other',
      );

      // A patch delivered that library's code, so its source goes live with it:
      // the app runs what the source says now.
      await watch.markPatched({'libbridge.dylib'});
      expect(await watch.verdict(), isA<NativeLibsCurrent>());
    });
  });

  test(
    'a native hot patch clears the library it delivered, and only that',
    () async {
      final bridge = file('libbridge.dylib', [1]);
      final other = file('libother.dylib', [5]);
      final contract = file('codegen.ir', [10]);
      final watch = await NativeLibsWatch.of({
        bridge.path: [contract.path],
        other.path: [contract.path],
      });
      bridge.writeAsBytesSync([2]);
      other.writeAsBytesSync([6]);

      // A patch put libbridge's new code into the running process; libother
      // still runs what it launched with.
      await watch.markPatched({'libbridge.dylib'});
      expect(
        await watch.verdict(),
        isA<NativeCodeStale>().having((v) => v.libs, 'libs', [other.path]),
      );
    },
  );

  test('a declared file the build never wrote is loud', () async {
    final lib = file('liba.dylib', [1]);
    final watch = await NativeLibsWatch.of({lib.path: const []});
    lib.deleteSync();
    // Not "current", which would let an increment land on stale machine code,
    // and not "moved", which would blame the app's source for a broken build.
    // The build declared this path and did not write it.
    await expectLater(watch.verdict(), throwsA(isA<FileSystemException>()));
  });
}
