/// Generates Flutter asset bundle files (AssetManifest.bin, FontManifest.json).
///
/// This tool implements the StandardMessageCodec binary encoding used by
/// Flutter's AssetManifest.bin format. It has no package dependencies and
/// runs with the bare Dart SDK.
///
/// Usage:
///   dart generate_asset_manifest.dart --config <path> --output-dir <path>
///       [--program-assets=<path>]
///
/// `--program-assets` names what a program ships, in rules_dart's
/// program-assets line format (its README, "The program-assets file"). Each
/// data asset the program ships is bundled at `packages/<package>/<name>` and
/// listed in the asset manifest under that key, as flutter_tools bundles a
/// hook's data asset.
///
/// The config file is JSON with this schema:
/// {
///   "assets": {
///     "assets/image.png": [
///       {"asset": "assets/image.png"},
///       {"asset": "assets/2.0x/image.png", "dpr": 2.0}
///     ]
///   },
///   "fonts": [...],
///   "copies": {"key": "source/path", ...}   // stored at the key, URI-encoded
/// }
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// -- StandardMessageCodec binary encoding ------------------------------------
// This reimplements Flutter's StandardMessageCodec.encodeMessage() so we can
// produce AssetManifest.bin without depending on package:flutter.

const int _tagNull = 0;
const int _tagTrue = 1;
const int _tagFalse = 2;
const int _tagInt32 = 3;
const int _tagInt64 = 4;
const int _tagFloat64 = 6;
const int _tagString = 7;
const int _tagList = 12;
const int _tagMap = 13;

class _WriteBuffer {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _position = 0;

  void putUint8(int value) {
    _builder.addByte(value);
    _position++;
  }

  void putBytes(List<int> bytes) {
    _builder.add(bytes);
    _position += bytes.length;
  }

  void _putByteData(ByteData data) {
    _builder.add(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    _position += data.lengthInBytes;
  }

  void putInt32(int value) {
    final d = ByteData(4)..setInt32(0, value, Endian.host);
    _putByteData(d);
  }

  void putInt64(int value) {
    final d = ByteData(8)..setInt64(0, value, Endian.host);
    _putByteData(d);
  }

  void putFloat64(double value) {
    // Align to 8-byte boundary.
    final pad = (8 - (_position % 8)) % 8;
    for (var i = 0; i < pad; i++) {
      _builder.addByte(0);
    }
    _position += pad;
    final d = ByteData(8)..setFloat64(0, value, Endian.host);
    _putByteData(d);
  }

  Uint8List done() => _builder.toBytes();
}

void _writeSize(_WriteBuffer buf, int size) {
  if (size < 254) {
    buf.putUint8(size);
  } else if (size < 0x10000) {
    buf.putUint8(254);
    final d = ByteData(2)..setUint16(0, size, Endian.host);
    buf._putByteData(d);
  } else {
    buf.putUint8(255);
    final d = ByteData(4)..setUint32(0, size, Endian.host);
    buf._putByteData(d);
  }
}

void _writeValue(_WriteBuffer buf, Object? value) {
  if (value == null) {
    buf.putUint8(_tagNull);
  } else if (value is bool) {
    buf.putUint8(value ? _tagTrue : _tagFalse);
  } else if (value is int) {
    if (value >= -0x80000000 && value <= 0x7fffffff) {
      buf.putUint8(_tagInt32);
      buf.putInt32(value);
    } else {
      buf.putUint8(_tagInt64);
      buf.putInt64(value);
    }
  } else if (value is double) {
    buf.putUint8(_tagFloat64);
    buf.putFloat64(value);
  } else if (value is String) {
    buf.putUint8(_tagString);
    final encoded = utf8.encode(value);
    _writeSize(buf, encoded.length);
    buf.putBytes(encoded);
  } else if (value is List) {
    buf.putUint8(_tagList);
    _writeSize(buf, value.length);
    for (final item in value) {
      _writeValue(buf, item);
    }
  } else if (value is Map) {
    buf.putUint8(_tagMap);
    _writeSize(buf, value.length);
    for (final entry in value.entries) {
      _writeValue(buf, entry.key);
      _writeValue(buf, entry.value);
    }
  } else {
    throw ArgumentError('Unsupported type: ${value.runtimeType}');
  }
}

Uint8List encodeStandardMessage(Object? message) {
  if (message == null) return Uint8List(0);
  final buf = _WriteBuffer();
  _writeValue(buf, message);
  return buf.done();
}

// -- Icon tree shaking helpers -----------------------------------------------

/// Ends the build with [message]. Icon tree shaking either does what it was
/// asked to or fails, as `flutter build` does: a bundle that quietly skipped
/// it would ship icon fonts whole that the app was said to ship subset, and a
/// subset made from a wrong answer would drop glyphs the app draws.
Never _failTreeShaking(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'To build without icon tree shaking, set `tree_shake_icons = False`.',
  );
  exit(1);
}

