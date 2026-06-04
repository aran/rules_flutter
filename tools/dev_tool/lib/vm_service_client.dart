/// VM service client for hot reload.
///
/// Connects to a running Flutter app's VM service to push
/// incremental .dill deltas for hot reload/restart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Signature for connecting to a VM service (allows test injection).
typedef VmServiceConnector = Future<VmService> Function(String wsUri);

/// Client for the Dart VM service protocol.
///
/// Connects to a running Flutter app and provides hot reload/restart.
/// Uses the VM's in-memory devFS for uploading incremental dills,
/// which works for both local and remote (iOS device) VMs.
class VmServiceClient {
  final VmServiceConnector _connector;
  VmService? _service;
  String? _mainIsolateId;

  /// The HTTP address of the VM service (for devFS file uploads).
  Uri? _httpAddress;

  /// Name of the devFS created on the VM.
  static const _devFSName = 'flutter_bazel';

  /// Base URI of the devFS as returned by the VM.
  Uri? _devFSBaseUri;

  /// Absolute path to the app's `flutter_assets` directory, required by the
  /// engine's `_flutter.runInView` (hot restart re-runs main from a fresh
  /// isolate and re-specifies the asset bundle). Set by the run command from
  /// the build outputs before the first restart.
  String? assetDirectory;

  /// `renderedErrorText` of the post-reload `Flutter.Error` that failed the
  /// last reload/restart, if any. Cleared at the start of each one.
  String? _lastReloadError;

  /// The most recent post-reload Flutter framework error, if the last
  /// `hotReload` / `hotRestart` was reported as failed because of one.
  String? get lastReloadError => _lastReloadError;

  VmServiceClient({VmServiceConnector? connector})
      : _connector = connector ?? vmServiceConnectUri;

  /// Connect to the VM service at the given URI.
  Future<void> connect(Uri serviceUri) async {
    _httpAddress = serviceUri;

    // Convert http(s) URI to ws URI for VM service.
    final wsUri = serviceUri.replace(
      scheme: serviceUri.scheme == 'https' ? 'wss' : 'ws',
      path: '${serviceUri.path}ws',
    );

    _service = await _connector(wsUri.toString());

    // Find the main isolate.
    final vm = await _service!.getVM();
    for (final isolateRef in vm.isolates ?? <IsolateRef>[]) {
      if (isolateRef.name == 'main') {
        _mainIsolateId = isolateRef.id;
        break;
      }
    }
    _mainIsolateId ??= vm.isolates?.firstOrNull?.id;

    // Register the Extension stream so Flutter.Error / Flutter.Frame
    // events flow; the per-reload verdict listener is attached in
    // _applyAndVerify.
    await _ensureExtensionStream();

    // Create devFS for file uploads.
    await _createDevFS();
  }

  /// Ensure the VM is publishing the `Extension` stream (carries
  /// `Flutter.Error` and `Flutter.Frame`). Idempotent across reconnects.
  Future<void> _ensureExtensionStream() async {
    final svc = _service;
    if (svc == null) return;
    try {
      await svc.streamListen(EventStreams.kExtension);
    } on RPCError catch (e) {
      // 103 = kStreamAlreadySubscribed — fine on reconnect.
      if (e.code != 103) rethrow;
    }
  }

