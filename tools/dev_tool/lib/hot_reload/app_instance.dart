/// A running Flutter app on a single device — the I/O boundary for the
/// reload pipeline.
///
/// `AppInstance` is an abstract interface; production wires up
/// `VmServiceAppInstance` (this file) and tests inject a `FakeAppInstance`.
/// Either way, every `applyKernel` returns within `rpcTimeout` regardless
/// of what the VM is doing — so callers (and `CommandRunner.Pool(1)`)
/// never wait unboundedly. On timeout we force-close the connection: the
/// leaked RPC's future continues internally to the `VmServiceClient` but
/// is `.ignore()`d here.
import 'dart:async';

import '../vm_service_client.dart';

enum ApplyMode {
  hotReload,
  hotRestart,
}

/// Outcome of a single [AppInstance.applyKernel] call.
sealed class ApplyOutcome {
  const ApplyOutcome();
}

/// The kernel was uploaded and the VM accepted the reload/restart.
class Applied extends ApplyOutcome {
  const Applied();
}

/// The VM responded but the reload itself reported failure (or the upload
/// to devFS failed). [reason] is best-effort diagnostic text.
class ApplyFailed extends ApplyOutcome {
  final String reason;
  const ApplyFailed(this.reason);
}

/// The reload exceeded the per-call latency budget. The connection has
/// been force-closed; the next call will reconnect.
class ApplyTimedOut extends ApplyOutcome {
  const ApplyTimedOut();
}

/// A running app instance on one device. Implementations differ by
/// transport (`VmServiceAppInstance` for native VM service,
/// `WebAppInstance` for DDC, etc.).
abstract interface class AppInstance {
  String get id;
  Future<ApplyOutcome> applyKernel(
    String dillPath, {
    required ApplyMode mode,
  });
}

/// Production [AppInstance] backed by a Dart VM service connection.
class VmServiceAppInstance implements AppInstance {
  /// Stable identifier for this instance (typically the appId/device).
  @override
  final String id;

  /// Per-call latency budget. Every `applyKernel` returns within this
  /// duration even if the VM hangs. Default 30s.
  final Duration rpcTimeout;

  final VmServiceClient _client;

  VmServiceAppInstance({
    required this.id,
    required VmServiceClient client,
    this.rpcTimeout = const Duration(seconds: 30),
  }) : _client = client;

  @override
  Future<ApplyOutcome> applyKernel(
    String dillPath, {
    required ApplyMode mode,
  }) async {
    final inner = switch (mode) {
      ApplyMode.hotReload => _client.hotReload(dillPath),
      ApplyMode.hotRestart => _client.hotRestart(dillPath),
    };

    try {
      final ok = await inner.timeout(rpcTimeout);
      if (ok) return const Applied();
      return ApplyFailed(
          _client.lastReloadError ?? 'reloadSources reported failure');
    } on TimeoutException {
      // The leaked future will resolve when the WebSocket closes during
      // forceDisconnect (or when the VM eventually responds — we don't
      // care). Detach so we don't surface unhandled async errors.
      inner.ignore();
      await _client.forceDisconnect();
      return const ApplyTimedOut();
    } on StateError catch (e) {
      // VmServiceClient throws StateError when not connected. Surface as
      // ApplyFailed rather than letting it escape.
      return ApplyFailed(e.message);
    }
  }
}
