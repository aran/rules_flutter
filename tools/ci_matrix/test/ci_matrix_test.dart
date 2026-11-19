import 'package:test/test.dart';

import '../e2e_matrix.dart';

void main() {
  group('the committed table', () {
    test('accounts for every system of every workspace', () {
      // What is on disk is checked by `bazel run //tools/ci_matrix`; this
      // holds the table to its own rules.
      expect(
        matrixProblems(
          e2eWorkspaces,
          e2eWorkspaces.map((w) => 'e2e/${w.name}'),
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
    const ok = E2eWorkspace(
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
          const E2eWorkspace(
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
          const E2eWorkspace('a', runs: {Os.macos: 'why'}),
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
          const E2eWorkspace(
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
          const E2eWorkspace(
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
          const E2eWorkspace(
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
          const E2eWorkspace(
            'a',
            runs: {Os.linux: 'why'},
            skips: {Os.linux: 'why not', Os.macos: 'x', Os.windows: 'x'},
          ),
        ], found),
        [contains('both runs and is skipped on linux')],
      );
    });

    test('rejects a workspace listed twice', () {
      expect(matrixProblems([ok, ok], found), [contains('listed twice')]);
    });
  });

  group('matrixInclude', () {
    test('has one job per workspace and system it runs on', () {
      expect(
        matrixInclude([
          const E2eWorkspace(
            'x',
            runs: {Os.windows: 'b', Os.macos: 'a'},
            skips: {Os.linux: 'why'},
            command: 'build',
          ),
        ], (_) => ''),
        [
          {
            'workspace': 'x',
            'os': 'macos-latest',
            'command': 'build',
            'targets': '//...',
          },
          {
            'workspace': 'x',
            'os': 'windows-latest',
            'command': 'build',
            'targets': '//...',
          },
        ],
      );
    });

    test('gives a system its own command and the tests it names', () {
      expect(
        matrixInclude([
          const E2eWorkspace(
            'x',
            runs: {Os.linux: 'a', Os.macos: 'b'},
            skips: {Os.windows: 'why'},
            command: 'build',
            commands: {Os.linux: 'test'},
            testsNamed: {
              Os.linux: ['one_', 'two_'],
            },
          ),
        ], (_) => 'a(name = "two_b_test")\na(name = "one_a_test")\n'),
        [
          {
            'workspace': 'x',
            'os': 'macos-latest',
            'command': 'build',
            'targets': '//...',
          },
          {
            'workspace': 'x',
            'os': 'ubuntu-latest',
            'command': 'test',
            'targets': '//:one_a_test //:two_b_test',
          },
        ],
      );
    });
  });

  group('targetProblems', () {
    const build =
        'foo(\n    name = "web_one_test",\n)\n'
        'bar(name="web_two_test")\n'
        'bar(name="web_helper")\n'
        'bar(name="linux_one_test")\n'
        'bar(name="other_web_test")\n';
    String file(String _) => build;
    const web = E2eWorkspace(
      'x',
      runs: {Os.linux: 'a'},
      testsNamed: {
        Os.linux: ['web_'],
      },
    );

    test('selects the tests with the prefix, sorted', () {
      expect(web.targetsOn(Os.linux, build), [
        '//:web_one_test',
        '//:web_two_test',
      ]);
    });

    test('picks up a test added to the BUILD file', () {
      expect(
        web.targetsOn(Os.linux, '$build\nbaz(name = "web_x_test")\n'),
        ['//:web_one_test', '//:web_two_test', '//:web_x_test'],
      );
    });

    test('joins several prefixes into one sorted list', () {
      const both = E2eWorkspace(
        'x',
        testsNamed: {
          Os.linux: ['web_', 'linux_'],
        },
      );
      expect(both.targetsOn(Os.linux, build), [
        '//:linux_one_test',
        '//:web_one_test',
        '//:web_two_test',
      ]);
    });

    test('runs everything where nothing is named', () {
      expect(web.targetsOn(Os.macos, build), ['//...']);
    });

    test('accepts prefixes that match a test', () {
      expect(targetProblems([web], file), isEmpty);
    });

    test('names a prefix that matches no test', () {
      expect(
        targetProblems([
          const E2eWorkspace(
            'x',
            testsNamed: {
              Os.linux: ['web_', 'gone_', 'other_'],
            },
          ),
        ], file),
        [
          contains('no `gone_...test` target in e2e/x/BUILD.bazel'),
        ],
      );
    });

    test('does not count a target that is not a test', () {
      expect(
        targetProblems([
          const E2eWorkspace(
            'x',
            testsNamed: {
              Os.linux: ['web_helper'],
            },
          ),
        ], file),
        [contains('no `web_helper...test` target')],
      );
    });

    test('rejects an empty selection', () {
      expect(
        targetProblems([
          const E2eWorkspace('x', testsNamed: {Os.linux: []}),
        ], file),
        [contains('selects no tests')],
      );
    });
  });

  group('deep tier', () {
    const tagged = 'a(name = "t", tags = ["android", "deep"])\n';
    const plain = 'a(name = "t", tags = ["android"])\n';
    const runs = E2eWorkspace('x', deep: 'the Gradle host');
    const silent = E2eWorkspace('y');

    test('lists the workspaces that run it, in table order', () {
      expect(deepInclude([silent, runs, const E2eWorkspace('z', deep: 'b')]), [
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

    test('rejects a blank purpose', () {
      expect(
        deepProblems([const E2eWorkspace('x', deep: ' ')], (_) => [tagged]),
        [contains('x runs its deep tier without saying what it exercises')],
      );
    });

    test('finds a deep target in any BUILD file of the workspace', () {
      expect(deepProblems([silent], (_) => [plain, plain, tagged]), [
        contains('y has `deep` targets'),
      ]);
      expect(deepProblems([runs], (_) => [plain, tagged]), isEmpty);
    });

    group('hasDeepTag', () {
      test('sees the tag in a list among others', () {
        expect(hasDeepTag(tagged), isTrue);
        expect(hasDeepTag('a(tags=["deep"])'), isTrue);
        expect(hasDeepTag("a(tags = ['deep'])"), isTrue);
      });

      test('sees the tag in a list that spans lines', () {
        expect(
          hasDeepTag('a(\n  tags = [\n    "android",\n    "deep",\n  ],\n)'),
          isTrue,
        );
      });

      test('sees the tag in an expression', () {
        expect(
          hasDeepTag(
            'a(tags = ["android"] + (["deep"] if variant == "x" else []))',
          ),
          isTrue,
        );
      });

      test('does not take a name that merely contains deep for a tag', () {
        expect(hasDeepTag('a(name = "deep_lib")\n'), isFalse);
        expect(hasDeepTag('a(tags = ["deep_lib", "not-deep"])'), isFalse);
      });

      test('does not take a target named deep for a deep target', () {
        expect(hasDeepTag('a(name = "deep", tags = ["android"])'), isFalse);
        expect(hasDeepTag('a(tags = ["android"], name = "deep")'), isFalse);
        expect(hasDeepTag('a(name = "deep", srcs = ["deep"])'), isFalse);
      });

      test('does not take another attribute for the tags', () {
        expect(hasDeepTag('a(test_tags = ["deep"])'), isFalse);
        expect(hasDeepTag('a(my.tags = ["deep"])'), isFalse);
        expect(hasDeepTag('a(tags == ["deep"])'), isFalse);
      });

      test('does not take a comment or a docstring for a tag', () {
        expect(hasDeepTag('# tags = ["deep"]\na(tags = ["android"])'), isFalse);
        expect(
          hasDeepTag('a(tags = [\n  "android",\n  # "deep",\n])'),
          isFalse,
        );
        expect(hasDeepTag(r'a(doc = "tags = [\"deep\"]")'), isFalse);
      });

      test('stops at the end of the argument', () {
        expect(hasDeepTag('a(tags = ["android"], srcs = ["deep"])'), isFalse);
        expect(
          hasDeepTag('a(tags = ["android"])\nb(srcs = ["deep"])'),
          isFalse,
        );
      });
    });

    test('is run by the committed workspaces that have gradle hosts', () {
      expect(
        deepInclude(e2eWorkspaces).map((e) => e['workspace']),
        ['plugin_example', 'custom_engine'],
      );
    });
  });

  group('lockCheckWorkspaces', () {
    const table = [
      E2eWorkspace(
        'apple',
        runs: {Os.macos: 'a', Os.linux: 'b'},
        skips: {Os.windows: 'x'},
      ),
      E2eWorkspace(
        'neutral',
        runs: {Os.linux: 'a', Os.windows: 'b'},
        skips: {Os.macos: 'x'},
      ),
      E2eWorkspace(
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
        lockCheckProblems(lockCheckWorkspaces(e2eWorkspaces), [
          'MODULE.bazel.lock',
          for (final w in e2eWorkspaces) 'e2e/${w.name}/MODULE.bazel.lock',
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
