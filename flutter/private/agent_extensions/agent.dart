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
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show SemanticsBinding, SemanticsHandle;
import 'package:flutter/widgets.dart';

/// Keeps the semantics tree compiled so the `semanticsLabel` finder can read
/// `RenderObject.debugSemantics`. Semantics are off by default; flutter_driver
/// enables them on demand. We enable once for the (debug-only) agent build and
/// never dispose — the handle just has to stay reachable.
// ignore: unused_field
SemanticsHandle? _semanticsHandle;

void registerRulesFlutterAgentExtensions() {
  _semanticsHandle = SemanticsBinding.instance.ensureSemantics();
  registerExtension('ext.rules_flutter.tap', _guard(_handleTap));
  registerExtension('ext.rules_flutter.longPress', _guard(_handleLongPress));
  registerExtension('ext.rules_flutter.doubleTap', _guard(_handleDoubleTap));
  registerExtension('ext.rules_flutter.drag', _guard(_handleDrag));
  registerExtension(
      'ext.rules_flutter.scrollIntoView', _guard(_handleScrollIntoView));
  registerExtension('ext.rules_flutter.enterText', _guard(_handleEnterText));
  registerExtension('ext.rules_flutter.getText', _guard(_handleGetText));
  registerExtension('ext.rules_flutter.getRect', _guard(_handleGetRect));
  registerExtension('ext.rules_flutter.waitFor', _guard(_handleWaitFor));
  registerExtension(
      'ext.rules_flutter.waitForAbsent', _guard(_handleWaitForAbsent));
  registerExtension('ext.rules_flutter.pageBack', _guard(_handlePageBack));
}