/// The glyph an icon font keeps when the program uses none of its icons, by
/// font family: flutter_tools' `_kKnownIconFontFallbackCodePoints`.
const _iconFontFallbackCodePoints = <String, int>{
  'MaterialIcons': 0xe047, // Icons.add
  'packages/cupertino_icons/CupertinoIcons': 0xf3d2, // chevron_left
};

const _iconDataLibrary = 'package:flutter/src/widgets/icon_data.dart';

/// [value] as a [T], or a [FormatException] naming [what] it was meant to
/// be: the recorded uses are another program's output, and a shape this tool
/// does not know ends the build with a message rather than a cast error.
T _expect<T>(Object? value, String what) {
  if (value is T) return value;
  throw FormatException('expected $what to be a $T, got ${jsonEncode(value)}');
}

/// The entry of [list] at [index], which [what] names.
Map<String, dynamic> _entry(List<dynamic> list, Object? index, String what) {
  final i = _expect<int>(index, '$what index');
  if (i < 0 || i >= list.length) {
    throw FormatException(
      '$what index $i is out of range: the file lists ${list.length}',
    );
  }
  return _expect<Map<String, dynamic>>(list[i], '$what $i');
}

/// The icons a recorded-uses file (`package:record_use`'s JSON, as a
/// compile's `--recorded-uses` or dart2js's `--write-resources` writes it)
/// says the program uses: the code points of each constant `IconData`, by
/// font family (`packages/<package>/<family>` for a package's font), and
/// whether any `IconData` is made from values not known at compile time.
///
/// An `IconData` with no `fontFamily` draws from the system font, so it
/// names no font to subset and is left out, as flutter_tools leaves it.
///
/// Throws a [FormatException] for a file of a shape it does not know.
({Map<String, Set<int>> codePoints, bool nonConstant}) iconDataUses(
  Map<String, dynamic> recordings,
) {
  final constants =
      _expect<List<dynamic>?>(recordings['constants'], '"constants"') ??
      const [];
  final definitions =
      _expect<List<dynamic>?>(recordings['definitions'], '"definitions"') ??
      const [];
  final uses =
      _expect<Map<String, dynamic>?>(recordings['uses'], '"uses"') ?? const {};
  final codePoints = <String, Set<int>>{};
  var nonConstant = false;

  Map<String, dynamic> constant(Object? index) =>
      _entry(constants, index, 'constant');

  // A constant's value as a Dart value, for the kinds `IconData`'s three
  // fields can hold; any other kind is `_other`.
  Object? value(Object? index) {
    if (index == null) return null;
    final c = constant(index);
    switch (c['type']) {
      case 'null':
        return null;
      case 'int':
        return _expect<int>(c['value'], "an int constant's value");
      case 'string':
        return _expect<String>(c['value'], "a string constant's value");
      // A program compiled to JavaScript has no separate `int`: its integers
      // may be recorded as doubles.
      case 'double':
        final number = _expect<Map<String, dynamic>>(
          c['value'],
          "a double constant's value",
        );
        if (number['type'] == 'number') {
          final v = _expect<num>(number['value'], 'a number');
          if (v == v.roundToDouble()) return v.round();
        }
        return _other;
      case 'non_constant':
        return _nonConstant;
      default:
        return _other;
    }
  }

  void record(Object? codePoint, Object? fontFamily, Object? fontPackage) {
    if (codePoint is! int || fontFamily is! String) return;
    final family = fontPackage is String
        ? 'packages/$fontPackage/$fontFamily'
        : fontFamily;
    codePoints.putIfAbsent(family, () => <int>{}).add(codePoint);
  }

  final instances =
      _expect<List<dynamic>?>(uses['instances'], '"uses"."instances"') ??
      const [];
  for (final recording in instances) {
    final r = _expect<Map<String, dynamic>>(recording, 'an instance recording');
    final definition = _entry(
      definitions,
      r['definition_index'],
      'definition',
    );
    final path =
        _expect<List<dynamic>?>(definition['path'], "a definition's path") ??
        const [];
    if (definition['uri'] != _iconDataLibrary ||
        path.isEmpty ||
        _expect<Map<String, dynamic>>(
              path.first,
              "a definition's path element",
            )['name'] !=
            'IconData') {
      continue;
    }
    final references =
        _expect<List<dynamic>?>(r['uses'], "an instance recording's uses") ??
        const [];
    for (final use in references) {
      final u = _expect<Map<String, dynamic>>(use, 'an instance use');
      switch (u['type']) {
        case 'constant':
          final c = constant(u['constant_index']);
          final fields =
              _expect<Map<String, dynamic>?>(
                c['value'],
                "an instance constant's fields",
              ) ??
              const {};
          record(
            value(fields['codePoint']),
            value(fields['fontFamily']),
            value(fields['fontPackage']),
          );
        case 'creation':
          final positional =
              _expect<List<dynamic>?>(
                u['positional'],
                "a creation's positional arguments",
              ) ??
              const [];
          final named =
              _expect<Map<String, dynamic>?>(
                u['named'],
                "a creation's named arguments",
              ) ??
              const {};
          final arguments = [
            for (final index in positional) value(index),
            for (final index in named.values) value(index),
          ];
          if (arguments.any((a) => identical(a, _nonConstant))) {
            nonConstant = true;
            continue;
          }
          record(
            positional.isEmpty ? null : value(positional.first),
            value(named['fontFamily']),
            value(named['fontPackage']),
          );
        default:
          // A tear-off of the constructor: what it is called with is unknown.
          nonConstant = true;
      }
    }
  }
  return (codePoints: codePoints, nonConstant: nonConstant);
}

