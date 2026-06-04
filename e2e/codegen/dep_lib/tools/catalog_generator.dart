/// Per-file generator for the `dep_lib` package: emits a STANDALONE library
/// (not a `part of`) that the hand-written sibling imports. Interface
/// (dart_codegen): dart catalog_generator.dart --input <file> --output <file>
import 'dart:io';

void main(List<String> args) {
  String? inputPath;
  String? outputPath;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--input' && i + 1 < args.length) {
      inputPath = args[i + 1];
    } else if (args[i] == '--output' && i + 1 < args.length) {
      outputPath = args[i + 1];
    }
  }
  if (inputPath == null || outputPath == null) {
    stderr.writeln('Usage: catalog_generator.dart --input <file> --output <file>');
    exit(1);
  }

  final source = File(inputPath).readAsStringSync();
  // Discover the input's field names — editing the fields (a codegen INPUT
  // change) changes this generated standalone library, observable on reload.
  final fields = [
    for (final m in RegExp(r'final\s+\w+\s+(\w+);').allMatches(source))
      m.group(1)!,
  ];

  // A real library (top-level const list), not a `part of`, imported by the
  // hand-written sibling.
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
    ..writeln()
    ..writeln('const List<String> catalogFields = [')
    ..writeAll(fields.map((f) => "  '$f',\n"))
    ..writeln('];');

  File(outputPath).writeAsStringSync(buffer.toString());
}
