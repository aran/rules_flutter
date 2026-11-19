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

  const embeddingPom = '''
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.flutter</groupId>
  <artifactId>flutter_embedding_release</artifactId>
  <version>1.0.0-abc</version>
  <packaging>jar</packaging>
  <dependencies>
    <dependency>
      <groupId>androidx.lifecycle</groupId>
      <artifactId>lifecycle-process</artifactId>
      <version>2.7.0</version>
      <scope>compile</scope>
    </dependency>
  </dependencies>
</project>
''';

  Map<String, Object?> embeddingSpec(String artifact) => {
    'engineVersion': {'pom': 'io.flutter:$artifact'},
    'artifacts': [
      {
        'group': 'io.flutter',
        'artifact': artifact,
        'engine': true,
        'packaging': 'jar',
        'dependencies': [],
      },
    ],
  };

  test("layOut publishes an engine's embedding with the engine's own POM", () {
    final tmp = Directory.systemTemp.createTempSync('maven_repo_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final jar = File('${tmp.path}/classes.jar')..writeAsStringSync('jar');
    final given = File('${tmp.path}/flutter_embedding_release.pom')
      ..writeAsStringSync(embeddingPom);
    layOut(
      embeddingSpec('flutter_embedding_release'),
      [jar.path],
      '${tmp.path}/repo',
      poms: {'io.flutter:flutter_embedding_release': given.path},
    );
    const base =
        'io/flutter/flutter_embedding_release/1.0.0-abc/'
        'flutter_embedding_release-1.0.0-abc';
    expect(
      File('${tmp.path}/repo/$base.pom').readAsStringSync(),
      embeddingPom,
    );
    expect(
      File('${tmp.path}/repo/$base.pom.sha1').readAsStringSync(),
      sha1Hex(utf8.encode(embeddingPom)),
    );
  });

  test("layOut publishes a custom engine's artifacts at its POM's version, "
      'and names them at it', () {
    final tmp = Directory.systemTemp.createTempSync('maven_repo_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final aar = File('${tmp.path}/module.aar')..writeAsStringSync('aar');
    final jar = File('${tmp.path}/classes.jar')..writeAsStringSync('jar');
    final libs = File('${tmp.path}/libs.zip')..writeAsStringSync('libs');
    // Not 1.0.0-<the revision the SDK's flutter_engine.json names>: a
    // custom engine's build may publish at any version.
    final custom = embeddingPom.replaceFirst('1.0.0-abc', '2.3.4-custom');
    final given = File('${tmp.path}/flutter_embedding_release.pom')
      ..writeAsStringSync(custom);
    Map<String, Object?> engine(String artifact) => {
      'group': 'io.flutter',
      'artifact': artifact,
      'engine': true,
      'scope': 'compile',
    };
    final published = layOut(
      {
        'engineVersion': {'pom': 'io.flutter:flutter_embedding_release'},
        'artifacts': [
          {
            'group': 'com.example.module',
            'artifact': 'flutter_release',
            'version': '1.0',
            'packaging': 'aar',
            'dependencies': [
              engine('flutter_embedding_release'),
              engine('arm64_v8a_release'),
            ],
          },
          {
            'group': 'io.flutter',
            'artifact': 'flutter_embedding_release',
            'engine': true,
            'packaging': 'jar',
            'dependencies': [],
          },
          {
            'group': 'io.flutter',
            'artifact': 'arm64_v8a_release',
            'engine': true,
            'packaging': 'jar',
            'dependencies': [],
          },
        ],
      },
      [aar.path, jar.path, libs.path],
      '${tmp.path}/repo',
      poms: {'io.flutter:flutter_embedding_release': given.path},
    );
    expect(published, [
      ('com.example.module', 'flutter_release', '1.0'),
      ('io.flutter', 'flutter_embedding_release', '2.3.4-custom'),
      ('io.flutter', 'arm64_v8a_release', '2.3.4-custom'),
    ]);
    expect(
      File(
        '${tmp.path}/repo/io/flutter/arm64_v8a_release/2.3.4-custom/'
        'arm64_v8a_release-2.3.4-custom.jar',
      ).readAsStringSync(),
      'libs',
    );
    final modulePom = File(
      '${tmp.path}/repo/com/example/module/flutter_release/1.0/'
      'flutter_release-1.0.pom',
    ).readAsStringSync();
    expect(
      RegExp('<version>2.3.4-custom</version>').allMatches(modulePom),
      hasLength(2),
    );
  });

  test(
    "layOut names a release engine's artifacts at the version it is given",
    () {
      final tmp = Directory.systemTemp.createTempSync('maven_repo_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final aar = File('${tmp.path}/plugin.aar')..writeAsStringSync('aar');
      layOut(
        {
          'engineVersion': {'version': '1.0.0-abc'},
          'artifacts': [
            {
              'group': 'io.flutter.plugins.pathprovider',
              'artifact': 'path_provider_android_release',
              'version': '1.0',
              'packaging': 'aar',
              'dependencies': [
                {
                  'group': 'io.flutter',
                  'artifact': 'flutter_embedding_release',
                  'engine': true,
                  'scope': 'compile',
                },
              ],
            },
          ],
        },
        [aar.path],
        '${tmp.path}/repo',
      );
      expect(
        File(
          '${tmp.path}/repo/io/flutter/plugins/pathprovider/'
          'path_provider_android_release/1.0/'
          'path_provider_android_release-1.0.pom',
        ).readAsStringSync(),
        contains(
          '      <artifactId>flutter_embedding_release</artifactId>\n'
          '      <version>1.0.0-abc</version>\n'
          '      <scope>compile</scope>\n',
        ),
      );
    },
  );

  test("layOut refuses an engine's POM of another artifact", () {
    final tmp = Directory.systemTemp.createTempSync('maven_repo_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final jar = File('${tmp.path}/classes.jar')..writeAsStringSync('jar');
    final given = File('${tmp.path}/flutter_embedding_debug.pom')
      ..writeAsStringSync(embeddingPom);
    expect(
      () => layOut(
        embeddingSpec('flutter_embedding_debug'),
        [jar.path],
        '${tmp.path}/repo',
        poms: {'io.flutter:flutter_embedding_debug': given.path},
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains(
            'it is the POM of io.flutter:flutter_embedding_release:1.0.0-abc',
          ),
        ),
      ),
    );
  });

  test('pomCoordinatesProblem reads the project, not its dependencies', () {
    expect(
      pomCoordinatesProblem(
        embeddingPom,
        group: 'io.flutter',
        artifact: 'flutter_embedding_release',
        version: '1.0.0-abc',
      ),
      isNull,
    );
    expect(
      pomCoordinatesProblem(
        '<project><dependencies><dependency><groupId>x</groupId>'
        '<artifactId>y</artifactId><version>1</version></dependency>'
        '</dependencies></project>',
        group: 'x',
        artifact: 'y',
        version: '1',
      ),
      isNotNull,
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
