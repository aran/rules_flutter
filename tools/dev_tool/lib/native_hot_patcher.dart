/// Hot reload for native code: delivering an edit to a `dlopen`ed library into
/// the process that has it mapped.
///
/// A process can never replace a library it has loaded, and relaunching it to
/// get new code throws away every piece of state the edit was meant to be tried
/// against — on a phone that is also tens of seconds of install and launch. What
/// a process *can* do is load a second library and send calls there. A library
/// that is built for it (see `flutter_native_library.hot_patch`) says how such a
/// patch is built; this class decides when to ask for one, gets it to the app,
/// has the app load it, and turns what happened into a [NativePatchOutcome].
///
/// The patch builder is language-specific and runs on this machine; everything
/// else here is not. What it needs from a device is a place the app may load
/// from and a way to get a file there ([NativePatchDelivery]); what it needs
/// from the app is the agent's three native extensions.
///
/// ## When to ask
///
/// On every hot reload, cheaply. A patch build costs a bazel invocation, so it
/// only happens when something says the library's code may have moved: one of
/// the source files the builder declared has a new size or mtime, or the
/// reload's own rebuild (a codegen app's) moved the library itself. A Dart-only
/// edit stats a handful of files and costs nothing else.
///
/// ## Against what
///
/// Always the launched image. The builder snapshots it once per process, and
/// every patch is cumulative against that snapshot — so an edit that is undone
/// comes back as `unchanged` while the process is still running the earlier
/// patch. This class remembers which apps have a patch live and sends those
/// back to their launched code. A relaunch is a new image: [rebaseline].
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart' show RPCError;

import 'bazel.dart';
import 'dev_tool_exception.dart';
import 'logging.dart';
import 'native_hot_patch_tool.dart';
import 'native_image_identity.dart';
import 'native_libs_fingerprint.dart';
import 'native_patch_delivery.dart';
import 'native_patch_outcome.dart';
import 'temp_dir.dart';

export 'native_patch_outcome.dart';

/// The aspect that collects every `hot_patch` target a launch target bundles.
const hotPatchAspect =
    '@rules_flutter//flutter:native_hot_patch.bzl%'
    'flutter_native_hot_patch_aspect';

/// The output group [hotPatchAspect] fills.
const hotPatchOutputGroup = 'flutter_native_hot_patch';

/// One running app, as the patcher needs it.
abstract class NativePatchTarget {
  String get appId;

  /// How a patch reaches this app's device, or null where it cannot.
  NativePatchDelivery? get delivery;

  /// Call an `ext.rules_flutter.*` extension in the app and return its JSON.
  Future<Map<String, dynamic>?> callExtension(
    String method,
    Map<String, String> args,
  );
}

/// A library the running app bundles, with the builder that patches it.
class _Patchable {
  final NativePatchTool tool;
  final String libraryFileName;
  final String stateDirectory;
  Map<String, String> sourceStamps;

  _Patchable({
    required this.tool,
    required this.stateDirectory,
    required this.sourceStamps,
  }) : libraryFileName = p.basename(tool.manifest.library);
}

class NativeHotPatcher {
  final String workspace;

  /// Builds [hotPatchAspect]'s group through the launch target, in the launch
  /// configuration.
  final Future<BazelAspectOutputs> Function() build;

  /// The artifact the app was launched from, whose bundled libraries decide
  /// which of a build's copies of a library is the running one.
  final String appFile;

  /// The apps to patch, read at the moment of patching: a relaunch replaces them.
  final Iterable<NativePatchTarget> Function() targets;

  final Logger logger;

  /// How the patch builders are run; a process by default.
  final PatchToolRunner? _runTool;

  final Directory _scratch;

  List<_Patchable> _libraries;

  /// Per appId, the library file names whose calls a patch has redirected.
  final Map<String, Set<String>> _live = {};

  /// The apps the last [patchIfMoved] changed native code in.
  List<NativePatchTarget> _lastChanged = const [];

  /// Per library file name, how many patches have been delivered — so every
  /// delivery has a file name its loader has never opened.
  final Map<String, int> _delivered = {};

  NativeHotPatcher._({
    required this.workspace,
    required this.build,
    required this.appFile,
    required this.targets,
    required this.logger,
    required Directory scratch,
    required List<_Patchable> libraries,
    PatchToolRunner? runTool,
  }) : _scratch = scratch,
       _libraries = libraries,
       _runTool = runTool;

  /// The file names of the libraries a patch has redirected in any running app.
  List<String> get livePatchedLibraries =>
      {for (final libs in _live.values) ...libs}.toList()..sort();

  /// The file names of the libraries this patcher can patch.
  List<String> get libraries => [for (final l in _libraries) l.libraryFileName];

