import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

/// Parses the OpenType / TrueType `cmap` table of [fontBytes] and returns the
/// set of Unicode code points mapped to a non-zero glyph ID.
Set<int> readCmapCodePoints(Uint8List fontBytes) {
  final data = ByteData.sublistView(fontBytes);
  final numTables = data.getUint16(4, Endian.big);

  int? cmapOffset;
  int? cmapLength;
  for (var i = 0; i < numTables; i++) {
    final recordOffset = 12 + i * 16;
    final tag = String.fromCharCodes(
      fontBytes.sublist(recordOffset, recordOffset + 4),
    );
    if (tag == 'cmap') {
      cmapOffset = data.getUint32(recordOffset + 8, Endian.big);
      cmapLength = data.getUint32(recordOffset + 12, Endian.big);
      break;
    }
  }
  if (cmapOffset == null || cmapLength == null) {
    throw FormatException('Font does not contain a cmap table');
  }

  final codePoints = <int>{};
  final numSubtables = data.getUint16(cmapOffset + 2, Endian.big);
  for (var i = 0; i < numSubtables; i++) {
    final recordOffset = cmapOffset + 4 + i * 8;
    final subtableRelOffset = data.getUint32(recordOffset + 4, Endian.big);
    final subtableOffset = cmapOffset + subtableRelOffset;
    final format = data.getUint16(subtableOffset, Endian.big);

    if (format == 4) {
      final segCountX2 = data.getUint16(subtableOffset + 6, Endian.big);
      final segCount = segCountX2 ~/ 2;
      final endCodeStart = subtableOffset + 14;
      final startCodeStart = endCodeStart + segCountX2 + 2;
      final idDeltaStart = startCodeStart + segCountX2;
      final idRangeOffsetStart = idDeltaStart + segCountX2;

      for (var s = 0; s < segCount; s++) {
        final endCode = data.getUint16(endCodeStart + s * 2, Endian.big);
        final startCode = data.getUint16(startCodeStart + s * 2, Endian.big);
        final idDelta = data.getInt16(idDeltaStart + s * 2, Endian.big);
        final idRangeOffsetPos = idRangeOffsetStart + s * 2;
        final idRangeOffset = data.getUint16(idRangeOffsetPos, Endian.big);

        for (var c = startCode; c <= endCode; c++) {
          if (c == 0xFFFF) continue;
          int glyphId;
          if (idRangeOffset == 0) {
            glyphId = (c + idDelta) & 0xFFFF;
          } else {
            final glyphIndexOffset =
                idRangeOffsetPos + idRangeOffset + 2 * (c - startCode);
            if (glyphIndexOffset + 2 > fontBytes.length) continue;
            glyphId = data.getUint16(glyphIndexOffset, Endian.big);
            if (glyphId != 0) {
              glyphId = (glyphId + idDelta) & 0xFFFF;
            }
          }
          if (glyphId != 0) {
            codePoints.add(c);
          }
        }
      }
    } else if (format == 12) {
      final numGroups = data.getUint32(subtableOffset + 12, Endian.big);
      for (var g = 0; g < numGroups; g++) {
        final groupOffset = subtableOffset + 16 + g * 12;
        final startChar = data.getUint32(groupOffset, Endian.big);
        final endChar = data.getUint32(groupOffset + 4, Endian.big);
        final startGlyph = data.getUint32(groupOffset + 8, Endian.big);
        for (var c = startChar; c <= endChar; c++) {
          final glyphId = startGlyph + (c - startChar);
          if (glyphId != 0) {
            codePoints.add(c);
          }
        }
      }
    }
  }
  return codePoints;
}

List<File> _findAllRunfiles(String suffix) {
  final matchSuffix = suffix;
  final found = <File>[];
  final runfilesPath =
      Platform.environment['RUNFILES_DIR'] ??
      Platform.environment['TEST_SRCDIR'];
  if (runfilesPath != null && Directory(runfilesPath).existsSync()) {
    for (final entity in Directory(
      runfilesPath,
    ).listSync(recursive: true, followLinks: true)) {
      if (entity is File &&
          entity.path.replaceAll('\\', '/').endsWith(matchSuffix)) {
        found.add(entity);
      }
    }
  }
  final manifestPath = Platform.environment['RUNFILES_MANIFEST_FILE'];
  if (manifestPath != null && File(manifestPath).existsSync()) {
    for (final line in File(manifestPath).readAsLinesSync()) {
      final space = line.indexOf(' ');
      if (space <= 0) continue;
      final target = line.substring(space + 1).trim();
      if (target.replaceAll('\\', '/').endsWith(matchSuffix) &&
          File(target).existsSync()) {
        found.add(File(target));
      }
      if (Directory(target).existsSync()) {
        for (final entity in Directory(
          target,
        ).listSync(recursive: true, followLinks: true)) {
          if (entity is File &&
              entity.path.replaceAll('\\', '/').endsWith(matchSuffix)) {
            found.add(entity);
          }
        }
      }
    }
  }
  final seen = <String>{};
  return found.where((f) => seen.add(f.path)).toList();
}

