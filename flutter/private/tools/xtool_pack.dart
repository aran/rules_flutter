/// Hermetic Apple application bundle and archive packager for the `xtool`
/// cross-compilation backend.
///
/// Assembles unsigned iOS `.ipa` (`Payload/<AppName>.app/...`) and macOS
/// `.app.zip` (`<AppName>.app/Contents/...`) archives on any host OS (Linux or
/// macOS) without requiring Xcode, `actool`, `ibtool`, `codesign`, or external
/// system zip utilities, or signs them when `zsign` is provided.
///
/// Capabilities:
///   1. XML `Info.plist` merging, variable substitution (`$(EXECUTABLE_NAME)`,
///      `${PRODUCT_BUNDLE_IDENTIFIER}`, `${MACOSX_DEPLOYMENT_TARGET}`, etc.),
///      and standard Apple bundle metadata injection.
///   2. Framework resolution from `.framework` directories, wrapper tree
///      artifacts containing `*.framework`, or `.xcframework` bundles (selecting
///      the appropriate slice for `ios`, `ios_sim`, or `macos`).
///   3. Pure-Dart SHA-1 (RFC 3174) and SHA-256 (FIPS 180-4) digest computation
///      and Apple `_CodeSignature/CodeResources` XML property list generation
///      when signing with `zsign`.
///   4. Optional `zsign` invocation when a `zsign` binary is provided; unsigned
///      bundles omit `_CodeSignature/`.
///   5. Pure-Dart deterministic ZIP archive writer with Unix permission bits
///      (`0755` for executables and framework dylibs, `0644` for resources,
///      `0120777` for symbolic links) and fixed DOS epoch timestamps.
///
/// Usage:
///   dart xtool_pack.dart bundle \
///     --platform <ios|ios_sim|macos> \
///     --app-name <AppName> \
///     --bundle-id <com.example.app> \
///     --executable <path> \
///     --minimum-os-version <version> \
///     [--info-plist <path> ...] \
///     [--define <KEY=VALUE> ...] \
///     [--framework <path> ...] \
///     [--resource <src[=dest_rel]> ...] \
///     [--provisioning-profile <path>] \
///     [--entitlements <path>] \
///     [--zsign <path>] \
///     [--certificate <path>] \
///     [--certificate-password-file <path>] \
///     [--certificate-password-env <ENV_VAR>] \
///     [--temp-dir <path>] \
///     [--output-archive <path>] \
///     [--output-app-dir <path>]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crc32.dart' as crc32lib;
import 'macho_edit.dart' show Segment64Spec, extractFrameworkZip;
import 'sha256.dart' as sha256lib;

// ---------------------------------------------------------------------------
// Pure-Dart SHA-1 (RFC 3174); SHA-256 lives in sha256.dart.
// ---------------------------------------------------------------------------

int _rotl32(int val, int shift) =>
    ((val << shift) & 0xFFFFFFFF) | ((val & 0xFFFFFFFF) >>> (32 - shift));

/// Computes the 20-byte SHA-1 digest of [data] per RFC 3174.
Uint8List sha1Bytes(List<int> data) {
  final msgLen = data.length;
  final bitLen = msgLen * 8;
  // Pad to 64-byte boundary with 0x80 followed by zeros and 64-bit big-endian length.
  final padLen = ((56 - (msgLen + 1) % 64) + 64) % 64;
  final totalLen = msgLen + 1 + padLen + 8;
  final padded = Uint8List(totalLen);
  padded.setRange(0, msgLen, data);
  padded[msgLen] = 0x80;
  final bd = ByteData.sublistView(padded);
  bd.setUint32(totalLen - 8, (bitLen ~/ 0x100000000) & 0xFFFFFFFF, Endian.big);
  bd.setUint32(totalLen - 4, bitLen & 0xFFFFFFFF, Endian.big);

  var h0 = 0x67452301;
  var h1 = 0xEFCDAB89;
  var h2 = 0x98BADCFE;
  var h3 = 0x10325476;
  var h4 = 0xC3D2E1F0;

  final w = Uint32List(80);

  for (var offset = 0; offset < totalLen; offset += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = bd.getUint32(offset + i * 4, Endian.big);
    }
    for (var i = 16; i < 80; i++) {
      w[i] = _rotl32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;

    for (var i = 0; i < 80; i++) {
      final int f;
      final int k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xFFFFFFFF) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final temp = (_rotl32(a, 5) + f + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = _rotl32(b, 30);
      b = a;
      a = temp;
    }

    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
  }

  final out = Uint8List(20);
  final outBd = ByteData.sublistView(out);
  outBd.setUint32(0, h0, Endian.big);
  outBd.setUint32(4, h1, Endian.big);
  outBd.setUint32(8, h2, Endian.big);
  outBd.setUint32(12, h3, Endian.big);
  outBd.setUint32(16, h4, Endian.big);
  return out;
}

/// Computes the 32-byte SHA-256 digest of [data] per FIPS 180-4.
Uint8List sha256Bytes(List<int> data) =>
    Uint8List.fromList(sha256lib.sha256(data));

// ---------------------------------------------------------------------------
// Info.plist parsing, merging, variable substitution, and standard keys
// ---------------------------------------------------------------------------

/// A root `<dict>` entry in an XML property list.
class PlistEntry {
  final String key;
  final String rawValue;

  const PlistEntry(this.key, this.rawValue);
}

/// Cursor over an XML plist string while its top-level `<dict>` entries are
/// read. Holds the mutable scan position that the nested readers share.
class _PlistReader {
  final String xml;
  final String source;
  var pos = 0;

  _PlistReader(this.xml, {required this.source});

  void skipTrivia() {
    while (pos < xml.length) {
      final c = xml[pos];
      if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
        pos++;
      } else if (xml.startsWith('<!--', pos)) {
        final end = xml.indexOf('-->', pos + 4);
        if (end == -1) {
          throw FormatException('Unterminated comment in $source.');
        }
        pos = end + 3;
      } else {
        break;
      }
    }
  }

  (String, bool, bool) readTag() {
    if (pos >= xml.length || xml[pos] != '<') {
      throw FormatException('Expected tag at offset $pos in $source.');
    }
    pos++;
    var isEnd = false;
    if (pos < xml.length && xml[pos] == '/') {
      isEnd = true;
      pos++;
    }
    final name = _readTagName();
    return _readTagClose(name, isEnd);
  }

  String _readTagName() {
    final nameStart = pos;
    while (pos < xml.length && RegExp(r'[A-Za-z0-9_.:-]').hasMatch(xml[pos])) {
      pos++;
    }
    return xml.substring(nameStart, pos);
  }

  (String, bool, bool) _readTagClose(String name, bool isEnd) {
    var inQuote = '';
    while (pos < xml.length) {
      final c = xml[pos];
      if (inQuote.isNotEmpty) {
        if (c == inQuote) inQuote = '';
        pos++;
      } else if (c == '"' || c == "'") {
        inQuote = c;
        pos++;
      } else if (c == '>') {
        pos++;
        return (name, false, isEnd);
      } else if (xml.startsWith('/>', pos)) {
        pos += 2;
        return (name, true, isEnd);
      } else {
        pos++;
      }
    }
    throw FormatException('Unterminated tag <$name in $source.');
  }

  String readElement() {
    final start = pos;
    final (name, selfClosing, isEnd) = readTag();
    if (isEnd) {
      throw FormatException('Unexpected closing tag </$name> in $source.');
    }
    if (selfClosing) return xml.substring(start, pos);
    var depth = 1;
    while (depth > 0) {
      final next = xml.indexOf('<', pos);
      if (next == -1) {
        throw FormatException('Unterminated <$name> in $source.');
      }
      pos = next;
      if (!_skipCommentOrStep()) {
        final (_, nestedSelfClosing, nestedEnd) = readTag();
        if (nestedEnd) {
          depth--;
        } else if (!nestedSelfClosing) {
          depth++;
        }
      }
    }
    return xml.substring(start, pos);
  }

  /// Skips an XML comment at the cursor; returns false when the cursor is on
  /// a real tag that the caller must read.
  bool _skipCommentOrStep() {
    if (!xml.startsWith('<!--', pos)) return false;
    final end = xml.indexOf('-->', pos + 4);
    if (end == -1) {
      throw FormatException('Unterminated comment in $source.');
    }
    pos = end + 3;
    return true;
  }
}

/// Parses the top-level `<dict>` entries of an XML plist.
List<PlistEntry> parsePlistEntries(String xml, {String source = '<memory>'}) {
  final dictStart = xml.indexOf('<dict');
  if (dictStart == -1) {
    if (xml.contains('<dict/>')) return const [];
    throw FormatException('Plist $source does not contain a root <dict>.');
  }
  final openEnd = xml.indexOf('>', dictStart);
  if (openEnd == -1) {
    throw FormatException('Malformed <dict> tag in $source.');
  }
  if (xml[openEnd - 1] == '/') {
    return const [];
  }

  final reader = _PlistReader(xml, source: source)..pos = openEnd + 1;
  final entries = <PlistEntry>[];
  while (true) {
    reader.skipTrivia();
    if (reader.pos >= xml.length) {
      throw FormatException('Root <dict> not closed in $source.');
    }
    final (tagName, selfClosing, isEnd) = reader.readTag();
    if (isEnd) {
      if (tagName != 'dict') {
        throw FormatException('Unexpected </$tagName> in $source.');
      }
      return entries;
    }
    if (tagName != 'key' || selfClosing) {
      throw FormatException('Expected <key> in $source, found <$tagName>.');
    }
    entries.add(_readPlistEntry(xml, reader, source));
  }
}

PlistEntry _readPlistEntry(String xml, _PlistReader reader, String source) {
  final keyClose = xml.indexOf('</key>', reader.pos);
  if (keyClose == -1) {
    throw FormatException('Unclosed <key> in $source.');
  }
  final keyName = xml.substring(reader.pos, keyClose).trim();
  reader.pos = keyClose + '</key>'.length;
  reader.skipTrivia();
  final valueXml = reader.readElement();
  return PlistEntry(keyName, valueXml);
}

/// Substitutes `$(VAR)` and `${VAR}` placeholders in [text] using [variables].
String substitutePlistVariables(String text, Map<String, String> variables) {
  return text.replaceAllMapped(
    RegExp(r'\$\(([A-Za-z0-9_]+)\)|\$\{([A-Za-z0-9_]+)\}'),
    (match) {
      final name = match.group(1) ?? match.group(2)!;
      return variables[name] ?? '';
    },
  );
}

bool _isEmptyPlistString(String rawValue) {
  final trimmed = rawValue.trim();
  return trimmed == '<string></string>' || trimmed == '<string/>';
}

String _escapeXml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Merges plist sources with Xcode variable substitution, remembering key
/// order and overwrite rules.
class _PlistMerger {
  final Map<String, String> variables;
  final merged = <String, String>{};
  final order = <String>[];

  _PlistMerger(this.variables);

  void setEntry(String key, String rawValue, {bool overwriteNonEmpty = true}) {
    final substituted = substitutePlistVariables(rawValue.trim(), variables);
    if (!merged.containsKey(key)) {
      merged[key] = substituted;
      order.add(key);
      return;
    }
    if (_isEmptyPlistString(merged[key]!)) {
      merged[key] = substituted;
      return;
    }
    if (overwriteNonEmpty && !_isEmptyPlistString(substituted)) {
      merged[key] = substituted;
    }
  }

  void dropIfEmpty(String key) {
    if (merged.containsKey(key) && _isEmptyPlistString(merged[key]!)) {
      merged.remove(key);
      order.remove(key);
    }
  }
}

Map<String, String> _basePlistVariables({
  required String appName,
  required String bundleId,
  required String minimumOsVersion,
  required Map<String, String> extraVariables,
}) {
  return {
    'EXECUTABLE_NAME': appName,
    'PRODUCT_NAME': appName,
    'PRODUCT_BUNDLE_IDENTIFIER': bundleId,
    'BUNDLE_IDENTIFIER': bundleId,
    'DEVELOPMENT_LANGUAGE': 'en',
    'MACOSX_DEPLOYMENT_TARGET': minimumOsVersion,
    'IPHONEOS_DEPLOYMENT_TARGET': minimumOsVersion,
    'FLUTTER_BUILD_NAME': '1.0.0',
    'FLUTTER_BUILD_NUMBER': '1',
    ...extraVariables,
  };
}

void _mergePlistSources(_PlistMerger merger, List<String> plistXmls) {
  for (var i = 0; i < plistXmls.length; i++) {
    final entries = parsePlistEntries(plistXmls[i], source: 'plist[$i]');
    for (final entry in entries) {
      merger.setEntry(entry.key, entry.rawValue, overwriteNonEmpty: true);
    }
  }
}

void _applyBuildVersionOverrides(
  _PlistMerger merger,
  Map<String, String> extraVariables,
) {
  // If explicit build/short version variables were supplied, ensure they
  // populate CFBundleVersion / CFBundleShortVersionString even if the base
  // Info.plist had literal strings instead of $(FLUTTER_BUILD_*) placeholders.
  final buildName = extraVariables['FLUTTER_BUILD_NAME'];
  if (buildName != null && buildName.isNotEmpty) {
    merger.setEntry(
      'CFBundleShortVersionString',
      '<string>${_escapeXml(buildName)}</string>',
      overwriteNonEmpty: true,
    );
  }
  final buildNumber = extraVariables['FLUTTER_BUILD_NUMBER'];
  if (buildNumber != null && buildNumber.isNotEmpty) {
    merger.setEntry(
      'CFBundleVersion',
      '<string>${_escapeXml(buildNumber)}</string>',
      overwriteNonEmpty: true,
    );
  }
}

Map<String, String> _standardPlistDefaults(
  Map<String, String> variables,
  String appName,
  String bundleId,
) {
  return {
    'CFBundleDevelopmentRegion': '<string>en</string>',
    'CFBundleExecutable': '<string>${_escapeXml(appName)}</string>',
    'CFBundleIdentifier': '<string>${_escapeXml(bundleId)}</string>',
    'CFBundleInfoDictionaryVersion': '<string>6.0</string>',
    'CFBundleName': '<string>${_escapeXml(appName)}</string>',
    'CFBundlePackageType': '<string>APPL</string>',
    'CFBundleShortVersionString':
        '<string>${_escapeXml(variables['FLUTTER_BUILD_NAME']!)}</string>',
    'CFBundleVersion':
        '<string>${_escapeXml(variables['FLUTTER_BUILD_NUMBER']!)}</string>',
  };
}

String _iosDeviceFamilyXml(List<String> families) {
  final familyIds = <int>[];
  if (families.isEmpty) {
    familyIds.addAll([1, 2]);
  } else {
    for (final f in families) {
      switch (f) {
        case 'iphone':
          if (!familyIds.contains(1)) familyIds.add(1);
        case 'ipad':
          if (!familyIds.contains(2)) familyIds.add(2);
        default:
          throw ArgumentError(
            'Unsupported iOS device family "$f" in families. '
            'Expected "iphone" or "ipad".',
          );
      }
    }
  }
  return '<array>\n${familyIds.map((id) => '\t\t<integer>$id</integer>').join('\n')}\n\t</array>';
}

void _addIosPlistDefaults(
  Map<String, String> defaults,
  String platform,
  String minimumOsVersion,
  List<String> families,
  _PlistMerger merger,
) {
  final supportedPlatform = platform == 'ios_sim'
      ? 'iPhoneSimulator'
      : 'iPhoneOS';
  final dtPlatform = platform == 'ios_sim' ? 'iphonesimulator' : 'iphoneos';
  defaults['MinimumOSVersion'] =
      '<string>${_escapeXml(minimumOsVersion)}</string>';
  defaults['CFBundleSupportedPlatforms'] =
      '<array>\n\t\t<string>$supportedPlatform</string>\n\t</array>';
  defaults['DTPlatformName'] = '<string>$dtPlatform</string>';

  final familyXml = _iosDeviceFamilyXml(families);
  if (families.isNotEmpty) {
    merger.setEntry('UIDeviceFamily', familyXml, overwriteNonEmpty: true);
  } else {
    defaults['UIDeviceFamily'] = familyXml;
  }
}

void _addMacosPlistDefaults(
  Map<String, String> defaults,
  String minimumOsVersion,
) {
  defaults['LSMinimumSystemVersion'] =
      '<string>${_escapeXml(minimumOsVersion)}</string>';
  defaults['CFBundleSupportedPlatforms'] =
      '<array>\n\t\t<string>MacOSX</string>\n\t</array>';
  defaults['DTPlatformName'] = '<string>macosx</string>';
  defaults['NSPrincipalClass'] = '<string>NSApplication</string>';
}

/// The inputs for merging an `Info.plist`: XML sources, bundle identity,
/// and platform defaults. Grouped so the plist entry point stays small.
class InfoPlistRequest {
  const InfoPlistRequest({
    required this.plistXmls,
    required this.platform,
    required this.appName,
    required this.bundleId,
    required this.minimumOsVersion,
    this.extraVariables = const {},
    this.families = const [],
  });

  /// The raw `Info.plist` XML sources to merge.
  final List<String> plistXmls;

  /// The target platform (`ios`, `ios_sim`, or `macos`).
  final String platform;

  /// The `CFBundleName` / executable name.
  final String appName;

  /// The `CFBundleIdentifier` value.
  final String bundleId;

  /// The minimum-OS version string.
  final String minimumOsVersion;

  /// Extra Xcode build-variable substitutions.
  final Map<String, String> extraVariables;

  /// The requested iOS device families.
  final List<String> families;
}

