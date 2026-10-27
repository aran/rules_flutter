/// The text `app.dumpSemanticsTree` answers with: a running app's semantics
/// tree, one line per node.
///
/// The input is what `ext.rules_flutter.dumpSemanticsTree` returns (see
/// `flutter/private/agent_extensions/agent.dart`). The
/// output is meant for a reader deciding what to tap, type into or assert:
/// one line per node that says something, and nothing for the nodes that only
/// group others.
///
/// ```
/// view 0 800x600 @2x
/// #1 scopesRoute
///   #4 header "Hello World" @400,28 784x56
///   #9 button "Increment" [tap] @756,556 56x56
/// ```
///
/// A line is `#<id>`, then the node's role and flags as words, then its
/// strings, then its actions in brackets, then `@<x>,<y>` — the centre of
/// its rect, in the logical pixels `app.tap`'s `x` and `y` take — and
/// `<w>x<h>`, its size. Indentation is nesting.
library;

import 'dart:convert';

/// Render [views], the `views` list of the extension's answer, as text.
String renderCompactSemantics(List<Object?> views) {
  final out = StringBuffer();
  for (final view in views.cast<Map<String, Object?>>()) {
    final size = (view['size'] as List?)?.cast<num>();
    final dpr = view['devicePixelRatio'] as num?;
    out.write('view ${view['viewId']}');
    if (size != null) out.write(' ${size[0].round()}x${size[1].round()}');
    if (dpr != null) out.write(' @${_n(dpr)}x');
    out.writeln();
    if (view['missing'] case final String why) {
      out.writeln('(no semantics: $why)');
      continue;
    }
    if (view['root'] case final Map<String, Object?> root) {
      _renderNode(root, 0, out);
    }
  }
  return out.toString();
}

/// Writes [node] at [depth], or only its children at the same depth when the
/// node itself says nothing a reader could act on or check.
void _renderNode(Map<String, Object?> node, int depth, StringBuffer out) {
  // A node merged into its parent is part of the parent's label and actions
  // already, which is how an accessibility service sees it too.
  if (node['merged'] == true) return;
  final words = describeSemanticsNode(node);
  var childDepth = depth;
  if (words != null) {
    out
      ..write('  ' * depth)
      ..writeln('#${node['id']} $words');
    childDepth = depth + 1;
  }
  for (final child
      in (node['children'] as List? ?? const []).cast<Map<String, Object?>>()) {
    _renderNode(child, childDepth, out);
  }
}

/// The text after `#<id> ` on [node]'s line, or null when the node carries
/// nothing but its children.
String? describeSemanticsNode(Map<String, Object?> node) {
  final flags = {...(node['flags'] as List? ?? const []).cast<String>()};
  final words = <String>[
    if (node['role'] case final String role) role,
    ..._flagWords(flags),
    if (node['headingLevel'] case final int level) 'h$level',
  ];
  final label = node['label'] as String?;
  final strings = <String>[
    if (label != null) jsonEncode(label),
    if (node['value'] case final String v) 'value=${jsonEncode(v)}',
    if (node['hint'] case final String h) 'hint=${jsonEncode(h)}',
    if (node['tooltip'] case final String t when t != label)
      'tooltip=${jsonEncode(t)}',
    if (node['identifier'] case final String i) 'id=${jsonEncode(i)}',
  ];
  final actions = <String>[
    for (final a in (node['actions'] as List? ?? const []).cast<String>())
      if (!_quietActions.contains(a)) a,
    for (final c in (node['customActions'] as List? ?? const []).cast<String>())
      jsonEncode(c),
  ];
  if (words.isEmpty && strings.isEmpty && actions.isEmpty) return null;
  final parts = [
    ...words,
    ...strings,
    if (actions.isNotEmpty) '[${actions.join(',')}]',
    if (node['invisible'] == true) 'invisible',
  ];
  // No point for a node that cannot be tapped where it is. An invisible one
  // has no size; a hidden one is scrolled out of its viewport, so its rect
  // lies under whatever is drawn there instead, and a tap at it lands on that.
  if ((node['rect'] as List?)?.cast<num>()
      case [
        final l,
        final t,
        final r,
        final b,
      ]
      when node['invisible'] != true && !flags.contains('isHidden')) {
    parts.add(
      '@${((l + r) / 2).round()},${((t + b) / 2).round()} '
      '${(r - l).round()}x${(b - t).round()}',
    );
  }
  return parts.join(' ');
}

/// Flutter's flag names (`SemanticsFlags.toStrings`) as the words a line
/// carries.
///
/// A flag that says a state exists (`hasCheckedState`) and one that says what
/// it is (`isChecked`) become one word for the state. `is` is dropped from the
/// rest. Left out: what every node of its kind has and nothing turns on
/// (`isFocusable`, `hasEnabledState` with `isEnabled`, `hasImplicitScrolling`,
/// which the scroll actions already say).
Iterable<String> _flagWords(Set<String> flags) sync* {
  if (flags.contains('hasCheckedState')) {
    yield flags.contains('isCheckStateMixed')
        ? 'mixed'
        : flags.contains('isChecked')
        ? 'checked'
        : 'unchecked';
  }
  if (flags.contains('hasToggledState')) {
    yield flags.contains('isToggled') ? 'on' : 'off';
  }
  // Only the selected one: every list tile reports a selected state, and
  // "unselected" on each of them says nothing the selected one's word does not.
  if (flags.contains('isSelected')) yield 'selected';
  if (flags.contains('hasExpandedState')) {
    yield flags.contains('isExpanded') ? 'expanded' : 'collapsed';
  }
  if (flags.contains('hasEnabledState') && !flags.contains('isEnabled')) {
    yield 'disabled';
  }
  if (flags.contains('isRequired')) yield 'required';
  for (final flag in flags) {
    if (_stateFlags.contains(flag)) continue;
    yield flag.startsWith('is') && flag.length > 2
        ? flag[2].toLowerCase() + flag.substring(3)
        : flag;
  }
}

/// The flags [_flagWords] folds into a state word or leaves out.
const _stateFlags = {
  'hasCheckedState',
  'isChecked',
  'isCheckStateMixed',
  'hasToggledState',
  'isToggled',
  'hasSelectedState',
  'isSelected',
  'hasExpandedState',
  'isExpanded',
  'hasEnabledState',
  'isEnabled',
  'hasRequiredState',
  'isRequired',
  'isFocusable',
  'hasImplicitScrolling',
};

/// Actions nearly every focusable or text node offers, which say nothing
/// about what the node is for. Every other action is listed.
const _quietActions = {
  'focus',
  'showOnScreen',
  'didGainAccessibilityFocus',
  'didLoseAccessibilityFocus',
  'setSelection',
  'moveCursorForwardByCharacter',
  'moveCursorBackwardByCharacter',
  'moveCursorForwardByWord',
  'moveCursorBackwardByWord',
  'scrollToOffset',
};

/// [v] as a whole number when it is one, and to three decimals otherwise:
/// device pixel ratios such as 2.625 are not.
String _n(num v) {
  if (v == v.roundToDouble()) return '${v.round()}';
  return v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
}