  /// Apply a kernel and verify the running app did not break.
  ///
  /// Determinism: a Flutter build failure is reported via
  /// `FlutterError.reportError` → a `Flutter.Error` extension event
  /// *during* `drawFrame`'s build phase, strictly before that same frame's
  /// `Flutter.Frame` timing event — and both travel on the single
  /// in-order VM-service `Extension` stream. So we subscribe *before*
  /// [apply] mutates the app, then, once the kernel is applied, await the
  /// first terminal event:
  ///   - `Flutter.Error` → the reload took but the app is now broken;
  ///   - the next `Flutter.Frame` → the rebuilt frame rendered cleanly.
  /// The verdict comes from awaiting the stream directly, so it never
  /// depends on cross-future microtask ordering (unlike the previous
  /// counter + `getVM()` barrier). The timeout is only a degenerate-case
  /// safety net (no frame and no error ever arrive), never the success
  /// path. Returns false (with [lastReloadError] set) when the reload was
  /// accepted but the app ended up in an error state.
  Future<bool> _applyAndVerify(Future<bool> Function() apply) {
    return _withReconnect(() async {
      _lastReloadError = null;
      var applied = false;
      String? capturedError;
      final settled = Completer<void>();
      void settle() {
        if (!settled.isCompleted) settled.complete();
      }

      // Subscribe before apply() so no event between reloadSources and the
      // rebuilt frame can be missed.
      final sub = _service!.onExtensionEvent.listen((e) {
        if (e.extensionKind == 'Flutter.Error') {
          capturedError ??= _flutterErrorText(e);
          if (applied) settle();
        } else if (e.extensionKind == 'Flutter.Frame' && applied) {
          settle();
        }
      });
      try {
        final accepted = await apply();
        if (!accepted) return false;
        applied = true;
        // An error may have been reported during reassemble, before
        // `applied` was set; honor it now.
        if (capturedError != null) settle();
        await settled.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () {},
        );
        if (capturedError != null) {
          _lastReloadError = capturedError;
          return false;
        }
        return true;
      } finally {
        await sub.cancel();
      }
    });
  }

  /// Best-effort human-readable text from a `Flutter.Error` event.
  String _flutterErrorText(Event e) {
    final data = e.extensionData?.data;
    final text = data?['renderedErrorText'] ?? data?['description'];
    if (text is String && text.trim().isNotEmpty) return text.trim();
    return 'Flutter error reported after reload';
  }

  /// Create an in-memory filesystem on the VM for uploading dills.
  Future<void> _createDevFS() async {
    if (_service == null) return;
    try {
      final response = await _service!.callServiceExtension(
        '_createDevFS',
        args: {'fsName': _devFSName},
      );
      final uri = response.json?['uri'] as String?;
      if (uri != null) _devFSBaseUri = Uri.parse(uri);
    } catch (e) {
      // 1001 = kFileSystemAlreadyExists — delete and recreate.
      if (e is RPCError && e.code == 1001) {
        try {
          await _service!.callServiceExtension(
            '_deleteDevFS',
            args: {'fsName': _devFSName},
          );
          final response = await _service!.callServiceExtension(
            '_createDevFS',
            args: {'fsName': _devFSName},
          );
          final uri = response.json?['uri'] as String?;
          if (uri != null) _devFSBaseUri = Uri.parse(uri);
        } catch (e2) {
          stderr.writeln('Warning: Could not create devFS: $e2');
        }
      } else {
        stderr.writeln('Warning: Could not create devFS: $e');
      }
    }
  }

  /// Upload a file to the VM's devFS via HTTP PUT.
  ///
  /// Returns the devFS URI that can be passed to reloadSources.
  Future<Uri?> _uploadToDevFS(String localPath, String devFSPath) async {
    if (_devFSBaseUri == null || _httpAddress == null) return null;

    final file = File(localPath);
    if (!file.existsSync()) return null;

    final client = HttpClient();
    try {
      final request = await client.putUrl(_httpAddress!);
      request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
      request.headers.add('dev_fs_name', _devFSName);
      request.headers.add(
        'dev_fs_uri_b64',
        base64.encode(utf8.encode(devFSPath)),
      );
      final bytes = await file.readAsBytes();
      request.add(gzip.encode(bytes));
      final response = await request.close().timeout(const Duration(seconds: 30));
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == HttpStatus.ok) {
        return _devFSBaseUri!.resolve(devFSPath);
      }
      stderr.writeln('DevFS upload failed: HTTP ${response.statusCode} $body');
      return null;
    } catch (e) {
      stderr.writeln('DevFS upload failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// Perform a hot reload by loading the given .dill file.
  ///
  /// Uploads the dill to the VM's devFS, then calls reloadSources
  /// with the devFS URI. This works for all platforms including
  /// physical iOS devices.
  Future<bool> hotReload(String dillPath) async {
    if (_httpAddress == null) {
      throw StateError('Not connected to VM service');
    }

    try {
      return await _applyAndVerify(() async {
        // Upload the dill to the VM's in-memory devFS.
        const entryPath = 'main.dart.incremental.dill';
        final devFSUri = await _uploadToDevFS(dillPath, entryPath);

        // Fall back to local file URI if devFS upload fails (works for local VMs).
        final rootLibUri =
            devFSUri?.toString() ?? Uri.file(dillPath).toString();
        final result = await _service!.reloadSources(
          _mainIsolateId!,
          rootLibUri: rootLibUri,
        );
        if (!result.success!) return false;

        // Trigger widget tree rebuild with the new code.
        await _service!.callServiceExtension(
          'ext.flutter.reassemble',
          isolateId: _mainIsolateId,
        );
        return true;
      });
    } catch (e) {
      stderr.writeln('Hot reload failed: $e');
      return false;
    }
  }

  /// Wait until the Flutter framework has rendered its first frame.
  Future<void> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (_service == null || _mainIsolateId == null) return;

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final resp = await _callService((s) => s.callServiceExtension(
              'ext.flutter.didSendFirstFrameRasterizedEvent',
              isolateId: _mainIsolateId,
            ));
        if (resp.json?['enabled'] == 'true') return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Capture a Flutter widget tree screenshot as raw PNG bytes.
  ///
  /// Uses the `_flutter.screenshot` VM service extension. Waits for the
  /// first frame to be rasterized before capturing.
  Future<List<int>> screenshotBytes() async {
    if (_service == null || _mainIsolateId == null) {
      throw StateError('Not connected to VM service');
    }

    await waitForFirstFrame();

    final response = await _callService((s) => s.callServiceExtension(
          '_flutter.screenshot',
          isolateId: _mainIsolateId,
        ));

    final data = response.json?['screenshot'] as String?;
    if (data == null) {
      throw StateError('_flutter.screenshot returned no data');
    }

    return base64.decode(data);
  }

  /// Capture a screenshot and save to [outputPath].
  Future<void> screenshot(String outputPath) async {
    final bytes = await screenshotBytes();
    await File(outputPath).writeAsBytes(bytes);
  }

  /// Perform a hot restart — re-run `main()` in a fresh isolate.
  ///
  /// Unlike [hotReload] (which swaps code into the running isolate via
  /// `reloadSources`, so `main()` does NOT re-execute), this uses the Flutter
  /// engine's `_flutter.runInView` to spawn a new root isolate that runs
  /// `main()` from the new kernel — matching `flutter run`'s capital-R restart.
  /// Framework + app state is reset and `main()`-level changes take effect.
  Future<bool> hotRestart(String dillPath) async {
    if (_httpAddress == null) {
      throw StateError('Not connected to VM service');
    }

    try {
      final ok = await _applyAndVerify(() async {
        // Upload the full kernel to devFS as the new main.
        const entryPath = 'main.dart.dill';
        final devFSUri = await _uploadToDevFS(dillPath, entryPath);
        final mainUri = devFSUri?.toString() ?? Uri.file(dillPath).toString();

        final views = await _listViews();
        if (views.isEmpty) return false;
        for (final view in views) {
          // The engine's runInView interacts with non-thread-safe dart APIs on
          // the UI thread, so a paused isolate would block it — resume first.
          final isolateId = view.isolateId;
          if (isolateId != null) await _resumeIfPaused(isolateId);
          await _service!.callMethod('_flutter.runInView', args: {
            'viewId': view.id,
            'mainScript': mainUri,
            'assetDirectory': assetDirectory ?? '',
          });
        }
        return true;
      });
      // runInView rotates the root isolate; re-resolve so subsequent
      // reloads/screenshots target the new live isolate.
      await _refreshMainIsolate();
      return ok;
    } catch (e) {
      stderr.writeln('Hot restart failed: $e');
      return false;
    }
  }

  /// The Flutter views (`_flutter.listViews`) with their UI isolate ids.
  Future<List<({String id, String? isolateId})>> _listViews() async {
    final resp = await _callService((s) => s.callMethod('_flutter.listViews'));
    final views = (resp.json?['views'] as List?) ?? const [];
    return [
      for (final v in views)
        if ((v as Map)['type'] == 'FlutterView')
          (id: v['id'] as String, isolateId: (v['isolate'] as Map?)?['id'] as String?),
    ];
  }

  /// Resume [isolateId] if it is paused (e.g. PauseStart), so runInView can run.
  Future<void> _resumeIfPaused(String isolateId) async {
    try {
      final isolate = await _service!.getIsolate(isolateId);
      final kind = isolate.pauseEvent?.kind;
      if (kind != null && kind.startsWith('Pause')) {
        await _service!.resume(isolateId);
      }
    } catch (_) {}
  }

  /// Re-resolve [_mainIsolateId] after a restart rotated the root isolate.
  Future<void> _refreshMainIsolate() async {
    try {
      final vm = await _callService((s) => s.getVM());
      final isolates = vm.isolates ?? const <IsolateRef>[];
      for (final ref in isolates) {
        if (ref.name == 'main') {
          _mainIsolateId = ref.id;
          return;
        }
      }
      _mainIsolateId = isolates.firstOrNull?.id ?? _mainIsolateId;
    } catch (_) {}
  }

  /// Call a service extension on the main isolate and return the parsed
  /// JSON response. Callers that don't need the payload simply discard it.
  Future<Map<String, dynamic>?> callServiceExtension(
    String method, {
    Map<String, String>? args,
  }) async {
    if (_service == null || _mainIsolateId == null) {
      throw StateError('Not connected to VM service');
    }
    final response = await _callService((s) => s.callServiceExtension(
          method,
          isolateId: _mainIsolateId,
          args: args,
        ));
    return response.json;
  }

  /// Toggle the performance overlay.
  Future<bool> togglePerformanceOverlay() async =>
      _toggleExtension('ext.flutter.showPerformanceOverlay');

  /// Toggle the widget inspector.
  Future<bool> toggleWidgetInspector() async =>
      _toggleExtension('ext.flutter.inspector.show');

  Future<bool> _toggleExtension(String method) async {
    if (_service == null || _mainIsolateId == null) {
      throw StateError('Not connected to VM service');
    }
    try {
      final current = await _callService((s) => s.callServiceExtension(
            method,
            isolateId: _mainIsolateId,
          ));
      final enabled = current.json?['enabled'] == 'true';
      await _callService((s) => s.callServiceExtension(
            method,
            isolateId: _mainIsolateId,
            args: {'enabled': (!enabled).toString()},
          ));
      return !enabled;
    } catch (e) {
      stderr.writeln('Failed to toggle $method: $e');
      return false;
    }
  }

  /// Run a VM-service operation, transparently reconnecting and replaying
  /// it once if the underlying connection has been disposed.
  ///
  /// `package:vm_service` auto-disposes its `VmService` when the underlying
  /// WebSocket closes (idle timeout, hot restart rotating the VM, DDS
  /// tunnel hiccup). The HTTP transport on the same URI typically stays
  /// alive, so re-running [connect] — which rebuilds `_mainIsolateId` and
  /// the devFS — recovers without consumer involvement.
  ///
  /// [operation] must be self-contained: on a disposed-connection error the
  /// *entire* closure is re-invoked against a freshly-built `VmService` and
  /// devFS. That atomic replay is what makes the multi-step `hotReload` /
  /// `hotRestart` sequences (devFS upload → `reloadSources` → reassemble)
  /// safe — the retry re-uploads to the fresh devFS rather than reloading
  /// against a half-built one. The reconnect is never mid-sequence.
  Future<T> _withReconnect<T>(Future<T> Function() operation) async {
    if (_httpAddress == null) {
      throw StateError('Not connected to VM service');
    }
    if (_service == null) {
      await connect(_httpAddress!);
    }
    try {
      return await operation();
    } on RPCError catch (e) {
      if (!_isConnectionDisposed(e)) rethrow;
      _service = null;
      await connect(_httpAddress!);
      return await operation();
    }
  }

  /// Run a single VM-service RPC with transparent reconnect (see
  /// [_withReconnect]). The degenerate single-step case.
  Future<T> _callService<T>(Future<T> Function(VmService) rpc) =>
      _withReconnect(() => rpc(_service!));

  /// Whether [e] indicates the WebSocket transport has been closed and
  /// `package:vm_service` has auto-disposed its [VmService]. Subsequent
  /// RPCs surface as `RPCError(-32000, "Service connection disposed")`.
  bool _isConnectionDisposed(RPCError e) =>
      e.code == -32000 && e.message.contains('Service connection disposed');

  /// Disconnect from the VM service.
  Future<void> disconnect() async {
    if (_devFSBaseUri != null && _service != null) {
      try {
        await _service!.callServiceExtension(
          '_deleteDevFS',
          args: {'fsName': _devFSName},
        );
      } catch (_) {}
    }
    await _service?.dispose();
    _service = null;
    _mainIsolateId = null;
    _devFSBaseUri = null;
  }

  /// Aggressively close the connection without trying to clean up devFS.
  ///
  /// Used when the connection is hung — calling `_deleteDevFS` over a
  /// wedged WebSocket would itself hang. Just dispose the underlying
  /// VmService (closes the WebSocket) and null out our state. The next
  /// call requiring a connection should reconnect via [connect].
  Future<void> forceDisconnect() async {
    try {
      await _service?.dispose();
    } catch (_) {}
    _service = null;
    _mainIsolateId = null;
    _devFSBaseUri = null;
  }

  /// Whether we are currently connected.
  bool get isConnected => _service != null;
}