/// Wrap a handler so a [TimeoutException] from the settle/idle-wait (see
/// [_waitUntilIdle]) becomes a clean error response instead of an opaque
/// extension failure. The handler still *throws* TimeoutException internally
/// (matching flutter_driver's `command.timeout`); this only serializes it for
/// the wire, since a Dart exception type can't cross the VM service boundary.
Future<ServiceExtensionResponse> Function(String, Map<String, String>) _guard(
  Future<ServiceExtensionResponse> Function(String, Map<String, String>) handler,
) {
  return (method, params) async {
    try {
      return await handler(method, params);
    } on TimeoutException catch (e) {
      return _err('timed out after ${e.duration?.inMilliseconds}ms waiting for '
          'the app to settle (window may be minimized/occluded so frames are '
          'paused)');
    }
  };
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

/// Settle after an action so a follow-up getRect/getText observes the result,
/// using the caller's optional `timeoutMs` (default 10s).
///
/// The input was already dispatched synchronously. If the embedder has paused
/// frames (window hidden/minimized/occluded — `framesEnabled` is false),
/// waiting for a frame or for animations would block until the window is shown
/// again, so we return immediately rather than burn the whole timeout. This is
/// what keeps interactions from hanging when an agent drives a backgrounded
/// app — the bug this replaced. Otherwise we wait for the pending frame to
/// render and the app to go idle (see [_waitUntilSettled]).
Future<void> _settle(Map<String, String> params) {
  final timeout = Duration(
    milliseconds: int.tryParse(params['timeoutMs'] ?? '10000') ?? 10000,
  );
  if (!SchedulerBinding.instance.framesEnabled) return Future<void>.value();
  return _waitUntilSettled(timeout);
}

/// Wait for the pending frame to render (so a `setState` rebuild from the
/// action is observable) and then for the app to go idle — no animations in
/// flight — bounded by [timeout].
///
/// Mirrors flutter_driver's frame-sync (`transientCallbackCount == 0`), but
/// also guarantees at least one rendered frame so non-animating state changes
/// are visible on return (flutter_driver leans on inter-command timing for
/// that). Throws [TimeoutException] if the app never settles within [timeout]
/// (e.g. a perpetual animation) — matching flutter_driver's `command.timeout`
/// (`Future.timeout`); unlike flutter_driver, whose default timeout is `null`,
/// we always pass a finite one.
Future<void> _waitUntilSettled(Duration timeout) {
  final completer = Completer<void>();
  void checkIdle(Duration _) {
    if (SchedulerBinding.instance.transientCallbackCount == 0) {
      if (!completer.isCompleted) completer.complete();
    } else {
      SchedulerBinding.instance.addPostFrameCallback(checkIdle);
    }
  }

  // Run after the next frame (the action's rebuild), then poll idle.
  SchedulerBinding.instance.addPostFrameCallback(checkIdle);
  SchedulerBinding.instance.scheduleFrame();
  return completer.future.timeout(timeout);
}

Future<ServiceExtensionResponse> _handleTap(
  String method,
  Map<String, String> params,
) =>
    _withRect(params, (rect) async {
      _dispatchTapAt(rect.center);
      await _settle(params);
      return {
        'tappedAt': {'x': rect.center.dx, 'y': rect.center.dy},
      };
    });

Future<ServiceExtensionResponse> _handleLongPress(
  String method,
  Map<String, String> params,
) =>
    _withRect(params, (rect) async {
      final hold = Duration(
        milliseconds: int.tryParse(params['durationMs'] ?? '500') ?? 500,
      );
      await _dispatchLongPressAt(rect.center, hold);
      await _settle(params);
      return {
        'pressedAt': {'x': rect.center.dx, 'y': rect.center.dy},
        'heldMs': hold.inMilliseconds,
      };
    });

Future<ServiceExtensionResponse> _handleDoubleTap(
  String method,
  Map<String, String> params,
) =>
    _withRect(params, (rect) async {
      await _dispatchDoubleTapAt(rect.center);
      await _settle(params);
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
  return _withRect(params, (rect) async {
    final start = rect.center;
    final end = start + Offset(dx, dy);
    await _dispatchDrag(start, end, duration);
    await _settle(params);
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
  final _Selector sel;
  try {
    sel = _selector(params);
  } on _SelectorError catch (e) {
    return _err(e.message);
  }
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
  var element = _findElementWhere(sel.test);
  if (element != null) {
    await Scrollable.ensureVisible(element, duration: duration);
    await _settle(params);
    return _ok({'iterations': 0});
  }

  // Slow path: target hasn't been built yet (lazy ListView). Drag the
  // scrollable identified by [scrollableKey] by (dx, dy) repeatedly
  // until the target shows up or we exhaust [maxIterations]. We hold
  // an Element reference (cheap, stable across frames) and recompute
  // its rect each iteration so a moving scrollable still gets dragged
  // at its current screen position. The scrollable is addressed by
  // ValueKey only (selectors apply to the scroll *target*).
  if (scrollableKey == null) {
    return _err('no widget matching ${sel.label}; '
        'pass scrollableKey to drag-scroll');
  }
  final scrollableEl = _findElementWhere(_valueKeyTest(scrollableKey));
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
    await _settle(params);
    element = _findElementWhere(sel.test);
    if (element != null) {
      await Scrollable.ensureVisible(element, duration: duration);
      await _settle(params);
      return _ok({'iterations': i});
    }
  }
  return _err('did not find ${sel.label} after $maxIterations scrolls of '
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
  await _settle(params);
  return _ok({'enteredText': text});
}

Future<ServiceExtensionResponse> _handleGetText(
  String method,
  Map<String, String> params,
) async {
  final _Selector sel;
  try {
    sel = _selector(params);
  } on _SelectorError catch (e) {
    return _err(e.message);
  }
  final el = _findElementWhere(sel.test);
  if (el == null) return _err('no widget matching ${sel.label} found');
  final text = _textOf(el);
  if (text == null) return _err('no Text widget under ${sel.label}');
  return _ok({'text': text});
}

Future<ServiceExtensionResponse> _handleGetRect(
  String method,
  Map<String, String> params,
) =>
    _withRect(params, (rect) async => _rectAsMap(rect));

Future<ServiceExtensionResponse> _handleWaitFor(
  String method,
  Map<String, String> params,
) async {
  final _Selector sel;
  try {
    sel = _selector(params);
  } on _SelectorError catch (e) {
    return _err(e.message);
  }
  final timeout = Duration(
    milliseconds: int.tryParse(params['timeoutMs'] ?? '5000') ?? 5000,
  );
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final rect = _rectOf(_findElementWhere(sel.test));
    if (rect != null) return _ok(_rectAsMap(rect));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return _err('timed out waiting for ${sel.label}');
}

Future<ServiceExtensionResponse> _handleWaitForAbsent(
  String method,
  Map<String, String> params,
) async {
  final _Selector sel;
  try {
    sel = _selector(params);
  } on _SelectorError catch (e) {
    return _err(e.message);
  }
  final timeout = Duration(
    milliseconds: int.tryParse(params['timeoutMs'] ?? '5000') ?? 5000,
  );
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (_rectOf(_findElementWhere(sel.test)) == null) return _ok({});
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return _err('timed out waiting for ${sel.label} to disappear');
}

Future<ServiceExtensionResponse> _handlePageBack(
  String method,
  Map<String, String> params,
) async {
  final nav = _findNavigator();
  if (nav == null) return _err('no Navigator found in widget tree');
  final popped = await nav.maybePop();
  await _settle(params);
  return _ok({'popped': popped});
}

/// Resolve the target element via the selector params, fetch its RenderBox
/// rect, run [body] with it, and wrap the result in `_ok`. Shared by tap,
/// longPress, doubleTap, drag, and getRect.
Future<ServiceExtensionResponse> _withRect(
  Map<String, String> params,
  Future<Map<String, Object?>> Function(Rect rect) body,
) async {
  final _Selector sel;
  try {
    sel = _selector(params);
  } on _SelectorError catch (e) {
    return _err(e.message);
  }
  final rect = _rectOf(_findElementWhere(sel.test));
  if (rect == null) return _err('no widget matching ${sel.label} found');
  return _ok(await body(rect));
}

Map<String, Object?> _rectAsMap(Rect rect) => {
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    };

// ---------------------------------------------------------------------------
// Finders.
//
// Mirrors flutter_driver's SerializableFinder vocabulary (ByValueKey, ByText,
// ByTooltipMessage, ByType, BySemanticsLabel) but hand-rolled against the
// element tree, since this file cannot import flutter_test/flutter_driver.
// ---------------------------------------------------------------------------

typedef _ElementPredicate = bool Function(Element el);

/// A resolved selector: a human-readable [label] for error messages and the
/// [test] predicate that matches the target element.
class _Selector {
  _Selector(this.label, this.test);
  final String label;
  final _ElementPredicate test;
}

/// Thrown by [_selector] when the selector params are missing or ambiguous;
/// callers translate it into an `_err` response.
class _SelectorError implements Exception {
  _SelectorError(this.message);
  final String message;
}

_ElementPredicate _valueKeyTest(String value) =>
    (el) => el.widget.key is ValueKey && (el.widget.key as ValueKey).value == value;

/// Resolve the finder from exactly one of `key`, `text`, `tooltip`, `type`,
/// or `semanticsLabel`. Throws [_SelectorError] if none or more than one is
/// provided (no silent precedence).
_Selector _selector(Map<String, String> params) {
  final key = params['key'];
  final text = params['text'];
  final tooltip = params['tooltip'];
  final type = params['type'];
  final semanticsLabel = params['semanticsLabel'];

  final provided = <String>[
    if (key != null) 'key',
    if (text != null) 'text',
    if (tooltip != null) 'tooltip',
    if (type != null) 'type',
    if (semanticsLabel != null) 'semanticsLabel',
  ];
  if (provided.isEmpty) {
    throw _SelectorError('missing selector: provide one of '
        'key, text, tooltip, type, semanticsLabel');
  }
  if (provided.length > 1) {
    throw _SelectorError('ambiguous selector: provide exactly one of '
        'key, text, tooltip, type, semanticsLabel (got ${provided.join(", ")})');
  }

  if (key != null) {
    return _Selector('ValueKey($key)', _valueKeyTest(key));
  }
  if (text != null) {
    return _Selector('text "$text"', (el) {
      final w = el.widget;
      return (w is Text && w.data == text) ||
          (w is EditableText && w.controller.text == text);
    });
  }
  if (tooltip != null) {
    return _Selector('tooltip "$tooltip"',
        (el) => el.widget is Tooltip && (el.widget as Tooltip).message == tooltip);
  }
  if (type != null) {
    return _Selector(
        'type $type', (el) => el.widget.runtimeType.toString() == type);
  }
  return _Selector('semanticsLabel "$semanticsLabel"',
      (el) => el.renderObject?.debugSemantics?.label == semanticsLabel);
}

/// Depth-first search for the first element matching [test].
Element? _findElementWhere(_ElementPredicate test) {
  Element? match;
  void visit(Element el) {
    if (match != null) return;
    if (test(el)) {
      match = el;
      return;
    }
    el.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return match;
}

/// Global-coordinate rect of [el]'s RenderBox, or null if unsized/absent.
Rect? _rectOf(Element? el) {
  if (el == null) return null;
  final ro = el.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/// Text content of [el] if it (or its first Text descendant) is a Text widget.
String? _textOf(Element el) {
  final w = el.widget;
  if (w is Text) return w.data;
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