  /// Build and snapshot every patch builder the launched app bundles.
  ///
  /// Returns null when the app bundles none. Throws [DevToolException] when one
  /// is declared and cannot be armed — a device no patch can be delivered to, no
  /// identity to match it by, no build of it that is the running one, a
  /// snapshot the builder refused — because every one of those means native
  /// edits in this run will need a restart, and the user is owed that sentence
  /// at launch rather than on the first edit.
  static Future<NativeHotPatcher?> arm({
    required String workspace,
    required Future<BazelAspectOutputs> Function() build,
    required String appFile,
    required Iterable<NativePatchTarget> Function() targets,
    required Logger logger,
    required Directory scratch,
    PatchToolRunner? runTool,
  }) async {
    final patcher = NativeHotPatcher._(
      workspace: workspace,
      build: build,
      appFile: appFile,
      targets: targets,
      logger: logger,
      scratch: scratch,
      libraries: const [],
      runTool: runTool,
    );
    await patcher.rebaseline();
    if (patcher._libraries.isEmpty) return null;
    final undeliverable = [
      for (final target in targets())
        if (target.delivery == null) target.appId,
    ];
    if (undeliverable.isNotEmpty) {
      throw DevToolException(
        '${patcher.libraries.join(', ')} declare${patcher.libraries.length == 1 ? 's' : ''} a hot patch, and '
        '${undeliverable.join(', ')} ${undeliverable.length == 1 ? 'runs' : 'run'} on a device '
        'the dev tool cannot deliver a native patch to yet, so native edits in '
        'this run need a hot restart.',
      );
    }
    return patcher;
  }

  /// Take the running app's libraries as the new baseline: at arming, and after
  /// a relaunch replaced the process with one that loaded a rebuilt library.
  Future<void> rebaseline() async {
    // First, whatever follows: the process this is called for launched from a
    // bundle, so it runs no patch — even if the snapshot below fails and this
    // patcher patches nothing more.
    _live.clear();
    _libraries = const [];
    final built = await build();
    if (!built.success) {
      throw DevToolException(
        'Building the native hot patch inputs failed, so native edits in this '
        'run need a hot restart.\n${built.stderr}',
      );
    }
    final manifestFiles = [
      for (final f in built.files)
        if (f.endsWith(hotPatchManifestSuffix)) f,
    ];
    if (manifestFiles.isEmpty) {
      _libraries = const [];
      return;
    }
    final executionRoot = built.executionRoot;
    if (executionRoot == null) {
      throw DevToolException(
        'The native hot patch build named no built file to locate its '
        'execution root by, so its manifests cannot be resolved.',
      );
    }
    final manifests = [
      for (final path in manifestFiles)
        NativeHotPatchManifest.parse(path, await File(path).readAsString()),
    ];
    final running = await _runningManifests(manifests, executionRoot);

    final libraries = <_Patchable>[];
    for (final manifest in running) {
      final name = p.basename(manifest.library);
      final state = Directory(
        p.join(_scratch.path, 'state', '$name.${libraries.length}'),
      );
      if (state.existsSync()) state.deleteSync(recursive: true);
      state.createSync(recursive: true);
      final tool = NativePatchTool(
        manifest: manifest,
        executionRoot: executionRoot,
        run: _runTool,
      );
      await tool.snapshot(state.path);
      libraries.add(
        _Patchable(
          tool: tool,
          stateDirectory: state.path,
          sourceStamps: await _stamps(manifest.sources),
        ),
      );
    }
    _libraries = libraries;
    logger.info({
      'message': 'native_hot_patch_armed',
      'text':
          'Native hot reload armed for ${libraries.map((l) => l.libraryFileName).join(', ')}.',
      'libraries': [for (final l in libraries) l.libraryFileName],
    });
  }

