/// Strips native libraries as the Android Gradle Plugin does.
///
/// A Gradle build never packages a native library as it finds it: the Android
/// Gradle Plugin's `strip<Variant>DebugSymbols` task runs the NDK's
/// `llvm-strip --strip-unneeded` over every merged native library, in every
/// build type, an app's and a library's (AAR) alike. This tool does the same.
/// `--strip-unneeded` keeps the dynamic symbol table, which is all the loader
/// and `dlsym` read.
///
/// It takes one of two inputs:
///
/// * A jar, with `--output`: the Flutter engine's `flutter.jar`, the
///   embedding's classes plus `lib/<abi>/libflutter.so` (and, in the arm64
///   debug engine, the Vulkan validation layer), all with full debug info. The
///   libraries leave the jar, stripped, into a compressed zip of their own
///   (`--libs`) that keeps their `lib/<abi>/` paths, and every other entry goes
///   to `--output`. `android_binary` builds one APK for every ABI its platforms
///   name, and takes the classes and resources of all of them from the first
///   alone, so a `lib/` entry inside a jar reaches the APK of the first ABI
///   only. A zip of libraries handed over as `AndroidNativeLibsInfo`, as an
///   AAR's are, reaches the APK of the ABI it was built for. A jar with no
///   native library is an error: the engine always has one, so finding none
///   means the input is not what the caller thinks it is.
/// * A zip of native libraries alone, without `--output`: an app's own
///   (`libapp.so`, its `native_deps` libraries and its code assets), each at
///   `lib/<abi>/<name>`. `--libs` is the same zip with every library
///   stripped, its entries stored uncompressed as the input's are. It may be
///   empty, as a debug app's with no native library is; an entry that is not
///   a native library is an error.
///
/// The tool has no package dependencies and runs with the bare Dart SDK. It
/// unpacks the input with `zipper`, strips each `lib/**.so` entry in place and
/// packs the results.
///
/// Usage:
///   dart strip_native_libs.dart --zipper <path> --strip <path>
///       --input <jar> --output <jar> --libs <zip>
///   dart strip_native_libs.dart --zipper <path> --strip <path>
///       --input <zip> --libs <zip>
///
/// With `--no-strip <reason>` in place of `--strip`, the rule had no strip
/// tool to give: the tool prints the reason and fails.
import 'dart:io';

/// The entries of [entries] that are native libraries: shared objects under
/// the jar's `lib/` directory, where `android_binary` takes them from.
List<String> nativeLibraries(Iterable<String> entries) => [
  for (final entry in entries)
    if (entry.startsWith('lib/') && entry.endsWith('.so')) entry,
];

/// The jar entry name of the file at [relativePath] in the unpacked jar,
/// whose path segments are joined by [separator]. Entry names always use
/// `/`; on Windows the unpacked paths use `\`.
String jarEntryName(String relativePath, String separator) =>
    relativePath.replaceAll(separator, '/');

/// The arguments the Android Gradle Plugin passes its strip tool.
List<String> stripArguments({required String input, required String output}) =>
    ['--strip-unneeded', '-o', output, input];

/// Why the entries of an input can't be stripped, or null if they can.
/// [libraries] is the native libraries among [entries]; [split] is whether the
/// input is a jar to split (`--output`) rather than a zip of libraries alone.
String? entriesProblem(
  List<String> entries,
  List<String> libraries, {
  required bool split,
}) {
  if (split) {
    return libraries.isEmpty ? 'has no lib/**.so entry to strip' : null;
  }
  final others = [
    for (final entry in entries)
      if (!libraries.contains(entry)) entry,
  ];
  return others.isEmpty
      ? null
      : 'is not a zip of native libraries alone: it has ${others.join(', ')}';
}

Map<String, String> _parseArgs(List<String> args) {
  const required = {'--zipper', '--input', '--libs'};
  const names = {...required, '--strip', '--no-strip', '--output'};
  final values = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final name = args[i];
    if (!names.contains(name) || i + 1 >= args.length) {
      throw ArgumentError('unexpected argument: $name');
    }
    values[name] = args[++i];
  }
  final missing = required.difference(values.keys.toSet());
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
  // The rule found no strip tool, and says why.
  if (options['--no-strip'] case final reason?) {
    stderr.writeln(reason);
    exitCode = 1;
    return;
  }
  final zipper = File(options['--zipper']!).absolute.path;
  final strip = File(
    options['--strip'] ?? (throw ArgumentError('missing --strip')),
  ).absolute.path;
  final input = File(options['--input']!).absolute.path;
  final output = switch (options['--output']) {
    final String path => File(path).absolute.path,
    null => null,
  };
  final libsZip = File(options['--libs']!).absolute.path;

  final scratch = Directory.systemTemp.createTempSync('strip_native_libs');
  try {
    final unpacked = Directory('${scratch.path}/jar')..createSync();
    // zipper takes `-d` relative to its working directory, absolute or not.
    await _run(zipper, ['x', input], workingDirectory: unpacked.path);

    final entries = [
      for (final file in unpacked.listSync(recursive: true).whereType<File>())
        jarEntryName(
          file.path.substring(unpacked.path.length + 1),
          Platform.pathSeparator,
        ),
    ]..sort();

    final libraries = nativeLibraries(entries);
    final problem = entriesProblem(entries, libraries, split: output != null);
    if (problem != null) {
      throw StateError('$input $problem');
    }
    for (final library in libraries) {
      final unstripped = '${unpacked.path}/$library';
      final stripped = '${scratch.path}/stripped.so';
      await _run(strip, stripArguments(input: unstripped, output: stripped));
      File(stripped).renameSync(unstripped);
    }

    if (output == null) {
      // Stored, as the app's libraries are, for the APK to keep them so.
      await _pack(
        zipper,
        libsZip,
        scratch.path,
        unpacked.path,
        libraries,
        compress: false,
      );
      return;
    }
    // Compressed, as an AAR's libraries are.
    await _pack(zipper, libsZip, scratch.path, unpacked.path, libraries);
    await _pack(
      zipper,
      output,
      scratch.path,
      unpacked.path,
      entries.where((e) => !libraries.contains(e)).toList(),
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

/// Packs [entries] of [root] into [zip], compressed unless [compress] is
/// false.
Future<void> _pack(
  String zipper,
  String zip,
  String scratch,
  String root,
  List<String> entries, {
  bool compress = true,
}) async {
  final argfile = File('$scratch/entries_${zip.hashCode}')
    ..writeAsStringSync(entries.map((e) => '$e=$root/$e\n').join());
  await _run(zipper, [compress ? 'cC' : 'c', zip, '@${argfile.path}']);
}
