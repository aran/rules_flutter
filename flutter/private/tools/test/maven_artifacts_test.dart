import 'dart:convert';

import 'package:test/test.dart';

import '../maven_artifacts.dart';

/// Gradle module metadata whose variants constrain [constraints], as
/// coordinate to version.
String metadata(Map<String, String> constraints, {String key = 'requires'}) =>
    jsonEncode({
      'formatVersion': '1.1',
      'variants': [
        for (final name in ['api', 'runtime'])
          {
            'name': name,
            'dependencyConstraints': [
              for (final MapEntry(key: coordinate, value: version)
                  in constraints.entries)
                {
                  'group': coordinate.split(':')[0],
                  'module': coordinate.split(':')[1],
                  'version': {key: version},
                },
            ],
          },
      ],
    });

void main() {
  group('compareVersions', () {
    test('orders numbers numerically and releases after qualifiers', () {
      expect(compareVersions('1.10.0', '1.9.0'), 1);
      expect(compareVersions('1.9', '1.9.0'), 0);
      expect(compareVersions('1.9.0-rc01', '1.9.0'), -1);
      expect(compareVersions('1.9.0-alpha01', '1.9.0-beta01'), -1);
    });
  });

  group('constraintsOf', () {
    test('reads every variant\'s constraints once', () {
      expect(
        constraintsOf(metadata({'androidx.activity:activity-ktx': '1.9.0'})),
        [(coordinate: 'androidx.activity:activity-ktx', version: '1.9.0')],
      );
    });

    test('reads strictly too', () {
      expect(constraintsOf(metadata({'g:a': '2.0'}, key: 'strictly')), [
        (coordinate: 'g:a', version: '2.0'),
      ]);
    });

    test('leaves out ranges and metadata without constraints', () {
      expect(constraintsOf(metadata({'g:a': '[1.0,2.0)'})), isEmpty);
      expect(
        constraintsOf(
          jsonEncode({
            'variants': [{}],
          }),
        ),
        isEmpty,
      );
    });
  });

  group('align', () {
    Future<List<Constraint>> Function(String, String) from(
      Map<String, Map<String, String>> byModule,
    ) =>
        (coordinate, version) async => [
          for (final MapEntry(:key, :value)
              in (byModule['$coordinate:$version'] ?? const {}).entries)
            (coordinate: key, version: value),
        ];

    test('raises a companion the main artifact constrains', () async {
      final aligned = await align(
        {'a:activity': '1.9.0', 'a:activity-ktx': '1.5.1'},
        from({
          'a:activity:1.9.0': {'a:activity-ktx': '1.9.0', 'a:compose': '1.9.0'},
          'a:activity-ktx:1.5.1': {'a:activity': '1.5.1'},
        }),
      );
      expect(aligned.keys, ['a:activity-ktx']);
      expect(aligned['a:activity-ktx']!.version, '1.9.0');
      expect(aligned['a:activity-ktx']!.by, 'a:activity 1.9.0');
    });

    test('follows the metadata of what it raised', () async {
      final aligned = await align(
        {'a:main': '2.0', 'a:ktx': '1.0', 'b:other': '1.0'},
        from({
          'a:main:2.0': {'a:ktx': '2.0'},
          'a:ktx:2.0': {'b:other': '3.0'},
        }),
      );
      expect(aligned.map((k, v) => MapEntry(k, v.version)), {
        'a:ktx': '2.0',
        'b:other': '3.0',
      });
    });
  });

  group('formatReport', () {
    test('marks what the plugins need and what Gradle would align', () {
      final report = formatReport(
        app: '//:app',
        requirements: {
          'g:fine': Requirement('1.0', ['package:a 1.2']),
          'g:old': Requirement('1.2', ['package:a 1.2']),
          'g:gone': Requirement(null, ['package:b 3.4']),
        },
        resolved: {'g:fine': '1.0', 'g:old': '1.1', 'a:ktx': '1.5.1'},
        aligned: {'a:ktx': Alignment('1.9.0', 'a:main 1.9.0')},
      );
      expect(
        report,
        contains('Android plugins that //:app links declare'),
      );
      expect(report, contains('# 2 of 3 are missing or too low'));
      expect(report, contains('# 1 more resolves lower than'));
      for (final line in [
        '        "g:fine:1.0",  # declared by package:a 1.2\n',
        '        "g:gone:<version>",  # declared by package:b 3.4; missing\n',
        '        "g:old:1.2",  # declared by package:a 1.2; resolves 1.1\n',
        '        "a:ktx:1.9.0",  # aligned with a:main 1.9.0; resolves 1.5.1\n',
      ]) {
        expect(report, contains(line));
      }
    });

    test('raises a declared artifact Gradle would align higher', () {
      final report = formatReport(
        app: null,
        requirements: {
          'a:ktx': Requirement('1.0', ['package:a 1.0']),
        },
        resolved: {'a:ktx': '1.0'},
        aligned: {'a:ktx': Alignment('1.9.0', 'a:main 1.9.0')},
      );
      expect(
        report,
        contains(
          '"a:ktx:1.9.0",  # declared by package:a 1.0; '
          'aligned with a:main 1.9.0; resolves 1.0',
        ),
      );
      expect(report, isNot(contains(' more resolve')));
    });

    test('lists the Gradle lines it could not read', () {
      final report = formatReport(
        app: null,
        requirements: {
          'g:a': Requirement('1.0', ['package:a 1.0']),
        },
        resolved: {'g:a': '1.0'},
        aligned: {},
        unread: [
          (
            package: 'package:b 2.0',
            script: 'android/build.gradle',
            lineNumber: 69,
            line: 'implementation platform("g:bom:\${bomVersion}")',
          ),
        ],
      );
      expect(report, contains('flutter_pub.annotation(package = ...'));
      expect(
        report,
        contains(
          '#   package:b 2.0, android/build.gradle:69: '
          'implementation platform("g:bom:\${bomVersion}")\n',
        ),
      );
      expect(
        formatReport(
          app: null,
          requirements: {},
          resolved: {},
          aligned: {},
        ),
        isNot(contains('does not read')),
      );
    });

    test('prints the BoMs, and an artifact\'s exclusions as its tag', () {
      final report = formatReport(
        app: null,
        requirements: {
          'com.google.firebase:firebase-common': Requirement(null, [
            'package:firebase_core 5.1.0',
          ], managed: true),
          'com.google.firebase:firebase-firestore': Requirement(
            null,
            ['package:cloud_firestore 7.2.0'],
            managed: true,
            exclusions: ['junit:junit', 'org.mockito:mockito-core'],
          ),
        },
        resolved: {},
        aligned: {},
        boms: {
          'com.google.firebase:firebase-bom': Requirement('35.1.0', [
            'package:cloud_firestore 7.2.0',
            'package:firebase_core 5.1.0',
          ]),
        },
      );
      expect(report, contains('# 3 of 3 are missing or too low'));
      for (final text in [
        '        "com.google.firebase:firebase-common",  '
            '# declared by package:firebase_core 5.1.0; missing\n',
        'boms = [...]), which gives\n',
        '        "com.google.firebase:firebase-bom:35.1.0",  # declared by '
            'package:cloud_firestore 7.2.0, package:firebase_core 5.1.0; '
            'missing\n',
        '# declared by package:cloud_firestore 7.2.0; missing\n'
            'maven.artifact(\n'
            '    name = "rules_flutter_maven",\n'
            '    artifact = "firebase-firestore",\n'
            '    exclusions = ["junit:junit", "org.mockito:mockito-core"],\n'
            '    group = "com.google.firebase",\n'
            ')\n',
      ]) {
        expect(report, contains(text));
      }
      expect(
        report,
        isNot(contains('"com.google.firebase:firebase-firestore"')),
      );
    });

    test('suggests one buildozer command for the changes', () {
      String commandOf(String report) => report
          .split('\n')
          .where((line) => line.startsWith('#   '))
          .map((line) => line.substring(4))
          .join('\n');
      final report = formatReport(
        app: null,
        requirements: {
          'g:fine': Requirement('1.0', ['package:a 1.0']),
          'g:new': Requirement('2.0', ['package:a 1.0']),
          'g:managed': Requirement(null, ['package:a 1.0'], managed: true),
          'g:listed': Requirement('3.0', ['package:a 1.0']),
          'g:transitive': Requirement('4.0', ['package:a 1.0']),
        },
        resolved: {
          'g:fine': '1.0',
          'g:listed': '2.5',
          'g:transitive': '3.5',
          'a:ktx': '1.0',
        },
        aligned: {'a:ktx': Alignment('1.9.0', 'a:main 1.9.0')},
        boms: {
          'g:bom': Requirement('35.1.0', ['package:a 1.0']),
          'g:old-bom': Requirement('2.0', ['package:a 1.0']),
          'g:fine-bom': Requirement('1.0', ['package:a 1.0']),
        },
        resolvedBoms: {'g:old-bom': '1.0', 'g:fine-bom': '1.0'},
        listed: {
          'g:fine': 'g:fine:1.0',
          'g:listed': 'g:listed:2.5',
          'a:ktx': 'a:ktx:1.0',
        },
      );
      expect(
        report,
        contains(
          '# Or, when that maven.install is in the root MODULE.bazel itself',
        ),
      );
      expect(
        commandOf(report),
        "buildozer 'add artifacts g:managed g:new:2.0 g:transitive:4.0' "
        "'add boms g:bom:35.1.0' "
        "'replace artifacts g:listed:2.5 g:listed:3.0' "
        "'replace artifacts a:ktx:1.0 a:ktx:1.9.0' "
        "'replace boms g:old-bom:1.0 g:old-bom:2.0' "
        '//MODULE.bazel:rules_flutter_maven\n'
        'REPIN=1 bazel run @rules_flutter_maven//:pin',
      );

      // An install with no lock file has nothing to regenerate, and one
      // that has everything needs no command.
      expect(
        commandOf(
          formatReport(
            app: null,
            requirements: {
              'g:new': Requirement('2.0', ['package:a 1.0']),
            },
            resolved: {},
            aligned: {},
            locked: false,
          ),
        ),
        "buildozer 'add artifacts g:new:2.0' //MODULE.bazel:rules_flutter_maven",
      );
      expect(
        formatReport(
          app: null,
          requirements: {
            'g:fine': Requirement('1.0', ['package:a 1.0']),
          },
          resolved: {'g:fine': '1.0'},
          aligned: {},
        ),
        isNot(contains('buildozer')),
      );
    });

    test('says when there is nothing to paste', () {
      final report = formatReport(
        app: '//:app',
        requirements: {},
        resolved: {'g:a': '1.0'},
        aligned: {},
      );
      expect(report, contains('# None.'));
    });
  });

  group('moduleMetadata', () {
    test('takes the first repository that has it', () async {
      final asked = <Uri>[];
      final json = await moduleMetadata(
        'androidx.activity:activity',
        '1.9.0',
        ['https://repo1.example/maven2', 'https://google.example/'],
        (url) async {
          asked.add(url);
          return url.host == 'google.example' ? '{}' : null;
        },
      );
      expect(json, '{}');
      expect(asked.map((u) => u.toString()), [
        'https://repo1.example/maven2/androidx/activity/activity/1.9.0/activity-1.9.0.module',
        'https://google.example/androidx/activity/activity/1.9.0/activity-1.9.0.module',
      ]);
    });

    test('is null when no repository has it', () async {
      expect(
        await moduleMetadata('g:a', '1', ['https://r.example'], (_) async {
          return null;
        }),
        isNull,
      );
    });
  });

  group('snapshot', () {
    final snapshot = <String, List<Constraint>?>{
      'androidx.core:core:1.17.0': [
        (coordinate: 'androidx.core:core-ktx', version: '1.17.0'),
      ],
      'androidx.activity:activity:1.9.0': [
        (coordinate: 'androidx.activity:activity-ktx', version: '1.9.0'),
        (coordinate: 'androidx.activity:activity-compose', version: '1.9.0'),
      ],
      'com.google.guava:guava:33.3.1-jre': null,
      'g:a:1': [],
    };

    test('reads back what it writes', () {
      final read = parseSnapshot(formatSnapshot(snapshot));
      expect(read.keys, unorderedEquals(snapshot.keys));
      for (final key in snapshot.keys) {
        expect(read[key]?.toSet(), snapshot[key]?.toSet(), reason: key);
      }
    });

    test('is laid out as prettier lays out JSON', () {
      expect(formatSnapshot(snapshot), '''{
  "androidx.activity:activity:1.9.0": [
    "androidx.activity:activity-compose:1.9.0",
    "androidx.activity:activity-ktx:1.9.0"
  ],
  "androidx.core:core:1.17.0": ["androidx.core:core-ktx:1.17.0"],
  "com.google.guava:guava:33.3.1-jre": null,
  "g:a:1": []
}
''');
      expect(formatSnapshot({}), '{}\n');
    });
  });
}
