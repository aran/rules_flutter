/// Strategy for applying compilation results to running devices.
///
/// Abstracts the difference between VM service-based hot reload (native),
/// DWDS VM service-based reload (web DDC), and CDP page reload (web WASM).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart' as vm;

import 'frontend_server.dart';
import 'session.dart';
import 'web_module_server.dart';

/// How to apply compiled output to running devices.
abstract interface class ReloadStrategy {
  /// Apply incremental changes (hot reload).
  Future<bool> applyReload(CompileResult result, List<DeviceSession> sessions);

  /// Apply full restart.
  Future<bool> applyRestart(CompileResult result, List<DeviceSession> sessions);
}

/// Reload strategy for native platforms via Dart VM service.
///
/// Uploads the compiled dill to each device's devFS and triggers
/// `reloadSources` + `reassemble` (reload) or `hotRestart` (restart).
class VmServiceReloadStrategy implements ReloadStrategy {
  @override
  Future<bool> applyReload(
      CompileResult result, List<DeviceSession> sessions) async {
    final results = await Future.wait([
      for (final s in sessions)
        if (s.vmClient != null) s.vmClient!.hotReload(result.dillPath),
    ]);
    return results.every((ok) => ok);
  }

  @override
  Future<bool> applyRestart(
      CompileResult result, List<DeviceSession> sessions) async {
    final results = await Future.wait([
      for (final s in sessions)
        if (s.vmClient != null) s.vmClient!.hotRestart(result.dillPath),
    ]);
    return results.every((ok) => ok);
  }
}

/// Reload strategy for web DDC via DWDS VM service protocol.
///
/// Uses DWDS's VM service to trigger `$dartReloadModifiedModules` (reload)
/// or page restart via the DWDS-injected client.
///
/// Flow for hot reload:
///   1. Update module server with new DDC output
///   2. DWDS VM service `reloadSources` → `$dartReloadModifiedModules` in browser
///   3. `ext.flutter.reassemble` → widget rebuild with preserved state
///
/// Flow for hot restart:
///   1. Update module server with new DDC output
///   2. CDP Page.reload → page reloads with new modules
class DwdsReloadStrategy implements ReloadStrategy {
  final WebModuleServer moduleServer;

  /// CDP port for page reload (hot restart fallback).
  final int? cdpPort;

  /// App URL for finding the correct CDP tab.
  final String? appUrl;

  /// The DWDS VM service instance. Set after DWDS connection is established.
  vm.VmService? vmService;

  /// The main isolate ID from the DWDS VM service.
  String? _isolateId;

  DwdsReloadStrategy({
    required this.moduleServer,
    this.cdpPort,
    this.appUrl,
  });

  /// Discover the main isolate ID from the VM service.
  Future<String?> _getIsolateId() async {
    if (_isolateId != null) return _isolateId;
    if (vmService == null) return null;
    final vmInfo = await vmService!.getVM();
    if (vmInfo.isolates != null && vmInfo.isolates!.isNotEmpty) {
      _isolateId = vmInfo.isolates!.first.id;
    }
    return _isolateId;
  }

  @override
  Future<bool> applyReload(
      CompileResult result, List<DeviceSession> sessions) async {
    // Update modules — DDC writes incremental output to the same files.
    moduleServer.updateModules(result.dillPath);

    if (vmService == null) {
      stderr.writeln('Warning: DWDS VM service not connected — '
          'falling back to hot restart.');
      return applyRestart(result, sessions);
    }

    try {
      final isolateId = await _getIsolateId();
      if (isolateId == null) {
        stderr.writeln('Warning: No isolate found — cannot hot reload.');
        return false;
      }

      // Trigger DWDS hot reload: reloadSources → $dartReloadModifiedModules.
      final report = await vmService!.reloadSources(isolateId);
      if (report.success != true) {
        stderr.writeln('Warning: reloadSources reported failure.');
        return false;
      }

      // Trigger Flutter widget rebuild to pick up the new code.
      try {
        await vmService!.callServiceExtension(
          'ext.flutter.reassemble',
          isolateId: isolateId,
        );
      } catch (e) {
        // reassemble may not be available if Flutter framework isn't loaded yet.
        stderr.writeln('Warning: ext.flutter.reassemble failed: $e');
      }

      return true;
    } catch (e) {
      stderr.writeln('Warning: DWDS hot reload failed: $e');
      return false;
    }
  }

