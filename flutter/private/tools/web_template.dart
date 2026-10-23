/// Substitutes Flutter's web template placeholders, and refuses to guess.
///
/// This is the Bazel counterpart of `WebTemplate.withSubstitutions` in
/// `flutter_tools/lib/src/web_template.dart`. It performs the same
/// substitutions in the same order:
///
///   1. `$FLUTTER_BASE_HREF`
///   2. `$FLUTTER_STATIC_ASSETS_URL`
///   3. legacy service-worker constructs
///   4. `{{variable}}` — user `web_defines` plus the four built-ins the build
///      supplies (`flutter_js`, `flutter_build_config`,
///      `flutter_service_worker_version`, `flutter_bootstrap_js`)
///
/// Where it deliberately differs from upstream is what happens when a
/// substitution cannot be made. Upstream logs a warning and leaves the
/// placeholder in the shipped file, because it carries a decade of index.html
/// files it cannot break. A `{{API_URL}}` that survives into a deployed page
/// is a page that half-works, and the failure surfaces in a browser far from
/// the build that caused it — so here every such case is an error naming the
/// file and line.
///
/// The same reasoning covers the legacy service-worker constructs. Upstream
/// rewrites them in place with a deprecation comment; these rules ship a
/// self-unregistering worker registered through `flutter.js`'s loader, so a
/// hand-rolled registration would fight it rather than merge with it. Detected
/// and refused, with the migration named.
///
/// Config JSON schema:
/// {
///   "web_defines": {"NAME": "value", ...},
///   "keep_placeholders": ["name", ...],
///   "files": [
///     {
///       "template": "/path/to/input",
///       "output": "/path/to/output",
///       "label": "web/index.html",
///       "base_href": "/",
///       "static_assets_url": "/",
///       "dev_loop_guard": false,
///       "manages_service_worker": true,
///       "check_constructs": true,
///       "builtins": {
///         "flutter_js": {"file": "/path/to/flutter.js"},
///         "flutter_build_config": {"value": "..."},
///         "flutter_service_worker_version": {"value": "\"v1\""},
///         "flutter_bootstrap_js": {"from_output": 0}
///       }
///     }
///   ]
/// }
///
/// Files are processed in order, so a later file can inline an earlier one's
/// substituted result through `from_output` — which is how an index.html
/// carries `{{flutter_bootstrap_js}}`.
///
/// The same template may appear twice, under different built-ins: a debug
/// build substitutes `flutter_bootstrap.js` once for the bundle and once for
/// the dev loop, whose build config names DDC's output instead of the bundle's.
/// `check_constructs` is false on the second, so bytes both entries read report
/// a deprecated construct in them once rather than twice.
///
/// Substitution is a single pass: replacement text is never rescanned, so a
/// `{{...}}` inside a value — or inside a bootstrap inlined into index.html —
/// ships literally rather than being substituted again. That is what keeps a
/// kept placeholder from being re-judged once it has been inlined somewhere
/// else, and keeps a define's value from being able to inject another.
library;

import 'dart:convert';
import 'dart:io';

/// The variable syntax, matching upstream's `web_template.dart` exactly.
///
/// The tight identifier form is load-bearing for the error-by-default policy:
/// the spaced `{{ item }}` and section `{{#each}}` forms that Vue, Angular and
/// Mustache use do not match, so a page carrying those is untouched and
/// unreported.
final _variablePattern = RegExp(r'\{\{([A-Za-z_][A-Za-z0-9_]*)\}\}');

/// Names the build supplies. Never user-provided, so never "missing".
const _builtinNames = <String>{
  'flutter_js',
  'flutter_build_config',
  'flutter_service_worker_version',
  'flutter_bootstrap_js',
};

/// Built-ins that boot the engine by inlining it into the page.
///
/// The Bazel dev loop serves `index.html` from the build output, and beside it
/// a `flutter_bootstrap.js` substituted for DDC rather than the one the bundle
/// ships. An index that inlines the loader or the bundle's bootstrap therefore
/// never reaches the dev loop's: the page runs against the built bundle, so it
/// renders and hot reload does nothing.
const _bootPathBuiltins = <String>{
  'flutter_js',
  'flutter_bootstrap_js',
  'flutter_build_config',
};

const _baseHrefPlaceholder = r'$FLUTTER_BASE_HREF';
const _staticAssetsUrlPlaceholder = r'$FLUTTER_STATIC_ASSETS_URL';

/// Constructs upstream rewrites and we refuse whatever the target ships.
///
/// `loadEntrypoint` is here rather than below because it has nothing to do with
/// service workers: it only ever loads a JavaScript entrypoint, so a page using
/// it boots the dart2js fallback of a WASM bundle and the WASM build never runs.
final _legacyConstructs = <RegExp, String>{
  RegExp(r'_flutter\.loader\.loadEntrypoint\('):
      'Use _flutter.loader.load() instead. loadEntrypoint only ever loads a '
      'JavaScript entrypoint, so on a dart2wasm bundle it silently boots the '
      'dart2js fallback and the WASM build never runs.',
};

