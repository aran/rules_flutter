/// What a debug Flutter app knows about the build it came from.
///
/// `flutter_compile_kernel` bakes this into every `-c dbg`
/// `flutter_application` as the dart define `rules_flutter.build_info`, and
/// `ext.rules_flutter.buildInfo` serves it back verbatim.
///
/// It exists because a target says what *would* be built, while only the
/// process says what it *was* built from — and those diverge routinely in a dev
/// loop, as the BUILD file changes or the checkout moves under a running app.
/// `attach` is where that matters most: it is handed a process it did not
/// launch, and no amount of querying the build graph recovers which build
/// produced it.
library;

import 'dart:convert';

import 'package:vm_service/vm_service.dart' show RPCError;

import 'bazel.dart';
import 'dev_tool_exception.dart';
import 'vm_service_client.dart';

/// The service extension the app answers with. Registered pre-main, outside
/// the agent's binding guard, so it is answerable before `runApp`.
const buildInfoExtension = 'ext.rules_flutter.buildInfo';

/// The dart define `flutter_compile_kernel` bakes the record into, and that the
/// dev tool re-injects on its own compiler so a hot restart keeps it.
const buildInfoDefine = 'rules_flutter.build_info';

class BuildInfo {
  /// The `flutter_application`'s own label, canonical form (`@@//:app`).
  ///
  /// Not the platform wrapper the user launched — this is the target inside
  /// it, which is what a `kind("flutter_application", deps(…))` cquery
  /// returns, so the two can be compared.
  final String label;

  /// `dbg` for anything the dev tool can drive.
  final String compilationMode;

  /// The bazel flags the *launch target's* build needs in order to put this
  /// app in the configuration it is running from — `--ios_multi_cpus=…`,
  /// `--platforms=…`, empty on desktop.
  ///
  /// Mirrors `Device.buildArgs`. The user never typed these (on `run` they
  /// came from `-d`, and `attach` has no `-d` at all), which is why they have
  /// to travel inside the app rather than being asked for.
  final List<String> platformBuildArgs;

  /// The `--dart-define`s the app was compiled with, so the dev tool's own
  /// compiler can replay them without being told.
  final List<String> dartDefines;

  /// The app's `flutter_assets` tree, as an exec-root-relative bazel path
  /// with forward slashes on every host. Compared against
  /// `bazel cquery --output=files` output in exactly this form; only
  /// filesystem access converts it.
  final String assetsDir;

  /// The Flutter platform the app was compiled for (`ios`, `macos`,
  /// `android`, `linux`, `windows`).
  ///
  /// The dev build runs in the HOST configuration, so nothing on the dev
  /// tool's side of the build can answer this — an iOS run on a macOS host
  /// resolves the bare `flutter_application` as macOS. The app knows, because
  /// its kernel was compiled in the launch configuration. The dev tool selects
  /// which platform-filtered plugin registrant its resident frontend_server
  /// compiles by this value; picking the host's would register the wrong
  /// plugin set after a hot restart, silently.
  final String targetPlatform;

  /// The record exactly as the running app served it.
  ///
  /// Kept alongside the parsed fields rather than re-derived from them, so a
  /// field a newer `flutter_compile_kernel` bakes and this binary has no getter
  /// for still survives the round trip in [defineAssignment].
  final Map<String, dynamic> record;

  const BuildInfo._({
    required this.label,
    required this.compilationMode,
    required this.platformBuildArgs,
    required this.dartDefines,
    required this.assetsDir,
    required this.targetPlatform,
    required this.record,
  });

  /// The `-D` assignment that carries this record into a kernel the dev tool
  /// compiles itself.
  ///
  /// `flutter_compile_kernel` bakes the define into the *launch* build only,
  /// and the resident frontend_server does not replay it: after a hot restart
  /// the app runs a dill this tool produced, so it reports its own record only
  /// if this went onto the compiler. Without it a restarted app answers
  /// `ext.rules_flutter.buildInfo` with its "carries no record" error, and the
  /// assets tree that answer settles becomes unrecoverable mid-session.
  ///
  /// Deliberately not sourced from `_dev_config.json`: that comes from the
  /// host-configured dev build, so replaying its value would have the app start
  /// reporting the dev pipeline's configuration as its launch truth — see
  /// `user_defines` in `flutter/private/common.bzl`.
  String get defineAssignment => '$buildInfoDefine=${jsonEncode(record)}';

  /// Parse the extension's payload.
  ///
  /// Every field is required. A partial record is a rules/dev-tool version
  /// skew, and guessing at the missing half is how the dev tool would end up
  /// rebuilding into a tree the app never reads — the failure this whole
  /// mechanism exists to prevent. So it fails by name instead.
  factory BuildInfo.fromJson(Map<String, dynamic> json) {
    T need<T>(String key) {
      final value = json[key];
      if (value is! T) {
        throw DevToolException(
          'the app reported a $buildInfoExtension record with no usable '
          '"$key" (got ${value.runtimeType}). The app and this dev tool were '
          'built from different revisions of rules_flutter.',
        );
      }
      return value;
    }

    return BuildInfo._(
      label: need<String>('label'),
      compilationMode: need<String>('compilationMode'),
      platformBuildArgs: need<List<dynamic>>(
        'platformBuildArgs',
      ).cast<String>(),
      dartDefines: need<List<dynamic>>('dartDefines').cast<String>(),
      assetsDir: need<String>('assetsDir'),
      targetPlatform: need<String>('targetPlatform'),
      record: json,
    );
  }

