/// Per-file code generator producing toJson() extensions.
///
/// A second generator shape (alongside simple_generator's toDebugString) so the
/// e2e covers more than one dart_codegen output format. Emits a `part of` file,
/// which is what the Flutter app (lib/user.dart) consumes — exercising the
/// kernel compile's co-location of a generated part with its source sibling.
///
/// Interface: dart json_generator.dart --input <file> --output <file>
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
    stderr.writeln('Usage: json_generator.dart --input <file> --output <file>');
    exit(1);
  }

  final source = File(inputPath).readAsStringSync();
  final classPattern = RegExp(r'class\s+(\w+)');
  final fieldPattern = RegExp(r'final\s+(\w+)\s+(\w+);');

  final buffer = StringBuffer();
  buffer.writeln('// GENERATED CODE - DO NOT MODIFY BY HAND');
  buffer.writeln();
  buffer.writeln("part of '${Uri.file(inputPath).pathSegments.last}';");
  buffer.writeln();

  for (final classMatch in classPattern.allMatches(source)) {
    final className = classMatch.group(1)!;
    final classStart = classMatch.start;
    final nextClass = classPattern.firstMatch(source.substring(classStart + 1));
    final classEnd =
        nextClass != null ? classStart + 1 + nextClass.start : source.length;
    final classBody = source.substring(classStart, classEnd);

    final fields = <(String, String)>[
      for (final m in fieldPattern.allMatches(classBody))
        (m.group(1)!, m.group(2)!),
    ];

    buffer.writeln('extension ${className}Json on $className {');
    buffer.writeln('  Map<String, dynamic> toJson() => {');
    for (final (_, name) in fields) {
      buffer.writeln("        '$name': $name,");
    }
    buffer.writeln('      };');
    buffer.writeln('}');
    buffer.writeln();
  }

  File(outputPath).writeAsStringSync(buffer.toString());
}