List<File> _findIconTreeShakeDills() {
  final dills = <File>[
    ..._findAllRunfiles('_icon_tree_shaking.dill'),
    ..._findAllRunfiles('.icon_tree_shaking.dill'),
  ];
  final seen = <String>{};
  final unique = <File>[];
  for (final d in dills) {
    if (seen.add(d.path) &&
        d.path.replaceAll('\\', '/').contains('icon_tree_shaking')) {
      unique.add(d);
    }
  }
  // Also catch renderer-suffixed dills (e.g. _icon_tree_shaking_skwasm.dill)
  // whose suffix above already matches, plus any dill under a forwarded
  // icon-tree-shake output that the exact suffix missed.
  for (final d in _findAllRunfiles('.dill')) {
    final norm = d.path.replaceAll('\\', '/');
    if (norm.contains('icon_tree_shaking') && seen.add(d.path)) {
      unique.add(d);
    }
  }
  return unique;
}

File _findRunfile(String suffix) {
  final matchSuffix = suffix.startsWith('/') ? suffix : '/$suffix';
  final runfilesPath =
      Platform.environment['RUNFILES_DIR'] ??
      Platform.environment['TEST_SRCDIR'];
  if (runfilesPath != null && Directory(runfilesPath).existsSync()) {
    final dir = Directory(runfilesPath);
    for (final entity in dir.listSync(recursive: true, followLinks: true)) {
      if (entity is File &&
          entity.path.replaceAll('\\', '/').endsWith(matchSuffix)) {
        return entity;
      }
    }
  }
  final manifestPath = Platform.environment['RUNFILES_MANIFEST_FILE'];
  if (manifestPath != null && File(manifestPath).existsSync()) {
    for (final line in File(manifestPath).readAsLinesSync()) {
      final space = line.indexOf(' ');
      if (space <= 0) continue;
      final target = line.substring(space + 1).trim();
      if (target.replaceAll('\\', '/').endsWith(matchSuffix) &&
          File(target).existsSync()) {
        return File(target);
      }
      if (Directory(target).existsSync()) {
        for (final entity in Directory(
          target,
        ).listSync(recursive: true, followLinks: true)) {
          if (entity is File &&
              entity.path.replaceAll('\\', '/').endsWith(matchSuffix)) {
            return entity;
          }
        }
      }
    }
  }
  final fallback = Directory.current.parent;
  for (final entity in fallback.listSync(recursive: true, followLinks: true)) {
    if (entity is File &&
        entity.path.replaceAll('\\', '/').endsWith(matchSuffix)) {
      return entity;
    }
  }
  throw StateError('Runfile ending with "$suffix" not found');
}