  @override
  Future<bool> applyRestart(
      CompileResult result, List<DeviceSession> sessions) async {
    moduleServer.updateModules(result.dillPath);

    // Hot restart uses CDP page reload — the page reloads and picks up
    // the new modules from the module server.
    if (cdpPort == null) {
      stderr.writeln('Warning: CDP port not available — cannot hot restart.');
      return false;
    }
    try {
      await _cdpPageReload(cdpPort!, appUrl: appUrl);
      return true;
    } catch (e) {
      stderr.writeln('Warning: CDP page reload failed: $e');
      return false;
    }
  }
}

/// Reload strategy for web DDC via recompile + CDP Page.reload.
///
/// Updates the [WebModuleServer] with new DDC output, then sends
/// `Page.reload` to Chrome via the Chrome DevTools Protocol.
class CdpReloadStrategy implements ReloadStrategy {
  final int cdpPort;
  final String? appUrl;

  /// Module server to update before page reload. Null for WASM mode.
  final WebModuleServer? moduleServer;

  CdpReloadStrategy({
    required this.cdpPort,
    this.appUrl,
    this.moduleServer,
  });

  @override
  Future<bool> applyReload(
      CompileResult result, List<DeviceSession> sessions) async {
    // CDP has no incremental reload — always do full page reload.
    return applyRestart(result, sessions);
  }

  @override
  Future<bool> applyRestart(
      CompileResult result, List<DeviceSession> sessions) async {
    // Update module server with recompiled DDC output before reload.
    moduleServer?.updateModules(result.dillPath);
    try {
      await _cdpPageReload(cdpPort, appUrl: appUrl);
      return true;
    } catch (e) {
      stderr.writeln('Warning: CDP Page.reload failed: $e');
      return false;
    }
  }
}

/// Reload strategy for WASM web via bazel rebuild + CDP Page.reload.
///
/// WASM has no frontend server and no DWDS — hot restart means:
///   1. Re-run `bazel build` to recompile the WASM binary
///   2. CDP `Page.reload` to pick up the new files
class WasmReloadStrategy implements ReloadStrategy {
  final int cdpPort;
  final String? appUrl;

  /// Callback to rebuild via bazel. Returns true on success.
  final Future<bool> Function() rebuild;

  WasmReloadStrategy({
    required this.cdpPort,
    required this.rebuild,
    this.appUrl,
  });

  @override
  Future<bool> applyReload(
      CompileResult result, List<DeviceSession> sessions) async {
    // WASM has no incremental reload — do full restart.
    return applyRestart(result, sessions);
  }

  @override
  Future<bool> applyRestart(
      CompileResult result, List<DeviceSession> sessions) async {
    try {
      final buildOk = await rebuild();
      if (!buildOk) {
        stderr.writeln('WASM rebuild failed.');
        return false;
      }
      await _cdpPageReload(cdpPort, appUrl: appUrl);
      return true;
    } catch (e) {
      stderr.writeln('Warning: WASM hot restart failed: $e');
      return false;
    }
  }
}

/// Send Page.reload via Chrome DevTools Protocol.
Future<void> _cdpPageReload(int cdpPort, {String? appUrl}) async {
  final client = HttpClient();
  try {
    // Get the list of targets (tabs).
    final listReq =
        await client.getUrl(Uri.parse('http://127.0.0.1:$cdpPort/json'));
    final listResp = await listReq.close();
    final listBody = await listResp.transform(utf8.decoder).join();
    final targets = json.decode(listBody) as List;
    if (targets.isEmpty) {
      throw StateError('No CDP targets found');
    }

    // Find the page target matching our app URL.
    final pageTargets =
        targets.where((t) => (t as Map)['type'] == 'page').toList();
    Map target;
    if (appUrl != null) {
      final appTarget = pageTargets.where((t) {
        final url = (t as Map)['url'] as String? ?? '';
        return url.startsWith(appUrl);
      });
      target = appTarget.isNotEmpty
          ? appTarget.first as Map
          : (pageTargets.isNotEmpty
              ? pageTargets.first as Map
              : targets.first as Map);
    } else {
      target = pageTargets.isNotEmpty
          ? pageTargets.first as Map
          : targets.first as Map;
    }

    final wsUrl = target['webSocketDebuggerUrl'] as String?;
    if (wsUrl == null) {
      throw StateError('No WebSocket URL in CDP target');
    }

    // Connect and send Page.reload.
    final ws = await WebSocket.connect(wsUrl);
    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      final msg = json.decode(data as String) as Map<String, dynamic>;
      if (msg['id'] == 1 && !responseCompleter.isCompleted) {
        responseCompleter.complete(msg);
      }
    });

    ws.add(json.encode({
      'id': 1,
      'method': 'Page.reload',
      'params': {'ignoreCache': true},
    }));

    await responseCompleter.future.timeout(const Duration(seconds: 10));
    await ws.close();
  } finally {
    client.close();
  }
}