/// Constructs refused only when the build manages a service worker of its own.
///
/// With `pwa = False` the build ships and registers nothing, so a page that
/// registers its own worker is the supported way to have one — there is
/// nothing for it to fight. With `pwa = True` there is: the rules register a
/// self-unregistering worker through flutter.js's loader, which waits for
/// activation, times out, and registers only for a visitor who already has a
/// worker to replace.
final _managedServiceWorkerConstructs = <RegExp, String>{
  RegExp('(const|var) serviceWorkerVersion = null'):
      'Remove it. The service worker version reaches flutter.js through '
      '{{flutter_service_worker_version}} in flutter_bootstrap.js, which '
      'these rules generate.',
  RegExp(r"navigator\.serviceWorker\.register\('flutter_service_worker\.js'\)"):
      'Remove it and let flutter.js register the worker, or set `pwa = False` '
      'to take over service worker duty entirely. A hand-rolled registration '
      'alongside the built-in one installs a worker for every visitor and '
      'waits for neither.',
};

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'compile') {
    _runWebCompile(args.sublist(1));
    return;
  }
  if (args.length != 2 || args[0] != '--config') {
    stderr.writeln('Usage: web_template.dart --config <config.json>');
    exit(1);
  }

  final config =
      json.decode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  final errors = <String>[];
  final result = substituteTemplates(config, errors);

  if (errors.isNotEmpty) {
    stderr.writeln('web template substitution failed:');
    for (final error in errors) {
      stderr.writeln('  $error');
    }
    exit(1);
  }

  result.forEach((path, content) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  });
}

/// Applies every file in [config], collecting problems into [errors].
///
/// Returns output path to substituted content. Public so the tool's own tests
/// drive it directly rather than through a subprocess.
///
/// Nothing is written when [errors] is non-empty: a partially substituted
/// output is worse than none, because a later build would find it up to date.
Map<String, String> substituteTemplates(
  Map<String, dynamic> config,
  List<String> errors,
) {
  final webDefines = <String, String>{
    for (final entry
        in ((config['web_defines'] as Map<String, dynamic>?) ?? {}).entries)
      entry.key: entry.value as String,
  };
  final keepPlaceholders = <String>{
    ...((config['keep_placeholders'] as List<dynamic>?) ?? []).cast<String>(),
  };
  final files = (config['files'] as List<dynamic>).cast<Map<String, dynamic>>();

  // A define that shadows a built-in would be dropped without trace, and one
  // that is also an allowed passthrough asks for two different things at once.
  for (final name in webDefines.keys) {
    if (_builtinNames.contains(name)) {
      errors.add(
        'web_defines declares `$name`, which is a name the build supplies. '
        'Rename the define.',
      );
    }
    if (keepPlaceholders.contains(name)) {
      errors.add(
        '`$name` is in both web_defines and keep_placeholders: it cannot be '
        'both substituted and left in place.',
      );
    }
  }

  final usedDefines = <String>{};
  final outputs = <String, String>{};
  final substituted = <String>[];

  for (final file in files) {
    final label = file['label'] as String;
    final content = File(file['template'] as String).readAsStringSync();
    final result = _substituteFile(
      content: content,
      label: label,
      file: file,
      webDefines: webDefines,
      keepPlaceholders: keepPlaceholders,
      priorOutputs: substituted,
      usedDefines: usedDefines,
      errors: errors,
    );
    substituted.add(result);
    outputs[file['output'] as String] = result;
  }

  // Checked across the whole invocation, not per file: a define may legitimately
  // appear only in the bootstrap or only in index.html.
  for (final name in webDefines.keys) {
    if (!usedDefines.contains(name)) {
      errors.add(
        'web_defines declares `$name`, which no template references. Searched: '
        '${files.map((f) => f['label']).join(', ')}.',
      );
    }
  }

  return outputs;
}

/// One file's substitutions, in upstream's order.
String _substituteFile({
  required String content,
  required String label,
  required Map<String, dynamic> file,
  required Map<String, String> webDefines,
  required Set<String> keepPlaceholders,
  required List<String> priorOutputs,
  required Set<String> usedDefines,
  required List<String> errors,
}) {
  final baseHref = file['base_href'] as String?;
  final staticAssetsUrl = file['static_assets_url'] as String?;
  final devLoopGuard = (file['dev_loop_guard'] as bool?) ?? false;

  var result = content;
  if (baseHref != null) {
    result = result.replaceAll(_baseHrefPlaceholder, baseHref);
  }
  if (staticAssetsUrl != null) {
    result = result.replaceAll(_staticAssetsUrlPlaceholder, staticAssetsUrl);
  }

  // False only for a second entry over a template another entry already read,
  // so one deprecated construct is reported once.
  final checkConstructs = file['check_constructs'] as bool;
  final managesServiceWorker =
      (file['manages_service_worker'] as bool?) ?? false;
  _refusedConstructErrors(
    result,
    label,
    checkConstructs,
    managesServiceWorker,
    errors,
  );

  final builtins = _resolveBuiltins(
    (file['builtins'] as Map<String, dynamic>?) ?? {},
    priorOutputs,
  );

  if (devLoopGuard) {
    _bootPathErrors(result, label, errors);
  }

  return result.replaceAllMapped(
    _variablePattern,
    (match) => _substituteVariable(
      match,
      result,
      label,
      webDefines,
      builtins,
      keepPlaceholders,
      usedDefines,
      errors,
    ),
  );
}

/// Records an error for every legacy construct in [result] these rules refuse.
void _refusedConstructErrors(
  String result,
  String label,
  bool checkConstructs,
  bool managesServiceWorker,
  List<String> errors,
) {
  final refused = <RegExp, String>{
    if (checkConstructs) ..._legacyConstructs,
    if (checkConstructs && managesServiceWorker)
      ..._managedServiceWorkerConstructs,
  };
  refused.forEach((pattern, remedy) {
    for (final match in pattern.allMatches(result)) {
      errors.add(
        '$label:${_lineOf(result, match.start)}: `${match.group(0)}` is '
        'deprecated wiring these rules do not support. $remedy',
      );
    }
  });
}

