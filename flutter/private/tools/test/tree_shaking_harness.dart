/// Runs `generate_asset_manifest.dart` over icon fonts, with a stand-in for
/// `font-subset` and the recorded uses a program's compiles would write, and
/// returns what it did.
library;

import 'dart:convert';
import 'dart:io';

import 'package:record_use/record_use.dart';
import 'package:runfiles/runfiles.dart';

/// One font family in the `FontManifest.json` the tool is given.
class Family {
  Family(this.name, this.assets);

  final String name;

  /// Bundle paths of the family's font files.
  final List<String> assets;
}

/// What a run of the tool left behind.
class Run {
  Run(this.exitCode, this.stderrText, this._files);

  final int exitCode;
  final String stderrText;
  final Map<String, String> _files;

  /// What the bundle holds at [path], or null when nothing is there.
  String? read(String path) => _files[path];
}

/// Runs the tool for [families], each font file of which is the text
/// `<its path>` (or [contents]'s entry for the path), with the uses each of
/// [recordedUses] records, as the files a program's compiles wrote. A font
/// file whose contents say `unsubsettable` makes the stand-in `font-subset`
/// fail.
Future<Run> runTool({
  required List<Family> families,
  required List<String> recordedUses,
  Map<String, String> contents = const {},
}) async {
  final runfiles = Runfiles.create();
  String runfile(String path) => runfiles.rlocation(path);

  final work = Directory.systemTemp.createTempSync('tree_shaking_');
  try {
    final sources = Directory('${work.path}/src')..createSync();
    final copies = <String, String>{};
    for (final family in families) {
      for (final asset in family.assets) {
        final source = File('${sources.path}/${asset.replaceAll('/', '_')}')
          ..writeAsStringSync(contents[asset] ?? asset);
        copies[asset] = source.path;
      }
    }

    final recorded = [
      for (final (i, text) in recordedUses.indexed)
        (File(
          '${work.path}/recorded_uses_$i.json',
        )..writeAsStringSync(text)).path,
    ];

    final config = File('${work.path}/config.json')
      ..writeAsStringSync(
        jsonEncode({
          'assets': <String, Object?>{},
          'fonts': [
            for (final family in families)
              {
                'family': family.name,
                'fonts': [
                  for (final asset in family.assets) {'asset': asset},
                ],
              },
          ],
          'copies': copies,
          'icon_tree_shaking': {
            'font_subset': runfile(
              '_main/flutter/private/tools/fake_font_subset'
              '${Platform.isWindows ? '.exe' : ''}',
            ),
            'recorded_uses': recorded,
          },
        }),
      );

    final bundle = Directory('${work.path}/bundle');
    final result = await Process.run(Platform.resolvedExecutable, [
      runfile('_main/flutter/private/tools/generate_asset_manifest.dart'),
      '--config',
      config.path,
      '--output-dir',
      bundle.path,
    ]);

    // Only the fonts are read back: the rest of a bundle is binary.
    return Run(result.exitCode, '${result.stderr}', {
      for (final asset in copies.keys)
        if (File('${bundle.path}/$asset').existsSync())
          asset: File('${bundle.path}/$asset').readAsStringSync(),
    });
  } finally {
    work.deleteSync(recursive: true);
  }
}

const _iconData = Class(
  'IconData',
  Library('package:flutter/src/widgets/icon_data.dart'),
);
const _root = LoadingUnit('root');

/// Recorded uses of [references] of `IconData`, as a compile writes them.
String recordings(List<InstanceReference> references) => jsonEncode(
  Recordings(
    calls: const {},
    instances: {if (references.isNotEmpty) _iconData: references},
  ).toJson(),
);

/// A constant `IconData(codePoint, fontFamily: family)`.
InstanceReference constantIcon(int codePoint, String family) =>
    InstanceConstantReference(
      instanceConstant: InstanceConstant(
        definition: _iconData,
        fields: {
          'codePoint': IntConstant(codePoint),
          'fontFamily': StringConstant(family),
        },
      ),
      loadingUnit: _root,
    );

/// The recorded uses of a program with a constant `IconData` for each code
/// point of each family.
String usesIcons(Map<String, List<int>> codePointsByFamily) => recordings([
  for (final MapEntry(key: family, value: codePoints)
      in codePointsByFamily.entries)
    for (final codePoint in codePoints) constantIcon(codePoint, family),
]);

/// `IconData(<codePoint>, fontFamily: <family>)` called with arguments that
/// are each constant or not.
InstanceReference creation(MaybeConstant codePoint, MaybeConstant family) =>
    InstanceCreationReference(
      definition: _iconData,
      loadingUnit: _root,
      positionalArguments: [codePoint],
      namedArguments: {'fontFamily': family},
    );

/// `IconData.new`, torn off.
const InstanceReference tearOff = ConstructorTearoffReference(
  definition: _iconData,
  loadingUnit: _root,
);
