/// The code assets an app ships, and where each lives in its bundle.
///
/// What ships is decided by rules_dart's program-assets operation: a package's
/// link hook chooses among its code assets in a release build, and the
/// program-assets file an action is handed (`program_assets_action_args()`)
/// records the choice. Analysis time knows only the candidates, so every step
/// that places a library or names it in the app's native-assets manifest
/// reads that file, through [ProgramCodeAssets],
/// and places it through [CodeAssetPlacement], which holds each platform's
/// convention once.
///
/// The tool has no package dependencies and runs with the bare Dart SDK.
/// rules_dart's reference reader (`@rules_dart//dart/program_assets`) is a
/// package, so this carries its own, checked against rules_dart's
/// conformance fixture.
///
/// Usage:
///   dart code_assets.dart place --program-assets=<file> --os <os>
///       [--abi <abi>] --output <dir> [--library <file>]... [--copy <file>]...
///     Copies each shipped library, and each `--library` (which always ships),
///     into `<dir>`, at its path in the platform's code-asset directory. A
///     shipped library with a `--copy` of the same file name (one stripped
///     for the bundle) is placed from the copy.
///     On Linux, each library's runpath entries relative to `$ORIGIN` become
///     one `$ORIGIN`, the bundle's `lib/`.
///   dart code_assets.dart android-libs --program-assets=<file> --abi <abi>
///       --output <zip> [--library <file>]... [--library-as <name> <file>]...
///     Writes the APK's native libraries, `lib/<abi>/<name>` entries stored
///     uncompressed: each code asset that ships, each `--library` (which
///     always ships) and each `--library-as` under the name given.
///   dart code_assets.dart ios-dropped-frameworks --program-assets=<file>
///       --output <file> [--conflict <label>]
///       (--framework <file name> <framework name>)...
///     Writes the frameworks of the code assets a link hook dropped, one
///     `<name>.framework` a line, which an iOS app carries for
///     `ios_code_asset_post_processor.dart` to remove. With `--conflict` (the
///     app's own `ipa_post_processor`, which displaces that one), a list
///     that is not empty fails.
///   dart code_assets.dart manifest --program-assets=<file> --os <os>
///       [--target <os>_<arch>] --output <file>
///       [--framework <file name> <framework name>]...
///     Writes the app's native-assets manifest (`nativeAssetsManifest`).
///   dart code_assets.dart merge-manifests --output <file>
///       (--manifest <abi> <file>)...
///     Writes the one native-assets manifest of an APK of several ABIs, each
///     ABI's build's under its own target (`mergeNativeAssetsManifests`).
///   dart code_assets.dart xcframeworks --output <dir>
///       (--slice <id> --program-assets=<file>)...
///       (--candidate <file name> <xcframework>)... [--always <xcframework>]...
///     Copies the xcframework of each code asset the first slice (the
///     device build) ships into `<dir>`, after checking the other slices
///     ship nothing it does not, and each `--always`.
///   dart code_assets.dart package-swift --template <file> --output <file>
///       [--binary <name>]... [--binaries-in <dir>]...
///     Writes the add-to-app `Package.swift` from `<template>`, a binary
///     target for each `--binary` and each xcframework in a `--binaries-in`
///     directory (the code assets that ship, known only once built).
library;

import 'dart:convert';
import 'dart:io';

import 'apple_frameworks.dart' show copyBundle;
import 'assemble_directory.dart' show copyFile;
import 'elf_runpath.dart' show ElfDynamic, bundledRunpath;
import 'native_assets_manifests.dart'
    show ManifestMergeException, mergeNativeAssetsManifests;
import 'zip_archive.dart' show ZipEntry, writeZip;

/// The name and version of the program-assets line format this reads.
const programAssetsFormat = 'rules_dart_program_assets/1';

/// One code asset of a program.
final class CodeAsset {
  CodeAsset(this.id, this.linkMode, this.file, this.fileName, this.uri);

  /// `package:<package>/<name>`.
  final String id;

  /// Upstream's link mode type: `dynamic_loading_bundle`,
  /// `dynamic_loading_system`, `dynamic_loading_process`,
  /// `dynamic_loading_executable` or `static`.
  final String linkMode;

  /// The path of its library, or null: an asset without one, or a file that
  /// holds the code assets by name.
  final String? file;

  /// The file name of its library, or null for an asset without one.
  final String? fileName;

