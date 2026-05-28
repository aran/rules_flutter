// AI-agent custom service extensions.
//
// Registered in the wrapper main injected by flutter_compile_kernel for
// debug builds. Exposes the `ext.rules_flutter.*` API the dev_tool's HTTP
// control channel proxies to.
//
// Imports only `package:flutter` and `dart:*` — no flutter_driver, no
// flutter_test, no transitive pub deps.

import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

void registerRulesFlutterAgentExtensions() {
  registerExtension('ext.rules_flutter.tap', _handleTap);
  registerExtension('ext.rules_flutter.longPress', _handleLongPress);
  registerExtension('ext.rules_flutter.doubleTap', _handleDoubleTap);
  registerExtension('ext.rules_flutter.drag', _handleDrag);
  registerExtension('ext.rules_flutter.scrollIntoView', _handleScrollIntoView);
  registerExtension('ext.rules_flutter.enterText', _handleEnterText);
  registerExtension('ext.rules_flutter.getText', _handleGetText);
  registerExtension('ext.rules_flutter.getRect', _handleGetRect);
  registerExtension('ext.rules_flutter.waitFor', _handleWaitFor);
  registerExtension('ext.rules_flutter.waitForAbsent', _handleWaitForAbsent);
  registerExtension('ext.rules_flutter.pageBack', _handlePageBack);
}

// Synthetic pointer IDs start at 0x70000 to keep them well clear of real
// device pointer ranges (touch screens / mice typically issue IDs from 1).
int _nextPointer = 0x70000;

Duration _now() =>
    Duration(microseconds: DateTime.now().microsecondsSinceEpoch);

void _dispatchTapAt(Offset position) {
  final pointer = ++_nextPointer;
  final ts = _now();
  GestureBinding.instance.handlePointerEvent(PointerDownEvent(
    timeStamp: ts,
    pointer: pointer,
    position: position,
    kind: PointerDeviceKind.touch,
  ));
  GestureBinding.instance.handlePointerEvent(PointerUpEvent(
    timeStamp: ts,
    pointer: pointer,
    position: position,
    kind: PointerDeviceKind.touch,
  ));
}

Future<void> _dispatchLongPressAt(Offset position, Duration hold) async {
  final pointer = ++_nextPointer;
  final start = _now();
  GestureBinding.instance.handlePointerEvent(PointerDownEvent(
    timeStamp: start,
    pointer: pointer,
    position: position,
    kind: PointerDeviceKind.touch,
  ));
  await Future<void>.delayed(hold);
  GestureBinding.instance.handlePointerEvent(PointerUpEvent(
    timeStamp: start + hold,
    pointer: pointer,
    position: position,
    kind: PointerDeviceKind.touch,
  ));
}

Future<void> _dispatchDoubleTapAt(Offset position) async {
  _dispatchTapAt(position);
  // DoubleTapGestureRecognizer accepts taps within kDoubleTapTimeout (300ms).
  await Future<void>.delayed(const Duration(milliseconds: 100));
  _dispatchTapAt(position);
}

Future<void> _dispatchDrag(
    Offset start, Offset end, Duration duration) async {
  final pointer = ++_nextPointer;
  const steps = 10;
  final stepDur = Duration(microseconds: duration.inMicroseconds ~/ steps);
  final baseTs = _now();

  GestureBinding.instance.handlePointerEvent(PointerDownEvent(
    timeStamp: baseTs,
    pointer: pointer,
    position: start,
    kind: PointerDeviceKind.touch,
  ));
  Offset previous = start;
  for (var i = 1; i <= steps; i++) {
    final t = i / steps;
    final next = Offset.lerp(start, end, t)!;
    GestureBinding.instance.handlePointerEvent(PointerMoveEvent(
      timeStamp: baseTs + stepDur * i,
      pointer: pointer,
      position: next,
      delta: next - previous,
      kind: PointerDeviceKind.touch,
    ));
    previous = next;
  }
  GestureBinding.instance.handlePointerEvent(PointerUpEvent(
    timeStamp: baseTs + duration,
    pointer: pointer,
    position: end,
    kind: PointerDeviceKind.touch,
  ));
}

Future<ServiceExtensionResponse> _handleTap(
  String method,
  Map<String, String> params,
) =>
    _withRectByKey(params, (rect) async {
      _dispatchTapAt(rect.center);
      await SchedulerBinding.instance.endOfFrame;
      return {
        'tappedAt': {'x': rect.center.dx, 'y': rect.center.dy},
      };
    });