/// Merges zero or more XML `Info.plist` sources, substitutes Xcode build
/// variables, and injects standard Apple bundle keys required by iOS/macOS.
String buildInfoPlist(InfoPlistRequest request) {
  final platform = request.platform;
  final minimumOsVersion = request.minimumOsVersion;
  final families = request.families;
  final extraVariables = request.extraVariables;
  final variables = _basePlistVariables(
    appName: request.appName,
    bundleId: request.bundleId,
    minimumOsVersion: minimumOsVersion,
    extraVariables: extraVariables,
  );
  final merger = _PlistMerger(variables);
  _mergePlistSources(merger, request.plistXmls);

  // Drop empty CFBundleIconFile left by `flutter create` scaffolds if nothing
  // populated it.
  merger.dropIfEmpty('CFBundleIconFile');
  _applyBuildVersionOverrides(merger, extraVariables);

  // Standard Apple bundle defaults (only injected when missing or empty).
  final defaults = _standardPlistDefaults(
    variables,
    request.appName,
    request.bundleId,
  );
  if (platform == 'ios' || platform == 'ios_sim') {
    _addIosPlistDefaults(
      defaults,
      platform,
      minimumOsVersion,
      families,
      merger,
    );
  } else if (platform == 'macos') {
    _addMacosPlistDefaults(defaults, minimumOsVersion);
  }
  for (final entry in defaults.entries) {
    merger.setEntry(entry.key, entry.value, overwriteNonEmpty: false);
  }
  return _renderPlistXml(merger.order, merger.merged);
}

String _renderPlistXml(List<String> order, Map<String, String> merged) {
  final buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    )
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>');
  for (final key in order) {
    final value = merged[key];
    if (value == null) continue;
    buffer
      ..writeln('\t<key>$key</key>')
      ..writeln('\t$value');
  }
  buffer
    ..writeln('</dict>')
    ..writeln('</plist>');
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// _CodeSignature/CodeResources generation
// ---------------------------------------------------------------------------

/// Lists every file under [bundleDir] relative to it, skipping signature
/// artifacts, excluded paths, and symbolic links.
List<String> _collectBundleRelativeFiles(
  Directory bundleDir,
  Set<String> excludedRelativePaths,
) {
  final relativeFiles = <String>[];

  void walk(Directory dir, String relPrefix) {
    final children = dir.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in children) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final relPath = relPrefix.isEmpty ? name : '$relPrefix/$name';
      if (relPath == '_CodeSignature' ||
          relPath.startsWith('_CodeSignature/') ||
          excludedRelativePaths.contains(relPath)) {
        continue;
      }
      if (entity is Link) {
        continue;
      } else if (entity is Directory) {
        walk(entity, relPath);
      } else if (entity is File) {
        relativeFiles.add(relPath);
      }
    }
  }

  if (bundleDir.existsSync()) {
    walk(bundleDir, '');
  }
  relativeFiles.sort();
  return relativeFiles;
}

/// Hashes [relativeFiles] (relative to [rootPath]) into the v1 (`files`) and
/// v2 (`files2`) CodeResources maps, omitting `Info.plist` and `PkgInfo`.
({
  Map<String, String> files1,
  Map<String, ({String sha1B64, String sha256B64})> files2,
})
_hashBundleFiles(String rootPath, List<String> relativeFiles) {
  final files1 = <String, String>{};
  final files2 = <String, ({String sha1B64, String sha256B64})>{};
  for (final relPath in relativeFiles) {
    final bytes = File('$rootPath/$relPath').readAsBytesSync();
    final sha1B64 = base64.encode(sha1Bytes(bytes));
    final sha256B64 = base64.encode(sha256Bytes(bytes));
    // Per Apple CodeResources format, Info.plist and PkgInfo are omitted from
    // `files` / `files2` when rules2 omits them, or included in `files` for v1
    // resources. Including all non-Info.plist/PkgInfo files in both `files` and
    // `files2` matches standard codesign/zsign output.
    if (relPath != 'Info.plist' && relPath != 'PkgInfo') {
      files1[relPath] = sha1B64;
      files2[relPath] = (sha1B64: sha1B64, sha256B64: sha256B64);
    }
  }
  return (files1: files1, files2: files2);
}

/// Generates the XML contents of `_CodeSignature/CodeResources` for [bundleDir].
///
/// For iOS bundles or `.framework` directories, [bundleDir] is the `.app` or
/// `.framework` root. For macOS `.app` bundles, [bundleDir] is
/// `<AppName>.app/Contents`.
///
/// [excludedRelativePaths] specifies paths relative to [bundleDir] (using `/`)
/// that must not be listed in `CodeResources` (such as the main Mach-O
/// executable and `_CodeSignature/CodeResources` itself).
String generateCodeResources(
  Directory bundleDir, {
  Set<String> excludedRelativePaths = const {},
}) {
  final relativeFiles = _collectBundleRelativeFiles(
    bundleDir,
    excludedRelativePaths,
  );
  final (:files1, :files2) = _hashBundleFiles(bundleDir.path, relativeFiles);
  return _renderCodeResourcesXml(files1, files2);
}

String _renderCodeResourcesXml(
  Map<String, String> files1,
  Map<String, ({String sha1B64, String sha256B64})> files2,
) {
  final buf = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
      '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
    )
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>')
    ..writeln('\t<key>files</key>')
    ..writeln('\t<dict>');
  for (final entry in files1.entries) {
    buf
      ..writeln('\t\t<key>${_escapeXml(entry.key)}</key>')
      ..writeln('\t\t<data>${entry.value}</data>');
  }
  buf
    ..writeln('\t</dict>')
    ..writeln('\t<key>files2</key>')
    ..writeln('\t<dict>');
  for (final entry in files2.entries) {
    buf
      ..writeln('\t\t<key>${_escapeXml(entry.key)}</key>')
      ..writeln('\t\t<dict>')
      ..writeln('\t\t\t<key>hash</key>')
      ..writeln('\t\t\t<data>${entry.value.sha1B64}</data>')
      ..writeln('\t\t\t<key>hash2</key>')
      ..writeln('\t\t\t<data>${entry.value.sha256B64}</data>')
      ..writeln('\t\t</dict>');
  }
  buf
    ..writeln('\t</dict>')
    ..writeln('\t<key>rules</key>')
    ..writeln('\t<dict>')
    ..writeln('\t\t<key>^</key>')
    ..writeln('\t\t<true/>')
    ..writeln('\t\t<key>^.*\\.lproj/</key>')
    ..writeln('\t\t<dict>')
    ..writeln('\t\t\t<key>optional</key>')
    ..writeln('\t\t\t<true/>')
    ..writeln('\t\t\t<key>weight</key>')
    ..writeln('\t\t\t<real>1000</real>')
    ..writeln('\t\t</dict>')
    ..writeln('\t</dict>')
    ..writeln('\t<key>rules2</key>')
    ..writeln('\t<dict>')
    ..writeln('\t\t<key>^</key>')
    ..writeln('\t\t<dict>')
    ..writeln('\t\t\t<key>weight</key>')
    ..writeln('\t\t\t<real>20</real>')
    ..writeln('\t\t</dict>')
    ..writeln('\t\t<key>^Info\\.plist\$</key>')
    ..writeln('\t\t<dict>')
    ..writeln('\t\t\t<key>omit</key>')
    ..writeln('\t\t\t<true/>')
    ..writeln('\t\t\t<key>weight</key>')
    ..writeln('\t\t\t<real>20</real>')
    ..writeln('\t\t</dict>')
    ..writeln('\t\t<key>^PkgInfo\$</key>')
    ..writeln('\t\t<dict>')
    ..writeln('\t\t\t<key>omit</key>')
    ..writeln('\t\t\t<true/>')
    ..writeln('\t\t\t<key>weight</key>')
    ..writeln('\t\t\t<real>20</real>')
    ..writeln('\t\t</dict>')
    ..writeln('\t</dict>')
    ..writeln('</dict>')
    ..writeln('</plist>');
  return buf.toString();
}

/// Writes `_CodeSignature/CodeResources` inside [bundleDir].
File writeCodeResources(
  Directory bundleDir, {
  Set<String> excludedRelativePaths = const {},
}) {
  final xml = generateCodeResources(
    bundleDir,
    excludedRelativePaths: excludedRelativePaths,
  );
  final sigDir = Directory('${bundleDir.path}/_CodeSignature')
    ..createSync(recursive: true);
  final file = File('${sigDir.path}/CodeResources');
  file.writeAsStringSync(xml);
  return file;
}

// ---------------------------------------------------------------------------
// Pure-Dart Deterministic ZIP Archive Writer & Reader
// ---------------------------------------------------------------------------

/// Computes the IEEE 802.3 CRC-32 checksum of [bytes].
int crc32(List<int> bytes) => crc32lib.crc32(bytes);

class _BytesSink implements Sink<List<int>> {
  final BytesBuilder builder = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    builder.add(data);
  }

  @override
  void close() {}
}

class _CrcAndSizeSink implements Sink<List<int>> {
  int _crc = 0xFFFFFFFF;
  int totalLength = 0;

  int get crc32Value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  @override
  void add(List<int> data) {
    _crc = crc32lib.crc32Update(_crc, data);
    totalLength += data.length;
  }

  @override
  void close() {}
}

void _setUint64LE(ByteData bd, int offset, int value) {
  bd.setUint32(offset, value & 0xFFFFFFFF, Endian.little);
  bd.setUint32(offset + 4, (value >>> 32) & 0xFFFFFFFF, Endian.little);
}

int _getUint64LE(ByteData bd, int offset) {
  final lo = bd.getUint32(offset, Endian.little);
  final hi = bd.getUint32(offset + 4, Endian.little);
  return ((hi & 0x7FFFFFFF) * 0x100000000) + lo;
}

const int _zip64Limit16 = 0xFFFF;
const int _zip64Limit32 = 0xFFFFFFFF;
const int _zip64HeaderId = 0x0001;
const int _streamingFileThreshold = 64 * 1024 * 1024; // 64 MiB

/// An entry in a deterministic ZIP archive.
class ZipEntry {
  final String path;
  final Uint8List data;
  final Uint8List? compressedData;
  final int? uncompressedSizeOverride;
  final int? crc32Override;
  final bool isDirectory;
  final bool isExecutable;
  final bool isSymlink;

  /// When true, [encodeDeterministicZip] writes the entry stored (method 0)
  /// even when deflating would shrink it. Native Android libraries (`.so`)
  /// need this: the APK stores them uncompressed so `zipalign` can
  /// page-align them, and the APK overlay copies them without inflating.
  final bool storeOnly;

  const ZipEntry({
    required this.path,
    required this.data,
    this.compressedData,
    this.uncompressedSizeOverride,
    this.crc32Override,
    this.isDirectory = false,
    this.isExecutable = false,
    this.isSymlink = false,
    this.storeOnly = false,
  });

  /// The uncompressed byte length of this entry (including 64-bit ZIP64 sizes).
  int get uncompressedSize => uncompressedSizeOverride ?? data.length;
}

/// Builds a deterministic ZIP archive from [rootDir].
///
/// [executablePaths] contains relative archive paths (using `/`) that receive
/// `0755` (`-rwxr-xr-x`) Unix permissions. All other regular files receive
/// `0644` (`-rw-r--r--`), directories receive `0755` (`drwxr-xr-x`), and
/// symbolic links receive `0120777` (`lrwxrwxrwx`). Host filesystem mode bits
/// are never inherited.
Uint8List createDeterministicZipFromDirectory(
  Directory rootDir, {
  Set<String> executablePaths = const {},
}) {
  final entries = <ZipEntry>[];
  _collectZipEntries(entries, rootDir, '', executablePaths);
  return encodeDeterministicZip(entries);
}

/// Reads [entity] as a streaming deflated ZIP entry, computing its CRC-32
/// incrementally so files larger than [_streamingFileThreshold] never sit
/// fully inflated in memory.
ZipEntry _streamingZipEntry(File entity, String relPath, bool isExec) {
  final fileSize = entity.lengthSync();
  final raf = entity.openSync(mode: FileMode.read);
  try {
    final bytesSink = _BytesSink();
    final deflateSink = ZLibEncoder(raw: true).startChunkedConversion(
      bytesSink,
    );
    final chunkBuf = Uint8List(1024 * 1024);
    var runningCrc = 0xFFFFFFFF;
    while (true) {
      final n = raf.readIntoSync(chunkBuf);
      if (n <= 0) break;
      runningCrc = crc32lib.crc32Update(runningCrc, chunkBuf, n);
      deflateSink.add(Uint8List.sublistView(chunkBuf, 0, n));
    }
    deflateSink.close();
    return ZipEntry(
      path: relPath,
      data: Uint8List(0),
      compressedData: bytesSink.builder.takeBytes(),
      uncompressedSizeOverride: fileSize,
      crc32Override: (runningCrc ^ 0xFFFFFFFF) & 0xFFFFFFFF,
      isExecutable: isExec,
    );
  } finally {
    raf.closeSync();
  }
}

void _collectZipEntries(
  List<ZipEntry> entries,
  Directory dir,
  String relPrefix,
  Set<String> executablePaths,
) {
  final children = dir.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in children) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final relPath = relPrefix.isEmpty ? name : '$relPrefix/$name';
    if (entity is Link) {
      final target = entity.targetSync();
      entries.add(
        ZipEntry(
          path: relPath,
          data: Uint8List.fromList(utf8.encode(target)),
          isSymlink: true,
        ),
      );
    } else if (entity is Directory) {
      entries.add(
        ZipEntry(path: '$relPath/', data: Uint8List(0), isDirectory: true),
      );
      _collectZipEntries(entries, entity, relPath, executablePaths);
    } else if (entity is File) {
      // File modes are determined strictly from the entry role via
      // executablePaths, never from host filesystem stat.mode bits.
      final isExec = executablePaths.contains(relPath);
      if (entity.lengthSync() > _streamingFileThreshold) {
        entries.add(_streamingZipEntry(entity, relPath, isExec));
      } else {
        entries.add(
          ZipEntry(
            path: relPath,
            data: entity.readAsBytesSync(),
            isExecutable: isExec,
          ),
        );
      }
    }
  }
}

/// Encodes [entries] into a deterministic ZIP (or ZIP64) byte buffer.
///
/// Automatically writes ZIP64 extended information extra fields (`0x0001`),
/// ZIP64 End of Central Directory record (`0x06064b50`), and ZIP64 End of
/// Central Directory Locator (`0x07064b50`) when entry count >= 65,535 or any
/// entry size or offset >= 4 GiB (`0xFFFFFFFF`).
/// A ZIP entry's chosen on-disk representation: compression method (0 for
/// stored, 8 for deflate), payload bytes, uncompressed length, and CRC-32.
typedef _ZipPayload = ({
  int method,
  Uint8List payload,
  int uncompressedLen,
  int crc,
});

/// Stateful writer for the local-file and central-directory sections of a
/// deterministic ZIP archive. Tracks the running data offset and whether any
/// entry needed ZIP64 extended information.
class _DeterministicZipEncoder {
  final localParts = BytesBuilder(copy: false);
  final centralParts = BytesBuilder(copy: false);
  final rawDeflate = ZLibCodec(raw: true);
  var offset = 0;
  var anyEntryZip64 = false;

  // Fixed DOS timestamp: 1980-01-01 00:00:00 (time = 0, date = 0x0021).
  static const dosTime = 0x0000;
  static const dosDate = 0x0021;
  // Version made by: Unix (3) << 8 | ZIP 2.0 (20) or ZIP 4.5 (45) for ZIP64.
  static const versionMadeByStandard = (3 << 8) | 20;
  static const versionMadeByZip64 = (3 << 8) | 45;
  static const versionNeededStandard = 20;
  static const versionNeededZip64 = 45;

  void writeEntry(ZipEntry entry) {
    final nameBytes = utf8.encode(entry.path);
    final record = _chooseZipPayload(entry);
    final externalAttrs = _zipExternalAttrs(entry);
    final localExtra = _localZip64Extra(
      record.uncompressedLen,
      record.payload.length,
    );
    _writeLocalRecord(nameBytes, record, localExtra);
    _writeCentralRecord(nameBytes, record, localExtra, externalAttrs);
    offset += 30 + nameBytes.length + localExtra.length + record.payload.length;
  }

  _ZipPayload _chooseZipPayload(ZipEntry entry) {
    final uncompressed = entry.data;
    final uncompressedLen = entry.uncompressedSize;
    final crc = entry.isDirectory
        ? 0
        : (entry.crc32Override ?? crc32(uncompressed));
    if (entry.storeOnly && entry.compressedData != null) {
      throw ArgumentError(
        'encodeDeterministicZip: entry ${entry.path} is storeOnly but '
        'carries compressedData.',
      );
    }
    var compressionMethod = 0; // Stored
    var payload = uncompressed;
    if (entry.compressedData != null) {
      compressionMethod = 8; // Deflate
      payload = entry.compressedData!;
    } else if (_shouldDeflate(entry, uncompressed)) {
      final deflated = Uint8List.fromList(rawDeflate.encode(uncompressed));
      if (deflated.length < uncompressed.length) {
        compressionMethod = 8; // Deflate
        payload = deflated;
      }
    }
    return (
      method: compressionMethod,
      payload: payload,
      uncompressedLen: uncompressedLen,
      crc: crc,
    );
  }

  bool _shouldDeflate(ZipEntry entry, Uint8List uncompressed) {
    return !entry.storeOnly &&
        !entry.isDirectory &&
        !entry.isSymlink &&
        uncompressed.isNotEmpty &&
        entry.uncompressedSizeOverride == null;
  }

  int _zipExternalAttrs(ZipEntry entry) {
    if (entry.isDirectory) {
      return (0x41ED << 16) | 0x10; // drwxr-xr-x + DOS directory bit
    } else if (entry.isSymlink) {
      return (0xA1FF << 16); // lrwxrwxrwx
    } else if (entry.isExecutable) {
      return (0x81ED << 16); // -rwxr-xr-x
    } else {
      return (0x81A4 << 16); // -rw-r--r--
    }
  }

