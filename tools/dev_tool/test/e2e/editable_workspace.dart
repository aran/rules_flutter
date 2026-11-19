/// A private, writable copy of an e2e workspace.
///
/// ## The contract
///
/// **Input:** an [E2eApp], which names a module under `e2e/` and a package in
/// it. The whole module is copied, since the app builds against what is
/// beside it.
///
/// **Output:** [EditableWorkspace.root] — a directory that builds and runs
/// like that module and belongs to one test; [EditableWorkspace.appRoot] is
/// the app's package inside it. Edit anything in it. Nothing
/// needs restoring, because nothing else will ever read it.
///
/// Three invariants make the copy behave like the original, and each is here
/// because the copy would otherwise be broken in a way that is not obvious:
///
///  1. **The `bazel-*` convenience symlinks are not copied.** They point into
///     an output base belonging to the source workspace's path, and following
///     them would drag a foreign build tree into the copy.
///  2. **Relative `local_path_override`s are rewritten to absolute
///     `--override_module` flags.** Every e2e workspace resolves the ruleset
///     under test with `local_path_override(path = "../..")`, which is
///     relative to the workspace and therefore meaningless once it moves.
///     Without this the copy fails at `Computing main repo mapping` before it
///     reaches a single target.
///  3. **The source's own `.bazelrc.user` is carried across.** That file is
///     gitignored per-developer config — on this project it is what points
///     `rules_dart` at a sibling checkout — so a copy without it builds
///     against different code than the workspace it was copied from.
///
/// ## What is NOT contractual
///
/// **How the copy is made.** Today it is a plain recursive file copy. (Bazel's
/// *repository* cache is shared across output bases, so the expensive
/// downloads are not repeated.) If that becomes the bottleneck, a
/// clone-on-write copy, a symlink farm, an overlay mount or a container can
/// replace it without touching a single test — provided the three invariants
/// above still hold at [EditableWorkspace.root].
///
/// Tests must therefore reach the workspace ONLY through this type. A test
/// that mutates files must never build a path from [E2eApp.moduleRoot] or [E2eApp.root], or it
/// writes into the tree every other test is reading.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// Set to keep the copies on disk after a run, for post-mortem debugging.
///
/// Off by default: a full sweep makes one copy per mutating test, and each
/// carries its own Bazel output base. The path is printed on creation either
/// way, so a failing run can be repeated with this set.
const _keepEnvVar = 'E2E_KEEP_WORKSPACES';

/// Where copies share their built actions.
///
/// Outside any workspace so it survives them, and outside the repo so no
/// build or `git clean` sees it. Bounded by [_diskCacheMaxSize] and
/// [_diskCacheMaxAge], and safe to delete outright at any time; the next run
/// just pays the cold cost again. A `--disk_cache` in the source workspace's
/// `.bazelrc.user` replaces this one, since that file is appended after it.
String get _diskCache =>
    p.join(_homeDirectory, '.cache', 'rules_flutter_e2e_disk');

/// The current user's home directory.
///
/// Read per platform rather than one name falling back to the other: `HOME` is
/// POSIX and simply does not exist on Windows, where `USERPROFILE` is the same
/// thing under a different name. A `??` chain would read as tolerating a
/// missing value, which is not what this is.
String get _homeDirectory {
  final name = Platform.isWindows ? 'USERPROFILE' : 'HOME';
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw StateError(
      '$name is unset, so there is nowhere to put the shared disk cache. '
      'It has to live outside the repo and outside every workspace copy, so '
      'there is no sensible default to pick here.',
    );
  }
  return value;
}

