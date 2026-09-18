/// What `app.pressKey` presses: a key chord, named the way Playwright's
/// `keyboard.press` names it, and the events that press it.
///
/// `Enter`, `ArrowDown`, `Backspace`, `a`, `A`, `!`, `Control+K`, `Shift+Tab`,
/// `Meta+A`, `ControlOrMeta+Z`. Coding agents already know this vocabulary, so
/// it is the one to accept rather than one of our own.
///
/// The tables here are ported from Playwright
/// (`packages/playwright-core/src/server/usKeyboardLayout.ts`,
/// `macEditingCommands.ts`, and the chord handling in `input.ts` and
/// `chromium/crInput.ts`), Copyright Microsoft Corporation and Google Inc.,
/// under the Apache License 2.0 — the same license as this repository. The
/// layout is a US keyboard, as it is there.
///
/// Pure Dart with no imports beyond the core library, because both routes
/// read it: the browser route turns a chord into CDP `Input.dispatchKeyEvent`
/// calls here, and the framework route sends the app the chord's keys by their
/// DOM `code`, which the app maps onto Flutter's own keys with
/// `kWebToPhysicalKey`. One table, so the two routes cannot disagree about
/// what a name means.
library;

/// A key that is held while another is pressed.
///
/// In CDP mask order: `Input.dispatchKeyEvent`'s `modifiers` is Alt=1,
/// Control=2, Meta=4, Shift=8.
enum KeyModifier {
  alt('Alt', 1),
  control('Control', 2),
  meta('Meta', 4),
  shift('Shift', 8);

  const KeyModifier(this.key, this.cdpBit);

  /// The DOM `KeyboardEvent.key` of this modifier.
  final String key;

  /// This modifier's bit in CDP's `modifiers` mask.
  final int cdpBit;

  static KeyModifier? forKey(String key) {
    for (final m in values) {
      if (m.key == key) return m;
    }
    return null;
  }
}

/// One key on a US keyboard, as a DOM `KeyboardEvent` would describe it.
class KeyDescription {
  /// `KeyboardEvent.code`: which physical key — `KeyA`, `Enter`,
  /// `ControlLeft`. Stable across modifiers.
  final String code;

  /// `KeyboardEvent.key`: what the key means right now — `a`, or `A` with
  /// Shift held, or `Enter`.
  final String key;

  /// The Windows virtual key code, which CDP wants as `windowsVirtualKeyCode`
  /// and which Flutter's web engine reads as `keyCode` (13 is what makes a
  /// single-line field submit).
  final int keyCode;

  /// What the key types, or empty when it types nothing: a named key, or any
  /// key pressed with a modifier other than Shift.
  final String text;

  /// `KeyboardEvent.location`: 0 standard, 1 left, 2 right, 3 numpad.
  final int location;

  /// This key with Shift held, where Shift changes what it types.
  final KeyDescription? shifted;

  const KeyDescription({
    required this.code,
    required this.key,
    required this.keyCode,
    required this.text,
    required this.location,
    this.shifted,
  });

  /// The modifier this key is, if it is one.
  KeyModifier? get modifier => KeyModifier.forKey(key);

  KeyDescription _copyWith({String? key, int? keyCode, String? text}) =>
      KeyDescription(
        code: code,
        key: key ?? this.key,
        keyCode: keyCode ?? this.keyCode,
        text: text ?? this.text,
        location: location,
      );

  @override
  String toString() => code;
}

/// A refused key chord, with a message that says what to write instead.
class KeyChordException implements Exception {
  final String message;
  const KeyChordException(this.message);

  @override
  String toString() => message;
}

/// One key going down or coming up, with the modifiers held while it does.
class KeyStroke {
  /// True for a key going down, false for one coming up.
  final bool down;

  /// The key as it reads at this moment: `A` rather than `a` when Shift is
  /// held, and typing nothing when another modifier is.
  final KeyDescription description;

  /// The modifiers held while this event is dispatched — after a modifier's
  /// own down has added it, and after its own up has removed it, as a browser
  /// reports them.
  final Set<KeyModifier> modifiers;

  const KeyStroke({
    required this.down,
    required this.description,
    required this.modifiers,
  });