  Uint8List _localZip64Extra(int uncompressedLen, int compressedLen) {
    if (uncompressedLen < _zip64Limit32 && compressedLen < _zip64Limit32) {
      return Uint8List(0);
    }
    anyEntryZip64 = true;
    final localExtra = Uint8List(20);
    final extraBd = ByteData.sublistView(localExtra);
    extraBd.setUint16(0, _zip64HeaderId, Endian.little);
    extraBd.setUint16(2, 16, Endian.little);
    _setUint64LE(extraBd, 4, uncompressedLen);
    _setUint64LE(extraBd, 12, compressedLen);
    return localExtra;
  }

  void _writeLocalRecord(
    List<int> nameBytes,
    _ZipPayload record,
    Uint8List localExtra,
  ) {
    final localNeedZip64 = localExtra.isNotEmpty;
    final localVersionNeeded = localNeedZip64
        ? versionNeededZip64
        : versionNeededStandard;
    // Local file header (30 bytes + filename + extra + payload).
    final localHeader = ByteData(30 + nameBytes.length + localExtra.length);
    localHeader.setUint32(0, 0x04034b50, Endian.little);
    localHeader.setUint16(4, localVersionNeeded, Endian.little);
    localHeader.setUint16(6, 0x0800, Endian.little); // UTF-8 flag
    localHeader.setUint16(8, record.method, Endian.little);
    localHeader.setUint16(10, dosTime, Endian.little);
    localHeader.setUint16(12, dosDate, Endian.little);
    localHeader.setUint32(14, record.crc, Endian.little);
    localHeader.setUint32(
      18,
      localNeedZip64 ? _zip64Limit32 : record.payload.length,
      Endian.little,
    );
    localHeader.setUint32(
      22,
      localNeedZip64 ? _zip64Limit32 : record.uncompressedLen,
      Endian.little,
    );
    localHeader.setUint16(26, nameBytes.length, Endian.little);
    localHeader.setUint16(28, localExtra.length, Endian.little);
    localHeader.buffer.asUint8List().setRange(
      30,
      30 + nameBytes.length,
      nameBytes,
    );
    if (localExtra.isNotEmpty) {
      localHeader.buffer.asUint8List().setRange(
        30 + nameBytes.length,
        30 + nameBytes.length + localExtra.length,
        localExtra,
      );
    }
    localParts.add(localHeader.buffer.asUint8List());
    localParts.add(record.payload);
  }

  Uint8List _centralZip64Extra(
    int uncompressedLen,
    int compressedLen,
    int entryOffset,
  ) {
    final needUncompressed64 = uncompressedLen >= _zip64Limit32;
    final needCompressed64 = compressedLen >= _zip64Limit32;
    final needOffset64 = entryOffset >= _zip64Limit32;
    if (!needUncompressed64 && !needCompressed64 && !needOffset64) {
      return Uint8List(0);
    }
    anyEntryZip64 = true;
    final fieldCount =
        (needUncompressed64 ? 1 : 0) +
        (needCompressed64 ? 1 : 0) +
        (needOffset64 ? 1 : 0);
    final cdExtra = Uint8List(4 + fieldCount * 8);
    final extraBd = ByteData.sublistView(cdExtra);
    extraBd.setUint16(0, _zip64HeaderId, Endian.little);
    extraBd.setUint16(2, fieldCount * 8, Endian.little);
    var fieldPos = 4;
    if (needUncompressed64) {
      _setUint64LE(extraBd, fieldPos, uncompressedLen);
      fieldPos += 8;
    }
    if (needCompressed64) {
      _setUint64LE(extraBd, fieldPos, compressedLen);
      fieldPos += 8;
    }
    if (needOffset64) {
      _setUint64LE(extraBd, fieldPos, entryOffset);
      fieldPos += 8;
    }
    return cdExtra;
  }

  void _writeCentralRecord(
    List<int> nameBytes,
    _ZipPayload record,
    Uint8List localExtra,
    int externalAttrs,
  ) {
    final cdExtra = _centralZip64Extra(
      record.uncompressedLen,
      record.payload.length,
      offset,
    );
    final cdNeedZip64 = cdExtra.isNotEmpty || localExtra.isNotEmpty;
    final cdVersionMadeBy = cdNeedZip64
        ? versionMadeByZip64
        : versionMadeByStandard;
    final cdVersionNeeded = cdNeedZip64
        ? versionNeededZip64
        : versionNeededStandard;
    // Central directory header (46 bytes + filename + extra).
    final centralHeader = ByteData(46 + nameBytes.length + cdExtra.length);
    centralHeader.setUint32(0, 0x02014b50, Endian.little);
    centralHeader.setUint16(4, cdVersionMadeBy, Endian.little);
    centralHeader.setUint16(6, cdVersionNeeded, Endian.little);
    centralHeader.setUint16(8, 0x0800, Endian.little); // UTF-8 flag
    centralHeader.setUint16(10, record.method, Endian.little);
    centralHeader.setUint16(12, dosTime, Endian.little);
    centralHeader.setUint16(14, dosDate, Endian.little);
    centralHeader.setUint32(16, record.crc, Endian.little);
    centralHeader.setUint32(
      20,
      record.payload.length >= _zip64Limit32
          ? _zip64Limit32
          : record.payload.length,
      Endian.little,
    );
    centralHeader.setUint32(
      24,
      record.uncompressedLen >= _zip64Limit32
          ? _zip64Limit32
          : record.uncompressedLen,
      Endian.little,
    );
    centralHeader.setUint16(28, nameBytes.length, Endian.little);
    centralHeader.setUint16(30, cdExtra.length, Endian.little);
    centralHeader.setUint16(32, 0, Endian.little); // comment len
    centralHeader.setUint16(34, 0, Endian.little); // disk number
    centralHeader.setUint16(36, 0, Endian.little); // internal attrs
    centralHeader.setUint32(38, externalAttrs, Endian.little);
    centralHeader.setUint32(
      42,
      offset >= _zip64Limit32 ? _zip64Limit32 : offset,
      Endian.little,
    );
    centralHeader.buffer.asUint8List().setRange(
      46,
      46 + nameBytes.length,
      nameBytes,
    );
    if (cdExtra.isNotEmpty) {
      centralHeader.buffer.asUint8List().setRange(
        46 + nameBytes.length,
        46 + nameBytes.length + cdExtra.length,
        cdExtra,
      );
    }
    centralParts.add(centralHeader.buffer.asUint8List());
  }

  Uint8List finish(int entryCount) {
    final centralBytes = centralParts.takeBytes();
    final cdSize = centralBytes.length;
    final cdOffset = offset;
    localParts.add(centralBytes);
    final needZip64Eocd =
        anyEntryZip64 ||
        entryCount >= _zip64Limit16 ||
        cdSize >= _zip64Limit32 ||
        cdOffset >= _zip64Limit32;
    if (needZip64Eocd) {
      _writeZip64Eocd(cdOffset, cdSize, entryCount);
    }
    _writeEocd(entryCount, cdSize, cdOffset);
    return localParts.takeBytes();
  }

  void _writeZip64Eocd(int cdOffset, int cdSize, int entryCount) {
    final zip64EocdOffset = cdOffset + cdSize;
    // ZIP64 End of Central Directory Record (56 bytes).
    final zip64Eocd = ByteData(56);
    zip64Eocd.setUint32(0, 0x06064b50, Endian.little);
    _setUint64LE(zip64Eocd, 4, 44); // size of remaining record (56 - 12)
    zip64Eocd.setUint16(12, versionMadeByZip64, Endian.little);
    zip64Eocd.setUint16(14, versionNeededZip64, Endian.little);
    zip64Eocd.setUint32(16, 0, Endian.little); // number of this disk
    zip64Eocd.setUint32(20, 0, Endian.little); // disk with start of CD
    _setUint64LE(zip64Eocd, 24, entryCount);
    _setUint64LE(zip64Eocd, 32, entryCount);
    _setUint64LE(zip64Eocd, 40, cdSize);
    _setUint64LE(zip64Eocd, 48, cdOffset);
    localParts.add(zip64Eocd.buffer.asUint8List());

    // ZIP64 End of Central Directory Locator (20 bytes).
    final zip64Locator = ByteData(20);
    zip64Locator.setUint32(0, 0x07064b50, Endian.little);
    zip64Locator.setUint32(4, 0, Endian.little); // disk with ZIP64 EOCD
    _setUint64LE(zip64Locator, 8, zip64EocdOffset);
    zip64Locator.setUint32(16, 1, Endian.little); // total number of disks
    localParts.add(zip64Locator.buffer.asUint8List());
  }

  void _writeEocd(int entryCount, int cdSize, int cdOffset) {
    final eocd = ByteData(22);
    eocd.setUint32(0, 0x06054b50, Endian.little);
    eocd.setUint16(4, 0, Endian.little);
    eocd.setUint16(6, 0, Endian.little);
    eocd.setUint16(
      8,
      entryCount >= _zip64Limit16 ? _zip64Limit16 : entryCount,
      Endian.little,
    );
    eocd.setUint16(
      10,
      entryCount >= _zip64Limit16 ? _zip64Limit16 : entryCount,
      Endian.little,
    );
    eocd.setUint32(
      12,
      cdSize >= _zip64Limit32 ? _zip64Limit32 : cdSize,
      Endian.little,
    );
    eocd.setUint32(
      16,
      cdOffset >= _zip64Limit32 ? _zip64Limit32 : cdOffset,
      Endian.little,
    );
    eocd.setUint16(20, 0, Endian.little);
    localParts.add(eocd.buffer.asUint8List());
  }
}

/// Encodes [entries] into a deterministic ZIP (or ZIP64) byte buffer.
///
/// Automatically writes ZIP64 extended information extra fields (`0x0001`),
/// ZIP64 End of Central Directory record (`0x06064b50`), and ZIP64 End of
/// Central Directory Locator (`0x07064b50`) when entry count >= 65,535 or any
/// entry size or offset >= 4 GiB (`0xFFFFFFFF`).
Uint8List encodeDeterministicZip(List<ZipEntry> entries) {
  final sorted = [...entries]..sort((a, b) => a.path.compareTo(b.path));
  final encoder = _DeterministicZipEncoder();
  for (final entry in sorted) {
    encoder.writeEntry(entry);
  }
  return encoder.finish(sorted.length);
}

/// Central-directory record fields shared by the ZIP readers.
typedef _CentralRecord = ({
  String path,
  int method,
  int flags,
  int crc,
  int compressedSize,
  int uncompressedSize,
  int externalAttrs,
  int localOffset,
  int nextPos,
});

int _findEocdOffset(ByteData bd, Uint8List zipBytes) {
  // Locate End of Central Directory (0x06054b50).
  for (var i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      return i;
    }
  }
  throw FormatException('Invalid ZIP archive: EOCD signature not found.');
}

/// Applies the ZIP64 End of Central Directory locator when present,
/// returning the authoritative entry count and central-directory offset.
({int entryCount, int cdOffset}) _applyZip64Locator(
  ByteData bd,
  Uint8List zipBytes,
  int eocdOffset,
  int entryCount,
  int cdOffset,
) {
  // Check for ZIP64 End of Central Directory Locator (0x07064b50) immediately
  // preceding the standard EOCD record.
  if (eocdOffset >= 20 &&
      bd.getUint32(eocdOffset - 20, Endian.little) == 0x07064b50) {
    final zip64EocdOffset = _getUint64LE(bd, eocdOffset - 20 + 8);
    if (zip64EocdOffset + 56 > zipBytes.length ||
        bd.getUint32(zip64EocdOffset, Endian.little) != 0x06064b50) {
      throw FormatException(
        'Invalid ZIP64 archive: ZIP64 EOCD signature not found at $zip64EocdOffset.',
      );
    }
    return (
      entryCount: _getUint64LE(bd, zip64EocdOffset + 32),
      cdOffset: _getUint64LE(bd, zip64EocdOffset + 48),
    );
  }
  return (entryCount: entryCount, cdOffset: cdOffset);
}

/// Applies the ZIP64 extended information extra field (`0x0001`) to 32-bit
/// size/offset markers, returning the resolved values and whether the field
/// was present.
({
  int uncompressedSize,
  int compressedSize,
  int localOffset,
  bool found,
})
_applyZip64ExtraField(
  ByteData bd,
  int extraStart,
  int extraEnd,
  int uncompressedSize,
  int compressedSize,
  int localOffset,
) {
  var extraPos = extraStart;
  while (extraPos + 4 <= extraEnd) {
    final headerId = bd.getUint16(extraPos, Endian.little);
    final dataSize = bd.getUint16(extraPos + 2, Endian.little);
    final fieldDataStart = extraPos + 4;
    if (headerId == _zip64HeaderId) {
      var fieldPos = fieldDataStart;
      if (uncompressedSize == _zip64Limit32 &&
          fieldPos + 8 <= fieldDataStart + dataSize) {
        uncompressedSize = _getUint64LE(bd, fieldPos);
        fieldPos += 8;
      }
      if (compressedSize == _zip64Limit32 &&
          fieldPos + 8 <= fieldDataStart + dataSize) {
        compressedSize = _getUint64LE(bd, fieldPos);
        fieldPos += 8;
      }
      if (localOffset == _zip64Limit32 &&
          fieldPos + 8 <= fieldDataStart + dataSize) {
        localOffset = _getUint64LE(bd, fieldPos);
        fieldPos += 8;
      }
      return (
        uncompressedSize: uncompressedSize,
        compressedSize: compressedSize,
        localOffset: localOffset,
        found: true,
      );
    }
    extraPos += 4 + dataSize;
  }
  return (
    uncompressedSize: uncompressedSize,
    compressedSize: compressedSize,
    localOffset: localOffset,
    found: false,
  );
}

/// How strictly a central-directory record is validated while parsing.
///
/// The inflating reader is lenient (archives with trailing data descriptors
/// and 64-bit sizes it never needs still read); the raw reader is strict
/// (it refuses anything below the ZIP32 limits it cannot represent).
class _CentralParseOptions {
  const _CentralParseOptions({
    required this.checkBounds,
    required this.flagsOverride,
    required this.strictZip64,
  });

  final bool checkBounds;
  final int? flagsOverride;
  final bool strictZip64;
}

/// Parses one central-directory record at [pos] with ZIP64 size resolution.
///
/// [options] selects the header checks, the flags value, and the ZIP64 policy
/// of the caller; everything else is shared.
_CentralRecord _parseCentralRecord(
  ByteData bd,
  Uint8List zipBytes,
  int pos,
  _CentralParseOptions options,
) {
  if ((options.checkBounds && pos + 46 > zipBytes.length) ||
      bd.getUint32(pos, Endian.little) != 0x02014b50) {
    throw FormatException('Invalid central directory header at $pos.');
  }
  final flags = options.flagsOverride ?? bd.getUint16(pos + 8, Endian.little);
  final method = bd.getUint16(pos + 10, Endian.little);
  final crc = bd.getUint32(pos + 16, Endian.little);
  var compressedSize = bd.getUint32(pos + 20, Endian.little);
  var uncompressedSize = bd.getUint32(pos + 24, Endian.little);
  final nameLen = bd.getUint16(pos + 28, Endian.little);
  final extraLen = bd.getUint16(pos + 30, Endian.little);
  final commentLen = bd.getUint16(pos + 32, Endian.little);
  final externalAttrs = bd.getUint32(pos + 38, Endian.little);
  var localOffset = bd.getUint32(pos + 42, Endian.little);

  if (options.checkBounds && pos + 46 + nameLen > zipBytes.length) {
    throw FormatException('Invalid central directory header at $pos.');
  }
  final path = utf8.decode(zipBytes.sublist(pos + 46, pos + 46 + nameLen));

  if (uncompressedSize == _zip64Limit32 ||
      compressedSize == _zip64Limit32 ||
      localOffset == _zip64Limit32) {
    final extraStart = pos + 46 + nameLen;
    final resolved = _applyZip64ExtraField(
      bd,
      extraStart,
      extraStart + extraLen,
      uncompressedSize,
      compressedSize,
      localOffset,
    );
    uncompressedSize = resolved.uncompressedSize;
    compressedSize = resolved.compressedSize;
    localOffset = resolved.localOffset;
    if (options.strictZip64 &&
        !resolved.found &&
        (uncompressedSize == _zip64Limit32 ||
            compressedSize == _zip64Limit32 ||
            localOffset == _zip64Limit32)) {
      throw FormatException(
        'ZIP64 entry "$path" has no ZIP64 extra field; 64-bit sizes are '
        'not supported here.',
      );
    }
  }

  return (
    path: path,
    method: method,
    flags: flags,
    crc: crc,
    compressedSize: compressedSize,
    uncompressedSize: uncompressedSize,
    externalAttrs: externalAttrs,
    localOffset: localOffset,
    nextPos: pos + 46 + nameLen + extraLen + commentLen,
  );
}

_CentralRecord _parseInflatedCentralRecord(
  ByteData bd,
  Uint8List zipBytes,
  int pos,
) => _parseCentralRecord(
  bd,
  zipBytes,
  pos,
  const _CentralParseOptions(
    checkBounds: false,
    flagsOverride: 0,
    strictZip64: false,
  ),
);

/// Inflates one entry's payload, verifying checksums for large streaming
/// entries without holding them inflated in memory.
({
  Uint8List data,
  int? uncompressedSizeOverride,
  int? crc32Override,
})
_inflateZipPayload(
  ByteData bd,
  Uint8List zipBytes,
  ZLibCodec rawInflate,
  _CentralRecord central,
) {
  if (bd.getUint32(central.localOffset, Endian.little) != 0x04034b50) {
    throw FormatException(
      'Invalid local file header at ${central.localOffset}.',
    );
  }
  final localNameLen = bd.getUint16(central.localOffset + 26, Endian.little);
  final localExtraLen = bd.getUint16(central.localOffset + 28, Endian.little);
  final dataStart = central.localOffset + 30 + localNameLen + localExtraLen;
  final rawPayload = Uint8List.sublistView(
    zipBytes,
    dataStart,
    dataStart + central.compressedSize,
  );

  if (central.method == 0) {
    final data = Uint8List.fromList(rawPayload);
    return (
      data: data,
      uncompressedSizeOverride: central.uncompressedSize != data.length
          ? central.uncompressedSize
          : null,
      crc32Override: central.crc,
    );
  }
  if (central.method == 8) {
    if (central.uncompressedSize > _streamingFileThreshold) {
      return _inflateStreamingZipPayload(central, rawPayload);
    }
    final data = Uint8List.fromList(rawInflate.decode(rawPayload));
    return (
      data: data,
      uncompressedSizeOverride: central.uncompressedSize != data.length
          ? central.uncompressedSize
          : null,
      crc32Override: central.crc,
    );
  }
  throw UnsupportedError(
    'Unsupported ZIP compression method: ${central.method}',
  );
}