  /// How the runtime finds it, for `dynamic_loading_system`, or null.
  final String? uri;

  /// Whether the app's bundle carries its library.
  bool get bundled => linkMode == 'dynamic_loading_bundle' && fileName != null;
}

/// A program's code assets, as a program-assets file holds them.
final class ProgramCodeAssets {
  ProgramCodeAssets._(this.shipped, this.candidates);

  /// What ships, sorted by id.
  final List<CodeAsset> shipped;

  /// What could have shipped: every code asset that ships unconditionally,
  /// and every one a link hook chose among, kept or not.
  final List<CodeAsset> candidates;

  /// The file names of the bundled libraries that ship.
  Set<String> get shippedFileNames => {
    for (final asset in shipped)
      if (asset.bundled) asset.fileName!,
  };

  /// The file names of the bundled libraries a link hook dropped. A library
  /// that serves another id that ships is not among them.
  Set<String> get droppedFileNames => {
    for (final asset in candidates)
      if (asset.bundled) asset.fileName!,
  }.difference(shippedFileNames);

  /// Reads [path], a file in rules_dart's program-assets line format that
  /// holds the code assets (`code` or `code-names`). Its `exec` paths are
  /// relative to [base], the working directory when null, as are those of
  /// the selection files it names. Data records are passed over.
  static ProgramCodeAssets read(String path, {String? base}) {
    String resolve(String p) =>
        base == null || p.startsWith('/') ? p : '$base/$p';
    final lines = File(path).readAsLinesSync();
    var at = 0;
    String next(String what) {
      if (at >= lines.length) {
        throw FormatException('$path: ends before $what');
      }
      return lines[at++];
    }

    void tag(String expected) {
      final line = next('`$expected`');
      if (line != expected) {
        throw FormatException('$path: expected `$expected`, got `$line`');
      }
    }

    tag('--format');
    final format = next('the format');
    if (format != programAssetsFormat) {
      throw FormatException(
        '$path: format `$format`, not `$programAssetsFormat`',
      );
    }
    tag('--paths');
    final paths = next('the paths');
    if (paths != 'exec') {
      throw FormatException(
        '$path: `--paths $paths`; only `exec` is read here',
      );
    }
    tag('--holds');
    final holds = next('what it holds');
    final parts = holds.split(' ');
    if (holds.isEmpty ||
        parts.toSet().length != parts.length ||
        parts.any((p) => !const {'data', 'code', 'code-names'}.contains(p)) ||
        (parts.contains('code') && parts.contains('code-names'))) {
      throw FormatException('$path: `--holds` `$holds` is not a valid view');
    }
    final libraries = parts.contains('code');
    if (!libraries && !parts.contains('code-names')) {
      throw FormatException(
        '$path holds `$holds`, not the code assets; pass a `code` view to '
        '`program_assets_action_args()`',
      );
    }
    final holdsData = parts.contains('data');
    void holding(String record, bool held) {
      if (!held) {
        throw FormatException(
          '$path: a `$record` record in a file that holds `$holds`',
        );
      }
    }

    String? optional(String line) => line.isEmpty ? null : line;
    CodeAsset codeAsset() {
      final id = next('an id');
      final linkMode = next('a link mode');
      final library = optional(next('a library'));
      final uri = optional(next('a uri'));
      if (!libraries && library != null && library.contains('/')) {
        throw FormatException(
          '$path: `$id` names its library by a path, `$library`, in a file '
          'that holds the code assets by name',
        );
      }
      return CodeAsset(
        id,
        linkMode,
        libraries && library != null ? resolve(library) : null,
        library?.substring(library.lastIndexOf('/') + 1),
        uri,
      );
    }

    final shipped = <String, CodeAsset>{};
    final candidates = <CodeAsset>[];
    void ship(CodeAsset asset) {
      if (shipped.containsKey(asset.id)) {
        throw FormatException('$path names code asset `${asset.id}` twice');
      }
      shipped[asset.id] = asset;
    }

    while (at < lines.length) {
      switch (next('a record')) {
        case '--data-asset':
          holding('--data-asset', holdsData);
          next('an id');
          next('a file');
        case '--link-data':
          holding('--link-data', holdsData);
          next('a package');
          next('a directory');
        case '--code-asset':
          final asset = codeAsset();
          candidates.add(asset);
          ship(asset);
        case '--link-code':
          final package = next('a package');
          final selection = resolve(next('a selection'));
          final chosenAmong = <String, CodeAsset>{};
          while (at < lines.length && lines[at] == '--candidate') {
            at++;
            final candidate = codeAsset();
            chosenAmong[candidate.id] = candidate;
            candidates.add(candidate);
          }
          if (chosenAmong.isEmpty) {
            throw FormatException(
              '$path: the link hook of `$package` has a selection and no '
              'code assets it chose among',
            );
          }
          for (final id in File(selection).readAsLinesSync()) {
            if (id.isEmpty) continue;
            final kept = chosenAmong[id];
            if (kept == null) {
              throw FormatException(
                '$path: the link hook of `$package` kept `$id`, which is not '
                'one of the code assets it chose among',
              );
            }
            ship(kept);
          }
        case final other:
          throw FormatException('$path: unknown record `$other`');
      }
    }
    return ProgramCodeAssets._([
      for (final id in shipped.keys.toList()..sort()) shipped[id]!,
    ], candidates);
  }
}

