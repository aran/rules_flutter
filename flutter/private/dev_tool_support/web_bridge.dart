// The agent's extensions, served to the dev tool from a web bundle.
//
// A dart2wasm or dart2js bundle has no VM service: `registerExtension` files a
// handler in a map private to `dart:developer`, and nothing outside the page
// can call it. So a debug bundle's wrapper main hands the handlers to
// [installRulesFlutterAgentBridge], which publishes them on
// `globalThis.$rulesFlutterAgent`, where the dev tool calls them over the
// browser's DevTools protocol (`Runtime.evaluate`). The DDC dev loop does not
// use this: DWDS gives it a VM service.
//
// Alongside the agent's own `ext.rules_flutter.*`, it serves the widget
// inspector's `ext.flutter.inspector.*`, which `app.dumpWidgetTree` reads. Those
// are registered by the Flutter binding, not by this code, so they are caught
// on the way in: the inspector registers through
// `WidgetInspectorService.registerServiceExtension`, an overridable hook, and
// the service is replaced before `main()` by one that records what passes
// through it — the pattern Flutter's own inspector tests use.
//
// The contract the dev tool depends on (`browser_extension_channel.dart`):
//
//  * `call(method, paramsJson)` resolves to JSON text: `{"result": {...}}`,
//    `{"error": {"code": <int>, "detail": "..."}}` when the extension answered
//    with an error (what the VM service sends as an RPC error), or
//    `{"unregistered": true}`.
//  * `registered(method)` resolves to whether `method` is served: at once for
//    the agent's own, and for an inspector extension once the binding has
//    registered the inspector's.
//  * `bindingReady()` resolves once the binding has registered its service
//    extensions — when, on a VM service, `ext.flutter.reassemble` appears.
//  * `firstFrame()` resolves once the binding has sent its first frame.
//  * A `rulesflutteragentready` event is dispatched on `window` once
//    `$rulesFlutterAgent` exists, so a caller that arrives before the page has
//    run this far waits on an event rather than polling.
//
// Debug builds only, like the extensions it serves.

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Publish [agentHandlers] and the inspector's extensions to the dev tool.
///
/// Called by the wrapper main before `main()`, after
/// `registerRulesFlutterAgentExtensions`, and before anything creates a
/// binding: the inspector service has to be replaced before the binding asks
/// it to register.
void installRulesFlutterAgentBridge(
  Map<String, ServiceExtensionHandler> agentHandlers,
) {
  final inspector = _BridgedInspectorService()..install();

  Future<String> call(String method, Map<String, String> params) async {
    if (agentHandlers[method] case final handler?) {
      final ServiceExtensionResponse response;
      try {
        response = await handler(method, params);
      } catch (e, stack) {
        return _error(ServiceExtensionResponse.extensionError, '$e\n$stack');
      }
      final result = response.result;
      if (result != null) {
        return jsonEncode({'result': jsonDecode(result)});
      }
      return _error(response.errorCode!, response.errorDetail ?? '');
    }
    if (inspector.callbacks[method] case final callback?) {
      // As `BindingBase.registerServiceExtension` does for these on a VM
      // service: run on the outer event loop, never mid-frame.
      await Future<void>.delayed(Duration.zero);
      try {
        return jsonEncode({'result': await callback(params)});
      } catch (e, stack) {
        return _error(
          ServiceExtensionResponse.extensionError,
          jsonEncode({
            'exception': '$e',
            'stack': '$stack',
            'method': method,
          }),
        );
      }
    }
    return jsonEncode({'unregistered': true});
  }

  Future<bool> registered(String method) async {
    if (agentHandlers.containsKey(method)) return true;
    if (!method.startsWith('ext.flutter.inspector.')) return false;
    await inspector.registered.future;
    return inspector.callbacks.containsKey(method);
  }

  final bridge = JSObject()
    ..setProperty(
      'call'.toJS,
      ((JSString method, JSString paramsJson) {
        final params = (jsonDecode(paramsJson.toDart) as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, '$v'));
        return call(method.toDart, params).then((s) => s.toJS).toJS;
      }).toJS,
    )
    ..setProperty(
      'registered'.toJS,
      ((JSString method) => registered(
        method.toDart,
      ).then((r) => r.toJS).toJS).toJS,
    )
    ..setProperty(
      'bindingReady'.toJS,
      (() => inspector.registered.future.then((_) => null).toJS).toJS,
    )
    ..setProperty(
      'firstFrame'.toJS,
      (() => inspector.registered.future
              .then((_) => _firstFrameSent())
              .then((_) => null)
              .toJS)
          .toJS,
    );
  globalContext.setProperty(r'$rulesFlutterAgent'.toJS, bridge);
  _dispatchEvent(_Event('rulesflutteragentready'));
}

/// Completes once the binding has sent its first frame to the engine: what
/// `ext.flutter.didSendFirstFrameEvent` answers on a VM service.
///
/// Not `waitUntilFirstFrameRasterized`, which waits on frame timings the web
/// engine never reports.
Future<void> _firstFrameSent() async {
  final binding = WidgetsBinding.instance;
  while (!binding.debugDidSendFirstFrameEvent) {
    final frame = Completer<void>();
    binding.addPostFrameCallback((_) => frame.complete());
    await frame.future;
  }
}

String _error(int code, String detail) => jsonEncode({
  'error': {'code': code, 'detail': detail},
});

/// The default inspector, plus a record of the extensions it registers.
final class _BridgedInspectorService with WidgetInspectorService {
  /// Every `ext.flutter.inspector.*` extension, by its full method name.
  final callbacks = <String, ServiceExtensionCallback>{};

  /// Completed once the binding has had the inspector register its
  /// extensions, which it does last of all its own.
  final registered = Completer<void>();

  /// Make this the inspector the binding registers. In an instance member
  /// because the setter is `@protected`.
  void install() {
    WidgetInspectorService.instance = this;
  }

  @override
  void initServiceExtensions(
    RegisterServiceExtensionCallback registerExtension,
  ) {
    super.initServiceExtensions(registerExtension);
    if (!registered.isCompleted) registered.complete();
  }

  @override
  void registerServiceExtension({
    required String name,
    required ServiceExtensionCallback callback,
    required RegisterServiceExtensionCallback registerExtension,
  }) {
    callbacks['ext.flutter.inspector.$name'] = callback;
    super.registerServiceExtension(
      name: name,
      callback: callback,
      registerExtension: registerExtension,
    );
  }
}

@JS('Event')
extension type _Event._(JSObject _) implements JSObject {
  external factory _Event(String type);
}

@JS('dispatchEvent')
external bool _dispatchEvent(_Event event);