({
  Uint8List data,
  int? uncompressedSizeOverride,
  int? crc32Override,
})
_inflateStreamingZipPayload(_CentralRecord central, Uint8List rawPayload) {
  final crcSink = _CrcAndSizeSink();
  final inflateSink = ZLibDecoder(
    raw: true,
  ).startChunkedConversion(crcSink);
  const step = 1024 * 1024;
  for (var off = 0; off < rawPayload.length; off += step) {
    final end = (off + step < rawPayload.length)
        ? off + step
        : rawPayload.length;
    inflateSink.add(Uint8List.sublistView(rawPayload, off, end));
  }
  inflateSink.close();
  if (crcSink.totalLength != central.uncompressedSize) {
    throw FormatException(
      'ZIP64 inflated length mismatch for "${central.path}": '
      'expected ${central.uncompressedSize}, got ${crcSink.totalLength}.',
    );
  }
  if (crcSink.crc32Value != central.crc) {
    throw FormatException(
      'ZIP64 CRC-32 mismatch for "${central.path}": '
      'expected 0x${central.crc.toRadixString(16)}, '
      'got 0x${crcSink.crc32Value.toRadixString(16)}.',
    );
  }
  return (
    data: Uint8List(0),
    uncompressedSizeOverride: crcSink.totalLength,
    crc32Override: crcSink.crc32Value,
  );
}

({bool isDir, bool isSymlink, bool isExec}) _zipModeFlags(
  int externalAttrs,
  String path,
) {
  final unixMode = (externalAttrs >>> 16) & 0xFFFF;
  final fileType = unixMode & 0xF000;
  final isDir = path.endsWith('/') || fileType == 0x4000;
  final isSymlink = fileType == 0xA000;
  return (
    isDir: isDir,
    isSymlink: isSymlink,
    isExec: !isDir && !isSymlink && ((unixMode & 0x49) != 0),
  );
}

/// Decodes a ZIP or ZIP64 archive produced by [encodeDeterministicZip] (or
/// standard ZIP writers) into a list of [ZipEntry] items for inspection and
/// testing.
List<ZipEntry> readZipEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  final eocdOffset = _findEocdOffset(bd, zipBytes);
  final located = _applyZip64Locator(
    bd,
    zipBytes,
    eocdOffset,
    bd.getUint16(eocdOffset + 10, Endian.little),
    bd.getUint32(eocdOffset + 16, Endian.little),
  );
  final rawInflate = ZLibCodec(raw: true);

  final entries = <ZipEntry>[];
  var pos = located.cdOffset;
  for (var i = 0; i < located.entryCount; i++) {
    final central = _parseInflatedCentralRecord(bd, zipBytes, pos);
    pos = central.nextPos;
    final payload = _inflateZipPayload(bd, zipBytes, rawInflate, central);
    final flags = _zipModeFlags(central.externalAttrs, central.path);
    entries.add(
      ZipEntry(
        path: central.path,
        data: payload.data,
        uncompressedSizeOverride: payload.uncompressedSizeOverride,
        crc32Override: payload.crc32Override,
        isDirectory: flags.isDir,
        isExecutable: flags.isExec,
        isSymlink: flags.isSymlink,
      ),
    );
  }
  return entries;
}

/// A ZIP entry's on-disk payload, without inflating.
///
/// Unlike [readZipEntries], this never inflates deflated data and never drops
/// large entries: [rawData] is a view onto [zipBytes] holding the entry's
/// bytes exactly as stored (deflated bytes when [method] is 8), so entries of
/// any size below the ZIP32 limits can be copied through (for example a
/// stored native library spliced from one archive into another).
class ZipRawEntry {
  /// Archive path, UTF-8 decoded from the central directory.
  final String path;

  /// Compression method: 0 (stored) or 8 (deflated).
  final int method;

  /// CRC-32 of the uncompressed data, from the central directory.
  final int crc;

  /// Uncompressed byte length, with the ZIP64 extra field applied.
  final int uncompressedSize;

  /// The entry's bytes as stored: uncompressed content when [method] is 0,
  /// deflated content when [method] is 8. A view onto the input buffer.
  final Uint8List rawData;
  final bool isDirectory;

  const ZipRawEntry({
    required this.path,
    required this.method,
    required this.crc,
    required this.uncompressedSize,
    required this.rawData,
    required this.isDirectory,
  });
}

/// Reads the central directory of [zipBytes], returning each entry's raw
/// payload without inflating.
///
/// Refuses archives without a readable extra field where a 64-bit size marker
/// appears (writers that need 64-bit sizes must emit the ZIP64 extra fields
/// [encodeDeterministicZip] emits), encrypted entries, and unsupported
/// compression methods. Entries with data descriptors (bit 3) read fine: the
/// central record carries the authoritative sizes. Anything else below the
/// ZIP32 limits reads, at any size.
int _findRawEocdOffset(ByteData bd, Uint8List zipBytes) {
  // Locate End of Central Directory (0x06054b50): the last occurrence that
  // exactly consumes the trailing bytes (signature + comment).
  for (var i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50 &&
        i + 22 + bd.getUint16(i + 20, Endian.little) == zipBytes.length) {
      return i;
    }
    // The EOCD must lie within the last 64 KiB + 22 bytes; stop early.
    if (i < zipBytes.length - 22 - 65536) break;
  }
  throw FormatException('Invalid ZIP archive: EOCD signature not found.');
}

_CentralRecord _parseRawCentralRecord(
  ByteData bd,
  Uint8List zipBytes,
  int pos,
) => _parseCentralRecord(
  bd,
  zipBytes,
  pos,
  const _CentralParseOptions(
    checkBounds: true,
    flagsOverride: null,
    strictZip64: true,
  ),
);

ZipRawEntry _materializeRawEntry(
  ByteData bd,
  Uint8List zipBytes,
  _CentralRecord central,
) {
  if (central.method != 0 && central.method != 8) {
    throw UnsupportedError(
      'Unsupported ZIP compression method ${central.method} for "${central.path}".',
    );
  }
  if ((central.flags & 0x01) != 0) {
    throw FormatException(
      'Encrypted ZIP entries are not supported: ${central.path}.',
    );
  }
  if (central.localOffset + 30 > zipBytes.length ||
      bd.getUint32(central.localOffset, Endian.little) != 0x04034b50) {
    throw FormatException(
      'Invalid local file header at ${central.localOffset}.',
    );
  }
  final localNameLen = bd.getUint16(central.localOffset + 26, Endian.little);
  final localExtraLen = bd.getUint16(central.localOffset + 28, Endian.little);
  final dataStart = central.localOffset + 30 + localNameLen + localExtraLen;
  if (dataStart + central.compressedSize > zipBytes.length) {
    throw FormatException(
      'ZIP entry "${central.path}" overruns the archive '
      '(offset $dataStart, size ${central.compressedSize}).',
    );
  }
  final rawPayload = Uint8List.sublistView(
    zipBytes,
    dataStart,
    dataStart + central.compressedSize,
  );

  final unixMode = (central.externalAttrs >>> 16) & 0xFFFF;
  final fileType = unixMode & 0xF000;
  final isDir = central.path.endsWith('/') || fileType == 0x4000;
  return ZipRawEntry(
    path: central.path,
    method: central.method,
    crc: central.crc,
    uncompressedSize: central.uncompressedSize,
    rawData: rawPayload,
    isDirectory: isDir,
  );
}

/// Reads the central directory of [zipBytes], returning each entry's raw
/// payload without inflating.
///
/// Refuses archives without a readable extra field where a 64-bit size marker
/// appears (writers that need 64-bit sizes must emit the ZIP64 extra fields
/// [encodeDeterministicZip] emits), encrypted entries, and unsupported
/// compression methods. Entries with data descriptors (bit 3) read fine: the
/// central record carries the authoritative sizes. Anything else below the
/// ZIP32 limits reads, at any size.
List<ZipRawEntry> readZipRawEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  final eocdOffset = _findRawEocdOffset(bd, zipBytes);
  final located = _applyZip64Locator(
    bd,
    zipBytes,
    eocdOffset,
    bd.getUint16(eocdOffset + 10, Endian.little),
    bd.getUint32(eocdOffset + 16, Endian.little),
  );

  final entries = <ZipRawEntry>[];
  var pos = located.cdOffset;
  for (var i = 0; i < located.entryCount; i++) {
    final central = _parseRawCentralRecord(bd, zipBytes, pos);
    pos = central.nextPos;
    entries.add(_materializeRawEntry(bd, zipBytes, central));
  }
  return entries;
}

// ---------------------------------------------------------------------------
// Framework resolution & Bundle Assembly
// ---------------------------------------------------------------------------

/// Resolves a `--framework` argument into one or more `.framework` directories.
///
/// Accepts:
///   - A `.framework` directory directly (e.g. `foo/App.framework`).
///   - A `.xcframework` directory (e.g. `Flutter.xcframework`), selecting the
///     slice matching [platform] (`ios`, `ios_sim`, or `macos`).
///   - A wrapper directory containing `*.framework` or `*.xcframework` children
///     (such as a Bazel tree artifact output).
///
/// A `.framework.zip` archive is NOT accepted here: callers extract those
/// with [extractFrameworkArchive] first, since Bazel does not preserve
/// directory symlinks inside tree artifacts staged as action inputs and
/// `App.framework` travels between actions as its deterministic zip.
List<Directory> resolveFrameworkDirectories(String inputPath, String platform) {
  final dir = Directory(inputPath);
  if (!dir.existsSync()) {
    throw ArgumentError('Framework path does not exist: $inputPath');
  }

  if (inputPath.endsWith('.framework')) {
    return [dir];
  }

  if (inputPath.endsWith('.xcframework')) {
    return _resolveXcframeworkSlice(dir, platform);
  }

  // Wrapper directory: check immediate children for *.framework or *.xcframework.
  final results = <Directory>[];
  final children = dir.listSync(followLinks: true)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final child in children) {
    if (child is Directory) {
      if (child.path.endsWith('.framework')) {
        results.add(child);
      } else if (child.path.endsWith('.xcframework')) {
        results.addAll(_resolveXcframeworkSlice(child, platform));
      }
    }
  }
  if (results.isEmpty) {
    throw ArgumentError(
      'No .framework or .xcframework found inside directory: $inputPath',
    );
  }
  return results;
}

/// Extracts a `.framework.zip` archive (the form `App.framework` travels in
/// between Bazel actions: Bazel does not preserve directory symlinks inside
/// tree artifacts when staging them as action inputs) into [scratchRoot] and
/// returns the extracted `.framework` directory.
///
/// Entry paths in the archive carry the `<Name>.framework/` prefix written by
/// the producer, so the extracted directory is
/// `<scratchRoot>/<archive-basename-minus-.zip>/<archive-basename-minus-.zip>/`.
/// Any previous extraction at that path is removed first so a re-run over a
/// reused scratch root can never see stale entries.
Directory extractFrameworkArchive(String zipPath, Directory scratchRoot) {
  final zipBase = zipPath.split('/').where((s) => s.isNotEmpty).last;
  if (!zipBase.endsWith('.framework.zip')) {
    throw ArgumentError('Not a framework archive: $zipPath');
  }
  final fwFileName = zipBase.substring(0, zipBase.length - '.zip'.length);
  final scratch = Directory('${scratchRoot.path}/$fwFileName');
  if (scratch.existsSync()) {
    scratch.deleteSync(recursive: true);
  }
  scratch.createSync(recursive: true);
  extractFrameworkZip(File(zipPath).readAsBytesSync(), scratch);
  final extracted = Directory('${scratch.path}/$fwFileName');
  if (!extracted.existsSync()) {
    throw ArgumentError(
      'Framework archive $zipPath did not contain $fwFileName/.',
    );
  }
  return extracted;
}

List<Directory> _resolveXcframeworkSlice(
  Directory xcframeworkDir,
  String platform,
) {
  final sliceDirs =
      xcframeworkDir.listSync(followLinks: true).whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  bool matchesSlice(String sliceName) {
    final lower = sliceName.toLowerCase();
    if (platform == 'ios') {
      return lower.startsWith('ios-') && !lower.contains('simulator');
    } else if (platform == 'ios_sim') {
      return lower.startsWith('ios-') && lower.contains('simulator');
    } else if (platform == 'macos') {
      return lower.startsWith('macos-');
    }
    return false;
  }

  for (final slice in sliceDirs) {
    final sliceName = slice.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (matchesSlice(sliceName)) {
      final frameworks =
          slice
              .listSync(followLinks: true)
              .whereType<Directory>()
              .where((d) => d.path.endsWith('.framework'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (frameworks.isNotEmpty) {
        return frameworks;
      }
    }
  }

  throw ArgumentError(
    'No matching slice for platform "$platform" in ${xcframeworkDir.path}',
  );
}

void _copyDirectorySync(
  Directory src,
  Directory dst, {
  bool dereferenceSymlinks = false,
}) {
  dst.createSync(recursive: true);
  final children = src.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in children) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final destPath = '${dst.path}/$name';
    if (entity is Link) {
      final target = entity.targetSync();
      final shouldDereference =
          dereferenceSymlinks ||
          target.startsWith('/') ||
          target.contains('..');
      if (shouldDereference) {
        final resolved = entity.resolveSymbolicLinksSync();
        if (FileSystemEntity.isDirectorySync(resolved)) {
          _copyDirectorySync(
            Directory(resolved),
            Directory(destPath),
            dereferenceSymlinks: dereferenceSymlinks,
          );
        } else {
          File(resolved).copySync(destPath);
        }
      } else {
        final existing = Link(destPath);
        if (existing.existsSync()) existing.deleteSync();
        existing.createSync(target);
      }
    } else if (entity is Directory) {
      _copyDirectorySync(
        entity,
        Directory(destPath),
        dereferenceSymlinks: dereferenceSymlinks,
      );
    } else if (entity is File) {
      entity.copySync(destPath);
    }
  }
}

const List<String> _unsupportedIbtoolExtensions = ['.storyboard', '.xib'];
const List<String> _unsupportedActoolExtensions = [
  '.xcassets',
  '.appiconset',
  '.icon',
];

void _validateResourceNotRequiringXcodeTools(String pathOrSpec) {
  final lower = pathOrSpec.toLowerCase();
  for (final ext in _unsupportedIbtoolExtensions) {
    if (lower.endsWith(ext) ||
        lower.contains('$ext/') ||
        lower.contains('$ext=')) {
      throw ArgumentError(
        'Resource "$pathOrSpec" is an uncompiled Interface Builder source ($ext) '
        'which requires Xcode ibtool and has no hermetic implementation on the '
        'xtool backend.',
      );
    }
  }
  for (final ext in _unsupportedActoolExtensions) {
    if (lower.endsWith(ext) ||
        lower.contains('$ext/') ||
        lower.contains('$ext=')) {
      throw ArgumentError(
        'Resource "$pathOrSpec" is an uncompiled asset catalog source ($ext) '
        'which requires Xcode actool and has no hermetic implementation on the '
        'xtool backend.',
      );
    }
  }
}

void _copyResourceSpec(String spec, Directory destRoot) {
  _validateResourceNotRequiringXcodeTools(spec);
  final eqIndex = spec.indexOf('=');
  final String srcPath;
  final String relDest;
  if (eqIndex != -1) {
    srcPath = spec.substring(0, eqIndex);
    relDest = spec.substring(eqIndex + 1);
  } else {
    srcPath = spec;
    relDest = Uri.file(srcPath).pathSegments.where((s) => s.isNotEmpty).last;
  }
  _validateResourceNotRequiringXcodeTools(srcPath);
  _validateResourceNotRequiringXcodeTools(relDest);

  final destPath = '${destRoot.path}/$relDest';
  if (FileSystemEntity.isDirectorySync(srcPath)) {
    _copyDirectorySync(
      Directory(srcPath),
      Directory(destPath),
      dereferenceSymlinks: true,
    );
  } else if (FileSystemEntity.isFileSync(srcPath)) {
    File(destPath).parent.createSync(recursive: true);
    File(srcPath).copySync(destPath);
  } else {
    throw ArgumentError('Resource path does not exist: $srcPath');
  }
}