  /// The bazel flags that reproduce this app's configuration on a build or
  /// cquery of the launch target, plus whatever [extra] the caller was given.
  ///
  /// One list, used for every invocation of a session, so the tree that gets
  /// queried and the tree that gets built cannot drift apart.
  List<String> buildArgs({List<String> extra = const []}) => [
    ...platformBuildArgs,
    ...dartDefineFlags(dartDefines),
    ...extra,
  ];

  @override
  String toString() =>
      'BuildInfo($label, $compilationMode, $targetPlatform, '
      'platformBuildArgs: $platformBuildArgs, assetsDir: $assetsDir)';
}

/// The JSON-RPC code every `ServiceExtensionResponse.error` from the agent
/// carries — `_err` in `flutter/private/agent_extensions/agent.dart` builds
/// them all with `ServiceExtensionResponse.invalidParams`.
///
/// Named locally rather than imported, the way `reload_strategy.dart` names
/// `-32601`: `package:vm_service` exposes the wire codes only as literals.
const int _rpcInvalidParams = -32602;

/// Ask a running app which build it came from.
///
/// Returns null when the app answers with no payload at all. Throws
/// [DevToolException] when the app answers that it has no record to give —
/// carrying the app's own words for why, which are more specific than anything
/// this side could compose.
///
/// The refusal arrives as a **throw**, not as a returned map. Every failure the
/// agent reports is a `ServiceExtensionResponse.error`, which crosses the VM
/// service as a JSON-RPC error and makes `package:vm_service` complete the call
/// with an [RPCError].
///
/// Only the agent's own shape is converted, and it takes both halves to
/// recognise: that code, *and* handler-authored text in `details`. Anything
/// else — a disposed connection, an unknown method, the VM's own "invalid
/// params" for a stale isolate id — is a fault in the connection rather than an
/// answer from the app, and reporting it as "this app carries no record" would
/// be the same misattribution pointing the other way.
Future<BuildInfo?> readBuildInfo(VmServiceClient client) async {
  final Map<String, dynamic>? response;
  try {
    response = await client.callServiceExtension(buildInfoExtension);
  } on RPCError catch (e) {
    // The code first, and on its own: `RPCError.details` is an untyped read
    // out of the error's `data` map with an implicit cast to `String?`, so a
    // foreign error carrying something else there would throw out of the
    // getter instead of being rethrown as itself.
    if (e.code != _rpcInvalidParams) rethrow;
    // `details` is where the VM puts the handler's own text. `message` is
    // generic to the code — "Invalid params" for every refusal the agent makes
    // — so it is never the answer, and an error without `details` has no
    // answer in it at all.
    final said = e.details;
    if (said == null) rethrow;
    throw DevToolException(said);
  }
  if (response == null) return null;
  // The VM service appends these to every extension response.
  final json = Map<String, dynamic>.from(response)
    ..remove('type')
    ..remove('method');
  return BuildInfo.fromJson(json);
}

/// Settle which `flutter_assets` tree backs the running app.
///
/// Takes the already-gathered facts rather than fetching them, so the decision
/// can be exercised without a Bazel server or a running app — the ambiguity it
/// exists to resolve does not arise in an e2e harness, which only ever produces
/// the unambiguous case.
///
/// The answer is [info]'s, always. [candidates] only says whether that answer
/// is *legitimate*: is the tree the app claims among the outputs [target]
/// produces under the flags the app says built it. On Android that list holds
/// three plausible trees, so picking one by position is not an option.
///
/// Args:
///   info: what the running app reports about its own build.
///   candidates: workspace-relative outputs of the `flutter_application`
///     reached through [target], in [target]'s configuration.
///   queriedLabel: the configured label of that application, or null when the
///     query could not answer.
///   target: the launch target the user named, for error messages.
///   appliedArgs: the flags used for the query, for error messages.
///
/// Returns the workspace-relative assets directory. Throws [DevToolException]
/// when the app's tree is unreachable from [target], or when [target] builds a
/// different application.
String resolveAssetsDir({
  required BuildInfo info,
  required List<String> candidates,
  required String? queriedLabel,
  required String target,
  required List<String> appliedArgs,
}) {
  if (!candidates.contains(info.assetsDir)) {
    throw DevToolException(
      'the app reports its assets at "${info.assetsDir}", which is not among '
      'the outputs $target produces with the flags the app says built it '
      '(${appliedArgs.join(' ')}).\n'
      'Reachable from $target: '
      '${candidates.where((f) => f.endsWith('flutter_assets')).join(', ')}\n'
      'If the run passed extra --build-arg values, attach needs the same '
      'ones — they change the configuration and cannot be recovered from the '
      'app.',
    );
  }
  // A `-t` naming the wrong wrapper can still produce a plausible-looking
  // tree, and finding out by name beats finding out by rebuilding into
  // someone else's directory.
  if (queriedLabel != null &&
      canonicalizeLabel(queriedLabel) != canonicalizeLabel(info.label)) {
    throw DevToolException(
      'the app reports itself as ${info.label}, but $target contains '
      '${canonicalizeLabel(queriedLabel)}. The target named does not build '
      'the app that is running.',
    );
  }
  return info.assetsDir;
}

/// Bring a label to the canonical `@@//pkg:name` form the app reports.
///
/// `bazel cquery --output=label` prints the apparent form (`//:app`), while
/// `str(ctx.label)` in Starlark produces the canonical one (`@@//:app`).
/// Comparing them raw fails on every app in the main repository, which is
/// every app — so both sides pass through here first.
String canonicalizeLabel(String label) {
  if (label.startsWith('@@')) return label;
  if (label.startsWith('@')) return '@$label';
  return '@@$label';
}
