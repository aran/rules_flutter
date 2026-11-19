import 'package:test/test.dart';

import '../e2e_matrix.dart';

void main() {
  group('the committed table', () {
    test('accounts for every system of every workspace', () {
      // What is on disk is checked by `bazel run //tools/ci_matrix`; this
      // holds the table to its own rules.
      expect(
        matrixProblems(
          e2eEntries,
          e2eEntries.map((e) => 'e2e/${e.module}'),
        ),
        isEmpty,
      );
    });
  });

  group('archiveProblems', () {
    const attributes = '/e2e/a/ export-ignore\n/e2e/x.json export-ignore\n';

    test('accepts a filter that leaves out every entry but smoke', () {
      expect(archiveProblems(['a/', 'x.json', 'smoke/'], attributes), isEmpty);
    });

    test('names an entry the archive would ship', () {
      expect(archiveProblems(['a/', 'x.json', 'b/'], attributes), [
        contains('e2e/b/ has no `/e2e/b/ export-ignore` line'),
      ]);
    });

    test('names a line for an entry that does not exist', () {
      expect(archiveProblems(['a/'], attributes), [
        contains('export-ignores /e2e/x.json, which does not exist'),
      ]);
    });
  });

  group('matrixProblems', () {
    const ok = E2eEntry(
      'a',
      runs: {Os.linux: 'what Linux adds'},
      skips: {Os.macos: 'covered by b', Os.windows: 'cannot build'},
    );
    final found = ['e2e/a'];

    test('accepts a table that matches the tree', () {
      expect(matrixProblems([ok], found), isEmpty);
    });

    test('names a workspace that no entry covers', () {
      expect(
        matrixProblems([ok], ['e2e/a', 'e2e/nested/b']),
        [contains('e2e/nested/b is in no entry')],
      );
    });

    test('names an entry whose workspace is gone', () {
      expect(
        matrixProblems([
          ok,
          const E2eEntry(
            'gone',
            skips: {Os.macos: 'x', Os.linux: 'x', Os.windows: 'x'},
          ),
        ], found),
        [contains('lists e2e/gone, which does not exist')],
      );
    });

    test('requires every system to be run or skipped', () {
      expect(
        matrixProblems([
          const E2eEntry('a', runs: {Os.macos: 'why'}),
        ], found),
        unorderedEquals([
          contains('neither runs on linux nor says why not'),
          contains('neither runs on windows nor says why not'),
        ]),
      );
    });

    test('requires a purpose for every system a workspace runs on', () {
      expect(
        matrixProblems([
          const E2eEntry(
            'a',
            runs: {Os.macos: 'why', Os.linux: ' '},
            skips: {Os.windows: 'why not'},
          ),
        ], found),
        [contains('runs on linux without saying what it exercises there')],
      );
    });

    test('rejects the same purpose on two systems', () {
      expect(
        matrixProblems([
          const E2eEntry(
            'a',
            runs: {Os.macos: 'the same', Os.linux: 'the same'},
            skips: {Os.windows: 'why not'},
          ),
        ], found),
        [contains('gives macos and linux the same purpose')],
      );
    });

    test('rejects a blank reason for a skip', () {
      expect(
        matrixProblems([
          const E2eEntry(
            'a',
            runs: {Os.macos: 'why', Os.linux: 'and why'},
            skips: {Os.windows: ' '},
          ),
        ], found),
        [contains('skipped on windows without a reason')],
      );
    });

    test('rejects a system that both runs and is skipped', () {
      expect(
        matrixProblems([
          const E2eEntry(
            'a',
            runs: {Os.linux: 'why'},
            skips: {Os.linux: 'why not', Os.macos: 'x', Os.windows: 'x'},
          ),
        ], found),
        [contains('both runs and is skipped on linux')],
      );
    });

    test('rejects an entry listed twice', () {
      expect(matrixProblems([ok, ok], found), [contains('listed twice')]);
    });

    test('accepts two entries of one module with different patterns', () {
      const second = E2eEntry(
        'a',
        patterns: ['//b/...'],
        runs: {Os.macos: 'what macOS adds'},
        skips: {Os.linux: 'covered by a', Os.windows: 'cannot build'},
      );
      expect(matrixProblems([ok, second], found), isEmpty);
    });

    test('names an entry by its patterns', () {
      const bare = E2eEntry('a', patterns: ['//b/...'], runs: {Os.macos: 'x'});
      expect(
        matrixProblems([ok, bare], found),
        contains(contains('a (//b/...) neither runs on linux')),
      );
    });
  });

  group('matrixInclude', () {
    test('has one job per entry and system it runs on', () {
      expect(
        matrixInclude([
          const E2eEntry(
            'x',
            runs: {Os.windows: 'b', Os.macos: 'a'},
            skips: {Os.linux: 'why'},
          ),
        ]),
        [
          {
            'workspace': 'x',
            'os': 'macos-latest',
            'flags': '',
            'targets': '//...',
          },
          {
            'workspace': 'x',
            'os': 'windows-latest',
            'flags': '',
            'targets': '//...',
          },
        ],
      );
    });

    test('gives a system the tests of its tag, among the patterns', () {
      expect(
        matrixInclude([
          const E2eEntry(
            'x',
            patterns: ['//a/...', '//b/...'],
            runs: {Os.linux: 'a', Os.macos: 'b'},
            skips: {Os.windows: 'why'},
            testsTagged: {Os.linux: 'linux_host'},
          ),
        ]),
        [
          {
            'workspace': 'x',
            'os': 'macos-latest',
            'flags': '',
            'targets': '//a/... //b/...',
          },
          {
            'workspace': 'x',
            'os': 'ubuntu-latest',
            'flags': '--build_tests_only --test_tag_filters=linux_host',
            'targets': '//a/... //b/...',
          },
        ],
      );
    });

    test('runs two entries of one module as two jobs', () {
      expect(
        matrixInclude([
          const E2eEntry('x', patterns: ['//a/...'], runs: {Os.linux: 'a'}),
          const E2eEntry('x', patterns: ['//b/...'], runs: {Os.linux: 'b'}),
        ]).map((job) => job['targets']),
        ['//a/...', '//b/...'],
      );
    });
  });

  group('tagProblems', () {
    const build = 'a(name = "t", tags = ["windows_host"])\n';
    const windows = E2eEntry(
      'x',
      runs: {Os.windows: 'a'},
      testsTagged: {Os.windows: 'windows_host'},
    );

    test('accepts a tag that a target has', () {
      expect(tagProblems([windows], (_) => [build]), isEmpty);
    });

    test('finds the tag in any BUILD file of the module', () {
      expect(tagProblems([windows], (_) => ['b(name = "u")', build]), isEmpty);
    });

    test('names a tag that no target has', () {
      expect(
        tagProblems([
          const E2eEntry('x', testsTagged: {Os.linux: 'gone'}),
        ], (_) => [build]),
        [contains('no target of e2e/x is tagged "gone"')],
      );
    });

    test('rejects an empty selection', () {
      expect(
        tagProblems([
          const E2eEntry('x', testsTagged: {Os.linux: ' '}),
        ], (_) => [build]),
        [contains('selects no tests')],
      );
    });
  });

  group('deep tier', () {
    const tagged = 'a(name = "t", tags = ["android", "deep"])\n';
    const plain = 'a(name = "t", tags = ["android"])\n';
    const runs = E2eEntry('x', deep: 'the Gradle host');
    const silent = E2eEntry('y');

    test('lists the workspaces that run it, in table order', () {
      expect(deepInclude([silent, runs, const E2eEntry('z', deep: 'b')]), [
        {'workspace': 'x'},
        {'workspace': 'z'},
      ]);
    });

    test('accepts an entry for a workspace with deep targets', () {
      expect(
        deepProblems([runs, silent], (w) => [w == 'x' ? tagged : plain]),
        isEmpty,
      );
    });

    test('names deep targets that no entry runs', () {
      expect(deepProblems([silent], (_) => [tagged]), [
        contains('y has `deep` targets that no CI job runs'),
      ]);
    });

    test('names an entry whose workspace has no deep target', () {
      expect(deepProblems([runs], (_) => [plain]), [
        contains('x runs its deep tier, but no BUILD file of e2e/x has a'),
      ]);
    });

    test('rejects a purpose given in two entries of one module', () {
      expect(
        deepProblems([
          runs,
          const E2eEntry('x', patterns: ['//b/...'], deep: 'again'),
        ], (_) => [tagged]),
        [contains('x gives its deep tier a purpose in 2 entries')],
      );
    });

    test('rejects a blank purpose', () {
      expect(
        deepProblems([const E2eEntry('x', deep: ' ')], (_) => [tagged]),
        [contains('x runs its deep tier without saying what it exercises')],
      );
    });

    test('finds a deep target in any BUILD file of the workspace', () {
      expect(deepProblems([silent], (_) => [plain, plain, tagged]), [
        contains('y has `deep` targets'),
      ]);
      expect(deepProblems([runs], (_) => [plain, tagged]), isEmpty);
    });

    group('hasTag', () {
      test('sees the tag in a list among others', () {
        expect(hasTag(tagged, 'deep'), isTrue);
        expect(hasTag('a(tags=["deep"])', 'deep'), isTrue);
        expect(hasTag("a(tags = ['deep'])", 'deep'), isTrue);
      });

      test('sees the tag in a list that spans lines', () {
        expect(
          hasTag(
            'a(\n  tags = [\n    "android",\n    "deep",\n  ],\n)',
            'deep',
          ),
          isTrue,
        );
      });

      test('sees the tag in an expression', () {
        expect(
          hasTag(
            'a(tags = ["android"] + (["deep"] if variant == "x" else []))',
            'deep',
          ),
          isTrue,
        );
      });

      test('sees another tag the same way', () {
        expect(hasTag('a(tags = ["windows_host"])', 'windows_host'), isTrue);
        expect(hasTag('a(tags = ["windows_host"])', 'deep'), isFalse);
      });

      test('does not take a name that merely contains deep for a tag', () {
        expect(hasTag('a(name = "deep_lib")\n', 'deep'), isFalse);
        expect(hasTag('a(tags = ["deep_lib", "not-deep"])', 'deep'), isFalse);
      });

      test('does not take a target named deep for a deep target', () {
        expect(hasTag('a(name = "deep", tags = ["android"])', 'deep'), isFalse);
        expect(hasTag('a(tags = ["android"], name = "deep")', 'deep'), isFalse);
        expect(hasTag('a(name = "deep", srcs = ["deep"])', 'deep'), isFalse);
      });

      test('does not take another attribute for the tags', () {
        expect(hasTag('a(test_tags = ["deep"])', 'deep'), isFalse);
        expect(hasTag('a(my.tags = ["deep"])', 'deep'), isFalse);
        expect(hasTag('a(tags == ["deep"])', 'deep'), isFalse);
      });

      test('does not take a comment or a docstring for a tag', () {
        expect(
          hasTag('# tags = ["deep"]\na(tags = ["android"])', 'deep'),
          isFalse,
        );
        expect(
          hasTag('a(tags = [\n  "android",\n  # "deep",\n])', 'deep'),
          isFalse,
        );
        expect(hasTag(r'a(doc = "tags = [\"deep\"]")', 'deep'), isFalse);
      });

      test('stops at the end of the argument', () {
        expect(
          hasTag('a(tags = ["android"], srcs = ["deep"])', 'deep'),
          isFalse,
        );
        expect(
          hasTag('a(tags = ["android"])\nb(srcs = ["deep"])', 'deep'),
          isFalse,
        );
      });
    });

    test('is run by the committed workspaces that have gradle hosts', () {
      expect(
        deepInclude(e2eEntries).map((e) => e['workspace']),
        ['plugin_example', 'custom_engine'],
      );
    });
  });

  group('lockCheckWorkspaces', () {
    const table = [
      E2eEntry(
        'apple',
        runs: {Os.macos: 'a', Os.linux: 'b'},
        skips: {Os.windows: 'x'},
      ),
      E2eEntry(
        'neutral',
        runs: {Os.linux: 'a', Os.windows: 'b'},
        skips: {Os.macos: 'x'},
      ),
      E2eEntry(
        'own_job',
        skips: {Os.macos: 'x', Os.linux: 'x', Os.windows: 'x'},
      ),
    ];

    test('checks on macOS what runs there or nowhere, the rest on Linux', () {
      expect(lockCheckWorkspaces(table), {
        Os.linux: ['.', 'e2e/neutral'],
        Os.macos: ['e2e/apple', 'e2e/own_job'],
      });
    });

    test('gives each system one job', () {
      expect(lockCheckInclude(lockCheckWorkspaces(table)), [
        {'os': 'ubuntu-latest', 'workspaces': '. e2e/neutral'},
        {'os': 'macos-latest', 'workspaces': 'e2e/apple e2e/own_job'},
      ]);
    });

    test('covers every lock the committed table knows', () {
      expect(
        lockCheckProblems(lockCheckWorkspaces(e2eEntries), [
          'MODULE.bazel.lock',
          for (final e in e2eEntries) 'e2e/${e.module}/MODULE.bazel.lock',
        ]),
        isEmpty,
      );
    });

    test('names a lock no job checks', () {
      expect(
        lockCheckProblems(lockCheckWorkspaces(table), [
          'MODULE.bazel.lock',
          'e2e/apple/MODULE.bazel.lock',
          'e2e/apple/nested/MODULE.bazel.lock',
        ]),
        [contains('e2e/apple/nested/MODULE.bazel.lock is checked by no')],
      );
    });
  });
}