void _copyAdditionalContentSpec(
  String spec,
  Directory contentsDir, {
  required String contentsRelPrefix,
  required Set<String> executablePaths,
}) {
  final eqIndex = spec.indexOf('=');
  if (eqIndex <= 0 || eqIndex == spec.length - 1) {
    throw ArgumentError(
      'Invalid --additional-content spec "$spec": expected <subdir>=<path>.',
    );
  }
  final subdir = spec.substring(0, eqIndex).trim();
  final srcPath = spec.substring(eqIndex + 1);
  if (subdir.isEmpty ||
      subdir.startsWith('/') ||
      subdir.split('/').contains('..')) {
    throw ArgumentError(
      'Invalid additional_contents subdirectory "$subdir": must be a relative '
      'bundle subdirectory without "..".',
    );
  }
  _validateResourceNotRequiringXcodeTools(srcPath);

  final srcName = Uri.file(srcPath).pathSegments
      .where((s) => s.isNotEmpty)
      .last;
  final destPath = '${contentsDir.path}/$subdir/$srcName';
  final relBase = '$contentsRelPrefix/$subdir/$srcName';

  if (FileSystemEntity.isDirectorySync(srcPath)) {
    // Bazel tree-artifact wrapper directories (named after their target without
    // a bundle extension like .framework/.bundle/.appex/.xpc) expand their
    // contents directly into the destination subdirectory, matching
    // rules_apple's additional_contents semantics.
    final isBundleDir = srcName.contains('.');
    final targetDir = isBundleDir
        ? Directory('${contentsDir.path}/$subdir/$srcName')
        : Directory('${contentsDir.path}/$subdir');
    final targetRelPrefix = isBundleDir
        ? '$contentsRelPrefix/$subdir/$srcName'
        : '$contentsRelPrefix/$subdir';
    _copyDirectorySync(
      Directory(srcPath),
      targetDir,
      dereferenceSymlinks: false,
    );
    _markDirectoryExecutables(
      targetDir,
      targetRelPrefix,
      subdir: subdir,
      executablePaths: executablePaths,
    );
  } else if (FileSystemEntity.isFileSync(srcPath)) {
    File(destPath).parent.createSync(recursive: true);
    File(srcPath).copySync(destPath);
    if (srcName.endsWith('.dylib') ||
        srcName.endsWith('.so') ||
        subdir == 'MacOS' ||
        subdir == 'Frameworks') {
      executablePaths.add(relBase);
    }
  } else {
    throw ArgumentError('Additional content path does not exist: $srcPath');
  }
}

void _markDirectoryExecutables(
  Directory dir,
  String relPrefix, {
  required String subdir,
  required Set<String> executablePaths,
}) {
  if (!dir.existsSync()) return;
  final dirName = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  if (dirName.endsWith('.framework')) {
    final fwName = dirName.substring(0, dirName.length - '.framework'.length);
    if (File('${dir.path}/$fwName').existsSync()) {
      executablePaths.add('$relPrefix/$fwName');
    }
    if (File('${dir.path}/Versions/A/$fwName').existsSync()) {
      executablePaths.add('$relPrefix/Versions/A/$fwName');
    }
    return;
  }
  for (final entity in dir.listSync(followLinks: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (entity is Directory && name.endsWith('.framework')) {
      _markDirectoryExecutables(
        entity,
        '$relPrefix/$name',
        subdir: subdir,
        executablePaths: executablePaths,
      );
    } else if (entity is File) {
      if (name.endsWith('.dylib') ||
          name.endsWith('.so') ||
          subdir == 'MacOS') {
        executablePaths.add('$relPrefix/$name');
      }
    }
  }
}

/// Configuration for assembling an iOS or macOS application bundle and archive.
class BundleConfig {
  final String platform; // 'ios', 'ios_sim', or 'macos'
  final String appName;
  final String bundleId;
  final String executablePath;
  final String minimumOsVersion;
  final List<String> families;
  final String? versionFilePath;
  final List<String> infoPlistPaths;
  final Map<String, String> defines;
  final List<String> frameworkPaths;
  final List<String> nativeLibPaths;
  final List<String> resourceSpecs;
  final List<String> additionalContentSpecs;
  final String? provisioningProfilePath;
  final String? entitlementsPath;
  final String? zsignPath;
  final String? certificatePath;
  final String? certificatePasswordFilePath;
  final String? certificatePasswordEnv;
  final String? outputArchivePath;
  final String? outputAppDirPath;
  final String? tempDirPath;
  final Map<String, String>? environment;

  const BundleConfig({
    required this.platform,
    required this.appName,
    required this.bundleId,
    required this.executablePath,
    required this.minimumOsVersion,
    this.families = const [],
    this.versionFilePath,
    this.infoPlistPaths = const [],
    this.defines = const {},
    this.frameworkPaths = const [],
    this.nativeLibPaths = const [],
    this.resourceSpecs = const [],
    this.additionalContentSpecs = const [],
    this.provisioningProfilePath,
    this.entitlementsPath,
    this.zsignPath,
    this.certificatePath,
    this.certificatePasswordFilePath,
    this.certificatePasswordEnv,
    this.outputArchivePath,
    this.outputAppDirPath,
    this.tempDirPath,
    this.environment,
  });
}

Directory _allocateDeterministicStageSubdir(Directory base, String prefix) {
  final primary = Directory('${base.path}/$prefix');
  if (!primary.existsSync()) {
    primary.createSync(recursive: true);
    return primary;
  }
  for (var i = 1; ; i++) {
    final candidate = Directory('${base.path}/${prefix}_$i');
    if (!candidate.existsSync()) {
      candidate.createSync(recursive: true);
      return candidate;
    }
  }
}

(Directory stageDir, Directory? createdBaseDir) _createStagingDirectory(
  BundleConfig config,
) {
  if (config.tempDirPath != null && config.tempDirPath!.isNotEmpty) {
    final base = Directory(config.tempDirPath!);
    final existed = base.existsSync();
    if (!existed) {
      base.createSync(recursive: true);
    }
    final stage = _allocateDeterministicStageSubdir(base, 'stage');
    return (stage, existed ? null : base);
  }

  final outputParentCandidates = [
    if (config.outputAppDirPath != null && config.outputAppDirPath!.isNotEmpty)
      Directory(config.outputAppDirPath!).parent.path,
    if (config.outputArchivePath != null &&
        config.outputArchivePath!.isNotEmpty)
      File(config.outputArchivePath!).parent.path,
  ];

  for (final candidate in outputParentCandidates) {
    if (candidate.isNotEmpty) {
      final base = Directory(candidate);
      if (!base.existsSync()) {
        base.createSync(recursive: true);
      }
      final stage = _allocateDeterministicStageSubdir(
        base,
        '.xtool_pack_stage',
      );
      return (stage, null);
    }
  }

  final fallbackBase = Directory('.xtool_pack_tmp');
  final existed = fallbackBase.existsSync();
  if (!existed) {
    fallbackBase.createSync(recursive: true);
  }
  final stage = _allocateDeterministicStageSubdir(fallbackBase, 'stage');
  return (stage, existed ? null : fallbackBase);
}

void _collectRpathString(
  Uint8List bytes,
  ByteData bd,
  int pos,
  int cmdsize,
  Set<String> out,
) {
  final strOff = bd.getUint32(pos + 8, Endian.little);
  if (strOff >= cmdsize) return;
  var end = pos + strOff;
  while (end < pos + cmdsize && bytes[end] != 0) {
    end++;
  }
  out.add(
    utf8.decode(bytes.sublist(pos + strOff, end), allowMalformed: true),
  );
}

int _sectionPayloadFloor(
  ByteData bd,
  int pos,
  int cmdsize,
  int nsects,
  int floor,
) {
  var sectPos = pos + 72;
  for (var s = 0; s < nsects; s++) {
    if (sectPos + 80 > pos + cmdsize) break;
    final sectSize = _getUint64LE(bd, sectPos + 40);
    final sectOffset = bd.getUint32(sectPos + 48, Endian.little);
    if (sectSize > 0 && sectOffset > 0 && sectOffset < floor) {
      floor = sectOffset;
    }
    sectPos += 80;
  }
  return floor;
}

int _segmentPayloadFloor(
  Uint8List bytes,
  ByteData bd,
  int pos,
  int cmdsize,
  int floor,
) {
  final segBytes = bytes.sublist(pos + 8, pos + 24);
  final nul = segBytes.indexOf(0);
  final segName = ascii.decode(
    nul >= 0 ? segBytes.sublist(0, nul) : segBytes,
    allowInvalid: true,
  );
  final fileoff = _getUint64LE(bd, pos + 40);
  final filesize = _getUint64LE(bd, pos + 48);
  final nsects = bd.getUint32(pos + 64, Endian.little);
  if (segName != '__TEXT' &&
      segName != '__PAGEZERO' &&
      filesize > 0 &&
      fileoff > 0 &&
      fileoff < floor) {
    floor = fileoff;
  }
  return _sectionPayloadFloor(bd, pos, cmdsize, nsects, floor);
}

/// Scans Mach-O load commands for existing `LC_RPATH` entries and the lowest
/// payload file offset, returning null when the binary must be left alone.
({Set<String> existingRpaths, int minPayloadOffset})? _scanMachOLoadCommands(
  Uint8List bytes,
  ByteData bd,
  int ncmds,
  int sizeofcmds,
) {
  final existingRpaths = <String>{};
  var minPayloadOffset = bytes.length;
  var pos = 32;
  for (var i = 0; i < ncmds; i++) {
    if (pos + 8 > 32 + sizeofcmds) return null;
    final cmd = bd.getUint32(pos, Endian.little);
    final cmdsize = bd.getUint32(pos + 4, Endian.little);
    if (cmdsize < 8 || pos + cmdsize > 32 + sizeofcmds) return null;
    if (cmd == 0x8000001c && cmdsize >= 12) {
      _collectRpathString(bytes, bd, pos, cmdsize, existingRpaths);
    } else if (cmd == 0x19 && cmdsize >= 72) {
      minPayloadOffset = _segmentPayloadFloor(
        bytes,
        bd,
        pos,
        cmdsize,
        minPayloadOffset,
      );
    }
    pos += cmdsize;
  }
  return (existingRpaths: existingRpaths, minPayloadOffset: minPayloadOffset);
}

void _appendMissingRpaths(
  File execFile,
  Uint8List bytes,
  int ncmds,
  int sizeofcmds,
  int minPayloadOffset,
  List<Uint8List> missingRpaths,
) {
  final addedSize = missingRpaths.fold<int>(0, (s, c) => s + c.length);
  final newLoadCmdEnd = 32 + sizeofcmds + addedSize;
  if (newLoadCmdEnd > minPayloadOffset) return;
  for (var i = 32 + sizeofcmds; i < newLoadCmdEnd; i++) {
    if (bytes[i] != 0) return;
  }
  final out = Uint8List.fromList(bytes);
  final outBd = ByteData.sublistView(out);
  outBd.setUint32(16, ncmds + missingRpaths.length, Endian.little);
  outBd.setUint32(20, sizeofcmds + addedSize, Endian.little);
  var writeOff = 32 + sizeofcmds;
  for (final cmdBytes in missingRpaths) {
    out.setRange(writeOff, writeOff + cmdBytes.length, cmdBytes);
    writeOff += cmdBytes.length;
  }
  execFile.writeAsBytesSync(out);
}

void _ensureExecutableRpaths(File execFile, {required bool isMacOS}) {
  final bytes = execFile.readAsBytesSync();
  if (bytes.length < 32) return;
  final bd = ByteData.sublistView(bytes);
  if (bd.getUint32(0, Endian.little) != 0xfeedfacf) return;
  final ncmds = bd.getUint32(16, Endian.little);
  final sizeofcmds = bd.getUint32(20, Endian.little);
  if (32 + sizeofcmds > bytes.length) return;

  final scan = _scanMachOLoadCommands(bytes, bd, ncmds, sizeofcmds);
  if (scan == null) return;
  final requiredRpaths = <String>[
    '@executable_path/Frameworks',
    if (isMacOS) '@executable_path/../Frameworks',
  ];
  final missingRpaths = [
    for (final rp in requiredRpaths)
      if (!scan.existingRpaths.contains(rp)) _encodeMachORpathCommand(rp),
  ];
  if (missingRpaths.isEmpty) return;
  _appendMissingRpaths(
    execFile,
    bytes,
    ncmds,
    sizeofcmds,
    scan.minPayloadOffset,
    missingRpaths,
  );
}

void _checkBundlePlatform(BundleConfig config) {
  if (config.platform != 'ios' &&
      config.platform != 'ios_sim' &&
      config.platform != 'macos') {
    throw ArgumentError(
      'Unsupported platform "${config.platform}". Expected ios, ios_sim, or macos.',
    );
  }
}

File _requireBundleExecutable(BundleConfig config) {
  final execFile = File(config.executablePath);
  if (!execFile.existsSync()) {
    throw ArgumentError(
      'Executable binary does not exist: ${config.executablePath}',
    );
  }
  return execFile;
}

Map<String, String> _readBundleVersionDefines(BundleConfig config) {
  final effectiveDefines = <String, String>{...config.defines};
  if (config.versionFilePath == null || config.versionFilePath!.isEmpty) {
    return effectiveDefines;
  }
  final versionFile = File(config.versionFilePath!);
  if (!versionFile.existsSync()) {
    throw ArgumentError(
      'Version file does not exist: ${config.versionFilePath}',
    );
  }
  final decoded = jsonDecode(versionFile.readAsStringSync());
  if (decoded is! Map) {
    throw FormatException(
      'Version file ${config.versionFilePath} must contain a JSON object.',
    );
  }
  final buildVer = decoded['build_version'];
  final shortVer = decoded['short_version_string'];
  if (buildVer is String && buildVer.isNotEmpty) {
    effectiveDefines.putIfAbsent('FLUTTER_BUILD_NUMBER', () => buildVer);
  }
  if (shortVer is String && shortVer.isNotEmpty) {
    effectiveDefines.putIfAbsent('FLUTTER_BUILD_NAME', () => shortVer);
  }
  return effectiveDefines;
}

void _stripCodeSignatures(Directory dir) {
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync(followLinks: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == '_CodeSignature') {
      entity.deleteSync(recursive: true);
    } else if (entity is Directory) {
      _stripCodeSignatures(entity);
    }
  }
}

void _replaceWithSymlinkSync(String linkPath, String target) {
  final type = FileSystemEntity.typeSync(linkPath, followLinks: false);
  if (type == FileSystemEntityType.directory) {
    Directory(linkPath).deleteSync(recursive: true);
  } else if (type == FileSystemEntityType.link) {
    Link(linkPath).deleteSync();
  } else if (type != FileSystemEntityType.notFound) {
    File(linkPath).deleteSync();
  }
  Link(linkPath).createSync(target);
}

void _normalizeMacosVersionedFramework(Directory fwDir, String fwName) {
  final versionADir = Directory('${fwDir.path}/Versions/A');
  if (!versionADir.existsSync()) return;

  _replaceWithSymlinkSync('${fwDir.path}/Versions/Current', 'A');
  if (File('${versionADir.path}/$fwName').existsSync()) {
    _replaceWithSymlinkSync(
      '${fwDir.path}/$fwName',
      'Versions/Current/$fwName',
    );
  }
  for (final sub in const ['Resources', 'Headers', 'Modules']) {
    if (Directory('${versionADir.path}/$sub').existsSync()) {
      _replaceWithSymlinkSync('${fwDir.path}/$sub', 'Versions/Current/$sub');
    }
  }
}

/// Assembles one application bundle inside a staging directory: copies the
/// executable, metadata, resources, frameworks and native libraries, signs
/// when configured, and emits the requested outputs.
class _BundleAssembly {
  final BundleConfig config;
  final Directory tempDir;
  final Map<String, String> effectiveDefines;

  late final bool isMacOS = config.platform == 'macos';
  late final String appRelPath = isMacOS
      ? '${config.appName}.app'
      : 'Payload/${config.appName}.app';
  late final String contentsRelPrefix = isMacOS
      ? '$appRelPath/Contents'
      : appRelPath;
  late final Directory frameworksScratch = Directory(
    '${tempDir.path}/frameworks',
  );

  // Bundle staging directories. Assigned eagerly by [_createLayout] (called
  // first by [run]) in the fixed order below. Directory creation must never
  // depend on a lazy initializer's side effect: a resourceless macOS bundle
  // still stages an (empty) Contents/Resources/.
  late Directory appDir;
  late Directory contentsDir;
  late Directory execDir;
  late Directory frameworksDir;
  late Directory resourcesDir;

  final executablePaths = <String>{};

  bool get shouldSign =>
      config.zsignPath != null && config.zsignPath!.isNotEmpty;

  _BundleAssembly(this.config, this.tempDir, this.effectiveDefines);

  void run() {
    _createLayout();
    _copyMainExecutable();
    _writeBundleMetadata();
    _copyBundleResources();
    _copyProvisioningProfile();
    _embedFrameworks();
    _embedNativeLibs();
    _signOrStripBundle();
    _emitAppDir();
    _emitArchive();
  }

  /// Creates every bundle staging directory up front, in the same order the
  /// pre-refactor [assembleBundle] created them. In particular the macOS
  /// Contents/Resources/ directory always exists, even when the bundle packs
  /// no resources.
  void _createLayout() {
    appDir = Directory('${tempDir.path}/$appRelPath')
      ..createSync(recursive: true);
    contentsDir = isMacOS
        ? (Directory('${appDir.path}/Contents')..createSync())
        : appDir;
    execDir = isMacOS
        ? (Directory('${contentsDir.path}/MacOS')..createSync())
        : contentsDir;
    frameworksDir = Directory('${contentsDir.path}/Frameworks');
    resourcesDir = isMacOS
        ? (Directory('${contentsDir.path}/Resources')..createSync())
        : contentsDir;
  }

  void _copyMainExecutable() {
    // 1. Copy main executable and ensure @executable_path/Frameworks LC_RPATH.
    // Executable permissions (0755) are recorded directly in the ZIP central
    // directory via executablePaths without spawning an external chmod process.
    final destExecPath = '${execDir.path}/${config.appName}';
    File(config.executablePath).copySync(destExecPath);
    _ensureExecutableRpaths(File(destExecPath), isMacOS: isMacOS);
    executablePaths.add(
      isMacOS
          ? '$appRelPath/Contents/MacOS/${config.appName}'
          : '$appRelPath/${config.appName}',
    );
  }

  void _writeBundleMetadata() {
    // 2. Merge and write Info.plist + PkgInfo.
    final plistXmls = [
      for (final p in config.infoPlistPaths) File(p).readAsStringSync(),
    ];
    final mergedPlist = buildInfoPlist(
      InfoPlistRequest(
        plistXmls: plistXmls,
        platform: config.platform,
        appName: config.appName,
        bundleId: config.bundleId,
        minimumOsVersion: config.minimumOsVersion,
        extraVariables: effectiveDefines,
        families: config.families,
      ),
    );
    File('${contentsDir.path}/Info.plist').writeAsStringSync(mergedPlist);
    File('${contentsDir.path}/PkgInfo').writeAsStringSync('APPL????');
  }

