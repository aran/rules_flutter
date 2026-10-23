/// Strips the native libraries inside a jar, leaving every other entry as it
/// was.
///
/// The Flutter engine ships as `flutter.jar`: the embedding's classes plus
/// `lib/<abi>/libflutter.so` (and, in the arm64 debug engine, the Vulkan
/// validation layer), all with full debug info. A Gradle build never packages
/// those as they are: the Android Gradle Plugin's `strip<Variant>DebugSymbols`
/// task runs the NDK's `llvm-strip --strip-unneeded` over every merged native
/// library, in every build type. This tool does the same for the jar
/// `flutter_android_engine` imports, so the APK carries what a Gradle-built
/// one does. `--strip-unneeded` keeps the dynamic symbol table, which is all
/// the loader and `dlsym` read.
///
/// The tool has no package dependencies and runs with the bare Dart SDK. It
/// unpacks the jar with `zipper`, strips each `lib/**.so` entry in place, and
/// packs every entry back into a new jar. A jar with no native library is an
/// error: the engine always has one, so finding none means the input is not
/// what the caller thinks it is.
///
/// Usage:
///   dart strip_native_libs.dart --zipper <path> --strip <path>
///       --input <jar> --output <jar>
import 'dart:io';

import 'chmod.dart' as chmodlib;

/// The entries of [entries] that are native libraries: shared objects under
/// the jar's `lib/` directory, where `android_binary` takes them from.
List<String> nativeLibraries(Iterable<String> entries) => [
  for (final entry in entries)
    if (entry.startsWith('lib/') && entry.endsWith('.so')) entry,
];

/// The arguments the Android Gradle Plugin passes its strip tool.
List<String> stripArguments({required String input, required String output}) =>
    ['--strip-unneeded', '-o', output, input];

Map<String, String> _parseArgs(List<String> args) {
  const names = {'--zipper', '--strip', '--input', '--output'};
  final values = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final name = args[i];
    if (!names.contains(name) || i + 1 >= args.length) {
      throw ArgumentError('unexpected argument: $name');
    }
    values[name] = args[++i];
  }
  final missing = names.difference(values.keys.toSet());
  if (missing.isNotEmpty) {
    throw ArgumentError('missing ${missing.join(', ')}');
  }
  return values;
}

Future<void> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
}

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  final zipper = File(options['--zipper']!).absolute.path;
  final strip = File(options['--strip']!).absolute.path;
  final input = File(options['--input']!).absolute.path;
  final outputFile = File(options['--output']!).absolute;
  outputFile.parent.createSync(recursive: true);
  final output = outputFile.path;

  final scratch = Directory('$output.scratch')..createSync(recursive: true);
  try {
    final unpacked = Directory('${scratch.path}/jar')..createSync();
    // zipper takes `-d` relative to its working directory, absolute or not.
    await _run(zipper, ['x', input], workingDirectory: unpacked.path);

    final entries = [
      for (final file in unpacked.listSync(recursive: true).whereType<File>())
        file.path.substring(unpacked.path.length + 1),
    ]..sort();

    final libraries = nativeLibraries(entries);
    if (libraries.isEmpty) {
      throw StateError('$input has no lib/**.so entry to strip');
    }
    for (final library in libraries) {
      final unstripped = '${unpacked.path}/$library';
      final stripped = '${scratch.path}/stripped.so';
      await _run(strip, stripArguments(input: unstripped, output: stripped));
      File(stripped).renameSync(unstripped);
    }

    // Normalize file mode bits in the unpacked tree before repacking, so host
    // stat.mode bits (including umask) never leak into the output jar. Only
    // the executable bit of each entry is honoured (0755 vs 0644), matching
    // xtool_pack.dart.
    for (final entry in entries) {
      final file = File('${unpacked.path}/$entry');
      final mode = file.statSync().mode;
      final normalized = (mode & 0x49) != 0 ? 0x1ed : 0x1a4;
      chmodlib.chmodFile(file.path, normalized);
    }

    final argfile = File('${scratch.path}/entries')
      ..writeAsStringSync(
        entries.map((e) => '$e=${unpacked.path}/$e\n').join(),
      );
    await _run(zipper, ['cC', output, '@${argfile.path}']);
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
