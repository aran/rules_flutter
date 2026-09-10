// Entrypoint for the vendored `flutter gen-l10n` generator.
//
// Upstream's CLI reads `l10n.yaml` and threads options through
// `FlutterCommand`. Neither exists here: the Bazel rule owns the configuration
// and passes it as flags, so `l10n.yaml` is never consulted. That is
// deliberate — Bazel must know the output file names at analysis time, and a
// yaml file read at action time cannot inform that.
//
// Paths are interpreted relative to the process's working directory, which for
// a Bazel action is the exec root. The rule passes the arb directory and the
// output directory as exec-root-relative paths, so the generator writes
// Bazel's declared outputs in place.

import 'dart:io' as io;

import 'package:file/local.dart';

import 'package:flutter_gen_l10n/src/base/logger.dart';
import 'package:flutter_gen_l10n/src/localizations/gen_l10n.dart';
import 'package:flutter_gen_l10n/src/localizations/localizations_utils.dart';

const _usage = '''
Usage: gen_l10n --arb-dir=DIR --output-dir=DIR [options]

Required:
  --arb-dir=DIR                  Directory holding the .arb files.
  --output-dir=DIR               Directory to write generated Dart into.

Optional:
  --project-dir=DIR              Base for relative paths (default ".").
  --template-arb-file=NAME       Template arb (default "app_en.arb").
  --output-localization-file=N   Base output file (default
                                 "app_localizations.dart").
  --output-class=NAME            Generated class (default "AppLocalizations").
  --preferred-supported-locales=L Comma-separated locale ordering.
  --header=TEXT                  Header comment for generated files.
  --header-file=PATH             File holding the header comment.
  --use-deferred-loading         Emit deferred imports (web code splitting).
  --no-nullable-getter           Make the `of(context)` getter non-nullable.
  --required-resource-attributes Require @-metadata on every message.
  --use-escaping                 Honour single-quote escaping in messages.
  --relax-syntax                 Accept upstream's relaxed ICU syntax.
  --use-named-parameters         Generate named rather than positional params.
  --suppress-warnings            Silence generator warnings.
''';

/// Flags that take no `=value`.
const _switches = <String>{
  'use-deferred-loading',
  'no-nullable-getter',
  'required-resource-attributes',
  'use-escaping',
  'relax-syntax',
  'use-named-parameters',
  'suppress-warnings',
};

Never _fail(String message) {
  io.stderr.writeln('gen_l10n: $message');
  io.exit(1);
}

Map<String, String> _parseArgs(List<String> argv) {
  final parsed = <String, String>{};
  for (final arg in argv) {
    if (!arg.startsWith('--')) {
      _fail('unexpected positional argument "$arg".\n$_usage');
    }
    final body = arg.substring(2);
    final eq = body.indexOf('=');
    if (eq < 0) {
      if (!_switches.contains(body)) {
        _fail('flag "--$body" requires a value (--$body=...).\n$_usage');
      }
      parsed[body] = 'true';
    } else {
      final name = body.substring(0, eq);
      if (_switches.contains(name)) {
        _fail('flag "--$name" takes no value.\n$_usage');
      }
      parsed[name] = body.substring(eq + 1);
    }
  }
  return parsed;
}

/// Everything the generator printed, for surfacing on stderr.
///
/// Warnings matter here: the generator reports untranslated messages that way,
/// and an adoption mid-translation would otherwise never see them.
String _drain(BufferLogger logger) => <String>[
  logger.errorText,
  logger.warningText,
  logger.statusText,
].where((String s) => s.trim().isNotEmpty).join();

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);

  final arbDir = args['arb-dir'];
  final outputDir = args['output-dir'];
  if (arbDir == null || outputDir == null) {
    _fail('--arb-dir and --output-dir are both required.\n$_usage');
  }

  const fs = LocalFileSystem();
  final logger = BufferLogger.test();

  final options = LocalizationOptions(
    arbDir: arbDir,
    outputDir: outputDir,
    templateArbFile: args['template-arb-file'],
    outputLocalizationFile: args['output-localization-file'],
    outputClass: args['output-class'],
    preferredSupportedLocales: args['preferred-supported-locales']
        ?.split(',')
        .where((String s) => s.isNotEmpty)
        .toList(),
    header: args['header'],
    headerFile: args['header-file'],
    useDeferredLoading: args.containsKey('use-deferred-loading'),
    requiredResourceAttributes: args.containsKey(
      'required-resource-attributes',
    ),
    nullableGetter: !args.containsKey('no-nullable-getter'),
    useEscaping: args.containsKey('use-escaping'),
    relaxSyntax: args.containsKey('relax-syntax'),
    useNamedParameters: args.containsKey('use-named-parameters'),
    suppressWarnings: args.containsKey('suppress-warnings'),
    // Never formatted: upstream shells out to the `dart` binary, which this
    // action does not have. The vendored generator raises rather than
    // silently skipping, so this must stay false. Check formatting of the
    // generated sources with a `dart_format_test` if you want it enforced.
    format: false,
  );

  try {
    await generateLocalizations(
      projectDir: fs.directory(args['project-dir'] ?? '.'),
      options: options,
      logger: logger,
      fileSystem: fs,
    );
  } on Object catch (e) {
    final output = _drain(logger);
    if (output.isNotEmpty) {
      io.stderr.write(output);
    }
    _fail('$e');
  }

  // Succeeded — still surface warnings, which are not failures but are the
  // only report of untranslated messages.
  final output = _drain(logger);
  if (output.isNotEmpty) {
    io.stderr.write(output);
  }
}
