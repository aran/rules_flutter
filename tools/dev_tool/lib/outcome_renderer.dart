/// The one place a [CommandReport] becomes words.
///
/// [toWire] is that place. The terminal does not render the report a second
/// time: `reportReloadCommand` in `session.dart` composes its line from the
/// map [toWire] produced, so the sentence a person reads and the map a client
/// parses are the same rendering plus a suffix, and cannot disagree about
/// whether a reload worked.
library;

import 'command_report.dart';
import 'hot_reload/app_instance.dart';
import 'hot_reload/flutter_error_report.dart';
import 'hot_reload/reload_orchestrator.dart';
import 'reload_strategy.dart';

/// The protocol / HTTP shape.
///
/// `error` is present on **every** failure: callers decide success by asking
/// whether it is there, so an arm that omitted it would report a failure as a
/// success.
Map<String, dynamic> toWire(CommandReport report) {
  final map = <String, dynamic>{};

  if (report.unavailable case final reason?) {
    return {..._verdict(report), 'error': reason};
  }

  // Before the outcome switch and returning outright on a refusal: the command
  // stopped before the snapshot, so there is no outcome and no asset diff to
  // fold in — and falling through would reach the `null` outcome arm and call a
  // withheld increment a success.
  if (_refusedForNativeLibs(report.nativeLibs)) {
    return {
      ..._verdict(report),
      'error': _nativeLibsReason(report)!,
      'message': _nativeLibsSentence(report)!,
      'nativeLibsStale': _staleLibs(report.nativeLibs)!,
    };
  }

  // Returning outright, like the refusal above: the native half stopped the
  // command before anything was compiled.
  if (_nativePatchRefusal(report) case final refusal?) {
    return {
      ..._verdict(report),
      ...refusal,
      'message': '${report.verb} withheld: ${refusal['error']}',
    };
  }

  // Before everything below, and returning outright: the command stopped
  // here, so there is no outcome, no strategy and no asset diff to fold in —
  // and falling through would reach the `null` outcome arm and call a broken
  // build a success.
  // Also returning outright: the app is gone, and nothing below describes a
  // command that ended with no app to report on.
  if (report.relaunchFailed case final failed?) {
    final reasons = failed.failures.entries
        .map((e) => '${e.key}: ${e.value}')
        .join('; ');
    return {
      ..._verdict(report),
      'relaunched': false,
      'nativeLibsChanged': failed.changedLibs,
      'error': reasons,
      'message':
          '${report.verb} failed — the app was stopped to relaunch it on its '
          'changed native libraries (${failed.changedLibs.join(', ')}), and '
          'the relaunch failed: $reasons. The app is not running, so this run '
          'ends.',
    };
  }

  if (report.sourceRebuildFailed case final reason?) {
    return {
      ..._verdict(report),
      'error': reason,
      'message': '${report.verb} failed: $reason',
    };
  }

  // The web path reports through the strategy rather than the orchestrator.
  if (report.strategy case final strategy? when !strategy.isSuccess) {
    map['message'] = '${report.verb} failed: ${strategy.message}';
    map['error'] = strategy.message;
    // `timedOut` counts as a device list: guarding on `refused` alone would
    // leave an all-timeout failure naming no device at all, the same gap as the
    // all-timeout `error` below reached through the strategy instead of the
    // orchestrator.
    if (strategy is StrategyRejected &&
        (strategy.refused.isNotEmpty || strategy.timedOut.isNotEmpty)) {
      if (strategy.refused.isNotEmpty) map['refused'] = strategy.refused;
      if (strategy.timedOut.isNotEmpty) map['timedOut'] = strategy.timedOut;
      map['applied'] = strategy.applied;
    }
  }

  switch (report.outcome) {
    case null:
      // Through [_headline] rather than a literal, so the one arm that reaches
      // here with something to say — a relaunch, which runs no compiler and so
      // leaves `outcome` null — is not overwritten with a bare "successful".
      map['message'] ??= _headline(report);
    case ReloadApplied(:final filesRecompiled, :final isEmpty):
      map['message'] = '${report.verb} successful';
      map['filesRecompiled'] = filesRecompiled.toList()..sort();
      map['isEmpty'] = isEmpty;
    case ReloadNoChange():
      // A native patch is a change, whatever the Dart half found.
      map['message'] = report.nativePatch is NativePatched
          ? '${report.verb} successful'
          : '${report.verb} successful (no changes detected)';
    case ReloadCompileFailed(:final diagnostics):
      map['message'] = 'Compilation failed';
      map['error'] = diagnostics.isNotEmpty
          ? diagnostics
          : 'compilation failed';
    case ReloadApplyFailed(:final perApp):
      map['message'] = '${report.verb} failed on some devices';
      map['perApp'] = {
        for (final entry in perApp.entries)
          entry.key: _applyToWire(entry.value),
      };
      // Every failing app, not just the first, and a timeout counts.
      map['error'] = report.failedApps.entries
          .map((e) => '${e.key}: ${_applyReason(e.value)}')
          .join('; ');
  }

  final assets = report.assets;
  if (assets.rebuildFailed case final reason?) {
    map['error'] = reason;
    map['message'] = 'Asset rebuild failed';
  } else if (assets.changed.isNotEmpty) {
    map['assetsChanged'] = assets.changed.length;
    map['assetPaths'] = assets.changed.toList()..sort();
    if (assets.problem case final problem?) {
      map['assetsProblem'] = problem;
      map['error'] ??= problem;
    }
    map['message'] = _messageWithAssets(report);
  } else if (assets.rebuiltIdentical) {
    // Not an error: reverting an edit lands here honestly. But it is also the
    // shape a stale action cache makes, and saying it out loud is what lets
    // the two be told apart from a log.
    map['assetsChanged'] = 0;
    map['assetsRebuiltIdentical'] = true;
    map['message'] =
        '${_headline(report)} — the asset rebuild produced a '
        'bundle identical to the one the app already has';
  }

  // Delivered, and still something to say: the increment is live and the machine
  // code behind it is not. Named on a *successful* command, so `succeeded` is
  // what a driver reads to tell the two cases apart.
  if (report.nativeLibs case NativeCodeStale(:final libs)) {
    map['nativeLibsStale'] = libs;
    map['message'] =
        '${map['message'] ?? _headline(report)}. ${_staleCodeClause(libs)}';
  }

  // Delivered native code, said on the success sentence the way a stale library
  // is: which libraries, and what the patch replaced.
  if (report.nativePatch case NativePatched(
    :final functions,
    :final reverted,
  )) {
    if (functions.isNotEmpty) map['nativePatched'] = functions;
    if (reverted.isNotEmpty) map['nativeReverted'] = reverted;
    map['message'] =
        '${map['message'] ?? _headline(report)}. '
        '${_patchedClause(functions, reverted)}';
  }

  if (report.relaunch case final relaunched?) {
    map['relaunched'] = true;
    map['nativeLibsChanged'] = relaunched.changedLibs;
    // Whether the replacement rendered its first frame before this response —
    // i.e. whether it can take an `app.*` command now.
    map['ready'] = relaunched.ready;
    // Each launch buffers its own output from zero, so a cursor only means
    // anything within one launch. A driver compares this with the `launch` in
    // its last /logs page to know the cursor it holds is stale.
    map['launch'] = relaunched.launches;
    map['message'] = _withCursorCaveat(report, map['message'] as String);
  }

  if (report.elapsed case final elapsed?) {
    map['elapsedMs'] = elapsed.inMilliseconds;
  }
  return {..._verdict(report), ...map};
}

