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

import 'flutter_error_report.dart';

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
/// to devFS failed).
///
/// [reason] is all there is, because a refusal is the tool's own account of a
/// delivery that did not happen — see [VerdictRefused]. An app's own error
/// report belongs to an app that took the code, which is an
/// [AppliedThenThrew].
class ApplyFailed extends ApplyOutcome {
  final String reason;
  const ApplyFailed(this.reason);
}

/// The VM took the code, and the app then reported a framework error on the
/// frame that followed.
///
/// A failure to whoever asked for the reload, and *not* a failure of the
/// reload: the app is running exactly what was just sent. That is why this is
/// not an [ApplyFailed] — anything recording what the app has (the compiler's
/// accepted baseline, the applied-versions record) must advance for it, where a
/// refusal must roll back. Telling the compiler to discard code the VM is
/// already running leaves its baseline describing a program no app has, and
/// the next delta is computed against that fiction.
///
/// [error] is required: the app's report is what distinguishes this case from
/// a clean apply, and it is kept whole for the same reason [ApplyFailed.error]
/// is.
class AppliedThenThrew extends ApplyOutcome {
  final FlutterErrorReport error;
  const AppliedThenThrew(this.error);

  /// One line naming the failure, from the report's own fields.
  String get reason =>
      error.description ??
      error.renderedText ??
      'the app reported an error after the code was applied';
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
      return switch (await inner.timeout(rpcTimeout)) {
        VerdictApplied() => const Applied(),
        VerdictAppErrored(:final error) => AppliedThenThrew(error),
        // The client's own reason, whatever the failing step was. Naming one
        // step here would be a guess about a refusal that may never have got as
        // far as the upload.
        VerdictRefused(:final reason) => ApplyFailed(reason),
      };
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