  void _copyBundleResources() {
    // 3. Copy resources.
    for (final spec in config.resourceSpecs) {
      _copyResourceSpec(spec, resourcesDir);
    }

    // 3b. Copy additional_contents into their target bundle subdirectories.
    for (final spec in config.additionalContentSpecs) {
      _copyAdditionalContentSpec(
        spec,
        contentsDir,
        contentsRelPrefix: contentsRelPrefix,
        executablePaths: executablePaths,
      );
    }
  }

  void _copyProvisioningProfile() {
    // 4. Copy provisioning profile (iOS device builds).
    if (config.provisioningProfilePath != null && !isMacOS) {
      final profileFile = File(config.provisioningProfilePath!);
      if (!profileFile.existsSync()) {
        throw ArgumentError(
          'Provisioning profile does not exist: ${config.provisioningProfilePath}',
        );
      }
      profileFile.copySync('${appDir.path}/embedded.mobileprovision');
    }
  }

  void _embedFrameworks() {
    // 5. Resolve and embed frameworks and native dynamic libraries.
    for (final fwInput in config.frameworkPaths) {
      final List<Directory> fwDirs;
      if (fwInput.endsWith('.framework.zip')) {
        // App.framework travels between actions as its deterministic archive
        // because Bazel does not preserve the framework's directory symlinks
        // when staging a tree artifact as an action input.
        fwDirs = [extractFrameworkArchive(fwInput, frameworksScratch)];
      } else {
        fwDirs = resolveFrameworkDirectories(fwInput, config.platform);
      }
      for (final fwDir in fwDirs) {
        _embedFrameworkDir(fwDir);
      }
    }
  }

  ({Directory dir, String fileName, String name}) _stageFrameworkDir(
    Directory fwDir,
  ) {
    frameworksDir.createSync(recursive: true);
    final fwFileName = fwDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final fwName = fwFileName.substring(
      0,
      fwFileName.length - '.framework'.length,
    );
    final destFwDir = Directory('${frameworksDir.path}/$fwFileName');
    _copyDirectorySync(fwDir, destFwDir, dereferenceSymlinks: false);
    return (dir: destFwDir, fileName: fwFileName, name: fwName);
  }

  void _embedFrameworkDir(Directory fwDir) {
    final staged = _stageFrameworkDir(fwDir);
    if (isMacOS) {
      _normalizeMacosVersionedFramework(staged.dir, staged.name);
    }

    // Mark framework binary executable in ZIP metadata.
    final fwRelPrefix = '$contentsRelPrefix/Frameworks/${staged.fileName}';
    _markFrameworkExecutables(staged.dir, staged.name, fwRelPrefix);

    if (shouldSign) {
      writeCodeResources(
        staged.dir,
        excludedRelativePaths: {
          staged.name,
          'Versions/A/${staged.name}',
          'Versions/Current/${staged.name}',
        },
      );
    } else {
      _stripCodeSignatures(staged.dir);
    }
  }

  void _markFrameworkExecutables(
    Directory destFwDir,
    String fwName,
    String fwRelPrefix,
  ) {
    final topBinary = File('${destFwDir.path}/$fwName');
    final versionedBinary = File('${destFwDir.path}/Versions/A/$fwName');
    if (topBinary.existsSync()) {
      executablePaths.add('$fwRelPrefix/$fwName');
    }
    if (versionedBinary.existsSync()) {
      executablePaths.add('$fwRelPrefix/Versions/A/$fwName');
    }
  }

  void _embedNativeLibs() {
    for (final dylibPath in config.nativeLibPaths) {
      if (FileSystemEntity.isDirectorySync(dylibPath)) {
        _embedNativeLibDir(dylibPath);
      } else if (FileSystemEntity.isFileSync(dylibPath)) {
        _embedNativeLibFile(File(dylibPath));
      } else {
        throw ArgumentError('Native library does not exist: $dylibPath');
      }
    }
  }

  void _embedNativeLibDir(String dylibPath) {
    final children = Directory(dylibPath).listSync(followLinks: true)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in children) {
      if (entity is File) {
        _embedNativeLibFile(entity);
      } else if (entity is Directory && entity.path.endsWith('.framework')) {
        _embedNativeChildFramework(entity);
      }
    }
  }

  void _embedNativeLibFile(File dylibFile) {
    frameworksDir.createSync(recursive: true);
    final baseName = dylibFile.uri.pathSegments.where((s) => s.isNotEmpty).last;
    dylibFile.copySync('${frameworksDir.path}/$baseName');
    executablePaths.add('$contentsRelPrefix/Frameworks/$baseName');
  }

  void _embedNativeChildFramework(Directory entity) {
    final staged = _stageFrameworkDir(entity);
    final fwRelPrefix = '$contentsRelPrefix/Frameworks/${staged.fileName}';
    _markFrameworkExecutables(staged.dir, staged.name, fwRelPrefix);
  }

  void _signOrStripBundle() {
    // 6. Sign bundle with _CodeSignature/CodeResources + zsign when configured,
    //    or ensure unsigned bundles contain no _CodeSignature/ artifacts.
    if (!shouldSign) {
      _stripCodeSignatures(appDir);
      return;
    }
    writeCodeResources(
      contentsDir,
      excludedRelativePaths: {
        if (isMacOS) 'MacOS/${config.appName}' else config.appName,
      },
    );
    _runZsign(_resolveSigningPassword());
  }

  String? _resolveSigningPassword() {
    if (config.certificatePasswordFilePath != null &&
        config.certificatePasswordFilePath!.isNotEmpty) {
      final pwFile = File(config.certificatePasswordFilePath!);
      if (!pwFile.existsSync()) {
        throw ArgumentError(
          'Certificate password file does not exist: '
          '${config.certificatePasswordFilePath}',
        );
      }
      return pwFile.readAsStringSync().replaceAll(RegExp(r'[\r\n]+$'), '');
    }
    if (config.certificatePasswordEnv == null ||
        config.certificatePasswordEnv!.isEmpty) {
      return null;
    }
    final pwEnvKey = config.certificatePasswordEnv!;
    final String? envVal;
    if (pwEnvKey == 'TMPDIR' || pwEnvKey == 'TEST_TMPDIR') {
      envVal = config.environment != null
          ? (config.environment![pwEnvKey] ?? '')
          : '';
    } else if (config.environment != null) {
      envVal = config.environment![pwEnvKey];
    } else if (_ambientHostEnvVars.contains(pwEnvKey)) {
      envVal = null;
    } else {
      envVal = Platform.environment[pwEnvKey];
    }
    if (envVal == null) {
      throw ArgumentError(
        'Certificate password environment variable '
        '"$pwEnvKey" is not set.',
      );
    }
    return envVal;
  }

  void _runZsign(String? resolvedPassword) {
    final zsignArgs = <String>[];
    final redactedArgs = <String>[];
    if (config.certificatePath != null && config.certificatePath!.isNotEmpty) {
      zsignArgs.addAll(['-k', config.certificatePath!]);
      redactedArgs.addAll(['-k', config.certificatePath!]);
    }
    if (resolvedPassword != null && resolvedPassword.isNotEmpty) {
      zsignArgs.addAll(['-p', resolvedPassword]);
      redactedArgs.addAll(['-p', '<redacted>']);
    }
    if (config.provisioningProfilePath != null &&
        config.provisioningProfilePath!.isNotEmpty) {
      zsignArgs.addAll(['-m', config.provisioningProfilePath!]);
      redactedArgs.addAll(['-m', config.provisioningProfilePath!]);
    }
    if (config.entitlementsPath != null &&
        config.entitlementsPath!.isNotEmpty) {
      zsignArgs.addAll(['-e', config.entitlementsPath!]);
      redactedArgs.addAll(['-e', config.entitlementsPath!]);
    }
    zsignArgs.add(appDir.path);
    redactedArgs.add(appDir.path);
    final result = Process.runSync(
      config.zsignPath!,
      zsignArgs,
      environment: const {'PATH': '/usr/bin:/bin'},
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        config.zsignPath!,
        redactedArgs,
        'zsign failed (exit ${result.exitCode}):\n${result.stderr}',
        result.exitCode,
      );
    }
  }

  void _emitAppDir() {
    // 8. Emit --output-app-dir if requested.
    if (config.outputAppDirPath != null &&
        config.outputAppDirPath!.isNotEmpty) {
      final outAppDir = Directory(config.outputAppDirPath!);
      if (outAppDir.existsSync()) {
        outAppDir.deleteSync(recursive: true);
      }
      _copyDirectorySync(appDir, outAppDir, dereferenceSymlinks: false);
    }
  }

  void _emitArchive() {
    // 9. Emit --output-archive (.ipa or .app.zip) if requested.
    if (config.outputArchivePath != null &&
        config.outputArchivePath!.isNotEmpty) {
      final zipBytes = createDeterministicZipFromDirectory(
        tempDir,
        executablePaths: executablePaths,
      );
      final outArchive = File(config.outputArchivePath!);
      outArchive.parent.createSync(recursive: true);
      outArchive.writeAsBytesSync(zipBytes);
    }
  }
}

/// Assembles an iOS `.ipa` or macOS `.app.zip` (and optional `.app` directory)
/// according to [config].
void assembleBundle(BundleConfig config) {
  _checkBundlePlatform(config);
  _requireBundleExecutable(config);
  final effectiveDefines = _readBundleVersionDefines(config);
  final (tempDir, createdBaseDir) = _createStagingDirectory(config);
  try {
    _BundleAssembly(config, tempDir, effectiveDefines).run();
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
    if (createdBaseDir != null && createdBaseDir.existsSync()) {
      createdBaseDir.deleteSync(recursive: true);
    }
  }
}

// ---------------------------------------------------------------------------
// 7. Darwin SDK resolution and Mach-O MH_EXECUTE runner compilation
// ---------------------------------------------------------------------------

int _packMachOVersion(String version) {
  final parts = version.split('.');
  final major = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
  final minor = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  final patch = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
  return ((major & 0xffff) << 16) | ((minor & 0xff) << 8) | (patch & 0xff);
}

int _machOPlatformConstant(String platform) {
  switch (platform) {
    case 'macos':
      return 1; // PLATFORM_MACOS
    case 'ios':
      return 2; // PLATFORM_IOS
    case 'ios_sim':
      return 7; // PLATFORM_IOSSIMULATOR
    default:
      throw ArgumentError('Unsupported platform: $platform');
  }
}

Uint8List _encodeMachOSegment64Command(Segment64Spec spec) {
  final bytes = Uint8List(72);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x19, Endian.little); // LC_SEGMENT_64
  bd.setUint32(4, 72, Endian.little);
  final nameBytes = ascii.encode(spec.segname);
  bytes.setRange(
    8,
    8 + (nameBytes.length > 16 ? 16 : nameBytes.length),
    nameBytes,
  );
  _setUint64LE(bd, 24, spec.vmaddr);
  _setUint64LE(bd, 32, spec.vmsize);
  _setUint64LE(bd, 40, spec.fileoff);
  _setUint64LE(bd, 48, spec.filesize);
  bd.setInt32(56, spec.maxprot, Endian.little);
  bd.setInt32(60, spec.initprot, Endian.little);
  bd.setUint32(64, spec.nsects, Endian.little); // nsects
  bd.setUint32(68, spec.flags, Endian.little); // flags
  return bytes;
}

Uint8List _encodeMachOSymtabCommand({
  required int symoff,
  required int nsyms,
  required int stroff,
  required int strsize,
}) {
  final bytes = Uint8List(24);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x02, Endian.little); // LC_SYMTAB
  bd.setUint32(4, 24, Endian.little);
  bd.setUint32(8, symoff, Endian.little);
  bd.setUint32(12, nsyms, Endian.little);
  bd.setUint32(16, stroff, Endian.little);
  bd.setUint32(20, strsize, Endian.little);
  return bytes;
}

Uint8List _encodeMachODysymtabCommand() {
  final bytes = Uint8List(80);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x0b, Endian.little); // LC_DYSYMTAB
  bd.setUint32(4, 80, Endian.little);
  return bytes;
}

Uint8List _encodeMachOUuidCommand(Uint8List uuid16) {
  final bytes = Uint8List(24);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x1b, Endian.little); // LC_UUID
  bd.setUint32(4, 24, Endian.little);
  bytes.setRange(8, 24, uuid16);
  return bytes;
}

Uint8List _encodeMachOLoadDylibCommand(String installName) {
  final nameBytes = utf8.encode(installName);
  const headerSize = 24;
  final unpadded = headerSize + nameBytes.length + 1;
  final cmdSize = (unpadded + 7) & ~7;
  final bytes = Uint8List(cmdSize);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x0c, Endian.little); // LC_LOAD_DYLIB
  bd.setUint32(4, cmdSize, Endian.little);
  bd.setUint32(8, headerSize, Endian.little); // name offset
  bd.setUint32(12, 2, Endian.little); // timestamp
  bd.setUint32(16, 0x00010000, Endian.little); // current_version 1.0.0
  bd.setUint32(20, 0x00010000, Endian.little); // compatibility_version 1.0.0
  bytes.setRange(headerSize, headerSize + nameBytes.length, nameBytes);
  return bytes;
}

Uint8List _encodeMachORpathCommand(String rpath) {
  final pathBytes = utf8.encode(rpath);
  const headerSize = 12;
  final unpadded = headerSize + pathBytes.length + 1;
  final cmdSize = (unpadded + 7) & ~7;
  final bytes = Uint8List(cmdSize);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x8000001c, Endian.little); // LC_RPATH
  bd.setUint32(4, cmdSize, Endian.little);
  bd.setUint32(8, headerSize, Endian.little); // path offset
  bytes.setRange(headerSize, headerSize + pathBytes.length, pathBytes);
  return bytes;
}

Uint8List _encodeMachOBuildVersionCommand({
  required int platform,
  required int minos,
  required int sdk,
}) {
  final bytes = Uint8List(24);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x32, Endian.little); // LC_BUILD_VERSION
  bd.setUint32(4, 24, Endian.little); // cmdsize
  bd.setUint32(8, platform, Endian.little);
  bd.setUint32(12, minos, Endian.little);
  bd.setUint32(16, sdk, Endian.little);
  bd.setUint32(20, 0, Endian.little); // ntools = 0
  return bytes;
}

({int cpuType, int cpuSubtype, int pageSize}) _stubArchParams(String arch) {
  switch (arch) {
    case 'arm64':
      // CPU_TYPE_ARM64 / CPU_SUBTYPE_ARM64_ALL, 16 KiB pages.
      return (cpuType: 0x0100000c, cpuSubtype: 0, pageSize: 0x4000);
    case 'x86_64':
      // CPU_TYPE_X86_64 / CPU_SUBTYPE_X86_64_ALL, 4 KiB pages.
      return (cpuType: 0x01000007, cpuSubtype: 3, pageSize: 0x1000);
    default:
      throw ArgumentError('Unsupported architecture "$arch".');
  }
}

List<Uint8List> _stubLoadCommands(
  StubRunnerSpec spec,
  int versionPacked,
  int pageSize,
  int linkeditFileSize,
) {
  final platform = spec.platform;
  return [
    _encodeMachOBuildVersionCommand(
      platform: _machOPlatformConstant(platform),
      minos: versionPacked,
      sdk: versionPacked,
    ),
    _encodeMachOSegment64Command((
      segname: '__TEXT',
      vmaddr: 0,
      vmsize: pageSize,
      fileoff: 0,
      filesize: pageSize,
      maxprot: 5,
      initprot: 5,
      nsects: 0,
      flags: 0,
    )),
    _encodeMachOSegment64Command((
      segname: '__LINKEDIT',
      vmaddr: pageSize,
      vmsize: pageSize,
      fileoff: pageSize,
      filesize: linkeditFileSize,
      maxprot: 1,
      initprot: 1,
      nsects: 0,
      flags: 0,
    )),
    _encodeMachOSymtabCommand(
      symoff: pageSize,
      nsyms: 0,
      stroff: pageSize,
      strsize: linkeditFileSize,
    ),
    _encodeMachODysymtabCommand(),
    _encodeMachOUuidCommand(Uint8List(16)),
    _encodeMachORpathCommand('@executable_path/Frameworks'),
    if (platform == 'macos')
      _encodeMachORpathCommand('@executable_path/../Frameworks'),
    for (final fw in spec.linkedFrameworkNames)
      _encodeMachOLoadDylibCommand('@rpath/$fw.framework/$fw'),
    for (final sdkFw in spec.sdkFrameworks)
      _encodeMachOLoadDylibCommand(
        platform == 'macos'
            ? '/System/Library/Frameworks/$sdkFw.framework/Versions/A/$sdkFw'
            : '/System/Library/Frameworks/$sdkFw.framework/$sdkFw',
      ),
    for (final dylib in spec.sdkDylibs)
      _encodeMachOLoadDylibCommand(
        '/usr/lib/${dylib.startsWith('lib') ? dylib : 'lib$dylib'}.dylib',
      ),
  ];
}

/// Writes [loadCommands] after the Mach-O header, returning the file offset
/// of the `LC_UUID` payload for later stamping.
int _writeStubCommands(Uint8List out, List<Uint8List> loadCommands) {
  var offset = 32;
  var uuidDataOffset = -1;
  for (final cmd in loadCommands) {
    final cmdId = ByteData.sublistView(cmd).getUint32(0, Endian.little);
    if (cmdId == 0x1b) {
      uuidDataOffset = offset + 8;
    }
    out.setRange(offset, offset + cmd.length, cmd);
    offset += cmd.length;
  }
  return uuidDataOffset;
}