/// The two things a client should never have to work out for itself.
///
/// `succeeded` because deciding it from the absence of an `error` key is an
/// inference that can classify a failure as a success. The map says it
/// outright, from the same value `error` is written from, so the two cannot
/// drift.
///
/// `runningCode` because no message can carry it honestly: "the app keeps
/// running the code it already had" is true of only some failures.
Map<String, dynamic> _verdict(CommandReport report) => {
  'succeeded': report.succeeded,
  'runningCode': report.runningCode.name,
  // Omitted rather than empty when the command never resolved targets, for the
  // reason on [CommandReport.appIds]: "it reached no app" and "we never got far
  // enough to ask" are different answers.
  if (report.appIds case final ids?) 'appIds': ids,
};

/// The relaunch's own sentence, or null when no process was replaced.
///
/// Asked ahead of the `outcome` switch, for the same reason [_strategyFailure]
/// is: a relaunch runs no compiler, so its `outcome` is null, and the null
/// arm's "successful" would be all the reader got.
String? _relaunchSentence(CommandReport report) => switch (report.relaunch) {
  final r? =>
    '${report.verb} successful — the app was relaunched because '
        'its native libraries changed (${r.changedLibs.join(', ')})',
  _ => null,
};

/// The warning that a `/logs` cursor taken before a relaunch is against a
/// buffer that no longer exists.
///
/// Appended last rather than folded into [_relaunchSentence], because an asset
/// clause finishes that sentence and a caveat wedged between the two would
/// split the halves that belong together.
String _withCursorCaveat(CommandReport report, String sentence) =>
    report.relaunch == null
    ? sentence
    : '$sentence. The control channel keeps its port and token; '
          '/logs cursors do not survive — re-tail.';

