import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../code_assets.dart';
import '../elf_runpath.dart' show ElfDynamic;
import 'elf_fixture.dart';
import '../zip_archive.dart' show readZip;

void main() {
  // rules_dart's conformance fixture, read in its directory.
  String fixture(String name) {
    final runfiles = Runfiles.create();
    return Platform.environment['CONFORMANCE']!
        .split(' ')
        .map(runfiles.rlocation)
        .whereType<String>()
        .firstWhere((p) => p.endsWith('/$name'));
  }

  String describe(CodeAsset asset, String base) => [
    'code',
    asset.id,
    asset.linkMode,
    if (asset.file != null)
      asset.file!.substring(base.length + 1)
    else if (asset.fileName != null)
      asset.fileName!
    else if (asset.uri != null)
      asset.uri!,
  ].join('\t');

  List<String> expectedCode(String base, String name) => File(
    '$base/$name',
  ).readAsLinesSync().where((l) => l.startsWith('code\t')).toList();

  group('ProgramCodeAssets', () {
    test('reads the code assets of the conformance fixture by name', () {
      final params = fixture('code_names.params');
      final base = File(params).parent.path;
      final program = ProgramCodeAssets.read(params, base: base);
      expect(
        [for (final a in program.shipped) describe(a, base)],
        expectedCode(base, 'code_names.expected.txt'),
      );
      expect(program.shipped.every((a) => a.file == null), isTrue);
    });

    test('reads them with their libraries, passing over the data', () {
      final params = fixture('program.params');
      final base = File(params).parent.path;
      final program = ProgramCodeAssets.read(params, base: base);
      expect(
        [for (final a in program.shipped) describe(a, base)],
        expectedCode(base, 'expected.txt'),
      );
    });

    test('knows the candidates a link hook chose among', () {
      final params = fixture('code_names.params');
      final program = ProgramCodeAssets.read(
        params,
        base: File(params).parent.path,
      );
      expect(program.shippedFileNames, {'libadd.so', 'libtrim.so'});
      expect(
        [for (final a in program.candidates) a.id],
        containsAll(['package:pick/add', 'package:pick/mul']),
      );
    });

    test('refuses a file without the code assets', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/data.params')
        ..writeAsStringSync(
          '--format\n$programAssetsFormat\n--paths\nexec\n--holds\ndata\n',
        );
      expect(
        () => ProgramCodeAssets.read(file.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses another format', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/other.params')
        ..writeAsStringSync(
          '--format\nrules_dart_program_assets/2\n--paths\nexec\n--holds\ncode\n',
        );
      expect(
        () => ProgramCodeAssets.read(file.path),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('CodeAssetPlacement', () {
    test('places a library where each platform loads it from', () {
      expect(
        CodeAssetPlacement('linux').bundlePath('libfoo.so'),
        'lib/libfoo.so',
      );
      expect(CodeAssetPlacement('windows').bundlePath('foo.dll'), 'foo.dll');
      expect(
        CodeAssetPlacement('android', abi: 'arm64-v8a').bundlePath('libfoo.so'),
        'lib/arm64-v8a/libfoo.so',
      );
      expect(
        CodeAssetPlacement('macos').bundlePath('libfoo.dylib'),
        'Contents/Frameworks/libfoo.dylib',
      );
      expect(
        CodeAssetPlacement('ios').bundlePath('libfoo.dylib'),
        'Frameworks/foo.framework/foo',
      );
    });

    test('names a library by its path in the code-asset directory', () {
      expect(CodeAssetPlacement('macos').pathInDirectory('a.dylib'), 'a.dylib');
      expect(
        CodeAssetPlacement('ios').pathInDirectory('objective_c.dylib'),
        'objective_c.framework/objective_c',
      );
    });

    test('needs an ABI on Android and a known OS', () {
      expect(() => CodeAssetPlacement('android'), throwsArgumentError);
      expect(() => CodeAssetPlacement('fuchsia'), throwsArgumentError);
    });

    test('derives framework names as flutter_tools does', () {
      // flutter_tools 3.50's cases for `frameworkUri`.
      expect(frameworkName('libfoo.dylib'), 'foo');
      expect(frameworkName('foo'), 'foo');
      expect(frameworkName('foo_foo'), 'foo_foo');
      expect(frameworkName('foo-foo'), 'foo-foo');
      expect(frameworkName(r'foo$foo'), 'foofoo');
      expect(frameworkName('foo.foo'), 'foo.foo');
      expect(frameworkName('foo.1.2.3'), 'foo.1.2.3');
      expect(
        frameworkName('libatoolongfilenameforaframework.dylib'),
        'atoolongfilenameforaframework',
      );

      expect(frameworkName('objective_c.dylib'), 'objective_c');
      expect(frameworkName('foo.bar.dylib'), 'foo.bar');
      expect(frameworkName('libfoo.bar.dylib'), 'foo.bar');
      expect(frameworkName('libfoo'), 'libfoo');
      expect(frameworkName('libfoo.so'), 'libfoo.so');
      expect(frameworkName('my-lib_2.dylib'), 'my-lib_2');
      expect(frameworkName('foo bar+\u00e9.dylib'), 'foobar');
    });
  });

  group('place', () {
    test('copies what ships and what always does, nothing dropped', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final params = fixture('program.params');
      final program = ProgramCodeAssets.read(
        params,
        base: File(params).parent.path,
      );
      final always = File('${dir.path}/in/libnative.so')
        ..createSync(recursive: true)
        ..writeAsStringSync('native');
      final out = '${dir.path}/out';
      place(program, CodeAssetPlacement('windows'), out, [always.path]);
      final placed = [
        for (final f in Directory(out).listSync(recursive: true))
          if (f is File) f.path.substring(out.length + 1),
      ]..sort();
      expect(placed, ['libadd.so', 'libnative.so', 'libtrim.so']);
    });

    test('places a library that ships from its copy of the same name', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final params = fixture('program.params');
      final program = ProgramCodeAssets.read(
        params,
        base: File(params).parent.path,
      );
      final copy = File('${dir.path}/stripped/libadd.so')
        ..createSync(recursive: true)
        ..writeAsStringSync('stripped');
      final out = '${dir.path}/out';
      place(
        program,
        CodeAssetPlacement('windows'),
        out,
        [],
        copies: [copy.path],
      );
      expect(File('$out/libadd.so').readAsStringSync(), 'stripped');
      expect(File('$out/libtrim.so').existsSync(), isTrue);
    });

    test('refuses a file that holds the code assets by name', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final params = fixture('code_names.params');
      final program = ProgramCodeAssets.read(
        params,
        base: File(params).parent.path,
      );
      expect(
        () => place(program, CodeAssetPlacement('linux'), dir.path, []),
        throwsStateError,
      );
    });
  });

  group('place on Linux', () {
    // What Bazel links a `cc_shared_library` with a dynamic dependency with.
    const bazelRunpath =
        r'$ORIGIN/_solib_k8/_U:$ORIGIN/libtop.so.runfiles/_main/_solib_k8/_U';

    String library(Directory dir, String name, List<int> bytes) =>
        (File('${dir.path}/in/$name')
              ..createSync(recursive: true)
              ..writeAsBytesSync(bytes))
            .path;

    test('a library finds the code assets it links by \$ORIGIN', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final top = library(
        dir,
        'libtop.so',
        elfLibrary(
          needed: ['libbase.so', 'libc.so.6'],
          soname: 'libtop.so',
          runpath: bazelRunpath,
        ),
      );
      final base = library(
        dir,
        'libbase.so',
        elfLibrary(needed: ['libc.so.6'], soname: 'libbase.so'),
      );
      final out = '${dir.path}/out';
      place(_empty(dir), CodeAssetPlacement('linux'), out, [top, base]);
      final placed = ElfDynamic.read(
        File('$out/libtop.so').readAsBytesSync(),
        'libtop.so',
      );
      expect(placed.runpath, r'$ORIGIN');
      expect(placed.needed, ['libbase.so', 'libc.so.6']);
      expect(
        ElfDynamic.read(File('$out/libbase.so').readAsBytesSync(), 'b').runpath,
        isNull,
      );
    });

    test('refuses a library that links one beside it with no \$ORIGIN', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final top = library(
        dir,
        'libtop.so',
        elfLibrary(needed: ['libbase.so'], runpath: '/opt/lib'),
      );
      final base = library(dir, 'libbase.so', elfLibrary());
      expect(
        () => place(
          _empty(dir),
          CodeAssetPlacement('linux'),
          '${dir.path}/out',
          [top, base],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('libtop.so links libbase.so'), contains(r'$ORIGIN')),
          ),
        ),
      );
    });

    test('refuses a library that is not ELF', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final text = library(dir, 'libtext.so', 'not a library'.codeUnits);
      expect(
        () => place(
          _empty(dir),
          CodeAssetPlacement('linux'),
          '${dir.path}/out',
          [text],
        ),
        throwsFormatException,
      );
    });
  });

  group('consistentShipped', () {
    test('is what the device ships, when every slice agrees', () {
      final params = fixture('code_names.params');
      final program = ProgramCodeAssets.read(
        params,
        base: File(params).parent.path,
      );
      expect(consistentShipped({'a': program, 'b': program}), {
        'libadd.so',
        'libtrim.so',
      });
    });

    test('fails on a simulator asset the device does not ship', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final params = fixture('code_names.params');
      final program = ProgramCodeAssets.read(
        params,
        base: File(params).parent.path,
      );
      final none = File('${dir.path}/none.params')
        ..writeAsStringSync(
          '--format\n$programAssetsFormat\n--paths\nexec\n--holds\ncode-names\n',
        );
      expect(
        () => consistentShipped({
          'device': ProgramCodeAssets.read(none.path),
          'simulator': program,
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(
              'the simulator build ships the code asset package:pick/add',
            ),
          ),
        ),
      );
      expect(
        consistentShipped({
          'device': program,
          'simulator': ProgramCodeAssets.read(none.path),
        }),
        {'libadd.so', 'libtrim.so'},
        reason: 'the device build is the source of truth',
      );
    });
  });

  test('packageSwift lists each binary once, sorted', () {
    expect(
      packageSwift('deps: [@DEPENDENCIES@]\n@BINARY_TARGETS@end', [
        'b',
        'a',
        'b',
      ]),
      'deps: ["a", "b"]\n'
      '        .binaryTarget(name: "a", path: "a.xcframework"),\n'
      '        .binaryTarget(name: "b", path: "b.xcframework"),\n'
      'end',
    );
  });

  group('nativeAssetsManifest', () {
    ProgramCodeAssets program() {
      final params = fixture('code_names.params');
      return ProgramCodeAssets.read(params, base: File(params).parent.path);
    }

    test('names what ships, as the engine loads it on each platform', () {
      final manifest = jsonDecode(
        nativeAssetsManifest(program(), 'linux', 'linux_x64'),
      ) as Map<String, Object?>;
      expect(manifest, {
        'format-version': [1, 0, 0],
        'native-assets': {
          'linux_x64': {
            'package:pick/add': ['absolute', 'libadd.so'],
            'package:sqlite/sqlite': ['system', 'libsqlite3.so.0'],
            'package:trim/ops': ['absolute', 'libtrim.so'],
          },
        },
      });
    });

    test('names an iOS library by its framework', () {
      final manifest = jsonDecode(
        nativeAssetsManifest(program(), 'ios', 'ios_arm64'),
      ) as Map<String, Object?>;
      final section =
          (manifest['native-assets']! as Map)['ios_arm64']
              as Map<String, Object?>;
      expect(section['package:pick/add'], [
        'absolute',
        '@rpath/libadd.so.framework/libadd.so',
      ]);
    });

    test('is empty with nothing to ship, and needs a target otherwise', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final none = File('${dir.path}/none.params')
        ..writeAsStringSync(
          '--format\n$programAssetsFormat\n--paths\nexec\n--holds\ncode-names\n',
        );
      expect(
        jsonDecode(
          nativeAssetsManifest(ProgramCodeAssets.read(none.path), 'macos', ''),
        ),
        {
          'format-version': [1, 0, 0],
          'native-assets': <String, Object?>{},
        },
      );
      expect(
        () => nativeAssetsManifest(program(), 'linux', ''),
        throwsStateError,
      );
    });
  });

  group('androidNativeLibs', () {
    test('packages what ships and what always does, stored', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final params = fixture('program.params');
      final program = ProgramCodeAssets.read(
        params,
        base: File(params).parent.path,
      );
      final aot = File('${dir.path}/app.so')..writeAsStringSync('aot-bytes');
      final zip = Uint8List.fromList(
        androidNativeLibs(program, 'arm64-v8a', {'libapp.so': aot.path}),
      );
      expect(
        [for (final e in readZip(zip)) e.name],
        [
          'lib/arm64-v8a/libadd.so',
          'lib/arm64-v8a/libapp.so',
          'lib/arm64-v8a/libtrim.so',
        ],
      );
      // Stored: the bytes are in the archive as they are.
      expect(
        String.fromCharCodes(zip).contains('aot-bytes'),
        isTrue,
        reason: 'stored, not deflated',
      );
    });

    test('refuses two libraries under one name', () {
      final dir = Directory.systemTemp.createTempSync('code_assets');
      addTearDown(() => dir.deleteSync(recursive: true));
      final params = fixture('program.params');
      final program = ProgramCodeAssets.read(
        params,
        base: File(params).parent.path,
      );
      final other = File('${dir.path}/libadd.so')..writeAsStringSync('x');
      expect(
        () => androidNativeLibs(program, 'x86_64', {'libadd.so': other.path}),
        throwsStateError,
      );
    });
  });

  test('iosDroppedFrameworks lists the framework of each dropped library', () {
    final params = fixture('code_names.params');
    final program = ProgramCodeAssets.read(
      params,
      base: File(params).parent.path,
    );
    expect(program.droppedFileNames, {'libmul.so'});
    expect(iosDroppedFrameworks(program), 'libmul.so.framework\n');
  });

  test('an app with its own post-processor fails only when one is dropped', () {
    final dir = Directory.systemTemp.createTempSync('code_assets');
    addTearDown(() => dir.deleteSync(recursive: true));
    final params = fixture('code_names.params');
    final program = ProgramCodeAssets.read(
      params,
      base: File(params).parent.path,
    );
    expect(
      () => iosDroppedFrameworks(program, conflict: '//app:post'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('//app:post'), contains('libmul.so.framework')),
        ),
      ),
    );
    final none = File('${dir.path}/none.params')
      ..writeAsStringSync(
        '--format\n$programAssetsFormat\n--paths\nexec\n--holds\ncode-names\n',
      );
    expect(
      iosDroppedFrameworks(
        ProgramCodeAssets.read(none.path),
        conflict: '//app:post',
      ),
      '',
    );
  });
}

/// A program that ships no code assets, so only `place`'s `always` libraries
/// are placed.
ProgramCodeAssets _empty(Directory dir) {
  final file = File('${dir.path}/empty.params')
    ..writeAsStringSync(
      '--format\n$programAssetsFormat\n--paths\nexec\n--holds\ncode\n',
    );
  return ProgramCodeAssets.read(file.path);
}
