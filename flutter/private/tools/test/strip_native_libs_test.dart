import 'package:test/test.dart';

import '../strip_native_libs.dart';

void main() {
  group('nativeLibraries', () {
    test('takes every shared object under lib/', () {
      expect(
        nativeLibraries([
          'META-INF/MANIFEST.MF',
          'io/flutter/embedding/engine/FlutterJNI.class',
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libVkLayer_khronos_validation.so',
        ]),
        [
          'lib/arm64-v8a/libflutter.so',
          'lib/arm64-v8a/libVkLayer_khronos_validation.so',
        ],
      );
    });

    test('leaves shared objects outside lib/ alone', () {
      expect(nativeLibraries(['assets/libfoo.so', 'lib/README']), isEmpty);
    });
  });

  group('jarEntryName', () {
    test('joins a Windows path with /', () {
      expect(
        jarEntryName(r'lib\arm64-v8a\libflutter.so', r'\'),
        'lib/arm64-v8a/libflutter.so',
      );
    });

    test('keeps a POSIX path as it is', () {
      expect(
        jarEntryName('lib/arm64-v8a/libflutter.so', '/'),
        'lib/arm64-v8a/libflutter.so',
      );
    });
  });

  group('entriesProblem', () {
    const jar = ['META-INF/MANIFEST.MF', 'lib/arm64-v8a/libflutter.so'];

    test('splits a jar that has a native library', () {
      expect(entriesProblem(jar, nativeLibraries(jar), split: true), isNull);
    });

    test('refuses to split a jar with no native library', () {
      expect(
        entriesProblem(['META-INF/MANIFEST.MF'], [], split: true),
        'has no lib/**.so entry to strip',
      );
    });

    test('takes a zip of native libraries alone, or an empty one', () {
      const libs = ['lib/x86_64/libapp.so', 'lib/x86_64/libadd.so'];
      expect(entriesProblem(libs, libs, split: false), isNull);
      expect(entriesProblem([], [], split: false), isNull);
    });

    test('refuses a zip of libraries with anything else in it', () {
      expect(
        entriesProblem(jar, nativeLibraries(jar), split: false),
        'is not a zip of native libraries alone: it has META-INF/MANIFEST.MF',
      );
    });
  });

  test('strips as the Android Gradle Plugin does', () {
    expect(stripArguments(input: 'in.so', output: 'out.so'), [
      '--strip-unneeded',
      '-o',
      'out.so',
      'in.so',
    ]);
  });
}
