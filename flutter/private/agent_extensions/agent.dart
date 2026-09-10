// AI-agent custom service extensions.
//
// Registered before main() runs, so registration must not touch any Flutter
// binding; binding-dependent setup is deferred to first handler invocation.
// Exposes the `ext.rules_flutter.*` API the dev_tool's HTTP control channel
// proxies to.
//
// Two routes in, both of them pre-main. Native: the generated plugin
// registrant, which the engine invokes on every root-isolate launch, hot
// restart included. Web: the dev tool's synthetic entrypoint calls the
// registrar as its first statement, because the engine hook has no web
// equivalent — and because a web bundle cannot carry these at all, dart2wasm
// and dart2js having stubbed out `registerExtension`.
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
  registerExtension('ext.rules_flutter.tap', _guard(_handleTap));
  registerExtension('ext.rules_flutter.longPress', _guard(_handleLongPress));
  registerExtension('ext.rules_flutter.doubleTap', _guard(_handleDoubleTap));
  registerExtension('ext.rules_flutter.drag', _guard(_handleDrag));
  registerExtension(
    'ext.rules_flutter.scrollIntoView',
    _guard(_handleScrollIntoView),
  );
  registerExtension('ext.rules_flutter.enterText', _guard(_handleEnterText));
  registerExtension('ext.rules_flutter.getText', _guard(_handleGetText));
  registerExtension('ext.rules_flutter.getRect', _guard(_handleGetRect));
  registerExtension('ext.rules_flutter.settle', _guard(_handleSettle));
  registerExtension('ext.rules_flutter.waitFor', _guard(_handleWaitFor));
  registerExtension(
    'ext.rules_flutter.waitForAbsent',
    _guard(_handleWaitForAbsent),
  );
  registerExtension('ext.rules_flutter.pageBack', _guard(_handlePageBack));

  // Deliberately NOT wrapped in `_guard`: this one answers from a compile-time
  // constant and touches no binding, so it must stay answerable pre-main —
  // `_guard` would call `SemanticsBinding.instance` and wait for a frame, which
  // an app paused at its entrypoint never produces. `flutter_bazel attach`
  // reads this before the app is settled, sometimes before it has run at all.
  registerExtension('ext.rules_flutter.buildInfo', _handleBuildInfo);
}

/// The build configuration `flutter_compile_kernel` baked into this app.
///
/// Empty outside a debug build, and empty in any app whose rule supplies no
/// assets tree — see `assets_dir` in `flutter/private/common.bzl`.
const String _buildInfoJson = String.fromEnvironment(
  'rules_flutter.build_info',
);

Future<ServiceExtensionResponse> _handleBuildInfo(
  String method,
  Map<String, String> params,
) async {
  if (_buildInfoJson.isEmpty) {
    return _err(
      'this app carries no rules_flutter.build_info: it was not built in '
      '-c dbg by a rule that bundles assets, or its kernel was recompiled '
      'without the define. The dev tool cannot tell which build tree backs '
      'it, so it will not guess one.',
    );
  }
  return ServiceExtensionResponse.result(_buildInfoJson);
}

