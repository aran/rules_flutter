// How `flutter_test` applies Bazel's test protocol to a `RemoteListener` tree.
import 'package:test/test.dart';

import '../bazel_test_protocol.dart';

/// A test entry, named in full as `package:test` names it.
Map<String, dynamic> _test(String name) => {'type': 'test', 'name': name};

/// A test entry carrying `package:test` metadata tags.
Map<String, dynamic> _taggedTest(String name, List<String> tags) => {
  'type': 'test',
  'name': name,
  'metadata': {'tags': tags},
};

Map<String, dynamic> _group(
  String name,
  List<Map<String, dynamic>> entries, {
  bool fixtures = false,
}) => {
  'type': 'group',
  'name': name,
  'entries': entries,
  if (fixtures) 'setUpAll': _test('$name (setUpAll)'),
  if (fixtures) 'tearDownAll': _test('$name (tearDownAll)'),
};

/// A suite shaped like `bazel_protocol_test.dart` in e2e/hello_world, with a
/// fourth test so three shards split it unevenly.
Map<String, dynamic> _suite() => _group('', [
  _group('outer', [
    _test('outer runs its setUpAll once'),
    _test('outer ignores a per-test timeout'),
    _group('outer inner', [
      _test('outer inner is reached through both groups'),
    ]),
  ], fixtures: true),
  _test('a widget test is a case like any other'),
]);

/// A suite with tags at every level `package:test` reports them: group tags
/// and test tags. Library-level `@Tags` ride on the root group; they get
/// their own suite below so they do not colour this one.
Map<String, dynamic> _taggedSuite() => _group('', [
  _taggedTest('untagged case', []),
  _taggedTest('slow case', ['slow']),
  {
    'type': 'group',
    'name': 'golden group',
    'metadata': {
      'tags': ['golden'],
    },
    'entries': [_test('golden group case')],
    'setUpAll': _test('golden group (setUpAll)'),
    'tearDownAll': _test('golden group (tearDownAll)'),
  },
  _group('mixed group', [
    _taggedTest('mixed group slow case', ['slow']),
    _taggedTest('mixed group golden slow case', ['golden', 'slow']),
  ]),
]);

/// A suite whose root group carries a library-level `@Tags`, as `package:test`
/// reports it: every test in the file inherits it.
Map<String, dynamic> _libraryTaggedSuite() => {
  'type': 'group',
  'name': '',
  'metadata': {
    'tags': ['library'],
  },
  'entries': [_test('first case'), _test('second case')],
};

List<String> _names(Map<String, dynamic>? group) => [
  for (final entry in group?['entries'] as List? ?? const [])
    if ((entry as Map)['type'] == 'group')
      ..._names(entry.cast<String, dynamic>())
    else
      entry['name'] as String,
];

