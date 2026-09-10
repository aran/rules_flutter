/// Extracts Flutter toolchain paths from Bazel.
///
/// Two sources, answering two different questions:
///
///  * [resolveToolchainPaths] finds the Flutter host toolchain repo in a
///    workspace's Bazel output base and builds the five paths a run needs out
///    of it — `dart`, `dartaotruntime`, `frontend_server_aot.dart.snapshot`,
///    `platform_strong.dill` and the patched SDK root. It answers before
///    anything is built, which is why it is here and not read off a build.
///  * [parseDevConfig] reads the `_dev_config.json` a `flutter_application` or
///    `flutter_web_bundle` emits, which is what the *build* resolved.
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path/path.dart' as p;

import 'dev_tool_exception.dart';

/// Toolchain paths resolved from Bazel.
class ToolchainPaths {
  final String dart;
  final String dartaotruntime;
  final String frontendServer;
  final String platformDill;
  final String patchedSdkRoot;

  ToolchainPaths({
    required this.dart,
    required this.dartaotruntime,
    required this.frontendServer,
    required this.platformDill,
    required this.patchedSdkRoot,
  });
}

/// How [resolveToolchainPaths] reaches bazel.
///
/// Injected because a test target here runs inside a Bazel sandbox, where
/// nesting a `bazel` invocation is not possible (see the comment on the
/// analysis targets in this package's BUILD file), so the failures below cannot
/// be provoked without a seam.
typedef BazelRunner =
    Future<ProcessResult> Function(
      List<String> args, {
      required String workingDirectory,
    });

