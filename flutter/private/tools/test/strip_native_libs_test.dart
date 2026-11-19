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

    test('takes a file under lib/ that is not a library, as Gradle does', () {
      // An AAR's jni/<abi>/ may hold more than its .so files, and the
      // Android Gradle Plugin packages them all, stripping only the .so.
      const libs = ['lib/arm64-v8a/libfoo.so', 'lib/arm64-v8a/gdb.setup'];
      expect(nativeLibraries(libs), ['lib/arm64-v8a/libfoo.so']);
      expect(entriesProblem(libs, nativeLibraries(libs), split: false), isNull);
    });

    test('refuses a zip of libraries with an entry outside lib/', () {
      expect(
        entriesProblem(jar, nativeLibraries(jar), split: false),
        'is not a zip of native libraries: it has META-INF/MANIFEST.MF '
        'outside lib/',
      );
    });
  });

  group('parseArgs', () {
    const tools = ['--zipper', 'zipper', '--strip', 'strip'];

    test('pairs each zip with its stripped one, in order', () {
      final options = parseArgs([
        ...tools,
        '--input',
        'a.zip',
        '--libs',
        'a_stripped.zip',
        '--input',
        'b.zip',
        '--libs',
        'b_stripped.zip',
      ]);
      expect(options['--input'], ['a.zip', 'b.zip']);
      expect(options['--libs'], ['a_stripped.zip', 'b_stripped.zip']);
    });

    test('splits one jar', () {
      final options = parseArgs([
        ...tools,
        '--input',
        'flutter.jar',
        '--output',
        'classes.jar',
        '--libs',
        'libs.zip',
      ]);
      expect(options['--output'], ['classes.jar']);
    });

    test('refuses a zip with no stripped one', () {
      expect(
        () => parseArgs([
          ...tools,
          '--input',
          'a.zip',
          '--input',
          'b.zip',
          '--libs',
          'a_stripped.zip',
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'each --input needs one --libs',
          ),
        ),
      );
    });

    test('refuses to split more than one jar', () {
      expect(
        () => parseArgs([
          ...tools,
          '--input',
          'a.jar',
          '--libs',
          'a.zip',
          '--input',
          'b.jar',
          '--libs',
          'b.zip',
          '--output',
          'classes.jar',
        ]),
        throwsArgumentError,
      );
    });

    test('names what is missing', () {
      expect(
        () => parseArgs(['--zipper', 'zipper', '--input', 'a.zip']),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'missing --strip',
          ),
        ),
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
