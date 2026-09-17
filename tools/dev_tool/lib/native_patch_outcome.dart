/// What patching native code decided for one hot reload, before anyone puts it
/// into words.
///
/// Separate from `NativeLibsVerdict`, which answers whether the *bindings* an
/// increment carries can still be served. That question comes first and does
/// not change: a moved binding contract is withheld whether or not a patch
/// builder exists. This one answers what happened to the library's *code*.
library;

sealed class NativePatchOutcome {
  const NativePatchOutcome();
}

/// Nothing a patch builder watches moved, or the app bundles nothing a patch
/// builder serves. Nothing to say.
final class NativePatchNotNeeded extends NativePatchOutcome {
  const NativePatchNotNeeded();
}

/// The running app now runs the code on disk for [functions]' libraries — new
/// code patched in, or code a reverted edit had patched sent back to what it
/// launched with ([reverted]).
final class NativePatched extends NativePatchOutcome {
  /// Per library file name, what the patch replaced, in the builder's words.
  final Map<String, List<String>> functions;

  /// Libraries whose calls went back to their launched code.
  final List<String> reverted;

  const NativePatched({this.functions = const {}, this.reverted = const []});
}

/// A library's edit cannot be delivered into the running process. The reload is
/// withheld; a restart delivers it.
final class NativePatchNeedsRestart extends NativePatchOutcome {
  /// Per library file name, the builder's sentences saying why.
  final Map<String, List<String>> reasons;

  const NativePatchNeedsRestart(this.reasons);
}

/// No patch could be built: the build broke, or the builder did. The reload is
/// withheld, because the increment may depend on the native edit, and nothing
/// reached the app.
final class NativePatchBuildFailed extends NativePatchOutcome {
  final String message;

  const NativePatchBuildFailed(this.message);
}

/// A patch was built and did not load in every app. The reload is withheld.
///
/// Partial by nature: an app listed in [applied] runs the new code and one in
/// [failures] does not, which is why this names both.
final class NativePatchLoadFailed extends NativePatchOutcome {
  /// Per appId, why its patch did not load.
  final Map<String, String> failures;

  /// The appIds that did load it.
  final List<String> applied;

  const NativePatchLoadFailed({required this.failures, required this.applied});
}
