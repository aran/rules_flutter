import 'dart:convert';
import 'dart:developer' show ServiceExtensionResponse;

import 'package:flutter_bazel_dev_tool/build_info.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:flutter_bazel_dev_tool/vm_service_client.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

/// The `flutter_assets` tree an app is actually running from, and the two ways
/// naming the wrong one is caught.
///
/// None of this is reachable from the e2e suite. `bazel cquery <label>` lists a
/// target in every configuration the Bazel server has analysed, and a `run`
/// session always analyses the wrapper first — so the harness only ever
/// produces the unambiguous, conveniently-ordered case.
void main() {
  BuildInfo info({
    String assetsDir =
        'bazel-out/ios_sim_arm64-dbg-ST-abc/bin/app_flutter_flutter_assets',
    String label = '@@//:app_flutter',
  }) => BuildInfo.fromJson({
    'label': label,
    'compilationMode': 'dbg',
    'platformBuildArgs': const ['--ios_multi_cpus=sim_arm64'],
    'dartDefines': const <String>[],
    'assetsDir': assetsDir,
    'targetPlatform': 'ios',
  });

  group('resolveAssetsDir', () {
    test('takes the app’s tree, not the first plausible candidate', () {
      // An Android wrapper reaches the application in three configurations at
      // once, so several entries end in `flutter_assets` and the app's is not
      // first. Position is not information here — only the app knows which
      // build it came from.
      final chosen = resolveAssetsDir(
        info: info(
          assetsDir:
              'bazel-out/darwin_arm64-dbg-android-ST-a6b/bin/app_flutter_flutter_assets',
        ),
        candidates: const [
          'bazel-out/darwin_arm64-dbg-android-ST-80d/bin/app_flutter_flutter_assets',
          'bazel-out/darwin_arm64-dbg-ST-ec0/bin/app_flutter_flutter_assets',
          'bazel-out/darwin_arm64-dbg-android-ST-a6b/bin/app_flutter_flutter_assets',
        ],
        queriedLabel: '//:app_flutter',
        target: '//:app',
        appliedArgs: const [],
      );
      expect(
        chosen,
        'bazel-out/darwin_arm64-dbg-android-ST-a6b/bin/app_flutter_flutter_assets',
        reason:
            'the third candidate is the one the app reported; picking by '
            'position is the bug this replaced',
      );
    });

    test('accepts the app’s tree when it is the only candidate', () {
      final chosen = resolveAssetsDir(
        info: info(),
        candidates: const [
          'bazel-out/ios_sim_arm64-dbg-ST-abc/bin/app_flutter_flutter_assets',
          'bazel-out/ios_sim_arm64-dbg-ST-abc/bin/app_flutter.native_assets.json',
        ],
        queriedLabel: '//:app_flutter',
        target: '//:app',
        appliedArgs: const [],
      );
      expect(
        chosen,
        'bazel-out/ios_sim_arm64-dbg-ST-abc/bin/app_flutter_flutter_assets',
      );
    });

    test(
      'refuses a tree the target cannot produce, naming the flags applied',
      () {
        // The unrecoverable case: a `--build-arg` the run used and attach was not
        // given changes the configuration, so the app's tree is nowhere in the
        // listing. Breaking loudly beats rebuilding into a directory the app
        // never reads.
        expect(
          () => resolveAssetsDir(
            info: info(),
            candidates: const [
              'bazel-out/darwin_arm64-dbg/bin/app_flutter_flutter_assets',
            ],
            queriedLabel: '//:app_flutter',
            target: '//:app',
            appliedArgs: const ['--ios_multi_cpus=sim_arm64'],
          ),
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('ios_sim_arm64-dbg-ST-abc'),
                contains('--ios_multi_cpus=sim_arm64'),
                contains('--build-arg'),
              ),
            ),
          ),
        );
      },
    );

    test('refuses a target that builds a different application', () {
      expect(
        () => resolveAssetsDir(
          info: info(label: '@@//:app_flutter'),
          candidates: const [
            'bazel-out/ios_sim_arm64-dbg-ST-abc/bin/app_flutter_flutter_assets',
          ],
          queriedLabel: '//:other_flutter',
          target: '//:other',
          appliedArgs: const [],
        ),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(contains('@@//:app_flutter'), contains('other_flutter')),
          ),
        ),
      );
    });

    test('compares labels in one form, so the apparent one is not a mismatch', () {
      // `str(ctx.label)` in Starlark yields `@@//:app_flutter`; `bazel cquery
      // --output=label` prints `//:app_flutter`. Comparing them raw would fail
      // on every app in the main repository, which is every app.
      expect(
        () => resolveAssetsDir(
          info: info(label: '@@//:app_flutter'),
          candidates: const [
            'bazel-out/ios_sim_arm64-dbg-ST-abc/bin/app_flutter_flutter_assets',
          ],
          queriedLabel: '//:app_flutter',
          target: '//:app',
          appliedArgs: const [],
        ),
        returnsNormally,
      );
    });

    test('tolerates a query that could not answer', () {
      // `bazelCqueryFlutterAppLabel` returns null on a failed query. That is
      // not evidence of a mismatch, and the membership check above has already
      // established the tree is reachable.
      expect(
        () => resolveAssetsDir(
          info: info(),
          candidates: const [
            'bazel-out/ios_sim_arm64-dbg-ST-abc/bin/app_flutter_flutter_assets',
          ],
          queriedLabel: null,
          target: '//:app',
          appliedArgs: const [],
        ),
        returnsNormally,
      );
    });
  });

  group('BuildInfo.fromJson', () {
    test('rejects a partial record rather than guessing the rest', () {
      expect(
        () => BuildInfo.fromJson(const {
          'label': '@@//:app_flutter',
          'compilationMode': 'dbg',
          'platformBuildArgs': <String>[],
          'dartDefines': <String>[],
          'targetPlatform': 'ios',
          // assetsDir missing — a rules/dev-tool version skew.
        }),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains('assetsDir'),
          ),
        ),
      );
    });

    test('requires the target platform, so skew fails by name', () {
      // The dev tool selects the plugin registrant its frontend_server
      // compiles by this value. Guessing the host's platform here is exactly
      // the wrong-plugin-set bug the field exists to prevent.
      expect(
        () => BuildInfo.fromJson(const {
          'label': '@@//:app_flutter',
          'compilationMode': 'dbg',
          'platformBuildArgs': <String>[],
          'dartDefines': <String>[],
          'assetsDir': 'bazel-out/x/bin/app_flutter_flutter_assets',
          // targetPlatform missing — a rules/dev-tool version skew.
        }),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains('targetPlatform'),
          ),
        ),
      );
    });

    test('carries the target platform through', () {
      final parsed = BuildInfo.fromJson(const {
        'label': '@@//:app_flutter',
        'compilationMode': 'dbg',
        'platformBuildArgs': ['--ios_multi_cpus=sim_arm64'],
        'dartDefines': <String>[],
        'assetsDir': 'bazel-out/x/bin/app_flutter_flutter_assets',
        'targetPlatform': 'ios',
      });
      expect(parsed.targetPlatform, 'ios');
    });

    test('re-injects the app’s own record, verbatim', () {
      // The resident frontend_server does not replay the launch build's
      // defines, so a hot restart's kernel carries only what the dev tool puts
      // on its compiler. Without this the restarted app answers
      // `ext.rules_flutter.buildInfo` with its "carries no record" error, and
      // every later read — the assets tree above, most of all — loses the one
      // source that can answer it.
      final record = {
        'label': '@@//:app_flutter',
        'compilationMode': 'dbg',
        'platformBuildArgs': ['--ios_multi_cpus=sim_arm64'],
        'dartDefines': ['E2E_FLAG=from,flag'],
        'assetsDir': 'bazel-out/x/bin/app_flutter_flutter_assets',
        'targetPlatform': 'ios',
      };
      final parsed = BuildInfo.fromJson(record);

      expect(parsed.defineAssignment, startsWith('rules_flutter.build_info='));
      // Round-trips through the same parser the app's own reply goes through:
      // what the restarted app will report is what it reported before.
      final replayed = BuildInfo.fromJson(
        jsonDecode(
              parsed.defineAssignment.substring(
                'rules_flutter.build_info='.length,
              ),
            )
            as Map<String, dynamic>,
      );
      expect(replayed.label, parsed.label);
      expect(replayed.assetsDir, parsed.assetsDir);
      expect(replayed.targetPlatform, parsed.targetPlatform);
      expect(replayed.dartDefines, parsed.dartDefines);
      expect(replayed.platformBuildArgs, parsed.platformBuildArgs);
    });

    test('re-injects fields this dev tool does not know about', () {
      // Newer rules may bake a field this binary has no getter for. Re-deriving
      // the define from the parsed fields would drop it silently; the record is
      // replayed as the app sent it, so the app keeps describing itself the
      // same way after a restart as before one.
      final parsed = BuildInfo.fromJson({
        'label': '@@//:app_flutter',
        'compilationMode': 'dbg',
        'platformBuildArgs': <String>[],
        'dartDefines': <String>[],
        'assetsDir': 'bazel-out/x/bin/app_flutter_flutter_assets',
        'targetPlatform': 'ios',
        'somethingNewerRulesBake': 'keep me',
      });

      expect(parsed.defineAssignment, contains('somethingNewerRulesBake'));
      expect(parsed.defineAssignment, contains('keep me'));
    });

    test('carries the dart defines through as bazel flags', () {
      final parsed = BuildInfo.fromJson(const {
        'label': '@@//:app_flutter',
        'compilationMode': 'dbg',
        'platformBuildArgs': ['--ios_multi_cpus=sim_arm64'],
        'dartDefines': ['E2E_FLAG=from,flag'],
        'assetsDir': 'bazel-out/x/bin/app_flutter_flutter_assets',
        'targetPlatform': 'ios',
      });
      expect(parsed.buildArgs(extra: const ['--//custom:flag']), [
        '--ios_multi_cpus=sim_arm64',
        '--@rules_flutter//flutter:extra_dart_defines=E2E_FLAG=from,flag',
        '--//custom:flag',
      ]);
    });
  });

  /// How the app's refusal actually travels.
  ///
  /// `_handleBuildInfo` answers an app with no baked record with `_err(...)`,
  /// i.e. `ServiceExtensionResponse.error(invalidParams, text)`. That crosses
  /// the VM service as a JSON-RPC error, so `package:vm_service` completes the
  /// call with a **throw** — it never returns a map carrying an `error` key.
  group('readBuildInfo', () {
    /// A client whose app answers `ext.rules_flutter.buildInfo` with [error],
    /// or with [payload] when it has a record.
    Future<VmServiceClient> clientThat({
      RPCError? error,
      Map<String, dynamic>? payload,
    }) async {
      final fake = FakeVmService(
        isolates: [IsolateRef(id: 'iso-1', name: 'main', number: '1')],
      );
      if (error != null) fake.extensionErrors[buildInfoExtension] = error;
      if (payload != null) {
        fake.extensionResponses[buildInfoExtension] = payload;
      }
      final client = VmServiceClient(connector: (_) async => fake);
      await client.connect(Uri.parse('http://127.0.0.1:8181/'));
      return client;
    }

    /// The exact shape `_err` produces: the generic code and message, with the
    /// handler's own text in `details`.
    RPCError appRefusal(String text) =>
        RPCError(buildInfoExtension, -32602, 'Invalid params', {
          'details': text,
        });

    test('the code recognised here is the one the agent answers with', () {
      // `_err` in `flutter/private/agent_extensions/agent.dart` builds every
      // refusal with `ServiceExtensionResponse.invalidParams`, and
      // `build_info.dart` names that number as a literal because
      // `package:vm_service` exposes the wire codes only as literals. Asserted
      // against the SDK rather than trusted: if the two ever part company, a
      // real refusal stops being recognised and escapes as a fault.
      expect(ServiceExtensionResponse.invalidParams, -32602);
    });

    test('surfaces the app’s own words when it reports no record', () async {
      const said =
          'this app carries no rules_flutter.build_info: it was not '
          'built in -c dbg by a rule that bundles assets';
      final client = await clientThat(error: appRefusal(said));

      await expectLater(
        readBuildInfo(client),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            contains(said),
          ),
        ),
      );
    });

    test('does not answer with the JSON-RPC code’s generic message', () async {
      // `e.message` is "Invalid params" for every refusal the agent makes —
      // true of the transport and useless about the app. The text is in
      // `details`, and reaching for the wrong one turns every app-side failure
      // into the same meaningless line.
      final client = await clientThat(
        error: appRefusal('the app’s actual complaint'),
      );

      await expectLater(
        readBuildInfo(client),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            isNot(contains('Invalid params')),
          ),
        ),
      );
    });

    test('lets a transport fault stay a transport fault', () async {
      // A disposed or broken connection also arrives as an RPCError. Reading
      // it as "this app carries no record" would misattribute a tool fault to
      // the app — the same defect, pointed the other way.
      final client = await clientThat(
        error: RPCError(buildInfoExtension, -32000, 'Service has disappeared'),
      );

      await expectLater(readBuildInfo(client), throwsA(isA<RPCError>()));
    });

    test(
      'does not read any error carrying details as the app refusing',
      () async {
        // `details` alone is not the agent's signature either: it is an untyped
        // slot in the error's `data`, and anything on the connection may fill
        // it. Only the pair — the agent's code AND handler text — is a refusal.
        // Without the code check, a connection fault carrying a `details` would
        // be reported as "this app has no build record".
        final client = await clientThat(
          error: RPCError(buildInfoExtension, -32000, 'Service disappeared', {
            'details': 'the DDS connection was closed',
          }),
        );

        await expectLater(readBuildInfo(client), throwsA(isA<RPCError>()));
      },
    );

    test('lets the VM’s own "invalid params" stay a fault', () async {
      // The code alone is not the agent's signature: the VM answers with it
      // too, for a request it could not route — a stale isolate id, say. Those
      // carry no handler text, and reading one as "this app has no record"
      // would blame the app for the tool's own mistake.
      final client = await clientThat(
        error: RPCError(buildInfoExtension, -32602, 'Invalid params'),
      );

      await expectLater(readBuildInfo(client), throwsA(isA<RPCError>()));
    });

    test('parses the record when the app has one', () async {
      final client = await clientThat(
        payload: const {
          'type': '_extensionType',
          'method': buildInfoExtension,
          'label': '@@//:app_flutter',
          'compilationMode': 'dbg',
          'platformBuildArgs': <String>[],
          'dartDefines': <String>[],
          'assetsDir': 'bazel-out/x/bin/app_flutter_flutter_assets',
          'targetPlatform': 'macos',
        },
      );

      final parsed = await readBuildInfo(client);

      expect(parsed?.label, '@@//:app_flutter');
      expect(parsed?.targetPlatform, 'macos');
      expect(
        parsed?.record.containsKey('type'),
        isFalse,
        reason:
            'the VM service appends type/method to every extension '
            'response; they are not part of the app’s record',
      );
    });
  });
}
