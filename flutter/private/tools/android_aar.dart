/// Assembles an Android library archive (`.aar`), as the Android Gradle
/// Plugin lays one out: `AndroidManifest.xml`, `classes.jar`, `R.txt`,
/// `proguard.txt`, `res/`, `assets/` and `jni/<abi>/`.
///
/// rules_android's own `.aar` has no `jni/`, and an AAR of a Flutter module
/// is mostly native libraries and assets, so `flutter_android_aar` assembles
/// its archives with this. Run by a build action from the toolchain's Dart.
///
/// Usage (one argument per line in a params file named `@<file>`, or on the
/// command line):
///
///   dart android_aar.dart --output <aar> --manifest <xml>
///       [--r-txt <file>] [--classes <jar>]... [--proguard <file>]...
///       [--entry <name in the archive> <file>]...
///       [--tree <prefix in the archive> <directory>]...
///       [--flutter-assets <abi> <directory>]...
///       [--jni <abi> <library>]... [--jni-zip <abi> <zip>]...
///       [--jni-exclude <abi> <name>]...
///
/// `classes.jar` holds the entries of every `--classes` jar; two jars with
/// one class are an error. `--flutter-assets` names the `flutter_assets` of
/// each ABI's build. An AAR has one, at `assets/flutter_assets/`: the first
/// given. The others must be the same files with the same bytes, and are an
/// error when they are not, but for `kernel_blob.bin` (see
/// [sameFlutterAssets]) and `NativeAssetsManifest.json`, which holds each
/// ABI's code assets under its own key: the AAR's names those of every ABI
/// it has libraries for ([mergedNativeAssetsManifest]), as `flutter build
/// aar` writes it. Each `--jni` library goes to `jni/<abi>/<its name>`,
/// and each `lib/<abi>/<name>` entry of a `--jni-zip` (a
/// `flutter_android_bundle`'s native libraries, as an APK has them) to
/// `jni/<abi>/<name>`, but those a `--jni-exclude` of the ABI names: a
/// plugin's, which the plugin's own AAR carries. Excluding a name no
/// `--jni-zip` of the ABI holds is an error.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'native_assets_manifests.dart';
import 'zip_archive.dart';

