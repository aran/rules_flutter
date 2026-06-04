/// Per-file generator for the `dep_part` package: emits a `part of` extension
/// with a `toJson()` for the first class in the input. Interface (dart_codegen):
///   dart settings_generator.dart --input <file> --output <file>
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
    stderr.writeln('Usage: settings_generator.dart --input <file> --output <file>');
    exit(1);
  }

  final source = File(inputPath).readAsStringSync();
  final className = RegExp(r'class\s+(\w+)').firstMatch(source)!.group(1)!;
  final fields = [
    for (final m in RegExp(r'final\s+(\w+)\s+(\w+);').allMatches(source))
      m.group(2)!,
  ];

  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
    ..writeln()
    ..writeln("part of '${Uri.file(inputPath).pathSegments.last}';")
    ..writeln()
    ..writeln('extension ${className}Json on $className {')
    ..writeln('  Map<String, dynamic> toJson() => {');
  for (final f in fields) {
    buffer.writeln("        '$f': $f,");
  }
  buffer
    ..writeln('      };')
    ..writeln('}');

  File(outputPath).writeAsStringSync(buffer.toString());
}
