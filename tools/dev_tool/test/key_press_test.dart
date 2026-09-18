import 'package:flutter_bazel_dev_tool/key_press.dart';
import 'package:test/test.dart';

KeyChord parse(String spec, {bool controlOrMetaIsMeta = true}) =>
    KeyChord.parse(spec, controlOrMetaIsMeta: controlOrMetaIsMeta);

/// The message [spec] is refused with.
String refusal(String spec) {
  try {
    final chord = parse(spec);
    fail('expected "$spec" to be refused, got ${chord.strokes}');
  } on KeyChordException catch (e) {
    return e.message;
  }
}

/// The CDP `Input.dispatchKeyEvent` parameters for [spec], in order.
List<Map<String, Object>> cdp(String spec, {bool mac = false}) => [
  for (final s in parse(spec).strokes)
    s.cdpParams(macCommands: mac ? macEditingCommandsFor(s) : const []),
];

void main() {
  group('KeyChord.parse', () {
    test('a named key is looked up by its DOM key or code', () {
      for (final (spec, code) in const [
        ('Enter', 'Enter'),
        ('ArrowDown', 'ArrowDown'),
        ('Backspace', 'Backspace'),
        ('Tab', 'Tab'),
        ('Escape', 'Escape'),
        ('KeyA', 'KeyA'),
        ('Digit1', 'Digit1'),
        ('Space', 'Space'),
        ('NumpadEnter', 'NumpadEnter'),
      ]) {
        expect(parse(spec).key.code, code, reason: spec);
      }
    });

    test('a character is case-sensitive, as Playwright\'s is', () {
      final lower = parse('a').pressedKey;
      expect((lower.code, lower.key, lower.text), ('KeyA', 'a', 'a'));
      final upper = parse('A').pressedKey;
      expect((upper.code, upper.key, upper.text), ('KeyA', 'A', 'A'));
      final bang = parse('!').pressedKey;
      expect((bang.code, bang.key, bang.text), ('Digit1', '!', '!'));
      expect(parse(' ').pressedKey.code, 'Space');
    });

    test('Shift picks the shifted character of a key named by code', () {
      final chord = parse('Shift+KeyA');
      expect(chord.held.single.code, 'ShiftLeft');
      expect(chord.pressedKey.key, 'A');
      expect(chord.pressedKey.text, 'A');
      expect(parse('Shift+Digit1').pressedKey.text, '!');
    });

    test('a key named by its character keeps it under Shift, as in '
        'Playwright', () {
      // Playwright's layout maps "a" to the unshifted key with no shifted
      // form, so `Shift+a` types "a". Kept, so a chord an agent learned there
      // types the same thing here.
      expect(parse('Shift+a').pressedKey.text, 'a');
    });

    test('any other modifier means the key types nothing', () {
      for (final spec in const [
        'Control+K',
        'Meta+A',
        'Alt+x',
        'Control+Shift+a',
      ]) {
        expect(parse(spec).pressedKey.text, isEmpty, reason: spec);
      }
    });

    test('Enter types a carriage return and the newline characters are '
        'Enter', () {
      expect(parse('Enter').pressedKey.text, '\r');
      expect(parse('\n').key.code, 'Enter');
      expect(parse('\r').key.code, 'Enter');
    });

    test('"+" is a key where it cannot be a separator', () {
      expect(parse('+').pressedKey.key, '+');
      final chord = parse('Control++');
      expect(chord.held.single.code, 'ControlLeft');
      expect(chord.key.code, 'Equal');
      expect(chord.pressedKey.key, '+');
    });

    test('ControlOrMeta resolves per platform', () {
      expect(parse('ControlOrMeta+a').held.single.code, 'MetaLeft');
      expect(
        parse('ControlOrMeta+a', controlOrMetaIsMeta: false).held.single.code,
        'ControlLeft',
      );
    });

    test('an unknown key is refused by name, with the spelling it meant', () {
      final ctrl = refusal('Ctrl+K');
      expect(ctrl, contains('Unknown key "Ctrl" in "Ctrl+K"'));
      expect(ctrl, contains('Did you mean "Control"?'));
      expect(refusal('enter'), contains('Did you mean "Enter"?'));
      expect(refusal('Cmd+A'), contains('Did you mean "Meta"?'));
      expect(refusal('Down'), contains('Did you mean "ArrowDown"?'));
      final nonsense = refusal('Hyper');
      expect(nonsense, contains('Unknown key "Hyper"'));
      expect(nonsense, isNot(contains('Did you mean')));
      expect(nonsense, contains('Control+K'), reason: 'names the vocabulary');
    });

    test('only modifiers can be held', () {
      expect(refusal('a+b'), contains('"a" is held'));
      expect(refusal('a+b'), contains('one app.pressKey per key'));
    });

    test('an empty key, or nothing after "+", is refused', () {
      expect(refusal(''), contains('needs a key'));
      expect(refusal('Control+'), contains('Missing key in "Control+"'));
    });

    test('every key code in the layout is a name of its own', () {
      for (final code in const [
        'Escape',
        'F12',
        'Backquote',
        'Minus',
        'Equal',
        'Backslash',
        'BracketLeft',
        'Semicolon',
        'Quote',
        'Comma',
        'Period',
        'Slash',
        'ShiftRight',
        'ControlRight',
        'AltRight',
        'MetaRight',
        'PageUp',
        'Home',
        'Delete',
        'Numpad0',
        'NumpadDecimal',
      ]) {
        expect(knownKeyNames, contains(code));
        expect(parse(code).key.code, code);
      }
    });
  });

  group('KeyChord.strokes', () {
    test('holds the modifiers around the key, releasing in reverse', () {
      final strokes = parse('Control+Shift+Tab').strokes;
      expect(
        strokes.map((s) => '${s.down ? 'v' : '^'}${s.description.code}'),
        [
          'vControlLeft',
          'vShiftLeft',
          'vTab',
          '^Tab',
          '^ShiftLeft',
          '^ControlLeft',
        ],
      );
    });

    test('reports the modifiers as a browser does: a modifier counts '
        'from its own down to its own up', () {
      final masks = parse('Control+K').strokes.map((s) => s.cdpModifiers);
      // Control is 2 in CDP's mask.
      expect(masks, [2, 2, 2, 0]);
    });
  });

  group('cdpParams', () {
    test('a key that types is a keyDown carrying its text', () {
      final events = cdp('a');
      expect(events[0], {
        'type': 'keyDown',
        'modifiers': 0,
        'windowsVirtualKeyCode': 65,
        'code': 'KeyA',
        'commands': <String>[],
        'key': 'a',
        'text': 'a',
        'unmodifiedText': 'a',
        'autoRepeat': false,
        'location': 0,
        'isKeypad': false,
      });
      expect(events[1], {
        'type': 'keyUp',
        'modifiers': 0,
        'key': 'a',
        'windowsVirtualKeyCode': 65,
        'code': 'KeyA',
        'location': 0,
      });
    });

    test('Enter is a keyDown with "\\r" and virtual key 13, which is what '
        'submits a field', () {
      final down = cdp('Enter').first;
      expect(down['type'], 'keyDown');
      expect(down['text'], '\r');
      expect(down['windowsVirtualKeyCode'], 13);
    });

    test('a key that types nothing is a rawKeyDown', () {
      for (final spec in const ['ArrowDown', 'Backspace', 'Control+K']) {
        final down = cdp(spec).lastWhere((e) => e['type'] != 'keyUp');
        expect(down['type'], 'rawKeyDown', reason: spec);
        expect(down['text'], isEmpty, reason: spec);
      }
    });

    test('a modifier reports its location and the unsided virtual key', () {
      final control = cdp('Control+K').first;
      expect(control['code'], 'ControlLeft');
      expect(control['key'], 'Control');
      expect(control['windowsVirtualKeyCode'], 17);
      expect(control['location'], 1);
    });

    test('a numpad key is flagged as one', () {
      expect(cdp('NumpadEnter').first['isKeypad'], isTrue);
      expect(cdp('Enter').first['isKeypad'], isFalse);
    });
  });

  group('macEditingCommandsFor', () {
    List<String> commandsFor(String spec) =>
        cdp(spec, mac: true).lastWhere((e) => e['type'] != 'keyUp')['commands']
            as List<String>;

    test(
      'attaches the Cocoa command a Mac browser would, without its colon',
      () {
        expect(commandsFor('Control+K'), ['deleteToEndOfParagraph']);
        expect(commandsFor('ArrowDown'), ['moveDown']);
        expect(commandsFor('Control+N'), ['moveDown']);
        expect(commandsFor('Shift+ArrowLeft'), ['moveLeftAndModifySelection']);
        expect(commandsFor('Alt+ArrowUp'), [
          'moveBackward',
          'moveToBeginningOfParagraph',
        ]);
        expect(commandsFor('Meta+A'), ['selectAll']);
      },
    );

    test('keeps insertNewline for Enter and drops the other insertions', () {
      expect(commandsFor('Enter'), ['insertNewline']);
      expect(commandsFor('Control+O'), ['moveBackward']);
      expect(commandsFor('Alt+Enter'), isEmpty);
    });

    test('a key with no binding, and every key up, carries none', () {
      expect(commandsFor('a'), isEmpty);
      for (final e in cdp('Control+K', mac: true)) {
        if (e['type'] == 'keyUp') expect(e.containsKey('commands'), isFalse);
      }
    });

    test('off a Mac nothing is attached', () {
      for (final e in cdp('Control+K')) {
        if (e['type'] != 'keyUp') expect(e['commands'], isEmpty);
      }
    });
  });
}
