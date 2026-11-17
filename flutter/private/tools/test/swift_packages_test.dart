import 'dart:convert';

import 'package:test/test.dart';

import '../swift_packages.dart';

const _firebase = 'https://github.com/firebase/firebase-ios-sdk';

Need need(String plugin, Requirement requirement, {String url = _firebase}) =>
    (plugin: plugin, url: url, requirement: requirement);

Pin pin(String version) => (version: version, branch: null, revision: 'abc');

void main() {
  group('compareVersions', () {
    test('orders by number, then a prerelease below its release', () {
      expect(compareVersions('13.10.0', '13.9.0'), 1);
      expect(compareVersions('13.1.1', '13.1.1+build'), 0);
      expect(compareVersions('2.0.0-beta.2', '2.0.0'), -1);
      expect(compareVersions('2.0.0-beta.2', '2.0.0-beta.10'), -1);
      expect(compareVersions('2.0.0-alpha', '2.0.0-alpha.1'), -1);
    });
  });

  group('Requirement', () {
    test('reads dump-package\'s requirements', () {
      expect(
        Requirement.fromJson({
          'exact': ['13.1.1'],
        }),
        const Exact('13.1.1'),
      );
      expect(
        Requirement.fromJson({
          'range': [
            {'lowerBound': '1.2.0', 'upperBound': '2.0.0'},
          ],
        }),
        const Range('1.2.0', '2.0.0'),
      );
      expect(
        Requirement.fromJson({
          'branch': ['main'],
        }),
        const Branch('main'),
      );
    });

    test('writes each as Package.swift does', () {
      expect(const Exact('13.1.1').swift, 'exact: "13.1.1"');
      expect(const Range('1.2.0', '2.0.0').swift, 'from: "1.2.0"');
      expect(
        const Range('1.2.0', '1.3.0').swift,
        '.upToNextMinor(from: "1.2.0")',
      );
      expect(const Range('1.2.0', '1.2.5').swift, '"1.2.0"..<"1.2.5"');
      expect(const Revision('abc').swift, 'revision: "abc"');
    });

    test('checks a pin', () {
      expect(const Exact('13.1.1').accepts(pin('13.1.1')), isTrue);
      expect(const Exact('13.1.1').accepts(pin('13.2.0')), isFalse);
      expect(const Range('1.2.0', '2.0.0').accepts(pin('1.9.9')), isTrue);
      expect(const Range('1.2.0', '2.0.0').accepts(pin('2.0.0')), isFalse);
      expect(
        const Branch(
          'main',
        ).accepts((version: null, branch: 'main', revision: 'abc')),
        isTrue,
      );
    });
  });

  group('combine', () {
    test('takes the overlap of ranges', () {
      expect(
        combine([const Range('1.2.0', '2.0.0'), const Range('1.5.0', '1.6.0')]),
        const Range('1.5.0', '1.6.0'),
      );
    });

    test('takes an exact version every range accepts', () {
      expect(
        combine([const Exact('1.5.1'), const Range('1.2.0', '2.0.0')]),
        const Exact('1.5.1'),
      );
    });

    test('finds no version when they conflict', () {
      expect(combine([const Exact('1.0.0'), const Exact('1.0.1')]), isNull);
      expect(
        combine([const Exact('3.0.0'), const Range('1.2.0', '2.0.0')]),
        isNull,
      );
      expect(
        combine([const Range('1.0.0', '2.0.0'), const Range('2.0.0', '3.0.0')]),
        isNull,
      );
      expect(combine([const Branch('main'), const Exact('1.0.0')]), isNull);
    });
  });

  group('needsOf', () {
    test('reads each plugin\'s listing once per requirement', () {
      final listing = jsonEncode({
        'package': 'firebase_core',
        'version': '5.1.0',
        'platforms': {
          for (final platform in ['ios', 'macos'])
            platform: [
              {
                'identity': 'firebase-ios-sdk',
                'url': _firebase,
                'requirement': {
                  'exact': ['13.1.1'],
                },
              },
            ],
        },
      });
      expect(needsOf([listing]), {
        'firebase-ios-sdk': [
          need('package:firebase_core 5.1.0', const Exact('13.1.1')),
        ],
      });
    });
  });

  group('formatReport', () {
    final needs = {
      'firebase-ios-sdk': [
        need('package:firebase_core 5.1.0', const Exact('13.1.1')),
      ],
    };

    test('prints the Package.swift and MODULE.bazel lines', () {
      final report = formatReport(
        hub: 'deps',
        needs: needs,
        pins: {'firebase-ios-sdk': pin('13.1.1')},
        resolved: '//:Package.resolved',
      );
      expect(report.conflict, isFalse);
      expect(
        report.text,
        contains(
          '    .package(url: "$_firebase", exact: "13.1.1"),  '
          '// package:firebase_core 5.1.0\n',
        ),
      );
      expect(
        report.text,
        contains(
          '    use_repo(swift_deps, "swift_package", '
          '"swiftpkg_firebase_ios_sdk")\n',
        ),
      );
      expect(
        report.text,
        contains('    inject_repo(flutter_pub, "swiftpkg_firebase_ios_sdk")\n'),
      );
      expect(report.text, contains('pins all 1 at versions'));
    });

    test('marks a package the root does not pin, or pins too high', () {
      expect(
        formatReport(
          hub: 'deps',
          needs: needs,
          pins: {},
          resolved: '//:Package.resolved',
        ).text,
        contains(
          '// package:firebase_core 5.1.0; missing from //:Package.resolved',
        ),
      );
      expect(
        formatReport(
          hub: 'deps',
          needs: needs,
          pins: {'firebase-ios-sdk': pin('13.2.0')},
          resolved: '//:Package.resolved',
        ).text,
        contains('; //:Package.resolved pins 13.2.0'),
      );
    });

    test('asks for swift_package_resolved when no tag names one', () {
      expect(
        formatReport(
          hub: 'deps',
          needs: needs,
          pins: null,
          resolved: null,
        ).text,
        contains('swift_package_resolved = "//:Package.resolved",'),
      );
    });

    test('marks a conflict', () {
      final report = formatReport(
        hub: 'deps',
        needs: {
          'firebase-ios-sdk': [
            need('package:a 1.0.0', const Exact('13.1.1')),
            need('package:b 1.0.0', const Exact('12.0.0')),
          ],
        },
        pins: {},
        resolved: '//:Package.resolved',
      );
      expect(report.conflict, isTrue);
      expect(
        report.text,
        contains(
          'no version meets every plugin: package:a 1.0.0 requires exact '
          '13.1.1; package:b 1.0.0 requires exact 12.0.0',
        ),
      );
    });

    test('says when no plugin needs a package', () {
      expect(
        formatReport(hub: 'deps', needs: {}, pins: null, resolved: null).text,
        contains('No Apple plugin of @deps depends on a remote Swift package'),
      );
    });
  });
}