/// Records an error for every engine boot path inlined into a dev-loop page.
///
/// The Bazel dev loop serves `index.html` from the build output, and beside it
/// a `flutter_bootstrap.js` substituted for DDC rather than the one the bundle
/// ships. An index that inlines the loader or the bundle's bootstrap therefore
/// never reaches the dev loop's: the page runs against the built bundle, so it
/// renders and hot reload does nothing.
void _bootPathErrors(String result, String label, List<String> errors) {
  for (final match in _variablePattern.allMatches(result)) {
    final name = match.group(1)!;
    if (_bootPathBuiltins.contains(name)) {
      errors.add(
        '$label:${_lineOf(result, match.start)}: `{{$name}}` inlines the '
        'engine boot path into the page, which the Bazel dev loop cannot '
        'serve: it serves index.html as built, next to a flutter_bootstrap.js '
        'substituted for DDC, so an inlined copy of this build config would '
        'boot the built bundle and hot reload would do nothing. Use '
        '`<script src="flutter_bootstrap.js" async>` instead, or build this '
        'target in a non-debug configuration.',
      );
    }
  }
}

/// One `{{variable}}`'s substitution: a user define, a built-in, a kept
/// placeholder, or an error naming the file and line.
String _substituteVariable(
  Match match,
  String result,
  String label,
  Map<String, String> webDefines,
  Map<String, String> builtins,
  Set<String> keepPlaceholders,
  Set<String> usedDefines,
  List<String> errors,
) {
  final name = match.group(1)!;
  if (webDefines.containsKey(name)) {
    usedDefines.add(name);
    return webDefines[name]!;
  }
  if (builtins.containsKey(name)) {
    return builtins[name]!;
  }
  if (keepPlaceholders.contains(name)) {
    return match.group(0)!;
  }
  if (_builtinNames.contains(name)) {
    // A build-supplied name, but not one this file is given. The only way
    // that happens is `{{flutter_bootstrap_js}}` in the bootstrap itself,
    // which would have to inline its own output. Naming web_defines here
    // would send the reader to an error that refuses to shadow a built-in.
    errors.add(
      '$label:${_lineOf(result, match.start)}: `{{$name}}` is supplied by the '
      'build, but not to this file. Only index.html can inline the bootstrap.',
    );
    return match.group(0)!;
  }
  errors.add(
    '$label:${_lineOf(result, match.start)}: `{{$name}}` has no value. Supply '
    'one with `web_defines = {"$name": "..."}`, or list it in '
    '`keep_placeholders` to ship the placeholder as written.',
  );
  return match.group(0)!;
}

/// Resolves each built-in to the text it substitutes to.
Map<String, String> _resolveBuiltins(
  Map<String, dynamic> spec,
  List<String> priorOutputs,
) {
  final resolved = <String, String>{};
  spec.forEach((name, value) {
    final entry = value as Map<String, dynamic>;
    if (entry.containsKey('value')) {
      resolved[name] = entry['value'] as String;
    } else if (entry.containsKey('file')) {
      resolved[name] = File(entry['file'] as String).readAsStringSync();
    } else if (entry.containsKey('from_output')) {
      resolved[name] = priorOutputs[entry['from_output'] as int];
    } else {
      throw ArgumentError(
        'builtin `$name` names none of "value", "file", "from_output"',
      );
    }
  });
  return resolved;
}

/// The 1-based line [offset] falls on.
int _lineOf(String content, int offset) =>
    RegExp(r'\r\n|\r|\n').allMatches(content.substring(0, offset)).length + 1;

/// Runs `dart2wasm` or `dart2js` directly via `dartaotruntime`, bypassing
/// `dartdev` (which probes `execroot/bin` outside declared inputs) and
/// normalizing output paths so compilation is sandbox-confined and
/// workspace-path-independent.
void _runWebCompile(List<String> args) {
  final subcommand = args.isNotEmpty ? args.first : '';
  if (subcommand == 'wasm') {
    _runDart2Wasm(args.sublist(1));
  } else if (subcommand == 'js') {
    _runDart2Js(args.sublist(1));
  } else {
    stderr.writeln('web_template compile: unknown subcommand "$subcommand"');
    exit(64);
  }
}