void main() {
  late Uint8List originalMaterialBytes;
  late Uint8List originalRobotoBytes;

  setUpAll(() {
    originalMaterialBytes = _findRunfile(
      'material-fonts/MaterialIcons-Regular.otf',
    ).readAsBytesSync();
    originalRobotoBytes = _findRunfile(
      'material-fonts/Roboto-Regular.ttf',
    ).readAsBytesSync();
  });

  test(
    'kDebugMode ? Icons.a : Icons.b keeps Icons.b and shakes out Icons.a',
    () {
      final bundledMaterial = _findRunfile(
        '_web_font_fixture_web/assets/fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();

      final codePoints = readCmapCodePoints(bundledMaterial);
      // Icons.b (0xe567, selected in icon_choice_lib dep) and Icons.d (0xe88a,
      // selected in main.dart) must be retained.
      expect(codePoints, contains(0xe567));
      expect(codePoints, contains(0xe88a));
      // Icons.a (0xe047) and Icons.c (0xe145) from the unchosen kDebugMode
      // branch must be shaken out.
      expect(codePoints, isNot(contains(0xe047)));
      expect(codePoints, isNot(contains(0xe145)));
    },
  );

  test(
    'font families used only through TextStyle(fontFamily: ...) ship whole',
    () {
      final bundledRoboto = _findRunfile(
        '_web_font_fixture_web/assets/fonts/Roboto-Regular.ttf',
      ).readAsBytesSync();
      expect(bundledRoboto, equals(originalRobotoBytes));

      final bundledCupertino = _findRunfile(
        '_web_font_fixture_web/assets/packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ).readAsBytesSync();
      expect(bundledCupertino, equals(originalMaterialBytes));
      final cupertinoCodePoints = readCmapCodePoints(bundledCupertino);
      expect(cupertinoCodePoints, containsAll(<int>[0xe047, 0xe567, 0xe145]));

      final bundledTextOnlyMaterial = _findRunfile(
        'text_only_material_fixture_web/assets/fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      expect(bundledTextOnlyMaterial, equals(originalMaterialBytes));
      final materialTextCodePoints = readCmapCodePoints(
        bundledTextOnlyMaterial,
      );
      expect(
        materialTextCodePoints,
        containsAll(<int>[0xe047, 0xe567, 0xe145, 0xe88a]),
      );
    },
  );

  test(
    'unused glyphs in an icon font family are subsetted where upstream would subset it',
    () {
      final bundledUnusedFamily = _findRunfile(
        '_web_font_fixture_web/assets/packages/unused_icons/fonts/UnusedFamily.otf',
      ).readAsBytesSync();

      final codePoints = readCmapCodePoints(bundledUnusedFamily);
      expect(codePoints, contains(0xe5cd));
      expect(codePoints, isNot(contains(0xe047)));
      expect(codePoints, isNot(contains(0xe567)));
      expect(codePoints, isNot(contains(0xe145)));
    },
  );

  test(
    'families where one name or asset path is a suffix of another get distinct subsets',
    () {
      final bundledMaterial = _findRunfile(
        '_web_font_fixture_web/assets/fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      final bundledBareIcons = _findRunfile(
        '_web_font_fixture_web/assets/fonts/Icons.otf',
      ).readAsBytesSync();
      final bundledPkgIcons = _findRunfile(
        '_web_font_fixture_web/assets/packages/custom_icons/fonts/Icons.otf',
      ).readAsBytesSync();

      final materialCodePoints = readCmapCodePoints(bundledMaterial);
      final bareIconsCodePoints = readCmapCodePoints(bundledBareIcons);
      final pkgIconsCodePoints = readCmapCodePoints(bundledPkgIcons);

      // MaterialIcons retains 0xe567 and 0xe88a, not 0xe047 or 0xe145.
      expect(materialCodePoints, containsAll(<int>[0xe567, 0xe88a]));
      expect(materialCodePoints, isNot(contains(0xe047)));
      expect(materialCodePoints, isNot(contains(0xe145)));

      // Bare 'Icons' (fonts/Icons.otf) retains only 0xe047.
      expect(bareIconsCodePoints, contains(0xe047));
      expect(bareIconsCodePoints, isNot(contains(0xe145)));
      expect(bareIconsCodePoints, isNot(contains(0xe567)));
      expect(bareIconsCodePoints, isNot(contains(0xe88a)));

      // Package 'packages/custom_icons/Icons' (packages/custom_icons/fonts/Icons.otf)
      // retains only 0xe145 and is not clobbered by bare 'fonts/Icons.otf'.
      expect(pkgIconsCodePoints, contains(0xe145));
      expect(pkgIconsCodePoints, isNot(contains(0xe047)));
      expect(pkgIconsCodePoints, isNot(contains(0xe567)));
      expect(pkgIconsCodePoints, isNot(contains(0xe88a)));
    },
  );

  test(
    'bundled MaterialIcons covers plugin-registered, renderer-guarded, and user-define-guarded code points across all shipped programs',
    () {
      final skwasmMaterial = _findRunfile(
        'skwasm_plugin_icon_fixture_web/assets/fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      final canvaskitMaterial = _findRunfile(
        'canvaskit_plugin_icon_fixture_web/assets/fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();
      final dart2jsCanvaskitMaterial = _findRunfile(
        'dart2js_canvaskit_plugin_icon_fixture_web/assets/fonts/MaterialIcons-Regular.otf',
      ).readAsBytesSync();

      final skwasmCodePoints = readCmapCodePoints(skwasmMaterial);
      final canvaskitCodePoints = readCmapCodePoints(canvaskitMaterial);
      final dart2jsCanvaskitCodePoints = readCmapCodePoints(
        dart2jsCanvaskitMaterial,
      );

      // Every bundle must retain Icons.a (0xe047) reached only via
      // WebIconPlugin.registerWith in the generated web plugin registrant.
      expect(skwasmCodePoints, contains(0xe047));
      expect(canvaskitCodePoints, contains(0xe047));
      expect(dart2jsCanvaskitCodePoints, contains(0xe047));

      // `compiler = "dart2wasm", renderer = "skwasm"` ships BOTH the skwasm
      // WASM build (FLUTTER_WEB_USE_SKWASM=true -> Icons.b, 0xe567) AND the
      // canvaskit JS fallback build (FLUTTER_WEB_USE_SKIA=true -> Icons.c, 0xe145),
      // plus the user-define-guarded Icons.e (0xe5cd), and shakes out Icons.d (0xe88a).
      expect(skwasmCodePoints, contains(0xe567));
      expect(skwasmCodePoints, contains(0xe145));
      expect(skwasmCodePoints, contains(0xe5cd));
      expect(skwasmCodePoints, isNot(contains(0xe88a)));

      // `compiler = "dart2wasm", renderer = "canvaskit"` (with no USER_ICON_DEFINE)
      // ships only canvaskit builds, retaining Icons.c (0xe145, FLUTTER_WEB_USE_SKIA=true)
      // and shaking out Icons.b (0xe567, FLUTTER_WEB_USE_SKWASM), Icons.d (0xe88a),
      // and Icons.e (0xe5cd, USER_ICON_DEFINE).
      expect(canvaskitCodePoints, contains(0xe145));
      expect(canvaskitCodePoints, isNot(contains(0xe567)));
      expect(canvaskitCodePoints, isNot(contains(0xe88a)));
      expect(canvaskitCodePoints, isNot(contains(0xe5cd)));

      // `compiler = "dart2js", renderer = "canvaskit"` (with USER_ICON_DEFINE=true)
      // ships only the canvaskit JS build, retaining Icons.c (0xe145, FLUTTER_WEB_USE_SKIA=true)
      // and Icons.e (0xe5cd, USER_ICON_DEFINE=true), and shaking out Icons.b (0xe567)
      // and Icons.d (0xe88a).
      expect(dart2jsCanvaskitCodePoints, contains(0xe145));
      expect(dart2jsCanvaskitCodePoints, contains(0xe5cd));
      expect(dart2jsCanvaskitCodePoints, isNot(contains(0xe567)));
      expect(dart2jsCanvaskitCodePoints, isNot(contains(0xe88a)));
    },
  );

  test('icon tree-shake kernel dills record only stable URIs', () {
    final dills = _findIconTreeShakeDills();
    expect(
      dills,
      isNotEmpty,
      reason: 'expected forwarded icon tree-shake dills',
    );
    for (final dill in dills) {
      final bytes = dill.readAsBytesSync();
      final text = String.fromCharCodes(bytes);
      // Absolute `file://` URIs would make the dill differ per checkout,
      // machine and sandbox run number. `file://` itself also appears in
      // Dart error strings (e.g. `file:///80443` in URI parsing), so only
      // `file://` URIs carrying a filesystem location are refused.
      for (final fragment in [
        'file:///bazel-out',
        'file:///tmp',
        'file:///src',
        'file:///home',
        'file:///build',
        'file:///external',
        'file://C:',
        'file://c:',
        'processwrapper',
        'execroot',
        'rules_flutter_dart2js_cfe_',
        'sandbox/',
        'sandbox\\',
      ]) {
        expect(
          text,
          isNot(contains(fragment)),
          reason: '${dill.path} embeds an absolute path ($fragment)',
        );
      }
      expect(
        text,
        contains('org-dartlang-app:///'),
        reason:
            '${dill.path} should key libraries under the stable multi-root scheme',
      );
    }
  });

  test(
    'FlutterDart2JS main.dart.js.deps contains only hermetic org-dartlang-* URIs and no host temp paths',
    () {
      for (final (depsSuffix, expectedPkgConfigUri) in [
        (
          'text_only_material_fixture_dart2js_fallback/main.dart.js.deps',
          'org-dartlang-app:///flutter/tests/icon_tree_shake_fixture/text_only_material_fixture.package_config.json',
        ),
        (
          'dart2js_canvaskit_plugin_icon_fixture_dart2js/main.dart.js.deps',
          'org-dartlang-app:///flutter/tests/icon_tree_shake_fixture/dart2js_canvaskit_plugin_icon_fixture.package_config.json',
        ),
      ]) {
        final depsContent = _findRunfile(depsSuffix).readAsStringSync();
        final lines = depsContent
            .split('\n')
            .where((l) => l.isNotEmpty)
            .toList();
        expect(lines, isNotEmpty);
        expect(lines, contains(expectedPkgConfigUri));
        for (final line in lines) {
          expect(line, isNot(contains('file:')));
          expect(line, isNot(contains('flutter_dart2js_')));
          expect(line, isNot(contains('_dart2js_tmp')));
          expect(line, isNot(contains('bazel-out/')));
          expect(
            line.startsWith('org-dartlang-app:///') ||
                line.startsWith('org-dartlang-sdk:///'),
            isTrue,
            reason: 'unexpected URI scheme in $depsSuffix: $line',
          );
        }
        final sorted = [...lines]..sort();
        expect(lines, equals(sorted));
      }
    },
  );
}