void _stampStubUuid(Uint8List out, int uuidDataOffset) {
  if (uuidDataOffset < 0) return;
  final digest = sha256Bytes(out);
  final uuid = Uint8List.fromList(digest.sublist(0, 16));
  uuid[6] = (uuid[6] & 0x0f) | 0x50;
  uuid[8] = (uuid[8] & 0x3f) | 0x80;
  out.setRange(uuidDataOffset, uuidDataOffset + 16, uuid);
}

/// The inputs for synthesizing a stub runner Mach-O binary: target platform
/// and version plus linked frameworks, libraries, and metadata. Grouped so
/// the stub entry points stay small.
class StubRunnerSpec {
  const StubRunnerSpec({
    required this.platform,
    this.arch = 'arm64',
    required this.minimumOsVersion,
    this.linkedFrameworkNames = const [],
    this.sdkFrameworks = const [],
    this.sdkDylibs = const [],
    this.metadataEntries = const [],
  });

  /// The target platform (`ios`, `ios_sim`, or `macos`).
  final String platform;

  /// The target architecture (`arm64` or `x86_64`).
  final String arch;

  /// The minimum-OS version string.
  final String minimumOsVersion;

  /// The embedded frameworks to `LC_LOAD_DYLIB`.
  final List<String> linkedFrameworkNames;

  /// The system frameworks to `LC_LOAD_DYLIB`.
  final List<String> sdkFrameworks;

  /// The `/usr/lib` libraries to `LC_LOAD_DYLIB`.
  final List<String> sdkDylibs;

  /// The metadata lines embedded in `__TEXT`.
  final List<String> metadataEntries;
}

/// Synthesizes a 64-bit Mach-O `MH_EXECUTE` runner binary with
/// `LC_BUILD_VERSION`, `__TEXT` / `__LINKEDIT` segments, `LC_SYMTAB`,
/// `LC_DYSYMTAB`, `LC_UUID`, `LC_RPATH`, and `LC_LOAD_DYLIB` commands.
Uint8List generateStubExecutableMachO(StubRunnerSpec spec) {
  final archParams = _stubArchParams(spec.arch);
  final pageSize = archParams.pageSize;
  const linkeditFileSize = 8;
  final versionPacked = _packMachOVersion(spec.minimumOsVersion);

  final loadCommands = _stubLoadCommands(
    spec,
    versionPacked,
    pageSize,
    linkeditFileSize,
  );
  final sizeofcmds = loadCommands.fold<int>(0, (s, c) => s + c.length);
  final metadataText = spec.metadataEntries.isEmpty
      ? ''
      : '${spec.metadataEntries.join('\n')}\n';
  final metadataBytes = utf8.encode(metadataText);

  final totalSize = pageSize + linkeditFileSize;
  final out = Uint8List(totalSize);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, 0xfeedfacf, Endian.little); // MH_MAGIC_64
  bd.setInt32(4, archParams.cpuType, Endian.little);
  bd.setInt32(8, archParams.cpuSubtype, Endian.little);
  bd.setUint32(12, 0x2, Endian.little); // MH_EXECUTE
  bd.setUint32(16, loadCommands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, 0x00200001, Endian.little); // MH_NOUNDEFS | MH_PIE
  bd.setUint32(28, 0, Endian.little); // reserved

  final uuidDataOffset = _writeStubCommands(out, loadCommands);

  // Leave 64 bytes of zero padding after load commands before writing metadata
  // inside __TEXT so any subsequent load-command patching has room.
  final metaStart = 32 + sizeofcmds + 64;
  if (metadataBytes.isNotEmpty &&
      metaStart + metadataBytes.length <= pageSize) {
    out.setRange(metaStart, metaStart + metadataBytes.length, metadataBytes);
  }

  // Standard Mach-O string table in __LINKEDIT begins with " \0".
  out[pageSize] = 0x20;
  out[pageSize + 1] = 0x00;

  _stampStubUuid(out, uuidDataOffset);
  return out;
}

({String sdkPrefix, String defaultDirName}) _sdkNamesForPlatform(
  String platform,
) {
  switch (platform) {
    case 'ios':
      return (sdkPrefix: 'iphoneos', defaultDirName: 'iPhoneOS.sdk');
    case 'ios_sim':
      return (
        sdkPrefix: 'iphonesimulator',
        defaultDirName: 'iPhoneSimulator.sdk',
      );
    case 'macos':
      return (sdkPrefix: 'macosx', defaultDirName: 'MacOSX.sdk');
    default:
      throw ArgumentError('Unsupported platform "$platform".');
  }
}

/// Searches an `info.json` artifact bundle for a variant whose key or path
/// names the [sdkPrefix], returning its directory when it exists.
Directory? _findSdkInArtifactInfo(
  Directory sdkRoot,
  Object? decoded,
  String sdkPrefix,
) {
  if (decoded is! Map<String, Object?>) return null;
  final artifacts = decoded['artifacts'];
  if (artifacts is! Map<String, Object?>) return null;
  for (final entry in artifacts.entries) {
    final candidate = _matchSdkVariant(
      sdkRoot,
      entry.key,
      entry.value,
      sdkPrefix,
    );
    if (candidate != null) return candidate;
  }
  return null;
}

Directory? _matchSdkVariant(
  Directory sdkRoot,
  String key,
  Object? val,
  String sdkPrefix,
) {
  if (val is! Map<String, Object?>) return null;
  final variants = val['variants'];
  if (variants is! List<Object?>) return null;
  final keyLower = key.toLowerCase();
  for (final v in variants) {
    if (v is! Map<String, Object?>) continue;
    final path = v['path'];
    if (path is! String) continue;
    if (keyLower.startsWith(sdkPrefix) ||
        path.toLowerCase().contains(sdkPrefix)) {
      final candidate = Directory('${sdkRoot.path}/$path');
      if (candidate.existsSync()) {
        return candidate;
      }
    }
  }
  return null;
}

/// Resolves the platform `.sdk` directory inside a `darwin.artifactbundle`
/// directory for [platform] (`ios`, `ios_sim`, or `macos`).
Directory resolveDarwinSdkPathFromArtifactBundle(
  Directory sdkRoot,
  String platform,
) {
  if (!sdkRoot.existsSync()) {
    throw ArgumentError('SDK root directory does not exist: ${sdkRoot.path}');
  }
  final names = _sdkNamesForPlatform(platform);

  final infoJsonFile = File('${sdkRoot.path}/info.json');
  if (infoJsonFile.existsSync()) {
    final decoded = jsonDecode(infoJsonFile.readAsStringSync());
    final fromInfo = _findSdkInArtifactInfo(sdkRoot, decoded, names.sdkPrefix);
    if (fromInfo != null) return fromInfo;
  }

  final fallback = Directory('${sdkRoot.path}/${names.defaultDirName}');
  if (fallback.existsSync()) {
    return fallback;
  }

  throw ArgumentError(
    'Could not resolve Darwin SDK for platform "$platform" in ${sdkRoot.path}',
  );
}

/// Configuration for compiling or synthesizing an iOS/macOS runner binary.
class RunnerCompileConfig {
  final String platform; // 'ios', 'ios_sim', or 'macos'
  final String arch; // 'arm64' or 'x86_64'
  final String appName;
  final String minimumOsVersion;
  final bool sdkAvailable;
  final String? sdkRootPath;
  final String? swiftcPath;
  final String? clangPath;
  final List<String> sourcePaths;
  final List<String> headerPaths;
  final List<String> modulemapPaths;
  final List<String> frameworkPaths;
  final List<String> sdkFrameworks;
  final List<String> sdkDylibs;
  final String outputPath;

  const RunnerCompileConfig({
    required this.platform,
    this.arch = 'arm64',
    required this.appName,
    required this.minimumOsVersion,
    this.sdkAvailable = false,
    this.sdkRootPath,
    this.swiftcPath,
    this.clangPath,
    this.sourcePaths = const [],
    this.headerPaths = const [],
    this.modulemapPaths = const [],
    this.frameworkPaths = const [],
    this.sdkFrameworks = const [],
    this.sdkDylibs = const [],
    required this.outputPath,
  });
}

void _checkRunnerPlatform(RunnerCompileConfig config) {
  if (config.platform != 'ios' &&
      config.platform != 'ios_sim' &&
      config.platform != 'macos') {
    throw ArgumentError(
      'Unsupported platform "${config.platform}". Expected ios, ios_sim, or macos.',
    );
  }
}

void _requireRunnerFilesExist(List<String> paths, String kind) {
  for (final path in paths) {
    if (!File(path).existsSync()) {
      throw ArgumentError('Runner $kind file does not exist: $path');
    }
  }
}

/// Resolves `--framework` inputs to framework directories and their link
/// names, extracting `.framework.zip` archives beside the runner output.
({
  List<Directory> dirs,
  List<String> names,
})
_resolveRunnerFrameworks(RunnerCompileConfig config) {
  final resolvedFrameworkDirs = <Directory>[];
  final linkedFrameworkNames = <String>[];
  Directory? frameworksScratch;
  for (final fwInput in config.frameworkPaths) {
    final List<Directory> dirs;
    if (fwInput.endsWith('.framework.zip')) {
      // Same archive form as bundle embedding (see above): extract beside
      // the declared runner output so the linker gets a real directory.
      frameworksScratch ??= Directory('${config.outputPath}.frameworks')
        ..createSync(recursive: true);
      dirs = [extractFrameworkArchive(fwInput, frameworksScratch)];
    } else {
      dirs = resolveFrameworkDirectories(fwInput, config.platform);
    }
    for (final d in dirs) {
      resolvedFrameworkDirs.add(d);
      final base = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final fwName = base.endsWith('.framework')
          ? base.substring(0, base.length - '.framework'.length)
          : base;
      if (!linkedFrameworkNames.contains(fwName)) {
        linkedFrameworkNames.add(fwName);
      }
    }
  }
  return (dirs: resolvedFrameworkDirs, names: linkedFrameworkNames);
}

List<String> _dedupeNonEmpty(List<String> values) {
  final deduped = <String>[];
  for (final value in values) {
    if (value.isNotEmpty && !deduped.contains(value)) {
      deduped.add(value);
    }
  }
  return deduped;
}

Directory? _resolveRunnerSdkDir(RunnerCompileConfig config) {
  if (config.sdkAvailable &&
      config.sdkRootPath != null &&
      config.sdkRootPath!.isNotEmpty) {
    return resolveDarwinSdkPathFromArtifactBundle(
      Directory(config.sdkRootPath!),
      config.platform,
    );
  }
  return null;
}

String _runnerTargetTriple(RunnerCompileConfig config) {
  switch (config.platform) {
    case 'ios':
      return '${config.arch}-apple-ios${config.minimumOsVersion}';
    case 'ios_sim':
      return '${config.arch}-apple-ios${config.minimumOsVersion}-simulator';
    case 'macos':
      return '${config.arch}-apple-macos${config.minimumOsVersion}';
    default:
      throw StateError('Unreachable');
  }
}

List<String> _buildSwiftcArgs(
  RunnerCompileConfig config,
  Directory? resolvedSdkDir,
  List<Directory> resolvedFrameworkDirs,
  List<String> linkedFrameworkNames,
  List<String> sdkFrameworks,
  List<String> sdkDylibs,
) {
  final swiftcArgs = <String>[
    '-target',
    _runnerTargetTriple(config),
    if (resolvedSdkDir != null) ...['-sdk', resolvedSdkDir.path],
    '-Xlinker',
    '-rpath',
    '-Xlinker',
    '@executable_path/Frameworks',
    if (config.platform == 'macos') ...[
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      '@executable_path/../Frameworks',
    ],
  ];

  final seenFwParents = <String>{};
  for (final fwDir in resolvedFrameworkDirs) {
    final parentPath = fwDir.parent.path;
    if (seenFwParents.add(parentPath)) {
      swiftcArgs.addAll(['-F', parentPath]);
    }
  }
  for (final fwName in linkedFrameworkNames) {
    swiftcArgs.addAll(['-framework', fwName]);
  }
  for (final sdkFw in sdkFrameworks) {
    swiftcArgs.addAll(['-framework', sdkFw]);
  }
  for (final dylib in sdkDylibs) {
    final libArg = dylib.startsWith('lib') ? dylib.substring(3) : dylib;
    swiftcArgs.add('-l$libArg');
  }

  final seenHeaderDirs = <String>{};
  for (final hdr in config.headerPaths) {
    final dirPath = File(hdr).parent.path;
    if (seenHeaderDirs.add(dirPath)) {
      swiftcArgs.addAll(['-I', dirPath]);
    }
  }
  for (final mm in config.modulemapPaths) {
    swiftcArgs.addAll(['-Xcc', '-fmodule-map-file=$mm']);
  }

  swiftcArgs.addAll([
    ...config.sourcePaths,
    '-emit-executable',
    '-o',
    config.outputPath,
  ]);
  return swiftcArgs;
}

void _runSwiftc(RunnerCompileConfig config, List<String> swiftcArgs) {
  File(config.outputPath).parent.createSync(recursive: true);
  final result = Process.runSync(
    config.swiftcPath!,
    swiftcArgs,
    environment: const {'PATH': '/usr/bin:/bin'},
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      config.swiftcPath!,
      swiftcArgs,
      'swiftc failed (exit ${result.exitCode}):\n${result.stderr}',
      result.exitCode,
    );
  }
}

void _synthesizeRunnerBinary(
  RunnerCompileConfig config,
  Directory? resolvedSdkDir,
  List<String> linkedFrameworkNames,
  List<String> sdkFrameworks,
  List<String> sdkDylibs,
) {
  final metadataEntries = <String>[
    'app=${config.appName}',
    'platform=${config.platform}',
    'arch=${config.arch}',
    'sdk_available=${config.sdkAvailable}',
    if (resolvedSdkDir != null)
      'sdk=${resolvedSdkDir.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    for (final src in config.sourcePaths)
      'source=${Uri.file(src).pathSegments.where((s) => s.isNotEmpty).last}',
    for (final hdr in config.headerPaths)
      'header=${Uri.file(hdr).pathSegments.where((s) => s.isNotEmpty).last}',
    for (final mm in config.modulemapPaths)
      'modulemap=${Uri.file(mm).pathSegments.where((s) => s.isNotEmpty).last}',
    for (final fw in linkedFrameworkNames) 'framework=$fw',
    for (final sdkFw in sdkFrameworks) 'sdk_framework=$sdkFw',
    for (final dylib in sdkDylibs) 'sdk_dylib=$dylib',
  ];

  final machoBytes = generateStubExecutableMachO(
    StubRunnerSpec(
      platform: config.platform,
      arch: config.arch,
      minimumOsVersion: config.minimumOsVersion,
      linkedFrameworkNames: linkedFrameworkNames,
      sdkFrameworks: sdkFrameworks,
      sdkDylibs: sdkDylibs,
      metadataEntries: metadataEntries,
    ),
  );
  final outFile = File(config.outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(machoBytes);
}

/// Compiles or synthesizes a Mach-O `MH_EXECUTE` runner binary from
/// [RunnerCompileConfig].
void compileRunner(RunnerCompileConfig config) {
  _checkRunnerPlatform(config);
  _requireRunnerFilesExist(config.sourcePaths, 'source');
  _requireRunnerFilesExist(config.headerPaths, 'header');
  _requireRunnerFilesExist(config.modulemapPaths, 'modulemap');

  final resolved = _resolveRunnerFrameworks(config);
  final sdkFrameworks = _dedupeNonEmpty(config.sdkFrameworks);
  final sdkDylibs = _dedupeNonEmpty(config.sdkDylibs);
  final resolvedSdkDir = _resolveRunnerSdkDir(config);

  if (config.sdkAvailable &&
      config.swiftcPath != null &&
      config.swiftcPath!.isNotEmpty) {
    _runSwiftc(
      config,
      _buildSwiftcArgs(
        config,
        resolvedSdkDir,
        resolved.dirs,
        resolved.names,
        sdkFrameworks,
        sdkDylibs,
      ),
    );
    return;
  }

  _synthesizeRunnerBinary(
    config,
    resolvedSdkDir,
    resolved.names,
    sdkFrameworks,
    sdkDylibs,
  );
}

/// Reads the `BUILD_EMBED_LABEL` value from a Bazel `stable-status.txt` file,
/// falling back to [fallbackBuildLabel] when absent.
String? _readBuildEmbedLabel(
  String? stableStatusPath,
  String fallbackBuildLabel,
) {
  String? embedLabel;
  if (stableStatusPath != null &&
      stableStatusPath.isNotEmpty &&
      File(stableStatusPath).existsSync()) {
    for (final line in File(stableStatusPath).readAsLinesSync()) {
      if (line.startsWith('BUILD_EMBED_LABEL ')) {
        final val = line.substring('BUILD_EMBED_LABEL '.length).trim();
        if (val.isNotEmpty) {
          embedLabel = val;
        }
        break;
      }
    }
  }
  if ((embedLabel == null || embedLabel.isEmpty) &&
      fallbackBuildLabel.isNotEmpty) {
    embedLabel = fallbackBuildLabel;
  }
  return embedLabel;
}

/// Matches [embedLabel] against [buildLabelPattern]'s `{name}` placeholders,
/// returning the captured group values.
Map<String, String> _matchLabelGroups(
  String buildLabelPattern,
  Map<String, String> captureGroups,
  String embedLabel,
) {
  final groupNames = <String>[];
  final regexPattern = buildLabelPattern.replaceAllMapped(
    RegExp(r'\{([A-Za-z0-9_]+)\}'),
    (m) {
      final name = m.group(1)!;
      final groupRegex = captureGroups[name];
      if (groupRegex == null) {
        throw ArgumentError(
          'Placeholder "{$name}" in build_label_pattern is not present in capture_groups.',
        );
      }
      groupNames.add(name);
      return '($groupRegex)';
    },
  );
  final match = RegExp('^$regexPattern\$').firstMatch(embedLabel);
  if (match == null) {
    throw ArgumentError(
      'Build label "$embedLabel" did not match build_label_pattern "$buildLabelPattern".',
    );
  }
  final values = <String, String>{};
  for (var i = 0; i < groupNames.length; i++) {
    values[groupNames[i]] = match.group(i + 1) ?? '';
  }
  return values;
}

String _substituteLabelGroups(String template, Map<String, String> values) {
  return template.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (m) {
    final name = m.group(1)!;
    return values[name] ?? m.group(0)!;
  });
}

