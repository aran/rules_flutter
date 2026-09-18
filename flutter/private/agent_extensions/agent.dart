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
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show SemanticsBinding, SemanticsHandle;
import 'package:flutter/services.dart';
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
  registerExtension('ext.rules_flutter.pressKey', _guard(_handlePressKey));

  // Deliberately NOT wrapped in `_guard`: this one answers from a compile-time
  // constant and touches no binding, so it must stay answerable pre-main —
  // `_guard` would call `SemanticsBinding.instance` and wait for a frame, which
  // an app paused at its entrypoint never produces. `flutter_bazel attach`
  // reads this before the app is settled, sometimes before it has run at all.
  registerExtension('ext.rules_flutter.buildInfo', _handleBuildInfo);

  // Not wrapped either, and for a reason of the same kind: the dev tool asks
  // this straight after a reload or a restart, the restart's before `runApp`
  // may even have run, and it is the one question whose answer must not wait
  // for a frame.
  registerExtension('ext.rules_flutter.renderState', _handleRenderState);
}

/// Whether this app is drawing frames: what the dev tool asks when a reload or
/// a restart has landed and the frame that would show it has not come.
///
/// A backgrounded app draws nothing — `framesEnabled` is false, see [_guard] —
/// and a restarted one inherits that, because the engine hands the new isolate
/// the lifecycle state it last sent. Without this the dev tool can only wait
/// out its bound and then call the reload a success it has not seen, which is
/// ten seconds of nothing followed by a tree still showing the frame before.
///
/// Answers only once the app's first frame has been built. Before that
/// `framesEnabled` is false for a reason that has nothing to do with being
/// seen — `WidgetsBinding` holds it false until `runApp` has attached the root
/// widget — and it is exactly the moment the dev tool asks after a restart.
/// Waiting is also what keeps a build error ahead of the answer: `runApp` and
/// `reassemble` both draw a warm-up frame whatever the lifecycle, and an error
/// in it is reported while it runs. After it, `framesEnabled` follows the
/// lifecycle alone. `timeoutMs` bounds the wait for an app whose `main` has not
/// reached `runApp`; that app gets `firstFrameBuilt: false` and no verdict.
Future<ServiceExtensionResponse> _handleRenderState(
  String method,
  Map<String, String> params,
) async {
  // Asked before `runApp` has made a binding, there is no lifecycle yet to
  // read. A debug-only query, like this file.
  if (BindingBase.debugBindingType() == null) return _ok({'started': false});
  final binding = WidgetsBinding.instance;
  if (!binding.debugDidSendFirstFrameEvent) {
    final built = Completer<void>();
    binding.addPostFrameCallback((_) {
      if (!built.isCompleted) built.complete();
    });
    await built.future.timeout(
      Duration(milliseconds: int.tryParse(params['timeoutMs'] ?? '') ?? 5000),
      onTimeout: () {},
    );
  }
  if (!binding.debugDidSendFirstFrameEvent) {
    return _ok({'firstFrameBuilt': false});
  }
  return _ok({
    'firstFrameBuilt': true,
    'rendering': binding.framesEnabled,
    'lifecycleState': binding.lifecycleState?.name,
  });
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
      // Once the app is running, what turns frames off is the app lifecycle.
      // `handleAppLifecycleStateChanged` is the only thing that ever sets
      // `framesEnabled` false (`scheduler/binding.dart:414`) — for `hidden`,
      // `paused` and `detached`, back true for `resumed` and `inactive`; the
      // only other writer is `resetInternalState`, which is
      // `@visibleForTesting` and only ever sets it true. (Before that,
      // `WidgetsBinding` also holds it false until `runApp` attaches the root
      // widget; see [_handleRenderState].) The state is routine wherever the
      // OS backgrounds apps — this file is staged into every *debug* kernel,
      // iOS and Android included (`AGENT_EXTENSIONS_ATTR` in `common.bzl`) —
      // and on macOS it follows the window: the embedder sends `hidden` when
      // `NSApplication.occlusionState` stops being visible (`FlutterEngine.mm`,
      // `handleDidChangeOcclusionState`). Measured on Darwin 27.0: an app that
      // had been in front and was then hidden, or fully covered by another
      // app's window, reports `framesEnabled` false within a second. The
      // embedder acts only on a *change*, though: a window that had never been
      // in front kept drawing, fully covered or hidden, which may be how an
      // earlier measurement (Darwin 25.5, minimized and hidden windows at ~8
      // frames/s) came to find the state unreachable on a desktop.
      // `_settleAfterInput` below guards on the same flag for the same reason.
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
      // Only a wait that is the command itself reaches here — `app.settle`.
      // A wait that follows delivered input is reported on that command's
      // reply instead ([_settleAfterInput]): the input landed, and an error
      // would read as input that never happened.
      return _err(
        '${_whyNotSettled(e)} An app that animates perpetually never '
        'settles: pass "settle": "false" to act without waiting, and '
        'app.waitFor to resynchronise afterwards.',
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

/// Settle after input that has already been delivered, and say how the wait
/// ended, so a follow-up getRect/getText observes the result. Bounded by the
/// caller's optional `timeoutMs` (default 10s).
///
/// Returns the reply fields the browser route of `app.pressKey` and the
/// screenshot endpoints' `X-Settled` headers already use: `settled` is `yes`,
/// `no` or `skipped`, and `settleDetail` says why when it is not `yes`.
///
/// A wait that runs out is `no`, never an error. It used to throw, and the
/// command answered with an error whose advice read as though nothing had
/// happened — on an app that animates constantly, `app.tap` tapped and then
/// reported failure, so a caller that retried tapped twice, and a retried
/// `app.pressKey` of Enter submitted twice. The input landed before the wait
/// began; what timed out is only the promise that its effect is visible.
///
/// When `framesEnabled` is false there is no frame to wait for: the flag
/// tracks the app *lifecycle* (`hidden`/`paused`/`detached`), not window
/// visibility — see the longer note in [_guard] — so the app is backgrounded,
/// and nothing will schedule a frame until it comes back. That is `skipped`,
/// and the reply's `notRendering` says the rest. What stops a hang is the
/// bound inside [_waitUntilSettled], not this check — frames can stop after
/// it.
///
/// `settle: "false"` skips the wait entirely — flutter_driver's
/// `runUnsynchronized`, under a name that says what it turns off. Some apps
/// never go idle: a spinner, a progress indicator, a hand-rolled caret, any
/// perpetual `AnimationController` holds a transient callback for as long as
/// it runs. Without it every command on such an app would wait out its whole
/// `timeoutMs`. The cost is the guarantee the wait exists for — a follow-up
/// `getText` may read the state from before the action — so `app.waitFor` is
/// how a caller resynchronises.
///
/// Parsed strictly, unlike the numeric parameters around it, which fall back
/// to their defaults. A number that fails to parse is a slower command; a
/// `settle` that fails to parse is the opposite behaviour, chosen silently.
Future<Map<String, Object?>> _settleAfterInput(
  Map<String, String> params,
) async {
  if (!_boolParam(params, 'settle', ifAbsent: true)) {
    return {
      'settled': 'skipped',
      'settleDetail': 'the caller asked not to wait',
    };
  }
  if (!SchedulerBinding.instance.framesEnabled) {
    return {
      'settled': 'skipped',
      'settleDetail':
          'the app is backgrounded, so no frame is coming and there is '
          'nothing to wait for',
    };
  }
  final timeout = Duration(
    milliseconds: int.tryParse(params['timeoutMs'] ?? '10000') ?? 10000,
  );
  try {
    await _waitUntilSettled(timeout);
    return {'settled': 'yes'};
  } on TimeoutException catch (e) {
    return {
      'settled': 'no',
      'settleDetail':
          '${_whyNotSettled(e)} The input was delivered and its handler ran, '
          'so sending this command again would do it twice. A read now may '
          'answer with the state from before it finished: resynchronise with '
          'app.waitFor on the value you expect, or pass "settle": "false" to '
          'skip this wait on an app that never goes idle.',
    };
  }
}

/// What a settle wait that ran out found, as the start of a sentence.
///
/// The count of transient callbacks separates the two ways a wait runs out:
/// zero means nothing was animating, so the app was backgrounded mid-command
/// and the frame being waited on never came; non-zero names the animations
/// that kept it from going idle. Read now rather than captured at the
/// deadline, because a callback that outlived the bound is still registered —
/// that is the whole condition.
String _whyNotSettled(TimeoutException e) {
  final animating = SchedulerBinding.instance.transientCallbackCount;
  return 'timed out after ${e.duration?.inMilliseconds}ms waiting for the app '
      'to settle: ${animating == 0 ? 'nothing was animating, so the app was '
                'backgrounded mid-command and the frame being waited on never '
                'arrived' : '$animating animation'
                '${animating == 1 ? ' was' : 's were'} still in flight, so it '
                'never went idle'}.';
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
  return {
    'tappedAt': {'x': rect.center.dx, 'y': rect.center.dy},
    ...await _settleAfterInput(params),
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
  return {
    'pressedAt': {'x': rect.center.dx, 'y': rect.center.dy},
    'heldMs': hold.inMilliseconds,
    ...await _settleAfterInput(params),
  };
});

Future<ServiceExtensionResponse> _handleDoubleTap(
  String method,
  Map<String, String> params,
) => _withRect(dispatchesPointer: true, params, (rect) async {
  await _dispatchDoubleTapAt(rect.center);
  return {
    'tappedAt': {'x': rect.center.dx, 'y': rect.center.dy},
    ...await _settleAfterInput(params),
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
    return {
      'from': {'x': start.dx, 'y': start.dy},
      'to': {'x': end.dx, 'y': end.dy},
      'durationMs': duration.inMilliseconds,
      ...await _settleAfterInput(params),
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

  // One command, many inputs. Once a wait for idle has run out, the rest are
  // skipped — an app that did not go idle within `timeoutMs` will not in the
  // next wait either, and 40 drags would each spend it — and the reply reports
  // the wait that ran out. The next frame is still awaited, bounded, because
  // that is what builds the children a drag scrolled into a lazy list.
  Map<String, Object?>? ranOut;
  Future<Map<String, Object?>> settle() async {
    final earlier = ranOut;
    if (earlier != null) {
      await SchedulerBinding.instance.endOfFrame.timeout(
        _semanticsFrameBound,
        onTimeout: () {},
      );
      return earlier;
    }
    final outcome = await _settleAfterInput(params);
    if (outcome['settled'] == 'no') ranOut = outcome;
    return outcome;
  }

  // Fast path: target is already in the element tree → use the framework
  // helper to scroll any ancestor Scrollable into the right offset.
  var element = _findElementWhere(sel.test);
  if (element != null) {
    await Scrollable.ensureVisible(element, duration: duration);
    final settled = await settle();
    final asleep = _notRendering();
    return _ok({
      'iterations': 0,
      'reachable': _reachable(element),
      ...settled,
      if (asleep != null) 'notRendering': asleep,
    });
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
    await settle();
    element = _findElementWhere(sel.test);
    if (element != null) {
      await Scrollable.ensureVisible(element, duration: duration);
      final settled = await settle();
      final asleep = _notRendering();
      return _ok({
        'iterations': i,
        'reachable': _reachable(element),
        ...settled,
        if (asleep != null) 'notRendering': asleep,
      });
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
  // The wait after focusing the field, when it ran out. Focusing is input
  // too: it already happened, so the text goes in regardless, and the second
  // wait is skipped because it would run out the same way.
  Map<String, Object?>? focusRanOut;
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
    final focused = await _settleAfterInput(params);
    if (focused['settled'] == 'no') focusRanOut = focused;
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
  final settled = focusRanOut ?? await _settleAfterInput(params);
  final asleep = _notRendering();
  return _ok({
    'enteredText': text,
    'into': target,
    ...settled,
    if (asleep != null) 'notRendering': asleep,
  });
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
  if (el == null) return _readErr('no widget matching ${sel.label} found');
  final texts = _textsUnder(el);
  if (texts.isEmpty) {
    return _readErr(
      'no text-bearing widget (Text, RichText, EditableText) in the '
      'subtree of ${sel.label}',
    );
  }
  // `text` is the first in pre-order — the reading order of the subtree —
  // and `texts` is always present, so a caller can see that a container held
  // more than one string (a ListTile's title and subtitle, say) instead of
  // silently getting whichever came first.
  return _readOk({'text': texts.first, 'texts': texts});
}

Future<ServiceExtensionResponse> _handleGetRect(
  String method,
  Map<String, String> params,
) => _withRect(params, (rect) async => _readBody(_rectAsMap(rect)));

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
/// backgrounded app has no frame coming (see [_settleAfterInput]), and answering
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
    if (rect != null) return _readOk(_rectAsMap(rect));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return _readErr('timed out waiting for ${sel.label}');
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
    if (_rectOf(_findElementWhere(sel.test)) == null) return _readOk({});
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return _readErr('timed out waiting for ${sel.label} to disappear');
}

Future<ServiceExtensionResponse> _handlePageBack(
  String method,
  Map<String, String> params,
) async {
  final nav = _findNavigator();
  if (nav == null) return _err('no Navigator found in widget tree');
  final popped = await nav.maybePop();
  final settled = await _settleAfterInput(params);
  final asleep = _notRendering();
  return _ok({
    'popped': popped,
    ...settled,
    if (asleep != null) 'notRendering': asleep,
  });
}

// ---------------------------------------------------------------------------
// Keys.
//
// `app.pressKey`'s framework route: what a native embedder does with a
// hardware key, reproduced from inside the app. Modeled on flutter_test's
// `KeyEventSimulator` (event_simulation.dart) and
// `MacOSTestTextInputKeyHandler` (test_text_input_key_handler.dart), which this
// file cannot import. It reaches everything the framework does with a key —
// shortcuts, focus traversal, text editing — and skips the OS and its input
// method, which is why the dev tool names the route in its reply. On the web
// the dev tool presses keys in the browser itself, over CDP, and never calls
// this.
//
// The dev tool parses the chord (Playwright's vocabulary) and sends each key
// by its DOM `code`; `kWebToPhysicalKey` turns that into Flutter's own key, so
// both routes read one table.
// ---------------------------------------------------------------------------

/// Press a key chord: `code` is the key's DOM `KeyboardEvent.code`,
/// `modifiers` the comma-separated codes held while it is pressed, `text` what
/// the key types (empty for a named key or a shortcut).
///
/// Each key goes through both halves of the path an embedder uses: a
/// `ui.KeyData` through `PlatformDispatcher.onKeyData`, then the legacy
/// `flutter/keyevent` message, whose reply says whether the framework handled
/// it. The framework holds the first until the second arrives, so neither
/// works alone. A key the framework left alone then goes where the platform's
/// input method would take it — see [_deliverToTextInput].
Future<ServiceExtensionResponse> _handlePressKey(
  String method,
  Map<String, String> params,
) async {
  if (kIsWeb) {
    return _err(
      'on the web, app.pressKey presses keys in the browser itself over the '
      'DevTools protocol, and never reaches this extension. Reaching it means '
      'something called ext.rules_flutter.pressKey directly.',
    );
  }
  final keymap = _rawKeymap();
  if (keymap == null) {
    return _err(
      'pressKey has no key simulation for $defaultTargetPlatform: it knows '
      'the key messages of macOS, iOS, Android, Linux and Windows.',
    );
  }
  final code = params['code'];
  if (code == null) {
    return _err(
      'missing required param: code (the DOM KeyboardEvent.code of the key '
      'to press). The dev tool fills this in from app.pressKey\'s "key".',
    );
  }
  final keys = <_FlutterKey>[];
  for (final c in [
    ...(params['modifiers'] ?? '').split(',').where((c) => c.isNotEmpty),
    code,
  ]) {
    final key = _keyForCode(c);
    if (key == null) {
      return _err('Flutter has no keyboard key for the DOM code "$c".');
    }
    keys.add(key);
  }
  final alreadyDown = [
    for (final k in keys)
      if (HardwareKeyboard.instance.physicalKeysPressed.contains(k.physical))
        k.name,
  ];
  if (alreadyDown.isNotEmpty) {
    // A second down for a key the framework thinks is held is an assertion
    // inside the key pipeline, and the key would be left in a state nothing
    // releases.
    return _err(
      '${alreadyDown.join(' and ')} ${alreadyDown.length == 1 ? 'is' : 'are'} '
      'already held down — by a real keyboard, or by a key press that did '
      'not finish — so pressing it again would be a second down without an '
      'up. Release it and try again.',
    );
  }
  final text = params['text'] ?? '';
  // Every key's message is built once before anything is sent, so a key this
  // platform has no code for is refused whole — throwing half way would leave
  // the framework holding the keys already pressed.
  for (final k in keys) {
    _rawKeyMessage(keymap, k, down: true, character: null, pressed: const {});
  }
  final mainKey = keys.removeLast();

  final presser = _KeyPresser(keymap);
  final bool handled;
  final Map<String, Object?> textInput;
  try {
    for (final k in keys) {
      await presser.press(k, down: true);
    }
    handled = await presser.press(
      mainKey,
      down: true,
      character: _types(text) ? text : null,
    );
    textInput = handled
        ? {
            'skipped':
                'the framework handled the key, so the platform input method '
                'never sees it',
          }
        : await _deliverToTextInput(mainKey, presser, text);
  } finally {
    // Released even when something above threw: a key left down is a key
    // the framework believes is held for the rest of the run.
    await presser.releaseAll();
  }
  final settled = await _settleAfterInput(params);
  final asleep = _notRendering();
  return _ok({
    'sent': presser.sent,
    'handled': handled,
    'textInput': textInput,
    ...settled,
    if (asleep != null) 'notRendering': asleep,
  });
}

/// Whether [text] is something a key types, as opposed to a control
/// character such as Enter's `"\r"`.
bool _types(String text) => text.isNotEmpty && text.codeUnitAt(0) >= 0x20;

/// The `keymap` the legacy key message names on this platform, or null where
/// there is none to imitate.
///
/// Read from [defaultTargetPlatform], so an app that overrides it for testing
/// gets the overridden platform's messages.
String? _rawKeymap() => switch (defaultTargetPlatform) {
  TargetPlatform.macOS => 'macos',
  TargetPlatform.iOS => 'ios',
  TargetPlatform.android => 'android',
  TargetPlatform.linux => 'linux',
  TargetPlatform.windows => 'windows',
  TargetPlatform.fuchsia => null,
};

/// One key as Flutter knows it.
class _FlutterKey {
  const _FlutterKey(this.physical, this.logical);
  final PhysicalKeyboardKey physical;
  final LogicalKeyboardKey logical;

  String get name =>
      physical.debugName ?? '0x${physical.usbHidUsage.toRadixString(16)}';
}

/// Flutter's logical keys by debug name.
///
/// flutter_test pairs a logical key with its physical one by debug name
/// (`_findPhysicalKey`); this is the same pairing read the other way. Debug
/// names exist only where asserts run, which is every build this file is
/// compiled into.
final Map<String, LogicalKeyboardKey> _logicalByName = {
  for (final k in LogicalKeyboardKey.knownLogicalKeys)
    if (k.debugName case final name?) name: k,
};

/// The logical key for a DOM `code` whose physical key's debug name names a
/// different logical key.
///
/// Flutter calls the US apostrophe key's physical key "Quote", and "Quote" is
/// also the name of the logical key for `"` — the apostrophe is "Quote Single".
/// Pairing by name pressed ⌘' as ⌘", which a shortcut bound to `quoteSingle`
/// never answers (reported by rainstorm, whose Block Quote is ⌘'). Checked
/// against the SDK's key tables for every key in the dev tool's US layout: this
/// is the only one the names pair wrongly.
const Map<String, LogicalKeyboardKey> _logicalForCode = {
  'Quote': LogicalKeyboardKey.quoteSingle,
};

/// The key a DOM `code` names, or null if Flutter has none.
_FlutterKey? _keyForCode(String code) {
  final physical = kWebToPhysicalKey[code];
  final logical = _logicalForCode[code] ?? _logicalByName[physical?.debugName];
  if (physical == null || logical == null) return null;
  return _FlutterKey(physical, logical);
}

/// Sends key events the way the platform's embedder would, and keeps track of
/// what is held so nothing is left down.
class _KeyPresser {
  _KeyPresser(this.keymap);

  final String keymap;
  final List<_FlutterKey> _down = [];

  /// What was dispatched, for the reply.
  final List<Map<String, Object?>> sent = [];

  bool _held(LogicalKeyboardKey left, LogicalKeyboardKey right) =>
      _down.any((k) => k.logical == left || k.logical == right);

  bool get shift =>
      _held(LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight);
  bool get control =>
      _held(LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight);
  bool get alt =>
      _held(LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight);
  bool get meta =>
      _held(LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight);

  /// Send [key] down or up, and answer whether the framework handled it.
  Future<bool> press(
    _FlutterKey key, {
    required bool down,
    String? character,
  }) async {
    if (down) {
      _down.add(key);
    } else {
      _down.remove(key);
    }
    final onKeyData = ui.PlatformDispatcher.instance.onKeyData;
    if (onKeyData == null) {
      throw StateError(
        'PlatformDispatcher.onKeyData is not set, so the framework has no key '
        'pipeline to deliver to.',
      );
    }
    final dataHandled = onKeyData(
      ui.KeyData(
        timeStamp: _now(),
        type: down ? ui.KeyEventType.down : ui.KeyEventType.up,
        physical: key.physical.usbHidUsage,
        logical: key.logical.keyId,
        character: down ? character : null,
        synthesized: false,
      ),
    );
    final message = _rawKeyMessage(
      keymap,
      key,
      down: down,
      character: character ?? _keyLabel(key.logical),
      pressed: {for (final k in _down) k.logical},
    );
    final reply = Completer<bool>();
    ui.channelBuffers.push(
      SystemChannels.keyEvent.name,
      SystemChannels.keyEvent.codec.encodeMessage(message),
      (data) {
        final decoded = data == null
            ? null
            : SystemChannels.keyEvent.codec.decodeMessage(data);
        reply.complete(decoded is Map && decoded['handled'] == true);
      },
    );
    final handled = await reply.future || dataHandled;
    sent.add({
      'type': down ? 'down' : 'up',
      'key': key.name,
      if (down && character != null) 'character': character,
      if (down) 'handled': handled,
    });
    return handled;
  }

  /// Release whatever is still down, last pressed first.
  Future<void> releaseAll() async {
    for (final k in _down.reversed.toList()) {
      await press(k, down: false);
    }
  }
}

/// flutter_test's `_keyLabel`: a one-character label, lowercased, or null.
String? _keyLabel(LogicalKeyboardKey key) {
  final label = key.keyLabel;
  return label.length == 1 ? label.toLowerCase() : null;
}

/// The legacy `flutter/keyevent` message for [key], in [keymap]'s shape —
/// flutter_test's `KeyEventSimulator.getKeyData`.
///
/// Every field is what that function puts there, including its choice of the
/// GLFW shape on Linux. The modifier flags are the framework's
/// `RawKeyEventData*` constants written out: those classes are deprecated,
/// and the values are what the embedders send regardless.
Map<String, Object?> _rawKeyMessage(
  String keymap,
  _FlutterKey key, {
  required bool down,
  required String? character,
  required Set<LogicalKeyboardKey> pressed,
}) {
  final chars = character ?? '';
  final physical = key.physical.usbHidUsage;
  int? reverse<T>(Map<int, T> map, bool Function(T) matches) {
    for (final entry in map.entries) {
      if (matches(entry.value)) return entry.key;
    }
    return null;
  }

  int require(int? code, String what) {
    if (code == null) {
      throw FormatException(
        'Flutter has no $keymap $what for ${key.name}, so the key message '
        'this platform sends for it cannot be built.',
      );
    }
    return code;
  }

  bool held(LogicalKeyboardKey k) => pressed.contains(k);
  final message = <String, Object?>{
    'type': down ? 'keydown' : 'keyup',
    'keymap': keymap,
  };
  switch (keymap) {
    case 'macos' || 'ios':
      message['keyCode'] = require(
        reverse(
          keymap == 'macos' ? kMacOsToPhysicalKey : kIosToPhysicalKey,
          (p) => p.usbHidUsage == physical,
        ),
        'key code',
      );
      if (chars.isNotEmpty || keymap == 'ios') {
        message['characters'] = chars;
        message['charactersIgnoringModifiers'] = chars;
      }
      var flags = 0;
      if (held(LogicalKeyboardKey.shiftLeft)) flags |= 0x02 | 0x20000;
      if (held(LogicalKeyboardKey.shiftRight)) flags |= 0x04 | 0x20000;
      if (held(LogicalKeyboardKey.metaLeft)) flags |= 0x08 | 0x100000;
      if (held(LogicalKeyboardKey.metaRight)) flags |= 0x10 | 0x100000;
      if (held(LogicalKeyboardKey.controlLeft)) flags |= 0x01 | 0x40000;
      if (held(LogicalKeyboardKey.controlRight)) flags |= 0x2000 | 0x40000;
      if (held(LogicalKeyboardKey.altLeft)) flags |= 0x20 | 0x80000;
      if (held(LogicalKeyboardKey.altRight)) flags |= 0x40 | 0x80000;
      if (pressed.any(_functionKeys.contains)) flags |= 0x800000;
      if (pressed.any(kMacOsNumPadMap.values.contains)) flags |= 0x200000;
      if (held(LogicalKeyboardKey.capsLock)) flags |= 0x10000;
      message['modifiers'] = flags;
    case 'android':
      message['keyCode'] = require(
        reverse(kAndroidToLogicalKey, (l) => l.keyId == key.logical.keyId),
        'key code',
      );
      message['scanCode'] = require(
        reverse(kAndroidToPhysicalKey, (p) => p.usbHidUsage == physical),
        'scan code',
      );
      if (chars.isNotEmpty) {
        message['codePoint'] = chars.codeUnitAt(0);
        message['character'] = chars;
      }
      var flags = 0;
      if (held(LogicalKeyboardKey.shiftLeft)) flags |= 0x40 | 0x01;
      if (held(LogicalKeyboardKey.shiftRight)) flags |= 0x80 | 0x01;
      if (held(LogicalKeyboardKey.metaLeft)) flags |= 0x20000 | 0x10000;
      if (held(LogicalKeyboardKey.metaRight)) flags |= 0x40000 | 0x10000;
      if (held(LogicalKeyboardKey.controlLeft)) flags |= 0x2000 | 0x1000;
      if (held(LogicalKeyboardKey.controlRight)) flags |= 0x4000 | 0x1000;
      if (held(LogicalKeyboardKey.altLeft)) flags |= 0x10 | 0x02;
      if (held(LogicalKeyboardKey.altRight)) flags |= 0x20 | 0x02;
      if (held(LogicalKeyboardKey.fn)) flags |= 0x08;
      if (held(LogicalKeyboardKey.scrollLock)) flags |= 0x400000;
      if (held(LogicalKeyboardKey.numLock)) flags |= 0x200000;
      if (held(LogicalKeyboardKey.capsLock)) flags |= 0x100000;
      message['metaState'] = flags;
    case 'linux':
      message['toolkit'] = 'glfw';
      message['keyCode'] = require(
        reverse(kGlfwToLogicalKey, (l) => l.keyId == key.logical.keyId),
        'key code',
      );
      message['scanCode'] = require(
        reverse(kLinuxToPhysicalKey, (p) => p.usbHidUsage == physical),
        'scan code',
      );
      var flags = 0;
      if (held(LogicalKeyboardKey.shiftLeft) ||
          held(LogicalKeyboardKey.shiftRight)) {
        flags |= 0x01;
      }
      if (held(LogicalKeyboardKey.controlLeft) ||
          held(LogicalKeyboardKey.controlRight)) {
        flags |= 0x02;
      }
      if (held(LogicalKeyboardKey.altLeft) ||
          held(LogicalKeyboardKey.altRight)) {
        flags |= 0x04;
      }
      if (held(LogicalKeyboardKey.metaLeft) ||
          held(LogicalKeyboardKey.metaRight)) {
        flags |= 0x08;
      }
      if (held(LogicalKeyboardKey.capsLock)) flags |= 0x10;
      message['modifiers'] = flags;
      message['unicodeScalarValues'] = chars.isEmpty ? 0 : chars.codeUnitAt(0);
    case 'windows':
      message['keyCode'] = require(
        reverse(kWindowsToLogicalKey, (l) => l.keyId == key.logical.keyId),
        'key code',
      );
      message['scanCode'] = require(
        reverse(kWindowsToPhysicalKey, (p) => p.usbHidUsage == physical),
        'scan code',
      );
      if (chars.isNotEmpty) message['characterCodePoint'] = chars.codeUnitAt(0);
      var flags = 0;
      if (held(LogicalKeyboardKey.shiftLeft)) flags |= 1 << 0 | 1 << 1;
      if (held(LogicalKeyboardKey.shiftRight)) flags |= 1 << 0 | 1 << 2;
      if (held(LogicalKeyboardKey.controlLeft)) flags |= 1 << 3 | 1 << 4;
      if (held(LogicalKeyboardKey.controlRight)) flags |= 1 << 3 | 1 << 5;
      if (held(LogicalKeyboardKey.altLeft)) flags |= 1 << 6 | 1 << 7;
      if (held(LogicalKeyboardKey.altRight)) flags |= 1 << 6 | 1 << 8;
      if (held(LogicalKeyboardKey.metaLeft)) flags |= 1 << 9;
      if (held(LogicalKeyboardKey.metaRight)) flags |= 1 << 10;
      if (held(LogicalKeyboardKey.capsLock)) flags |= 1 << 11;
      if (held(LogicalKeyboardKey.numLock)) flags |= 1 << 12;
      if (held(LogicalKeyboardKey.scrollLock)) flags |= 1 << 13;
      message['modifiers'] = flags;
  }
  return message;
}

/// The keys whose press sets the macOS and iOS "function" modifier, as
/// flutter_test's simulator sets it.
final Set<LogicalKeyboardKey> _functionKeys = {
  LogicalKeyboardKey.f1,
  LogicalKeyboardKey.f2,
  LogicalKeyboardKey.f3,
  LogicalKeyboardKey.f4,
  LogicalKeyboardKey.f5,
  LogicalKeyboardKey.f6,
  LogicalKeyboardKey.f7,
  LogicalKeyboardKey.f8,
  LogicalKeyboardKey.f9,
  LogicalKeyboardKey.f10,
  LogicalKeyboardKey.f11,
  LogicalKeyboardKey.f12,
  LogicalKeyboardKey.f13,
  LogicalKeyboardKey.f14,
  LogicalKeyboardKey.f15,
  LogicalKeyboardKey.f16,
  LogicalKeyboardKey.f17,
  LogicalKeyboardKey.f18,
  LogicalKeyboardKey.f19,
  LogicalKeyboardKey.f20,
  LogicalKeyboardKey.f21,
};

/// Hand a key the framework did not handle to where the platform's input
/// method would take it, and say what that was.
///
/// Only while a text field has focus: with none, no input method is attached
/// and the embedder drops the key after the framework declines it.
///
/// * **Return**, on every platform, is the field's own: a newline where the
///   field takes one (multiline with the newline action), then the field's
///   input action — `TextInputClient.performAction`, which is what fires
///   `onSubmitted`. That is what each engine does with it rather than
///   anything an input method decides; macOS's `insertNewline:` in
///   particular never reaches the framework as a selector.
/// * **Editing commands** on macOS: AppKit's standard key bindings turn a key
///   into Cocoa selectors (`moveDown:`, `deleteBackward:`), which the engine
///   forwards as `TextInputClient.performSelectors`. That is the only way
///   those keys edit on macOS — the framework deliberately leaves them
///   unhandled there so the input method can have them. iOS does the same for
///   Backspace and Delete, whose deletions its engine performs; the framework
///   maps the same selectors to the same deletions.
/// * **Text**, anywhere else: the character goes into the field at the
///   selection, as the engine's input model would put it there.
///
/// The text-input messages carry client id -1, which the framework accepts
/// from any caller in a debug build — the only build this file is in — so they
/// reach whichever field is attached, as the engine's own would.
Future<Map<String, Object?>> _deliverToTextInput(
  _FlutterKey key,
  _KeyPresser presser,
  String text,
) async {
  final field = FocusManager.instance.primaryFocus?.context
      ?.findAncestorStateOfType<EditableTextState>();
  if (field == null) {
    return {
      'skipped':
          'no text field has focus, so no input method is attached to take '
          'the key',
    };
  }
  if (field.widget.readOnly) {
    return {'skipped': 'the focused text field is read-only'};
  }
  final enter =
      key.logical == LogicalKeyboardKey.enter ||
      key.logical == LogicalKeyboardKey.numpadEnter;
  if (enter && !presser.control && !presser.alt && !presser.meta) {
    final config = field.textInputConfiguration;
    final newline =
        config.inputType == TextInputType.multiline &&
        config.inputAction == TextInputAction.newline;
    if (newline) _insertText(field, '\n');
    final action = config.inputAction.toString();
    await _sendTextInput('TextInputClient.performAction', [-1, action]);
    return {if (newline) 'inserted': '\n', 'action': action};
  }
  final selectors = _selectorsFor(key.logical, presser);
  if (selectors != null) {
    await _sendTextInput('TextInputClient.performSelectors', [-1, selectors]);
    return {'selectors': selectors};
  }
  if (_types(text)) {
    _insertText(field, text);
    return {'inserted': text};
  }
  return {
    'skipped':
        'the key types nothing, and $defaultTargetPlatform\'s input method '
        'has no editing command for it',
  };
}

/// Put [text] into [field] in place of its selection, the way a typed
/// character arrives.
///
/// Through the field's own `userUpdateTextEditingValue`, so its formatters,
/// `maxLength` and `onChanged` see it as they would a keystroke, and so the
/// field tells the engine the new value — an update that bypassed it would
/// leave the engine's model of the text behind, and the next real keystroke
/// would be applied to the old text.
///
/// The caret lands after what was typed. `TextEditingValue.replaced` alone
/// would carry a selection across the replacement and leave the typed text
/// selected — measured: Meta+A then `Q` showed a highlighted "Q".
void _insertText(EditableTextState field, String text) {
  final value = field.textEditingValue;
  final selection = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: value.text.length);
  field.userUpdateTextEditingValue(
    TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, text),
      selection: TextSelection.collapsed(
        offset: selection.start + text.length,
      ),
    ),
    SelectionChangedCause.keyboard,
  );
}

/// Deliver a `flutter/textinput` method call to the framework as the engine
/// does, and wait for its answer.
Future<void> _sendTextInput(String method, List<Object?> args) {
  final done = Completer<void>();
  ui.channelBuffers.push(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(MethodCall(method, args)),
    (_) => done.complete(),
  );
  return done.future;
}

/// The Cocoa selectors the platform's input method sends for [key] with what
/// [presser] holds, or null when it sends none.
List<String>? _selectorsFor(LogicalKeyboardKey key, _KeyPresser presser) {
  final platform = defaultTargetPlatform;
  if (platform != TargetPlatform.macOS && platform != TargetPlatform.iOS) {
    return null;
  }
  for (final (activator, selectors) in _macSelectors) {
    if (activator.trigger == key &&
        activator.shift == presser.shift &&
        activator.alt == presser.alt &&
        activator.meta == presser.meta &&
        activator.control == presser.control) {
      // iOS hands only its deletions to the input method; every other key in
      // this table is handled by the framework's own shortcuts there.
      if (platform == TargetPlatform.iOS &&
          key != LogicalKeyboardKey.backspace &&
          key != LogicalKeyboardKey.delete) {
        return null;
      }
      return selectors;
    }
  }
  return null;
}

/// flutter_test's `_macOSActivatorToSelectors`: the selectors
/// NSStandardKeyBindingResponding produces for each chord.
///
/// Copied as it is there, with two corrections: `deleteToEndOfParagraph:` and
/// `centerSelectionInVisibleArea:` carry the trailing colon every Cocoa action
/// selector has, which the flutter_test table leaves off.
final List<(SingleActivator, List<String>)> _macSelectors = [
  for (final shift in const [true, false]) ...[
    (
      SingleActivator(LogicalKeyboardKey.backspace, shift: shift),
      ['deleteBackward:'],
    ),
    (
      SingleActivator(LogicalKeyboardKey.backspace, alt: true, shift: shift),
      ['deleteWordBackward:'],
    ),
    (
      SingleActivator(LogicalKeyboardKey.backspace, meta: true, shift: shift),
      ['deleteToBeginningOfLine:'],
    ),
    (
      SingleActivator(
        LogicalKeyboardKey.backspace,
        control: true,
        shift: shift,
      ),
      ['deleteBackwardByDecomposingPreviousCharacter:'],
    ),
    (
      SingleActivator(LogicalKeyboardKey.delete, shift: shift),
      ['deleteForward:'],
    ),
    (
      SingleActivator(LogicalKeyboardKey.delete, alt: true, shift: shift),
      ['deleteWordForward:'],
    ),
    (
      SingleActivator(LogicalKeyboardKey.delete, meta: true, shift: shift),
      ['deleteToEndOfLine:'],
    ),
  ],
  (const SingleActivator(LogicalKeyboardKey.arrowLeft), ['moveLeft:']),
  (const SingleActivator(LogicalKeyboardKey.arrowRight), ['moveRight:']),
  (const SingleActivator(LogicalKeyboardKey.arrowUp), ['moveUp:']),
  (const SingleActivator(LogicalKeyboardKey.arrowDown), ['moveDown:']),
  (
    const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true),
    ['moveLeftAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true),
    ['moveRightAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true),
    ['moveUpAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true),
    ['moveDownAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true),
    ['moveWordLeft:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true),
    ['moveWordRight:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true),
    ['moveBackward:', 'moveToBeginningOfParagraph:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true),
    ['moveForward:', 'moveToEndOfParagraph:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true, shift: true),
    ['moveWordLeftAndModifySelection:'],
  ),
  (
    const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      alt: true,
      shift: true,
    ),
    ['moveWordRightAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true, shift: true),
    ['moveParagraphBackwardAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true, shift: true),
    ['moveParagraphForwardAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true),
    ['moveToLeftEndOfLine:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowRight, meta: true),
    ['moveToRightEndOfLine:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowUp, meta: true),
    ['moveToBeginningOfDocument:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowDown, meta: true),
    ['moveToEndOfDocument:'],
  ),
  (
    const SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      meta: true,
      shift: true,
    ),
    ['moveToLeftEndOfLineAndModifySelection:'],
  ),
  (
    const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      meta: true,
      shift: true,
    ),
    ['moveToRightEndOfLineAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.arrowUp, meta: true, shift: true),
    ['moveToBeginningOfDocumentAndModifySelection:'],
  ),
  (
    const SingleActivator(
      LogicalKeyboardKey.arrowDown,
      meta: true,
      shift: true,
    ),
    ['moveToEndOfDocumentAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true),
    ['moveToBeginningOfParagraphAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyA, control: true),
    ['moveToBeginningOfParagraph:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyB, control: true, shift: true),
    ['moveBackwardAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyB, control: true),
    ['moveBackward:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyE, control: true, shift: true),
    ['moveToEndOfParagraphAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyE, control: true),
    ['moveToEndOfParagraph:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true),
    ['moveForwardAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyF, control: true),
    ['moveForward:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyK, control: true),
    ['deleteToEndOfParagraph:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyL, control: true),
    ['centerSelectionInVisibleArea:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyN, control: true),
    ['moveDown:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true),
    ['moveDownAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyO, control: true),
    ['insertNewlineIgnoringFieldEditor:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyP, control: true),
    ['moveUp:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true),
    ['moveUpAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyT, control: true),
    ['transpose:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyV, control: true),
    ['pageDown:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true),
    ['pageDownAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.keyY, control: true),
    ['yank:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.quoteSingle, control: true),
    ['insertSingleQuoteIgnoringSubstitution:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.quote, control: true),
    ['insertDoubleQuoteIgnoringSubstitution:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.home),
    ['scrollToBeginningOfDocument:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.end),
    ['scrollToEndOfDocument:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.home, shift: true),
    ['moveToBeginningOfDocumentAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.end, shift: true),
    ['moveToEndOfDocumentAndModifySelection:'],
  ),
  (const SingleActivator(LogicalKeyboardKey.pageUp), ['scrollPageUp:']),
  (const SingleActivator(LogicalKeyboardKey.pageDown), ['scrollPageDown:']),
  (
    const SingleActivator(LogicalKeyboardKey.pageUp, shift: true),
    ['pageUpAndModifySelection:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.pageDown, shift: true),
    ['pageDownAndModifySelection:'],
  ),
  (const SingleActivator(LogicalKeyboardKey.escape), ['cancelOperation:']),
  (
    const SingleActivator(LogicalKeyboardKey.enter, alt: true),
    ['insertNewlineIgnoringFieldEditor:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.enter, control: true),
    ['insertLineBreak:'],
  ),
  (const SingleActivator(LogicalKeyboardKey.tab), ['insertTab:']),
  (
    const SingleActivator(LogicalKeyboardKey.tab, alt: true),
    ['insertTabIgnoringFieldEditor:'],
  ),
  (
    const SingleActivator(LogicalKeyboardKey.tab, shift: true),
    ['insertBacktab:'],
  ),
];

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
  if (rect == null) return _readErr('no widget matching ${sel.label} found');
  if (dispatchesPointer && _boolParam(params, 'requireHit', ifAbsent: true)) {
    final miss = _pointerWouldMiss(element!, rect.center, sel.label);
    if (miss != null) return _err(miss);
  }
  final answer = await body(rect);
  // Said on a successful command: the input landed, and what it changed is not
  // on screen or in any read until the app is resumed.
  if (dispatchesPointer) {
    final asleep = _notRendering();
    if (asleep != null) answer['notRendering'] = asleep;
  }
  return _ok(answer);
}

/// What an input command owes the caller when the app is not rendering, or
/// null when it is.
///
/// Frames stop when the OS backgrounds an app, which on a phone is the ordinary
/// state of a locked screen, and on macOS is a window hidden or covered after
/// it had been on screen (see [_guard]). The input still reaches the framework
/// and its handler still runs — the counter really does increment — but nothing
/// rebuilds and nothing paints, so a `getText` straight afterwards answers with
/// the tree as it was. Measured on a locked Pixel 9a: `app.tap` answered with
/// the point it tapped and the label it drives did not move; it moves when the
/// device is unlocked. After a restart the tree is the one `runApp`'s first
/// frame built, and nothing the app does after that — a `FutureBuilder`
/// resolving, a `setState` — reaches it.
///
/// Said rather than refused. The command did what it was asked, and refusing it
/// would break the one case where this is routine and harmless: a desktop
/// window minimized while a script drives it, which `agent_e2e_test`'s occluded
/// tap covers — the tap lands, and the restored window's next frame shows it.
/// Reads carry it too, because a stale tree answers them without complaint.
///
/// Silent before the first frame: until `runApp` attaches the root widget,
/// `WidgetsBinding` holds `framesEnabled` false for a reason that has nothing to
/// do with being seen (see [_handleRenderState]).
String? _notRendering() {
  final binding = WidgetsBinding.instance;
  if (binding.framesEnabled || !binding.debugDidSendFirstFrameEvent) {
    return null;
  }
  final state = binding.lifecycleState?.name ?? 'unknown';
  return 'the app is not rendering: its lifecycle state is "$state", which is '
      'how the OS says it cannot be seen — on macOS a window hidden or covered '
      'after it was on screen, on a device a locked screen or another app in '
      'front. Nothing rebuilds or repaints until it can be seen again, so the '
      'widget tree stays as the last frame left it: what a command did has '
      'happened, and a read shows the state from before it.';
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
    // The string the widget shows, read the way `getText` reads it. Comparing
    // `Text.data` alone never matched a `Text.rich`, whose `data` is null —
    // `getText` read one that `waitFor` and `tap` could not find (reported by
    // rainstorm). `flutter_test`'s `find.text` matches it the same way.
    return _Selector(
      'text "$text"',
      (el) => _displayedText(el.widget) == text,
    );
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

/// [body] with [_notRendering] added when the tree it was read from is not
/// being rebuilt.
Map<String, Object?> _readBody(Map<String, Object?> body) {
  final asleep = _notRendering();
  return {...body, if (asleep != null) 'notRendering': asleep};
}

ServiceExtensionResponse _readOk(Map<String, Object?> body) =>
    _ok(_readBody(body));

/// A read that found nothing, saying so when the tree it searched is frozen.
///
/// The case this exists for: a restart while the app is backgrounded leaves a
/// tree that `runApp`'s first frame built, so a widget the app shows once its
/// data loads is not in it, and "no widget matching" alone sends the reader
/// looking for a bug in the app.
ServiceExtensionResponse _readErr(String message) {
  final asleep = _notRendering();
  return _err(asleep == null ? message : '$message. Note: $asleep');
}