String _toAppSchemeRelPath(String path) {
  final norm = path.replaceAll(r'\', '/');
  return norm.replaceFirst(
    RegExp(r'^(?:\./)?bazel-out/[^/]+/(?:bin|genfiles)/'),
    '',
  );
}

/// Rewrites [packagesPath] so every package root resolves inside the compile's
/// staging root, and writes the result to [outPath].
///
/// Roots under the app scheme name the staged tree directly. Roots on the
/// filesystem must sit under the action's working directory, where the staging
/// root holds their staged copies; a root anywhere else (a `file:` URI the
/// compiler would read straight off the host, outside every multi-root) fails
/// the compile instead of passing through. Roots under any other scheme are
/// left alone: the compiler reports what it cannot resolve.
void _rewritePackageConfigForStage(
  String packagesPath,
  String normCwd,
  String cwdPrefix,
  String outPath,
) {
  final pkgFile = File(packagesPath).absolute;
  final pkgJson =
      json.decode(pkgFile.readAsStringSync()) as Map<String, dynamic>;
  final pkgs = (pkgJson['packages'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  for (final p in pkgs) {
    final rootUri = p['rootUri'] as String;
    String rel = '';
    if (rootUri.startsWith('org-dartlang-app:///')) {
      rel = _toAppSchemeRelPath(
        rootUri.substring('org-dartlang-app:///'.length),
      );
    } else {
      final resolved = pkgFile.uri.resolve(rootUri);
      if (resolved.scheme != 'file') {
        continue;
      }
      final fsPath = resolved.toFilePath().replaceAll(r'\', '/');
      if (fsPath.startsWith(cwdPrefix)) {
        var r = fsPath.substring(cwdPrefix.length);
        if (r.endsWith('/') && r.length > 1) {
          r = r.substring(0, r.length - 1);
        }
        rel = _toAppSchemeRelPath(r);
      } else if (fsPath == normCwd || fsPath == cwdPrefix) {
        rel = '';
      } else {
        stderr.writeln(
          'web_template compile: package ${p['name']} root $rootUri resolves '
          'outside the declared inputs ($fsPath); refusing to compile.',
        );
        exit(1);
      }
    }
    p['rootUri'] = 'org-dartlang-app:///$rel';
  }
  File(outPath).writeAsStringSync(json.encode(pkgJson));
}

/// Rewrites [packagesPath] so every package root resolves inside the compile's
/// staging root, and writes the result to [outPath]. The wasm compiler mounts
/// the staging root itself (see [_runDart2Wasm]), so roots under the working
/// directory name their staged copies; a root anywhere else (a `file:` URI the
/// compiler would read straight off the host, outside every multi-root) fails
/// the compile instead of passing through. Roots under any other scheme are
/// left alone: the compiler reports what it cannot resolve.
void _rewritePackageConfig(
  String packagesPath,
  String normCwd,
  String cwdPrefix,
  String outPath,
) {
  final pkgFile = File(packagesPath).absolute;
  final pkgJson =
      json.decode(pkgFile.readAsStringSync()) as Map<String, dynamic>;
  final pkgs = (pkgJson['packages'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  for (final p in pkgs) {
    final rootUri = p['rootUri'] as String;
    if (rootUri.startsWith('org-dartlang-app:///')) {
      continue;
    }
    final resolved = pkgFile.uri.resolve(rootUri);
    if (resolved.scheme == 'file') {
      final fsPath = resolved.toFilePath().replaceAll(r'\', '/');
      if (fsPath.startsWith(cwdPrefix)) {
        var rel = fsPath.substring(cwdPrefix.length);
        if (rel.endsWith('/') && rel.length > 1) {
          rel = rel.substring(0, rel.length - 1);
        }
        rel = _toAppSchemeRelPath(rel);
        p['rootUri'] = 'org-dartlang-app:///$rel';
      } else if (fsPath == normCwd || fsPath == cwdPrefix) {
        p['rootUri'] = 'org-dartlang-app:///';
      } else {
        stderr.writeln(
          'web_template compile: package ${p['name']} root $rootUri resolves '
          'outside the declared inputs ($fsPath); refusing to compile.',
        );
        exit(1);
      }
    }
  }
  File(outPath).writeAsStringSync(json.encode(pkgJson));
}

void _runDart2Wasm(List<String> args) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final sdkBin = File(Platform.resolvedExecutable).parent.path;
  final dartaotruntime = '$sdkBin/dartaotruntime$exeSuffix';

  final parsed = _parseDart2WasmArgs(args);
  final packagesPath = parsed.packagesPath;
  final outputWasm = parsed.outputWasm;
  final mainDart = parsed.mainDart;
  if (packagesPath == null || outputWasm == null || mainDart == null) {
    stderr.writeln(
      'web_template compile wasm: --packages, -o, and entrypoint are required',
    );
    exit(64);
  }

  _compileWasm(
    dartaotruntime: dartaotruntime,
    sdkBin: sdkBin,
    packagesPath: packagesPath,
    outputWasm: outputWasm,
    mainDart: mainDart,
    multiRoot: parsed.multiRoot,
    noSourceMaps: parsed.noSourceMaps,
    extraOptions: parsed.extraOptions,
    forwardArgs: parsed.forwardArgs,
  );
}

/// The `compile wasm` flags in [args].
({
  String? packagesPath,
  String? outputWasm,
  String? mainDart,
  String? multiRoot,
  bool noSourceMaps,
  List<String> extraOptions,
  List<String> forwardArgs,
})
_parseDart2WasmArgs(List<String> args) {
  String? packagesPath;
  String? outputWasm;
  String? mainDart;
  String? multiRoot;
  var noSourceMaps = false;
  final extraOptions = <String>[];
  final forwardArgs = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--packages=')) {
      packagesPath = arg.substring('--packages='.length);
    } else if (arg.startsWith('--multi-root=')) {
      multiRoot = arg.substring('--multi-root='.length);
    } else if (arg.startsWith('--extra-compiler-option=')) {
      extraOptions.add(arg.substring('--extra-compiler-option='.length));
    } else if (arg == '-o') {
      outputWasm = args[++i];
    } else if (arg.startsWith('-o=')) {
      outputWasm = arg.substring('-o='.length);
    } else if (arg == '--no-source-maps') {
      noSourceMaps = true;
      forwardArgs.add(arg);
    } else if (arg.startsWith('-')) {
      forwardArgs.add(arg);
    } else {
      mainDart = arg;
    }
  }
  return (
    packagesPath: packagesPath,
    outputWasm: outputWasm,
    mainDart: mainDart,
    multiRoot: multiRoot,
    noSourceMaps: noSourceMaps,
    extraOptions: extraOptions,
    forwardArgs: forwardArgs,
  );
}

/// Compiles [mainDart] to [outputWasm] (plus its `.mjs` and optional source
/// map) with the wasm compiler's staging root mounted.
void _compileWasm({
  required String dartaotruntime,
  required String sdkBin,
  required String packagesPath,
  required String outputWasm,
  required String mainDart,
  required String? multiRoot,
  required bool noSourceMaps,
  required List<String> extraOptions,
  required List<String> forwardArgs,
}) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final outWasmFile = File(outputWasm)..parent.createSync(recursive: true);
  final tmpDir = Directory('${outWasmFile.parent.path}/_wasm_tmp')
    ..createSync(recursive: true);
  final tmpAbsPath = tmpDir.absolute.path;
  try {
    final cwdPath = Directory.current.absolute.path;
    final rootDirPath = multiRoot != null
        ? Directory(multiRoot).absolute.path
        : cwdPath;
    final normCwd = cwdPath.replaceAll(r'\', '/');
    final cwdPrefix = normCwd.endsWith('/') ? normCwd : '$normCwd/';
    final rewrittenPkgPath = '${tmpDir.path}/package_config.json';
    _rewritePackageConfig(packagesPath, normCwd, cwdPrefix, rewrittenPkgPath);

    final tmpWasm = '${tmpDir.path}/main.dart.wasm';
    final normMainDart = multiRoot != null
        ? _toAppSchemeRelPath(mainDart)
        : mainDart.replaceAll(r'\', '/');
    final wasmArgs = <String>[
      '$sdkBin/snapshots/dart2wasm_product.snapshot',
      ...extraOptions,
      '--packages=$rewrittenPkgPath',
      '--multi-root-scheme=org-dartlang-app',
      '--multi-root=$rootDirPath',
      '--wasm-opt=$sdkBin/utils/wasm-opt$exeSuffix',
      ...forwardArgs,
      'org-dartlang-app:///$normMainDart',
      tmpWasm,
    ];
    final res = Process.runSync(
      dartaotruntime,
      wasmArgs,
      environment: {
        ...Platform.environment,
        'TMPDIR': tmpAbsPath,
        'TMP': tmpAbsPath,
        'TEMP': tmpAbsPath,
      },
    );
    if (res.exitCode != 0) {
      stdout.write(res.stdout as String);
      stderr.write(res.stderr as String);
      exit(res.exitCode);
    }

    _copyWasmOutputs(outputWasm, tmpDir, noSourceMaps, tmpWasm);
  } finally {
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  }
}

/// Copies the compiled wasm, its `.mjs` loader and optional source map out of
/// the scratch directory.
void _copyWasmOutputs(
  String outputWasm,
  Directory tmpDir,
  bool noSourceMaps,
  String tmpWasm,
) {
  File(tmpWasm).copySync(outputWasm);

  final outputMjs = outputWasm.endsWith('.wasm')
      ? '${outputWasm.substring(0, outputWasm.length - 5)}.mjs'
      : '$outputWasm.mjs';
  File('${tmpDir.path}/main.dart.mjs').copySync(outputMjs);

  if (!noSourceMaps) {
    final tmpMap = File('$tmpWasm.map');
    if (tmpMap.existsSync()) {
      tmpMap.copySync('$outputWasm.map');
    }
  }
}

String _toAppSchemeUri(String path, String cwdPrefix) {
  var norm = path.replaceAll(r'\', '/');
  if (norm.startsWith(cwdPrefix)) {
    norm = norm.substring(cwdPrefix.length);
  }
  return 'org-dartlang-app:///${_toAppSchemeRelPath(norm)}';
}

/// Scrubs host-specific file URIs, temporary package_config paths, stage paths,
/// and compilation timestamps from dart2js output artifacts in [outDir].
///
/// Directory-wide scrubbing is only safe when no other action writes compiler
/// outputs into [outDir] concurrently: every scrub below is a read-modify-write
/// computed with only this action's temp paths, so scrubbing a sibling
/// action's file can overwrite its normalized result with a sorted-but-raw
/// copy. A compile that shares its output directory — the base and canvaskit
/// icon kernels both emit `<dill>.deps` into the same `bin` dir — must scrub
/// only its own files with [scrubDart2JsFile].
void scrubDart2JsOutputs(
  Directory outDir, {
  required String cwdPath,
  String? rootDirPath,
  String? tmpDirPath,
  String? packagesPath,
  String? rewrittenPkgPath,
}) {
  if (!outDir.existsSync()) return;

  final entries = outDir.listSync(recursive: true)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entries) {
    if (entity is File &&
        (entity.path.endsWith('.deps') ||
            entity.path.endsWith('.info.json') ||
            entity.path.endsWith('.map') ||
            entity.path.endsWith('.js'))) {
      scrubDart2JsFile(
        entity,
        cwdPath: cwdPath,
        rootDirPath: rootDirPath,
        tmpDirPath: tmpDirPath,
        packagesPath: packagesPath,
        rewrittenPkgPath: rewrittenPkgPath,
      );
    }
  }
}

/// Scrubs one compiler output file in place.
///
/// This is the per-file core of [scrubDart2JsOutputs], split out so an action
/// whose outputs share a directory with a concurrent action's outputs can
/// normalize exactly the files it owns and never read-modify-write a file
/// another action is still producing. The base and canvaskit icon kernels
/// (see the `--cfe-only` branch of [_runDart2Js]) compile concurrently into
/// the same `bin` dir: with a directory-wide scrub, a scrub that read the
/// sibling's `<dill>.deps` while raw and wrote it back after the sibling's
/// own scrub overwrote the normalized file with a sorted-but-still-raw copy —
/// a declared output differing per strategy (P-web-icon-dill-paths).
void scrubDart2JsFile(
  File file, {
  required String cwdPath,
  String? rootDirPath,
  String? tmpDirPath,
  String? packagesPath,
  String? rewrittenPkgPath,
}) {
  final prefixes = _scrubPrefixesFor(
    cwdPath: cwdPath,
    rootDirPath: rootDirPath,
    tmpDirPath: tmpDirPath,
    packagesPath: packagesPath,
    rewrittenPkgPath: rewrittenPkgPath,
  );
  final state = _ScrubState(file.readAsStringSync());
  _scrubPackageUris(state, prefixes);
  _scrubDirectoryUris(state, prefixes);
  _scrubSourcemapStageRefs(state, file, prefixes);
  _scrubInfoJson(state, file, prefixes);
  _scrubDepsFile(state, file);
  if (state.changed) {
    file.writeAsStringSync(state.content);
  }
}

/// The host-specific spellings `scrubDart2JsFile` normalizes away.
class _ScrubPrefixes {
  final String? pkgAppUri;
  final String? rewrittenPkgUri;
  final String? origPkgUri;
  final String? tmpDirUriPrefix;
  final String? stageUriPrefix;
  final String cwdUriPrefix;
  final String? stageDirName;
  final String? relStagePrefix;

  _ScrubPrefixes({
    required this.pkgAppUri,
    required this.rewrittenPkgUri,
    required this.origPkgUri,
    required this.tmpDirUriPrefix,
    required this.stageUriPrefix,
    required this.cwdUriPrefix,
    required this.stageDirName,
    required this.relStagePrefix,
  });
}

/// One compiler output file mid-scrub: its current [content] and whether any
/// replacement has changed it yet.
class _ScrubState {
  String content;
  bool changed = false;

  _ScrubState(this.content);

  /// Replaces every [from] with [to], recording the change.
  void replace(Pattern from, String to) {
    final next = content.replaceAll(from, to);
    if (next != content) {
      content = next;
      changed = true;
    }
  }
}

/// Computes the host-specific spellings of the cwd, staging root, temp dir
/// and package configs that compiler outputs may record.
_ScrubPrefixes _scrubPrefixesFor({
  required String cwdPath,
  required String? rootDirPath,
  required String? tmpDirPath,
  required String? packagesPath,
  required String? rewrittenPkgPath,
}) {
  final normCwd = cwdPath.replaceAll(r'\', '/');
  final cwdPrefix = normCwd.endsWith('/') ? normCwd : '$normCwd/';
  final normRootDir = rootDirPath?.replaceAll(r'\', '/');
  return _ScrubPrefixes(
    pkgAppUri: packagesPath != null
        ? _toAppSchemeUri(packagesPath, cwdPrefix)
        : null,
    rewrittenPkgUri: rewrittenPkgPath != null
        ? Uri.file(File(rewrittenPkgPath).absolute.path).toString()
        : null,
    origPkgUri: packagesPath != null
        ? Uri.file(File(packagesPath).absolute.path).toString()
        : null,
    tmpDirUriPrefix: tmpDirPath != null
        ? Uri.directory(tmpDirPath).toString()
        : null,
    stageUriPrefix: rootDirPath != null
        ? Uri.directory(rootDirPath).toString()
        : null,
    cwdUriPrefix: Uri.directory(cwdPath).toString(),
    stageDirName: rootDirPath != null ? _stageDirName(rootDirPath) : null,
    relStagePrefix: normRootDir != null && normRootDir.startsWith(cwdPrefix)
        ? _toAppSchemeRelPath(normRootDir.substring(cwdPrefix.length))
        : null,
  );
}

/// The staging root's own directory name, for source-map relative spellings.
String? _stageDirName(String rootDirPath) {
  final segments = Directory(
    rootDirPath,
  ).uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return segments.isNotEmpty ? segments.last : null;
}

/// Rewrites recorded package-config URIs to their stable app-scheme spelling.
void _scrubPackageUris(_ScrubState state, _ScrubPrefixes p) {
  if (p.pkgAppUri != null) {
    if (p.rewrittenPkgUri != null) {
      state.replace(p.rewrittenPkgUri!, p.pkgAppUri!);
    }
    if (p.origPkgUri != null) {
      state.replace(p.origPkgUri!, p.pkgAppUri!);
    }
  }
}

/// Rewrites recorded temp, staging-root and working-directory URIs to the
/// stable app-scheme root.
void _scrubDirectoryUris(_ScrubState state, _ScrubPrefixes p) {
  if (p.tmpDirUriPrefix != null) {
    state.replace(p.tmpDirUriPrefix!, 'org-dartlang-app:///');
  }
  if (p.stageUriPrefix != null) {
    state.replace(p.stageUriPrefix!, 'org-dartlang-app:///');
  }
  state.replace(p.cwdUriPrefix, 'org-dartlang-app:///');
  state.replace(
    RegExp(r'org-dartlang-app:///(?:\./)?bazel-out/[^/]+/(?:bin|genfiles)/'),
    'org-dartlang-app:///',
  );
  // A staged input is addressed as `<stage>/<rel>` under the same scheme,
  // so the same file is recorded with and without the `<stage>/` prefix
  // depending on which copy the frontend chose. Without this the depfile
  // differs per strategy even though every URI is already stable.
  state.replace(
    RegExp(r'org-dartlang-app:///.*?\.stage/'),
    'org-dartlang-app:///',
  );
}

/// Rewrites the staging directory's relative spellings in a source map.
void _scrubSourcemapStageRefs(
  _ScrubState state,
  File file,
  _ScrubPrefixes p,
) {
  if (file.path.endsWith('.map') &&
      p.stageDirName != null &&
      p.stageDirName!.isNotEmpty) {
    state.replace(
      RegExp('(?:\\.\\./)+${RegExp.escape(p.stageDirName!)}/'),
      'org-dartlang-app:///',
    );
  }
}

/// Normalizes a `.info.json` dump: relative output paths and compilation
/// timestamps.
void _scrubInfoJson(_ScrubState state, File file, _ScrubPrefixes p) {
  if (!file.path.endsWith('.info.json')) return;
  state.replace(
    RegExp(r'(?:\./)?bazel-out/[^/]+/(?:bin|genfiles)/'),
    '',
  );
  if (p.relStagePrefix != null &&
      p.relStagePrefix!.isNotEmpty &&
      state.content.contains('${p.relStagePrefix!}/')) {
    state.replace('${p.relStagePrefix!}/', '');
  }
  state.content = state.content
      .replaceAllMapped(
        RegExp(r'"compilationMoment":\s*"[^"]*"'),
        (_) => '"compilationMoment": "1970-01-01 00:00:00.000000"',
      )
      .replaceAllMapped(
        RegExp(
          r'"(compilationDuration|toJsonDuration|dumpInfoDuration)":\s*\d+',
        ),
        (m) => '"${m.group(1)}": 0',
      );
  state.changed = true;
}

/// Sorts, trims and dedupes a `.deps` depfile.
void _scrubDepsFile(_ScrubState state, File file) {
  if (!file.path.endsWith('.deps')) return;
  final lines =
      state.content
          .split('\n')
          .map((l) => l.trimRight())
          .where((l) => l.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  final normalized = lines.isEmpty ? '' : '${lines.join('\n')}\n';
  if (normalized != state.content) {
    state.content = normalized;
    state.changed = true;
  }
}

/// Builds the `dart2js` snapshot argv for a staged multi-root compile.
///
/// The js frontend resolves `org-dartlang-app:///` URIs against a `file:`
/// multi-root naming the per-action staging tree that holds both source and
/// generated inputs; the entrypoint and every package root are addressed as
/// URIs relative to that root, so the compile reads only declared inputs
/// whatever the strategy. The recorded library URIs stay stable relative URIs
/// with no sandbox or execroot absolute paths. Mirrors [_runDart2Wasm]'s
/// stable scheme, adapted to the js frontend's `file:`-rooted multi-root
/// (a plain path multi-root answers "Unknown scheme in uri").
List<String> buildDart2JsSnapshotArgs({
  required List<String> forwardArgs,
  required String rewrittenPkgPath,
  required String stageRootUri,
  required String normMainDart,
}) {
  final entryUri = 'org-dartlang-app:///$normMainDart';
  return <String>[
    for (final a in forwardArgs)
      if (a.startsWith('--packages=')) '--packages=$rewrittenPkgPath' else a,
    '--multi-root-scheme=org-dartlang-app',
    '--multi-root=$stageRootUri',
    entryUri,
  ];
}

/// The `file:` multi-root URI for the staging directory [multiRoot] names:
/// the Bazel action passes it exec-root-relative, so absolutize against the
/// working directory; an already-absolute or `file:` spelling is honored.
String stageRootUri(String multiRoot) {
  final norm = multiRoot.replaceAll(r'\', '/');
  if (norm.startsWith('file:')) {
    final uri = Uri.parse(norm);
    return Uri.directory(uri.toFilePath()).toString();
  }
  return Uri.directory(Directory(multiRoot).absolute.path).toString();
}

void _runDart2Js(List<String> args) {
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final sdkBin = File(Platform.resolvedExecutable).parent.path;
  final dartaotruntime = '$sdkBin/dartaotruntime$exeSuffix';

  final parsed = _parseDart2JsArgs(args);

  // `dart compile js --cfe-only` produces a kernel dill for const_finder
  // (the `app.dill` upstream runs icon tree-shaking on) rather than
  // JavaScript. Its `-o` names a file, not a directory, so the scratch
  // directory is a uniquely-named sibling of the output (the compiler already
  // writes `<dill>.deps` there, so the parent is the action's own output
  // tree); two icon kernels compile concurrently into one `bin` dir, hence
  // the timestamp/pid suffix. JS scrubbing is skipped: there is no JS to
  // scrub, and the `.deps` sibling is normalized below.
  final cfeOnly = parsed.forwardArgs.contains('--cfe-only');

  final cwdPath = Directory.current.absolute.path;
  final scratch = _dart2JsScratchDir(
    outJs: parsed.outJs,
    cfeOnly: cfeOnly,
    cwdPath: cwdPath,
  );
  final tmpDir = scratch.tmpDir;
  final tmpAbsPath = scratch.tmpAbsPath;
  String? rootDirPath;
  String? rewrittenPkgPath;
  try {
    final compiled = _compileDart2Js(
      dartaotruntime: dartaotruntime,
      sdkBin: sdkBin,
      tmpPath: tmpDir.path,
      tmpAbsPath: tmpAbsPath,
      multiRoot: parsed.multiRoot,
      packagesPath: parsed.packagesPath,
      mainDart: parsed.mainDart,
      forwardArgs: parsed.forwardArgs,
      cwdPath: cwdPath,
    );
    rootDirPath = compiled.rootDirPath;
    rewrittenPkgPath = compiled.rewrittenPkgPath;
  } finally {
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  }

  _scrubDart2JsResults(
    outJs: parsed.outJs,
    cfeOnly: cfeOnly,
    cwdPath: cwdPath,
    rootDirPath: rootDirPath,
    tmpAbsPath: tmpAbsPath,
    packagesPath: parsed.packagesPath,
    rewrittenPkgPath: rewrittenPkgPath,
  );
}

/// The `compile js` flags in [args].
({
  String? outJs,
  String? multiRoot,
  String? packagesPath,
  String? mainDart,
  List<String> forwardArgs,
})
_parseDart2JsArgs(List<String> args) {
  String? outJs;
  String? multiRoot;
  String? packagesPath;
  String? mainDart;
  final forwardArgs = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-o' && i + 1 < args.length) {
      outJs = args[++i];
      forwardArgs.addAll(['-o', outJs]);
    } else if (arg.startsWith('-o=')) {
      outJs = arg.substring('-o='.length);
      forwardArgs.add(arg);
    } else if (arg.startsWith('--multi-root=')) {
      multiRoot = arg.substring('--multi-root='.length);
    } else if (arg.startsWith('--packages=')) {
      packagesPath = arg.substring('--packages='.length);
      forwardArgs.add(arg);
    } else if (arg.startsWith('-')) {
      forwardArgs.add(arg);
    } else {
      mainDart = arg;
    }
  }
  return (
    outJs: outJs,
    multiRoot: multiRoot,
    packagesPath: packagesPath,
    mainDart: mainDart,
    forwardArgs: forwardArgs,
  );
}

/// The compile's scratch directory and its absolute path.
///
/// The icon-kernel scratch sits under the action's output directory when the
/// output is known (never the shared system temp): for a tree-artifact
/// output that is `outJs`'s own directory, for a dill output its parent dir.
({Directory tmpDir, String tmpAbsPath}) _dart2JsScratchDir({
  required String? outJs,
  required bool cfeOnly,
  required String cwdPath,
}) {
  final baseTmpParent = (cfeOnly || outJs == null)
      ? cwdPath
      : (File(outJs).parent..createSync(recursive: true)).path;
  final cfeScratchParent = cfeOnly && outJs != null
      ? (File(outJs).parent..createSync(recursive: true)).path
      : baseTmpParent;
  final tmpDir = Directory(
    cfeOnly
        ? '$cfeScratchParent/rules_flutter_dart2js_cfe_${DateTime.now().microsecondsSinceEpoch}_${pid}'
        : '$baseTmpParent/_dart2js_tmp',
  )..createSync(recursive: true);
  return (tmpDir: tmpDir, tmpAbsPath: tmpDir.absolute.path);
}

/// Runs the dart2js snapshot in [tmpPath]'s scratch, staging the package
/// config first when the compile mounts a multi-root; answers the staging
/// root and rewritten package config the output scrub needs.
({String? rootDirPath, String? rewrittenPkgPath}) _compileDart2Js({
  required String dartaotruntime,
  required String sdkBin,
  required String tmpPath,
  required String tmpAbsPath,
  required String? multiRoot,
  required String? packagesPath,
  required String? mainDart,
  required List<String> forwardArgs,
  required String cwdPath,
}) {
  String? rootDirPath;
  String? rewrittenPkgPath;
  List<String> jsArgs;
  if (multiRoot != null && packagesPath != null && mainDart != null) {
    rootDirPath = Uri.parse(stageRootUri(multiRoot)).toFilePath();
    final normCwd = cwdPath.replaceAll(r'\', '/');
    final cwdPrefix = normCwd.endsWith('/') ? normCwd : '$normCwd/';
    rewrittenPkgPath = '$tmpPath/package_config.json';
    _rewritePackageConfigForStage(
      packagesPath,
      normCwd,
      cwdPrefix,
      rewrittenPkgPath,
    );
    final relMain = _toAppSchemeRelPath(mainDart);
    jsArgs = buildDart2JsSnapshotArgs(
      forwardArgs: forwardArgs,
      rewrittenPkgPath: rewrittenPkgPath,
      stageRootUri: stageRootUri(multiRoot),
      normMainDart: relMain,
    );
  } else {
    jsArgs = <String>[
      ...forwardArgs,
      if (mainDart != null) mainDart,
    ];
  }

  final res = Process.runSync(
    dartaotruntime,
    [
      '$sdkBin/snapshots/dart2js_aot.dart.snapshot',
      '--invoker=dart_cli',
      ...jsArgs,
    ],
    environment: {
      ...Platform.environment,
      'TMPDIR': tmpAbsPath,
      'TMP': tmpAbsPath,
      'TEMP': tmpAbsPath,
    },
  );
  if (res.exitCode != 0) {
    stdout.write(res.stdout as String);
    stderr.write(res.stderr as String);
    exit(res.exitCode);
  }
  return (rootDirPath: rootDirPath, rewrittenPkgPath: rewrittenPkgPath);
}

/// Normalizes this action's own compiler outputs.
///
/// A directory-wide scrub for a regular JS output; only the `<dill>.deps`
/// sibling for a `--cfe-only` kernel, never the whole output directory: the
/// base and canvaskit icon kernels compile concurrently into the same `bin`
/// dir, and a directory-wide scrub is a read-modify-write of the sibling's
/// depfile with only this action's temp paths known. A scrub that read the
/// sibling's file while raw and writes it back after the sibling's own scrub
/// overwrites the normalized file with a sorted-but-still-raw copy — a
/// declared output that then differs per strategy (P-web-icon-dill-paths).
/// The `.dill` itself needs no scrubbing: the kernel records
/// workspace-relative library URIs.
void _scrubDart2JsResults({
  required String? outJs,
  required bool cfeOnly,
  required String cwdPath,
  required String? rootDirPath,
  required String tmpAbsPath,
  required String? packagesPath,
  required String? rewrittenPkgPath,
}) {
  if (outJs != null && !cfeOnly) {
    scrubDart2JsOutputs(
      File(outJs).parent,
      cwdPath: cwdPath,
      rootDirPath: rootDirPath,
      tmpDirPath: tmpAbsPath,
      packagesPath: packagesPath,
      rewrittenPkgPath: rewrittenPkgPath,
    );
  }
  if (outJs != null && cfeOnly) {
    final depsFile = File('$outJs.deps');
    if (depsFile.existsSync()) {
      scrubDart2JsFile(
        depsFile,
        cwdPath: cwdPath,
        rootDirPath: rootDirPath,
        tmpDirPath: tmpAbsPath,
        packagesPath: packagesPath,
        rewrittenPkgPath: rewrittenPkgPath,
      );
    }
  }
}