/// Wrap a handler so a [TimeoutException] from the settle/idle-wait (see
/// [_waitUntilSettled]) becomes a clean error response instead of an opaque
/// extension failure. The handler still *throws* TimeoutException internally
/// (matching flutter_driver's `command.timeout`); this only serializes it for
/// the wire, since a Dart exception type can't cross the VM service boundary.
Future<ServiceExtensionResponse> Function(String, Map<String, String>) _guard(
  Future<ServiceExtensionResponse> Function(String, Map<String, String>)
  handler,
) {
  return (method, params) async {
    try {
      // Registration runs pre-main (engine plugin-registrant hook), before
      // any binding exists — binding-dependent setup is deferred to first
      // invocation, by which point the app is running. Enable semantics once
      // and wait a frame so the tree exists for semanticsLabel finders.
      //
      // The wait happens only when a frame can happen, and is bounded even
      // then. `SchedulerBinding.scheduleFrame` returns without doing anything
      // while `framesEnabled` is false (`scheduler/binding.dart:947`), and
      // `endOfFrame` only completes from a post-frame callback — so waiting on
      // it in that state never ends. This handler would never return, and the
      // dev tool's command pool is serialized through one slot, so every
      // command behind it would queue for the life of the run.
      //
      // What turns frames off is the app lifecycle and nothing else.
      // `handleAppLifecycleStateChanged` is the only thing that ever sets
      // `framesEnabled` false (`scheduler/binding.dart:414`) — for `hidden`,
      // `paused` and `detached`, back true for `resumed` and `inactive`; the
      // only other writer is `resetInternalState`, which is
      // `@visibleForTesting` and only ever sets it true. Window visibility
      // does not appear in any of it. So the state is routine wherever the OS backgrounds
      // apps — this file is staged into every *debug* kernel, iOS and Android
      // included (`AGENT_EXTENSIONS_ATTR` in `common.bzl`) — and hard to reach
      // on a desktop: measured on macOS (Darwin 25.5), a minimized window and
      // a hidden application both kept producing frames at ~8/s. That is one
      // host and one OS version, so read the desktop half as unmeasured
      // elsewhere; the lifecycle mechanism above is from the source and holds
      // everywhere. `_settle` below guards on the same flag for the same
      // reason, and neither guard becomes dead code merely because this Mac
      // cannot produce the state.
      //
      // The bound is not that same check written twice: frames can stop
      // between the check and the await, and only a deadline closes that
      // window rather than narrowing it. It is absorbed rather than reported
      // because both paths leave the same state — the tree may not be built
      // yet — and a `semanticsLabel` finder, the only one that reads it, then
      // simply reports no match.
      if (_semanticsHandle == null) {
        _semanticsHandle = SemanticsBinding.instance.ensureSemantics();
        if (SchedulerBinding.instance.framesEnabled) {
          SchedulerBinding.instance.scheduleFrame();
          await SchedulerBinding.instance.endOfFrame.timeout(
            _semanticsFrameBound,
            onTimeout: () {},
          );
        }
      }
      return await handler(method, params);
    } on FormatException catch (e) {
      // A parameter this file refused to guess at. `settle` is the one that
      // can say it: a typo there would otherwise pick the opposite behaviour
      // in silence.
      return _err(e.message);
    } on TimeoutException catch (e) {
      // Not a frames-off app: `_settle` returns early for that instead of
      // timing out. What reaches here is an app that never went idle — an
      // animation still in flight when the deadline passed — or one the OS
      // backgrounded after the frames-enabled check, so the frame being
      // awaited never came.
      //
      // The count separates those two: zero means nothing was animating, so
      // the frame simply never came; non-zero names the wait for what it is.
      // It is read here
      // rather than captured at the deadline because a callback that outlived
      // the bound is still registered now — that is the whole condition.
      final animating = SchedulerBinding.instance.transientCallbackCount;
      return _err(
        'timed out after ${e.duration?.inMilliseconds}ms waiting for the app '
        'to settle: ${animating == 0 ? 'nothing was animating, so the app was '
                  'backgrounded mid-command and the frame being waited on never '
                  'arrived' : '$animating animation'
                  '${animating == 1 ? ' was' : 's were'} still in flight, so it '
                  'never went idle'}. An app that animates perpetually — a spinner, '
        'a custom caret — never settles: pass "settle": "false" to act '
        'without waiting, and app.waitFor to resynchronise afterwards.',
      );
    }
  };
}

/// How long the one-time semantics bootstrap waits for its frame.
///
/// A frame the embedder has agreed to produce arrives within one vsync — 16ms
/// at 60Hz — so this is a safety net for frames stopping between the
/// `framesEnabled` check and the await, never a budget anything spends.
const Duration _semanticsFrameBound = Duration(seconds: 5);