Future<ServiceExtensionResponse> _handleLongPress(
  String method,
  Map<String, String> params,
) =>
    _withRectByKey(params, (rect) async {
      final hold = Duration(
        milliseconds: int.tryParse(params['durationMs'] ?? '500') ?? 500,
      );
      await _dispatchLongPressAt(rect.center, hold);
      await SchedulerBinding.instance.endOfFrame;
      return {
        'pressedAt': {'x': rect.center.dx, 'y': rect.center.dy},
        'heldMs': hold.inMilliseconds,
      };
    });

Future<ServiceExtensionResponse> _handleDoubleTap(
  String method,
  Map<String, String> params,
) =>
    _withRectByKey(params, (rect) async {
      await _dispatchDoubleTapAt(rect.center);
      await SchedulerBinding.instance.endOfFrame;
      return {
        'tappedAt': {'x': rect.center.dx, 'y': rect.center.dy},
      };
    });

Future<ServiceExtensionResponse> _handleDrag(
  String method,
  Map<String, String> params,
) async {
  final dx = double.tryParse(params['dx'] ?? '');
  final dy = double.tryParse(params['dy'] ?? '');
  if (dx == null || dy == null) {
    return _err('drag requires numeric dx and dy');
  }
  final duration = Duration(
    milliseconds: int.tryParse(params['durationMs'] ?? '200') ?? 200,
  );
  return _withRectByKey(params, (rect) async {
    final start = rect.center;
    final end = start + Offset(dx, dy);
    await _dispatchDrag(start, end, duration);
    await SchedulerBinding.instance.endOfFrame;
    return {
      'from': {'x': start.dx, 'y': start.dy},
      'to': {'x': end.dx, 'y': end.dy},
      'durationMs': duration.inMilliseconds,
    };
  });
}

Future<ServiceExtensionResponse> _handleScrollIntoView(
  String method,
  Map<String, String> params,
) async {
  final key = params['key'];
  if (key == null) return _err('missing required param: key');
  final duration = Duration(
    milliseconds: int.tryParse(params['durationMs'] ?? '200') ?? 200,
  );
  final scrollableKey = params['scrollableKey'];
  final dx = double.tryParse(params['dx'] ?? '0') ?? 0;
  final dy = double.tryParse(params['dy'] ?? '-50') ?? -50;
  final maxIterations =
      int.tryParse(params['maxIterations'] ?? '40') ?? 40;

  // Fast path: target is already in the element tree → use the framework
  // helper to scroll any ancestor Scrollable into the right offset.
  var element = _findElementByValueKey(key);
  if (element != null) {
    await Scrollable.ensureVisible(element, duration: duration);
    await SchedulerBinding.instance.endOfFrame;
    return _ok({'iterations': 0});
  }

  // Slow path: target hasn't been built yet (lazy ListView). Drag the
  // scrollable identified by [scrollableKey] by (dx, dy) repeatedly
  // until the target shows up or we exhaust [maxIterations]. We hold
  // an Element reference (cheap, stable across frames) and recompute
  // its rect each iteration so a moving scrollable still gets dragged
  // at its current screen position.
  if (scrollableKey == null) {
    return _err(
        'no widget with ValueKey($key); pass scrollableKey to drag-scroll');
  }
  final scrollableEl = _findElementByValueKey(scrollableKey);
  if (scrollableEl == null) {
    return _err('no scrollable with ValueKey($scrollableKey)');
  }
  final delta = Offset(dx, dy);
  for (var i = 1; i <= maxIterations; i++) {
    final ro = scrollableEl.renderObject;
    if (ro is! RenderBox || !ro.hasSize) {
      return _err(
          'scrollable with ValueKey($scrollableKey) was unmounted mid-scroll');
    }
    final scrollableRect = ro.localToGlobal(Offset.zero) & ro.size;
    await _dispatchDrag(
        scrollableRect.center, scrollableRect.center + delta, duration);
    await SchedulerBinding.instance.endOfFrame;
    element = _findElementByValueKey(key);
    if (element != null) {
      await Scrollable.ensureVisible(element, duration: duration);
      await SchedulerBinding.instance.endOfFrame;
      return _ok({'iterations': i});
    }
  }
  return _err(
      'did not find ValueKey($key) after $maxIterations scrolls of '
      'ValueKey($scrollableKey) by ($dx, $dy)');
}