/// [path] as a Bazel rc file will read it back.
///
/// Bazel treats a backslash in an rc file as an escape character, so a native
/// Windows path written verbatim loses every separator:
/// `C:\Users\testuser\.cache\rules_flutter_e2e_disk` arrives as
/// `C:Userstestuser.cacherules_flutter_e2e_disk`, which is relative, so Bazel
/// resolves it under the workspace and dies in `RemoteModule.setup` with
/// `InvalidPathException: Illegal char <:>` — reported to the caller as
/// `bazel info workspace` exiting 37 with an empty stderr, naming neither the
/// flag nor the path. Bazel accepts forward slashes on Windows, and this is a
/// no-op everywhere else.
String _rcPath(String path) => path.replaceAll(r'\', '/');

/// Ceiling on [_diskCache].
///
/// Nothing collects this cache by default — Bazel's `gc_max_size` defaults to
/// `"0"`, meaning unlimited, and one Android target alone puts 1.3 GB in it.
/// 50 GB is chosen to be far above a full sweep's working set, so the GC is a
/// backstop against unbounded growth rather than something that evicts
/// entries a later run still wants.
const _diskCacheMaxSize = '50G';

/// Age ceiling on [_diskCache].
///
/// `30d`, not `1m`: Bazel's duration units are `d`/`h`/`m`/`s` and `m` is
/// MINUTES, not months — `gc_idle_delay` defaults to `"5m"`. Writing `1m` for
/// "one month" would evict everything older than sixty seconds and turn every
/// run cold.
const _diskCacheMaxAge = '30d';

/// Set to a rules_dart checkout to build generated workspaces against it
/// instead of the module `.bazelrc.user` names (or the published pin), such as
/// a snapshot of rules_dart's committed HEAD while its live tree is changing.
/// See docs/TESTING.md, "Testing against another rules_dart".
const rulesDartOverrideEnvVar = 'E2E_RULES_DART_OVERRIDE';

/// The repository's `.bazelrc.user` as a generated workspace can use it, or
/// null when the repository has none and [rulesDartOverrideEnvVar] is unset.
///
/// On a developer machine that file points modules at sibling checkouts
/// (`--override_module`), among them ones only the repository's own
/// development depends on. Bazel refuses an override of a module the root
/// does not depend on ("the root module specifies overrides on nonexistent
/// module(s)"), so a generated workspace takes the overrides of the modules
/// its own `MODULE.bazel` ([moduleBazel]) names with `bazel_dep`, and nothing
/// else of the file changes. [rulesDartOverrideEnvVar], when set, replaces the
/// file's override of rules_dart, or adds one.
String? repositoryUserConfigFor(String repository, String moduleBazel) {
  final file = File(p.join(repository, '.bazelrc.user'));
  final rulesDart = Platform.environment[rulesDartOverrideEnvVar] ?? '';
  if (!file.existsSync() && rulesDart.isEmpty) return null;
  final depends = {
    for (final m in RegExp(
      r'bazel_dep\(\s*name\s*=\s*"([^"]+)"',
    ).allMatches(moduleBazel))
      m.group(1)!,
  };
  final override = RegExp(r'^\s*\w+\s+--override_module=([^=\s]+)=');
  final lines = file.existsSync() ? file.readAsLinesSync() : <String>[];
  return [
    ...lines.where((line) {
      final module = override.firstMatch(line)?.group(1);
      if (module == 'rules_dart' && rulesDart.isNotEmpty) return false;
      return module == null || depends.contains(module);
    }),
    if (rulesDart.isNotEmpty && depends.contains('rules_dart'))
      'common --override_module=rules_dart=${_rcPath(rulesDart)}',
  ].join('\n');
}

/// A workspace copy that belongs to one test.
class EditableWorkspace {
  /// The name it was copied from, for messages.
  final String name;

  /// Absolute path to the copy's module root. Bazel and the dev tool run here.
  final String root;

  /// The app's package, relative to [root]; empty when the app is the module's
  /// root package, and always empty for a [generatedWorkspace].
  final String package;

  EditableWorkspace._(this.name, this.root, [this.package = '']);

  /// Absolute path of the app's directory inside the copy: [root] joined with
  /// [package].
  String get appRoot => p.normalize(p.join(root, package));

  /// A file of the app inside the copy, addressed the way the source app would
  /// (relative to its package).
  File file(String relative) => File(p.join(appRoot, relative));

  /// A directory of the app inside the copy, relative to its package.
  Directory dir(String relative) => Directory(p.join(appRoot, relative));

  /// The label of [target] in the app's package, as [E2eApp.label] gives it.
  String label(String target) => E2eApp(name, package).label(target);
}

/// Snapshot the module of [app] into a copy this test owns.
///
/// Disposed at the end of the test: the copy's Bazel server is shut down (one
/// server per output base, and a sweep makes many) and the tree is removed
/// unless [_keepEnvVar] is set.
Future<EditableWorkspace> editableWorkspace(E2eApp app) async {
  final name = app.module;
  final source = app.moduleRoot;
  if (!Directory(source).existsSync()) {
    throw StateError('no e2e module named "$name" at $source');
  }
  if (!Directory(app.root).existsSync()) {
    throw StateError('no package "${app.package}" in e2e module "$name"');
  }

  final parent = await Directory.systemTemp.createTemp('e2e_ws_');
  final root = p.join(parent.path, name);
  Directory(root).createSync(recursive: true);

  _copyTree(Directory(source), Directory(root));
  _writeLocalConfig(source: source, root: root);

  printOnFailure('workspace copy for "$name": $root');
  _disposeAtTeardown(parent: parent, root: root);

  return EditableWorkspace._(name, root, app.package);
}

/// A workspace made from [files] (relative path to contents), for a test that
/// needs a project of its own rather than a copy of one under `e2e/`.
///
/// Disposed like a copy: its Bazel server is shut down and its output base and
/// tree removed when the test ends (when the scope is a `setUpAll`, after the
/// group). Nothing is copied or rewritten, so [files] must be a complete
/// workspace, `MODULE.bazel` included.
Future<EditableWorkspace> generatedWorkspace(
  String name,
  Map<String, String> files,
) async {
  final parent = await Directory.systemTemp.createTemp('e2e_ws_');
  final root = p.join(parent.path, name);
  Directory(root).createSync(recursive: true);
  for (final entry in files.entries) {
    final file = File(p.join(root, entry.key));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value);
  }
  printOnFailure('generated workspace "$name": $root');
  _disposeAtTeardown(parent: parent, root: root);
  return EditableWorkspace._(name, root);
}