// Synthetic pointer IDs start at 0x70000 to keep them well clear of real
// device pointer ranges (touch screens / mice typically issue IDs from 1).
int _nextPointer = 0x70000;

Duration _now() =>
    Duration(microseconds: DateTime.now().microsecondsSinceEpoch);

void _dispatchTapAt(Offset position) {
  final pointer = ++_nextPointer;
  final ts = _now();
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(
      timeStamp: ts,
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
    ),
  );
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(
      timeStamp: ts,
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
    ),
  );
}

Future<void> _dispatchLongPressAt(Offset position, Duration hold) async {
  final pointer = ++_nextPointer;
  final start = _now();
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(
      timeStamp: start,
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
    ),
  );
  await Future<void>.delayed(hold);
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(
      timeStamp: start + hold,
      pointer: pointer,
      position: position,
      kind: PointerDeviceKind.touch,
    ),
  );
}

Future<void> _dispatchDoubleTapAt(Offset position) async {
  _dispatchTapAt(position);
  // DoubleTapGestureRecognizer accepts taps within kDoubleTapTimeout (300ms).
  await Future<void>.delayed(const Duration(milliseconds: 100));
  _dispatchTapAt(position);
}

Future<void> _dispatchDrag(Offset start, Offset end, Duration duration) async {
  final pointer = ++_nextPointer;
  const steps = 10;
  final stepDur = Duration(microseconds: duration.inMicroseconds ~/ steps);
  final baseTs = _now();

  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(
      timeStamp: baseTs,
      pointer: pointer,
      position: start,
      kind: PointerDeviceKind.touch,
    ),
  );
  Offset previous = start;
  for (var i = 1; i <= steps; i++) {
    final t = i / steps;
    final next = Offset.lerp(start, end, t)!;
    GestureBinding.instance.handlePointerEvent(
      PointerMoveEvent(
        timeStamp: baseTs + stepDur * i,
        pointer: pointer,
        position: next,
        delta: next - previous,
        kind: PointerDeviceKind.touch,
      ),
    );
    previous = next;
  }
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(
      timeStamp: baseTs + duration,
      pointer: pointer,
      position: end,
      kind: PointerDeviceKind.touch,
    ),
  );
}

/// Settle after an action so a follow-up getRect/getText observes the result,
/// using the caller's optional `timeoutMs` (default 10s).
///
/// The input was already dispatched synchronously. When `framesEnabled` is
/// false there is no frame to wait for: the flag tracks the app *lifecycle*
/// (`hidden`/`paused`/`detached`), not window visibility — see the longer note
/// in [_guard] — so the app is backgrounded, and nothing will schedule a frame
/// until it comes back. Returning straight away spends none of the caller's
/// `timeoutMs` on a frame that cannot arrive, and reports no failure for a
/// state that is not one.
///
/// What stops a hang is the bound inside [_waitUntilSettled], not this check —
/// frames can stop after it. Otherwise we wait for the pending frame to render
/// and the app to go idle (see [_waitUntilSettled]).
///
/// `settle: "false"` skips the wait entirely — flutter_driver's
/// `runUnsynchronized`, under a name that says what it turns off. Some apps
/// never go idle: a spinner, a progress indicator, a hand-rolled caret, any
/// perpetual `AnimationController` holds a transient callback for as long as
/// it runs, and every command on such an app spends its whole `timeoutMs` and
/// then fails. Without this they could not be driven at all. The cost is the
/// guarantee the wait exists for — a follow-up `getText` may read the state
/// from before the action — so `app.waitFor` is how a caller resynchronises.
///
/// Parsed strictly, unlike the numeric parameters around it, which fall back
/// to their defaults. A number that fails to parse is a slower command; a
/// `settle` that fails to parse is the opposite behaviour, chosen silently.
Future<void> _settle(Map<String, String> params) {
  if (!_boolParam(params, 'settle', ifAbsent: true)) {
    return Future<void>.value();
  }
  final timeout = Duration(
    milliseconds: int.tryParse(params['timeoutMs'] ?? '10000') ?? 10000,
  );
  if (!SchedulerBinding.instance.framesEnabled) return Future<void>.value();
  return _waitUntilSettled(timeout);
}