/// The wire fields of a native patch that stopped the command, or null when it
/// did not.
///
/// Each says what the reader can do next. A restart reason is the patch
/// builder's own sentence about their edit; a build failure is their code or the
/// builder; a load failure names the apps, because one app running the new code
/// and another not is the state they have to know about.
Map<String, dynamic>? _nativePatchRefusal(
  CommandReport report,
) => switch (report.nativePatch) {
  NativePatchNeedsRestart(:final reasons) => {
    'error':
        '${reasons.keys.join(', ')} changed in a way that cannot be '
        'patched into the running app: '
        '${[for (final r in reasons.values) ...r].join(' ')} Nothing was '
        'compiled and nothing was sent. A restart (R) relaunches the app '
        'on the new code.',
    'nativePatchRestart': reasons,
  },
  NativePatchBuildFailed(:final message) => {
    'error':
        'the native patch could not be built, so nothing was compiled and '
        'nothing was sent.\n$message',
  },
  NativePatchLoadFailed(:final failures, :final applied) => {
    'error':
        'the native patch did not load in '
        '${failures.entries.map((e) => '${e.key} (${e.value})').join(', ')}'
        '${applied.isEmpty ? '' : ', and did in ${applied.join(', ')}, which now run the new native code'}'
        '. The Dart edit was not sent. A restart (R) relaunches the app on '
        'the new code.',
    'nativePatchFailed': failures,
    'nativePatchApplied': applied,
  },
  _ => null,
};

/// What a delivered native patch owes the reader: which code is new.
String _patchedClause(
  Map<String, List<String>> functions,
  List<String> reverted,
) => [
  for (final MapEntry(key: lib, value: replaced) in functions.entries)
    'Patched $lib in the running app'
        '${replaced.isEmpty ? '' : ' (${replaced.join(', ')})'}',
  if (reverted.isNotEmpty)
    '${reverted.join(', ')} back on the code the app launched with',
].join('; ');

/// Whether this verdict stopped the command before it compiled anything.
bool _refusedForNativeLibs(NativeLibsVerdict? verdict) =>
    verdict is NativeBindingsMoved || verdict is NativeLibsUnverifiable;

/// The libraries a verdict has something to say about, or null when it has not.
List<String>? _staleLibs(NativeLibsVerdict? verdict) => switch (verdict) {
  NativeCodeStale(:final libs) => libs,
  NativeBindingsMoved(:final libs) => libs,
  NativeLibsUnverifiable(:final libs) => libs,
  _ => null,
};

/// Why a command that found a rebuilt native library did nothing.
///
/// Says what moved, what that means, and what is left to try — in that order,
/// because the reader's first question is which of their native deps this is
/// about. "Nothing was compiled and nothing was sent" is the part that keeps
/// them from hunting for a half-applied edit: the app is self-consistent, on the
/// code and the library it launched with.
///
/// The two refusals differ in what the reader can do next, which is why they are
/// different sentences rather than one with a list. A moved contract is a fact
/// about their edit; a missing contract is a fact about their build, and saying
/// so is the only way anyone learns that declaring one buys a working reload.
String? _nativeLibsReason(CommandReport report) => switch (report.nativeLibs) {
  NativeBindingsMoved(:final libs, :final contracts) =>
    '${libs.join(', ')} changed, and so did what its bindings are generated '
        'from (${contracts.join(', ')}) — so the increment would be injected '
        'over a library that cannot serve it, and a process cannot replace a '
        'library it has already loaded. Nothing was compiled and nothing was '
        'sent: the app is still running the Dart code and the library it '
        'launched with. Only a new process picks both up, which a restart (R, '
        'or `app.restart`) relaunches when this run launched the app.',
  NativeLibsUnverifiable(:final libs) =>
    '${libs.join(', ')} changed, and nothing declares what its bindings are '
        'generated from — so whether the increment still matches it is not '
        'knowable here, and a process cannot replace a library it has already '
        'loaded. Nothing was compiled and nothing was sent: the app is still '
        'running the Dart code and the library it launched with. A restart (R, '
        'or `app.restart`) relaunches it; declaring the library through '
        '`flutter_native_library(binding_contract = …)` is what lets a reload '
        'through when only its code changed.',
  _ => null,
};