/// Shut down the Bazel server of the workspace at [root], remove its output
/// base, and delete [parent], when the current test (or group) ends.
void _disposeAtTeardown({required Directory parent, required String root}) {
  addTearDown(() async {
    // Asked BEFORE the shutdown, for two reasons. The server is still up from
    // the test's own builds, so answering is nearly free; and after a shutdown
    // `bazel info` has to start a fresh server to answer, which recreates the
    // very output base this teardown exists to remove.
    final outputBase = await _outputBase(root);

    // One Bazel server per output base, and the output base is keyed by this
    // path — so without this a sweep leaves a server per mutating test, each
    // holding its analysis cache. Bounded: a server that will not stop is not
    // grounds to fail a test that has otherwise finished.
    await Process.run('bazel', [
      'shutdown',
    ], workingDirectory: root).timeout(
      const Duration(seconds: 60),
      onTimeout: () => ProcessResult(0, 0, '', ''),
    );
    if (Platform.environment[_keepEnvVar] != null) {
      stdout.writeln('kept workspace copy: $root');
      // Kept too: a copy without its output base is not a thing you can debug
      // post-mortem, because the build under investigation lives in there.
      if (outputBase != null) stdout.writeln('kept output base: $outputBase');
      return;
    }
    // Before the tree goes: deleting the copy destroys the only pointer back
    // to its output base. Bazel keys the base by the workspace path and never
    // garbage-collects one, so a base orphaned here is unreachable and
    // permanent, and they are tens of gigabytes each.
    if (outputBase != null) await _removeOutputBase(outputBase);
    if (parent.existsSync()) parent.deleteSync(recursive: true);
  });
}

/// The output base Bazel uses for the workspace at [root], or null if it will
/// not say.
///
/// Never throws and never fails a test: a teardown that cannot find the base
/// leaves one directory behind, which is the status quo this is improving on,
/// not a reason to fail a test that has otherwise finished.
Future<String?> _outputBase(String root) async {
  final ProcessResult result;
  try {
    result =
        await Process.run('bazel', [
          'info',
          'output_base',
        ], workingDirectory: root).timeout(
          const Duration(seconds: 60),
          onTimeout: () => ProcessResult(0, 1, '', ''),
        );
  } on Exception {
    return null;
  }
  if (result.exitCode != 0) return null;
  final path = (result.stdout as String).trim();
  return path.isEmpty ? null : path;
}

/// Delete the output base at [outputBase].
///
/// Two things make this more than a recursive delete:
///
///  1. **The guard.** This removes a directory tree whose path came from
///     another process's stdout. A `bazel info` that fails in an unforeseen
///     way must not turn into a recursive delete of whatever it printed, so
///     nothing is removed unless the basename is the 32-character hex digest
///     Bazel names output bases with. That is a property of every output base
///     and of almost nothing else, and it assumes no particular cache
///     location — which differs across platforms.
///  2. **The chmod.** Bazel leaves its output directories read-only, and a
///     directory without write permission will not give up its children. A
///     plain recursive delete fails partway through with `Permission denied`
///     and leaves most of the tree — which looks like success from the
///     outside, because the exception is on a file nobody is watching.
Future<void> _removeOutputBase(String outputBase) async {
  if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(p.basename(outputBase))) {
    stdout.writeln(
      'not removing "$outputBase": not shaped like a Bazel output base',
    );
    return;
  }
  final directory = Directory(outputBase);
  if (!directory.existsSync()) return;
  try {
    await Process.run('chmod', ['-R', 'u+w', outputBase]);
    directory.deleteSync(recursive: true);
  } on Exception catch (error) {
    // Same bound as the shutdown above: a base that will not go is disk to
    // reclaim later, not grounds to fail a finished test.
    stdout.writeln('could not remove output base "$outputBase": $error');
  }
}