/// Read a boolean parameter, or [ifAbsent] when the caller did not pass one.
///
/// Throws [FormatException] — which [_guard] renders as the command's error —
/// for anything that is neither `"true"` nor `"false"`. Service-extension
/// parameters arrive as strings, so there is no type to lean on, and a caller
/// that sent `1` or `yes` has said something this cannot act on either way.
bool _boolParam(
  Map<String, String> params,
  String name, {
  required bool ifAbsent,
}) {
  final raw = params[name];
  if (raw == null) return ifAbsent;
  return switch (raw) {
    'true' => true,
    'false' => false,
    _ => throw FormatException(
      '$name must be "true" or "false", not "$raw"',
    ),
  };
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
) => _withRect(dispatchesPointer: true, params, (rect) async {
  _dispatchTapAt(rect.center);
  await _settle(params);
  return {
    'tappedAt': {'x': rect.center.dx, 'y': rect.center.dy},
  };
});

Future<ServiceExtensionResponse> _handleLongPress(
  String method,
  Map<String, String> params,
) => _withRect(dispatchesPointer: true, params, (rect) async {
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
) => _withRect(dispatchesPointer: true, params, (rect) async {
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
  return _withRect(dispatchesPointer: true, params, (rect) async {
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
  final maxIterations = int.tryParse(params['maxIterations'] ?? '40') ?? 40;

  // Fast path: target is already in the element tree → use the framework
  // helper to scroll any ancestor Scrollable into the right offset.
  var element = _findElementWhere(sel.test);
  if (element != null) {
    await Scrollable.ensureVisible(element, duration: duration);
    await _settle(params);
    return _ok({'iterations': 0, 'reachable': _reachable(element)});
  }

  // Slow path: target hasn't been built yet (lazy ListView). Drag the
  // scrollable identified by [scrollableKey] by (dx, dy) repeatedly
  // until the target shows up or we exhaust [maxIterations]. We hold
  // an Element reference (cheap, stable across frames) and recompute
  // its rect each iteration so a moving scrollable still gets dragged
  // at its current screen position. The scrollable is addressed by
  // ValueKey only (selectors apply to the scroll *target*).
  if (scrollableKey == null) {
    return _err(
      'no widget matching ${sel.label}; '
      'pass scrollableKey to drag-scroll',
    );
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
        'scrollable with ValueKey($scrollableKey) was unmounted mid-scroll',
      );
    }
    final scrollableRect = ro.localToGlobal(Offset.zero) & ro.size;
    await _dispatchDrag(
      scrollableRect.center,
      scrollableRect.center + delta,
      duration,
    );
    await _settle(params);
    element = _findElementWhere(sel.test);
    if (element != null) {
      await Scrollable.ensureVisible(element, duration: duration);
      await _settle(params);
      return _ok({'iterations': i, 'reachable': _reachable(element)});
    }
  }
  return _err(
    'did not find ${sel.label} after $maxIterations scrolls of '
    'ValueKey($scrollableKey) by ($dx, $dy)',
  );
}

/// Type [text] into a field.
///
/// With a selector, the field is the first `EditableText` under the matched
/// widget — so the key can sit where a human would put it, on the
/// `TextField`, rather than on the `EditableText` it builds — and it is
/// focused first, the way a tap would. With no selector, the currently
/// focused field is used (`flutter_driver`'s model), which is what an
/// autofocused form or a tap-with-side-effects flow wants.
///
/// `text` is this method's payload, so it cannot double as the `text`
/// selector it is on every other method; the other four selectors apply.
Future<ServiceExtensionResponse> _handleEnterText(
  String method,
  Map<String, String> params,
) async {
  final text = params['text'];
  if (text == null) {
    return _err('missing required param: text (the string to type)');
  }

  final EditableTextState field;
  final String target;
  if (_selectorNames.any(params.containsKey)) {
    final _Selector sel;
    try {
      sel = _selector(params, textIsSelector: false);
    } on _SelectorError catch (e) {
      return _err(e.message);
    }
    final el = _findElementWhere(sel.test);
    if (el == null) return _err('no widget matching ${sel.label} found');
    final state = _editableTextUnder(el);
    if (state == null) {
      return _err(
        'no EditableText in the subtree of ${sel.label}; put the '
        'selector on a TextField/TextFormField, or on a widget containing '
        'one',
      );
    }
    field = state;
    target = sel.label;
    field.requestKeyboard();
    await _settle(params);
  } else {
    final focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (focused == null) {
      return _err(
        'no selector given and no text field is focused; pass one '
        'of key, tooltip, type, semanticsLabel to target a field, or tap '
        'it first',
      );
    }
    field = focused;
    target = 'focused';
  }

  field.userUpdateTextEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
    SelectionChangedCause.keyboard,
  );
  await _settle(params);
  return _ok({'enteredText': text, 'into': target});
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
  final texts = _textsUnder(el);
  if (texts.isEmpty) {
    return _err(
      'no text-bearing widget (Text, RichText, EditableText) in the '
      'subtree of ${sel.label}',
    );
  }
  // `text` is the first in pre-order — the reading order of the subtree —
  // and `texts` is always present, so a caller can see that a container held
  // more than one string (a ListTile's title and subtitle, say) instead of
  // silently getting whichever came first.
  return _ok({'text': texts.first, 'texts': texts});
}

Future<ServiceExtensionResponse> _handleGetRect(
  String method,
  Map<String, String> params,
) => _withRect(params, (rect) async => _rectAsMap(rect));

/// Wait for the app to go idle, and say whether it did.
///
/// The step every other command already takes, on its own — because the one
/// thing that needs it most cannot take it as a step. A native screenshot is
/// an OS capture: it returns whatever is on screen at that instant, so a
/// caller that acts and then captures gets the frame from before its action
/// painted, and a stale picture is indistinguishable from a real result. Two
/// wrong bug theories were built on exactly that.
///
/// Reports rather than assumes when there is nothing to wait for: a
/// backgrounded app has no frame coming (see [_settle]), and answering
/// `settled: true` there would be a claim about a frame that was never
/// scheduled. A wait that runs out throws, and [_guard] renders it with the
/// number of animations still in flight.
Future<ServiceExtensionResponse> _handleSettle(
  String method,
  Map<String, String> params,
) async {
  final timeout = Duration(
    milliseconds: int.tryParse(params['timeoutMs'] ?? '10000') ?? 10000,
  );
  if (!SchedulerBinding.instance.framesEnabled) {
    return _ok({
      'settled': false,
      'reason':
          'the app is backgrounded, so no frame is coming and there is '
          'nothing to wait for',
    });
  }
  await _waitUntilSettled(timeout);
  return _ok({'settled': true});
}

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
/// Resolve the selector to a rect and run [body] against it.
///
/// [dispatchesPointer] marks the handlers that send a real pointer event at
/// the rect's centre, and turns on the check that the point actually reaches
/// the widget — see [_pointerWouldMiss]. `getRect` reads a rect and dispatches
/// nothing, so it asks no such question.
Future<ServiceExtensionResponse> _withRect(
  Map<String, String> params,
  Future<Map<String, Object?>> Function(Rect rect) body, {
  bool dispatchesPointer = false,
}) async {
  final _Selector sel;
  try {
    sel = _selector(params);
  } on _SelectorError catch (e) {
    return _err(e.message);
  }
  final element = _findElementWhere(sel.test);
  final rect = _rectOf(element);
  if (rect == null) return _err('no widget matching ${sel.label} found');
  if (dispatchesPointer && _boolParam(params, 'requireHit', ifAbsent: true)) {
    final miss = _pointerWouldMiss(element!, rect.center, sel.label);
    if (miss != null) return _err(miss);
  }
  return _ok(await body(rect));
}

/// Why a pointer event at [point] would not reach [el], or null when it does.
///
/// The widget being *in the tree* is not the same as being reachable: a child
/// of a scroll view that is scrolled past is laid out at coordinates outside
/// the viewport, and one behind a dialog or an overlay is covered. Both used
/// to answer `{"tappedAt": …}` — a success, for a tap that hit nothing.
/// Measured on `hello_world`: a button clipped out of a horizontal
/// `SingleChildScrollView` reported a tap at x=985 in an 800-wide window, and
/// the counter it increments did not move.
///
/// The test is the framework's own — hit-test the point and look for the
/// target in the resulting path — matching `WidgetController._getElementPoint`,
/// whose `warnIfMissed` exists for exactly this and whose
/// `hitTestWarningShouldBeFatal` is the choice made here. A hit *below* the
/// target counts: a `ValueKey` goes on the widget you would point at, and what
/// actually receives the pointer is a listener several elements beneath it.
String? _pointerWouldMiss(Element el, Offset point, String label) {
  final box = el.renderObject;
  if (box is! RenderBox) return null;
  final view = View.of(el);
  final result = HitTestResult();
  GestureBinding.instance.hitTestInView(result, point, view.viewId);
  final reached = result.path.any(
    (entry) => _isAncestorOfTarget(box, entry.target),
  );
  if (reached) return null;

  // Two causes, and the remedy differs — telling someone to scroll a widget
  // that is already on screen and merely covered sends them nowhere.
  final size = view.physicalSize / view.devicePixelRatio;
  final outside = !(Offset.zero & size).contains(point);
  final because = outside
      ? 'that is outside the view, which is '
            '${size.width.toStringAsFixed(1)}x'
            '${size.height.toStringAsFixed(1)} — the widget is scrolled or '
            'laid out off-screen. Bring it into view first with '
            'app.scrollIntoView'
      : 'something else is on top of it there, or it does not accept pointer '
            'events. Dismiss or move whatever covers it';
  return '$label is at (${point.dx.toStringAsFixed(1)}, '
      '${point.dy.toStringAsFixed(1)}), where a pointer event does not reach '
      'it: $because. Nothing would have received this event — or pass '
      '"requireHit": "false" to dispatch at that point anyway.';
}

/// Whether a pointer event at [el]'s centre would now reach it.
///
/// What `scrollIntoView` is actually asked, and what `iterations` alone could
/// not answer: `0` means the target was already built and `ensureVisible` was
/// called on it, which is not the same as it having ended up anywhere a tap
/// can land — a reader took that zero for "there was nothing to do". This is
/// the same test `app.tap` applies before dispatching, so a `true` here is a
/// promise that the tap will not be refused.
bool _reachable(Element el) {
  final rect = _rectOf(el);
  if (rect == null) return false;
  return _pointerWouldMiss(el, rect.center, '') == null;
}

/// Whether [target] is [box] or something below it in the render tree.
///
/// The hand-rolled equivalent of flutter_test's
/// `isRenderObjectAncestorOfTarget`, which this file cannot import.
bool _isAncestorOfTarget(RenderObject box, HitTestTarget target) {
  if (identical(target, box)) return true;
  if (target is! RenderObject) return false;
  for (
    RenderObject? current = target.parent;
    current != null;
    current = current.parent
  ) {
    if (identical(current, box)) return true;
  }
  return false;
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
    (el) =>
        el.widget.key is ValueKey && (el.widget.key as ValueKey).value == value;

/// Selector params that are never anything but a selector.
///
/// `text` is deliberately absent: it is also `enterText`'s payload, which is
/// why that method opts out of it via [_selector]'s `textIsSelector`.
const _selectorNames = <String>['key', 'tooltip', 'type', 'semanticsLabel'];

/// Resolve the finder from exactly one of `key`, `text`, `tooltip`, `type`,
/// or `semanticsLabel`. Throws [_SelectorError] if none or more than one is
/// provided (no silent precedence).
///
/// [textIsSelector] is false for `enterText`, where `text` is the string to
/// type; the error messages then offer only the selectors that method has.
_Selector _selector(Map<String, String> params, {bool textIsSelector = true}) {
  final key = params['key'];
  final text = textIsSelector ? params['text'] : null;
  final tooltip = params['tooltip'];
  final type = params['type'];
  final semanticsLabel = params['semanticsLabel'];
  final names = textIsSelector
      ? 'key, text, tooltip, type, semanticsLabel'
      : _selectorNames.join(', ');

  final provided = <String>[
    if (key != null) 'key',
    if (text != null) 'text',
    if (tooltip != null) 'tooltip',
    if (type != null) 'type',
    if (semanticsLabel != null) 'semanticsLabel',
  ];
  if (provided.isEmpty) {
    throw _SelectorError('missing selector: provide one of $names');
  }
  if (provided.length > 1) {
    throw _SelectorError(
      'ambiguous selector: provide exactly one of '
      '$names (got ${provided.join(", ")})',
    );
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
    return _Selector(
      'tooltip "$tooltip"',
      (el) => el.widget is Tooltip && (el.widget as Tooltip).message == tooltip,
    );
  }
  if (type != null) {
    return _Selector(
      'type $type',
      (el) => el.widget.runtimeType.toString() == type,
    );
  }
  return _Selector(
    'semanticsLabel "$semanticsLabel"',
    (el) => el.renderObject?.debugSemantics?.label == semanticsLabel,
  );
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

/// Every string displayed under [el], in depth-first pre-order.
///
/// The whole subtree is searched, not one level of it: a selector names the
/// widget an app author hangs a `Key` on — a `Chip`, a `ListTile`, a button —
/// and the `Text` that widget displays sits several elements below the one
/// that carries the key. A shallower search made a key that `tap` and
/// `waitFor` accept fail for `getText` alone.
///
/// Descendants of a match are pruned, because Flutter builds text out of more
/// text: a `Text` builds a `RichText`, a `TextField` builds an `EditableText`
/// that builds another `RichText`. Without pruning one visible string would be
/// reported two or three times.
List<String> _textsUnder(Element el) {
  final out = <String>[];
  void visit(Element e) {
    final text = _displayedText(e.widget);
    if (text != null) {
      out.add(text);
      return;
    }
    e.visitChildren(visit);
  }

  visit(el);
  return out;
}

/// The string [w] puts on screen, or null if it is not a text-bearing widget.
String? _displayedText(Widget w) {
  // `Text.rich` leaves `data` null and carries its content as a span.
  if (w is Text) return w.data ?? w.textSpan?.toPlainText();
  if (w is EditableText) return w.controller.text;
  if (w is RichText) return w.text.toPlainText();
  return null;
}

/// The state of the first `EditableText` at or under [el].
///
/// A `TextField`'s key sits well above the `EditableText` it builds, so
/// resolving a selector to a field means descending.
EditableTextState? _editableTextUnder(Element el) {
  EditableTextState? found;
  void visit(Element e) {
    if (found != null) return;
    if (e is StatefulElement && e.state is EditableTextState) {
      found = e.state as EditableTextState;
      return;
    }
    e.visitChildren(visit);
  }

  visit(el);
  return found;
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

ServiceExtensionResponse _err(String message) => ServiceExtensionResponse.error(
  ServiceExtensionResponse.invalidParams,
  message,
);
