/// Aggregate code generator for dart_aggregate_codegen rule.
///
/// Interface (dart_aggregate_codegen contract): the primary source arrives as
/// `--input <exec>`; each additional source arrives as
/// `--input-asset-extra <exec>|<asset>`. The single output is `--output <path>`.
///
/// Reads all source files, finds every class definition across them, and
/// generates a single registry file listing every model class.
import 'dart:io';

void main(List<String> args) {
  final inputPaths = <String>[];
  String? outputPath;

  for (var i = 0; i + 1 < args.length; i++) {
    final value = args[i + 1];
    switch (args[i]) {
      case '--input':
        inputPaths.add(value);
        i++;
      case '--input-asset-extra':
        // Extra sources are passed as `<exec>|<asset>`; take the exec path.
        inputPaths.add(value.split('|').first);
        i++;
      case '--output':
        outputPath = value;
        i++;
    }
  }

  if (inputPaths.isEmpty || outputPath == null) {
    stderr.writeln('Usage: aggregate_generator.dart --input <file> '
        '[--input-asset-extra <exec>|<asset>...] --output <file>');
    exit(1);
  }

  final classPattern = RegExp(r'^class\s+(\w+)', multiLine: true);
  final allClasses = <String>[];

  for (final path in inputPaths) {
    final source = File(path).readAsStringSync();
    for (final match in classPattern.allMatches(source)) {
      allClasses.add(match.group(1)!);
    }
  }

  allClasses.sort();

  final buffer = StringBuffer();
  buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
  buffer.writeln('// Aggregate registry generated from ${inputPaths.length} source file(s).');
  buffer.writeln();
  buffer.writeln('/// All model classes discovered by the aggregate generator.');
  buffer.writeln('const List<String> registeredModels = [');
  for (final cls in allClasses) {
    buffer.writeln("  '$cls',");
  }
  buffer.writeln('];');
  buffer.writeln();
  buffer.writeln('/// Number of registered model classes.');
  buffer.writeln('const int modelCount = ${allClasses.length};');
  buffer.writeln();

  File(outputPath).writeAsStringSync(buffer.toString());
}