Future<ServiceExtensionResponse> _handleEnterText(
  String method,
  Map<String, String> params,
) async {
  final text = params['text'];
  if (text == null) return _err('missing required param: text');
  final focused = FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();
  if (focused == null) return _err('no focused EditableText');
  focused.userUpdateTextEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
    SelectionChangedCause.keyboard,
  );
  await SchedulerBinding.instance.endOfFrame;
  return _ok({'enteredText': text});
}

Future<ServiceExtensionResponse> _handleGetText(
  String method,
  Map<String, String> params,
) async {
  final key = params['key'];
  if (key == null) return _err('missing required param: key');
  final text = _findTextByValueKey(key);
  if (text == null) return _err('no Text widget with ValueKey($key)');
  return _ok({'text': text});
}

Future<ServiceExtensionResponse> _handleGetRect(
  String method,
  Map<String, String> params,
) =>
    _withRectByKey(params, (rect) async => _rectAsMap(rect));

Future<ServiceExtensionResponse> _handleWaitFor(
  String method,
  Map<String, String> params,
) async {
  final key = params['key'];
  if (key == null) return _err('missing required param: key');
  final timeout = Duration(
    milliseconds: int.tryParse(params['timeoutMs'] ?? '5000') ?? 5000,
  );
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final rect = _findRenderBoxRectByValueKey(key);
    if (rect != null) return _ok(_rectAsMap(rect));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return _err('timed out waiting for ValueKey($key)');
}

Future<ServiceExtensionResponse> _handleWaitForAbsent(
  String method,
  Map<String, String> params,
) async {
  final key = params['key'];
  if (key == null) return _err('missing required param: key');
  final timeout = Duration(
    milliseconds: int.tryParse(params['timeoutMs'] ?? '5000') ?? 5000,
  );
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (_findRenderBoxRectByValueKey(key) == null) return _ok({});
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return _err('timed out waiting for ValueKey($key) to disappear');
}

Future<ServiceExtensionResponse> _handlePageBack(
  String method,
  Map<String, String> params,
) async {
  final nav = _findNavigator();
  if (nav == null) return _err('no Navigator found in widget tree');
  final popped = await nav.maybePop();
  await SchedulerBinding.instance.endOfFrame;
  return _ok({'popped': popped});
}

/// Look up the keyed widget's RenderBox rect, run [body] with it, and wrap
/// the result in `_ok`. Five handlers (tap, longPress, doubleTap, drag,
/// getRect) share this prelude.
Future<ServiceExtensionResponse> _withRectByKey(
  Map<String, String> params,
  Future<Map<String, Object?>> Function(Rect rect) body,
) async {
  final key = params['key'];
  if (key == null) return _err('missing required param: key');
  final rect = _findRenderBoxRectByValueKey(key);
  if (rect == null) return _err('no widget with ValueKey($key) found');
  return _ok(await body(rect));
}

Map<String, Object?> _rectAsMap(Rect rect) => {
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    };

Element? _findElementByValueKey(String keyValue) {
  Element? match;
  void visit(Element el) {
    if (match != null) return;
    final k = el.widget.key;
    if (k is ValueKey && k.value == keyValue) {
      match = el;
      return;
    }
    el.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return match;
}

Rect? _findRenderBoxRectByValueKey(String keyValue) {
  final el = _findElementByValueKey(keyValue);
  if (el == null) return null;
  final ro = el.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

String? _findTextByValueKey(String keyValue) {
  final el = _findElementByValueKey(keyValue);
  if (el == null) return null;
  final w = el.widget;
  if (w is Text) return w.data;
  // Walk descendants for the first Text child.
  String? out;
  el.visitChildren((child) {
    if (out != null) return;
    if (child.widget is Text) out = (child.widget as Text).data;
  });
  return out;
}

NavigatorState? _findNavigator() {
  NavigatorState? nav;
  void visit(Element el) {
    if (nav != null) return;
    if (el is StatefulElement && el.state is NavigatorState) {
      nav = el.state as NavigatorState;
      return;
    }
    el.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return nav;
}

ServiceExtensionResponse _ok(Map<String, Object?> body) =>
    ServiceExtensionResponse.result(jsonEncode(body));

ServiceExtensionResponse _err(String message) =>
    ServiceExtensionResponse.error(
      ServiceExtensionResponse.invalidParams,
      message,
    );