/// The framework each bundled library of an iOS app ships in, by the
/// library's file name: `<name>` of `<name>.framework/<name>`.
///
/// Analysis names them (`ios_framework_names` in `flutter_native_assets.bzl`,
/// flutter_tools' `frameworkUri` over the app's libraries in file-name order,
/// a name already taken gaining `1`, `2`, ...) and hands the names to every
/// action that needs one as `--framework <file name> <name>` pairs.
final class IosFrameworks {
  IosFrameworks(this.byFileName);

  /// The pairs of `--framework <file name> <name>` in [args].
  factory IosFrameworks.fromArgs(List<String> args) => IosFrameworks({
    for (var i = 0; i < args.length - 2; i++)
      if (args[i] == '--framework') args[i + 1]: args[i + 2],
  });

  /// The framework name of each library, by its file name.
  final Map<String, String> byFileName;

  /// The framework [fileName] ships in.
  String of(String fileName) =>
      byFileName[fileName] ??
      (throw StateError(
        'no framework is named for $fileName, a library the iOS app '
        'bundles; its build passes one `--framework` for every library',
      ));
}

/// The path of the library [fileName] in [os]'s code-asset directory
/// ([CodeAssetPlacement.directory]): its file name, or on iOS a framework of
/// its own, named by [frameworks].
String codeAssetPathInDirectory(
  String os,
  String fileName, {
  IosFrameworks? frameworks,
}) {
  if (os != 'ios') return fileName;
  if (frameworks == null) {
    throw ArgumentError('an iOS code-asset path needs the framework names');
  }
  final name = frameworks.of(fileName);
  return '$name.framework/$name';
}

/// The native-assets manifest of an app for [os] (Dart's `<os>_<arch>`
/// [target]): each code asset that ships, by id, to how the engine loads it.
/// A bundled library is named by its path in the platform's code-asset
/// directory, which the engine resolves it against; on iOS by its framework's
/// install name, `@rpath/<name>.framework/<name>`, as flutter_tools 3.50
/// names it. The name the VM hands `dlopen` must be the install name: under
/// any other, dyld knows the library only as the file on disk, and a rebuild
/// that replaces the file while the app runs maps a second copy of it. The app ships it as
/// `flutter_assets/NativeAssetsManifest.json`, which the engine reads at
/// startup, as upstream's `InstallCodeAssets` ships it.
String nativeAssetsManifest(
  ProgramCodeAssets program,
  String os,
  String target, {
  IosFrameworks? frameworks,
}) {
  final section = <String, List<String>>{
    for (final asset in program.shipped)
      asset.id: switch (asset.linkMode) {
        'dynamic_loading_bundle' when asset.fileName != null => [
          'absolute',
          os == 'ios'
              ? '@rpath/${codeAssetPathInDirectory(os, asset.fileName!, frameworks: frameworks)}'
              : codeAssetPathInDirectory(os, asset.fileName!),
        ],
        'dynamic_loading_system' when asset.uri != null => [
          'system',
          asset.uri!,
        ],
        'dynamic_loading_executable' => ['executable'],
        'dynamic_loading_process' => ['process'],
        final mode => throw StateError(
          'the code asset ${asset.id} has link mode `$mode`, which an app '
          'cannot load',
        ),
      },
  };
  if (section.isNotEmpty && target.isEmpty) {
    throw StateError(
      '${section.length} code asset(s) ship for $os, but the target '
      'architecture is unknown, so the manifest could name none of them',
    );
  }
  return const JsonEncoder.withIndent('  ').convert({
    'format-version': [1, 0, 0],
    'native-assets': section.isEmpty ? <String, Object>{} : {target: section},
  });
}

