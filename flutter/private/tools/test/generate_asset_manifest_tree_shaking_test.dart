// Tagged `runfiles`: the harness finds the tool and its stand-ins through
// `package:runfiles`, which only Bazel supplies.
@Tags(['runfiles'])
library;

import 'dart:convert';

import 'package:record_use/record_use.dart';
import 'package:test/test.dart';

import 'tree_shaking_harness.dart';

void main() {
  // A font file is stored as the text of its own path, and the stand-in
  // `font-subset` writes `subset(<that text>): <code points kept>`.

  test('an icon font is subset to the code points the program uses', () async {
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
      ],
      recordedUses: [
        usesIcons({
          'Icons': [1, 2],
        }),
      ],
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(run.read('fonts/Icons.ttf'), 'subset(fonts/Icons.ttf): 1 2');
  });

  test('a font the program uses no icon of is bundled whole', () async {
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
        Family('Text', ['fonts/Text.ttf']),
      ],
      recordedUses: [
        usesIcons({
          'Icons': [1],
        }),
      ],
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(run.read('fonts/Text.ttf'), 'fonts/Text.ttf');
  });

  test('each family is subset to its own code points', () async {
    final run = await runTool(
      families: [
        Family('First', ['fonts/First.ttf']),
        Family('Second', ['fonts/Second.ttf']),
      ],
      recordedUses: [
        usesIcons({
          'First': [1],
          'Second': [2],
        }),
      ],
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(run.read('fonts/First.ttf'), 'subset(fonts/First.ttf): 1');
    expect(run.read('fonts/Second.ttf'), 'subset(fonts/Second.ttf): 2');
  });

  test('each family is subset to its own code points whatever the order '
      'of the manifest, when one path ends with the other', () async {
    final families = [
      Family('Packaged', ['packages/p/fonts/Icons.ttf']),
      Family('Plain', ['fonts/Icons.ttf']),
    ];
    final run = await runTool(
      families: families,
      recordedUses: [
        usesIcons({
          'Packaged': [1],
          'Plain': [2],
        }),
      ],
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(
      run.read('packages/p/fonts/Icons.ttf'),
      'subset(packages/p/fonts/Icons.ttf): 1',
    );
    expect(run.read('fonts/Icons.ttf'), 'subset(fonts/Icons.ttf): 2');
  });

  group('a font is subset with the code points of its own family', () {
    // flutter_tools finds the font of a family by its exact path in the
    // bundle. Whatever two paths a bundle holds, a font never takes another
    // family's icons, however the paths relate. The cases are the relations a
    // suffix match gets wrong.
    final cases = <String, List<Family>>{
      // `packages/p/fonts/Icons.ttf` ends with `fonts/Icons.ttf`.
      'one path ends with the other': [
        Family('Plain', ['fonts/Icons.ttf']),
        Family('Packaged', ['packages/p/fonts/Icons.ttf']),
      ],
      // `fonts/MyIcons.ttf` ends with `Icons.ttf`, with no directory between.
      'one name ends with the other': [
        Family('Short', ['Icons.ttf']),
        Family('Long', ['fonts/MyIcons.ttf']),
      ],
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        final families = entry.value;
        final run = await runTool(
          families: families,
          recordedUses: [
            usesIcons({
              for (final (i, family) in families.indexed) family.name: [i + 1],
            }),
          ],
        );

        expect(run.exitCode, 0, reason: run.stderrText);
        for (final (i, family) in families.indexed) {
          final path = family.assets.single;
          expect(run.read(path), 'subset($path): ${i + 1}');
        }
      });
    }
  });

  test('an icon family with several font files fails the build', () async {
    // flutter_tools: "This tool cannot process icon fonts with multiple fonts
    // in a single family." Subsetting the first and shipping the rest whole
    // would leave the bundle holding icons the program was said not to use.
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons-Regular.ttf', 'fonts/Icons-Bold.ttf']),
      ],
      recordedUses: [
        usesIcons({
          'Icons': [1],
        }),
      ],
    );

    expect(run.exitCode, isNot(0));
  });

  test('a recorded uses file that is not JSON fails the build', () async {
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
      ],
      recordedUses: ['not json'],
    );

    expectTreeShakingFailure(run, 'Failed to parse the recorded uses file');
  });

  group('a recorded uses file of a shape the tool does not know fails the '
      'build saying so', () {
    // Not a crash: a cast or an index out of range would end the tool with a
    // stack trace and no word of icon tree shaking or how to turn it off.
    final iconData = {
      'uri': 'package:flutter/src/widgets/icon_data.dart',
      'path': [
        {'name': 'IconData'},
      ],
    };
    final cases = <String, Object?>{
      'constants that are not a list': {'constants': 'x'},
      'a use of a definition it does not list': {
        'uses': {
          'instances': [
            {'definition_index': 3, 'uses': <Object?>[]},
          ],
        },
      },
      'a constant index that is not a number': {
        'definitions': [iconData],
        'uses': {
          'instances': [
            {
              'definition_index': 0,
              'uses': [
                {'type': 'constant', 'constant_index': 'zero'},
              ],
            },
          ],
        },
      },
      'a constant index past the constants': {
        'definitions': [iconData],
        'constants': <Object?>[],
        'uses': {
          'instances': [
            {
              'definition_index': 0,
              'uses': [
                {
                  'type': 'creation',
                  'positional': [4],
                },
              ],
            },
          ],
        },
      },
    };
    for (final MapEntry(key: name, value: recorded) in cases.entries) {
      test(name, () async {
        final run = await runTool(
          families: [
            Family('Icons', ['fonts/Icons.ttf']),
          ],
          recordedUses: [jsonEncode(recorded)],
        );

        expectTreeShakingFailure(run, 'Invalid recorded uses file');
      });
    }
  });

  test('the uses of every compile are the program\'s', () async {
    // flutter_tools merges the uses dart2js and dart2wasm record.
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
      ],
      recordedUses: [
        usesIcons({
          'Icons': [1],
        }),
        usesIcons({
          'Icons': [2],
        }),
      ],
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(run.read('fonts/Icons.ttf'), 'subset(fonts/Icons.ttf): 1 2');
  });

  test('an IconData made with constant arguments is used', () async {
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
      ],
      recordedUses: [
        recordings([creation(IntConstant(7), StringConstant('Icons'))]),
      ],
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(run.read('fonts/Icons.ttf'), 'subset(fonts/Icons.ttf): 7');
  });

  test(
    'a known icon font the program uses no icon of keeps one glyph',
    () async {
      // flutter_tools 3.50 cuts MaterialIcons to `Icons.add` and CupertinoIcons
      // to `chevron_left` rather than shipping them whole.
      final run = await runTool(
        families: [
          Family('MaterialIcons', ['fonts/MaterialIcons-Regular.otf']),
          Family('packages/cupertino_icons/CupertinoIcons', [
            'packages/cupertino_icons/assets/CupertinoIcons.ttf',
          ]),
        ],
        recordedUses: ['{}'],
      );

      expect(run.exitCode, 0, reason: run.stderrText);
      expect(
        run.read('fonts/MaterialIcons-Regular.otf'),
        'subset(fonts/MaterialIcons-Regular.otf): ${0xe047}',
      );
      expect(
        run.read('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        'subset(packages/cupertino_icons/assets/CupertinoIcons.ttf): ${0xf3d2}',
      );
    },
  );

  test('a font-subset that fails fails the build', () async {
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
      ],
      recordedUses: [
        usesIcons({
          'Icons': [1],
        }),
      ],
      contents: {'fonts/Icons.ttf': 'unsubsettable'},
    );

    expect(run.exitCode, isNot(0));
  });

  group('an IconData that is not constant fails the build', () {
    // flutter_tools: "Avoid non-constant invocations of IconData or try to
    // build again with --no-tree-shake-icons." Which icons such a program
    // uses is unknown, so no subset of the font is safe, and the full font
    // is not what the program was asked to ship.
    final cases = <String, InstanceReference>{
      'a code point not known at compile time': creation(
        const NonConstant(),
        StringConstant('Icons'),
      ),
      'a torn-off constructor': tearOff,
    };
    for (final MapEntry(key: name, value: reference) in cases.entries) {
      test(name, () async {
        final run = await runTool(
          families: [
            Family('Icons', ['fonts/Icons.ttf']),
          ],
          recordedUses: [
            recordings([constantIcon(1, 'Icons'), reference]),
          ],
        );

        expectTreeShakingFailure(run, 'non-constant instances of IconData');
      });
    }
  });
}

/// That [run] ended the build through the tool's own failure, whose message
/// has [message] and says how to build without icon tree shaking.
void expectTreeShakingFailure(Run run, String message) {
  expect(run.exitCode, 1, reason: run.stderrText);
  expect(run.stderrText, contains(message));
  expect(run.stderrText, contains('tree_shake_icons = False'));
}