/// A failure the build reports as it is.
class AarException implements Exception {
  AarException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the command line asks for.
class AarSpec {
  String? output;
  String? manifest;
  String? rTxt;
  final classes = <String>[];
  final proguard = <String>[];
  final entries = <(String, String)>[];
  final trees = <(String, String)>[];
  final flutterAssets = <(String, String)>[];
  final jni = <(String, String)>[];
  final jniZips = <(String, String)>[];
  final jniExcludes = <(String, String)>[];
}

/// Expands a leading `@<file>` into the file's lines.
List<String> expandParams(List<String> args) {
  if (args.length == 1 && args.single.startsWith('@')) {
    return File(
      args.single.substring(1),
    ).readAsLinesSync().where((l) => l.isNotEmpty).toList();
  }
  return args;
}

AarSpec parseArgs(List<String> args) {
  final spec = AarSpec();
  String next(int i) {
    if (i >= args.length) {
      throw AarException('${args[i - 1]} needs a value');
    }
    return args[i];
  }

  for (var i = 0; i < args.length; i++) {
    final flag = args[i];
    switch (flag) {
      case '--output':
        spec.output = next(++i);
      case '--manifest':
        spec.manifest = next(++i);
      case '--r-txt':
        spec.rTxt = next(++i);
      case '--classes':
        spec.classes.add(next(++i));
      case '--proguard':
        spec.proguard.add(next(++i));
      case '--entry':
        spec.entries.add((next(++i), next(++i)));
      case '--tree':
        spec.trees.add((next(++i), next(++i)));
      case '--flutter-assets':
        spec.flutterAssets.add((next(++i), next(++i)));
      case '--jni':
        spec.jni.add((next(++i), next(++i)));
      case '--jni-zip':
        spec.jniZips.add((next(++i), next(++i)));
      case '--jni-exclude':
        spec.jniExcludes.add((next(++i), next(++i)));
      default:
        throw AarException('unknown argument: $flag');
    }
  }
  if (spec.output == null || spec.manifest == null) {
    throw AarException('--output and --manifest are required');
  }
  return spec;
}

/// The files under [directory], by their `/`-separated path in it, sorted.
Map<String, File> treeFiles(String directory) {
  final root = Directory(directory);
  if (!root.existsSync()) {
    throw AarException('$directory is not a directory');
  }
  final prefix = root.path.endsWith('/') ? root.path : '${root.path}/';
  final files = <String, File>{};
  for (final entity in root.listSync(recursive: true, followLinks: true)) {
    if (entity is File) {
      files[entity.path.substring(prefix.length).replaceAll(r'\', '/')] =
          entity;
    }
  }
  return Map.fromEntries(
    files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The debug kernel. Each ABI's build compiles the same program, and the
/// kernels differ only in the record of the build each carries for
/// rules_flutter's dev tool (`rules_flutter.build_info`: which configuration's
/// assets back it), so they are not compared.
const _kernel = 'kernel_blob.bin';

/// The one native-assets manifest of an AAR: the code assets of each ABI of
/// [abis], each under its own target, from that ABI's build of [perAbi]
/// (`mergeNativeAssetsManifests`). A build that has none contributes
/// nothing; null when none has one.
///
/// Throws [AarException] when two builds disagree on the format or name one
/// target.
Uint8List? mergedNativeAssetsManifest(
  List<(String, String)> perAbi,
  Set<String> abis,
) {
  final manifests = [
    for (final (abi, dir) in perAbi)
      if (abis.contains(abi) &&
          File('$dir/$nativeAssetsManifestName').existsSync())
        (abi, File('$dir/$nativeAssetsManifestName').readAsStringSync()),
  ];
  if (manifests.isEmpty) return null;
  try {
    return utf8.encode(mergeNativeAssetsManifests(manifests));
  } on ManifestMergeException catch (e) {
    throw AarException('flutter_assets/${e.message}');
  }
}

/// The one `flutter_assets` tree of an AAR, the first of [perAbi], checked
/// against those of the other ABIs' builds.
///
/// Throws [AarException] naming the first file in which two ABIs differ.
Map<String, File> sameFlutterAssets(List<(String, String)> perAbi) {
  if (perAbi.isEmpty) return {};
  final (firstAbi, firstDir) = perAbi.first;
  final first = treeFiles(firstDir);
  for (final (abi, dir) in perAbi.skip(1)) {
    final other = treeFiles(dir);
    final names = {...first.keys, ...other.keys}.toList()..sort();
    for (final name in names) {
      final a = first[name];
      final b = other[name];
      if (a == null || b == null) {
        final (has, lacks) = a == null ? (abi, firstAbi) : (firstAbi, abi);
        throw AarException(
          'flutter_assets/$name is in the $has build and not in the $lacks '
          'build; an AAR has one flutter_assets for every ABI, so they must '
          'be the same',
        );
      }
      if (name != _kernel &&
          name != nativeAssetsManifestName &&
          !_sameBytes(a.readAsBytesSync(), b.readAsBytesSync())) {
        throw AarException(
          'flutter_assets/$name differs between the $firstAbi and $abi builds; '
          'an AAR has one flutter_assets for every ABI, so they must be the same',
        );
      }
    }
  }
  return first;
}

/// `classes.jar`: the entries of [jars], each class from one jar only.
Uint8List mergeJars(List<String> jars) {
  final entries = <String, ZipEntry>{};
  final from = <String, String>{};
  for (final jar in jars) {
    for (final entry in readZip(File(jar).readAsBytesSync())) {
      final seen = entries[entry.name];
      if (seen == null) {
        entries[entry.name] = entry;
        from[entry.name] = jar;
        continue;
      }
      if (entry.name.startsWith('META-INF/') ||
          _sameBytes(seen.bytes, entry.bytes)) {
        continue;
      }
      throw AarException(
        '${entry.name} is in both ${from[entry.name]} and $jar; '
        'classes.jar can hold one',
      );
    }
  }
  final names = entries.keys.toList()..sort();
  return writeZip([for (final n in names) entries[n]!]);
}

/// The entries of the AAR [spec] describes, in the order Gradle writes them.
List<ZipEntry> aarEntries(AarSpec spec) {
  final out = <ZipEntry>[
    ZipEntry('AndroidManifest.xml', File(spec.manifest!).readAsBytesSync()),
    ZipEntry('classes.jar', mergeJars(spec.classes)),
    ZipEntry(
      'R.txt',
      spec.rTxt == null ? const <int>[] : File(spec.rTxt!).readAsBytesSync(),
    ),
  ];
  if (spec.proguard.isNotEmpty) {
    final rules = BytesBuilder();
    for (final file in spec.proguard) {
      final bytes = File(file).readAsBytesSync();
      rules.add(bytes);
      if (bytes.isNotEmpty && bytes.last != 0x0a) rules.addByte(0x0a);
    }
    out.add(ZipEntry('proguard.txt', rules.takeBytes()));
  }
  final rest = <String, List<int>>{};
  void add(String name, List<int> bytes) {
    if (rest.containsKey(name) || out.any((e) => e.name == name)) {
      throw AarException('two files would be $name in the AAR');
    }
    rest[name] = bytes;
  }

  for (final (name, file) in spec.entries) {
    add(name, File(file).readAsBytesSync());
  }
  for (final (prefix, dir) in spec.trees) {
    for (final MapEntry(:key, :value) in treeFiles(dir).entries) {
      add('$prefix/$key', value.readAsBytesSync());
    }
  }
  // The ABIs the AAR has libraries for, whose code assets its manifest
  // names.
  final abis = {
    for (final (abi, _) in [...spec.jni, ...spec.jniZips]) abi,
  };
  final manifest = mergedNativeAssetsManifest(
    spec.flutterAssets,
    abis.isEmpty ? {for (final (abi, _) in spec.flutterAssets) abi} : abis,
  );
  for (final MapEntry(:key, :value) in sameFlutterAssets(
    spec.flutterAssets,
  ).entries) {
    add(
      'assets/flutter_assets/$key',
      key == nativeAssetsManifestName ? manifest! : value.readAsBytesSync(),
    );
  }
  for (final (abi, library) in spec.jni) {
    add('jni/$abi/${library.split('/').last}', File(library).readAsBytesSync());
  }
  final excluded = {
    for (final (abi, name) in spec.jniExcludes) 'jni/$abi/$name',
  };
  final zipped = <String>{};
  for (final (abi, zip) in spec.jniZips) {
    for (final entry in readZip(File(zip).readAsBytesSync())) {
      final prefix = 'lib/$abi/';
      if (!entry.name.startsWith(prefix)) {
        throw AarException(
          '$zip holds ${entry.name}, which is not a library of $abi',
        );
      }
      final name = 'jni/$abi/${entry.name.substring(prefix.length)}';
      zipped.add(name);
      if (!excluded.contains(name)) add(name, entry.bytes);
    }
  }
  final unmatched = excluded.difference(zipped).toList()..sort();
  if (unmatched.isNotEmpty) {
    throw AarException(
      'no --jni-zip holds ${unmatched.join(', ')}, which --jni-exclude names',
    );
  }
  final names = rest.keys.toList()..sort();
  return out..addAll([for (final n in names) ZipEntry(n, rest[n]!)]);
}

void main(List<String> args) {
  try {
    final spec = parseArgs(expandParams(args));
    File(spec.output!).writeAsBytesSync(writeZip(aarEntries(spec)));
  } on AarException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  } on FormatException catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  }
}
