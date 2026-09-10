/// Which kind of web run this is, decided once, at plan time.
///
/// A web run comes in exactly three shapes, and everything about the run —
/// which server fronts the browser, whether there is a VM service, what an
/// edit turns into — follows from which one it is. Re-deriving that decision at
/// each site from the raw flags (`isWebDevice`, `--wasm`, `--profile`,
/// `--hot`) combines them slightly differently each time: one gate ignores
/// `--profile` where another refuses it, and `--wasm` on a native device is
/// silently dropped.
///
/// [resolveWebMode] is the one place the flags are read. Every other site
/// switches on the result, and the sealed hierarchy is what makes the compiler
/// point at any site that forgot a shape.
library;

import 'dev_tool_exception.dart';

/// One of the three shapes a web run can take. `null` stands for "not a web
/// run at all" — [resolveWebMode] returns `WebMode?`, and a `switch` over it
/// is exhaustive over all four states.
sealed class WebMode {
  const WebMode();
}

/// The DDC dev loop: the module server fronts the browser, DWDS provides the
/// VM service, and an edit becomes a state-preserving hot reload. The only
/// web shape with a VM service, and therefore the only one with DevTools,
/// agent control, and an app console sourced from the VM.
final class DdcWebMode extends WebMode {
  const DdcWebMode();
}

/// The WASM dev loop, which is not a dev loop: `dart2wasm` has no incremental
/// compiler and no VM service, so "hot restart" is a bazel rebuild plus a CDP
/// page reload, and hot reload does not exist at all. The bundle is served
/// statically; the app console arrives over CDP.
final class WasmWebMode extends WebMode {
  const WasmWebMode();
}

/// A built bundle served statically: no VM service, no reload of any kind.
/// What `--profile` and `--no-hot` resolve to on a browser. The app console
/// arrives over CDP; a screenshot is CDP's `Page.captureScreenshot`.
final class StaticWebMode extends WebMode {
  const StaticWebMode();
}

/// The one derivation of a run's [WebMode] from its flags. `null` for a
/// native run.
///
/// Refusals, not reinterpretations — a flag that cannot mean anything here is
/// an error, never silently dropped:
///
///  * `--wasm` without a web device.
///  * an explicit `--hot` with `--wasm`. `--hot` defaults to on, so only a
///    flag the user actually typed ([hotExplicit]) counts as asking; the
///    default quietly stepping aside for WASM is fine, the explicit request
///    being reinterpreted as "restart only" is not.
///
/// `--profile` outranks the `--hot` default, exactly as
/// `RunPlan.compilationModeFor` already ranks them for the build. With
/// `--wasm` the run is [WasmWebMode] whatever `--profile` says: rebuild plus
/// page reload works identically in any compilation mode, so profile only
/// changes what the rebuild builds.
WebMode? resolveWebMode({
  required bool isWebDevice,
  required bool wasmMode,
  required bool profileMode,
  required bool hotReloadEnabled,
  required bool hotExplicit,
}) {
  if (!isWebDevice) {
    if (wasmMode) {
      throw DevToolException(
        '--wasm only applies to a browser: it selects how a web run '
        'reloads, and this run is not on a web device. Drop --wasm, or run '
        'with -d chrome.',
      );
    }
    return null;
  }
  if (wasmMode) {
    if (hotExplicit && hotReloadEnabled) {
      throw DevToolException(
        '--hot cannot be honored with --wasm: dart2wasm has no incremental '
        'compiler, so a WASM run has no hot reload — only restart '
        '(a bazel rebuild plus a page reload). Drop --hot, or drop --wasm '
        'to get the DDC dev loop with hot reload.',
      );
    }
    return const WasmWebMode();
  }
  if (profileMode || !hotReloadEnabled) return const StaticWebMode();
  return const DdcWebMode();
}