/// Where a platform's app bundle carries its code assets.
///
/// Each library lives in one directory of the bundle, the one the platform's
/// loader resolves a native-assets manifest entry against, at
/// [pathInDirectory]: its file name, or on iOS, which embeds no loose
/// library, a framework of its own. The manifest names that same path.
final class CodeAssetPlacement {
  CodeAssetPlacement._(this.os, this.directory, [this.frameworks]);

  /// The placement for [os] (`linux`, `windows`, `android`, `macos` or
  /// `ios`); [abi] is the Android ABI, and [frameworks] the frameworks of an
  /// iOS app.
  factory CodeAssetPlacement(
    String os, {
    String? abi,
    IosFrameworks? frameworks,
  }) => switch (os) {
    'linux' => CodeAssetPlacement._(os, 'lib'),
    'windows' => CodeAssetPlacement._(os, ''),
    'android' when abi != null && abi.isNotEmpty => CodeAssetPlacement._(
      os,
      'lib/$abi',
    ),
    'android' => throw ArgumentError('an Android placement needs an ABI'),
    'macos' => CodeAssetPlacement._(os, 'Contents/Frameworks'),
    'ios' => CodeAssetPlacement._(os, 'Frameworks', frameworks),
    _ => throw ArgumentError('no code-asset placement for `$os`'),
  };

  /// The OS.
  final String os;

  /// The framework of each library, on iOS.
  final IosFrameworks? frameworks;

  /// The bundle directory the libraries are in: next to the runner on
  /// Windows (`''`), `lib/` beside `libapp.so` on Linux, `lib/<abi>/` in an
  /// APK, `Contents/Frameworks/` of a macOS app and `Frameworks/` of an iOS
  /// one.
  final String directory;

  /// The path of the library [fileName] in [directory].
  String pathInDirectory(String fileName) =>
      codeAssetPathInDirectory(os, fileName, frameworks: frameworks);

  /// The path of the library [fileName] in the bundle.
  String bundlePath(String fileName) => directory.isEmpty
      ? pathInDirectory(fileName)
      : '$directory/${pathInDirectory(fileName)}';
}

String _flag(List<String> args, String name, {bool optional = false}) {
  final at = args.indexOf(name);
  if (at == -1 || at + 1 >= args.length) {
    if (optional) return '';
    throw ArgumentError('missing $name');
  }
  return args[at + 1];
}

List<String> _all(List<String> args, String name) => [
  for (var i = 0; i < args.length - 1; i++)
    if (args[i] == name) args[i + 1],
];

String _programAssets(List<String> args) {
  const flag = '--program-assets=';
  final found = [
    for (final a in args)
      if (a.startsWith(flag)) a.substring(flag.length),
  ];
  if (found.length != 1) {
    throw ArgumentError('expected one $flag, got ${found.length}');
  }
  return found.single;
}