  /// CDP's `modifiers` mask for [modifiers].
  int get cdpModifiers => modifiers.fold(0, (mask, m) => mask | m.cdpBit);

  /// The `Input.dispatchKeyEvent` parameters for this stroke, as Playwright's
  /// Chromium driver sends them.
  ///
  /// A down that types something is `keyDown` and carries its `text`, so the
  /// browser both fires `keydown` and inserts the text; one that types
  /// nothing is `rawKeyDown`. [macCommands] are the editing commands a Mac
  /// browser would have attached — see [macEditingCommandsFor] — and are
  /// empty off a Mac.
  Map<String, Object> cdpParams({List<String> macCommands = const []}) {
    final d = description;
    if (!down) {
      return {
        'type': 'keyUp',
        'modifiers': cdpModifiers,
        'key': d.key,
        'windowsVirtualKeyCode': d.keyCode,
        'code': d.code,
        'location': d.location,
      };
    }
    return {
      'type': d.text.isNotEmpty ? 'keyDown' : 'rawKeyDown',
      'modifiers': cdpModifiers,
      'windowsVirtualKeyCode': d.keyCode,
      'code': d.code,
      'commands': macCommands,
      'key': d.key,
      'text': d.text,
      'unmodifiedText': d.text,
      'autoRepeat': false,
      'location': d.location,
      'isKeypad': d.location == _keypadLocation,
    };
  }
}

/// A key chord: modifiers held, one key pressed and released, modifiers
/// released in reverse.
class KeyChord {
  /// As the caller wrote it.
  final String spec;

  /// The keys held down first, in the order they were named.
  final List<KeyDescription> held;

  /// The key pressed while they are held.
  final KeyDescription key;

  const KeyChord._(this.spec, this.held, this.key);

  /// Parse [spec] the way Playwright's `keyboard.press` does.
  ///
  /// Tokens are joined with `+`, and a `+` is itself a key when it is the
  /// first character or follows another `+` — so `+` and `Control++` both
  /// press the plus key. Every token before the last must be a modifier;
  /// Playwright also accepts `a+b`, but a chord of two ordinary keys is two
  /// presses to anything that is not a browser, and refusing it keeps both
  /// routes pressing the same thing.
  ///
  /// [controlOrMetaIsMeta] resolves `ControlOrMeta`, Playwright's name for
  /// the platform's primary shortcut modifier: Meta on Apple platforms,
  /// Control elsewhere. Which platform that is depends on the route — the
  /// browser's host for a browser, the app's OS for the framework.
  ///
  /// Throws [KeyChordException] naming the key it did not know.
  static KeyChord parse(String spec, {required bool controlOrMetaIsMeta}) {
    if (spec.isEmpty) {
      throw KeyChordException(
        'app.pressKey needs a key to press. $_vocabulary',
      );
    }
    final tokens = _split(spec);
    final resolved = <KeyDescription>[];
    for (final token in tokens) {
      final name = token == 'ControlOrMeta'
          ? (controlOrMetaIsMeta ? 'Meta' : 'Control')
          : token;
      final description = _usKeyboard[name];
      if (description == null) {
        throw KeyChordException(_unknown(token, spec));
      }
      resolved.add(description);
    }
    final held = resolved.sublist(0, resolved.length - 1);
    for (final (i, k) in held.indexed) {
      if (k.modifier == null) {
        throw KeyChordException(
          'In "$spec", "${tokens[i]}" is held while the last key is pressed, '
          'but it is not a modifier. Only Shift, Control, Alt, Meta and '
          'ControlOrMeta can be held. To press keys one after another, send '
          'one app.pressKey per key.',
        );
      }
    }
    return KeyChord._(spec, held, resolved.last);
  }

  /// Every event that presses this chord, in order: each held key down, the
  /// key down and up, each held key up in reverse.
  List<KeyStroke> get strokes {
    final pressed = <KeyModifier>{};
    final out = <KeyStroke>[];
    void stroke(KeyDescription base, {required bool down}) {
      final d = _asPressed(base, pressed);
      final m = d.modifier;
      if (m != null) {
        if (down) {
          pressed.add(m);
        } else {
          pressed.remove(m);
        }
      }
      out.add(
        KeyStroke(down: down, description: d, modifiers: {...pressed}),
      );
    }

    for (final k in held) {
      stroke(k, down: true);
    }
    stroke(key, down: true);
    stroke(key, down: false);
    for (final k in held.reversed) {
      stroke(k, down: false);
    }
    return out;
  }