/// Copy [from] to [to], leaving out what belongs to the source's build rather
/// than to its sources.
void _copyTree(Directory from, Directory to) {
  for (final entity in from.listSync(followLinks: false)) {
    final base = p.basename(entity.path);
    // Invariant 1. `bazel-<name>`, `bazel-out`, `bazel-bin`, `bazel-testlogs`
    // are symlinks into an output base this copy does not share.
    if (base.startsWith('bazel-')) continue;
    final target = p.join(to.path, base);
    if (entity is Directory) {
      Directory(target).createSync();
      _copyTree(entity, Directory(target));
    } else if (entity is File) {
      entity.copySync(target);
    } else if (entity is Link) {
      // Preserved as written. A relative link inside the tree still resolves;
      // an absolute one pointed outside the workspace to begin with.
      Link(target).createSync(entity.targetSync());
    }
  }
}

/// Write the copy's `.bazelrc.user`: the overrides the move requires, then
/// whatever the source workspace already had.
void _writeLocalConfig({required String source, required String root}) {
  final lines = <String>[
    '# Written by `editableWorkspace`. Not the source workspace\'s file —',
    '# see `editable_workspace.dart` for why each line is here.',
    '',
    // Not an invariant — a cost fix. A copy has its own output base, so its
    // first build executes every action; without a shared cache the Android
    // screenshot e2e times out mid-build.
    //
    // Shared by every copy and safe to be: Bazel keys entries by action, so
    // concurrent readers and writers of one disk cache do not interfere the
    // way two runs sharing one output base do, and no lock is needed.
    'common --disk_cache=${_rcPath(_diskCache)}',
    //
    // The cache is shared by every copy and outlives all of them, so without
    // a ceiling it is another thing that only grows. Both bounds are needed:
    // size alone lets a cache that never reaches 50 GB keep entries from
    // builds that no longer exist, and age alone bounds nothing during a
    // heavy week.
    //
    // CAVEAT: these will not fire from an e2e run. Bazel collects the disk
    // cache in the background of an IDLE server, after `gc_idle_delay`
    // (default 5m), and this harness shuts its server down within seconds of
    // each test and then deletes the output base.
    //
    // So the ceilings below are a declaration of intent and a backstop for
    // any OTHER server that shares this cache — not a mechanism that keeps
    // it under 50 GB on its own. Deleting the directory outright still works
    // and costs only a cold rebuild.
    'common --experimental_disk_cache_gc_max_size=$_diskCacheMaxSize',
    'common --experimental_disk_cache_gc_max_age=$_diskCacheMaxAge',
    '',
    // The overrides below change what resolves, so the committed lock no
    // longer describes it; under the workspaces' `--lockfile_mode=error` the
    // build would refuse it.
    'common --lockfile_mode=off',
    '',
    '# Invariant 2: the source resolves these by a path relative to itself.',
  ];
  final overrides = _localPathOverrides(source);
  if (overrides.isEmpty) {
    throw StateError(
      'no local_path_override in ${p.join(source, 'MODULE.bazel')}. Every e2e '
      'workspace resolves the ruleset under test that way, so finding none '
      'means the parse below has stopped matching how they are written — and '
      'a copy without those overrides fails at "Computing main repo mapping" '
      'in a way that names none of this.',
    );
  }
  for (final entry in overrides.entries) {
    lines.add('common --override_module=${entry.key}=${_rcPath(entry.value)}');
  }

  final sourceConfig = File(p.join(source, '.bazelrc.user'));
  if (sourceConfig.existsSync()) {
    final carried = sourceConfig.readAsStringSync();
    for (final module in overrides.keys) {
      if (carried.contains('--override_module=$module=')) {
        throw StateError(
          '${sourceConfig.path} already overrides "$module", and this copy '
          'has to override it too (invariant 2). Two overrides of one module '
          'is a conflict Bazel resolves by order, which is not a thing to '
          'leave to chance — reconcile them by hand.',
        );
      }
    }
    lines
      ..add('')
      ..add('# Invariant 3: carried over from ${sourceConfig.path}.')
      ..add(carried.trimRight());
  }

  File(
    p.join(root, '.bazelrc.user'),
  ).writeAsStringSync('${lines.join('\n')}\n');
}

/// Module name → absolute path, for every `local_path_override` in
/// [workspace]'s `MODULE.bazel`.
///
/// Parsed rather than hardcoded: the rewrite is a property of how these
/// workspaces resolve their dependencies, not of which two happen to exist
/// today, and a workspace that adds a third gets it for free.
Map<String, String> _localPathOverrides(String workspace) {
  final module = File(p.join(workspace, 'MODULE.bazel'));
  if (!module.existsSync()) {
    throw StateError('no MODULE.bazel in $workspace');
  }
  final found = <String, String>{};
  final pattern = RegExp(
    r'local_path_override\s*\(\s*module_name\s*=\s*"([^"]+)"\s*,\s*'
    r'path\s*=\s*"([^"]+)"\s*,?\s*\)',
    multiLine: true,
  );
  for (final match in pattern.allMatches(module.readAsStringSync())) {
    found[match.group(1)!] = p.normalize(
      p.join(workspace, match.group(2)!),
    );
  }
  return found;
}
