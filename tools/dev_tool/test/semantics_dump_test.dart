import 'package:flutter_bazel_dev_tool/semantics_dump.dart';
import 'package:test/test.dart';

/// A node, shaped as `_semanticsNodeJson` in
/// `agent_extensions/agent.dart` writes it.
Map<String, Object?> node(
  int id, {
  List<num> rect = const [0, 0, 100, 40],
  String? label,
  String? value,
  String? hint,
  String? tooltip,
  String? identifier,
  String? role,
  List<String>? flags,
  List<String>? actions,
  List<String>? customActions,
  bool merged = false,
  bool invisible = false,
  List<Map<String, Object?>>? children,
}) => {
  'id': id,
  'rect': rect,
  'label': ?label,
  'value': ?value,
  'hint': ?hint,
  'tooltip': ?tooltip,
  'identifier': ?identifier,
  'role': ?role,
  'flags': ?flags,
  'actions': ?actions,
  'customActions': ?customActions,
  if (merged) 'merged': true,
  if (invisible) 'invisible': true,
  'children': ?children,
};

Map<String, Object?> view(Map<String, Object?> root, {int viewId = 0}) => {
  'viewId': viewId,
  'size': [800.0, 600.0],
  'devicePixelRatio': 2.0,
  'root': root,
};

void main() {
  group('renderCompactSemantics', () {
    test('drops nodes that only group others and indents the rest', () {
      final text = renderCompactSemantics([
        view(
          node(
            0,
            rect: [0, 0, 800, 600],
            children: [
              node(
                1,
                rect: [0, 0, 800, 600],
                flags: ['scopesRoute'],
                children: [
                  node(
                    2,
                    children: [
                      node(
                        3,
                        rect: [8, 0, 792, 56],
                        label: 'Hello World',
                        flags: ['isHeader'],
                      ),
                    ],
                  ),
                  node(
                    4,
                    rect: [728, 528, 784, 584],
                    label: 'Increment',
                    tooltip: 'Increment',
                    flags: [
                      'isButton',
                      'hasEnabledState',
                      'isEnabled',
                      'isFocusable',
                    ],
                    actions: ['focus', 'tap'],
                  ),
                ],
              ),
            ],
          ),
        ),
      ]);
      expect(
        text,
        'view 0 800x600 @2x\n'
        '#1 scopesRoute @400,300 800x600\n'
        '  #3 header "Hello World" @400,28 784x56\n'
        '  #4 button "Increment" [tap] @756,556 56x56\n',
      );
    });

    test('says what each state flag means rather than listing both', () {
      String line(List<String> flags) =>
          describeSemanticsNode(node(1, flags: flags))!.split(' @').first;
      expect(line(['hasCheckedState', 'isChecked']), 'checked');
      expect(line(['hasCheckedState']), 'unchecked');
      expect(line(['hasCheckedState', 'isCheckStateMixed']), 'mixed');
      expect(line(['hasToggledState']), 'off');
      expect(line(['hasToggledState', 'isToggled']), 'on');
      expect(line(['hasSelectedState', 'isSelected']), 'selected');
      expect(line(['hasSelectedState', 'hasCheckedState']), 'unchecked');
      expect(line(['hasExpandedState']), 'collapsed');
      expect(line(['isButton', 'hasEnabledState']), 'disabled button');
      expect(
        line(['isTextField', 'isFocused', 'isFocusable']),
        'textField focused',
      );
      expect(line(['hasRequiredState', 'isRequired']), 'required');
    });

    test('keeps a node that carries only actions or only flags', () {
      expect(
        describeSemanticsNode(node(5, actions: ['scrollUp', 'scrollDown'])),
        '[scrollUp,scrollDown] @50,20 100x40',
      );
      expect(describeSemanticsNode(node(6, flags: ['isFocusable'])), isNull);
      expect(
        describeSemanticsNode(node(7, actions: ['focus', 'showOnScreen'])),
        isNull,
      );
    });

    test('quotes strings so labels with newlines and quotes stay one line', () {
      expect(
        describeSemanticsNode(
          node(
            8,
            label: 'Say "hi"\nnow',
            value: '3',
            hint: 'Double tap',
            identifier: 'greeting',
            role: 'tab',
            customActions: ['Archive'],
          ),
        ),
        'tab "Say \\"hi\\"\\nnow" value="3" hint="Double tap" id="greeting" '
        '["Archive"] @50,20 100x40',
      );
    });

    test('skips merged-up nodes, which their parent already describes', () {
      final text = renderCompactSemantics([
        view(
          node(
            1,
            label: 'Go',
            flags: ['isButton'],
            children: [node(2, label: 'Go', merged: true)],
          ),
        ),
      ]);
      expect(text, 'view 0 800x600 @2x\n#1 button "Go" @50,20 100x40\n');
    });

    test('an invisible node says so instead of giving a point to tap', () {
      expect(
        describeSemanticsNode(
          node(9, label: 'gone', rect: [0, 0, 0, 0], invisible: true),
        ),
        '"gone" invisible',
      );
    });

    test('a node scrolled out of view gives no point, which would miss', () {
      expect(
        describeSemanticsNode(
          node(
            10,
            label: 'item 9',
            rect: [300, 620, 500, 644],
            flags: ['isHidden'],
          ),
        ),
        'hidden "item 9"',
      );
    });

    test('heads every view and says why one has no tree', () {
      final text = renderCompactSemantics([
        view(node(1, label: 'a')),
        {
          'viewId': 1,
          'size': [400.0, 300.0],
          'devicePixelRatio': 2.625,
          'missing': 'the app is not drawing frames',
        },
      ]);
      expect(
        text,
        'view 0 800x600 @2x\n'
        '#1 "a" @50,20 100x40\n'
        'view 1 400x300 @2.625x\n'
        '(no semantics: the app is not drawing frames)\n',
      );
    });
  });
}