  /// The key as pressed, with the held modifiers applied to it: what it
  /// reports and what it types.
  KeyDescription get pressedKey =>
      _asPressed(key, {for (final k in held) ?k.modifier});

  /// The modifiers held while [key] is pressed.
  Set<KeyModifier> get modifiers => {for (final k in held) ?k.modifier};
}

/// [base] as it reads with [pressed] held — Playwright's
/// `_keyDescriptionForString`.
///
/// Shift picks the shifted character where the key has one. Any modifier
/// other than Shift means the key types nothing: `Control+A` is a shortcut,
/// not an `a`.
KeyDescription _asPressed(KeyDescription base, Set<KeyModifier> pressed) {
  final shift = pressed.contains(KeyModifier.shift);
  final d = shift && base.shifted != null ? base.shifted! : base;
  final typesNothing = pressed.length > 1 || (pressed.length == 1 && !shift);
  return typesNothing ? d._copyWith(text: '') : d;
}

/// Playwright's `split`: `+` separates tokens, except that a `+` with nothing
/// before it in the current token is the plus key itself.
List<String> _split(String spec) {
  final keys = <String>[];
  final building = StringBuffer();
  for (final char in spec.split('')) {
    if (char == '+' && building.isNotEmpty) {
      keys.add(building.toString());
      building.clear();
    } else {
      building.write(char);
    }
  }
  keys.add(building.toString());
  return keys;
}

/// The editing commands a Mac browser attaches to [stroke], without their
/// trailing colon — what CDP's `commands` takes.
///
/// A browser on a Mac does not edit text from the key itself. AppKit turns
/// the key into a Cocoa selector (`moveDown:`, `deleteToEndOfParagraph:`)
/// and the browser runs the matching editing command. CDP's
/// `Input.dispatchKeyEvent` enters below AppKit, so a key sent without its
/// `commands` fires `keydown` and changes nothing in the field: ArrowDown
/// does not move the caret and Control+K deletes nothing.
///
/// Playwright filters out the commands that insert text, since the key's own
/// `text` inserts it. Enter is the exception kept here: `insertNewline` is
/// what makes a Mac browser treat it as the newline command, so it goes
/// with the key's `"\r"` rather than instead of it.
List<String> macEditingCommandsFor(KeyStroke stroke) {
  if (!stroke.down) return const [];
  final parts = [
    for (final m in const [
      KeyModifier.shift,
      KeyModifier.control,
      KeyModifier.alt,
      KeyModifier.meta,
    ])
      if (stroke.modifiers.contains(m)) m.key,
    stroke.description.code,
  ];
  final commands = _macEditingCommands[parts.join('+')] ?? const [];
  return [
    for (final c in commands)
      if (!c.startsWith('insert') || c == 'insertNewline:')
        c.substring(0, c.length - 1),
  ];
}

/// Named keys in the order a reader looks for them, for refusals.
const _vocabulary =
    'Keys are named the way Playwright\'s keyboard.press names them: a '
    'character ("a", "A", "!"), a KeyboardEvent key or code ("Enter", "Tab", '
    '"Backspace", "ArrowDown", "Escape", "KeyA", "Digit1", "Space"), with '
    'modifiers held by joining them with "+" ("Control+K", "Shift+Tab", '
    '"Meta+A", "ControlOrMeta+Z").';

/// Names people reach for that the vocabulary spells differently.
const _misspellings = {
  'ctrl': 'Control',
  'cmd': 'Meta',
  'command': 'Meta',
  'super': 'Meta',
  'win': 'Meta',
  'windows': 'Meta',
  'option': 'Alt',
  'opt': 'Alt',
  'esc': 'Escape',
  'return': 'Enter',
  'up': 'ArrowUp',
  'down': 'ArrowDown',
  'left': 'ArrowLeft',
  'right': 'ArrowRight',
  'del': 'Delete',
  'pgup': 'PageUp',
  'pgdn': 'PageDown',
  'pagedn': 'PageDown',
  'spacebar': 'Space',
  'plus': '+',
};