/// The one-line form, which leads with the verb so the terminal line reads as an
/// answer to the key that was pressed.
String? _nativeLibsSentence(CommandReport report) =>
    _nativeLibsReason(report) == null
    ? null
    : '${report.verb} withheld: ${_nativeLibsReason(report)}';

/// What a delivered increment still owes the reader: the code behind it is not
/// the code it was compiled against.
///
/// Its own clause appended to a success sentence rather than a verdict of its
/// own, because the command did work — the edit is live — and the one thing it
/// could not do is the thing no command but a relaunch can.
String _staleCodeClause(List<String> libs) =>
    '${libs.join(', ')} was rebuilt and its bindings did not change, so the '
    'increment is live over the library the app already loaded — the new '
    'native code is not running. A restart (R) relaunches the app on it.';

/// The failing web apply's own sentence, or null when the apply did not fail.
///
/// Its own helper because both [toWire] and [_headline] need it:
/// [CommandReport.outcome] alone is null on the DDC path, so reading that would
/// call a refused delivery a success.
String? _strategyFailure(CommandReport report) => switch (report.strategy) {
  final s? when !s.isSuccess => '${report.verb} failed: ${s.message}',
  _ => null,
};

/// Whether the Dart half found nothing to do. True for an asset-only edit,
/// which is exactly the case where "no changes detected" is both accurate and
/// misleading.
///
/// A failed strategy is never "nothing to do": something was attempted and it
/// did not work.
bool _dartSaidNothing(CommandReport report) {
  if (_strategyFailure(report) != null) return false;
  // Nor is a relaunch: the whole Dart program was replaced, which is the
  // largest thing this tool can do to an app. Answering true here would let an
  // asset clause reduce it to "Restart successful".
  if (report.relaunch != null) return false;
  return switch (report.outcome) {
    null || ReloadNoChange() => true,
    ReloadApplied(:final isEmpty) => isEmpty,
    _ => false,
  };
}

String _assetClause(CommandReport report) {
  final assets = report.assets;
  return assets.problem == null
      ? '${assets.changed.length} asset(s) reloaded'
      : '${assets.changed.length} asset(s) changed but ${assets.problem}';
}

/// The Dart half's verdict, as the opening of a sentence an asset clause
/// finishes.
///
/// "no changes detected" is a verdict on the Dart half. An asset-only edit is
/// exactly where it is true and misleading at once, so it is dropped here and
/// the clause replaces it, rather than contradicting it in the same sentence.
String _headline(CommandReport report) =>
    _strategyFailure(report) ??
    _relaunchSentence(report) ??
    (_dartSaidNothing(report)
        ? '${report.verb} successful'
        : switch (report.outcome) {
            ReloadCompileFailed() => 'Compilation failed',
            ReloadApplyFailed() => '${report.verb} failed on some devices',
            _ => '${report.verb} successful',
          });

String _messageWithAssets(CommandReport report) =>
    '${_headline(report)} — ${_assetClause(report)}';

Map<String, dynamic> _applyToWire(ApplyOutcome outcome) => switch (outcome) {
  Applied() => {'status': 'ok'},
  ApplyTimedOut() => {'status': 'timedOut'},
  // Its own status, not `failed`: the code is live on this device, which a
  // client deciding what to do next (re-send? relaunch?) needs to know.
  AppliedThenThrew(:final reason, :final error) => {
    'status': 'appliedThenThrew',
    'reason': reason,
    ..._errorToWire(error),
  },
  // Its reason and nothing else: a refusal is this tool's account of a
  // delivery that did not happen, so there is no app report to attach.
  ApplyFailed(:final reason) => {
    'status': 'failed',
    'reason': reason,
  },
};

/// The app's own report, field by field.
///
/// The framework's rendering stays available, but beside the fields it was
/// rendered from rather than instead of them.
Map<String, dynamic> _errorToWire(FlutterErrorReport error) => {
  if (error.description != null) 'description': error.description,
  if (error.renderedText != null) 'renderedText': error.renderedText,
  if (error.errorsSinceReload != null)
    'errorsSinceReload': error.errorsSinceReload,
};

String _applyReason(ApplyOutcome outcome) => switch (outcome) {
  Applied() => 'ok',
  ApplyTimedOut() => 'timed out',
  AppliedThenThrew(:final reason) => 'applied, then threw: $reason',
  ApplyFailed(:final reason) => reason,
};