const _other = Object();
const _nonConstant = Object();

/// Run font-subset, piping code points via stdin. Returns true on success.
Future<bool> _runFontSubset(
  String fontSubsetBin,
  String outputPath,
  String inputPath,
  String codePoints,
) async {
  // font-subset reads code points from stdin (space-separated, newline-terminated).
  final process = await Process.start(fontSubsetBin, [outputPath, inputPath]);
  try {
    process.stdin.writeln(codePoints);
    await process.stdin.flush();
    await process.stdin.close();
  } on Exception {
    // Handled by checking exit code below.
  }

  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    stderr.writeln('font-subset failed for $inputPath (exit $exitCode)');
    return false;
  }
  return true;
}

// -- Main --------------------------------------------------------------------

/// The name and version of the program-assets line format this reads.
const programAssetsFormat = 'rules_dart_program_assets/1';

/// The data assets a program ships, read from a file in rules_dart's
/// program-assets line format: each link hook's data directory listed.
///
/// The bundle holds data assets only, so this reads a file that holds them
/// and passes over any code records it also holds. rules_dart's reference
/// reader (`@rules_dart//dart/program_assets`) is a package, and this tool
/// runs as a script with none; rules_dart's conformance fixture checks the
/// two agree.
final class ProgramAssets {
  ProgramAssets(this.dataAssets);

  /// Each data asset's file, by id (`package:<package>/<name>`).
  final Map<String, String> dataAssets;

