import 'dart:io';

import 'package:test/test.dart';

import '../android_aar_install.dart';
import '../maven_repo.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('aar_install_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('publishMetadata', () {
    test('records a first version', () {
      publishMetadata(
        tmp.path,
        [('com.example.module', 'flutter_release', '1.0')],
        DateTime.utc(2026, 11, 10, 8, 9, 10),
      );
      final file = File(
        '${tmp.path}/com/example/module/flutter_release/maven-metadata.xml',
      );
      final xml = file.readAsStringSync();
      expect(
        xml,
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<metadata>\n'
        '  <groupId>com.example.module</groupId>\n'
        '  <artifactId>flutter_release</artifactId>\n'
        '  <versioning>\n'
        '    <latest>1.0</latest>\n'
        '    <release>1.0</release>\n'
        '    <versions>\n'
        '      <version>1.0</version>\n'
        '    </versions>\n'
        '    <lastUpdated>20261110080910</lastUpdated>\n'
        '  </versioning>\n'
        '</metadata>\n',
      );
      expect(
        File('${file.path}.sha1').readAsStringSync(),
        sha1Hex(file.readAsBytesSync()),
      );
      expect(
        File('${file.path}.md5').readAsStringSync(),
        md5Hex(file.readAsBytesSync()),
      );
    });

    test('keeps the versions earlier runs published', () {
      for (final version in ['1.0', '2.0', '1.0']) {
        publishMetadata(tmp.path, [
          ('com.example.module', 'flutter_debug', version),
        ], DateTime.utc(2026));
      }
      final metadata = MavenMetadata.parse(
        File(
          '${tmp.path}/com/example/module/flutter_debug/maven-metadata.xml',
        ).readAsStringSync(),
      );
      expect(metadata.versions, ['2.0', '1.0']);
      expect(metadata.latest, '1.0');
      expect(metadata.release, '1.0');
    });

    test('records each artifact at its own version', () {
      publishMetadata(tmp.path, [
        ('com.example.module', 'flutter_release', '1.0'),
        ('io.flutter', 'flutter_embedding_release', '1.0.0-abc'),
      ], DateTime.utc(2026));
      final engine = MavenMetadata.parse(
        File(
          '${tmp.path}/io/flutter/flutter_embedding_release/maven-metadata.xml',
        ).readAsStringSync(),
      );
      expect(engine.versions, ['1.0.0-abc']);
    });

    test('refuses the metadata of another artifact', () {
      final dir = Directory('${tmp.path}/a/b/c')..createSync(recursive: true);
      File('${dir.path}/maven-metadata.xml').writeAsStringSync(
        '<metadata><groupId>x</groupId><artifactId>y</artifactId></metadata>',
      );
      expect(
        () => publishMetadata(
          tmp.path,
          [('a.b', 'c', '1.0')],
          DateTime.utc(2026),
        ),
        throwsA(isA<InstallException>()),
      );
    });
  });

  test('copyTree replaces what an earlier run wrote', () {
    final from = Directory('${tmp.path}/from/x')..createSync(recursive: true);
    File('${from.path}/f').writeAsStringSync('new');
    final to = Directory('${tmp.path}/to/x')..createSync(recursive: true);
    File('${to.path}/f').writeAsStringSync('old');
    File('${to.path}/g').writeAsStringSync('kept');
    copyTree('${tmp.path}/from', '${tmp.path}/to');
    expect(File('${to.path}/f').readAsStringSync(), 'new');
    expect(File('${to.path}/g').readAsStringSync(), 'kept');
  });

  test('modesIn finds the module artifact of each mode', () {
    for (final mode in ['debug', 'release']) {
      File(
          '${tmp.path}/com/example/m/flutter_$mode/1.0/flutter_$mode-1.0.aar',
        )
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
    }
    expect(modesIn(tmp.path, 'com.example.m', '1.0'), ['debug', 'release']);
    expect(modesIn(tmp.path, 'com.example.m', '2.0'), isEmpty);
  });

  group('howToConsume', () {
    test('prints upstream\'s steps for the modes there are', () {
      final text = howToConsume(
        modes: ['debug', 'profile'],
        packageName: 'com.example.m',
        repo: '/r',
        buildNumber: '1.0',
      );
      expect(text, contains("url '/r'"));
      expect(text, contains(r'url "$storageUrl/download.flutter.io"'));
      expect(
        text,
        contains("debugImplementation 'com.example.m:flutter_debug:1.0'"),
      );
      expect(
        text,
        contains("profileImplementation 'com.example.m:flutter_profile:1.0'"),
      );
      expect(text, isNot(contains('releaseImplementation')));
      expect(text, contains('initWith debug'));
    });

    test('has no profile build type without profile', () {
      expect(
        howToConsume(
          modes: ['release'],
          packageName: 'p',
          repo: '/r',
          buildNumber: '1',
        ),
        isNot(contains('initWith debug')),
      );
    });
  });

  test('missingModes says how to build the modes there are not', () {
    expect(
      missingModes(['release'], '//:module_aar'),
      contains('bazel run -c dbg //:module_aar   # flutter_debug'),
    );
    expect(missingModes(['debug', 'profile', 'release'], '//:m'), isEmpty);
  });
}
