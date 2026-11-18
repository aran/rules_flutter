import 'dart:typed_data';

import 'package:test/test.dart';

import '../elf_runpath.dart';
import 'elf_fixture.dart';

// What Bazel links a `cc_shared_library` with a dynamic dependency with.
const _bazelRunpath =
    r'$ORIGIN/_solib_k8/_U:$ORIGIN/libtop.so.runfiles/_main/_solib_k8/_U:'
    r'$ORIGIN/../../_solib_k8/_U';

void main() {
  group('bundleRunpath', () {
    test('makes the entries relative to the library one \$ORIGIN', () {
      expect(bundleRunpath(_bazelRunpath), r'$ORIGIN');
    });

    test('keeps the other entries, in order', () {
      expect(
        bundleRunpath(r'/opt/a:$ORIGIN/_solib_k8/_U:/opt/b:${ORIGIN}/x'),
        r'/opt/a:$ORIGIN:/opt/b',
      );
    });

    test('leaves a runpath with no entry relative to the library', () {
      expect(bundleRunpath('/opt/a:/opt/b'), '/opt/a:/opt/b');
      expect(bundleRunpath(r'$ORIGIN'), r'$ORIGIN');
    });
  });

  group('ElfDynamic', () {
    for (final is64 in [true, false]) {
      test(
        'reads what an ELF${is64 ? 64 : 32} library links and its paths',
        () {
          final elf = ElfDynamic.read(
            elfLibrary(
              needed: ['libbase.so', 'libc.so.6'],
              soname: 'libtop.so',
              runpath: _bazelRunpath,
              rpath: '/opt/a',
              is64: is64,
            ),
            'libtop.so',
          );
          expect(elf.needed, ['libbase.so', 'libc.so.6']);
          expect(elf.runpath, _bazelRunpath);
          expect(elf.rpath, '/opt/a');
        },
      );
    }

    test('refuses a file that is not ELF', () {
      expect(
        () => ElfDynamic.read(Uint8List.fromList(List.filled(64, 0)), 'x'),
        throwsFormatException,
      );
    });
  });

  group('bundledRunpath', () {
    test('rewrites the runpath in place, nothing else moving', () {
      final before = elfLibrary(
        needed: ['libbase.so'],
        soname: 'libtop.so',
        runpath: _bazelRunpath,
        symbols: ['top'],
      );
      final after = bundledRunpath(before, 'libtop.so');
      expect(after.length, before.length);
      final elf = ElfDynamic.read(after, 'libtop.so');
      expect(elf.runpath, r'$ORIGIN');
      expect(elf.needed, ['libbase.so']);
      // The original is left as it was.
      expect(ElfDynamic.read(before, 'libtop.so').runpath, _bazelRunpath);
    });

    test('rewrites a DT_RPATH as it does a DT_RUNPATH', () {
      final after = bundledRunpath(
        elfLibrary(rpath: r'$ORIGIN/_solib_k8/_U'),
        'libtop.so',
      );
      expect(ElfDynamic.read(after, 'libtop.so').rpath, r'$ORIGIN');
    });

    test('returns a library with nothing to change as it is', () {
      final bytes = elfLibrary(needed: ['libc.so.6']);
      expect(identical(bundledRunpath(bytes, 'libbase.so'), bytes), isTrue);
      final absolute = elfLibrary(runpath: '/opt/a');
      expect(
        identical(bundledRunpath(absolute, 'libbase.so'), absolute),
        isTrue,
      );
    });

    test('refuses to rewrite a runpath whose string another shares', () {
      expect(
        () => bundledRunpath(
          elfLibrary(runpath: _bazelRunpath, symbolInRunpath: 20),
          'libtop.so',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('shared with another'),
          ),
        ),
      );
    });
  });
}