  /// Reads [path]. Its `exec` paths are relative to [base], the working
  /// directory when null.
  static ProgramAssets read(String path, {String? base}) {
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
    if (!parts.contains('data')) {
      throw FormatException(
        '$path holds `$holds`, not the data assets the bundle needs; pass '
        '`data = True` to `program_assets_action_args()`',
      );
    }
    final holdsCode = parts.length > 1;
    void holding(String record, bool held) {
      if (!held) {
        throw FormatException(
          '$path: a `$record` record in a file that holds `$holds`',
        );
      }
    }

    final data = <String, String>{};
    void ship(String id, String file) {
      if (data.containsKey(id)) {
        throw FormatException('$path names data asset `$id` twice');
      }
      data[id] = file;
    }

    // A code asset's record: its id, link mode, library and uri.
    void passCodeAsset() {
      for (final what in ['an id', 'a link mode', 'a library', 'a uri']) {
        next(what);
      }
    }

    while (at < lines.length) {
      switch (next('a record')) {
        case '--data-asset':
          final id = next('an id');
          ship(id, resolve(next('a file')));
        case '--link-data':
          final package = next('a package');
          final directory = resolve(next('a directory'));
          final root = Directory(directory);
          final files = root.existsSync()
              ? root
                    .listSync(recursive: true, followLinks: true)
                    .whereType<File>()
              : const <File>[];
          for (final file in files) {
            final name = file.path
                .substring(directory.length + 1)
                .replaceAll(r'\', '/');
            ship('package:$package/$name', file.path);
          }
        case '--code-asset':
          holding('--code-asset', holdsCode);
          passCodeAsset();
        case '--link-code':
          holding('--link-code', holdsCode);
          next('a package');
          next('a selection');
          while (at < lines.length && lines[at] == '--candidate') {
            at++;
            passCodeAsset();
          }
        case final other:
          throw FormatException('$path: unknown record `$other`');
      }
    }
    return ProgramAssets(data);
  }
}

/// Adds each of a program's data assets to [config], at
/// `packages/<package>/<name>`, the key `rootBundle` loads it by.
///
/// A key another file already claims fails: the bundle can hold one of them.
void addProgramDataAssets(Map<String, dynamic> config, ProgramAssets program) {
  final assets = (config['assets'] ??= <String, dynamic>{}) as Map;
  final copies = (config['copies'] ??= <String, dynamic>{}) as Map;
  for (final MapEntry(key: id, value: source) in program.dataAssets.entries) {
    final key = 'packages/${id.substring('package:'.length)}';
    final claimed = copies[key];
    if (claimed != null && claimed != source) {
      stderr.writeln(
        'Two files claim the asset key $key: $claimed and the data asset '
        '$source. A bundle can hold one of them.',
      );
      exit(1);
    }
    copies[key] = source;
    assets[key] = [
      {'asset': key},
    ];
  }
}

Future<void> main(List<String> args) async {
  String? configPath;
  String? outputDir;
  String? programAssets;

  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--config' && i + 1 < args.length) {
      configPath = args[++i];
    } else if (args[i] == '--output-dir' && i + 1 < args.length) {
      outputDir = args[++i];
    } else if (args[i].startsWith('--program-assets=')) {
      programAssets = args[i].substring('--program-assets='.length);
    }
  }

  if (configPath == null || outputDir == null) {
    stderr.writeln(
      'Usage: dart generate_asset_manifest.dart --config <path> --output-dir <path>',
    );
    exit(1);
  }

  final config =
      json.decode(File(configPath).readAsStringSync()) as Map<String, dynamic>;
  if (programAssets != null) {
    addProgramDataAssets(config, ProgramAssets.read(programAssets));
  }

  // Create output directory.
  Directory(outputDir).createSync(recursive: true);

  // -- AssetManifest.bin -----------------------------------------------------
  final assets = config['assets'] as Map<String, dynamic>? ?? {};
  final manifestMap = <String, Object>{};
  for (final entry in assets.entries) {
    final variants = (entry.value as List<dynamic>).map((v) {
      final variant = v as Map<String, dynamic>;
      final result = <String, Object>{'asset': variant['asset'] as String};
      if (variant.containsKey('dpr')) {
        result['dpr'] = (variant['dpr'] as num).toDouble();
      }
      return result;
    }).toList();
    manifestMap[entry.key] = variants;
  }
  final binBytes = encodeStandardMessage(manifestMap);
  File('$outputDir/AssetManifest.bin').writeAsBytesSync(binBytes);

  // AssetManifest.bin.json — base64-encoded JSON wrapper for web.
  File('$outputDir/AssetManifest.bin.json').writeAsStringSync(
    json.encode(base64.encode(binBytes)),
  );

  // -- FontManifest.json -----------------------------------------------------
  final fonts = config['fonts'] as List<dynamic>? ?? [];
  File('$outputDir/FontManifest.json').writeAsStringSync(json.encode(fonts));

  // -- Icon tree shaking (optional) ------------------------------------------
  final iconTreeShaking = config['icon_tree_shaking'] as Map<String, dynamic>?;
  Map<String, Set<int>>? usedCodePoints;
  Map<String, String>? fontFamilyToAsset;

  // Code points each subset font keeps if the font has them, used or not.
  var optionalCodePoints = <int>[];

  if (iconTreeShaking != null) {
    final optional =
        iconTreeShaking['optional_code_points'] as List<dynamic>? ?? [];
    optionalCodePoints = [for (final cp in optional) cp as int];

    // Step 1: the icons the program uses, from the uses of `IconData` each
    // of its compiles recorded.
    final used = <String, Set<int>>{};
    for (final path in iconTreeShaking['recorded_uses'] as List<dynamic>) {
      final String text;
      try {
        text = File(path as String).readAsStringSync();
      } on FileSystemException catch (e) {
        _failTreeShaking('Cannot read the recorded uses file $path: $e');
      }
      // A compile that records no use writes an empty file or `{}`.
      if (text.trim().isEmpty) continue;
      final Object? decoded;
      try {
        decoded = json.decode(text);
      } on FormatException catch (e) {
        _failTreeShaking('Failed to parse the recorded uses file $path: $e');
      }
      if (decoded is! Map<String, dynamic>) {
        _failTreeShaking(
          'Invalid recorded uses file $path: expected a top level JSON '
          'object.',
        );
      }
      final ({Map<String, Set<int>> codePoints, bool nonConstant}) uses;
      try {
        uses = iconDataUses(decoded);
      } on FormatException catch (e) {
        _failTreeShaking('Invalid recorded uses file $path: ${e.message}.');
      }
      if (uses.nonConstant) {
        _failTreeShaking(
          'This application cannot tree shake icon fonts. It has non-constant '
          'instances of IconData. Avoid non-constant invocations of IconData.',
        );
      }
      uses.codePoints.forEach(
        (family, codePoints) =>
            used.putIfAbsent(family, () => <int>{}).addAll(codePoints),
      );
    }

    // An icon font the program draws nothing from still ships, cut to one
    // glyph, as flutter_tools 3.50 cuts it.
    for (final entry in fonts) {
      final family = (entry as Map<String, dynamic>)['family'] as String?;
      final fallback = _iconFontFallbackCodePoints[family];
      if (fallback != null && !used.containsKey(family)) {
        used[family!] = {fallback};
      }
    }
    usedCodePoints = used;

    // Build fontFamily → font path map from FontManifest. A family the app
    // draws icons from has one font file: subsetting one of several and
    // shipping the rest whole would leave the bundle holding icons the app
    // was said not to use.
    fontFamilyToAsset = <String, String>{};
    for (final entry in fonts) {
      final m = entry as Map<String, dynamic>;
      final family = m['family'] as String?;
      final fontList = m['fonts'] as List<dynamic>? ?? [];
      if (family == null || !used.containsKey(family)) continue;
      if (fontList.length != 1) {
        _failTreeShaking(
          'This tool cannot process icon fonts with multiple fonts in a '
          'single family ($family has ${fontList.length}).',
        );
      }
      final asset = (fontList.single as Map<String, dynamic>)['asset'];
      if (asset is! String) {
        _failTreeShaking(
          'FontManifest.json invalid: expected the "asset" of $family to be '
          'a string, got $asset.',
        );
      }
      fontFamilyToAsset[family] = asset;
    }
  }

  // -- Copy asset files (with optional font subsetting) ----------------------
  final copies = config['copies'] as Map<String, dynamic>? ?? {};
  for (final entry in copies.entries) {
    // The engine asks for `Uri.encodeFull(key)`, and flutter_tools stores each
    // file at its URI-encoded path (`my%20image.png`), so a name with a space
    // or a non-ASCII character is found; the manifest lists the decoded key.
    final dest = '$outputDir/${Uri(pathSegments: entry.key.split('/')).path}';
    Directory(File(dest).parent.path).createSync(recursive: true);

    // Check if this asset should be subsetted.
    if (usedCodePoints != null &&
        fontFamilyToAsset != null &&
        iconTreeShaking != null) {
      final fontSubsetBin = iconTreeShaking['font_subset'] as String;
      // A font is the one of a family by its exact path in the bundle, never
      // by how the paths end: `packages/p/fonts/Icons.ttf` and `fonts/Icons.ttf`
      // are two fonts, and each takes only its own family's code points.
      String? matchedFamily;
      for (final famEntry in fontFamilyToAsset.entries) {
        if (famEntry.value == entry.key) {
          matchedFamily = famEntry.key;
          break;
        }
      }

      final codePoints = matchedFamily != null
          ? usedCodePoints[matchedFamily]
          : null;
      if (codePoints != null && codePoints.isNotEmpty) {
        // Run font-subset: code points are piped via stdin.
        final codePointStr = [
          ...codePoints.map((cp) => cp.toString()),
          ...optionalCodePoints.map((cp) => 'optional:$cp'),
        ].join(' ');
        final success = await _runFontSubset(
          fontSubsetBin,
          dest,
          entry.value as String,
          codePointStr,
        );
        if (success) {
          final inputSize = File(entry.value as String).lengthSync();
          final outputSize = File(dest).lengthSync();
          final reduction = ((inputSize - outputSize) / inputSize * 100)
              .toStringAsFixed(1);
          stderr.writeln(
            'Font "${entry.key}" tree-shaken: $inputSize -> $outputSize bytes ($reduction% reduction).',
          );
          continue;
        }
        _failTreeShaking('Font subsetting failed for ${entry.key}.');
      }
    }

    File(entry.value as String).copySync(dest);
  }
}