String _unknown(String token, String spec) {
  final lower = token.toLowerCase();
  String? suggestion = _misspellings[lower];
  if (suggestion == null && token.length > 1) {
    for (final name in _usKeyboard.keys) {
      if (name.length > 1 && name.toLowerCase() == lower) {
        suggestion = name;
        break;
      }
    }
  }
  final where = token == spec ? '' : ' in "$spec"';
  final hint = suggestion == null ? '' : ' Did you mean "$suggestion"?';
  if (token.isEmpty) {
    return 'Missing key$where: a "+" joins a modifier to the key pressed '
        'with it, so something has to follow it. $_vocabulary';
  }
  return 'Unknown key "$token"$where.$hint $_vocabulary';
}

const _keypadLocation = 3;

/// One row of Playwright's `USKeyboardLayout`.
class _KeyDef {
  final String code;
  final int keyCode;
  final String key;
  final String? shiftKey;
  final int? shiftKeyCode;
  final int? keyCodeWithoutLocation;
  final String? text;
  final int location;

  const _KeyDef(
    this.code,
    this.keyCode,
    this.key, {
    this.shiftKey,
    this.shiftKeyCode,
    this.keyCodeWithoutLocation,
    this.text,
    this.location = 0,
  });
}

const _usLayout = <_KeyDef>[
  // Functions row
  _KeyDef('Escape', 27, 'Escape'),
  _KeyDef('F1', 112, 'F1'),
  _KeyDef('F2', 113, 'F2'),
  _KeyDef('F3', 114, 'F3'),
  _KeyDef('F4', 115, 'F4'),
  _KeyDef('F5', 116, 'F5'),
  _KeyDef('F6', 117, 'F6'),
  _KeyDef('F7', 118, 'F7'),
  _KeyDef('F8', 119, 'F8'),
  _KeyDef('F9', 120, 'F9'),
  _KeyDef('F10', 121, 'F10'),
  _KeyDef('F11', 122, 'F11'),
  _KeyDef('F12', 123, 'F12'),

  // Numbers row
  _KeyDef('Backquote', 192, '`', shiftKey: '~'),
  _KeyDef('Digit1', 49, '1', shiftKey: '!'),
  _KeyDef('Digit2', 50, '2', shiftKey: '@'),
  _KeyDef('Digit3', 51, '3', shiftKey: '#'),
  _KeyDef('Digit4', 52, '4', shiftKey: r'$'),
  _KeyDef('Digit5', 53, '5', shiftKey: '%'),
  _KeyDef('Digit6', 54, '6', shiftKey: '^'),
  _KeyDef('Digit7', 55, '7', shiftKey: '&'),
  _KeyDef('Digit8', 56, '8', shiftKey: '*'),
  _KeyDef('Digit9', 57, '9', shiftKey: '('),
  _KeyDef('Digit0', 48, '0', shiftKey: ')'),
  _KeyDef('Minus', 189, '-', shiftKey: '_'),
  _KeyDef('Equal', 187, '=', shiftKey: '+'),
  _KeyDef('Backslash', 220, r'\', shiftKey: '|'),
  _KeyDef('Backspace', 8, 'Backspace'),

  // First row
  _KeyDef('Tab', 9, 'Tab'),
  _KeyDef('KeyQ', 81, 'q', shiftKey: 'Q'),
  _KeyDef('KeyW', 87, 'w', shiftKey: 'W'),
  _KeyDef('KeyE', 69, 'e', shiftKey: 'E'),
  _KeyDef('KeyR', 82, 'r', shiftKey: 'R'),
  _KeyDef('KeyT', 84, 't', shiftKey: 'T'),
  _KeyDef('KeyY', 89, 'y', shiftKey: 'Y'),
  _KeyDef('KeyU', 85, 'u', shiftKey: 'U'),
  _KeyDef('KeyI', 73, 'i', shiftKey: 'I'),
  _KeyDef('KeyO', 79, 'o', shiftKey: 'O'),
  _KeyDef('KeyP', 80, 'p', shiftKey: 'P'),
  _KeyDef('BracketLeft', 219, '[', shiftKey: '{'),
  _KeyDef('BracketRight', 221, ']', shiftKey: '}'),

  // Second row
  _KeyDef('CapsLock', 20, 'CapsLock'),
  _KeyDef('KeyA', 65, 'a', shiftKey: 'A'),
  _KeyDef('KeyS', 83, 's', shiftKey: 'S'),
  _KeyDef('KeyD', 68, 'd', shiftKey: 'D'),
  _KeyDef('KeyF', 70, 'f', shiftKey: 'F'),
  _KeyDef('KeyG', 71, 'g', shiftKey: 'G'),
  _KeyDef('KeyH', 72, 'h', shiftKey: 'H'),
  _KeyDef('KeyJ', 74, 'j', shiftKey: 'J'),
  _KeyDef('KeyK', 75, 'k', shiftKey: 'K'),
  _KeyDef('KeyL', 76, 'l', shiftKey: 'L'),
  _KeyDef('Semicolon', 186, ';', shiftKey: ':'),
  _KeyDef('Quote', 222, "'", shiftKey: '"'),
  _KeyDef('Enter', 13, 'Enter', text: '\r'),

  // Third row
  _KeyDef(
    'ShiftLeft',
    160,
    'Shift',
    keyCodeWithoutLocation: 16,
    location: 1,
  ),
  _KeyDef('KeyZ', 90, 'z', shiftKey: 'Z'),
  _KeyDef('KeyX', 88, 'x', shiftKey: 'X'),
  _KeyDef('KeyC', 67, 'c', shiftKey: 'C'),
  _KeyDef('KeyV', 86, 'v', shiftKey: 'V'),
  _KeyDef('KeyB', 66, 'b', shiftKey: 'B'),
  _KeyDef('KeyN', 78, 'n', shiftKey: 'N'),
  _KeyDef('KeyM', 77, 'm', shiftKey: 'M'),
  _KeyDef('Comma', 188, ',', shiftKey: '<'),
  _KeyDef('Period', 190, '.', shiftKey: '>'),
  _KeyDef('Slash', 191, '/', shiftKey: '?'),
  _KeyDef(
    'ShiftRight',
    161,
    'Shift',
    keyCodeWithoutLocation: 16,
    location: 2,
  ),

  // Last row
  _KeyDef(
    'ControlLeft',
    162,
    'Control',
    keyCodeWithoutLocation: 17,
    location: 1,
  ),
  _KeyDef('MetaLeft', 91, 'Meta', location: 1),
  _KeyDef('AltLeft', 164, 'Alt', keyCodeWithoutLocation: 18, location: 1),
  _KeyDef('Space', 32, ' '),
  _KeyDef('AltRight', 165, 'Alt', keyCodeWithoutLocation: 18, location: 2),
  _KeyDef('AltGraph', 225, 'AltGraph'),
  _KeyDef('MetaRight', 92, 'Meta', location: 2),
  _KeyDef('ContextMenu', 93, 'ContextMenu'),
  _KeyDef(
    'ControlRight',
    163,
    'Control',
    keyCodeWithoutLocation: 17,
    location: 2,
  ),

  // Center block
  _KeyDef('PrintScreen', 44, 'PrintScreen'),
  _KeyDef('ScrollLock', 145, 'ScrollLock'),
  _KeyDef('Pause', 19, 'Pause'),

  _KeyDef('PageUp', 33, 'PageUp'),
  _KeyDef('PageDown', 34, 'PageDown'),
  _KeyDef('Insert', 45, 'Insert'),
  _KeyDef('Delete', 46, 'Delete'),
  _KeyDef('Home', 36, 'Home'),
  _KeyDef('End', 35, 'End'),

  _KeyDef('ArrowLeft', 37, 'ArrowLeft'),
  _KeyDef('ArrowUp', 38, 'ArrowUp'),
  _KeyDef('ArrowRight', 39, 'ArrowRight'),
  _KeyDef('ArrowDown', 40, 'ArrowDown'),

  // Media keys
  _KeyDef('AudioVolumeMute', 173, 'AudioVolumeMute'),
  _KeyDef('AudioVolumeDown', 174, 'AudioVolumeDown'),
  _KeyDef('AudioVolumeUp', 175, 'AudioVolumeUp'),
  _KeyDef('MediaTrackNext', 176, 'MediaTrackNext'),
  _KeyDef('MediaTrackPrevious', 177, 'MediaTrackPrevious'),
  _KeyDef('MediaPlayPause', 179, 'MediaPlayPause'),

  // Numpad
  _KeyDef('NumLock', 144, 'NumLock'),
  _KeyDef('NumpadDivide', 111, '/', location: 3),
  _KeyDef('NumpadMultiply', 106, '*', location: 3),
  _KeyDef('NumpadSubtract', 109, '-', location: 3),
  _KeyDef(
    'Numpad7',
    36,
    'Home',
    shiftKeyCode: 103,
    shiftKey: '7',
    location: 3,
  ),
  _KeyDef(
    'Numpad8',
    38,
    'ArrowUp',
    shiftKeyCode: 104,
    shiftKey: '8',
    location: 3,
  ),
  _KeyDef(
    'Numpad9',
    33,
    'PageUp',
    shiftKeyCode: 105,
    shiftKey: '9',
    location: 3,
  ),
  _KeyDef(
    'Numpad4',
    37,
    'ArrowLeft',
    shiftKeyCode: 100,
    shiftKey: '4',
    location: 3,
  ),
  _KeyDef(
    'Numpad5',
    12,
    'Clear',
    shiftKeyCode: 101,
    shiftKey: '5',
    location: 3,
  ),
  _KeyDef(
    'Numpad6',
    39,
    'ArrowRight',
    shiftKeyCode: 102,
    shiftKey: '6',
    location: 3,
  ),
  _KeyDef('NumpadAdd', 107, '+', location: 3),
  _KeyDef(
    'Numpad1',
    35,
    'End',
    shiftKeyCode: 97,
    shiftKey: '1',
    location: 3,
  ),
  _KeyDef(
    'Numpad2',
    40,
    'ArrowDown',
    shiftKeyCode: 98,
    shiftKey: '2',
    location: 3,
  ),
  _KeyDef(
    'Numpad3',
    34,
    'PageDown',
    shiftKeyCode: 99,
    shiftKey: '3',
    location: 3,
  ),
  _KeyDef(
    'Numpad0',
    45,
    'Insert',
    shiftKeyCode: 96,
    shiftKey: '0',
    location: 3,
  ),
  _KeyDef(
    'NumpadDecimal',
    46,
    ' ',
    shiftKeyCode: 110,
    shiftKey: '.',
    location: 3,
  ),
  _KeyDef('NumpadEnter', 13, 'Enter', text: '\r', location: 3),
];

/// Playwright's `aliases`: the bare modifier names press the left-hand key,
/// and a newline presses Enter.
const _aliases = {
  'ShiftLeft': ['Shift'],
  'ControlLeft': ['Control'],
  'AltLeft': ['Alt'],
  'MetaLeft': ['Meta'],
  'Enter': ['\n', '\r'],
};

/// Every name a key answers to: its code, its aliases, the character it types
/// and, for keys Shift changes, the shifted character — Playwright's
/// `buildLayoutClosure`.
final Map<String, KeyDescription> _usKeyboard = () {
  final result = <String, KeyDescription>{};
  for (final def in _usLayout) {
    final text = def.key.length == 1 ? def.key : (def.text ?? '');
    final base = KeyDescription(
      code: def.code,
      key: def.key,
      keyCode: def.keyCodeWithoutLocation ?? def.keyCode,
      text: text,
      location: def.location,
    );
    final shiftKey = def.shiftKey;
    final shifted = shiftKey == null
        ? null
        : base._copyWith(
            key: shiftKey,
            text: shiftKey,
            keyCode: def.shiftKeyCode,
          );
    result[def.code] = KeyDescription(
      code: base.code,
      key: base.key,
      keyCode: base.keyCode,
      text: base.text,
      location: base.location,
      shifted: shifted,
    );
    for (final alias in _aliases[def.code] ?? const <String>[]) {
      result[alias] = base;
    }
    // The numpad is reached by code only: "1" is the digit row, not Numpad1.
    if (def.location != 0) continue;
    if (base.key.length == 1) result[base.key] = base;
    if (shifted != null) result[shifted.key] = shifted;
  }
  return result;
}();

/// Every name [KeyChord.parse] accepts, for tests and listings.
Iterable<String> get knownKeyNames => _usKeyboard.keys;

/// Playwright's `macEditingCommands`: the Cocoa selectors AppKit's standard
/// key bindings produce for a chord, keyed by `Shift+Control+Alt+Meta+code`
/// in that order.
const _macEditingCommands = <String, List<String>>{
  'Backspace': ['deleteBackward:'],
  'Enter': ['insertNewline:'],
  'NumpadEnter': ['insertNewline:'],
  'Escape': ['cancelOperation:'],
  'ArrowUp': ['moveUp:'],
  'ArrowDown': ['moveDown:'],
  'ArrowLeft': ['moveLeft:'],
  'ArrowRight': ['moveRight:'],
  'F5': ['complete:'],
  'Delete': ['deleteForward:'],
  'Home': ['scrollToBeginningOfDocument:'],
  'End': ['scrollToEndOfDocument:'],
  'PageUp': ['scrollPageUp:'],
  'PageDown': ['scrollPageDown:'],
  'Shift+Backspace': ['deleteBackward:'],
  'Shift+Enter': ['insertNewline:'],
  'Shift+NumpadEnter': ['insertNewline:'],
  'Shift+Escape': ['cancelOperation:'],
  'Shift+ArrowUp': ['moveUpAndModifySelection:'],
  'Shift+ArrowDown': ['moveDownAndModifySelection:'],
  'Shift+ArrowLeft': ['moveLeftAndModifySelection:'],
  'Shift+ArrowRight': ['moveRightAndModifySelection:'],
  'Shift+F5': ['complete:'],
  'Shift+Delete': ['deleteForward:'],
  'Shift+Home': ['moveToBeginningOfDocumentAndModifySelection:'],
  'Shift+End': ['moveToEndOfDocumentAndModifySelection:'],
  'Shift+PageUp': ['pageUpAndModifySelection:'],
  'Shift+PageDown': ['pageDownAndModifySelection:'],
  'Shift+Numpad5': ['delete:'],
  'Control+Tab': ['selectNextKeyView:'],
  'Control+Enter': ['insertLineBreak:'],
  'Control+NumpadEnter': ['insertLineBreak:'],
  'Control+Quote': ['insertSingleQuoteIgnoringSubstitution:'],
  'Control+KeyA': ['moveToBeginningOfParagraph:'],
  'Control+KeyB': ['moveBackward:'],
  'Control+KeyD': ['deleteForward:'],
  'Control+KeyE': ['moveToEndOfParagraph:'],
  'Control+KeyF': ['moveForward:'],
  'Control+KeyH': ['deleteBackward:'],
  'Control+KeyK': ['deleteToEndOfParagraph:'],
  'Control+KeyL': ['centerSelectionInVisibleArea:'],
  'Control+KeyN': ['moveDown:'],
  'Control+KeyO': ['insertNewlineIgnoringFieldEditor:', 'moveBackward:'],
  'Control+KeyP': ['moveUp:'],
  'Control+KeyT': ['transpose:'],
  'Control+KeyV': ['pageDown:'],
  'Control+KeyY': ['yank:'],
  'Control+Backspace': ['deleteBackwardByDecomposingPreviousCharacter:'],
  'Control+ArrowUp': ['scrollPageUp:'],
  'Control+ArrowDown': ['scrollPageDown:'],
  'Control+ArrowLeft': ['moveToLeftEndOfLine:'],
  'Control+ArrowRight': ['moveToRightEndOfLine:'],
  'Shift+Control+Enter': ['insertLineBreak:'],
  'Shift+Control+NumpadEnter': ['insertLineBreak:'],
  'Shift+Control+Tab': ['selectPreviousKeyView:'],
  'Shift+Control+Quote': ['insertDoubleQuoteIgnoringSubstitution:'],
  'Shift+Control+KeyA': ['moveToBeginningOfParagraphAndModifySelection:'],
  'Shift+Control+KeyB': ['moveBackwardAndModifySelection:'],
  'Shift+Control+KeyE': ['moveToEndOfParagraphAndModifySelection:'],
  'Shift+Control+KeyF': ['moveForwardAndModifySelection:'],
  'Shift+Control+KeyN': ['moveDownAndModifySelection:'],
  'Shift+Control+KeyP': ['moveUpAndModifySelection:'],
  'Shift+Control+KeyV': ['pageDownAndModifySelection:'],
  'Shift+Control+Backspace': ['deleteBackwardByDecomposingPreviousCharacter:'],
  'Shift+Control+ArrowUp': ['scrollPageUp:'],
  'Shift+Control+ArrowDown': ['scrollPageDown:'],
  'Shift+Control+ArrowLeft': ['moveToLeftEndOfLineAndModifySelection:'],
  'Shift+Control+ArrowRight': ['moveToRightEndOfLineAndModifySelection:'],
  'Alt+Backspace': ['deleteWordBackward:'],
  'Alt+Enter': ['insertNewlineIgnoringFieldEditor:'],
  'Alt+NumpadEnter': ['insertNewlineIgnoringFieldEditor:'],
  'Alt+Escape': ['complete:'],
  'Alt+ArrowUp': ['moveBackward:', 'moveToBeginningOfParagraph:'],
  'Alt+ArrowDown': ['moveForward:', 'moveToEndOfParagraph:'],
  'Alt+ArrowLeft': ['moveWordLeft:'],
  'Alt+ArrowRight': ['moveWordRight:'],
  'Alt+Delete': ['deleteWordForward:'],
  'Alt+PageUp': ['pageUp:'],
  'Alt+PageDown': ['pageDown:'],
  'Shift+Alt+Backspace': ['deleteWordBackward:'],
  'Shift+Alt+Enter': ['insertNewlineIgnoringFieldEditor:'],
  'Shift+Alt+NumpadEnter': ['insertNewlineIgnoringFieldEditor:'],
  'Shift+Alt+Escape': ['complete:'],
  'Shift+Alt+ArrowUp': ['moveParagraphBackwardAndModifySelection:'],
  'Shift+Alt+ArrowDown': ['moveParagraphForwardAndModifySelection:'],
  'Shift+Alt+ArrowLeft': ['moveWordLeftAndModifySelection:'],
  'Shift+Alt+ArrowRight': ['moveWordRightAndModifySelection:'],
  'Shift+Alt+Delete': ['deleteWordForward:'],
  'Shift+Alt+PageUp': ['pageUp:'],
  'Shift+Alt+PageDown': ['pageDown:'],
  'Control+Alt+KeyB': ['moveWordBackward:'],
  'Control+Alt+KeyF': ['moveWordForward:'],
  'Control+Alt+Backspace': ['deleteWordBackward:'],
  'Shift+Control+Alt+KeyB': ['moveWordBackwardAndModifySelection:'],
  'Shift+Control+Alt+KeyF': ['moveWordForwardAndModifySelection:'],
  'Shift+Control+Alt+Backspace': ['deleteWordBackward:'],
  'Meta+NumpadSubtract': ['cancel:'],
  'Meta+Backspace': ['deleteToBeginningOfLine:'],
  'Meta+ArrowUp': ['moveToBeginningOfDocument:'],
  'Meta+ArrowDown': ['moveToEndOfDocument:'],
  'Meta+ArrowLeft': ['moveToLeftEndOfLine:'],
  'Meta+ArrowRight': ['moveToRightEndOfLine:'],
  'Shift+Meta+NumpadSubtract': ['cancel:'],
  'Shift+Meta+Backspace': ['deleteToBeginningOfLine:'],
  'Shift+Meta+ArrowUp': ['moveToBeginningOfDocumentAndModifySelection:'],
  'Shift+Meta+ArrowDown': ['moveToEndOfDocumentAndModifySelection:'],
  'Shift+Meta+ArrowLeft': ['moveToLeftEndOfLineAndModifySelection:'],
  'Shift+Meta+ArrowRight': ['moveToRightEndOfLineAndModifySelection:'],
  'Meta+KeyA': ['selectAll:'],
  'Meta+KeyC': ['copy:'],
  'Meta+KeyX': ['cut:'],
  'Meta+KeyV': ['paste:'],
  'Meta+KeyZ': ['undo:'],
  'Shift+Meta+KeyZ': ['redo:'],
};