  /// The manifests whose library is the copy the launched app carries.
  ///
  /// By linker identity, never by position or by bytes: see
  /// `native_image_identity.dart` for why bundling defeats a byte comparison and
  /// why a build can hold several copies of one library.
  Future<List<NativeHotPatchManifest>> _runningManifests(
    List<NativeHotPatchManifest> manifests,
    String executionRoot,
  ) async {
    final bundled = (await nativeLibsFingerprint(appFile)).keys.toList();
    final byName = <String, List<NativeHotPatchManifest>>{};
    for (final m in manifests) {
      byName.putIfAbsent(p.basename(m.library), () => []).add(m);
    }

    final running = <NativeHotPatchManifest>[];
    for (final MapEntry(key: name, value: candidates) in byName.entries) {
      final framework = iosFrameworkName(name);
      final members = [
        for (final member in bundled)
          if (p.basename(member) == name ||
              member.endsWith('$framework.framework/$framework'))
            member,
      ];
      if (members.isEmpty) {
        // Declared somewhere in the graph and not in this bundle: a library for
        // another platform, or one this app does not ship. Nothing is running
        // that a patch could reach.
        continue;
      }
      final bundledIds = <String>{};
      for (final member in members) {
        final id = nativeImageIdentity(await readBundledFile(appFile, member));
        if (id == null) {
          throw DevToolException(
            '$member in $appFile carries no linker identity (a Mach-O LC_UUID '
            'or an ELF build-id), so the dev tool cannot tell which build of '
            '$name the app is running, and native edits to it need a hot '
            'restart. Link it with an identity (`-Wl,--build-id` on ELF).',
          );
        }
        bundledIds.add(id);
      }
      final matched = <NativeHotPatchManifest>[];
      final seen = <String, String?>{};
      for (final candidate in candidates) {
        final path = p.join(executionRoot, candidate.library);
        final id = nativeImageIdentity(await File(path).readAsBytes());
        seen[candidate.library] = id;
        if (id != null && bundledIds.contains(id)) matched.add(candidate);
      }
      if (matched.isEmpty) {
        throw DevToolException(
          'None of the ${candidates.length} build(s) of $name the hot patch '
          'build produced is the one $appFile carries '
          '(${bundledIds.join(', ')}), so native edits to it need a hot '
          'restart. Built: ${seen.entries.map((e) => '${e.key} ${e.value ?? '(no identity)'}').join('; ')}',
        );
      }
      // Two manifests for one identity are one build reached twice; either
      // describes the running image.
      running.add(matched.first);
    }
    return running;
  }

  /// Patch every app whose library code moved, or say why it cannot be.
  ///
  /// [movedLibraries] are file names a reload's own rebuild saw move — the
  /// other trigger besides the declared sources.
  Future<NativePatchOutcome> patchIfMoved({
    Set<String> movedLibraries = const {},
  }) async {
    final moved = <_Patchable>[];
    for (final library in _libraries) {
      final stamps = await _stamps(library.tool.manifest.sources);
      if (!_sameStamps(stamps, library.sourceStamps) ||
          movedLibraries.contains(library.libraryFileName)) {
        moved.add(library);
      }
    }
    if (moved.isEmpty) return const NativePatchNotNeeded();

    // Taken before the build: a source saved while bazel reads it is not in
    // what bazel builds, and recording it as delivered would lose that edit.
    final stampsBefore = {
      for (final library in moved)
        library: await _stamps(library.tool.manifest.sources),
    };

    final built = await build();
    if (!built.success) {
      return NativePatchBuildFailed(
        'Building the native patch failed.\n${built.stderr}',
      );
    }

    final apps = targets().toList();
    // Checked at arming too. Here as well because the apps are read afresh: a
    // run that gained one no patch can reach must not have its edit counted as
    // delivered because nothing was asked of it.
    final undeliverable = [
      for (final app in apps)
        if (app.delivery == null) app.appId,
    ];
    if (undeliverable.isNotEmpty) {
      return NativePatchLoadFailed(
        failures: {
          for (final id in undeliverable)
            id: 'this device cannot receive a native patch',
        },
        applied: const [],
      );
    }
    final restart = <String, List<String>>{};
    final failed = <String>[];
    // Per library, per app: what to load (a patch file, or null to go back to
    // the launched code).
    final plans = <_Patchable, Map<NativePatchTarget, PatchBuilderAnswer>>{};
    for (final library in moved) {
      final perApp = plans[library] = {};
      for (final app in apps) {
        final delivery = app.delivery!;
        final int address;
        try {
          address = await _applyAddress(app, delivery, library);
        } on DevToolException catch (e) {
          return NativePatchLoadFailed(
            failures: {app.appId: e.message},
            applied: const [],
          );
        }
        final out = Directory(
          p.join(_scratch.path, 'out', app.appId, library.libraryFileName),
        );
        if (out.existsSync()) out.deleteSync(recursive: true);
        out.createSync(recursive: true);
        final result = await library.tool.patch(
          stateDirectory: library.stateDirectory,
          applyAddress: address,
          outputDirectory: out.path,
        );
        switch (result) {
          case PatchNeedsRestart(:final reasons):
            restart[library.libraryFileName] = reasons;
          case PatchFailed(:final message):
            failed.add('${library.libraryFileName}: $message');
          case PatchBuilt() || PatchUnchanged():
            perApp[app] = result;
        }
      }
    }
    if (restart.isNotEmpty) return NativePatchNeedsRestart(restart);
    if (failed.isNotEmpty) return NativePatchBuildFailed(failed.join('\n'));

    final functions = <String, List<String>>{};
    final reverted = <String>{};
    final failures = <String, String>{};
    final applied = <String>{};
    _lastChanged = const [];
    for (final MapEntry(key: library, value: perApp) in plans.entries) {
      for (final MapEntry(key: app, value: result) in perApp.entries) {
        final live = _live.putIfAbsent(app.appId, () => {});
        final name = library.libraryFileName;
        try {
          switch (result) {
            case PatchBuilt(:final file, functions: final replaced):
              await _load(app, library, file);
              live.add(name);
              functions[name] = replaced;
              applied.add(app.appId);
            case PatchUnchanged() when live.contains(name):
              await _revert(app, library);
              live.remove(name);
              reverted.add(name);
              applied.add(app.appId);
            case _:
              break;
          }
        } on DevToolException catch (e) {
          failures[app.appId] = e.message;
        } on NativePatchDeliveryException catch (e) {
          failures[app.appId] = e.message;
        }
      }
    }
    if (failures.isNotEmpty) {
      return NativePatchLoadFailed(
        failures: failures,
        applied: [
          for (final id in applied)
            if (!failures.containsKey(id)) id,
        ],
      );
    }
    for (final MapEntry(key: library, value: stamps) in stampsBefore.entries) {
      library.sourceStamps = stamps;
    }
    _lastChanged = [
      for (final app in apps)
        if (applied.contains(app.appId)) app,
    ];
    if (functions.isEmpty && reverted.isEmpty) {
      return const NativePatchNotNeeded();
    }
    return NativePatched(functions: functions, reverted: reverted.toList());
  }