/// The inputs for resolving bundle versions from a build label: templates,
/// label-matching rules, and the output path. Grouped so the resolver entry
/// point stays small.
class BundleVersionRequest {
  const BundleVersionRequest({
    required this.buildVersion,
    this.shortVersionString = '',
    this.buildLabelPattern = '',
    this.fallbackBuildLabel = '',
    this.captureGroups = const {},
    this.stableStatusPath,
    required this.outputPath,
  });

  /// The `build_version` template.
  final String buildVersion;

  /// The `short_version_string` template (defaults to [buildVersion]).
  final String shortVersionString;

  /// The regex the `BUILD_EMBED_LABEL` must match, if any.
  final String buildLabelPattern;

  /// The label used when no `stable-status.txt` entry exists.
  final String fallbackBuildLabel;

  /// The named capture-group patterns for label substitution.
  final Map<String, String> captureGroups;

  /// The `stable-status.txt` path, if any.
  final String? stableStatusPath;

  /// Where to write the resolved version JSON.
  final String outputPath;
}

/// Resolves `build_version` and `short_version_string` from a Bazel
/// `stable-status.txt` `BUILD_EMBED_LABEL` (or the request's fallback build
/// label) and the request's build-label pattern / capture groups, writing
/// JSON to the request's output path.
void resolveBundleVersion(BundleVersionRequest request) {
  final buildVersion = request.buildVersion;
  final buildLabelPattern = request.buildLabelPattern;
  var resolvedShort = request.shortVersionString.isNotEmpty
      ? request.shortVersionString
      : buildVersion;
  var resolvedBuild = buildVersion;

  if (buildLabelPattern.isNotEmpty) {
    final embedLabel = _readBuildEmbedLabel(
      request.stableStatusPath,
      request.fallbackBuildLabel,
    );
    if (embedLabel != null && embedLabel.isNotEmpty) {
      final values = _matchLabelGroups(
        buildLabelPattern,
        request.captureGroups,
        embedLabel,
      );
      resolvedBuild = _substituteLabelGroups(resolvedBuild, values);
      resolvedShort = _substituteLabelGroups(resolvedShort, values);
    }
  }

  final outFile = File(request.outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(
    '${jsonEncode({'build_version': resolvedBuild, 'short_version_string': resolvedShort})}\n',
  );
}

// ---------------------------------------------------------------------------
// CLI entrypoint
// ---------------------------------------------------------------------------

Never _usageError(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'Usage:\n'
    '  dart xtool_pack.dart bundle \\\n'
    '    --platform <ios|ios_sim|macos> \\\n'
    '    --app-name <AppName> \\\n'
    '    --bundle-id <com.example.app> \\\n'
    '    --executable <path> \\\n'
    '    --minimum-os-version <version> \\\n'
    '    [--family <iphone|ipad> ...] \\\n'
    '    [--version-file <path>] \\\n'
    '    [--info-plist <path> ...] \\\n'
    '    [--define <KEY=VALUE> ...] \\\n'
    '    [--framework <path> ...] \\\n'
    '    [--native-lib <path> ...] \\\n'
    '    [--resource <src[=dest_rel]> ...] \\\n'
    '    [--additional-content <subdir=src> ...] \\\n'
    '    [--provisioning-profile <path>] \\\n'
    '    [--entitlements <path>] \\\n'
    '    [--zsign <path>] \\\n'
    '    [--certificate <path>] \\\n'
    '    [--certificate-password-file <path>] \\\n'
    '    [--certificate-password-env <ENV_VAR>] \\\n'
    '    [--temp-dir <path>] \\\n'
    '    [--output-archive <path>] \\\n'
    '    [--output-app-dir <path>]',
  );
  exit(1);
}

/// Mutable parse state for `resolve-version` CLI arguments.
class _ResolveVersionArgState {
  String buildVersion = '1.0';
  String shortVersionString = '';
  String buildLabelPattern = '';
  String fallbackBuildLabel = '';
  final captureGroups = <String, String>{};
  String? stableStatusPath;
  String? outputPath;

  int apply(List<String> args, int i) {
    final arg = args[i];
    String nextVal() {
      if (i + 1 >= args.length) {
        _usageError('Missing value for $arg.');
      }
      return args[++i];
    }

    switch (arg) {
      case '--control':
        _applyControlFile(nextVal());
      case '--build-version':
        buildVersion = nextVal();
      case '--short-version-string':
        shortVersionString = nextVal();
      case '--build-label-pattern':
        buildLabelPattern = nextVal();
      case '--fallback-build-label':
        fallbackBuildLabel = nextVal();
      case '--capture-group':
        _applyCaptureGroup(nextVal());
      case '--stable-status':
        stableStatusPath = nextVal();
      case '--output':
        outputPath = nextVal();
      default:
        _usageError('Unrecognized argument for resolve-version: $arg');
    }
    return i;
  }

  void _applyControlFile(String controlPath) {
    final decoded = jsonDecode(File(controlPath).readAsStringSync());
    if (decoded is! Map) {
      _usageError('Control file $controlPath must contain a JSON object.');
    }
    buildVersion =
        (decoded['build_version_pattern'] as String?) ?? buildVersion;
    shortVersionString =
        (decoded['short_version_string_pattern'] as String?) ??
        shortVersionString;
    buildLabelPattern =
        (decoded['build_label_pattern'] as String?) ?? buildLabelPattern;
    fallbackBuildLabel =
        (decoded['fallback_build_label'] as String?) ?? fallbackBuildLabel;
    stableStatusPath =
        (decoded['build_info_path'] as String?) ?? stableStatusPath;
    final cg = decoded['capture_groups'];
    if (cg is Map) {
      for (final entry in cg.entries) {
        captureGroups[entry.key.toString()] = entry.value.toString();
      }
    }
  }

  void _applyCaptureGroup(String kv) {
    final eq = kv.indexOf('=');
    if (eq == -1) {
      _usageError('Expected KEY=REGEX for --capture-group, got "$kv".');
    }
    captureGroups[kv.substring(0, eq)] = kv.substring(eq + 1);
  }
}

void _runResolveVersionCli(List<String> args) {
  final state = _ResolveVersionArgState();
  for (var i = 0; i < args.length; i++) {
    i = state.apply(args, i);
  }
  final outputPath = state.outputPath;
  if (outputPath == null) {
    _usageError('Required flag for resolve-version: --output.');
  }

  try {
    resolveBundleVersion(
      BundleVersionRequest(
        buildVersion: state.buildVersion,
        shortVersionString: state.shortVersionString,
        buildLabelPattern: state.buildLabelPattern,
        fallbackBuildLabel: state.fallbackBuildLabel,
        captureGroups: state.captureGroups,
        stableStatusPath: state.stableStatusPath,
        outputPath: outputPath,
      ),
    );
  } on Object catch (e) {
    stderr.writeln('xtool_pack resolve-version failed: $e');
    exit(1);
  }
}

/// Mutable parse state for `compile-runner` CLI arguments.
class _CompileRunnerArgState {
  String? platform;
  String arch = 'arm64';
  String? appName;
  String minimumOsVersion = '14.0';
  bool sdkAvailable = false;
  String? sdkRootPath;
  String? swiftcPath;
  String? clangPath;
  final sourcePaths = <String>[];
  final headerPaths = <String>[];
  final modulemapPaths = <String>[];
  final frameworkPaths = <String>[];
  final sdkFrameworks = <String>[];
  final sdkDylibs = <String>[];
  String? outputPath;

  int apply(List<String> args, int i) {
    final arg = args[i];
    String nextVal() {
      if (i + 1 >= args.length) {
        _usageError('Missing value for $arg.');
      }
      return args[++i];
    }

    switch (arg) {
      case '--platform':
        platform = nextVal();
      case '--arch':
        arch = nextVal();
      case '--app-name':
        appName = nextVal();
      case '--minimum-os-version':
        minimumOsVersion = nextVal();
      case '--sdk-available':
        sdkAvailable = nextVal().toLowerCase() == 'true';
      case '--sdk-root':
        sdkRootPath = nextVal();
      case '--swiftc':
        swiftcPath = nextVal();
      case '--clang':
        clangPath = nextVal();
      case '--source':
        sourcePaths.add(nextVal());
      case '--header':
        headerPaths.add(nextVal());
      case '--modulemap':
        modulemapPaths.add(nextVal());
      case '--framework':
        frameworkPaths.add(nextVal());
      case '--sdk-framework':
        sdkFrameworks.add(nextVal());
      case '--sdk-dylib':
        sdkDylibs.add(nextVal());
      case '--output':
        outputPath = nextVal();
      default:
        _usageError('Unrecognized argument for compile-runner: $arg');
    }
    return i;
  }

  RunnerCompileConfig build() {
    if (platform == null || appName == null || outputPath == null) {
      _usageError(
        'Required flags for compile-runner: --platform, --app-name, --output.',
      );
    }
    return RunnerCompileConfig(
      platform: platform!,
      arch: arch,
      appName: appName!,
      minimumOsVersion: minimumOsVersion,
      sdkAvailable: sdkAvailable,
      sdkRootPath: sdkRootPath,
      swiftcPath: swiftcPath,
      clangPath: clangPath,
      sourcePaths: sourcePaths,
      headerPaths: headerPaths,
      modulemapPaths: modulemapPaths,
      frameworkPaths: frameworkPaths,
      sdkFrameworks: sdkFrameworks,
      sdkDylibs: sdkDylibs,
      outputPath: outputPath!,
    );
  }
}

void _runCompileRunnerCli(List<String> args) {
  final state = _CompileRunnerArgState();
  for (var i = 0; i < args.length; i++) {
    i = state.apply(args, i);
  }

  try {
    compileRunner(state.build());
  } on Object catch (e) {
    stderr.writeln('xtool_pack compile-runner failed: $e');
    exit(1);
  }
}

const Set<String> _ambientHostEnvVars = {
  'TMPDIR',
  'TEST_TMPDIR',
  'HOME',
  'PATH',
  'PWD',
  'USER',
  'LOGNAME',
  'SHELL',
  'SHLVL',
  '_',
};

/// Mutable parse state for `bundle` CLI arguments.
class _BundleArgState {
  String? platform;
  String? appName;
  String? bundleId;
  String? executablePath;
  String minimumOsVersion = '14.0';
  final families = <String>[];
  String? versionFilePath;
  final infoPlistPaths = <String>[];
  final defines = <String, String>{};
  final frameworkPaths = <String>[];
  final nativeLibPaths = <String>[];
  final resourceSpecs = <String>[];
  final additionalContentSpecs = <String>[];
  String? provisioningProfilePath;
  String? entitlementsPath;
  String? zsignPath;
  String? certificatePath;
  String? certificatePasswordFilePath;
  String? certificatePasswordEnv;
  var isolatedEnv = false;
  final declaredEnvVars = <String>{};
  String? tempDirPath;
  String? outputArchivePath;
  String? outputAppDirPath;

  int apply(List<String> args, int i) {
    final arg = args[i];
    if (arg == '--certificate-password' ||
        arg.startsWith('--certificate-password=')) {
      throw ArgumentError(
        '--certificate-password is not permitted because command-line '
        'arguments are visible in process listings and build logs. '
        'Use --certificate-password-file <path> or '
        '--certificate-password-env <ENV_VAR> instead.',
      );
    }

    String nextVal() {
      if (i + 1 >= args.length) {
        throw ArgumentError('Missing value for $arg.');
      }
      return args[++i];
    }

    if (_applyIdentityFlag(arg, nextVal)) return i;
    if (_applySigningFlag(arg, nextVal)) return i;
    switch (arg) {
      case '--define':
        final kv = nextVal();
        final eq = kv.indexOf('=');
        if (eq == -1) {
          throw ArgumentError('Expected KEY=VALUE for --define, got "$kv".');
        }
        defines[kv.substring(0, eq)] = kv.substring(eq + 1);
      case '--isolated-env':
        isolatedEnv = true;
      case '--declared-env':
        declaredEnvVars.add(nextVal());
      default:
        throw ArgumentError('Unrecognized argument: $arg');
    }
    return i;
  }

  bool _applyIdentityFlag(String arg, String Function() nextVal) {
    switch (arg) {
      case '--platform':
        platform = nextVal();
      case '--app-name':
        appName = nextVal();
      case '--bundle-id':
        bundleId = nextVal();
      case '--executable':
        executablePath = nextVal();
      case '--minimum-os-version':
        minimumOsVersion = nextVal();
      case '--family':
        families.add(nextVal());
      case '--version-file':
        versionFilePath = nextVal();
      case '--info-plist':
        infoPlistPaths.add(nextVal());
      case '--framework':
        frameworkPaths.add(nextVal());
      case '--native-lib':
        nativeLibPaths.add(nextVal());
      case '--resource':
        resourceSpecs.add(nextVal());
      case '--additional-content':
        additionalContentSpecs.add(nextVal());
      default:
        return false;
    }
    return true;
  }

  bool _applySigningFlag(String arg, String Function() nextVal) {
    switch (arg) {
      case '--provisioning-profile':
        provisioningProfilePath = nextVal();
      case '--entitlements':
        entitlementsPath = nextVal();
      case '--zsign':
        zsignPath = nextVal();
      case '--certificate':
        certificatePath = nextVal();
      case '--certificate-password-file':
        certificatePasswordFilePath = nextVal();
      case '--certificate-password-env':
        certificatePasswordEnv = nextVal();
      case '--temp-dir':
        tempDirPath = nextVal();
      case '--output-archive':
        outputArchivePath = nextVal();
      case '--output-app-dir':
        outputAppDirPath = nextVal();
      default:
        return false;
    }
    return true;
  }

  Map<String, String> _buildResolvedEnv() {
    final resolvedEnv = <String, String>{};
    if (isolatedEnv) {
      for (final key in declaredEnvVars) {
        if (key == 'TMPDIR' || key == 'TEST_TMPDIR') continue;
        final val = Platform.environment[key];
        if (val != null) {
          resolvedEnv[key] = val;
        }
      }
      if (certificatePasswordEnv != null &&
          certificatePasswordEnv!.isNotEmpty) {
        resolvedEnv.putIfAbsent(certificatePasswordEnv!, () => '');
      }
      return resolvedEnv;
    }
    for (final entry in Platform.environment.entries) {
      if (_ambientHostEnvVars.contains(entry.key) &&
          !declaredEnvVars.contains(entry.key)) {
        continue;
      }
      if (entry.key == 'TMPDIR' || entry.key == 'TEST_TMPDIR') {
        continue;
      }
      resolvedEnv[entry.key] = entry.value;
    }
    if (certificatePasswordEnv == 'TMPDIR' ||
        certificatePasswordEnv == 'TEST_TMPDIR') {
      resolvedEnv[certificatePasswordEnv!] = '';
    }
    return resolvedEnv;
  }

  BundleConfig build() {
    if (platform == null ||
        appName == null ||
        bundleId == null ||
        executablePath == null ||
        (outputArchivePath == null && outputAppDirPath == null)) {
      throw ArgumentError(
        'Required flags: --platform, --app-name, --bundle-id, --executable, '
        'and at least one of --output-archive or --output-app-dir.',
      );
    }
    return BundleConfig(
      platform: platform!,
      appName: appName!,
      bundleId: bundleId!,
      executablePath: executablePath!,
      minimumOsVersion: minimumOsVersion,
      families: families,
      versionFilePath: versionFilePath,
      infoPlistPaths: infoPlistPaths,
      defines: defines,
      frameworkPaths: frameworkPaths,
      nativeLibPaths: nativeLibPaths,
      resourceSpecs: resourceSpecs,
      additionalContentSpecs: additionalContentSpecs,
      provisioningProfilePath: provisioningProfilePath,
      entitlementsPath: entitlementsPath,
      zsignPath: zsignPath,
      certificatePath: certificatePath,
      certificatePasswordFilePath: certificatePasswordFilePath,
      certificatePasswordEnv: certificatePasswordEnv,
      tempDirPath: tempDirPath,
      outputArchivePath: outputArchivePath,
      outputAppDirPath: outputAppDirPath,
      environment: _buildResolvedEnv(),
    );
  }
}

/// Parses `bundle` CLI arguments into a [BundleConfig], throwing [ArgumentError]
/// on invalid or forbidden flags (such as plain-text `--certificate-password`).
BundleConfig parseBundleCliArgs(List<String> args) {
  final state = _BundleArgState();
  for (var i = 0; i < args.length; i++) {
    i = state.apply(args, i);
  }
  return state.build();
}

void main(List<String> args) {
  if (args.isEmpty) {
    _usageError(
      'Missing subcommand (expected "bundle", "compile-runner", or "resolve-version").',
    );
  }

  final subcommand = args.first;
  if (subcommand == 'compile-runner') {
    _runCompileRunnerCli(args.sublist(1));
    return;
  }
  if (subcommand == 'resolve-version') {
    _runResolveVersionCli(args.sublist(1));
    return;
  }
  if (subcommand != 'bundle') {
    _usageError(
      'Unknown subcommand "$subcommand" (expected "bundle", "compile-runner", or "resolve-version").',
    );
  }

  final BundleConfig config;
  try {
    config = parseBundleCliArgs(args.sublist(1));
  } on ArgumentError catch (e) {
    _usageError('${e.message}');
  }

  try {
    assembleBundle(config);
  } on Object catch (e) {
    stderr.writeln('xtool_pack failed: $e');
    exit(1);
  }
}
