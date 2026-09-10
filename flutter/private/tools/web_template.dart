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

  final builtins = _resolveBuiltins(
    (file['builtins'] as Map<String, dynamic>?) ?? {},
    priorOutputs,
  );

  if (devLoopGuard) {
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

  return result.replaceAllMapped(_variablePattern, (match) {
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
  });
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
