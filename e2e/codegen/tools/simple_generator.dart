/// Per-file code generator for dart_codegen rule.
///
/// Interface: dart simple_generator.dart --input <path> --output <path>
///
/// Reads a .dart source file, finds class definitions and their fields,
/// and generates a companion file with toDebugString() extensions.
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
    stderr.writeln(
        'Usage: dart simple_generator.dart --input <file> --output <file>');
    exit(1);
  }

  final source = File(inputPath).readAsStringSync();
  final generated = generateForSource(source, inputPath);
  File(outputPath).writeAsStringSync(generated);
}

/// Parse classes and fields from [source] and return generated code.
String generateForSource(String source, String inputPath) {
  final classPattern = RegExp(r'^class\s+(\w+)', multiLine: true);
  final fieldPattern = RegExp(r'final\s+\w+\s+(\w+);');

  final buffer = StringBuffer();
  buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
  buffer.writeln();

  final fileName = Uri.file(inputPath).pathSegments.last;
  buffer.writeln("part of '$fileName';");
  buffer.writeln();

  for (final classMatch in classPattern.allMatches(source)) {
    final className = classMatch.group(1)!;

    // Extract the body between this class and the next (or end of file).
    final classStart = classMatch.start;
    final nextClass = classPattern.firstMatch(source.substring(classStart + 1));
    final classEnd =
        nextClass != null ? classStart + 1 + nextClass.start : source.length;
    final classBody = source.substring(classStart, classEnd);

    final fields = <String>[
      for (final m in fieldPattern.allMatches(classBody)) m.group(1)!,
    ];

    buffer.writeln('extension ${className}Debug on $className {');
    buffer.writeln('  String toDebugString() {');
    if (fields.isEmpty) {
      buffer.writeln("    return '$className()';");
    } else {
      final parts = fields.map((f) => '$f: \$$f').join(', ');
      buffer.writeln("    return '$className($parts)';");
    }
    buffer.writeln('  }');
    buffer.writeln('}');
    buffer.writeln();
  }

  return buffer.toString();
}