Future<ProcessResult> _runBazel(
  List<String> args, {
  required String workingDirectory,
}) => Process.run(
  'bazel',
  args,
  workingDirectory: workingDirectory,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

/// What the Flutter host toolchain repo for [platform] is called inside an
/// output base, in each of the two positions `rules_flutter` can occupy.
///
/// A module extension's repos are named
/// `<canonical repo of the module that DEFINES the extension>+<extension>+<repo>`.
/// This extension is defined in `rules_flutter`, whose own canonical repo name
/// is `''` when it is the root module and `rules_flutter+` when it is a
/// dependency — so there are exactly two possible names, a workspace resolves
/// `rules_flutter` in one position or the other, and never both. This is an
/// enumeration of a two-valued fact, not a search: at most one of these exists
/// in any one output base.
List<String> flutterToolchainRepoNames(String platform) => [
  'rules_flutter++flutter+flutter_$platform',
  '+flutter+flutter_$platform',
];

/// Resolve Flutter toolchain paths from Bazel for a given target.
///
/// [workspace] must be the consumer's workspace root — it's used as the spawned
/// bazel process's `workingDirectory` so the call works under `bazel run`
/// (where `Directory.current` is the runfiles execroot).
///
/// Runs before anything is built, because the frontend server and the
/// dartaotruntime that drives it are needed to assemble a run at all. That is
/// what makes the fetch below load-bearing rather than incidental: on a
/// workspace whose output base has never been built there is no external repo
/// to find yet, and this is the call that creates it.
Future<ToolchainPaths> resolveToolchainPaths(
  String target, {
  required String workspace,
  BazelRunner runBazel = _runBazel,
}) async {
  final info = await runBazel([
    'info',
    'output_base',
  ], workingDirectory: workspace);
  if (info.exitCode != 0) {
    throw DevToolException(
      'Could not read the Bazel output base for $workspace.\n'
      '  cd $workspace && bazel info output_base\n'
      '  exit ${info.exitCode}\n'
      '${_tail(info.stderr as String)}',
    );
  }
  final outputBase = (info.stdout as String).trim();

  final platform = detectHostPlatform();
  final externalBase = p.join(outputBase, 'external');
  final candidates = flutterToolchainRepoNames(platform);

  var externalDir = _existingRepo(externalBase, candidates);
  if (externalDir == null) {
    // `bazel fetch` analyses the target, and analysis is what resolves the
    // Flutter toolchain and materializes its repo. Its result is checked: this
    // is the first bazel command a run makes, so every way the workspace is
    // unusable surfaces here, and discarding it would turn all of them into
    // "could not find Flutter toolchain".
    final fetch = await runBazel([
      'fetch',
      target,
    ], workingDirectory: workspace);
    if (fetch.exitCode != 0) {
      throw DevToolException(
        'Could not fetch what $target needs, so the Flutter toolchain was '
        'never materialized.\n'
        '  cd $workspace && bazel fetch $target\n'
        '  exit ${fetch.exitCode}\n'
        '${_tail(fetch.stderr as String)}',
      );
    }
    externalDir = _existingRepo(externalBase, candidates);
  }
  if (externalDir == null) {
    throw DevToolException(
      '`bazel fetch $target` succeeded but left no Flutter toolchain in '
      '$externalBase.\n'
      'Looked for: ${candidates.join(', ')}.\n'
      'That means $target resolves no rules_flutter toolchain — check that '
      'the workspace registers one (`register_toolchains`) and that $target '
      'is a Flutter target.',
    );
  }

  final isWindows = Platform.isWindows;
  final dartBin = isWindows ? 'dart.exe' : 'dart';
  final dartaotruntimeBin = isWindows ? 'dartaotruntime.exe' : 'dartaotruntime';

  return ToolchainPaths(
    dart: p.join(externalDir, 'dart-sdk', 'bin', dartBin),
    dartaotruntime: p.join(externalDir, 'dart-sdk', 'bin', dartaotruntimeBin),
    frontendServer: p.join(
      externalDir,
      'host-tools',
      'frontend_server_aot.dart.snapshot',
    ),
    platformDill: p.join(
      externalDir,
      'patched-sdk',
      'flutter_patched_sdk',
      'platform_strong.dill',
    ),
    patchedSdkRoot: p.join(externalDir, 'patched-sdk', 'flutter_patched_sdk'),
  );
}

/// Whichever of [candidates] exists under [externalBase], or null.
///
/// At most one can: see [flutterToolchainRepoNames].
String? _existingRepo(String externalBase, List<String> candidates) {
  for (final name in candidates) {
    final dir = p.join(externalBase, name);
    if (Directory(dir).existsSync()) return dir;
  }
  return null;
}

/// The last few lines of [output], so a failure names its own cause without
/// pasting a whole Bazel run into one exception message.
///
/// Bazel writes its diagnostics — `ERROR:` lines included — to stderr, which is
/// what every caller here passes.
String _tail(String output, {int lines = 40}) {
  final trimmed = output.trimRight();
  // Said rather than left blank: a message that trails off after "exit 2" reads
  // as truncated output, when what happened is that bazel explained nothing.
  if (trimmed.isEmpty) return '(bazel wrote nothing to stderr)';
  final all = trimmed.split('\n');
  if (all.length <= lines) return trimmed;
  return all.sublist(all.length - lines).join('\n');
}

String detectHostPlatform() {
  final os = Platform.operatingSystem;
  final arch = detectArch();

  switch (os) {
    case 'macos':
      return 'darwin-$arch';
    case 'linux':
      return 'linux-$arch';
    case 'windows':
      return 'windows-$arch';
    default:
      throw UnsupportedError('Unsupported OS: $os');
  }
}

String detectArch() {
  final abi = Abi.current();
  if (abi == Abi.macosArm64 ||
      abi == Abi.linuxArm64 ||
      abi == Abi.windowsArm64) {
    return 'arm64';
  }
  return 'x64';
}

/// Paths to web SDK artifacts for DDC dev mode.
class WebToolchainPaths {
  final String ddcOutlineDill;
  final String librariesSpec;
  final String dartSdkJs;
  final String ddcModuleLoaderJs;
  final String stackTraceMapperJs;
  final String dartSdkRoot;

  WebToolchainPaths({
    required this.ddcOutlineDill,
    required this.librariesSpec,
    required this.dartSdkJs,
    required this.ddcModuleLoaderJs,
    required this.stackTraceMapperJs,
    required this.dartSdkRoot,
  });
}

/// Dev config parsed from `_dev_config.json` emitted by `flutter_web_bundle`
/// in debug mode.
///
/// Contains engine revision, version, host toolchain paths, and dart-sdk root.
class DevConfig {
  final String engineRevision;
  final String flutterVersion;
  final String dartSdkRoot;
  final String dartaotruntime;
  final String frontendServer;
  final String patchedSdkRoot;

  /// The app's entrypoint as a package: URI (e.g. `package:my_app/main.dart`)
  /// or exec-root-relative path if package_name was not set.
  final String appEntrypoint;

  /// Absolute path to the hot-reload package_config (distinct from the build
  /// one): for a source-assembled app its rootUri uses [filesystemScheme] so it
  /// resolves across the live source tree + generated bazel-out roots. Empty
  /// when the build did not emit one (e.g. web dev configs).
  final String devPackageConfig;

  /// Absolute path to the **build** package_config — the one whose `rootUri`s
  /// are ordinary paths, so a `package:` URI resolved through it can be opened
  /// as a file. Web only; empty for a native config.
  ///
  /// Deliberately a second field rather than a second use of
  /// [devPackageConfig]. The two answer different questions and a
  /// source-assembled app is where they diverge: the dev config's `rootUri` is
  /// `<filesystemScheme>:///<lib_root>`, which the frontend_server resolves
  /// through `--filesystem-root` and `Uri.toFilePath()` refuses outright. The
  /// compiler wants the dev one (live sources); DWDS wants this one, because
  /// its job is to read the source off disk and show it. Handed the dev one it
  /// throws `Cannot extract a file path from a org-dartlang-app URI` on every
  /// first-party library and the debugger shows a blank pane.
  final String buildPackageConfig;

  /// Absolute `--filesystem-root` dirs the frontend_server searches for
  /// [filesystemScheme] URIs (live source roots, then generated bazel-out
  /// roots). Empty unless the app package is source-assembled.
  final List<String> filesystemRoots;

  /// The `--filesystem-scheme` paired with [filesystemRoots] (e.g.
  /// `org-dartlang-app`). Empty when [filesystemRoots] is empty.
  final String filesystemScheme;

  /// Absolute paths of the generated files in the app package; re-stat'd after
  /// a rebuild to add changed ones to the reload invalidation set. Parallel to
  /// [generatedSourceUris].
  final List<String> generatedSourcePaths;

  /// The `package:` URIs of the generated files, parallel to
  /// [generatedSourcePaths] (so the dev tool invalidates the right library
  /// without inferring a URI from a path).
  final List<String> generatedSourceUris;

  /// First-party source packages (app + local deps) as `{name, libRoot}`, where
  /// `libRoot` is workspace-relative. Drives the [PackageUriResolver] so a live
  /// edit in any of these packages maps to its `package:` URI. Empty for web
  /// dev configs only if the build emitted none.
  final List<({String name, String libRoot})> sourcePackages;

  /// Merged user defines (target `defines` attr + the extra_dart_defines
  /// flag) the app was built with. Replayed as -D launch flags on the
  /// resident frontend_server so hot reload/restart recompiles see the same
  /// String.fromEnvironment values as the initial build.
  final List<String> dartDefines;

  /// Per-platform generated plugin registrants (`_PluginRegistrant`), keyed
  /// by Flutter platform (`android`, `ios`, `linux`, `macos`, `windows`).
  ///
  /// A map rather than one file because the dev build runs in the HOST
  /// configuration while the app can be running on a different platform:
  /// `generate_dart_plugin_registrant` filters plugins by platform, so the
  /// host-config registrant is filtered for the host — on an iOS run from a
  /// macOS host that registers the macOS plugin set after a hot restart,
  /// silently. The rules emit one registrant per platform and the dev tool
  /// picks the entry matching [BuildInfo.targetPlatform] via [registrantFor].
  ///
  /// The chosen file is compiled into the dev tool's dills via `--source` and
  /// advertised with `-Dflutter.dart_plugin_registrant` so the engine's
  /// pre-main hook keeps firing after hot restart. An empty value states that
  /// platform has no Dart plugins and no agent to register. Values are
  /// absolutized by [parseDevConfig].
  final Map<String, String> dartPluginRegistrants;

  /// Absolute path to the generated Flutter **web** plugin registrant
  /// (`registerPlugins()`), or `''` when the app has no web plugins.
  ///
  /// Distinct from [dartPluginRegistrants]: the native registrant is injected
  /// into the isolate via `--source` + `-Dflutter.dart_plugin_registrant` and
  /// invoked by the engine before `main()`, while the web registrant is
  /// imported by the synthetic web entrypoint and called from
  /// `ui_web.bootstrapEngine(registerPlugins: …)`.
  final String webPluginRegistrant;

  /// Absolute path to the staged AI-agent service extensions
  /// (`registerRulesFlutterAgentExtensions()`), or `''` for a config that
  /// predates them.
  ///
  /// Web only, and dev-loop only. The native rules compile the same source into
  /// the app's kernel and let the engine's pre-main registrant hook call it;
  /// the web bundle cannot, because dart2wasm/dart2js stub out
  /// `registerExtension`. So the DDC dev loop is the one place it can run, and
  /// the dev tool imports it from the synthetic entrypoint it generates.
  final String agentExtensions;

  /// Absolute path to the bootstrap the dev server answers
  /// `/flutter_bootstrap.js` with. `''` for a native config, which has no page
  /// to boot.
  ///
  /// The build substitutes it, from the same `bootstrap_js` template the bundle
  /// ships, with the DDC build config a `-d chrome` run compiles under. A
  /// bootstrap generated by the dev tool instead would ignore the target's
  /// template and every `web_defines` entry that referenced it, so a define
  /// would work on `bazel build` and silently do nothing on `run`.
  final String flutterBootstrapJs;

  /// Language experiments the app was built with, as bare names (`records`),
  /// not as flags.
  ///
  /// The build spells them one way and the frontend server another, so the
  /// spelling belongs to whoever writes the command line — [CompilerConfig],
  /// which turns each into `--enable-experiment=<name>`. They go on the
  /// resident compiler's own argv, which is what makes them apply to the
  /// initial compile and to every recompile after it: an experiment is a
  /// property of the process, not of a request.
  ///
  /// Without them a source using an experiment fails in the frontend server
  /// with a parse error pointing at the syntax rather than at the missing
  /// flag.
  final List<String> enableExperiments;

  /// Whether DDC's native null assertions are on — `nativeNonNullAsserts` in
  /// the generated main module.
  ///
  /// True unless the build says otherwise, matching the rules' attr default
  /// (which in turn matches `flutter build web`). Read rather than assumed
  /// because the dev loop generates `main_module.bootstrap.js` itself: a build
  /// that turned this off would otherwise get it silently back on under the dev
  /// loop.
  final bool nativeNullAssertions;

  DevConfig({
    required this.engineRevision,
    required this.flutterVersion,
    required this.dartSdkRoot,
    required this.dartaotruntime,
    required this.frontendServer,
    required this.patchedSdkRoot,
    required this.appEntrypoint,
    this.devPackageConfig = '',
    this.buildPackageConfig = '',
    this.filesystemRoots = const [],
    this.filesystemScheme = '',
    this.generatedSourcePaths = const [],
    this.generatedSourceUris = const [],
    this.sourcePackages = const [],
    this.dartDefines = const [],
    this.dartPluginRegistrants = const {},
    this.webPluginRegistrant = '',
    this.agentExtensions = '',
    this.flutterBootstrapJs = '',
    this.enableExperiments = const [],
    this.nativeNullAssertions = true,
  });

  /// The registrant for the platform the app is running on, from
  /// [BuildInfo.targetPlatform].
  ///
  /// A missing key is rules/dev-tool version skew or an unknown platform
  /// string, and it fails by name — falling back to another platform's
  /// registrant is exactly the silent wrong-plugin-set bug the map exists to
  /// prevent. An empty value is a real answer: no registrant on this platform.
  String registrantFor(String platform) {
    final registrant = dartPluginRegistrants[platform];
    if (registrant == null) {
      throw DevToolException(
        'the dev config carries no plugin registrant for platform '
        '"$platform" (it has: ${dartPluginRegistrants.keys.join(', ')}). '
        'The app and this dev tool were built from different revisions of '
        'rules_flutter.',
      );
    }
    return registrant;
  }

  /// Generated files as `{package: URI → absolute path}` for reload
  /// invalidation, zipped from the parallel [generatedSourceUris] /
  /// [generatedSourcePaths].
  Map<String, String> get generatedFileUris => {
    for (
      var i = 0;
      i < generatedSourceUris.length && i < generatedSourcePaths.length;
      i++
    )
      generatedSourceUris[i]: generatedSourcePaths[i],
  };

  /// Parse from the JSON content of a `_dev_config.json` file. The native
  /// (`flutter_application`) config carries the hot-reload multi-root fields;
  /// the web (`flutter_web_bundle`) config omits them, so they default empty.
  factory DevConfig.fromJson(Map<String, dynamic> json) {
    List<String> strList(String key) =>
        ((json[key] as List?) ?? const []).cast<String>();
    return DevConfig(
      engineRevision: json['engineRevision'] as String,
      flutterVersion: json['flutterVersion'] as String,
      dartSdkRoot: json['dartSdkRoot'] as String,
      dartaotruntime: json['dartaotruntime'] as String,
      frontendServer: json['frontendServer'] as String,
      patchedSdkRoot: json['patchedSdkRoot'] as String,
      appEntrypoint: json['appEntrypoint'] as String,
      devPackageConfig: (json['devPackageConfig'] as String?) ?? '',
      buildPackageConfig: (json['buildPackageConfig'] as String?) ?? '',
      filesystemRoots: strList('filesystemRoots'),
      filesystemScheme: (json['filesystemScheme'] as String?) ?? '',
      generatedSourcePaths: strList('generatedSourcePaths'),
      generatedSourceUris: strList('generatedSourceUris'),
      dartDefines: strList('dartDefines'),
      dartPluginRegistrants:
          ((json['dartPluginRegistrants'] as Map?) ?? const {})
              .cast<String, String>(),
      webPluginRegistrant: (json['webPluginRegistrant'] as String?) ?? '',
      agentExtensions: (json['agentExtensions'] as String?) ?? '',
      flutterBootstrapJs: (json['flutterBootstrapJs'] as String?) ?? '',
      enableExperiments: strList('enableExperiments'),
      // Absent means the build's attr default, which is on. Only an explicit
      // `false` turns it off.
      nativeNullAssertions: (json['nativeNullAssertions'] as bool?) ?? true,
      sourcePackages: [
        for (final e in (json['sourcePackages'] as List?) ?? const [])
          (
            name: (e as Map)['name'] as String,
            libRoot: e['libRoot'] as String,
          ),
      ],
    );
  }
}

/// Find `_dev_config.json` in build output files.
///
/// `bazel cquery <label> --output=files` can list the dev config in MORE THAN
/// ONE configuration for a cross-platform app: the `flutter_application` is
/// reached through the platform app's apple/android transition, so it appears
/// both in the transitioned config (e.g. `ios_sim_arm64-dbg-…-ST-<hash>`) AND
/// in the default host config (`darwin_arm64-dbg`). The dev tool builds the
/// BARE `flutter_application` label, which materializes only the host-config
/// instance — the transitioned path is a dangling symlink. Prefer a candidate
/// that actually resolves on disk; fall back to the first when none do (so the
/// caller surfaces a clear downstream error rather than silently finding none).
String? findDevConfig(List<String> files) {
  final candidates = [
    for (final f in files)
      if (f.endsWith('_dev_config.json')) f,
  ];
  if (candidates.isEmpty) return null;
  for (final f in candidates) {
    try {
      File(f).resolveSymbolicLinksSync();
      return f;
    } catch (_) {
      // Dangling symlink / nonexistent (an unbuilt transitioned config) — skip.
    }
  }
  return candidates.first;
}

/// Parse dev config JSON from a file path, resolving symlinks.
///
/// Paths in the JSON are execution-root-relative (e.g. `external/repo/...`).
/// We derive the execution root from the dev_config.json file's resolved
/// location (`.../execroot/_main/bazel-out/.../dev_config.json` → strip
/// from `/bazel-out/` onward) and prepend it to make all paths absolute.
DevConfig parseDevConfig(String path) {
  final resolved = File(path).resolveSymbolicLinksSync();
  final json =
      jsonDecode(File(resolved).readAsStringSync()) as Map<String, dynamic>;

  // Derive execution root: resolved path contains .../execroot/_main/bazel-out/...
  // Split into path components (separator-agnostic, so it works on Windows
  // where File.resolveSymbolicLinksSync returns '\'-separated paths) and strip
  // from the 'bazel-out' segment onward.
  final parts = p.split(resolved);
  final bazelOutIdx = parts.indexOf('bazel-out');
  final execRoot = bazelOutIdx > 0
      ? p.joinAll(parts.sublist(0, bazelOutIdx))
      : null;

  if (execRoot != null) {
    String abs(String value) =>
        p.isAbsolute(value) ? value : p.join(execRoot, value);

    // Make execution-root-relative path strings absolute.
    for (final key in [
      'dartSdkRoot',
      'dartaotruntime',
      'frontendServer',
      'patchedSdkRoot',
      'devPackageConfig',
      'buildPackageConfig',
      'webPluginRegistrant',
      'agentExtensions',
      'flutterBootstrapJs',
    ]) {
      final value = json[key];
      if (value is String && value.isNotEmpty) json[key] = abs(value);
    }
    // The per-platform registrant map: absolutize each path value. Empty
    // values mean "no registrant on that platform" and stay empty.
    final registrants = json['dartPluginRegistrants'] as Map?;
    if (registrants != null) {
      json['dartPluginRegistrants'] = {
        for (final e in registrants.entries)
          e.key as String: (e.value as String).isEmpty
              ? ''
              : abs(e.value as String),
      };
    }
    // Absolutize the exec-relative path LISTS (roots incl. "" → execroot, and
    // generated output paths). `generatedSourcesTarget` holds bazel labels, not
    // paths — leave it untouched.
    for (final key in ['filesystemRoots', 'generatedSourcePaths']) {
      final list = json[key] as List?;
      if (list != null) {
        json[key] = [for (final v in list.cast<String>()) abs(v)];
      }
    }
  }

  return DevConfig.fromJson(json);
}

/// Fail naming a file the build declared and did not write.
///
/// Every path here is one the build put in `_dev_config.json` and this tool
/// then reads or hands to the frontend_server. Present in the config and
/// absent on disk means a build reported success without materializing an
/// output, which otherwise surfaces far from its cause — a compiler exiting
/// with no file named.
///
/// Called by the pipeline assemblers rather than by [parseDevConfig]: parsing
/// a config and requiring its contents to exist are separate concerns, and a
/// unit test may legitimately parse one whose paths were never built.
void requireDeclaredFilesExist(DevConfig config) {
  final missing = <String>[];

  for (final entry in {
    'devPackageConfig': config.devPackageConfig,
    'buildPackageConfig': config.buildPackageConfig,
  }.entries) {
    if (entry.value.isNotEmpty && !File(entry.value).existsSync()) {
      missing.add('${entry.key}: ${entry.value}');
    }
  }

  for (final path in config.generatedSourcePaths) {
    if (!File(path).existsSync()) missing.add('generatedSourcePaths: $path');
  }

  if (missing.isEmpty) return;

  throw DevToolException(
    'the build declared files it did not write:\n'
    '  ${missing.join('\n  ')}\n'
    'These paths come from _dev_config.json, so the build produced them as '
    'declarations and something served the actions from cache without '
    'materializing the outputs. Bazel writes an output to this machine when '
    'it belongs to a target named on the command line; being an input to an '
    'action is not enough. If you are seeing this after changing what the dev '
    'tool asks bazel to build, the request no longer covers everything the '
    'config points at.',
  );
}

/// Find DDC dev files in build outputs and construct [WebToolchainPaths].
///
/// Looks for files by suffix pattern in the output list.
WebToolchainPaths buildWebToolchainFromOutputs(
  List<String> outputFiles,
  DevConfig devConfig,
) {
  String? ddcOutlineDill;
  String? librariesSpec;
  String? dartSdkJs;
  String? ddcModuleLoaderJs;
  String? stackTraceMapperJs;

  for (final f in outputFiles) {
    if (f.endsWith('_ddc_outline.dill')) {
      ddcOutlineDill = _resolve(f);
    } else if (f.endsWith('_ddc_libraries.json')) {
      librariesSpec = _resolve(f);
    } else if (f.endsWith('_ddc_dart_sdk.js')) {
      dartSdkJs = _resolve(f);
    } else if (f.endsWith('_ddc_module_loader.js')) {
      ddcModuleLoaderJs = _resolve(f);
    } else if (f.endsWith('_ddc_stack_trace_mapper.js')) {
      stackTraceMapperJs = _resolve(f);
    }
  }

  final missing = <String>[];
  if (ddcOutlineDill == null) missing.add('_ddc_outline.dill');
  if (librariesSpec == null) missing.add('_ddc_libraries.json');
  if (dartSdkJs == null) missing.add('_ddc_dart_sdk.js');
  if (ddcModuleLoaderJs == null) missing.add('_ddc_module_loader.js');
  if (stackTraceMapperJs == null) missing.add('_ddc_stack_trace_mapper.js');
  if (missing.isNotEmpty) {
    throw StateError(
      'Missing DDC dev files in build outputs: ${missing.join(', ')}.\n'
      'Ensure the target is a flutter_web_bundle built with -c dbg.',
    );
  }

  return WebToolchainPaths(
    ddcOutlineDill: ddcOutlineDill!,
    librariesSpec: librariesSpec!,
    dartSdkJs: dartSdkJs!,
    ddcModuleLoaderJs: ddcModuleLoaderJs!,
    stackTraceMapperJs: stackTraceMapperJs!,
    dartSdkRoot: devConfig.dartSdkRoot,
  );
}

/// Find the web output directory in build outputs.
///
/// The web output dir ends with `_web` and is a directory.
String findWebOutputDir(List<String> outputFiles) {
  for (final f in outputFiles) {
    if (f.endsWith('_web') && FileSystemEntity.isDirectorySync(f)) {
      return f;
    }
  }
  throw StateError(
    'No web output directory found in build outputs.\n'
    'Expected a directory ending with _web.',
  );
}

/// Resolve a build output to the path the DDC toolchain is handed.
///
/// No catch: `resolveSymbolicLinksSync` throws exactly when the path does not
/// resolve, and answering that with the unresolved path produces a file that
/// fails at open time, several steps later, in whichever of `frontend_server`,
/// DWDS or the browser got there first, naming none of this. Letting the
/// [FileSystemException] out reports the missing file where the toolchain
/// claimed to have found it.
String _resolve(String path) => File(path).resolveSymbolicLinksSync();