/// Copies each library that ships, and [always], into [output] as
/// [placement] has them in its directory. Two ids served by one library copy
/// it once. On Linux each library's runpath is the bundle's (`bundledRunpath`),
/// and one that links another the bundle carries must find it by `$ORIGIN`.
void place(
  ProgramCodeAssets program,
  CodeAssetPlacement placement,
  String output,
  List<String> always, {
  List<String> copies = const [],
}) {
  final copyOf = {
    for (final copy in copies) copy.substring(copy.lastIndexOf('/') + 1): copy,
  };
  Directory(output).createSync(recursive: true);
  final placed = <String, String>{};
  // On Linux, what each library placed links and where it looks.
  final linked = <String, ElfDynamic>{};
  void copy(String source, String fileName) {
    final target = placement.pathInDirectory(fileName);
    final other = placed[target];
    if (other != null) {
      if (other == source) return;
      throw StateError(
        'two libraries would both be bundled as $target: $other and $source',
      );
    }
    placed[target] = source;
    if (placement.os != 'linux') {
      copyFile(File(source), '$output/$target');
      return;
    }
    // Upstream's build hooks link a Linux library with a runpath of
    // `$ORIGIN`, by which it finds the code assets it links beside it.
    final bytes = bundledRunpath(File(source).readAsBytesSync(), source);
    final placedFile = File('$output/$target');
    placedFile.parent.createSync(recursive: true);
    if (placedFile.existsSync()) placedFile.deleteSync();
    placedFile.writeAsBytesSync(bytes);
    linked[target] = ElfDynamic.read(bytes, source);
  }

  for (final asset in program.shipped) {
    if (!asset.bundled) continue;
    if (asset.file == null) {
      throw StateError(
        'the code asset ${asset.id} is held by name; placing it needs the '
        '`libraries` view',
      );
    }
    copy(copyOf[asset.fileName!] ?? asset.file!, asset.fileName!);
  }
  for (final library in always) {
    copy(library, library.substring(library.lastIndexOf('/') + 1));
  }
  for (final MapEntry(key: target, value: elf) in linked.entries) {
    final siblings = [
      for (final name in elf.needed)
        if (name != target && linked.containsKey(name)) name,
    ];
    // The loader reads DT_RPATH only when there is no DT_RUNPATH.
    final searched = (elf.runpath ?? elf.rpath ?? '').split(':');
    if (siblings.isNotEmpty &&
        !searched.contains(r'$ORIGIN') &&
        !searched.contains(r'${ORIGIN}')) {
      throw StateError(
        '${placed[target]} links ${siblings.join(', ')}, which the bundle '
        'carries beside it, but has no runpath of `\$ORIGIN` to find '
        '${siblings.length == 1 ? 'it' : 'them'} there. Link it with '
        '`-Wl,-rpath,\$ORIGIN`, as Flutter\'s build hooks do',
      );
    }
  }
}

/// Copies into [output] the dSYM bundles of the libraries that ship: each of
/// [always], and each of [candidates] (a library's file name to its
/// bundle) whose library [program] ships. Each bundle is named by its
/// `Contents/Info.plist`, two directories under it, and keeps its name.
///
/// As `flutter build` makes a dSYM only for a code asset it bundles, the
/// dSYM of one a link hook dropped is left out.
void shippedDsyms(
  ProgramCodeAssets program,
  String output,
  List<String> always,
  Map<String, String> candidates,
) {
  Directory(output).createSync(recursive: true);
  final shipped = program.shippedFileNames;
  final bundles = {
    ...always,
    for (final MapEntry(key: fileName, value: plist) in candidates.entries)
      if (shipped.contains(fileName)) plist,
  };
  for (final plist in bundles) {
    final bundle = File(plist).parent.parent;
    final name = bundle.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    copyBundle(bundle, Directory('$output/$name'));
  }
}

/// The name of the file an iOS app carries listing the frameworks to remove
/// from it before it is signed: `iosDroppedFrameworks`, read by
/// `ios_code_asset_post_processor.dart`.
const iosDroppedFrameworksFile = 'rules_flutter_dropped_frameworks.txt';

/// The frameworks of the libraries a link hook dropped, one
/// `<name>.framework` a line, sorted: what an iOS app, which embeds every
/// candidate, removes before it is signed.
///
/// [conflict] names the app's own `ipa_post_processor`, when it has one:
/// rules_apple runs one, so the app cannot have rules_flutter's too, and a
/// list that is not empty fails, naming it.
String iosDroppedFrameworks(
  ProgramCodeAssets program,
  IosFrameworks frameworks, {
  String conflict = '',
}) {
  final list = [
    for (final name in [
      for (final fileName in program.droppedFileNames) frameworks.of(fileName),
    ]..sort())
      '$name.framework\n',
  ].join();
  if (conflict.isNotEmpty && list.isNotEmpty) {
    throw StateError(
      'the app has an ipa_post_processor of its own, $conflict, and a link '
      'hook dropped code assets whose frameworks rules_flutter must remove '
      'before the app is signed:\n$list'
      'rules_apple runs one post-processor and gives it no other files, so '
      'the two cannot both run. Drop the app\'s post-processor, or have its '
      'link hooks keep these code assets',
    );
  }
  return list;
}

