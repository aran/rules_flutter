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

  // Before everything below, and returning outright: the command stopped
  // here, so there is no outcome, no strategy and no asset diff to fold in —
  // and falling through would reach the `null` outcome arm and call a broken
  // build a success.
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
      map['message'] = '${report.verb} successful (no changes detected)';
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