void main() {
  group('TestSelection', () {
    test('keeps the whole tree when nothing narrows it', () {
      final selection = TestSelection.fromEnvironment(const {});
      expect(selection.narrows, isFalse);
      expect(_names(selection.select(_suite())), hasLength(4));
    });

    test('--test_filter is a regular expression over the full name', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': r'inner|widget\b',
      });
      expect(_names(selection.select(_suite())), [
        'outer inner is reached through both groups',
        'a widget test is a case like any other',
      ]);
    });

    test('a group the filter empties goes, fixtures and all', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': 'widget',
      });
      final selected = selection.select(_suite())!;
      expect(selected['entries'], hasLength(1));
      expect(_names(selected), ['a widget test is a case like any other']);
    });

    test('a group that keeps a test keeps its fixtures', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': 'setUpAll once',
      });
      final outer = (selection.select(_suite())!['entries'] as List).single;
      expect((outer as Map)['setUpAll'], isNotNull);
      expect(outer['tearDownAll'], isNotNull);
    });

    test('a filter that matches nothing leaves no tree', () {
      final selection = TestSelection.fromEnvironment(const {
        'TESTBRIDGE_TEST_ONLY': 'no such test',
      });
      expect(selection.narrows, isTrue);
      expect(selection.select(_suite()), isNull);
    });

    test(
      'shards split the tests into contiguous shares, each exactly once',
      () {
        final shards = [
          for (var i = 0; i < 3; i++)
            _names(
              TestSelection.fromEnvironment({
                'TEST_TOTAL_SHARDS': '3',
                'TEST_SHARD_INDEX': '$i',
              }).select(_suite()),
            ),
        ];
        expect(shards.expand((s) => s), _names(_suite()));
        expect(shards.map((s) => s.length), [1, 2, 1]);
      },
    );

    test('a shard with no share has no tree, and passes', () {
      final selection = TestSelection.fromEnvironment(const {
        // Four tests over eight shards: shard 0 takes [0, 1), shard 1 the
        // empty [1, 1).
        'TEST_TOTAL_SHARDS': '8',
        'TEST_SHARD_INDEX': '1',
      });
      expect(selection.narrows, isTrue);
      expect(selection.select(_suite()), isNull);
    });

    test('the filter applies before the shards split what is left', () {
      final shards = [
        for (var i = 0; i < 2; i++)
          _names(
            TestSelection.fromEnvironment({
              'TESTBRIDGE_TEST_ONLY': 'outer',
              'TEST_TOTAL_SHARDS': '2',
              'TEST_SHARD_INDEX': '$i',
            }).select(_suite()),
          ),
      ];
      expect(shards.expand((s) => s), hasLength(3));
      expect(shards.expand((s) => s), everyElement(contains('outer')));
    });

    test('refuses a filter that is not a regular expression', () {
      expect(
        () =>
            TestSelection.fromEnvironment(const {'TESTBRIDGE_TEST_ONLY': '('}),
        throwsFormatException,
      );
    });

    test('refuses shard numbers Bazel would not send', () {
      expect(
        () => TestSelection.fromEnvironment(const {
          'TEST_TOTAL_SHARDS': 'two',
          'TEST_SHARD_INDEX': '0',
        }),
        throwsFormatException,
      );
      expect(
        () => TestSelection.fromEnvironment(const {
          'TEST_TOTAL_SHARDS': '2',
          'TEST_SHARD_INDEX': '2',
        }),
        throwsFormatException,
      );
    });

    test('exclude_tags drops every test carrying an excluded tag', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_EXCLUDE_TAGS': 'golden',
      });
      expect(selection.narrows, isTrue);
      expect(_names(selection.select(_taggedSuite())), [
        'untagged case',
        'slow case',
        'mixed group slow case',
      ]);
    });

    test('exclude_tags is comma-separated, trimmed, and skips empties', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_EXCLUDE_TAGS': ' golden ,, slow ',
      });
      expect(_names(selection.select(_taggedSuite())), ['untagged case']);
    });

    test('include_tags keeps only tests carrying an included tag', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': 'slow',
      });
      expect(selection.narrows, isTrue);
      expect(_names(selection.select(_taggedSuite())), [
        'slow case',
        'mixed group slow case',
        'mixed group golden slow case',
      ]);
    });

    test(
      'several include_tags mean ALL of them, as flutter test intersects',
      () {
        final selection = TestSelection.fromEnvironment(const {
          'FLUTTER_TEST_TAGS': 'slow,golden',
        });
        expect(_names(selection.select(_taggedSuite())), [
          'mixed group golden slow case',
        ]);
      },
    );

    test('comma-separated include_tags trim and skip empties', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': ' slow ,, golden ',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'mixed group golden slow case',
      ]);
    });

    test('an include_tags entry is a boolean selector: &&', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': 'slow && golden',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'mixed group golden slow case',
      ]);
    });

    test('an include_tags entry is a boolean selector: ||', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': 'slow || golden',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'slow case',
        'golden group case',
        'mixed group slow case',
        'mixed group golden slow case',
      ]);
    });

    test('an include_tags entry is a boolean selector: !', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': '!slow',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'untagged case',
        'golden group case',
      ]);
    });

    test('an include_tags entry is a boolean selector: parentheses', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': '(slow || golden) && !golden',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'slow case',
        'mixed group slow case',
      ]);
    });

    test('attribute entries join the same intersection', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS_ATTR': 'slow,golden',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'mixed group golden slow case',
      ]);
    });

    test('exclude_tags drops tests matching ANY selector', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_EXCLUDE_TAGS': 'golden || slow',
      });
      expect(_names(selection.select(_taggedSuite())), ['untagged case']);
    });

    test('exclude_tags entries are selectors too: !', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_EXCLUDE_TAGS': '!slow',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'slow case',
        'mixed group slow case',
        'mixed group golden slow case',
      ]);
    });

    test('an entry that is not a boolean selector is an error', () {
      expect(
        () => TestSelection.fromEnvironment(const {
          'FLUTTER_TEST_TAGS': 'slow &&',
        }),
        throwsFormatException,
      );
      expect(
        () => TestSelection.fromEnvironment(const {
          'FLUTTER_TEST_TAGS_ATTR': 'slow &&',
        }),
        throwsFormatException,
      );
      expect(
        () => TestSelection.fromEnvironment(const {
          'FLUTTER_TEST_EXCLUDE_TAGS': '(slow',
        }),
        throwsFormatException,
      );
    });

    test('an attribute include selection that matches nothing fails', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS_ATTR': 'nosuchtag',
      });
      expect(selection.narrows, isTrue);
      expect(() => selection.select(_taggedSuite()), throwsFormatException);
    });

    test('an attribute selector that matches nothing fails', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS_ATTR': 'slow && golden && nosuchtag',
      });
      expect(() => selection.select(_taggedSuite()), throwsFormatException);
    });

    test('the typo guard runs before sharding', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS_ATTR': 'nosuchtag',
        'TEST_TOTAL_SHARDS': '8',
        'TEST_SHARD_INDEX': '1',
      });
      expect(() => selection.select(_taggedSuite()), throwsFormatException);
    });

    test('an attribute selection the filter empties still passes', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS_ATTR': 'slow',
        'TESTBRIDGE_TEST_ONLY': 'no such test',
      });
      expect(selection.select(_taggedSuite()), isNull);
    });

    test('an attribute selection a shard empties still passes', () {
      final selection = TestSelection.fromEnvironment(const {
        // Three slow tests over eight shards: shard 2 draws the empty [1, 1).
        'FLUTTER_TEST_TAGS_ATTR': 'slow',
        'TEST_TOTAL_SHARDS': '8',
        'TEST_SHARD_INDEX': '2',
      });
      expect(selection.select(_taggedSuite()), isNull);
    });

    test('a --test_env value clears the typo guard with the attribute', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': '',
        'FLUTTER_TEST_TAGS_ATTR': 'nosuchtag',
      });
      expect(selection.narrows, isFalse);
      expect(_names(selection.select(_taggedSuite())), hasLength(5));
    });

    test('a --test_env selection that matches nothing passes', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': 'nosuchtag',
        'FLUTTER_TEST_TAGS_ATTR': 'nosuchattrtag',
      });
      expect(selection.narrows, isTrue);
      expect(selection.select(_taggedSuite()), isNull);
    });

    test('exclusion wins over inclusion', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': 'slow',
        'FLUTTER_TEST_EXCLUDE_TAGS': 'golden',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'slow case',
        'mixed group slow case',
      ]);
    });

    test('a group tag reaches every case in the group', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': 'golden',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'golden group case',
        'mixed group golden slow case',
      ]);
    });

    test('a library-level tag on the root group reaches every test', () {
      final keeping = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': 'library',
      });
      expect(_names(keeping.select(_libraryTaggedSuite())), [
        'first case',
        'second case',
      ]);
      final dropping = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_EXCLUDE_TAGS': 'library',
      });
      expect(dropping.narrows, isTrue);
      expect(dropping.select(_libraryTaggedSuite()), isNull);
    });

    test('a group the tags empty goes, fixtures and all', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': 'slow',
      });
      final selected = selection.select(_taggedSuite())!;
      expect(_names(selected), [
        'slow case',
        'mixed group slow case',
        'mixed group golden slow case',
      ]);
      final entries = selected['entries'] as List;
      // The golden group kept nothing, so its setUpAll/tearDownAll went with
      // it; the mixed group kept tests, so it stays.
      expect(entries, hasLength(2));
    });

    test('tags apply before the filter and the shards split what is left', () {
      final shards = [
        for (var i = 0; i < 2; i++)
          _names(
            TestSelection.fromEnvironment({
              'FLUTTER_TEST_EXCLUDE_TAGS': 'golden',
              'TESTBRIDGE_TEST_ONLY': 'case',
              'TEST_TOTAL_SHARDS': '2',
              'TEST_SHARD_INDEX': '$i',
            }).select(_taggedSuite()),
          ),
      ];
      expect(shards.expand((s) => s), hasLength(3));
      expect(
        shards.expand((s) => s),
        everyElement(isNot(contains('golden'))),
      );
    });

    test('a --test_env tag selection that matches nothing passes', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS': 'nosuchtag',
      });
      expect(selection.narrows, isTrue);
      expect(selection.select(_taggedSuite()), isNull);
    });

    test('the rule forwards attributes under _ATTR keys', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_TAGS_ATTR': 'slow',
        'FLUTTER_TEST_EXCLUDE_TAGS_ATTR': 'golden',
      });
      expect(selection.narrows, isTrue);
      expect(_names(selection.select(_taggedSuite())), [
        'slow case',
        'mixed group slow case',
      ]);
    });

    test('a --test_env value overrides the attribute', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_EXCLUDE_TAGS': 'slow',
        'FLUTTER_TEST_EXCLUDE_TAGS_ATTR': 'golden',
      });
      expect(_names(selection.select(_taggedSuite())), [
        'untagged case',
        'golden group case',
      ]);
    });

    test('an empty --test_env value clears the attribute', () {
      final selection = TestSelection.fromEnvironment(const {
        'FLUTTER_TEST_EXCLUDE_TAGS': '',
        'FLUTTER_TEST_EXCLUDE_TAGS_ATTR': 'golden',
      });
      expect(selection.narrows, isFalse);
      expect(_names(selection.select(_taggedSuite())), [
        'untagged case',
        'slow case',
        'golden group case',
        'mixed group slow case',
        'mixed group golden slow case',
      ]);
    });
  });

  group('junitXml', () {
    final xml = junitXml([
      TestCaseResult.passed(
        'adds <two> & "two"',
        const Duration(milliseconds: 1500),
        'printed\n',
      ),
      TestCaseResult.failed(
        'fails',
        Duration.zero,
        '',
        failureType: 'TestFailure',
        message: 'Expected: 1\nActual: 2',
        detail: 'TestFailure: Expected: 1\nActual: 2',
      ),
      TestCaseResult.failed(
        'throws',
        Duration.zero,
        '',
        failureType: 'StateError',
        message: 'bad state',
        detail: 'StateError: bad state',
      ),
      TestCaseResult.skipped('skipped'),
    ], suiteName: 'test/foo_test.dart');

    test('counts each outcome on the suite', () {
      expect(
        xml,
        contains(
          '<testsuite name="test/foo_test.dart" tests="4" failures="1" '
          'errors="1" skipped="1" time="1.500">',
        ),
      );
    });

    test('keeps a failed expectation apart from an error', () {
      expect(xml, contains('<failure message="Expected: 1">'));
      expect(xml, contains('<error message="bad state">'));
    });

    test('escapes names and carries what the case printed', () {
      expect(xml, contains('name="adds &lt;two&gt; &amp; &quot;two&quot;"'));
      expect(xml, contains('<system-out>printed\n</system-out>'));
      expect(xml, contains('<skipped/>'));
    });
  });
}