/// An APK's native libraries for [abi], as `android_binary` merges an
/// `AndroidNativeLibsInfo` zip: each code asset of [program] that ships, and
/// each of [always] (file name to file), at `lib/<abi>/<name>`, stored, as
/// an APK keeps them to load them in place. Two different files under one
/// name fail; one file reached twice is placed once.
List<int> androidNativeLibs(
  ProgramCodeAssets program,
  String abi,
  Map<String, String> always,
) {
  final placement = CodeAssetPlacement('android', abi: abi);
  final sources = <String, String>{};
  void place(String name, String source) {
    final other = sources[name];
    if (other != null && other != source) {
      throw StateError(
        'two libraries would both be packaged as lib/$abi/$name: $other and '
        '$source. Android can load only one of them',
      );
    }
    sources[name] = source;
  }

  for (final MapEntry(:key, :value) in always.entries) {
    place(key, value);
  }
  for (final asset in program.shipped) {
    if (!asset.bundled) continue;
    if (asset.file == null) {
      throw StateError(
        'the code asset ${asset.id} is held by name; packaging it needs the '
        '`libraries` view',
      );
    }
    place(asset.fileName!, asset.file!);
  }
  final names = sources.keys.toList()..sort();
  return writeZip([
    for (final name in names)
      ZipEntry(
        placement.bundlePath(name),
        File(sources[name]!).readAsBytesSync(),
      ),
  ], store: true);
}

/// [template] with each of [binaries] a binary target of the package's
/// `FlutterPluginRegistrant` target: its `@DEPENDENCIES@` the names,
/// quoted, and its `@BINARY_TARGETS@` a `.binaryTarget` line each.
String packageSwift(String template, Iterable<String> binaries) {
  final sorted = binaries.toSet().toList()..sort();
  return template
      .replaceAll('@DEPENDENCIES@', sorted.map((b) => '"$b"').join(', '))
      .replaceAll(
        '@BINARY_TARGETS@',
        sorted
            .map(
              (b) =>
                  '        .binaryTarget(name: "$b", path: "$b.xcframework"),\n',
            )
            .join(),
      );
}

/// The file names of the code-asset libraries an xcframework of [slices]
/// ships: the first slice's (the device build), as upstream's
/// `verifyCodeAssetConsistency` takes the device build for the source of
/// truth. Every code asset another slice (the simulator build) ships must
/// ship from the device build too, from a library of the same name.
Set<String> consistentShipped(Map<String, ProgramCodeAssets> slices) {
  if (slices.isEmpty) return const {};
  final MapEntry(key: deviceSlice, value: device) = slices.entries.first;
  final deviceFiles = {
    for (final asset in device.shipped)
      if (asset.bundled) asset.id: asset.fileName!,
  };
  for (final MapEntry(key: slice, value: program) in slices.entries.skip(1)) {
    for (final asset in program.shipped) {
      if (!asset.bundled) continue;
      final deviceFile = deviceFiles[asset.id];
      if (deviceFile == null) {
        throw StateError(
          'the $slice build ships the code asset ${asset.id} '
          '(${asset.fileName}), which the $deviceSlice build does not. The '
          'device build is the source of truth for the xcframeworks, as in '
          '`flutter build ios-framework`',
        );
      }
      if (deviceFile != asset.fileName) {
        throw StateError(
          'the code asset ${asset.id} is ${asset.fileName} in the $slice '
          'build and $deviceFile in the $deviceSlice build; an xcframework '
          'needs one name',
        );
      }
    }
  }
  return deviceFiles.values.toSet();
}

