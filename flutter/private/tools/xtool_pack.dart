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
///     [--certificate-password <password>] \
///     [--output-archive <path>] \
///     [--output-app-dir <path>]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Pure-Dart SHA-1 (RFC 3174) & SHA-256 (FIPS 180-4)
// ---------------------------------------------------------------------------

int _rotl32(int val, int shift) =>
    ((val << shift) & 0xFFFFFFFF) | ((val & 0xFFFFFFFF) >>> (32 - shift));

int _rotr32(int val, int shift) =>
    ((val & 0xFFFFFFFF) >>> shift) | ((val << (32 - shift)) & 0xFFFFFFFF);

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

const List<int> _sha256K = [
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

/// Computes the 32-byte SHA-256 digest of [data] per FIPS 180-4.
Uint8List sha256Bytes(List<int> data) {
  final msgLen = data.length;
  final bitLen = msgLen * 8;
  final padLen = ((56 - (msgLen + 1) % 64) + 64) % 64;
  final totalLen = msgLen + 1 + padLen + 8;
  final padded = Uint8List(totalLen);
  padded.setRange(0, msgLen, data);
  padded[msgLen] = 0x80;
  final bd = ByteData.sublistView(padded);
  bd.setUint32(totalLen - 8, (bitLen ~/ 0x100000000) & 0xFFFFFFFF, Endian.big);
  bd.setUint32(totalLen - 4, bitLen & 0xFFFFFFFF, Endian.big);

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final w = Uint32List(64);

  for (var offset = 0; offset < totalLen; offset += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = bd.getUint32(offset + i * 4, Endian.big);
    }
    for (var i = 16; i < 64; i++) {
      final s0 =
          _rotr32(w[i - 15], 7) ^ _rotr32(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 =
          _rotr32(w[i - 2], 17) ^ _rotr32(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final temp1 = (h + s1 + ch + _sha256K[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xFFFFFFFF;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }

    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + h) & 0xFFFFFFFF;
  }

  final out = Uint8List(32);
  final outBd = ByteData.sublistView(out);
  outBd.setUint32(0, h0, Endian.big);
  outBd.setUint32(4, h1, Endian.big);
  outBd.setUint32(8, h2, Endian.big);
  outBd.setUint32(12, h3, Endian.big);
  outBd.setUint32(16, h4, Endian.big);
  outBd.setUint32(20, h5, Endian.big);
  outBd.setUint32(24, h6, Endian.big);
  outBd.setUint32(28, h7, Endian.big);
  return out;
}

// ---------------------------------------------------------------------------
// Info.plist parsing, merging, variable substitution, and standard keys
// ---------------------------------------------------------------------------

/// A root `<dict>` entry in an XML property list.
class PlistEntry {
  final String key;
  final String rawValue;

  const PlistEntry(this.key, this.rawValue);
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

  final entries = <PlistEntry>[];
  var pos = openEnd + 1;

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
    final nameStart = pos;
    while (pos < xml.length && RegExp(r'[A-Za-z0-9_.:-]').hasMatch(xml[pos])) {
      pos++;
    }
    final name = xml.substring(nameStart, pos);
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
      if (xml.startsWith('<!--', pos)) {
        final end = xml.indexOf('-->', pos + 4);
        if (end == -1) {
          throw FormatException('Unterminated comment in $source.');
        }
        pos = end + 3;
        continue;
      }
      final (_, nestedSelfClosing, nestedEnd) = readTag();
      if (nestedEnd) {
        depth--;
      } else if (!nestedSelfClosing) {
        depth++;
      }
    }
    return xml.substring(start, pos);
  }

  while (true) {
    skipTrivia();
    if (pos >= xml.length) {
      throw FormatException('Root <dict> not closed in $source.');
    }
    final (tagName, selfClosing, isEnd) = readTag();
    if (isEnd) {
      if (tagName != 'dict') {
        throw FormatException('Unexpected </$tagName> in $source.');
      }
      return entries;
    }
    if (tagName != 'key' || selfClosing) {
      throw FormatException('Expected <key> in $source, found <$tagName>.');
    }
    final keyClose = xml.indexOf('</key>', pos);
    if (keyClose == -1) {
      throw FormatException('Unclosed <key> in $source.');
    }
    final keyName = xml.substring(pos, keyClose).trim();
    pos = keyClose + '</key>'.length;
    skipTrivia();
    final valueXml = readElement();
    entries.add(PlistEntry(keyName, valueXml));
  }
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

/// Merges zero or more XML `Info.plist` sources, substitutes Xcode build
/// variables, and injects standard Apple bundle keys required by iOS/macOS.
String buildInfoPlist({
  required List<String> plistXmls,
  required String platform,
  required String appName,
  required String bundleId,
  required String minimumOsVersion,
  Map<String, String> extraVariables = const {},
}) {
  final variables = <String, String>{
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

  final merged = <String, String>{};
  final order = <String>[];

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

  for (var i = 0; i < plistXmls.length; i++) {
    final entries = parsePlistEntries(plistXmls[i], source: 'plist[$i]');
    for (final entry in entries) {
      setEntry(entry.key, entry.rawValue, overwriteNonEmpty: true);
    }
  }

  // Drop empty CFBundleIconFile left by `flutter create` scaffolds if nothing
  // populated it.
  if (merged.containsKey('CFBundleIconFile') &&
      _isEmptyPlistString(merged['CFBundleIconFile']!)) {
    merged.remove('CFBundleIconFile');
    order.remove('CFBundleIconFile');
  }

  // Standard Apple bundle defaults (only injected when missing or empty).
  final defaults = <String, String>{
    'CFBundleDevelopmentRegion': '<string>en</string>',
    'CFBundleExecutable': '<string>${_escapeXml(appName)}</string>',
    'CFBundleIdentifier': '<string>${_escapeXml(bundleId)}</string>',
    'CFBundleInfoDictionaryVersion': '<string>6.0</string>',
    'CFBundleName': '<string>${_escapeXml(appName)}</string>',
    'CFBundlePackageType': '<string>APPL</string>',
    'CFBundleShortVersionString': '<string>1.0.0</string>',
    'CFBundleVersion': '<string>1</string>',
  };

  if (platform == 'ios' || platform == 'ios_sim') {
    final supportedPlatform = platform == 'ios_sim'
        ? 'iPhoneSimulator'
        : 'iPhoneOS';
    final dtPlatform = platform == 'ios_sim' ? 'iphonesimulator' : 'iphoneos';
    defaults['MinimumOSVersion'] =
        '<string>${_escapeXml(minimumOsVersion)}</string>';
    defaults['CFBundleSupportedPlatforms'] =
        '<array>\n\t\t<string>$supportedPlatform</string>\n\t</array>';
    defaults['DTPlatformName'] = '<string>$dtPlatform</string>';
    defaults['UIDeviceFamily'] = '<array>\n\t\t<integer>1</integer>\n\t\t<integer>2</integer>\n\t</array>';
  } else if (platform == 'macos') {
    defaults['LSMinimumSystemVersion'] =
        '<string>${_escapeXml(minimumOsVersion)}</string>';
    defaults['CFBundleSupportedPlatforms'] =
        '<array>\n\t\t<string>MacOSX</string>\n\t</array>';
    defaults['DTPlatformName'] = '<string>macosx</string>';
    defaults['NSPrincipalClass'] = '<string>NSApplication</string>';
  }

  for (final entry in defaults.entries) {
    setEntry(entry.key, entry.value, overwriteNonEmpty: false);
  }

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
  final rootPath = bundleDir.path;
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

final Uint32List _crc32Table = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      if ((c & 1) != 0) {
        c = 0xEDB88320 ^ (c >>> 1);
      } else {
        c = c >>> 1;
      }
    }
    table[i] = c;
  }
  return table;
}();

/// Computes the IEEE 802.3 CRC-32 checksum of [bytes].
int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (var i = 0; i < bytes.length; i++) {
    c = _crc32Table[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// An entry in a deterministic ZIP archive.
class ZipEntry {
  final String path;
  final Uint8List data;
  final bool isDirectory;
  final bool isExecutable;
  final bool isSymlink;

  const ZipEntry({
    required this.path,
    required this.data,
    this.isDirectory = false,
    this.isExecutable = false,
    this.isSymlink = false,
  });
}

/// Builds a deterministic ZIP archive from [rootDir].
///
/// [executablePaths] contains relative archive paths (using `/`) that should
/// receive `0755` (`-rwxr-xr-x`) Unix permissions regardless of host filesystem
/// mode bits.
Uint8List createDeterministicZipFromDirectory(
  Directory rootDir, {
  Set<String> executablePaths = const {},
}) {
  final entries = <ZipEntry>[];

  void walk(Directory dir, String relPrefix) {
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
          ZipEntry(
            path: '$relPath/',
            data: Uint8List(0),
            isDirectory: true,
          ),
        );
        walk(entity, relPath);
      } else if (entity is File) {
        final stat = entity.statSync();
        final isExec =
            executablePaths.contains(relPath) ||
            ((stat.mode & 0x49) != 0); // 0111 in octal
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

  walk(rootDir, '');
  return encodeDeterministicZip(entries);
}

/// Encodes [entries] into a deterministic ZIP byte buffer.
Uint8List encodeDeterministicZip(List<ZipEntry> entries) {
  final sorted = [...entries]..sort((a, b) => a.path.compareTo(b.path));
  final localParts = BytesBuilder(copy: false);
  final centralParts = BytesBuilder(copy: false);
  final rawDeflate = ZLibCodec(raw: true);

  // Fixed DOS timestamp: 1980-01-01 00:00:00 (time = 0, date = 0x0021).
  const dosTime = 0x0000;
  const dosDate = 0x0021;
  // Version made by: Unix (3) << 8 | ZIP 2.0 (20).
  const versionMadeBy = (3 << 8) | 20;
  const versionNeeded = 20;

  var offset = 0;

  for (final entry in sorted) {
    final nameBytes = utf8.encode(entry.path);
    final uncompressed = entry.data;
    final crc = entry.isDirectory ? 0 : crc32(uncompressed);

    int compressionMethod = 0; // Stored
    Uint8List payload = uncompressed;
    if (!entry.isDirectory && !entry.isSymlink && uncompressed.isNotEmpty) {
      final deflated = Uint8List.fromList(rawDeflate.encode(uncompressed));
      if (deflated.length < uncompressed.length) {
        compressionMethod = 8; // Deflate
        payload = deflated;
      }
    }

    final int externalAttrs;
    if (entry.isDirectory) {
      externalAttrs = (0x41ED << 16) | 0x10; // drwxr-xr-x + DOS directory bit
    } else if (entry.isSymlink) {
      externalAttrs = (0xA1FF << 16); // lrwxrwxrwx
    } else if (entry.isExecutable) {
      externalAttrs = (0x81ED << 16); // -rwxr-xr-x
    } else {
      externalAttrs = (0x81A4 << 16); // -rw-r--r--
    }

    // Local file header (30 bytes + filename + payload).
    final localHeader = ByteData(30 + nameBytes.length);
    localHeader.setUint32(0, 0x04034b50, Endian.little);
    localHeader.setUint16(4, versionNeeded, Endian.little);
    localHeader.setUint16(6, 0x0800, Endian.little); // UTF-8 flag
    localHeader.setUint16(8, compressionMethod, Endian.little);
    localHeader.setUint16(10, dosTime, Endian.little);
    localHeader.setUint16(12, dosDate, Endian.little);
    localHeader.setUint32(14, crc, Endian.little);
    localHeader.setUint32(18, payload.length, Endian.little);
    localHeader.setUint32(22, uncompressed.length, Endian.little);
    localHeader.setUint16(26, nameBytes.length, Endian.little);
    localHeader.setUint16(28, 0, Endian.little);
    localHeader.buffer.asUint8List().setRange(
      30,
      30 + nameBytes.length,
      nameBytes,
    );

    localParts.add(localHeader.buffer.asUint8List());
    localParts.add(payload);

    // Central directory header (46 bytes + filename).
    final centralHeader = ByteData(46 + nameBytes.length);
    centralHeader.setUint32(0, 0x02014b50, Endian.little);
    centralHeader.setUint16(4, versionMadeBy, Endian.little);
    centralHeader.setUint16(6, versionNeeded, Endian.little);
    centralHeader.setUint16(8, 0x0800, Endian.little); // UTF-8 flag
    centralHeader.setUint16(10, compressionMethod, Endian.little);
    centralHeader.setUint16(12, dosTime, Endian.little);
    centralHeader.setUint16(14, dosDate, Endian.little);
    centralHeader.setUint32(16, crc, Endian.little);
    centralHeader.setUint32(20, payload.length, Endian.little);
    centralHeader.setUint32(24, uncompressed.length, Endian.little);
    centralHeader.setUint16(28, nameBytes.length, Endian.little);
    centralHeader.setUint16(30, 0, Endian.little); // extra len
    centralHeader.setUint16(32, 0, Endian.little); // comment len
    centralHeader.setUint16(34, 0, Endian.little); // disk number
    centralHeader.setUint16(36, 0, Endian.little); // internal attrs
    centralHeader.setUint32(38, externalAttrs, Endian.little);
    centralHeader.setUint32(42, offset, Endian.little);
    centralHeader.buffer.asUint8List().setRange(
      46,
      46 + nameBytes.length,
      nameBytes,
    );

    centralParts.add(centralHeader.buffer.asUint8List());
    offset += 30 + nameBytes.length + payload.length;
  }

  final centralBytes = centralParts.takeBytes();
  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(4, 0, Endian.little);
  eocd.setUint16(6, 0, Endian.little);
  eocd.setUint16(8, sorted.length, Endian.little);
  eocd.setUint16(10, sorted.length, Endian.little);
  eocd.setUint32(12, centralBytes.length, Endian.little);
  eocd.setUint32(16, offset, Endian.little);
  eocd.setUint16(20, 0, Endian.little);

  localParts.add(centralBytes);
  localParts.add(eocd.buffer.asUint8List());
  return localParts.takeBytes();
}

/// Decodes a ZIP archive produced by [encodeDeterministicZip] (or standard ZIP
/// writers) into a list of [ZipEntry] items for inspection and testing.
List<ZipEntry> readZipEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  // Locate End of Central Directory (0x06054b50).
  var eocdOffset = -1;
  for (var i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocdOffset = i;
      break;
    }
  }
  if (eocdOffset == -1) {
    throw FormatException('Invalid ZIP archive: EOCD signature not found.');
  }

  final entryCount = bd.getUint16(eocdOffset + 10, Endian.little);
  final cdOffset = bd.getUint32(eocdOffset + 16, Endian.little);
  final rawInflate = ZLibCodec(raw: true);

  final entries = <ZipEntry>[];
  var pos = cdOffset;
  for (var i = 0; i < entryCount; i++) {
    if (bd.getUint32(pos, Endian.little) != 0x02014b50) {
      throw FormatException('Invalid central directory header at $pos.');
    }
    final method = bd.getUint16(pos + 10, Endian.little);
    final compressedSize = bd.getUint32(pos + 20, Endian.little);
    final nameLen = bd.getUint16(pos + 28, Endian.little);
    final extraLen = bd.getUint16(pos + 30, Endian.little);
    final commentLen = bd.getUint16(pos + 32, Endian.little);
    final externalAttrs = bd.getUint32(pos + 38, Endian.little);
    final localOffset = bd.getUint32(pos + 42, Endian.little);

    final path = utf8.decode(
      zipBytes.sublist(pos + 46, pos + 46 + nameLen),
    );
    pos += 46 + nameLen + extraLen + commentLen;

    final localNameLen = bd.getUint16(localOffset + 26, Endian.little);
    final localExtraLen = bd.getUint16(localOffset + 28, Endian.little);
    final dataStart = localOffset + 30 + localNameLen + localExtraLen;
    final rawPayload = zipBytes.sublist(dataStart, dataStart + compressedSize);

    final Uint8List data;
    if (method == 0) {
      data = Uint8List.fromList(rawPayload);
    } else if (method == 8) {
      data = Uint8List.fromList(rawInflate.decode(rawPayload));
    } else {
      throw UnsupportedError('Unsupported ZIP compression method: $method');
    }

    final unixMode = (externalAttrs >>> 16) & 0xFFFF;
    final fileType = unixMode & 0xF000;
    final isDir = path.endsWith('/') || fileType == 0x4000;
    final isSymlink = fileType == 0xA000;
    final isExec = !isDir && !isSymlink && ((unixMode & 0x49) != 0);

    entries.add(
      ZipEntry(
        path: path,
        data: data,
        isDirectory: isDir,
        isExecutable: isExec,
        isSymlink: isSymlink,
      ),
    );
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

void _copyResourceSpec(String spec, Directory destRoot) {
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

/// Configuration for assembling an iOS or macOS application bundle and archive.
class BundleConfig {
  final String platform; // 'ios', 'ios_sim', or 'macos'
  final String appName;
  final String bundleId;
  final String executablePath;
  final String minimumOsVersion;
  final List<String> infoPlistPaths;
  final Map<String, String> defines;
  final List<String> frameworkPaths;
  final List<String> resourceSpecs;
  final String? provisioningProfilePath;
  final String? entitlementsPath;
  final String? zsignPath;
  final String? certificatePath;
  final String? certificatePassword;
  final String? outputArchivePath;
  final String? outputAppDirPath;

  const BundleConfig({
    required this.platform,
    required this.appName,
    required this.bundleId,
    required this.executablePath,
    required this.minimumOsVersion,
    this.infoPlistPaths = const [],
    this.defines = const {},
    this.frameworkPaths = const [],
    this.resourceSpecs = const [],
    this.provisioningProfilePath,
    this.entitlementsPath,
    this.zsignPath,
    this.certificatePath,
    this.certificatePassword,
    this.outputArchivePath,
    this.outputAppDirPath,
  });
}

/// Assembles an iOS `.ipa` or macOS `.app.zip` (and optional `.app` directory)
/// according to [config].
void assembleBundle(BundleConfig config) {
  if (config.platform != 'ios' &&
      config.platform != 'ios_sim' &&
      config.platform != 'macos') {
    throw ArgumentError(
      'Unsupported platform "${config.platform}". Expected ios, ios_sim, or macos.',
    );
  }

  final execFile = File(config.executablePath);
  if (!execFile.existsSync()) {
    throw ArgumentError(
      'Executable binary does not exist: ${config.executablePath}',
    );
  }

  final tempDir = Directory.systemTemp.createTempSync('xtool_pack_');
  try {
    final isMacOS = config.platform == 'macos';
    final appRelPath = isMacOS
        ? '${config.appName}.app'
        : 'Payload/${config.appName}.app';
    final appDir = Directory('${tempDir.path}/$appRelPath')
      ..createSync(recursive: true);

    final contentsDir = isMacOS
        ? (Directory('${appDir.path}/Contents')..createSync())
        : appDir;
    final execDir = isMacOS
        ? (Directory('${contentsDir.path}/MacOS')..createSync())
        : contentsDir;
    final frameworksDir = Directory('${contentsDir.path}/Frameworks');
    final resourcesDir = isMacOS
        ? (Directory('${contentsDir.path}/Resources')..createSync())
        : contentsDir;

    final executablePaths = <String>{};

    // 1. Copy main executable.
    // Executable permissions (0755) are recorded directly in the ZIP central
    // directory via executablePaths without spawning an external chmod process.
    final destExecPath = '${execDir.path}/${config.appName}';
    execFile.copySync(destExecPath);
    executablePaths.add(
      isMacOS
          ? '$appRelPath/Contents/MacOS/${config.appName}'
          : '$appRelPath/${config.appName}',
    );

    // 2. Merge and write Info.plist + PkgInfo.
    final plistXmls = [
      for (final p in config.infoPlistPaths) File(p).readAsStringSync(),
    ];
    final mergedPlist = buildInfoPlist(
      plistXmls: plistXmls,
      platform: config.platform,
      appName: config.appName,
      bundleId: config.bundleId,
      minimumOsVersion: config.minimumOsVersion,
      extraVariables: config.defines,
    );
    File('${contentsDir.path}/Info.plist').writeAsStringSync(mergedPlist);
    File('${contentsDir.path}/PkgInfo').writeAsStringSync('APPL????');

    // 3. Copy resources.
    for (final spec in config.resourceSpecs) {
      _copyResourceSpec(spec, resourcesDir);
    }

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

    final shouldSign = config.zsignPath != null && config.zsignPath!.isNotEmpty;

    void stripCodeSignatures(Directory dir) {
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync(followLinks: false)) {
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name == '_CodeSignature') {
          entity.deleteSync(recursive: true);
        } else if (entity is Directory) {
          stripCodeSignatures(entity);
        }
      }
    }

    // 5. Resolve and embed frameworks.
    for (final fwInput in config.frameworkPaths) {
      final fwDirs = resolveFrameworkDirectories(fwInput, config.platform);
      for (final fwDir in fwDirs) {
        frameworksDir.createSync(recursive: true);
        final fwFileName = fwDir.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .last;
        final fwName = fwFileName.substring(
          0,
          fwFileName.length - '.framework'.length,
        );
        final destFwDir = Directory('${frameworksDir.path}/$fwFileName');
        _copyDirectorySync(fwDir, destFwDir, dereferenceSymlinks: false);

        // Mark framework binary executable in ZIP metadata.
        final fwRelPrefix = isMacOS
            ? '$appRelPath/Contents/Frameworks/$fwFileName'
            : '$appRelPath/Frameworks/$fwFileName';
        final topBinary = File('${destFwDir.path}/$fwName');
        final versionedBinary = File('${destFwDir.path}/Versions/A/$fwName');
        if (topBinary.existsSync()) {
          executablePaths.add('$fwRelPrefix/$fwName');
        }
        if (versionedBinary.existsSync()) {
          executablePaths.add('$fwRelPrefix/Versions/A/$fwName');
        }

        if (shouldSign) {
          writeCodeResources(
            destFwDir,
            excludedRelativePaths: {
              fwName,
              'Versions/A/$fwName',
              'Versions/Current/$fwName',
            },
          );
        } else {
          stripCodeSignatures(destFwDir);
        }
      }
    }

    // 6. Sign bundle with _CodeSignature/CodeResources + zsign when configured,
    //    or ensure unsigned bundles contain no _CodeSignature/ artifacts.
    if (shouldSign) {
      writeCodeResources(
        contentsDir,
        excludedRelativePaths: {
          if (isMacOS) 'MacOS/${config.appName}' else config.appName,
        },
      );
      final zsignArgs = <String>[];
      if (config.certificatePath != null &&
          config.certificatePath!.isNotEmpty) {
        zsignArgs.addAll(['-k', config.certificatePath!]);
      }
      if (config.certificatePassword != null &&
          config.certificatePassword!.isNotEmpty) {
        zsignArgs.addAll(['-p', config.certificatePassword!]);
      }
      if (config.provisioningProfilePath != null &&
          config.provisioningProfilePath!.isNotEmpty) {
        zsignArgs.addAll(['-m', config.provisioningProfilePath!]);
      }
      if (config.entitlementsPath != null &&
          config.entitlementsPath!.isNotEmpty) {
        zsignArgs.addAll(['-e', config.entitlementsPath!]);
      }
      zsignArgs.add(appDir.path);
      final result = Process.runSync(config.zsignPath!, zsignArgs);
      if (result.exitCode != 0) {
        throw ProcessException(
          config.zsignPath!,
          zsignArgs,
          'zsign failed (exit ${result.exitCode}):\n${result.stderr}',
          result.exitCode,
        );
      }
    } else {
      stripCodeSignatures(appDir);
    }

    // 8. Emit --output-app-dir if requested.
    if (config.outputAppDirPath != null &&
        config.outputAppDirPath!.isNotEmpty) {
      final outAppDir = Directory(config.outputAppDirPath!);
      if (outAppDir.existsSync()) {
        outAppDir.deleteSync(recursive: true);
      }
      _copyDirectorySync(appDir, outAppDir, dereferenceSymlinks: false);
    }

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
  } finally {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
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

/// Synthesizes a 64-bit Mach-O `MH_EXECUTE` runner binary with
/// `LC_BUILD_VERSION`, `LC_RPATH`, and `LC_LOAD_DYLIB` commands.
Uint8List generateStubExecutableMachO({
  required String platform,
  String arch = 'arm64',
  required String minimumOsVersion,
  List<String> linkedFrameworkNames = const [],
  List<String> metadataEntries = const [],
}) {
  final int cpuType;
  final int cpuSubtype;
  switch (arch) {
    case 'arm64':
      cpuType = 0x0100000c; // CPU_TYPE_ARM64
      cpuSubtype = 0; // CPU_SUBTYPE_ARM64_ALL
    case 'x86_64':
      cpuType = 0x01000007; // CPU_TYPE_X86_64
      cpuSubtype = 3; // CPU_SUBTYPE_X86_64_ALL
    default:
      throw ArgumentError('Unsupported architecture "$arch".');
  }

  final versionPacked = _packMachOVersion(minimumOsVersion);
  final rpath = platform == 'macos'
      ? '@executable_path/../Frameworks'
      : '@executable_path/Frameworks';

  final loadCommands = <Uint8List>[
    _encodeMachOBuildVersionCommand(
      platform: _machOPlatformConstant(platform),
      minos: versionPacked,
      sdk: versionPacked,
    ),
    _encodeMachORpathCommand(rpath),
    for (final fw in linkedFrameworkNames)
      _encodeMachOLoadDylibCommand('@rpath/$fw.framework/$fw'),
  ];

  final sizeofcmds = loadCommands.fold<int>(0, (s, c) => s + c.length);
  final metadataText = metadataEntries.isEmpty
      ? ''
      : '${metadataEntries.join('\n')}\n';
  final metadataBytes = utf8.encode(metadataText);
  final paddedMetaLen = (metadataBytes.length + 7) & ~7;

  final totalSize = 32 + sizeofcmds + paddedMetaLen;
  final out = Uint8List(totalSize);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, 0xfeedfacf, Endian.little); // MH_MAGIC_64
  bd.setInt32(4, cpuType, Endian.little);
  bd.setInt32(8, cpuSubtype, Endian.little);
  bd.setUint32(12, 0x2, Endian.little); // MH_EXECUTE
  bd.setUint32(16, loadCommands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, 0x00200001, Endian.little); // MH_NOUNDEFS | MH_PIE
  bd.setUint32(28, 0, Endian.little); // reserved

  var offset = 32;
  for (final cmd in loadCommands) {
    out.setRange(offset, offset + cmd.length, cmd);
    offset += cmd.length;
  }
  if (metadataBytes.isNotEmpty) {
    out.setRange(offset, offset + metadataBytes.length, metadataBytes);
  }
  return out;
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

  final String sdkPrefix;
  final String defaultDirName;
  switch (platform) {
    case 'ios':
      sdkPrefix = 'iphoneos';
      defaultDirName = 'iPhoneOS.sdk';
    case 'ios_sim':
      sdkPrefix = 'iphonesimulator';
      defaultDirName = 'iPhoneSimulator.sdk';
    case 'macos':
      sdkPrefix = 'macosx';
      defaultDirName = 'MacOSX.sdk';
    default:
      throw ArgumentError('Unsupported platform "$platform".');
  }

  final infoJsonFile = File('${sdkRoot.path}/info.json');
  if (infoJsonFile.existsSync()) {
    final decoded = jsonDecode(infoJsonFile.readAsStringSync());
    if (decoded is Map<String, Object?>) {
      final artifacts = decoded['artifacts'];
      if (artifacts is Map<String, Object?>) {
        for (final entry in artifacts.entries) {
          final keyLower = entry.key.toLowerCase();
          final val = entry.value;
          if (val is Map<String, Object?>) {
            final variants = val['variants'];
            if (variants is List<Object?>) {
              for (final v in variants) {
                if (v is Map<String, Object?>) {
                  final path = v['path'];
                  if (path is String &&
                      (keyLower.startsWith(sdkPrefix) ||
                          path.toLowerCase().contains(sdkPrefix))) {
                    final candidate = Directory('${sdkRoot.path}/$path');
                    if (candidate.existsSync()) {
                      return candidate;
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  final fallback = Directory('${sdkRoot.path}/$defaultDirName');
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
    required this.outputPath,
  });
}

/// Compiles or synthesizes a Mach-O `MH_EXECUTE` runner binary from
/// [RunnerCompileConfig].
void compileRunner(RunnerCompileConfig config) {
  if (config.platform != 'ios' &&
      config.platform != 'ios_sim' &&
      config.platform != 'macos') {
    throw ArgumentError(
      'Unsupported platform "${config.platform}". Expected ios, ios_sim, or macos.',
    );
  }

  for (final src in config.sourcePaths) {
    if (!File(src).existsSync()) {
      throw ArgumentError('Runner source file does not exist: $src');
    }
  }
  for (final hdr in config.headerPaths) {
    if (!File(hdr).existsSync()) {
      throw ArgumentError('Runner header file does not exist: $hdr');
    }
  }
  for (final mm in config.modulemapPaths) {
    if (!File(mm).existsSync()) {
      throw ArgumentError('Runner modulemap file does not exist: $mm');
    }
  }

  final resolvedFrameworkDirs = <Directory>[];
  final linkedFrameworkNames = <String>[];
  for (final fwInput in config.frameworkPaths) {
    final dirs = resolveFrameworkDirectories(fwInput, config.platform);
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

  Directory? resolvedSdkDir;
  if (config.sdkAvailable &&
      config.sdkRootPath != null &&
      config.sdkRootPath!.isNotEmpty) {
    resolvedSdkDir = resolveDarwinSdkPathFromArtifactBundle(
      Directory(config.sdkRootPath!),
      config.platform,
    );
  }

  if (config.sdkAvailable &&
      config.swiftcPath != null &&
      config.swiftcPath!.isNotEmpty) {
    final String targetTriple;
    switch (config.platform) {
      case 'ios':
        targetTriple = '${config.arch}-apple-ios${config.minimumOsVersion}';
      case 'ios_sim':
        targetTriple =
            '${config.arch}-apple-ios${config.minimumOsVersion}-simulator';
      case 'macos':
        targetTriple = '${config.arch}-apple-macos${config.minimumOsVersion}';
      default:
        throw StateError('Unreachable');
    }

    final swiftcArgs = <String>[
      '-target',
      targetTriple,
      if (resolvedSdkDir != null) ...['-sdk', resolvedSdkDir.path],
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

    File(config.outputPath).parent.createSync(recursive: true);
    final result = Process.runSync(config.swiftcPath!, swiftcArgs);
    if (result.exitCode != 0) {
      throw ProcessException(
        config.swiftcPath!,
        swiftcArgs,
        'swiftc failed (exit ${result.exitCode}):\n${result.stderr}',
        result.exitCode,
      );
    }
    return;
  }

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
  ];

  final machoBytes = generateStubExecutableMachO(
    platform: config.platform,
    arch: config.arch,
    minimumOsVersion: config.minimumOsVersion,
    linkedFrameworkNames: linkedFrameworkNames,
    metadataEntries: metadataEntries,
  );
  final outFile = File(config.outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(machoBytes);
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
    '    [--info-plist <path> ...] \\\n'
    '    [--define <KEY=VALUE> ...] \\\n'
    '    [--framework <path> ...] \\\n'
    '    [--resource <src[=dest_rel]> ...] \\\n'
    '    [--provisioning-profile <path>] \\\n'
    '    [--entitlements <path>] \\\n'
    '    [--zsign <path>] \\\n'
    '    [--certificate <path>] \\\n'
    '    [--certificate-password <password>] \\\n'
    '    [--output-archive <path>] \\\n'
    '    [--output-app-dir <path>]',
  );
  exit(1);
}

void _runCompileRunnerCli(List<String> args) {
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
  String? outputPath;

  for (var i = 0; i < args.length; i++) {
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
      case '--output':
        outputPath = nextVal();
      default:
        _usageError('Unrecognized argument for compile-runner: $arg');
    }
  }

  if (platform == null || appName == null || outputPath == null) {
    _usageError(
      'Required flags for compile-runner: --platform, --app-name, --output.',
    );
  }

  try {
    compileRunner(
      RunnerCompileConfig(
        platform: platform,
        arch: arch,
        appName: appName,
        minimumOsVersion: minimumOsVersion,
        sdkAvailable: sdkAvailable,
        sdkRootPath: sdkRootPath,
        swiftcPath: swiftcPath,
        clangPath: clangPath,
        sourcePaths: sourcePaths,
        headerPaths: headerPaths,
        modulemapPaths: modulemapPaths,
        frameworkPaths: frameworkPaths,
        outputPath: outputPath,
      ),
    );
  } on Object catch (e) {
    stderr.writeln('xtool_pack compile-runner failed: $e');
    exit(1);
  }
}

void main(List<String> args) {
  if (args.isEmpty) {
    _usageError('Missing subcommand (expected "bundle" or "compile-runner").');
  }

  final subcommand = args.first;
  if (subcommand == 'compile-runner') {
    _runCompileRunnerCli(args.sublist(1));
    return;
  }
  if (subcommand != 'bundle') {
    _usageError(
      'Unknown subcommand "$subcommand" (expected "bundle" or "compile-runner").',
    );
  }

  String? platform;
  String? appName;
  String? bundleId;
  String? executablePath;
  String minimumOsVersion = '14.0';
  final infoPlistPaths = <String>[];
  final defines = <String, String>{};
  final frameworkPaths = <String>[];
  final resourceSpecs = <String>[];
  String? provisioningProfilePath;
  String? entitlementsPath;
  String? zsignPath;
  String? certificatePath;
  String? certificatePassword;
  String? outputArchivePath;
  String? outputAppDirPath;

  for (var i = 1; i < args.length; i++) {
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
      case '--app-name':
        appName = nextVal();
      case '--bundle-id':
        bundleId = nextVal();
      case '--executable':
        executablePath = nextVal();
      case '--minimum-os-version':
        minimumOsVersion = nextVal();
      case '--info-plist':
        infoPlistPaths.add(nextVal());
      case '--define':
        final kv = nextVal();
        final eq = kv.indexOf('=');
        if (eq == -1) {
          _usageError('Expected KEY=VALUE for --define, got "$kv".');
        }
        defines[kv.substring(0, eq)] = kv.substring(eq + 1);
      case '--framework':
        frameworkPaths.add(nextVal());
      case '--resource':
        resourceSpecs.add(nextVal());
      case '--provisioning-profile':
        provisioningProfilePath = nextVal();
      case '--entitlements':
        entitlementsPath = nextVal();
      case '--zsign':
        zsignPath = nextVal();
      case '--certificate':
        certificatePath = nextVal();
      case '--certificate-password':
        certificatePassword = nextVal();
      case '--output-archive':
        outputArchivePath = nextVal();
      case '--output-app-dir':
        outputAppDirPath = nextVal();
      default:
        _usageError('Unrecognized argument: $arg');
    }
  }

  if (platform == null ||
      appName == null ||
      bundleId == null ||
      executablePath == null ||
      (outputArchivePath == null && outputAppDirPath == null)) {
    _usageError(
      'Required flags: --platform, --app-name, --bundle-id, --executable, '
      'and at least one of --output-archive or --output-app-dir.',
    );
  }

  try {
    assembleBundle(
      BundleConfig(
        platform: platform,
        appName: appName,
        bundleId: bundleId,
        executablePath: executablePath,
        minimumOsVersion: minimumOsVersion,
        infoPlistPaths: infoPlistPaths,
        defines: defines,
        frameworkPaths: frameworkPaths,
        resourceSpecs: resourceSpecs,
        provisioningProfilePath: provisioningProfilePath,
        entitlementsPath: entitlementsPath,
        zsignPath: zsignPath,
        certificatePath: certificatePath,
        certificatePassword: certificatePassword,
        outputArchivePath: outputArchivePath,
        outputAppDirPath: outputAppDirPath,
      ),
    );
  } on Object catch (e) {
    stderr.writeln('xtool_pack failed: $e');
    exit(1);
  }
}
