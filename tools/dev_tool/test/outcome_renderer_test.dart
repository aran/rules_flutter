import 'package:flutter_bazel_dev_tool/command_report.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/flutter_error_report.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/reload_orchestrator.dart';
import 'package:flutter_bazel_dev_tool/outcome_renderer.dart';
import 'package:flutter_bazel_dev_tool/reload_strategy.dart';
import 'package:test/test.dart';

/// One report, one rendering. The property under test throughout is that the
/// map says outright what a reader would otherwise infer. The terminal line is
/// composed from this map by `reportReloadCommand` (covered in
/// `reload_strategy_test.dart`), so it cannot disagree with what is asserted
/// here.
void main() {
  CommandReport reload({
    ReloadOutcome? outcome,
    AssetOutcome assets = AssetOutcome.none,
    String? unavailable,
  }) => CommandReport(
    verb: 'Hot reload',
    outcome: outcome,
    assets: assets,
    unavailable: unavailable,
  );

  group('every failure carries an error', () {
    test('a compile failure', () {
      final report = reload(outcome: const ReloadCompileFailed('boom'));
      expect(report.succeeded, isFalse);
      expect(toWire(report)['error'], 'boom');
    });

    test('a compile failure with no diagnostics still says so', () {
      // Nothing to quote is not nothing to report.
      final report = reload(outcome: const ReloadCompileFailed(''));
      expect(toWire(report)['error'], isNotNull);
    });

    test('an apply failure names every failing app, not just the first', () {
      final report = reload(
        outcome: const ReloadApplyFailed({
          'app-a': ApplyFailed('isolate is gone'),
          'app-b': ApplyTimedOut(),
        }),
      );
      final error = toWire(report)['error'] as String;
      expect(error, contains('app-a'));
      expect(
        error,
        contains('app-b'),
        reason: 'every failing app must be named, not just the first',
      );
    });

    test('an all-timeout failure carries an error', () {
      // No `ApplyFailed` here to take a reason from, so the error has to be
      // built from the timeout itself or the failure reads as a success.
      final report = reload(
        outcome: const ReloadApplyFailed({'app-a': ApplyTimedOut()}),
      );
      expect(report.succeeded, isFalse);
      expect(toWire(report)['error'], isNotNull);
      expect(toWire(report)['error'], contains('timed out'));
    });

    test('an asset rebuild failure', () {
      final report = reload(
        assets: const AssetOutcome(rebuildFailed: 'bazel build failed'),
      );
      expect(report.succeeded, isFalse);
      expect(toWire(report)['error'], 'bazel build failed');
    });

    // A codegen app regenerates its `*.g.dart` before anything is compiled, so
    // this failure is neither a refusal — the build was attempted — nor an
    // asset rebuild, whose 'Asset rebuild failed' would send the reader to
    // look at the wrong tree entirely.
    test('a generated source rebuild failure', () {
      final report = CommandReport(
        verb: 'Restart',
        sourceRebuildFailed: 'Generated source rebuild (bazel) failed.',
      );
      expect(report.succeeded, isFalse);
      final wire = toWire(report);
      expect(wire['error'], 'Generated source rebuild (bazel) failed.');
      expect(
        wire['message'],
        'Restart failed: Generated source rebuild (bazel) failed.',
      );
      expect(wire['message'], isNot(contains('Asset')));
    });

    test('an asset delivery failure', () {
      final report = reload(
        outcome: const ReloadNoChange(),
        assets: AssetOutcome(
          changed: const {'assets/a.png'},
          delivery: const StrategyRejected('the browser refused the eviction'),
        ),
      );
      expect(report.succeeded, isFalse);
      expect(toWire(report)['error'], contains('refused'));
      expect(toWire(report)['assetsProblem'], contains('refused'));
    });

    test('a device that never answered is named, and not as a refusal', () {
      // Emitting device lists only when something *refused* would leave a
      // failure where every device merely went quiet naming none of them.
      final report = CommandReport(
        verb: 'Hot reload',
        strategy: StrategyRejected.devices(
          refused: const [],
          applied: const ['live'],
          timedOut: const ['hung'],
        ),
      );
      final wire = toWire(report);
      expect(report.succeeded, isFalse);
      expect(wire['timedOut'], ['hung']);
      expect(wire['applied'], ['live']);
      expect(wire['refused'], isNull);
      expect(wire['error'], contains('did not answer'));
    });

    test('a pipeline that could not run', () {
      final report = reload(unavailable: 'Hot reload is still starting up.');
      expect(report.succeeded, isFalse);
      expect(toWire(report)['error'], contains('starting up'));
    });

    // Each strategy composes a careful explanation — "no browser client
    // connected", "the browser did not report a restarted isolate within 60s"
    // — and that explanation has to survive to the protocol boundary. The
    // asset clause finishes the sentence; it must not replace the verdict that
    // opens it. A headline read from `outcome` alone would miss it: `outcome`
    // is null on the web path, where the apply is reported through `strategy`,
    // and `message` is the one field an agent reads to decide whether its edit
    // went live.
    test('a refused apply keeps its reason in front of the asset clause', () {
      final report = CommandReport(
        verb: 'Restart',
        strategy: const StrategyRejected('the browser refused'),
        assets: const AssetOutcome(
          changed: {'assets/a.png'},
          delivery: StrategyApplied(1),
        ),
      );
      const expected =
          'Restart failed: the browser refused — 1 asset(s) reloaded';
      expect(toWire(report)['message'], expected);
    });

    for (final outcome in const <StrategyOutcome>[
      StrategyRejected('the browser refused the new sources'),
      StrategyUnsupported('no browser client connected'),
    ]) {
      test('a ${outcome.runtimeType} says why in its own words', () {
        final report = CommandReport(verb: 'Restart', strategy: outcome);
        expect(report.succeeded, isFalse);
        final wire = toWire(report);
        expect(wire['error'], outcome.message);
        expect(wire['message'], startsWith('Restart failed: '));
        expect(wire['message'], contains(outcome.message));
      });
    }
  });

  group('success', () {
    test('carries no error and lists what recompiled', () {
      final report = reload(
        outcome: const ReloadApplied(
          filesRecompiled: {'package:app/b.dart', 'package:app/a.dart'},
          isEmpty: false,
          apps: [],
        ),
      );
      expect(report.succeeded, isTrue);
      final wire = toWire(report);
      expect(wire.containsKey('error'), isFalse);
      expect(
        wire['filesRecompiled'],
        ['package:app/a.dart', 'package:app/b.dart'],
        reason: 'sorted, so a diff of two runs is readable',
      );
      expect(wire['isEmpty'], isFalse);
    });
  });

  group('assets', () {
    test('an asset-only edit does not say "no changes detected"', () {
      // Both halves are true and saying them together is a contradiction: the
      // Dart half found nothing, and the user did change something.
      final report = reload(
        outcome: const ReloadNoChange(),
        assets: AssetOutcome(
          changed: const {'assets/logo.png'},
          delivery: const StrategyApplied(1),
        ),
      );
      expect(report.succeeded, isTrue);
      expect(toWire(report)['message'], isNot(contains('no changes')));
      expect(toWire(report)['message'], contains('1 asset(s) reloaded'));
    });

    test('keeps which assets changed, not only how many', () {
      final report = reload(
        outcome: const ReloadNoChange(),
        assets: AssetOutcome(
          changed: const {'assets/b.png', 'assets/a.png'},
          delivery: const StrategyApplied(1),
        ),
      );
      final wire = toWire(report);
      expect(wire['assetsChanged'], 2);
      expect(
        wire['assetPaths'],
        ['assets/a.png', 'assets/b.png'],
        reason: 'which image is stale is the question, not how many',
      );
    });

    test('a failing reload keeps its reason beside the asset clause', () {
      final report = reload(
        outcome: const ReloadCompileFailed('lib/a.dart:3: undefined name'),
        assets: AssetOutcome(
          changed: const {'assets/logo.png'},
          delivery: const StrategyApplied(1),
        ),
      );

      expect(toWire(report)['error'], contains('undefined name'));
    });

    test('a rebuild that changed nothing says so', () {
      // Reported at all, and reported as its own thing: a source moved and the
      // build handed back the bundle the app already has. Legitimate on a
      // reverted edit, and also what a stale action cache looks like from
      // here — silence would leave a stale asset with two suspects.
      final report = reload(
        outcome: const ReloadNoChange(),
        assets: const AssetOutcome(rebuiltIdentical: true),
      );

      expect(
        report.succeeded,
        isTrue,
        reason: 'nothing failed; the build simply had nothing to publish',
      );
      final wire = toWire(report);
      expect(wire['assetsRebuiltIdentical'], isTrue);
      expect(wire['assetsChanged'], 0);
      expect(wire['message'], contains('identical'));
    });

    test('a run that never rebuilt says nothing about assets at all', () {
      // The contrast the signature above depends on. If this also carried a
      // field, "the build found nothing" and "no build ran" would be back to
      // being one answer.
      final report = reload(outcome: const ReloadNoChange());

      final wire = toWire(report);
      expect(wire['assetsRebuiltIdentical'], isNull);
      expect(wire.containsKey('assetsChanged'), isFalse);
    });
  });

  group('a refusal carries its reason', () {
    test('and nothing an app would have had to send', () {
      // A refusal is the tool's own account of a delivery that did not happen.
      // The fields beside it — the framework's rendering, its error count —
      // exist only in a report an app sent about code it took, and an app that
      // took the code is an `AppliedThenThrew`.
      final report = reload(
        outcome: const ReloadApplyFailed({
          'app-a': ApplyFailed(
            'the new kernel could not be uploaded to the app\'s '
            'devFS',
          ),
        }),
      );

      final app = (toWire(report)['perApp'] as Map)['app-a'] as Map;
      expect(app['status'], 'failed');
      expect(app['reason'], contains('devFS'));
      expect(app.containsKey('renderedText'), isFalse);
      expect(app.containsKey('errorsSinceReload'), isFalse);
      expect(
        toWire(report)['error'],
        contains('devFS'),
        reason: 'the reason a person needs is why it was refused',
      );
    });
  });

  group('an app that took the code and then threw', () {
    CommandReport threw() => reload(
      outcome: ReloadApplyFailed({
        'app-a': AppliedThenThrew(
          const FlutterErrorReport({
            'renderedErrorText': '══╡ EXCEPTION ╞══',
            'description': "type 'Null' is not a subtype of type 'String'",
            'errorsSinceReload': 1,
          }),
        ),
      }),
    );

    test('is a failure carrying the app\'s report', () {
      final report = threw();
      expect(report.succeeded, isFalse);
      expect(report.failedApps.keys, ['app-a']);

      final wire = toWire(report);
      expect(wire['error'], contains('app-a'));
      expect(
        wire['error'],
        contains('subtype'),
        reason: 'the reason a person needs is the app error itself',
      );

      final app = (wire['perApp'] as Map)['app-a'] as Map;
      expect(
        app['status'],
        'appliedThenThrew',
        reason:
            'its own status: the code is live on this device, which a '
            'client deciding what to do next has to know',
      );
      expect(app['description'], contains('subtype'));
      expect(app['renderedText'], contains('EXCEPTION'));
      expect(app['errorsSinceReload'], 1);
    });

    test('falls back to the rendered text when there is no description', () {
      // The framework does not always send `description`; losing the only text
      // there is would leave "Hot reload failed: app-a" and nothing else.
      final report = reload(
        outcome: ReloadApplyFailed({
          'app-a': AppliedThenThrew(
            const FlutterErrorReport({'renderedErrorText': 'RangeError'}),
          ),
        }),
      );
      expect(toWire(report)['error'], contains('RangeError'));
    });
  });

  group('a relaunch is reported as one', () {
    CommandReport relaunch({
      bool ready = true,
      AssetOutcome assets = AssetOutcome.none,
    }) => CommandReport(
      verb: 'Restart',
      assets: assets,
      relaunch: Relaunched(
        changedLibs: const ['libnative.dylib'],
        ready: ready,
        launches: const {'app-a': 2},
      ),
    );

    test('the app is running the new code, and the map says so', () {
      // A relaunch replaces the process from a bundle that was just rebuilt,
      // so `updated` is not a guess — it is the one thing a new process cannot
      // be wrong about.
      final report = relaunch();

      expect(report.succeeded, isTrue);
      expect(report.runningCode, RunningCode.updated);
      final wire = toWire(report);
      expect(wire['succeeded'], isTrue);
      expect(wire['runningCode'], 'updated');
      expect(wire['relaunched'], isTrue);
      expect(wire['nativeLibsChanged'], ['libnative.dylib']);
      expect(wire['ready'], isTrue);
      expect(wire['launch'], {'app-a': 2});
    });

    test('an app that has not drawn yet is still running the new code', () {
      // `ready` is a fact about whether an `app.*` command can land, not about
      // which code is loaded. A process that came back without a first frame
      // still came back running the rebuilt bundle, and reporting `unchanged`
      // here would tell a driver to expect its old code.
      final report = relaunch(ready: false);

      expect(
        report.runningCode,
        RunningCode.updated,
        reason: 'the process was replaced whether or not it has drawn',
      );
      expect(report.succeeded, isTrue);
      final wire = toWire(report);
      expect(wire['ready'], isFalse);
      expect(wire['succeeded'], isTrue);
    });

    test('the message names the libraries that forced it', () {
      final report = relaunch();

      expect(toWire(report)['message'], contains('libnative.dylib'));
    });

    test('the message warns that /logs cursors did not survive', () {
      // The one thing a driver cannot work out from the fields alone without
      // already knowing to look: its cursor is against a buffer that no longer
      // exists. `launch` is the machine-readable half; this is the other.
      final report = relaunch();

      expect(toWire(report)['message'], contains('re-tail'));
    });

    // The asset arms assign `message` outright rather than defaulting it, and
    // a headline built from `outcome` alone — which a relaunch report leaves
    // null — drops the fact that the process was replaced. Reachable on the
    // ordinary single-device restart: the asset refresh runs first and returns
    // a non-empty diff, and only then does the relaunch fire.
    test('a changed asset does not overwrite the relaunch sentence', () {
      final report = relaunch(
        assets: const AssetOutcome(
          changed: {'assets/a.png'},
          delivery: StrategyApplied(1),
        ),
      );

      final wire = toWire(report);
      expect(
        wire['message'],
        contains('libnative.dylib'),
        reason: 'the asset clause finishes the sentence, not replaces it',
      );
      expect(wire['message'], contains('asset'));
      expect(wire['assetsChanged'], 1);
    });

    test('a rebuild identical to the running bundle keeps it too', () {
      // The other asset arm, which assigns `message` the same way.
      final report = relaunch(
        assets: const AssetOutcome(rebuiltIdentical: true),
      );

      expect(toWire(report)['message'], contains('libnative.dylib'));
    });

    test('a report with no relaunch says nothing about one', () {
      // The contrast the keys above depend on. Emitted unconditionally, a
      // driver could not tell a relaunch from an ordinary restart.
      final wire = toWire(CommandReport(verb: 'Restart'));

      expect(wire.containsKey('relaunched'), isFalse);
      expect(wire.containsKey('nativeLibsChanged'), isFalse);
      expect(wire.containsKey('launch'), isFalse);
    });
  });

  group('the map agrees with the value it came from', () {
    final cases = <String, CommandReport>{
      // Subject to the same three properties as every other reply.
      'relaunch': CommandReport(
        verb: 'Restart',
        relaunch: const Relaunched(
          changedLibs: ['libnative.dylib'],
          ready: true,
          launches: {'app-a': 2},
        ),
      ),
      'relaunch beside a changed asset': CommandReport(
        verb: 'Restart',
        relaunch: const Relaunched(
          changedLibs: ['libnative.dylib'],
          ready: true,
          launches: {'app-a': 2},
        ),
        assets: const AssetOutcome(
          changed: {'assets/a.png'},
          delivery: StrategyApplied(1),
        ),
      ),
      'success': CommandReport(
        verb: 'Hot reload',
        outcome: const ReloadApplied(
          filesRecompiled: {'package:app/a.dart'},
          isEmpty: false,
          apps: [],
        ),
      ),
      'compile failure': CommandReport(
        verb: 'Hot reload',
        outcome: const ReloadCompileFailed('x'),
      ),
      'apply failure': CommandReport(
        verb: 'Hot reload',
        outcome: const ReloadApplyFailed({'a': ApplyTimedOut()}),
      ),
      'applied then threw': CommandReport(
        verb: 'Hot reload',
        outcome: const ReloadApplyFailed({
          'a': AppliedThenThrew(FlutterErrorReport({'description': 'boom'})),
        }),
      ),
      'unavailable': CommandReport(
        verb: 'Hot reload',
        unavailable: 'not ready',
      ),
      'asset rebuild failure': CommandReport(
        verb: 'Hot reload',
        assets: const AssetOutcome(rebuildFailed: 'build failed'),
      ),
      'generated source rebuild failure': CommandReport(
        verb: 'Hot reload',
        sourceRebuildFailed: 'codegen build failed',
      ),
      // Web reports its apply through `strategy`, where the orchestrator uses
      // `outcome` — so a report whose only failure is a strategy is the shape
      // every renderer that reads `outcome` alone gets wrong.
      'strategy failure': CommandReport(
        verb: 'Hot reload',
        strategy: const StrategyRejected('the browser refused'),
      ),
      'strategy failure beside a delivered asset': CommandReport(
        verb: 'Hot reload',
        strategy: const StrategyRejected('the browser refused'),
        assets: const AssetOutcome(
          changed: {'assets/a.png'},
          delivery: StrategyApplied(1),
        ),
      ),
      'asset rebuild that changed nothing': CommandReport(
        verb: 'Hot reload',
        outcome: const ReloadNoChange(),
        assets: const AssetOutcome(rebuiltIdentical: true),
      ),
    };

    cases.forEach((name, report) {
      test('$name is a failure in both or neither', () {
        final wireSaysFailed = toWire(report).containsKey('error');
        expect(
          wireSaysFailed,
          !report.succeeded,
          reason: 'the wire form must agree with the value it came from',
        );
      });

      // `succeeded` is on the wire so a client never has to infer the verdict
      // from the absence of a key. Two ways of saying the same thing can
      // drift, so the property asserted is that they cannot.
      test('$name says whether it succeeded, and agrees with `error`', () {
        final wire = toWire(report);
        expect(wire['succeeded'], report.succeeded);
        expect(wire['succeeded'], !wire.containsKey('error'));
      });

      // The sentence has to agree with the verdict too. `succeeded` being
      // right is no help to someone reading the one line a terminal prints, or
      // to an agent that logs `message` — and 'successful' is the word both of
      // them look for. One assertion covers both audiences: the terminal line
      // is this `message` plus a suffix, and `reportReloadCommand` returns on
      // `error` before reaching it, so a failure cannot be congratulated there
      // without being congratulated here first.
      test('$name claims success in words only if it succeeded', () {
        final message = toWire(report)['message'] as String?;
        expect(
          message?.contains('successful') ?? false,
          report.succeeded,
          reason: 'the wire `message` must not congratulate a failure',
        );
      });
    });
  });

  /// The one fact a client needs that no message could carry honestly: after a
  /// failure, is the app still running what it was running before?
  ///
  /// "The app keeps running the code it already had" is true only where the
  /// app ended up with the code it started with, so the wire says which of the
  /// three states it is and the sentence is gated on it.
  group('runningCode', () {
    String state(CommandReport report) =>
        toWire(report)['runningCode'] as String;

    group('unchanged — the app has the code it already had', () {
      test('a compile failure never produced a delta to send', () {
        expect(
          state(reload(outcome: const ReloadCompileFailed('boom'))),
          'unchanged',
        );
      });

      test('a command that could not run at all', () {
        expect(
          state(reload(unavailable: 'Hot reload is still starting up.')),
          'unchanged',
        );
      });

      test(
        'a generated source rebuild that broke never reached a compiler',
        () {
          // `refreshGenerated` runs before the asset refresh and before any
          // compile (`reload_pipeline.dart`), so nothing was sent.
          expect(
            state(
              CommandReport(
                verb: 'Hot reload',
                sourceRebuildFailed: 'codegen failed',
              ),
            ),
            'unchanged',
          );
        },
      );

      test('nothing changed, so nothing was sent', () {
        expect(state(reload(outcome: const ReloadNoChange())), 'unchanged');
      });

      test('an apply with an empty delta left the code where it was', () {
        expect(
          state(
            reload(
              outcome: const ReloadApplied(
                filesRecompiled: {},
                isEmpty: true,
                apps: [],
              ),
            ),
          ),
          'unchanged',
        );
      });

      test('a restart with an empty delta reran main() and still changed no '
          'code', () {
        // The case this value is most easily misread on, so it is pinned. A
        // restart's `work` set is the whole disk snapshot and its unit is
        // always working (`reload_orchestrator.dart`), so an unedited restart
        // compiles, applies, and `runInView` re-runs `main()`: the state is
        // wiped and the screen can visibly change. `unchanged` is still the
        // honest answer, because the program the app has is the one it had.
        // Anything reading this as "nothing happened" is reading it wrong.
        expect(
          state(
            CommandReport(
              verb: 'Restart',
              outcome: const ReloadApplied(
                filesRecompiled: {'package:app/main.dart'},
                isEmpty: true,
                apps: [],
              ),
            ),
          ),
          'unchanged',
        );
      });

      test('a strategy with nothing to apply to reached no app', () {
        // `StrategyUnsupported`'s own doc: "Nothing could take the edit, so
        // nothing changed ... no app was ever reached."
        expect(
          state(
            CommandReport(
              verb: 'Hot reload',
              strategy: const StrategyUnsupported('no VM service'),
            ),
          ),
          'unchanged',
        );
      });

      test('a refused apply reached no app either', () {
        // A refusal is a claim only the steps before any delivery can make, so
        // this can say the app kept what it had rather than shrugging.
        expect(
          state(
            reload(
              outcome: const ReloadApplyFailed({
                'app-a': ApplyFailed('the VM rejected the new kernel'),
              }),
            ),
          ),
          'unchanged',
        );
      });
    });

    group('updated — the VM took the code', () {
      test('a plain successful reload', () {
        expect(
          state(
            reload(
              outcome: const ReloadApplied(
                filesRecompiled: {'package:app/a.dart'},
                isEmpty: false,
                apps: [],
              ),
            ),
          ),
          'updated',
        );
      });

      test('an app that took the code and then threw is running it', () {
        // The whole reason `AppliedThenThrew` is not an `ApplyFailed`: the app
        // is running exactly what was just sent.
        expect(
          state(
            reload(
              outcome: ReloadApplyFailed({
                'app-a': AppliedThenThrew(
                  const FlutterErrorReport({'description': 'boom'}),
                ),
              }),
            ),
          ),
          'updated',
        );
      });

      test('an applied strategy', () {
        expect(
          state(
            CommandReport(
              verb: 'Hot reload',
              strategy: const StrategyApplied(1),
            ),
          ),
          'updated',
        );
      });
    });

    group('unknown — nobody said what the app ended up with', () {
      test('a device that never answered', () {
        expect(
          state(
            reload(
              outcome: const ReloadApplyFailed({'app-a': ApplyTimedOut()}),
            ),
          ),
          'unknown',
        );
      });

      test('a strategy that threw claims nothing about the app', () {
        expect(
          state(
            CommandReport(
              verb: 'Hot reload',
              strategy: StrategyThrew(StateError('x')),
            ),
          ),
          'unknown',
        );
      });

      test('a rejected strategy shares its type with catch-alls', () {
        // `StrategyRejected` covers both a browser genuinely declining the new
        // sources and `catch (e)` arms that fire mid-delivery. The type is what
        // reaches the wire, so it answers for its weakest member.
        expect(
          state(
            CommandReport(
              verb: 'Hot reload',
              strategy: const StrategyRejected('the browser refused'),
            ),
          ),
          'unknown',
        );
      });

      test('one unknown device makes the whole run unknown', () {
        expect(
          state(
            reload(
              outcome: const ReloadApplyFailed({
                'app-a': Applied(),
                'app-b': ApplyTimedOut(),
              }),
            ),
          ),
          'unknown',
        );
      });
    });
  });
}
