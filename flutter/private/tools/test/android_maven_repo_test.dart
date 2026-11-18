import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../android_maven_repo.dart';
import '../maven_repo.dart';

void main() {
  group('checksums', () {
    test('sha1 is SHA-1', () {
      expect(sha1Hex([]), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
      expect(
        sha1Hex(utf8.encode('abc')),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
      );
      // Two blocks of padding.
      expect(
        sha1Hex(
          utf8.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '84983e441c3bd26ebaae4aa1f95129e5e54670f1',
      );
      expect(
        sha1Hex(List.filled(1000000, 0x61)),
        '34aa973cd4c4daa4f61eeb2bdbad27316534016f',
      );
    });

    test('md5 is MD5', () {
      expect(md5Hex([]), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(md5Hex(utf8.encode('abc')), '900150983cd24fb0d6963f7d28e17f72');
      expect(
        md5Hex(
          utf8.encode(
            '12345678901234567890123456789012345678901234567890123456789012345678901234567890',
          ),
        ),
        '57edf4a22be3c955ac49da2e2107b67a',
      );
    });
  });

  test('pom lists the dependencies as Gradle does', () {
    final xml = pom(
      group: 'com.example.module',
      artifact: 'flutter_release',
      version: '1.0',
      packaging: 'aar',
      dependencies: [
        MavenDependency(
          group: 'io.flutter',
          artifact: 'flutter_embedding_release',
          version: '1.0.0-abc',
          scope: 'compile',
        ),
      ],
    );
    expect(xml, contains('<groupId>com.example.module</groupId>'));
    expect(xml, contains('<packaging>aar</packaging>'));
    expect(
      xml,
      contains(
        '    <dependency>\n'
        '      <groupId>io.flutter</groupId>\n'
        '      <artifactId>flutter_embedding_release</artifactId>\n'
        '      <version>1.0.0-abc</version>\n'
        '      <scope>compile</scope>\n'
        '    </dependency>\n',
      ),
    );
  });

  test('a POM with no dependencies has no dependencies element', () {
    expect(
      pom(
        group: 'g',
        artifact: 'a',
        version: '1',
        packaging: 'aar',
        dependencies: [],
      ),
      isNot(contains('<dependencies>')),
    );
  });

  test('layOut writes each artifact with its checksums', () {
    final tmp = Directory.systemTemp.createTempSync('maven_repo_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final aar = File('${tmp.path}/in.aar')..writeAsStringSync('aar');
    layOut(
      {
        'artifacts': [
          {
            'group': 'io.flutter.plugins.pathprovider',
            'artifact': 'path_provider_android_release',
            'version': '1.0',
            'packaging': 'aar',
            'dependencies': [
              {
                'group': 'androidx.annotation',
                'artifact': 'annotation',
                'version': '1.9.1',
                'scope': 'runtime',
              },
            ],
          },
        ],
      },
      [aar.path],
      '${tmp.path}/repo',
    );
    const base =
        'io/flutter/plugins/pathprovider/path_provider_android_release/1.0/'
        'path_provider_android_release-1.0';
    final files = [
      for (final f in Directory('${tmp.path}/repo').listSync(recursive: true))
        if (f is File)
          f.path.substring('${tmp.path}/repo/'.length).replaceAll(r'\', '/'),
    ]..sort();
    expect(files, [
      '$base.aar',
      '$base.aar.md5',
      '$base.aar.sha1',
      '$base.pom',
      '$base.pom.md5',
      '$base.pom.sha1',
    ]);
    expect(
      File('${tmp.path}/repo/$base.aar.sha1').readAsStringSync(),
      sha1Hex(utf8.encode('aar')),
    );
    final pomText = File('${tmp.path}/repo/$base.pom').readAsStringSync();
    expect(pomText, contains('<artifactId>annotation</artifactId>'));
    expect(pomText, contains('<scope>runtime</scope>'));
    expect(
      File('${tmp.path}/repo/$base.pom.md5').readAsStringSync(),
      md5Hex(utf8.encode(pomText)),
    );
  });

  test('layOut writes an engine jar at its own version', () {
    final tmp = Directory.systemTemp.createTempSync('maven_repo_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final jar = File('${tmp.path}/libs.zip')..writeAsStringSync('jar');
    layOut(
      {
        'artifacts': [
          {
            'group': 'io.flutter',
            'artifact': 'arm64_v8a_release',
            'version': '1.0.0-abc',
            'packaging': 'jar',
            'dependencies': [],
          },
        ],
      },
      [jar.path],
      '${tmp.path}/repo',
    );
    const base =
        'io/flutter/arm64_v8a_release/1.0.0-abc/arm64_v8a_release-1.0.0-abc';
    expect(File('${tmp.path}/repo/$base.jar').readAsStringSync(), 'jar');
    expect(
      File('${tmp.path}/repo/$base.pom').readAsStringSync(),
      contains('<packaging>jar</packaging>'),
    );
  });

  test('layOut refuses a packaging it does not know', () {
    final tmp = Directory.systemTemp.createTempSync('maven_repo_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    expect(
      () => layOut(
        {
          'artifacts': [
            {
              'group': 'g',
              'artifact': 'a',
              'version': '1',
              'packaging': 'apk',
              'dependencies': [],
            },
          ],
        },
        ['${tmp.path}/x'],
        '${tmp.path}/repo',
      ),
      throwsFormatException,
    );
  });

  test('layOut refuses a spec that disagrees with its archives', () {
    expect(
      () => layOut({'artifacts': []}, ['x.aar'], '/nonexistent'),
      throwsFormatException,
    );
  });
}