  /// Rebuild the widget tree of every app the last [patchIfMoved] changed
  /// native code in.
  ///
  /// A patch changes what a call answers, not anything already on screen: a
  /// widget that showed a native result keeps showing the old one until it
  /// builds again. A Dart reload ends in a reassemble that does this, so this is
  /// for a reload that had no Dart to send.
  Future<void> reassembleChanged() async {
    for (final app in _lastChanged) {
      try {
        await app.callExtension('ext.flutter.reassemble', const {});
      } on RPCError catch (e) {
        logger.warning({
          'message': 'native_patch_reassemble_failed',
          'text':
              '${app.appId} runs the patched native code, and its widgets did '
              'not rebuild to show it: ${e.details ?? e.message}',
          'appId': app.appId,
        });
      }
    }
  }

  Future<int> _applyAddress(
    NativePatchTarget app,
    NativePatchDelivery delivery,
    _Patchable library,
  ) async {
    final loadPath = delivery.libraryLoadPath(library.libraryFileName);
    final answer = await _call(app, 'ext.rules_flutter.nativeSymbolAddress', {
      'library': loadPath,
      'symbol': hotPatchApplySymbol,
    });
    final address = answer['address'];
    final parsed = address is String && address.startsWith('0x')
        ? int.tryParse(address.substring(2), radix: 16)
        : null;
    if (parsed == null) {
      throw DevToolException(
        '${app.appId} answered nativeSymbolAddress for $loadPath with '
        '${jsonEncode(answer)}, which is no address.',
      );
    }
    return parsed;
  }

  Future<void> _load(
    NativePatchTarget app,
    _Patchable library,
    String patchFile,
  ) async {
    final delivery = app.delivery!;
    final directory = await _call(
      app,
      'ext.rules_flutter.nativePatchDirectory',
      const {},
    );
    final appDirectory = directory['path'];
    if (appDirectory is! String) {
      throw DevToolException(
        '${app.appId} answered nativePatchDirectory with '
        '${jsonEncode(directory)}, which names no directory.',
      );
    }
    final count = _delivered[library.libraryFileName] =
        (_delivered[library.libraryFileName] ?? 0) + 1;
    final devicePath = await delivery.deliver(
      localFile: patchFile,
      appDirectory: appDirectory,
      name: 'patch$count.${library.libraryFileName}',
    );
    await _call(app, 'ext.rules_flutter.applyNativePatch', {
      'library': delivery.libraryLoadPath(library.libraryFileName),
      'patch': devicePath,
    });
  }

  Future<void> _revert(NativePatchTarget app, _Patchable library) =>
      _call(app, 'ext.rules_flutter.applyNativePatch', {
        'library': app.delivery!.libraryLoadPath(library.libraryFileName),
      });

  /// An extension call, with the agent's refusal as a [DevToolException] in its
  /// own words.
  Future<Map<String, dynamic>> _call(
    NativePatchTarget app,
    String method,
    Map<String, String> args,
  ) async {
    try {
      return await app.callExtension(method, args) ?? const {};
    } on RPCError catch (e) {
      throw DevToolException(
        '${app.appId}: ${e.details ?? e.message}',
      );
    }
  }

  Future<Map<String, String>> _stamps(List<String> sources) async => {
    for (final source in sources)
      source: await _stamp(p.join(workspace, source)),
  };

  static Future<String> _stamp(String path) async {
    final stat = await File(path).stat();
    if (stat.type == FileSystemEntityType.notFound) return 'missing';
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  }

  static bool _sameStamps(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// Delete this patcher's scratch directory.
  Future<void> dispose() => deleteTempDir(_scratch);
}