int _run(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: code_assets.dart <command> ...');
    return 64;
  }
  final rest = args.sublist(1);
  switch (args.first) {
    case 'place':
      place(
        ProgramCodeAssets.read(_programAssets(rest)),
        CodeAssetPlacement(
          _flag(rest, '--os'),
          abi: _flag(rest, '--abi', optional: true),
        ),
        _flag(rest, '--output'),
        _all(rest, '--library'),
        copies: _all(rest, '--copy'),
      );
    case 'xcframeworks':
      final slices = <String, ProgramCodeAssets>{};
      final candidates = <String, String>{};
      final always = <String>[];
      String? slice;
      for (var i = 0; i < rest.length; i++) {
        final arg = rest[i];
        if (arg == '--slice') {
          slice = rest[++i];
        } else if (arg.startsWith('--program-assets=')) {
          if (slice == null) {
            throw ArgumentError('--program-assets before any --slice');
          }
          slices[slice] = ProgramCodeAssets.read(
            arg.substring('--program-assets='.length),
          );
          slice = null;
        } else if (arg == '--candidate') {
          candidates[rest[i + 1]] = rest[i + 2];
          i += 2;
        } else if (arg == '--always') {
          always.add(rest[++i]);
        } else if (arg == '--output') {
          i++;
        } else {
          throw ArgumentError('unexpected argument $arg');
        }
      }
      final output = _flag(rest, '--output');
      Directory(output).createSync(recursive: true);
      final shipped = consistentShipped(slices).toList()..sort();
      for (final xcframework in [
        for (final name in shipped)
          candidates[name] ??
              (throw StateError('no xcframework for the code asset $name')),
        ...always,
      ]) {
        final base = xcframework.substring(xcframework.lastIndexOf('/') + 1);
        copyBundle(Directory(xcframework), Directory('$output/$base'));
      }
    case 'dsyms':
      // `--candidate-dsym <file name> <plist>`, one for each code asset that
      // could ship; `--always <plist>`, one for each library that does.
      final candidates = <String, String>{};
      for (var i = 0; i < rest.length - 2; i++) {
        if (rest[i] == '--candidate-dsym') {
          candidates[rest[i + 1]] = rest[i + 2];
        }
      }
      shippedDsyms(
        ProgramCodeAssets.read(_programAssets(rest)),
        _flag(rest, '--output'),
        _all(rest, '--always'),
        candidates,
      );
    case 'android-libs':
      final always = <String, String>{
        for (final library in _all(rest, '--library'))
          library.substring(library.lastIndexOf('/') + 1): library,
      };
      for (var i = 0; i < rest.length - 2; i++) {
        if (rest[i] == '--library-as') always[rest[i + 1]] = rest[i + 2];
      }
      File(_flag(rest, '--output')).writeAsBytesSync(
        androidNativeLibs(
          ProgramCodeAssets.read(_programAssets(rest)),
          _flag(rest, '--abi'),
          always,
        ),
      );
    case 'ios-dropped-frameworks':
      File(_flag(rest, '--output')).writeAsStringSync(
        iosDroppedFrameworks(
          ProgramCodeAssets.read(_programAssets(rest)),
          IosFrameworks.fromArgs(rest),
          conflict: _flag(rest, '--conflict', optional: true),
        ),
      );
    case 'manifest':
      File(_flag(rest, '--output')).writeAsStringSync(
        nativeAssetsManifest(
          ProgramCodeAssets.read(_programAssets(rest)),
          _flag(rest, '--os'),
          _flag(rest, '--target', optional: true),
          frameworks: IosFrameworks.fromArgs(rest),
        ),
      );
    case 'merge-manifests':
      // `--manifest <abi> <file>`, one for each ABI's build.
      final manifests = <(String, String)>[];
      for (var i = 0; i < rest.length - 2; i++) {
        if (rest[i] == '--manifest') {
          manifests.add((rest[i + 1], File(rest[i + 2]).readAsStringSync()));
        }
      }
      File(
        _flag(rest, '--output'),
      ).writeAsStringSync(mergeNativeAssetsManifests(manifests));
    case 'package-swift':
      const suffix = '.xcframework';
      File(_flag(rest, '--output')).writeAsStringSync(
        packageSwift(File(_flag(rest, '--template')).readAsStringSync(), [
          ..._all(rest, '--binary'),
          for (final dir in _all(rest, '--binaries-in'))
            for (final entry in Directory(dir).listSync())
              if (entry.path.endsWith(suffix))
                entry.uri.pathSegments
                    .lastWhere((s) => s.isNotEmpty)
                    .replaceFirst(RegExp(r'\.xcframework$'), ''),
        ]),
      );
    default:
      stderr.writeln('code_assets.dart: unknown command ${args.first}');
      return 64;
  }
  return 0;
}

void main(List<String> args) {
  try {
    exitCode = _run(args);
  } on FormatException catch (e) {
    stderr.writeln('code_assets.dart: ${e.message}');
    exitCode = 1;
  } on StateError catch (e) {
    stderr.writeln('code_assets.dart: ${e.message}');
    exitCode = 1;
  } on ManifestMergeException catch (e) {
    stderr.writeln('code_assets.dart: ${e.message}');
    exitCode = 1;
  } on ArgumentError catch (e) {
    stderr.writeln('code_assets.dart: ${e.message}');
    exitCode = 64;
  }
}
