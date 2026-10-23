// Entrypoint for the vendored `flutter gen-l10n` generator.
//
// Upstream's CLI reads `l10n.yaml` and threads options through
// `FlutterCommand`. Neither exists here: the Bazel rule owns the configuration
// and passes it as flags, so `l10n.yaml` is never consulted. That is
// deliberate — Bazel must know the output file names at analysis time, and a
// yaml file read at action time cannot inform that.
//
// Paths are interpreted relative to the process's working directory, which for
// a Bazel action is the exec root. The rule passes each declared `.arb` file
// via `--arb-file=PATH` and the output directory as an exec-root-relative path.
// Only the declared `--arb-file` inputs are staged into an in-memory file
// system before invoking `generateLocalizations`, so `AppResourceBundleCollection`
// never scans `--arb-dir` on the host file system or ingests undeclared `.arb`
// files sitting in the same directory.

import 'dart:io' as io;

import 'package:file/local.dart';
import 'package:file/memory.dart';

import 'package:flutter_gen_l10n/src/base/logger.dart';
import 'package:flutter_gen_l10n/src/localizations/gen_l10n.dart';
import 'package:flutter_gen_l10n/src/localizations/localizations_utils.dart';

const _usage = '''
Usage: gen_l10n --arb-file=PATH [--arb-file=PATH ...] --output-dir=DIR [options]

Required:
  --arb-file=PATH                Declared .arb input file (repeatable).
  --output-dir=DIR               Directory to write generated Dart into.

Optional:
  --arb-dir=DIR                  Logical directory holding the .arb files.
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

({Map<String, String> options, List<String> arbFiles}) _parseArgs(
  List<String> argv,
) {
  final parsed = <String, String>{};
  final arbFiles = <String>[];
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
      final value = body.substring(eq + 1);
      if (name == 'arb-file') {
        if (value.isEmpty) {
          _fail('flag "--arb-file" requires a non-empty path.\n$_usage');
        }
        arbFiles.add(value);
      } else {
        parsed[name] = value;
      }
    }
  }
  return (options: parsed, arbFiles: arbFiles);
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
  final parsed = _parseArgs(argv);
  final args = parsed.options;
  final arbFiles = parsed.arbFiles;

  final outputDir = args['output-dir'];
  if (outputDir == null || outputDir.isEmpty || arbFiles.isEmpty) {
    _fail('--output-dir and at least one --arb-file are required.\n$_usage');
  }

  const localFs = LocalFileSystem();
  final memFs = MemoryFileSystem.test();
  final logger = BufferLogger.test();

  final projectDirPath = args['project-dir'] ?? '.';
  final setup = _localizationSetup(
    args: args,
    arbFiles: arbFiles,
    localFs: localFs,
  );
  final options = setup.options;
  final arbDir = setup.arbDir;

  try {
    final memProjectDir = memFs.directory(projectDirPath)
      ..createSync(recursive: true);
    final memInputDir = memFs.directory(
      memFs.path.join(memProjectDir.path, arbDir),
    )..createSync(recursive: true);

    _stageArbInputs(
      arbFiles: arbFiles,
      projectDirPath: projectDirPath,
      localFs: localFs,
      memFs: memFs,
      memInputPath: memInputDir.path,
    );
    _stageHeaderFile(
      headerFile: args['header-file'],
      projectDirPath: projectDirPath,
      arbDir: arbDir,
      localFs: localFs,
      memFs: memFs,
      memInputPath: memInputDir.path,
    );

    final generator = await generateLocalizations(
      projectDir: memProjectDir,
      options: options,
      logger: logger,
      fileSystem: memFs,
    );

    _writeGeneratorOutputs(
      outputFileList: generator.outputFileList,
      projectDirPath: projectDirPath,
      outputDir: outputDir,
      localFs: localFs,
      memFs: memFs,
    );
  } on Object catch (e) {
    _reportGeneratorOutput(logger);
    _fail('$e');
  }

  // Succeeded — still surface warnings, which are not failures but are the
  // only report of untranslated messages.
  _reportGeneratorOutput(logger);
}

/// Surfaces everything the generator printed on stderr.
void _reportGeneratorOutput(BufferLogger logger) {
  final output = _drain(logger);
  if (output.isNotEmpty) {
    io.stderr.write(output);
  }
}

/// The generator options for [args] and the logical `.arb` directory.
///
/// [arbDir] defaults to the first `--arb-file`'s directory, as the rule
/// passes each declared input explicitly rather than a directory to scan.
({LocalizationOptions options, String arbDir}) _localizationSetup({
  required Map<String, String> args,
  required List<String> arbFiles,
  required LocalFileSystem localFs,
}) {
  final rawArbDir = args['arb-dir'];
  final arbDir = (rawArbDir != null && rawArbDir.isNotEmpty)
      ? rawArbDir
      : localFs.path.dirname(arbFiles.first);

  final outputDir = args['output-dir']!;
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
    // silently skipping, so this must stay false. Nothing else formats them
    // either: rules_dart's format check covers hand-written files only.
    format: false,
  );
  return (options: options, arbDir: arbDir);
}

/// Copies the generator's in-memory outputs into the real [outputDir].
void _writeGeneratorOutputs({
  required List<String> outputFileList,
  required String projectDirPath,
  required String outputDir,
  required LocalFileSystem localFs,
  required MemoryFileSystem memFs,
}) {
  final localOutputDir = localFs.directory(
    localFs.path.join(projectDirPath, outputDir),
  )..createSync(recursive: true);
  for (final outPath in outputFileList) {
    final memFile = memFs.file(outPath);
    final dstFile = localOutputDir.childFile(memFile.basename);
    if (dstFile.existsSync()) {
      dstFile.deleteSync();
    }
    dstFile.writeAsBytesSync(memFile.readAsBytesSync());
  }
}

/// Stages the declared `--arb-file` inputs into the in-memory [memInputPath].
///
/// Only the declared inputs are staged, so `AppResourceBundleCollection` never
/// scans `--arb-dir` on the host file system or ingests undeclared `.arb`
/// files sitting in the same directory.
void _stageArbInputs({
  required List<String> arbFiles,
  required String projectDirPath,
  required LocalFileSystem localFs,
  required MemoryFileSystem memFs,
  required String memInputPath,
}) {
  final memInputDir = memFs.directory(memInputPath);
  final stagedSources = <String, String>{};
  for (final arbPath in arbFiles) {
    var srcFile = localFs.file(arbPath);
    if (!srcFile.existsSync() && projectDirPath != '.') {
      srcFile = localFs.file(localFs.path.join(projectDirPath, arbPath));
    }
    if (!srcFile.existsSync()) {
      _fail('arb file "$arbPath" does not exist.');
    }
    final basename = localFs.path.basename(arbPath);
    final resolvedPath = localFs.path.normalize(srcFile.path);
    final previous = stagedSources[basename];
    if (previous != null && previous != resolvedPath) {
      _fail(
        'multiple --arb-file inputs share basename "$basename": '
        '"$previous" and "$arbPath".',
      );
    }
    stagedSources[basename] = resolvedPath;
    memInputDir.childFile(basename).writeAsBytesSync(srcFile.readAsBytesSync());
  }
}

/// Stages the `--header-file` input next to the staged `.arb` files, when it
/// names a file that exists.
void _stageHeaderFile({
  required String? headerFile,
  required String projectDirPath,
  required String arbDir,
  required LocalFileSystem localFs,
  required MemoryFileSystem memFs,
  required String memInputPath,
}) {
  if (headerFile == null) return;
  var localHeader = localFs.file(
    localFs.path.join(projectDirPath, arbDir, headerFile),
  );
  if (!localHeader.existsSync()) {
    localHeader = localFs.file(localFs.path.join(projectDirPath, headerFile));
  }
  if (localHeader.existsSync()) {
    final memHeader = memFs.directory(memInputPath).childFile(headerFile);
    memHeader.parent.createSync(recursive: true);
    memHeader.writeAsBytesSync(localHeader.readAsBytesSync());
  }
}
