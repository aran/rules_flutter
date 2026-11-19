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
/// * Zips of native libraries alone, without `--output`: an app's own
///   (`libapp.so`, its `native_deps` libraries and its code assets), or those
///   `aar_import` takes out of a Maven AAR, each at `lib/<abi>/<name>`. Each
///   `--input` pairs with the `--libs` in the same place: the same zip with
///   every library stripped, its entries stored uncompressed. One may be
///   empty, as a debug app's with no native library is and most AARs' are.
///   Another file under `lib/`, which an AAR may have in `jni/<abi>/`, is
///   packaged as it is, as the Android Gradle Plugin merges every file of
///   `jni/` and strips only the `.so` ones; an entry outside `lib/` is an
///   error.
///
/// The tool has no package dependencies and runs with the bare Dart SDK. It
/// unpacks each input with `zipper`, strips each `lib/**.so` entry in place
/// and packs the results.
///
/// Usage:
///   dart strip_native_libs.dart --zipper <path> --strip <path>
///       --input <jar> --output <jar> --libs <zip>
///   dart strip_native_libs.dart --zipper <path> --strip <path>
///       (--input <zip> --libs <zip>)...
///   dart strip_native_libs.dart --no-strip <reason> [<argument>]...
///
/// With `--no-strip`, the rule had no strip tool to give: the tool prints the
/// reason and fails, whatever else it was asked.
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

/// The arguments the Android Gradle Plugin passes its strip tool. A rule that
/// strips a loose library runs the strip tool itself, with the same ones
/// (android_strip.bzl).
List<String> stripArguments({required String input, required String output}) =>
    ['--strip-unneeded', '-o', output, input];

/// Why the entries of an input can't be stripped, or null if they can.
/// [libraries] is the native libraries among [entries]; [split] is whether the
/// input is a jar to split (`--output`) rather than a zip of what an APK
/// packages under `lib/`.
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
      if (!entry.startsWith('lib/')) entry,
  ];
  return others.isEmpty
      ? null
      : 'is not a zip of native libraries: it has ${others.join(', ')} '
            'outside lib/';
}

/// The tool's arguments, each name with its values in order: `--input` and
/// `--libs` once for each input, the others once. Throws an [ArgumentError]
/// naming what is wrong.
Map<String, List<String>> parseArgs(List<String> args) {
  const names = {'--zipper', '--strip', '--input', '--output', '--libs'};
  final values = <String, List<String>>{};
  for (var i = 0; i < args.length; i++) {
    final name = args[i];
    if (!names.contains(name) || i + 1 >= args.length) {
      throw ArgumentError('unexpected argument: $name');
    }
    values.putIfAbsent(name, () => []).add(args[++i]);
  }
  for (final name in ['--zipper', '--strip', '--input', '--libs']) {
    if (values[name] == null) throw ArgumentError('missing $name');
  }
  for (final name in ['--zipper', '--strip', '--output']) {
    if (values[name] case [_, _, ...]) {
      throw ArgumentError('$name given more than once');
    }
  }
  final inputs = values['--input']!.length;
  if (values['--libs']!.length != inputs) {
    throw ArgumentError('each --input needs one --libs');
  }
  if (values['--output'] != null && inputs != 1) {
    throw ArgumentError(
      '--output splits one jar, and $inputs inputs are given',
    );
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
  // The rule found no strip tool, and says why.
  final noStrip = args.indexOf('--no-strip');
  if (noStrip != -1 && noStrip + 1 < args.length) {
    stderr.writeln(args[noStrip + 1]);
    exitCode = 1;
    return;
  }
  final options = parseArgs(args);
  String absolute(String path) => File(path).absolute.path;
  final zipper = absolute(options['--zipper']!.single);
  final strip = absolute(options['--strip']!.single);
  final output = switch (options['--output']) {
    [final path] => absolute(path),
    _ => null,
  };
  final inputs = options['--input']!.map(absolute).toList();
  final libsZips = options['--libs']!.map(absolute).toList();

  final scratch = Directory.systemTemp.createTempSync('strip_native_libs');
  try {
    for (var i = 0; i < inputs.length; i++) {
      final work = Directory('${scratch.path}/$i')..createSync();
      await _strip(zipper, strip, inputs[i], libsZips[i], output, work.path);
    }
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

/// Strips the libraries of [input] into [libsZip] and, for a jar, packs its
/// other entries into [output], working in [scratch].
Future<void> _strip(
  String zipper,
  String strip,
  String input,
  String libsZip,
  String? output,
  String scratch,
) async {
  final unpacked = Directory('$scratch/jar')..createSync();
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
    final stripped = '$scratch/stripped.so';
    await _run(strip, stripArguments(input: unstripped, output: stripped));
    File(stripped).renameSync(unstripped);
  }

  if (output == null) {
    // Stored, as the app's libraries are, for the APK to keep them so, with
    // the other files under lib/ as they are.
    await _pack(
      zipper,
      libsZip,
      scratch,
      unpacked.path,
      entries,
      compress: false,
    );
    return;
  }
  // Compressed, as an AAR's libraries are.
  await _pack(zipper, libsZip, scratch, unpacked.path, libraries);
  await _pack(
    zipper,
    output,
    scratch,
    unpacked.path,
    entries.where((e) => !libraries.contains(e)).toList(),
  );
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
